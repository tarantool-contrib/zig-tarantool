//! Live harness exe for the pipelined `Batch` surface (src/client/batch.zig):
//! build N request frames, `execute()` (one flush + read-all-N matched by sync),
//! and read per-handle results from the batch's arena. Standalone binary —
//! importing `tarantool-client` and LINKING with no `box_*` symbols is the
//! module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, and drives the fixture space `batch_kv` (created by the
//! luatest `batch` group's before_all: format {id unsigned, name string, score
//! unsigned}, primary tree on id, non-unique secondary tree `by_score`, plus the
//! stored function `batch_add`). Prints TAP-ish lines (`ok - <name>` / `not ok -
//! <name> (<detail>)`), exits 1 on the FIRST failing check, 0 once every check
//! passed — the luatest driver asserts the exit code and surfaces the captured
//! TAP text on failure.
//!
//! WITHIN-BATCH ORDERING (observed, commented at the call sites): the server
//! reads a batch's frames off one connection in arrival order and memtx runs each
//! request to completion serially, so a request sees the effects of every EARLIER
//! request in the SAME batch — a `get` after an `insert` reads the inserted row;
//! a `select` BEFORE an `update` reads the pre-update tuple. The batch read loop
//! never assumes reply ORDER (matches by sync), but the server's PROCESSING order
//! is the frames' arrival order.
//!
//! The checks use disjoint key ranges and drop what they create, so the case is
//! rerunnable even without the group's before_each truncate.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");

const Connection = client.Connection;

/// Positional tuple mirroring the `batch_kv` format: {id, name, score}. A tuple
/// struct encodes/decodes as an MP_ARRAY, matching how the server stores rows.
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

/// The full check sequence over an established connection. Returns 0 iff every
/// check passed, else 1 (after the first failing check printed its `not ok` line).
fn run(conn: *Connection) u8 {
    const kv = conn.space("batch_kv");
    const gpa = conn.gpa;

    // ---- 1. MIXED batch (>= 8 requests) ------------------------------------
    //
    // Arrival order is server processing order (see the module doc): insert(1),
    // insert(2), get(1), select(ge 1), update(2), upsert(3), call, eval, ping.
    // The `get` therefore reads insert(1)'s row (same batch); the `select` runs
    // BEFORE update(2), so it reads id 2's PRE-update score (20), while the
    // update handle echoes the POST-update score (25). Both are asserted.
    var b1 = conn.batch(gpa);
    defer b1.deinit(); // kept alive across later conn traffic for the arena check.

    const h_ins1 = b1.insert(kv, .{ @as(u32, 1), @as([]const u8, "alice"), @as(u32, 10) }) catch |e|
        return fail("b1.insert {1,alice,10}", @errorName(e));
    const h_ins2 = b1.insert(kv, .{ @as(u32, 2), @as([]const u8, "bob"), @as(u32, 20) }) catch |e|
        return fail("b1.insert {2,bob,20}", @errorName(e));
    // get of a row inserted EARLIER in this same batch — sees it (serial memtx TX).
    const h_get = b1.get(kv, .{@as(u32, 1)}) catch |e|
        return fail("b1.get {1}", @errorName(e));
    // GE on the primary index from key {1}: returns ids >= 1 present at this point
    // in the batch (1 and 2; the upsert of id 3 is LATER, so not seen).
    const h_sel = b1.select(kv, .{@as(u32, 1)}, .{ .iterator = .ge }) catch |e|
        return fail("b1.select ge {1}", @errorName(e));
    // add 5 to field 2 (score, 0-based) of id 2: 20 -> 25. Reply echoes the tuple.
    const h_upd = b1.update(kv, .{@as(u32, 2)}, .{proto.update.add(2, @as(u32, 5))}) catch |e|
        return fail("b1.update {2} +5", @errorName(e));
    // upsert id 3 (absent -> inserted as the tuple; ops apply only on PK conflict).
    const h_ups = b1.upsert(kv, .{ @as(u32, 3), @as([]const u8, "carol"), @as(u32, 30) }, .{proto.update.add(2, @as(u32, 1))}) catch |e|
        return fail("b1.upsert {3,carol,30}", @errorName(e));
    const h_call = b1.call("batch_add", .{ @as(i64, 3), @as(i64, 4) }) catch |e|
        return fail("b1.call batch_add(3,4)", @errorName(e));
    const h_eval = b1.eval("return 1 + 1", .{}) catch |e|
        return fail("b1.eval 1+1", @errorName(e));
    const h_ping = b1.ping() catch |e|
        return fail("b1.ping", @errorName(e));

    b1.execute() catch |e| return fail("b1.execute", @errorName(e));

    {
        const got = b1.decodeOne(h_ins1, Row) catch |e| return fail("b1 insert1 decode", @errorName(e));
        if (!rowEq(got, 1, "alice", 10)) return failRow("b1 insert1 echoes {1,alice,10}", got);
        ok("batch1: insert {1,alice,10} echo");
    }
    {
        const got = b1.decodeOne(h_ins2, Row) catch |e| return fail("b1 insert2 decode", @errorName(e));
        if (!rowEq(got, 2, "bob", 20)) return failRow("b1 insert2 echoes {2,bob,20}", got);
        ok("batch1: insert {2,bob,20} echo");
    }
    {
        // get sees insert(1) from EARLIER in the same batch — the ordering truth.
        const got = (b1.decodeMaybe(h_get, Row) catch |e| return fail("b1 get decode", @errorName(e))) orelse
            return fail("b1 get {1}", "expected the batched-insert row, got null");
        if (!rowEq(got, 1, "alice", 10)) return failRow("b1 get {1} -> {1,alice,10}", got);
        ok("batch1: get {1} sees same-batch insert (serial memtx ordering)");
    }
    {
        const rows = b1.decodeMany(h_sel, gpa, Row) catch |e| return fail("b1 select decode", @errorName(e));
        defer gpa.free(rows);
        if (rows.len != 2) return failFmt("b1 select ge {1} -> 2 rows", "got {d} rows", .{rows.len});
        if (!rowEq(rows[0], 1, "alice", 10)) return failRow("b1 select row0 {1,alice,10}", rows[0]);
        // Read BEFORE the update handle: id 2 still has its pre-update score (20).
        if (!rowEq(rows[1], 2, "bob", 20)) return failRow("b1 select row1 {2,bob,20} (pre-update)", rows[1]);
        ok("batch1: select ge {1} -> [{1,alice,10},{2,bob,20}] (pre-update snapshot)");
    }
    {
        const got = (b1.decodeMaybe(h_upd, Row) catch |e| return fail("b1 update decode", @errorName(e))) orelse
            return fail("b1 update {2}", "expected the updated row, got null");
        // POST-update score: the update ran AFTER the select in the same batch.
        if (!rowEq(got, 2, "bob", 25)) return failRow("b1 update {2} -> {2,bob,25}", got);
        ok("batch1: update {2} +5 -> {2,bob,25} (post-update echo)");
    }
    {
        b1.expectOk(h_ups) catch |e| return fail("b1 upsert expectOk", @errorName(e));
        ok("batch1: upsert {3,carol,30} ok");
    }
    {
        const sum = b1.decodeOne(h_call, i64) catch |e| return fail("b1 call decode", @errorName(e));
        if (sum != 7) return failFmt("b1 call batch_add(3,4) -> 7", "got {d}", .{sum});
        ok("batch1: call batch_add(3,4) -> 7");
    }
    {
        const two = b1.decodeOne(h_eval, i64) catch |e| return fail("b1 eval decode", @errorName(e));
        if (two != 2) return failFmt("b1 eval 1+1 -> 2", "got {d}", .{two});
        ok("batch1: eval 'return 1+1' -> 2");
    }
    {
        b1.expectOk(h_ping) catch |e| return fail("b1 ping expectOk", @errorName(e));
        ok("batch1: ping ok");
    }
    // Verify the upsert's insert landed, via a NORMAL (non-batch) request.
    {
        const got = (kv.get(.{@as(u32, 3)}, Row) catch |e| return fail("verify upsert get {3}", @errorName(e))) orelse
            return fail("verify upsert get {3}", "expected {3,carol,30}, got null");
        if (!rowEq(got, 3, "carol", 30)) return failRow("verify upsert -> {3,carol,30}", got);
        ok("batch1: upsert insert verified via conn get {3}");
    }

    // ---- 2. MID-BATCH server error (dup PK), siblings still succeed --------
    //
    // insert(5) then insert(5) again in ONE batch: the second is ER_TUPLE_FOUND,
    // parked in ITS slot only; the surrounding ping + get succeed (per-slot
    // error channels, not the connection's single last_error).
    {
        var b2 = conn.batch(gpa);
        defer b2.deinit();
        const e_a = b2.insert(kv, .{ @as(u32, 5), @as([]const u8, "erin"), @as(u32, 50) }) catch |e|
            return fail("b2.insert {5,erin,50}", @errorName(e));
        const e_dup = b2.insert(kv, .{ @as(u32, 5), @as([]const u8, "dup"), @as(u32, 51) }) catch |e|
            return fail("b2.insert dup {5}", @errorName(e));
        const e_ping = b2.ping() catch |e| return fail("b2.ping", @errorName(e));
        const e_get = b2.get(kv, .{@as(u32, 5)}) catch |e| return fail("b2.get {5}", @errorName(e));

        b2.execute() catch |e| return fail("b2.execute", @errorName(e));

        // Sibling before the error: ok.
        {
            const got = b2.decodeOne(e_a, Row) catch |e| return fail("b2 insert1 decode", @errorName(e));
            if (!rowEq(got, 5, "erin", 50)) return failRow("b2 insert1 echoes {5,erin,50}", got);
        }
        // The error slot: dataRaw -> error.ServerError, serverError has code + msg.
        if (b2.dataRaw(e_dup)) |_| {
            return fail("b2 dup slot -> ServerError", "dataRaw unexpectedly returned OK");
        } else |e| switch (e) {
            error.ServerError => {},
            else => return fail("b2 dup slot -> ServerError", @errorName(e)),
        }
        const se = b2.serverError(e_dup) orelse
            return fail("b2 dup slot serverError", "serverError(h) is null on a parked error");
        if (se.code == 0) return fail("b2 dup slot code", "server error code is 0");
        if (std.mem.indexOf(u8, se.message, "Duplicate key") == null)
            return failFmt("b2 dup slot message names it", "message '{s}' lacks 'Duplicate key'", .{se.message});
        // Siblings AFTER the error: unaffected.
        b2.expectOk(e_ping) catch |e| return fail("b2 ping after error", @errorName(e));
        {
            const got = (b2.decodeMaybe(e_get, Row) catch |e| return fail("b2 get after error", @errorName(e))) orelse
                return fail("b2 get {5}", "expected {5,erin,50}, got null");
            if (!rowEq(got, 5, "erin", 50)) return failRow("b2 get {5} -> {5,erin,50}", got);
        }
        ok("batch2: mid-batch dup PK -> per-slot ServerError; siblings ok");
    }

    // ---- 3. ARENA lifetime: b1's results outlive later conn traffic --
    //
    // b1 is still alive (deferred deinit). Run unrelated NORMAL requests (they
    // reuse the connection's resp_buf — the batch's staging area), then re-read
    // b1's results: still valid because each was COPIED into b1's arena.
    {
        conn.ping() catch |e| return fail("post-batch conn.ping", @errorName(e));
        _ = kv.get(.{@as(u32, 2)}, Row) catch |e| return fail("post-batch conn.get {2}", @errorName(e));

        const again = b1.decodeOne(h_ins1, Row) catch |e| return fail("b1 re-read insert1", @errorName(e));
        if (!rowEq(again, 1, "alice", 10)) return failRow("b1 re-read insert1 after conn traffic", again);
        const two = b1.decodeOne(h_eval, i64) catch |e| return fail("b1 re-read eval", @errorName(e));
        if (two != 2) return failFmt("b1 re-read eval == 2", "got {d}", .{two});
        ok("arena: b1 results still valid after later conn ping+get");
    }

    // ---- 4. DRIFT interaction: a DDL eval inside a batch marks schema stale -
    //
    // Fetch a schema FIRST (so the drift mark has a cached version to compare
    // against). A batch whose eval runs DDL (create batch_throwaway) bumps the
    // server's schema_version; the reply header applies through the batch read
    // loop and marks the connection stale. schema() then refetches.
    {
        _ = conn.schema() catch |e| return fail("drift: initial schema()", @errorName(e));
        if (conn.schema_stale) return fail("drift: fresh schema not stale", "schema_stale true right after fetch");

        var b3 = conn.batch(gpa);
        defer b3.deinit();
        const h_pre = b3.ping() catch |e| return fail("b3.ping", @errorName(e));
        const h_ddl = b3.eval(
            "if box.space.batch_throwaway then box.space.batch_throwaway:drop() end " ++
                "box.schema.space.create('batch_throwaway') return true",
            .{},
        ) catch |e| return fail("b3.eval DDL", @errorName(e));
        b3.execute() catch |e| return fail("b3.execute", @errorName(e));
        b3.expectOk(h_pre) catch |e| return fail("b3 ping ok", @errorName(e));
        b3.expectOk(h_ddl) catch |e| return fail("b3 DDL ok", @errorName(e));

        if (!conn.schema_stale) return fail("drift: DDL batch marks stale", "schema_stale still false after DDL");
        _ = conn.schema() catch |e| return fail("drift: schema() refetch", @errorName(e));
        if (conn.schema_stale) return fail("drift: refetch clears stale", "schema_stale still true after schema()");
        ok("drift: DDL eval in a batch marks schema stale; schema() refetches");

        // Rerunnable: drop the throwaway space and refresh — clean slate.
        _ = conn.eval("box.space.batch_throwaway:drop() return true", .{}, bool) catch |e|
            return fail("drift: drop throwaway", @errorName(e));
        conn.refreshSchema() catch |e| return fail("drift: refreshSchema", @errorName(e));
        ok("drift: throwaway dropped + schema refreshed (rerunnable)");
    }

    // ---- 5. EMPTY batch: execute is a no-op success ------------------------
    // ---- 6. POST-execute add -> error.BatchConsumed -----------------------
    {
        var b_empty = conn.batch(gpa);
        defer b_empty.deinit();
        b_empty.execute() catch |e| return fail("empty batch execute", @errorName(e));
        ok("empty: execute on zero adds is a no-op success");

        // Consumed: an adder and a second execute after execute are rejected.
        if (b_empty.ping()) |_| {
            return fail("post-execute add rejected", "ping after execute unexpectedly succeeded");
        } else |e| switch (e) {
            error.BatchConsumed => {},
            else => return fail("post-execute add -> BatchConsumed", @errorName(e)),
        }
        if (b_empty.execute()) |_| {
            return fail("second execute rejected", "second execute unexpectedly succeeded");
        } else |e| switch (e) {
            error.BatchConsumed => {},
            else => return fail("second execute -> BatchConsumed", @errorName(e)),
        }
        ok("consumed: post-execute add and re-execute -> error.BatchConsumed");
    }

    // ---- 7. Connection fully usable after all of the above -----------------
    {
        const sum = conn.call("batch_add", .{ @as(i64, 10), @as(i64, 20) }, i64) catch |e|
            return fail("final conn.call usable", @errorName(e));
        if (sum != 30) return failFmt("final conn.call batch_add(10,20) -> 30", "got {d}", .{sum});
        const got = (kv.get(.{@as(u32, 1)}, Row) catch |e| return fail("final conn.get {1}", @errorName(e))) orelse
            return fail("final conn.get {1}", "expected {1,alice,10}, got null");
        if (!rowEq(got, 1, "alice", 10)) return failRow("final conn.get {1} -> {1,alice,10}", got);
        ok("usable: connection fully usable after batches (typed call + get)");
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
