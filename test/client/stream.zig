//! Harness exe: exercise the live `tarantool-client` STREAM surface
//! (interactive transactions — Stream.open/begin/commit/rollback + stream-scoped
//! space DML) against the server the luatest `stream` group starts. Standalone
//! binary importing `tarantool-client` and LINKING with no `box_*` symbols — the
//! module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, and drives the fixture space `stream_kv` {id unsigned, v
//! string} (pk on id) created by the luatest group's before_all. That group runs
//! with `memtx_use_mvcc_engine = true` so an open stream transaction's uncommitted
//! writes are INVISIBLE to plain (autocommit) reads on the same connection — the
//! isolation the checks below assert. Prints TAP-ish lines (`ok - …` / `not ok -
//! … (<detail>)`); exits 1 on the FIRST failing check, 0 once every check passed.
//!
//! The checks delete/rollback everything they touch, so the case is rerunnable
//! even without a between-runs truncate.

const std = @import("std");
const client = @import("tarantool-client");

const Connection = client.Connection;
const Stream = client.Stream;

/// Positional tuple mirroring `stream_kv`: {id unsigned, v string}.
const Row = struct { u32, []const u8 };

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
    const plain = conn.space("stream_kv");

    // 1. MVCC isolation: open a stream, BEGIN, insert {1} INSIDE the stream. A
    //    plain (autocommit) get {1} on the same connection does NOT see the
    //    uncommitted write; the stream's own get {1} does. ROLLBACK discards it,
    //    so a plain get {1} is null again.
    {
        var s = Stream.open(conn) catch |e| return fail("Stream.open (isolation)", @errorName(e));
        s.begin() catch |e| return fail("stream.begin (isolation)", @errorName(e));

        const sp = s.space("stream_kv");
        _ = sp.insert(.{ @as(u32, 1), @as([]const u8, "a") }, void) catch |e|
            return fail("stream insert {1,a}", @errorName(e));

        // Plain read on the same connection: uncommitted -> invisible under MVCC.
        const plain_before = plain.get(.{@as(u32, 1)}, Row) catch |e|
            return fail("plain get {1} during txn", @errorName(e));
        if (plain_before != null)
            return fail("plain get {1} during txn -> null", "plain read saw the uncommitted insert");
        ok("stream: plain get {1} during open txn -> null (MVCC isolation)");

        // Stream read: the transaction sees its own write.
        const in_txn = (sp.get(.{@as(u32, 1)}, Row) catch |e|
            return fail("stream get {1} during txn", @errorName(e))) orelse
            return fail("stream get {1} during txn", "stream read did not see its own insert");
        if (!rowEq(in_txn, 1, "a")) return failRow("stream get {1} -> {1,a}", in_txn);
        ok("stream: stream get {1} during txn -> {1,a} (own write visible)");

        s.rollback() catch |e| return fail("stream.rollback", @errorName(e));
        const plain_after = plain.get(.{@as(u32, 1)}, Row) catch |e|
            return fail("plain get {1} after rollback", @errorName(e));
        if (plain_after != null)
            return fail("plain get {1} after rollback -> null", "rollback did not discard the write");
        ok("stream: rollback discards the write (plain get {1} -> null)");
    }

    // 2. A second stream: BEGIN, insert {2}, COMMIT. After commit the plain read
    //    sees it. Two sequential streams do not interfere (the first rolled back).
    {
        var s = Stream.open(conn) catch |e| return fail("Stream.open (commit)", @errorName(e));
        s.begin() catch |e| return fail("stream.begin (commit)", @errorName(e));

        const sp = s.space("stream_kv");
        _ = sp.insert(.{ @as(u32, 2), @as([]const u8, "b") }, void) catch |e|
            return fail("stream insert {2,b}", @errorName(e));
        s.commit() catch |e| return fail("stream.commit", @errorName(e));

        const committed = (plain.get(.{@as(u32, 2)}, Row) catch |e|
            return fail("plain get {2} after commit", @errorName(e))) orelse
            return fail("plain get {2} after commit", "commit did not make the write visible");
        if (!rowEq(committed, 2, "b")) return failRow("plain get {2} after commit -> {2,b}", committed);
        ok("stream: second stream commit makes {2,b} visible to plain reads");

        // cleanup so the case is rerunnable.
        _ = plain.delete(.{@as(u32, 2)}, void) catch |e| return fail("cleanup delete {2}", @errorName(e));
    }

    // 3. LIVE TRUTH: COMMIT without a prior BEGIN returns OK on this server
    //    (NOT a ServerError). Assert the no-error outcome and print it.
    {
        var s = Stream.open(conn) catch |e| return fail("Stream.open (commit-no-begin)", @errorName(e));
        s.commit() catch |e| return failFmt("commit without begin", "expected OK, got {s}", .{@errorName(e)});
        ok("stream: COMMIT without a prior BEGIN -> OK (live truth, no ServerError)");
    }

    // 4. The connection is still fully usable after all the stream traffic.
    {
        conn.ping() catch |e| return fail("ping after stream surface", @errorName(e));
        const three = conn.eval("return 1 + 2", .{}, i64) catch |e| return fail("eval 1+2", @errorName(e));
        if (three != 3) return failFmt("eval 1+2", "got {d}, want 3", .{three});
        ok("stream: connection still usable (ping + eval)");
    }

    return 0;
}

/// Structural row-equality against expected {id, v} fields.
fn rowEq(row: Row, id: u32, v: []const u8) bool {
    return row[0] == id and std.mem.eql(u8, row[1], v);
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

/// `fail` with a formatted detail (e.g. an unexpected value).
fn failFmt(name: []const u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "detail too long to format";
    return fail(name, detail);
}

/// `fail` rendering the actual row that mismatched.
fn failRow(name: []const u8, row: Row) u8 {
    return failFmt(name, "got {{{d},{s}}}", .{ row[0], row[1] });
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
