//! Harness exe: the DML MATRIX — the systematic coverage the smoke
//! exe (`dml.zig`) leaves out. Same standalone shape (imports `tarantool-client`,
//! links with no `box_*` symbols — the module-purity proof),
//! same TAP-ish output + first-failure-exit contract, same env wiring. Driven by
//! the luatest `dml` group's `test_dml_matrix` case against the fixture space
//! `dml_users` (format {id unsigned, name string, score unsigned}, primary tree
//! on id, NON-UNIQUE secondary tree `by_score` on score). Assumes before_each
//! truncated the space; SEEDS its own six rows (scores contain duplicates so the
//! non-unique-index MoreThanOne / all-matches cases are reachable).
//!
//! What it pins that the smoke exe does not:
//!   * select iterator matrix on the primary: GE tail, LE descending head, ALL
//!     with offset+limit (the exact middle slice), EQ miss -> empty (len 0);
//!   * update-op parity: set+add typed echo, splice post-state via get, missing
//!     key -> null; upsert as-insert then as-update;
//!   * Index reads on `by_score`: select over a duplicated score -> all matches,
//!     get over a duplicated score -> MoreThanOne, get unique -> the row, get
//!     absent -> null;
//!   * borrowed-lifetime discipline: copy-before-next-request survives;
//!   * schema_version stability: no DDL here, so it never moves.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");

const Connection = client.Connection;
const query = proto.query;
const update = proto.update;

/// Positional tuple mirroring the `dml_users` format: {id, name, score}.
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

    return run(&conn, gpa);
}

/// The seed rows. Scores 20 and 30 each appear twice (duplicates for the
/// non-unique `by_score` cases); 10 and 99 are unique.
const seed = [_]Row{
    .{ 1, "u1", 10 },
    .{ 2, "u2", 20 },
    .{ 3, "u3", 20 },
    .{ 4, "u4", 30 },
    .{ 5, "u5", 30 },
    .{ 6, "u6", 99 },
};

fn run(conn: *Connection, gpa: std.mem.Allocator) u8 {
    const users = conn.space("dml_users");

    // Seed the fixture (before_each truncated it). Discard the echoed tuples.
    for (seed) |r| {
        users.insert(.{ r[0], r[1], r[2] }, void) catch |e|
            return failFmt("seed insert id", "id {d}: {s}", .{ r[0], @errorName(e) });
    }
    // Capture schema_version now that requests have flowed; no DDL follows, so it
    // must stay pinned to this value through every remaining request.
    const sv0 = conn.schema_version;
    if (sv0 == 0) return fail("schema_version seeded", "still 0 after seed inserts");
    ok("seed: six rows inserted, schema_version captured");

    // ---- select iterator matrix on the PRIMARY index ----------------------

    // GE {3} unbounded -> the ordered tail 3,4,5,6 (ascending).
    {
        const rows = users.select(gpa, .{@as(u32, 3)}, .{ .iterator = .ge }, Row) catch |e|
            return fail("select GE {3}", @errorName(e));
        defer gpa.free(rows);
        if (!idsEq(rows, &.{ 3, 4, 5, 6 })) return failIds("select GE {3} -> [3,4,5,6]", rows);
        ok("select: GE {3} unbounded -> [3,4,5,6] ascending tail");
    }

    // LE {3} -> descending head 3,2,1 (LE/LT iterate descending, IteratorType).
    {
        const rows = users.select(gpa, .{@as(u32, 3)}, .{ .iterator = .le }, Row) catch |e|
            return fail("select LE {3}", @errorName(e));
        defer gpa.free(rows);
        if (!idsEq(rows, &.{ 3, 2, 1 })) return failIds("select LE {3} -> [3,2,1]", rows);
        ok("select: LE {3} -> [3,2,1] descending head");
    }

    // ALL offset=2 limit=2 -> the exact middle slice 3,4 (ascending, skip 1,2).
    // ALL ignores the key, so an empty key tuple is the natural form.
    {
        const rows = users.select(gpa, .{}, .{ .iterator = .all, .offset = 2, .limit = 2 }, Row) catch |e|
            return fail("select ALL off=2 lim=2", @errorName(e));
        defer gpa.free(rows);
        if (!idsEq(rows, &.{ 3, 4 })) return failIds("select ALL off=2 lim=2 -> [3,4]", rows);
        ok("select: ALL offset=2 limit=2 -> [3,4] middle slice");
    }

    // EQ miss -> empty slice (len 0), NOT an error.
    {
        const rows = users.select(gpa, .{@as(u32, 999)}, .{ .iterator = .eq }, Row) catch |e|
            return fail("select EQ {999} miss", @errorName(e));
        defer gpa.free(rows);
        if (rows.len != 0) return failFmt("select EQ {999} -> empty", "got {d} rows", .{rows.len});
        ok("select: EQ {999} miss -> empty slice (len 0)");
    }

    // ---- Index reads on the non-unique `by_score` secondary ---------------

    const by_score = users.index("by_score");

    // select over the duplicated score 20 -> both matching rows (ids 2 and 3).
    {
        const rows = by_score.select(gpa, .{@as(u32, 20)}, .{ .iterator = .eq }, Row) catch |e|
            return fail("by_score select {20}", @errorName(e));
        defer gpa.free(rows);
        if (rows.len != 2 or !hasId(rows, 2) or !hasId(rows, 3))
            return failIds("by_score select {20} -> {2,3}", rows);
        ok("index: by_score select {20} -> both duplicates {2,3}");
    }

    // get over the duplicated score 20 -> MoreThanOne (never silently drop).
    {
        if (by_score.get(.{@as(u32, 20)}, Row)) |_| {
            return fail("by_score get {20} -> MoreThanOne", "get unexpectedly returned a value");
        } else |e| switch (e) {
            error.MoreThanOne => {},
            else => return fail("by_score get {20} -> MoreThanOne", @errorName(e)),
        }
        ok("index: by_score get {20} (2 matches) -> error.MoreThanOne");
    }

    // get over a UNIQUE score 99 -> the single row (id 6).
    {
        const got = (by_score.get(.{@as(u32, 99)}, Row) catch |e|
            return fail("by_score get {99}", @errorName(e))) orelse
            return fail("by_score get {99}", "expected a row, got null");
        if (!rowEq(got, 6, "u6", 99)) return failRow("by_score get {99} -> {6,u6,99}", got);
        ok("index: by_score get {99} (unique) -> {6,u6,99}");
    }

    // get over an ABSENT score 77 -> null.
    {
        const got = by_score.get(.{@as(u32, 77)}, Row) catch |e|
            return fail("by_score get {77}", @errorName(e));
        if (got != null) return fail("by_score get {77} -> null", "expected null for absent score");
        ok("index: by_score get {77} absent -> null");
    }

    // ---- borrowed-lifetime discipline (copy before next request) -----
    {
        const rows = users.select(gpa, .{@as(u32, 3)}, .{ .iterator = .eq }, Row) catch |e|
            return fail("rk2 select {3}", @errorName(e));
        defer gpa.free(rows);
        if (rows.len != 1) return failFmt("rk2 select {3}", "expected 1 row, got {d}", .{rows.len});
        // Copy the borrowed name OUT of resp_buf before the next request stomps it.
        var namebuf: [64]u8 = undefined;
        const borrowed = rows[0][1];
        @memcpy(namebuf[0..borrowed.len], borrowed);
        const copy = namebuf[0..borrowed.len];
        // Any request reuses resp_buf and invalidates `borrowed` (rows[0][1]).
        _ = users.get(.{@as(u32, 6)}, Row) catch |e|
            return fail("rk2 intervening get {6}", @errorName(e));
        if (!std.mem.eql(u8, copy, "u3"))
            return failFmt("rk2 copy survives next request", "copy is '{s}', expected 'u3'", .{copy});
        ok("rk2: copied name survives an intervening request");
    }

    // ---- update-op parity -------------------------------------------------

    // set + add on id 1: name -> "U1", score 10 + 5 = 15. Typed echo verified.
    {
        const got = (users.update(
            .{@as(u32, 1)},
            .{ update.set(1, @as([]const u8, "U1")), update.add(2, @as(i64, 5)) },
            Row,
        ) catch |e| return fail("update set+add {1}", @errorName(e))) orelse
            return fail("update set+add {1}", "expected the updated row, got null");
        if (!rowEq(got, 1, "U1", 15)) return failRow("update set+add {1} -> {1,U1,15}", got);
        ok("update: set(name)+add(score) {1} -> {1,U1,15} typed echo");
    }

    // splice on id 2's name (field 1): insert "z-" at position 0, cut 0 chars ->
    // "z-u2". Assert the post-state via a fresh get.
    {
        _ = users.update(
            .{@as(u32, 2)},
            .{update.splice(1, 0, 0, "z-")},
            void,
        ) catch |e| return fail("update splice {2}", @errorName(e));
        const got = (users.get(.{@as(u32, 2)}, Row) catch |e|
            return fail("get {2} after splice", @errorName(e))) orelse
            return fail("get {2} after splice", "expected a row, got null");
        if (!rowEq(got, 2, "z-u2", 20)) return failRow("splice {2} -> {2,z-u2,20}", got);
        ok("update: splice(name) {2} -> {2,z-u2,20} via get");
    }

    // update a missing key -> null (UPDATE affects zero or one tuple).
    {
        const got = users.update(
            .{@as(u32, 999)},
            .{update.set(1, @as([]const u8, "nope"))},
            Row,
        ) catch |e| return fail("update missing {999}", @errorName(e));
        if (got != null) return fail("update missing {999} -> null", "expected null for a missing key");
        ok("update: missing key {999} -> null");
    }

    // ---- upsert path ------------------------------------------------------

    // upsert-as-INSERT: id 7 absent, so the tuple is inserted; the ops are not
    // applied. Verify {7,u7,70} via get.
    {
        users.upsert(
            .{ @as(u32, 7), @as([]const u8, "u7"), @as(u32, 70) },
            .{update.add(2, @as(i64, 1))},
        ) catch |e| return fail("upsert-as-insert {7}", @errorName(e));
        const got = (users.get(.{@as(u32, 7)}, Row) catch |e|
            return fail("get {7} after upsert-insert", @errorName(e))) orelse
            return fail("get {7} after upsert-insert", "expected a row, got null");
        if (!rowEq(got, 7, "u7", 70)) return failRow("upsert-as-insert {7} -> {7,u7,70}", got);
        ok("upsert: as-insert {7} -> {7,u7,70}");
    }

    // upsert-as-UPDATE: id 7 now exists, so the tuple is ignored and the ops
    // apply: score 70 + 1 = 71, name unchanged. Verify via get.
    {
        users.upsert(
            .{ @as(u32, 7), @as([]const u8, "ignored"), @as(u32, 0) },
            .{update.add(2, @as(i64, 1))},
        ) catch |e| return fail("upsert-as-update {7}", @errorName(e));
        const got = (users.get(.{@as(u32, 7)}, Row) catch |e|
            return fail("get {7} after upsert-update", @errorName(e))) orelse
            return fail("get {7} after upsert-update", "expected a row, got null");
        if (!rowEq(got, 7, "u7", 71)) return failRow("upsert-as-update {7} -> {7,u7,71}", got);
        ok("upsert: as-update {7} -> {7,u7,71} (ops applied, tuple ignored)");
    }

    // ---- schema_version stability ----------------------------------------
    {
        if (conn.schema_version != sv0)
            return failFmt("schema_version stable", "moved {d} -> {d} with no DDL", .{ sv0, conn.schema_version });
        ok("schema_version: constant (no DDL) across the whole matrix");
    }

    return 0;
}

/// True iff `rows` decode to exactly the expected ids, in order.
fn idsEq(rows: []const Row, expected: []const u32) bool {
    if (rows.len != expected.len) return false;
    for (rows, expected) |row, id| if (row[0] != id) return false;
    return true;
}

/// True iff some row in `rows` has the given id (order-independent membership).
fn hasId(rows: []const Row, id: u32) bool {
    for (rows) |row| if (row[0] == id) return true;
    return false;
}

/// Structural row-equality against expected {id, name, score}.
fn rowEq(row: Row, id: u32, name: []const u8, score: u32) bool {
    return row[0] == id and std.mem.eql(u8, row[1], name) and row[2] == score;
}

fn ok(name: []const u8) void {
    std.debug.print("ok - {s}\n", .{name});
}

fn fail(name: []const u8, detail: []const u8) u8 {
    std.debug.print("not ok - {s} ({s})\n", .{ name, detail });
    return 1;
}

fn failFmt(name: []const u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "detail too long to format";
    return fail(name, detail);
}

fn failRow(name: []const u8, row: Row) u8 {
    return failFmt(name, "got {{{d},{s},{d}}}", .{ row[0], row[1], row[2] });
}

/// `fail` rendering the actual id sequence a select returned.
fn failIds(name: []const u8, rows: []const Row) u8 {
    var buf: [128]u8 = undefined;
    var w: usize = 0;
    for (rows, 0..) |row, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const s = std.fmt.bufPrint(buf[w..], "{s}{d}", .{ sep, row[0] }) catch break;
        w += s.len;
    }
    return failFmt(name, "got ids [{s}] (len {d})", .{ buf[0..w], rows.len });
}

fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
