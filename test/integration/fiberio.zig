//! The self-connect deadlock-freedom proof for `tarantool.fiberio`.
//! A stored proc runs in a fiber ON the TX thread; if the
//! in-process client's network waits BLOCKED that thread, the server could never
//! serve the client's own connection back to this instance — the round-trip
//! would deadlock. So a proc that connects to its own listener over
//! `tarantool.fiberio.io()` and completes a full round-trip IS the yield proof:
//! success means the waits parked the fiber (via coio) and let the server make
//! progress. A connect TIMEOUT (a few seconds, never `.none`) turns any
//! regression into a fast, legible failure instead of a hang; luatest's own
//! per-test timeout is the outer backstop.
//!
//! Two procs, both taking the listener URI as an argument (no discovery —
//! the luatest group binds the ephemeral TCP listener in before_all and passes
//! its URI in):
//!   - `fiberio_selftest(uri)`: connect (tester/secret) → ping → insert+get on
//!     the fixture space `fiberio_kv` {id unsigned, v string} → typed eval 1+1 →
//!     close. Returns the string "ok" iff every check passed; any failure sets a
//!     box error under ER_PROC_C naming the failed step (so the Lua `:call`
//!     raises and luatest surfaces which check broke).
//!   - `fiberio_deadport(uri)`: connect to a dead port and EXPECT failure within
//!     the timeout. Returns "ok" iff the connect errored (a hang would trip the
//!     luatest timeout; an unexpected success is a loud failure).
//!
//! This module imports `tarantool-client` and drives it over the SDK's `fiberio`
//! backend — the build wires both into every integration `.so` (build.zig
//! `soFromZig`). Nothing here is host-`box_*`-bound beyond the proc ABI itself.

const std = @import("std");
const t = @import("tarantool");
const client = @import("tarantool-client");

const c = t.c;
const proc = t.proc;
const err = t.err;
const msgpack = t.msgpack;

const Connection = client.Connection;

const gpa = std.heap.c_allocator;

/// A few-seconds connect timeout — NOT `.none`. A blocking-regression must fail
/// fast, never hang the TX thread. `.awake` (monotonic) is the natural clock for
/// a relative connect deadline.
const connect_timeout: std.Io.Timeout = .{
    .duration = .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake },
};

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Decode the proc's single string argument (the listener URI) out of the
/// msgpack MP_ARRAY. Borrows the caller's arg bytes (valid for the call).
fn firstStringArg(args: [*c]const u8, args_end: [*c]const u8, comptime what: []const u8) ?[]const u8 {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const v = dec.decodeValue(gpa) catch return null;
    defer msgpack.freeValue(gpa, v);
    if (v != .array or v.array.len != 1) return null;
    // The URI must outlive `freeValue`, so hand back a c_allocator copy the
    // caller frees. A null return means "bad args" — the caller fails loudly.
    _ = what;
    const s = switch (v.array[0]) {
        .str => |s| s,
        else => return null,
    };
    return gpa.dupe(u8, s) catch null;
}

/// Positional tuple mirroring `fiberio_kv`'s format {id unsigned, v string}. A
/// tuple struct encodes/decodes as an MP_ARRAY — how the server stores the row.
const Row = struct { u64, []const u8 };

export fn fiberio_selftest(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const uri = firstStringArg(args, args_end, "selftest") orelse return fail("selftest: expected 1 string arg (uri)");
    defer gpa.free(uri);

    const io = t.fiberio.io();

    var conn = Connection.connect(gpa, io, .{
        .address = uri,
        .user = "tester",
        .password = "secret",
        .timeout = connect_timeout,
    }) catch return fail("selftest: connect (a blocking backend would deadlock the TX thread here)");
    defer conn.close();

    // 1. ping — a full request/response round-trip over the fiber-yielding waits.
    conn.ping() catch return fail("selftest: ping");

    // 2. insert then get on the fixture space; the echo and read-back must match.
    const kv = conn.space("fiberio_kv");
    const inserted = kv.insert(.{ @as(u64, 1), @as([]const u8, "hello") }, Row) catch
        return fail("selftest: insert {1,hello}");
    if (inserted[0] != 1 or !std.mem.eql(u8, inserted[1], "hello")) return fail("selftest: insert echo mismatch");

    const got = (kv.get(.{@as(u64, 1)}, Row) catch return fail("selftest: get {1}")) orelse
        return fail("selftest: get {1} returned nil");
    if (got[0] != 1 or !std.mem.eql(u8, got[1], "hello")) return fail("selftest: get read-back mismatch");

    // 3. typed eval — a value round-trip decoded into a Zig scalar.
    const sum = conn.eval("return 1 + 1", .{}, i64) catch return fail("selftest: eval 1+1");
    if (sum != 2) return fail("selftest: eval 1+1 != 2");

    return proc.returnValue(ctx, @as([]const u8, "ok"));
}

export fn fiberio_deadport(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const uri = firstStringArg(args, args_end, "deadport") orelse return fail("deadport: expected 1 string arg (uri)");
    defer gpa.free(uri);

    const io = t.fiberio.io();

    // Connecting to a dead port MUST fail (loopback refuses fast; the timeout
    // caps any slower path) — a hang would trip luatest's timeout. Any error is
    // the expected outcome; a SUCCESSFUL connect is the loud failure.
    if (Connection.connect(gpa, io, .{
        .address = uri,
        .user = "tester",
        .password = "secret",
        .timeout = connect_timeout,
    })) |conn_val| {
        var conn = conn_val;
        conn.close();
        return fail("deadport: expected connect failure, but connected");
    } else |_| {
        return proc.returnValue(ctx, @as([]const u8, "ok"));
    }
}
