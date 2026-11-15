//! Integration coverage for Index/Iterator/select and the BOX_ID_NIL fix.
//! Space `t` has fields (id unsigned, sec unsigned), a primary index on id and a
//! non-unique secondary tree index `sec` on the sec field. Created from Lua.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const box = t.box;
const proc = t.proc;
const err = t.err;
const msgpack = t.msgpack;

const alloc = std.heap.c_allocator;
const Row = struct { i64, i64 }; // [id, sec]

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Decode the proc's argument array into N integers.
fn argN(comptime N: usize, args: [*c]const u8, args_end: [*c]const u8) ![N]i64 {
    const blen = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..blen]);
    return msgpack.decode([N]i64, &dec);
}

fn secIndex() !box.Index {
    const space = try box.Space.byName("t");
    return space.index("sec");
}

/// idx_len() -> number of tuples in the primary index.
export fn idx_len(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const space = box.Space.byName("t") catch return fail("no space");
    const n = space.primary().len() catch return fail("len");
    return proc.returnValue(ctx, @as(i64, @intCast(n)));
}

/// idx_count(iter_code, key) -> count under the given iterator on the sec index.
export fn idx_count(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const idx = secIndex() catch return fail("no index");
    const n = idx.count(@fromBackingInt(@intCast(@as(c_int, @intCast(a[0])))), .{a[1]}) catch return fail("count");
    return proc.returnValue(ctx, @as(i64, @intCast(n)));
}

/// idx_sum_ge(threshold) -> sum of ids over rows with sec >= threshold (GE scan).
export fn idx_sum_ge(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const idx = secIndex() catch return fail("no index");
    var it = idx.iterator(.ge, .{a[0]}) catch return fail("iter");
    defer it.deinit();
    var sum: i64 = 0;
    while (it.next() catch return fail("next")) |row| {
        defer row.deinit();
        const r = row.decode(Row, alloc) catch return fail("decode");
        sum += r[0];
    }
    return proc.returnValue(ctx, sum);
}

/// idx_first(iter_code, key) -> the sec value of the first tuple under the iterator.
export fn idx_first(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const idx = secIndex() catch return fail("no index");
    var it = idx.iterator(@fromBackingInt(@intCast(@as(c_int, @intCast(a[0])))), .{a[1]}) catch return fail("iter");
    defer it.deinit();
    const row = (it.next() catch return fail("next")) orelse return fail("empty");
    defer row.deinit();
    const r = row.decode(Row, alloc) catch return fail("decode");
    return proc.returnValue(ctx, r[1]);
}

/// idx_min() / idx_max() -> the sec value at the index extremes.
export fn idx_min(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const idx = secIndex() catch return fail("no index");
    const row = (idx.min(.{}) catch return fail("min")) orelse return fail("empty");
    defer row.deinit();
    const r = row.decode(Row, alloc) catch return fail("decode");
    return proc.returnValue(ctx, r[1]);
}

export fn idx_max(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const idx = secIndex() catch return fail("no index");
    const row = (idx.max(.{}) catch return fail("max")) orelse return fail("empty");
    defer row.deinit();
    const r = row.decode(Row, alloc) catch return fail("decode");
    return proc.returnValue(ctx, r[1]);
}

/// idx_select(offset, limit) -> number of tuples collected from a GE-from-0 scan.
export fn idx_select(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const idx = secIndex() catch return fail("no index");
    const rows = idx.select(
        .{ .iterator = .ge, .offset = @intCast(a[0]), .limit = @intCast(a[1]) },
        .{@as(i64, 0)},
        alloc,
    ) catch return fail("select");
    defer {
        for (rows) |row| row.deinit();
        alloc.free(rows);
    }
    return proc.returnValue(ctx, @as(i64, @intCast(rows.len)));
}

/// idx_random() -> 1 if a random tuple was returned.
export fn idx_random(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const idx = secIndex() catch return fail("no index");
    const row = (idx.random(7) catch return fail("random")) orelse return fail("empty");
    row.deinit();
    return proc.returnValue(ctx, @as(i64, 1));
}

/// idx_missing_space() -> 1 iff resolving a missing space yields NoSuchSpace.
export fn idx_missing_space(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    if (box.Space.byName("does_not_exist")) |_| {
        return fail("expected NoSuchSpace");
    } else |e| {
        if (e == box.Error.NoSuchSpace) return proc.returnValue(ctx, @as(i64, 1));
        return fail("wrong error");
    }
}

/// idx_by_id() -> number of tuples in the secondary index (id 1), looked up by numeric id.
export fn idx_by_id(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const space = box.Space.byName("t") catch return fail("no space");
    const idx = space.indexById(1);
    const n = idx.len() catch return fail("len");
    return proc.returnValue(ctx, @as(i64, @intCast(n)));
}

/// idx_bsize() -> memory footprint of the secondary index in bytes.
export fn idx_bsize(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const idx = secIndex() catch return fail("no index");
    const n = idx.bsize() catch return fail("bsize");
    return proc.returnValue(ctx, @as(i64, @intCast(n)));
}

/// idx_missing_index() -> 1 iff resolving a missing index yields NoSuchIndex.
export fn idx_missing_index(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const space = box.Space.byName("t") catch return fail("no space");
    if (space.index("nope")) |_| {
        return fail("expected NoSuchIndex");
    } else |e| {
        if (e == box.Error.NoSuchIndex) return proc.returnValue(ctx, @as(i64, 1));
        return fail("wrong error");
    }
}
