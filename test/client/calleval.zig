//! Harness exe: exercise the live `tarantool-client` call/eval path (typed +
//! raw round-trips, plus a server-error negative) against the server the luatest
//! `client` group starts. Standalone binary — importing `tarantool-client` and
//! LINKING with no `box_*` symbols is the module-purity proof; the authed CALL/EVAL requests here also prove chap-sha1 end-to-end.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, runs a fixed sequence of checks, and prints TAP-ish lines
//! (`ok - <name>` / `not ok - <name> (<detail>)`). Exits 1 on the FIRST failing
//! check, 0 once every check passed — the luatest driver asserts the exit code
//! and surfaces the captured TAP text on failure.
//!
//! The stored function `harness_add(a, b) -> a + b` is created (and granted to
//! the test user) by the luatest group's before_all; the CALL checks below
//! resolve it by name.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");

const Connection = client.Connection;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const uri = env.get("TT_URI") orelse return missing("TT_URI");
    const user = env.get("TT_USER") orelse return missing("TT_USER");
    const pass = env.get("TT_PASS") orelse return missing("TT_PASS");

    var conn = Connection.connect(gpa, io, .{
        .address = uri,
        .user = user,
        .password = pass,
    }) catch |e| return fail("connect as test user", @errorName(e));
    defer conn.close();

    return run(&conn);
}

/// The check sequence over an established connection. Returns 0 iff every check
/// passed, else 1 (after the first failing check printed its `not ok` line).
fn run(conn: *Connection) u8 {
    // 1. typed EVAL, no args: `return 1 + 1` -> 2.
    {
        const got = conn.eval("return 1 + 1", .{}, i64) catch |e|
            return fail("typed eval 1+1", @errorName(e));
        if (got != 2) return failFmt("typed eval 1+1 == 2", "got {d}", .{got});
        ok("typed eval: return 1 + 1 == 2");
    }

    // 2. typed EVAL with args forwarded as `...`: math.max(3, 7) -> 7.
    {
        const got = conn.eval("return math.max(...)", .{ @as(i64, 3), @as(i64, 7) }, i64) catch |e|
            return fail("typed eval math.max", @errorName(e));
        if (got != 7) return failFmt("typed eval math.max(3,7) == 7", "got {d}", .{got});
        ok("typed eval: math.max(3, 7) == 7");
    }

    // 3. typed CALL of the stored function the luatest group created.
    {
        const got = conn.call("harness_add", .{ @as(i64, 3), @as(i64, 7) }, i64) catch |e|
            return fail("typed call harness_add", @errorName(e));
        if (got != 10) return failFmt("typed call harness_add(3,7) == 10", "got {d}", .{got});
        ok("typed call: harness_add(3, 7) == 10");
    }

    // 4. callRaw against the same function with PRE-ENCODED MP_ARRAY args; assert
    //    the raw DATA (the returns array) decodes to the expected single value.
    {
        var args = msgpack.Buffer.init(conn.gpa);
        defer args.deinit();
        msgpack.encodeArray(&args, .{ @as(i64, 3), @as(i64, 7) }) catch |e|
            return fail("callRaw encode args", @errorName(e));
        const data = (conn.callRaw("harness_add", args.items()) catch |e|
            return fail("callRaw harness_add", @errorName(e))) orelse
            return fail("callRaw harness_add", "reply carried no DATA");
        var dec = msgpack.Decoder.init(data);
        const returns = msgpack.decode(@Tuple(&.{i64}), &dec) catch |e|
            return fail("callRaw decode DATA", @errorName(e));
        if (returns[0] != 10) return failFmt("callRaw harness_add DATA == [10]", "got {d}", .{returns[0]});
        ok("callRaw: harness_add(3, 7) raw DATA decodes to 10");
    }

    // 5. string result: the returned slice BORROWS resp_buf (valid only until the
    //    next request) — assert it here, BEFORE issuing any further call.
    {
        const got = conn.eval("return 'hello'", .{}, []const u8) catch |e|
            return fail("typed eval string", @errorName(e));
        if (!std.mem.eql(u8, got, "hello"))
            return failFmt("typed eval 'hello' string", "got '{s}'", .{got});
        ok("typed eval: return 'hello' == \"hello\"");
    }

    // 6. server-error negative: `error('boom')` -> error.ServerError AND
    //    last_error populated with a message containing "boom".
    {
        if (conn.eval("error('boom')", .{}, void)) |_| {
            return fail("eval error('boom') rejected", "eval unexpectedly succeeded");
        } else |e| switch (e) {
            error.ServerError => {},
            else => return fail("eval error('boom') -> ServerError", @errorName(e)),
        }
        const le = conn.last_error orelse
            return fail("eval error('boom') last_error", "last_error is null after ServerError");
        if (std.mem.indexOf(u8, le.message, "boom") == null)
            return failFmt("eval error('boom') message", "message '{s}' lacks 'boom'", .{le.message});
        ok("server error: eval error('boom') -> ServerError + last_error 'boom'");
    }

    // 7. void/no-return: `return` (bare) yields an empty returns array; void
    //    ignores DATA and succeeds.
    {
        conn.eval("return", .{}, void) catch |e|
            return fail("typed eval void return", @errorName(e));
        ok("typed eval: bare return (void) succeeds");
    }

    return 0;
}

/// Print a passing TAP line.
fn ok(name: []const u8) void {
    std.debug.print("ok - {s}\n", .{name});
}

/// Print a failing TAP line and yield the process exit code (1).
fn fail(name: []const u8, detail: []const u8) u8 {
    std.debug.print("not ok - {s} ({s})\n", .{ name, detail });
    return 1;
}

/// `fail` with a formatted detail (e.g. an unexpected value). A too-long detail
/// is reported as such rather than swallowed.
fn failFmt(name: []const u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "detail too long to format";
    return fail(name, detail);
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
