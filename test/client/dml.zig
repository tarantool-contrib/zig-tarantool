//! Harness exe: exercise the live `tarantool-client` DML surface (Space
//! typed + raw CRUD, plus the negatives) against the server the luatest `dml`
//! group starts. Standalone binary — importing `tarantool-client` and LINKING
//! with no `box_*` symbols is the module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, drives the fixture space `dml_users` (created by the
//! luatest group's before_all: format {id unsigned, name string, score
//! unsigned}, primary tree on id, non-unique secondary tree `by_score` on
//! score), and prints TAP-ish lines (`ok - <name>` / `not ok - <name>
//! (<detail>)`). Exits 1 on the FIRST failing check, 0 once every check passed —
//! the luatest driver asserts the exit code and surfaces the captured TAP text
//! on failure.
//!
//! The checks delete every tuple they insert, so the case is rerunnable even if
//! the luatest group did not truncate between runs.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");

const Connection = client.Connection;

/// Positional tuple mirroring the `dml_users` format: {id, name, score}. A
/// tuple struct decodes/encodes as an MP_ARRAY (msgpack's `is_tuple` path),
/// matching how the server stores and echoes the row.
const Row = struct { u32, []const u8, u32 };

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
    const users = conn.space("dml_users");

    // 1. typed INSERT {1,"alice",10}; the reply echoes the inserted tuple. The
    //    returned Row borrows resp_buf — assert BEFORE the next request.
    {
        const got = users.insert(.{ @as(u32, 1), @as([]const u8, "alice"), @as(u32, 10) }, Row) catch |e|
            return fail("insert {1,alice,10}", @errorName(e));
        if (!rowEq(got, 1, "alice", 10)) return failRow("insert echoes {1,alice,10}", got);
        ok("insert: {1,alice,10} typed echo");
    }

    // 2. INSERT a DUPLICATE primary key -> error.ServerError (ER_TUPLE_FOUND) and
    //    last_error populated.
    {
        if (users.insert(.{ @as(u32, 1), @as([]const u8, "alice"), @as(u32, 10) }, void)) |_| {
            return fail("duplicate insert rejected", "insert unexpectedly succeeded");
        } else |e| switch (e) {
            error.ServerError => {},
            else => return fail("duplicate insert -> ServerError", @errorName(e)),
        }
        if (conn.last_error == null)
            return fail("duplicate insert last_error", "last_error is null after ServerError");
        ok("insert: duplicate PK -> ServerError + last_error");
    }

    // 3. GET the existing key -> the row; GET a missing key -> null.
    {
        const got = (users.get(.{@as(u32, 1)}, Row) catch |e|
            return fail("get {1}", @errorName(e))) orelse
            return fail("get {1}", "expected a row, got null");
        if (!rowEq(got, 1, "alice", 10)) return failRow("get {1} -> {1,alice,10}", got);
        ok("get: {1} -> {1,alice,10}");
    }
    {
        const got = users.get(.{@as(u32, 99)}, Row) catch |e|
            return fail("get {99}", @errorName(e));
        if (got != null) return fail("get {99} -> null", "expected null for a missing key");
        ok("get: {99} -> null");
    }

    // 4. REPLACE {1,"bob",20} -> echo the stored tuple; verify via a fresh GET.
    {
        const got = users.replace(.{ @as(u32, 1), @as([]const u8, "bob"), @as(u32, 20) }, Row) catch |e|
            return fail("replace {1,bob,20}", @errorName(e));
        if (!rowEq(got, 1, "bob", 20)) return failRow("replace echoes {1,bob,20}", got);
        ok("replace: {1,bob,20} typed echo");
    }
    {
        const got = (users.get(.{@as(u32, 1)}, Row) catch |e|
            return fail("get {1} after replace", @errorName(e))) orelse
            return fail("get {1} after replace", "expected a row, got null");
        if (!rowEq(got, 1, "bob", 20)) return failRow("get {1} after replace -> {1,bob,20}", got);
        ok("replace: verified via get {1} -> {1,bob,20}");
    }

    // 5. RAW path: insertRaw a PRE-ENCODED tuple, getRaw it back, decode the raw
    //    DATA. DATA is the OUTER array [tuple]; Tarantool frames it as an array32
    //    (0xdd) header EVEN for one element, so decode with the codec rather than
    //    pattern-matching a fixarray lead byte.
    {
        var tbuf = msgpack.Buffer.init(conn.gpa);
        defer tbuf.deinit();
        msgpack.encodeArray(&tbuf, .{ @as(u32, 2), @as([]const u8, "carol"), @as(u32, 30) }) catch |e|
            return fail("insertRaw encode tuple", @errorName(e));
        _ = users.insertRaw(tbuf.items()) catch |e|
            return fail("insertRaw {2,carol,30}", @errorName(e));

        var kbuf = msgpack.Buffer.init(conn.gpa);
        defer kbuf.deinit();
        msgpack.encodeArray(&kbuf, .{@as(u32, 2)}) catch |e|
            return fail("getRaw encode key", @errorName(e));
        const data = (users.getRaw(kbuf.items()) catch |e|
            return fail("getRaw {2}", @errorName(e))) orelse
            return fail("getRaw {2}", "reply carried no DATA");
        var dec = msgpack.Decoder.init(data);
        const outer = msgpack.decode(@Tuple(&.{Row}), &dec) catch |e|
            return fail("getRaw {2} decode DATA", @errorName(e));
        if (!rowEq(outer[0], 2, "carol", 30)) return failRow("getRaw {2} DATA -> {2,carol,30}", outer[0]);
        ok("raw: insertRaw+getRaw {2,carol,30} DATA decodes");
    }

    // 6. DELETE {1} -> echoes the deleted row; DELETE {1} again -> null.
    {
        const got = (users.delete(.{@as(u32, 1)}, Row) catch |e|
            return fail("delete {1}", @errorName(e))) orelse
            return fail("delete {1}", "expected the deleted row, got null");
        if (!rowEq(got, 1, "bob", 20)) return failRow("delete {1} echoes {1,bob,20}", got);
        ok("delete: {1} echoes {1,bob,20}");
    }
    {
        const got = users.delete(.{@as(u32, 1)}, Row) catch |e|
            return fail("delete {1} again", @errorName(e));
        if (got != null) return fail("delete {1} again -> null", "expected null, matched a tuple");
        ok("delete: {1} again -> null");
    }
    // cleanup the raw-path tuple so the case is rerunnable.
    _ = users.delete(.{@as(u32, 2)}, void) catch |e|
        return fail("cleanup delete {2}", @errorName(e));

    // 7. Row = void discard form on a write: insert compiles/works, then clean up.
    {
        users.insert(.{ @as(u32, 3), @as([]const u8, "dave"), @as(u32, 40) }, void) catch |e|
            return fail("insert {3,dave,40} discard (void)", @errorName(e));
        ok("insert: Row = void discard form works");
        _ = users.delete(.{@as(u32, 3)}, void) catch |e|
            return fail("cleanup delete {3}", @errorName(e));
    }

    // 8. INSERT into a space that does not exist -> error.ServerError, and
    //    last_error's message names the offending space (ER_NO_SUCH_SPACE).
    {
        const ghost = conn.space("no_such_space_dml");
        if (ghost.insert(.{ @as(u32, 1), @as([]const u8, "x"), @as(u32, 1) }, void)) |_| {
            return fail("insert into missing space rejected", "insert unexpectedly succeeded");
        } else |e| switch (e) {
            error.ServerError => {},
            else => return fail("insert missing space -> ServerError", @errorName(e)),
        }
        const le = conn.last_error orelse
            return fail("insert missing space last_error", "last_error is null after ServerError");
        if (std.mem.indexOf(u8, le.message, "no_such_space_dml") == null)
            return failFmt("insert missing space message names it", "message '{s}' lacks space name", .{le.message});
        ok("insert: missing space -> ServerError + last_error names it");
    }

    // 9. schema_version is updated from every response header — after the many
    //    requests above it must be non-zero (task-5 hook, populated for free).
    {
        if (conn.schema_version == 0)
            return fail("schema_version populated", "schema_version is still 0 after requests");
        ok("schema_version: non-zero after requests");
    }

    return 0;
}

/// Structural row-equality against expected {id, name, score} fields.
fn rowEq(row: Row, id: u32, name: []const u8, score: u32) bool {
    return row[0] == id and std.mem.eql(u8, row[1], name) and row[2] == score;
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

/// `fail` rendering the actual row that mismatched.
fn failRow(name: []const u8, row: Row) u8 {
    return failFmt(name, "got {{{d},{s},{d}}}", .{ row[0], row[1], row[2] });
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
