//! Integration coverage for `box.Index.range`/`top` + `box.Range(Row)` — the
//! typed, auto-freeing index cursor.
//! Host-bound, so
//! this driver IS the behavioral coverage: a full typed scan + per-row `free`,
//! an offset/limit window, a descending `top`, and the
//! copy-out-outlives-the-tuple lifetime guarantee. Each proc returns
//! an i64; failure → `setErr` + -1.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;

const alloc = std.heap.c_allocator;

// Declaration order == space format: id (unsigned), name (string), score (integer).
const Row = struct { id: u64, name: []const u8, score: i64 };

fn setErr(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// rng_scan_sum() -> sum of every row's score via a full `.all` range scan, each
/// row freed as the cursor advances.
export fn rng_scan_sum(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.range(Row, .{ .iterator = .all }, .{}, alloc) catch return setErr("range");
    defer cur.deinit();

    var sum: i64 = 0;
    while (cur.next() catch return setErr("next")) |r| {
        sum += r.score;
        box.Range(Row).free(r, alloc);
    }
    return proc.returnValue(ctx, sum);
}

/// rng_limit_offset() -> checksum of a 2-row window starting at offset 1 over the
/// primary key (ids 1..5). Skips id 1, yields ids 2 and 3; asserts exactly that
/// window and returns id2*100 + id3.
export fn rng_limit_offset(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.range(Row, .{ .iterator = .all, .offset = 1, .limit = 2 }, .{}, alloc) catch return setErr("range");
    defer cur.deinit();

    var ids: [2]u64 = undefined;
    var count: usize = 0;
    while (cur.next() catch return setErr("next")) |r| {
        defer box.Range(Row).free(r, alloc);
        if (count >= 2) return setErr("limit exceeded");
        ids[count] = r.id;
        count += 1;
    }
    if (count != 2) return setErr("expected exactly 2 rows");
    if (ids[0] != 2 or ids[1] != 3) return setErr("offset/limit window wrong");

    return proc.returnValue(ctx, @as(i64, @intCast(ids[0] * 100 + ids[1])));
}

/// rng_top() -> 1. `top(2, ..)` over the `by_score` secondary index returns the
/// two highest scorers in descending order; asserts the names and order.
export fn rng_top(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const by_score = rng.index("by_score") catch return setErr("no index by_score");

    const rows = by_score.top(2, Row, alloc) catch return setErr("top");
    defer box.Range(Row).freeSlice(rows, alloc);

    if (rows.len != 2) return setErr("top should return 2 rows");
    // Seed scores: zoe=50, max=40, ann=30, ... so descending = zoe, max.
    if (rows[0].score < rows[1].score) return setErr("top not descending");
    if (!std.mem.eql(u8, rows[0].name, "zoe")) return setErr("top[0] not zoe");
    if (!std.mem.eql(u8, rows[1].name, "max")) return setErr("top[1] not max");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// rng_copyout() -> 1. Read the first row's `[]const u8` name, advance the cursor
/// several more `next()`s (freeing each), THEN assert the first name is still
/// intact — proving the dupe outlives the freed host tuples.
export fn rng_copyout(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.range(Row, .{ .iterator = .all }, .{}, alloc) catch return setErr("range");
    defer cur.deinit();

    const first = (cur.next() catch return setErr("next")) orelse return setErr("no first row");
    defer box.Range(Row).free(first, alloc);
    const expected = "alice"; // id 1's name (seeded first by pk order)
    if (!std.mem.eql(u8, first.name, expected)) return setErr("first name wrong");

    // Drain several more rows, freeing each — this releases their host tuples.
    var advanced: usize = 0;
    while (cur.next() catch return setErr("next")) |r| {
        box.Range(Row).free(r, alloc);
        advanced += 1;
    }
    if (advanced == 0) return setErr("expected more rows to advance past");

    // The first row's name must still be intact: it was duped, not borrowed.
    if (!std.mem.eql(u8, first.name, expected)) return setErr("first name corrupted after advancing");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// cur_scan_sum() -> 150. A raw `box.Cursor` full scan over the pk, summing the
/// score field, with NO per-tuple `deinit` — the cursor frees each tuple as it
/// advances.
export fn cur_scan_sum(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.cursor(.{ .iterator = .all }, .{}) catch return setErr("cursor");
    defer cur.deinit();

    var sum: i64 = 0;
    while (cur.next() catch return setErr("next")) |tup| {
        const score = (tup.get(2, i64, alloc) catch return setErr("get score")) orelse return setErr("no score");
        sum += score;
    }
    return proc.returnValue(ctx, sum);
}

/// cur_offset_limit() -> 203. A raw cursor with offset 1 + limit 2 over the pk
/// yields exactly ids 2 and 3.
export fn cur_offset_limit(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.cursor(.{ .iterator = .all, .offset = 1, .limit = 2 }, .{}) catch return setErr("cursor");
    defer cur.deinit();

    var ids: [2]u64 = undefined;
    var count: usize = 0;
    while (cur.next() catch return setErr("next")) |tup| {
        if (count >= 2) return setErr("limit exceeded");
        ids[count] = (tup.get(0, u64, alloc) catch return setErr("get id")) orelse return setErr("no id");
        count += 1;
    }
    if (count != 2) return setErr("expected exactly 2 rows");
    if (ids[0] != 2 or ids[1] != 3) return setErr("offset/limit window wrong");

    return proc.returnValue(ctx, @as(i64, @intCast(ids[0] * 100 + ids[1])));
}

/// cur_copyout() -> 1. `Tuple.get` BORROWS the tuple buffer, so to keep a name
/// past the advance we `dupe` it out; advancing then frees the host tuple
/// the borrow pointed at, and the duped copy must still be intact.
export fn cur_copyout(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const rng = box.Space.byName("rng") catch return setErr("no space rng");
    const pk = rng.primary();

    var cur = pk.cursor(.{ .iterator = .all }, .{}) catch return setErr("cursor");
    defer cur.deinit();

    const first = (cur.next() catch return setErr("next")) orelse return setErr("no first row");
    const borrowed = (first.get(1, []const u8, alloc) catch return setErr("get name")) orelse return setErr("no name");
    const name = alloc.dupe(u8, borrowed) catch return setErr("dupe");
    defer alloc.free(name);
    const expected = "alice"; // id 1's name (seeded first by pk order)
    if (!std.mem.eql(u8, name, expected)) return setErr("first name wrong");

    // Advance to end: each next() frees the previously-yielded tuple (including
    // `first`), so `borrowed` would now dangle — but `name` is an owned copy.
    var advanced: usize = 0;
    while (cur.next() catch return setErr("next")) |_| advanced += 1;
    if (advanced == 0) return setErr("expected more rows to advance past");

    if (!std.mem.eql(u8, name, expected)) return setErr("duped name corrupted after advancing");

    return proc.returnValue(ctx, @as(i64, 1));
}
