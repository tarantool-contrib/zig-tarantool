//! Integration coverage for tuple construction (`Tuple.new`), `bsize`, the
//! `FieldIterator` cursor, and `proc.returnTuple`. Procs build tuples in-process
//! and either return them (inspected as a Lua tuple) or return scalar results
//! decoded from iteration (inspected as plain values).

const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const tuple = t.tuple;
const update = t.update;

// Caller-owned region adoption: each proc opens its own `region.Savepoint`
// and passes `t.region.allocator()` to `Tuple.new`/`Tuple.update`. The scratch
// lives strictly inside that savepoint scope; the savepoint is restored at
// function exit, after `returnTuple`/`returnValue` have run (defer order), so the
// host has copied the bytes and the built tuple is host-ref'd.

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// tup_make() -> a freshly built tuple {7, "hi", 42} returned via returnTuple.
export fn tup_make(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 7), "hi", @as(i64, 42) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();
    return proc.returnTuple(ctx, tup);
}

/// tup_bsize() -> the bsize of {1,2,3}.
export fn tup_bsize(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 1), @as(i64, 2), @as(i64, 3) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();
    return proc.returnValue(ctx, @as(i64, @intCast(tup.bsize())));
}

/// tup_iter_count() -> number of fields walked by FieldIterator.next over
/// {10,20,30,40}.
export fn tup_iter_count(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 10), @as(i64, 20), @as(i64, 30), @as(i64, 40) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();

    var it = tup.fieldIterator() catch return fail("iter");
    defer it.deinit();

    var n: i64 = 0;
    while (it.next(t.region.allocator()) catch return fail("next")) |_| {
        n += 1;
    }
    return proc.returnValue(ctx, n);
}

/// tup_iter_sum() -> sum of all integer fields of {10,20,30,40} via next.
export fn tup_iter_sum(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 10), @as(i64, 20), @as(i64, 30), @as(i64, 40) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();

    var it = tup.fieldIterator() catch return fail("iter");
    defer it.deinit();

    var sum: i64 = 0;
    while (it.next(t.region.allocator()) catch return fail("next")) |v| {
        sum += switch (v) {
            .uint => |u| @as(i64, @intCast(u)),
            .int => |i| i,
            else => return fail("not int"),
        };
    }
    return proc.returnValue(ctx, sum);
}

/// tup_iter_seek() -> field 2 (0-based) of {10,20,30,40} via seek (= 30).
export fn tup_iter_seek(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 10), @as(i64, 20), @as(i64, 30), @as(i64, 40) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();

    var it = tup.fieldIterator() catch return fail("iter");
    defer it.deinit();

    const v = (it.seek(2, t.region.allocator()) catch return fail("seek")) orelse return fail("no field");
    const got: i64 = switch (v) {
        .uint => |u| @as(i64, @intCast(u)),
        .int => |i| i,
        else => return fail("not int"),
    };
    return proc.returnValue(ctx, got);
}

/// tup_iter_position() -> the position after one next, then a rewind, then one
/// next again, encoded as pos_after_two_then_rewind_one. We assert a fixed
/// derived value: after rewind+next position must be 1, returned as that 1.
export fn tup_iter_rewind(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var tup = tuple.Tuple.new(.{ @as(i64, 10), @as(i64, 20), @as(i64, 30), @as(i64, 40) }, t.region.allocator()) catch return fail("new");
    defer tup.deinit();

    var it = tup.fieldIterator() catch return fail("iter");
    defer it.deinit();

    // Walk two fields: position should be 2.
    _ = (it.next(t.region.allocator()) catch return fail("next")) orelse return fail("empty");
    _ = (it.next(t.region.allocator()) catch return fail("next")) orelse return fail("empty");
    if (it.position() != 2) return fail("position!=2");

    // Rewind to the start: position should be 0.
    it.rewind();
    if (it.position() != 0) return fail("position!=0");

    // One more next: position should advance to 1.
    _ = (it.next(t.region.allocator()) catch return fail("next")) orelse return fail("empty");
    return proc.returnValue(ctx, @as(i64, @intCast(it.position())));
}

/// tup_update_new() -> the FIRST field of the NEW tuple produced by applying
/// `update.set(1, 99)` to {7, "hi", 42}. Pins the 1-based base: field `1`
/// targets the first field, so this must be 99.
export fn tup_update_new(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var orig = tuple.Tuple.new(.{ @as(i64, 7), "hi", @as(i64, 42) }, t.region.allocator()) catch return fail("new");
    defer orig.deinit();

    var upd = orig.update(.{update.set(1, @as(i64, 99))}, t.region.allocator()) catch return fail("update");
    defer upd.deinit();

    const v = (upd.field(0, t.region.allocator()) catch return fail("field")) orelse return fail("no field");
    const got: i64 = switch (v) {
        .uint => |u| @as(i64, @intCast(u)),
        .int => |i| i,
        else => return fail("not int"),
    };
    return proc.returnValue(ctx, got);
}

/// tup_update_orig() -> the FIRST field of the ORIGINAL tuple AFTER applying
/// `update.set(1, 99)`. `update` returns a new tuple and leaves the original
/// untouched, so this must still be 7.
export fn tup_update_orig(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var orig = tuple.Tuple.new(.{ @as(i64, 7), "hi", @as(i64, 42) }, t.region.allocator()) catch return fail("new");
    defer orig.deinit();

    var upd = orig.update(.{update.set(1, @as(i64, 99))}, t.region.allocator()) catch return fail("update");
    defer upd.deinit();

    const v = (orig.field(0, t.region.allocator()) catch return fail("field")) orelse return fail("no field");
    const got: i64 = switch (v) {
        .uint => |u| @as(i64, @intCast(u)),
        .int => |i| i,
        else => return fail("not int"),
    };
    return proc.returnValue(ctx, got);
}

/// tup_update_returns() -> the whole NEW tuple after `update.set(2, "yo")` on
/// {7, "hi", 42}, returned for full-shape inspection from Lua. Field 2
/// (1-based) is the SECOND field, so the result is {7, "yo", 42}.
export fn tup_update_returns(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var svp = t.region.Savepoint.save();
    defer svp.restore();
    var orig = tuple.Tuple.new(.{ @as(i64, 7), "hi", @as(i64, 42) }, t.region.allocator()) catch return fail("new");
    defer orig.deinit();

    var upd = orig.update(.{update.set(2, "yo")}, t.region.allocator()) catch return fail("update");
    defer upd.deinit();

    return proc.returnTuple(ctx, upd);
}
