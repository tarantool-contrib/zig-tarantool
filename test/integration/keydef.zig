//! Integration coverage for the `key_def` module: building a
//! `KeyDef` over `{fieldno,type}` parts, extracting a MessagePack key from a
//! tuple (`KeyDef.extractKey` and `Index.extractKey`), and the three orderings
//! produced by `compare` / `compareWithKey`. The Lua driver (`keydef.lua`)
//! asserts the extracted key bytes (decoded as a Lua table), the -1/0/1
//! orderings, and that a repeated build/extract/deinit loop stays correct
//! (`KeyDef.deinit` frees, nothing leaks — extracted bytes are owned
//! copies, no region pointer escapes).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const tuple = t.tuple;
const keydef = t.keydef;
const box = t.box;

const KeyDef = keydef.KeyDef;
const KeyPartDef = keydef.KeyPartDef;

// Scratch allocator for the test procs. `c_allocator` is caller-owned: the
// extracted key bytes live in it across the `box_return_mp` call and are freed
// afterwards. `extractKey`/`compareWithKey` take their own `region.Savepoint`
// internally, so passing the C allocator here does not leak region memory.
const alloc = std.heap.c_allocator;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// kd_extract() -> the MessagePack key extracted from {7,"abc",5} by a KeyDef
/// over parts {fieldno=0,type=.unsigned},{fieldno=1,type=.string}. The bytes
/// ARE a valid MessagePack array [7,"abc"], returned straight via
/// `box_return_mp` so Lua sees a table {7,"abc"}.
export fn kd_extract(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var tup = tuple.Tuple.new(.{ @as(u64, 7), "abc", @as(u64, 5) }, alloc) catch return fail("new");
    defer tup.deinit();

    const parts = [_]KeyPartDef{
        .{ .fieldno = 0, .type = .unsigned },
        .{ .fieldno = 1, .type = .string },
    };
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const key = kd.extractKey(tup, alloc) catch return fail("extract");
    defer alloc.free(key);

    return c.box_return_mp(ctx.?, key.ptr, key.ptr + key.len);
}

/// kd_compare() -> the order of {1,"a"} vs {2,"b"} by a KeyDef on field 0
/// (.unsigned), mapped to -1/0/1. 1 < 2 → .lt → -1.
export fn kd_compare(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var a = tuple.Tuple.new(.{ @as(u64, 1), "a" }, alloc) catch return fail("new a");
    defer a.deinit();
    var b = tuple.Tuple.new(.{ @as(u64, 2), "b" }, alloc) catch return fail("new b");
    defer b.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compare(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// kd_compare_eq() -> the order of {5,"x"} vs {5,"y"} by a KeyDef on field 0
/// (.unsigned). Equal keys → .eq → 0.
export fn kd_compare_eq(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var a = tuple.Tuple.new(.{ @as(u64, 5), "x" }, alloc) catch return fail("new a");
    defer a.deinit();
    var b = tuple.Tuple.new(.{ @as(u64, 5), "y" }, alloc) catch return fail("new b");
    defer b.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compare(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// kd_compare_gt() -> the order of {9} vs {3} by a KeyDef on field 0
/// (.unsigned). 9 > 3 → .gt → 1.
export fn kd_compare_gt(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var a = tuple.Tuple.new(.{@as(u64, 9)}, alloc) catch return fail("new a");
    defer a.deinit();
    var b = tuple.Tuple.new(.{@as(u64, 3)}, alloc) catch return fail("new b");
    defer b.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compare(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// kd_compare_key() -> the order of tuple {5,"x"} against key {5} by a KeyDef
/// on field 0 (.unsigned). Equal → .eq → 0.
export fn kd_compare_key(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var tup = tuple.Tuple.new(.{ @as(u64, 5), "x" }, alloc) catch return fail("new");
    defer tup.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compareWithKey(tup, .{@as(u64, 5)}, alloc) catch return fail("compareWithKey")) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// kd_compare_key_lt() -> the order of tuple {5} against key {8} by a KeyDef on
/// field 0 (.unsigned). 5 < 8 → .lt → -1.
export fn kd_compare_key_lt(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var tup = tuple.Tuple.new(.{@as(u64, 5)}, alloc) catch return fail("new");
    defer tup.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compareWithKey(tup, .{@as(u64, 8)}, alloc) catch return fail("compareWithKey")) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// kd_compare_key_gt() -> the order of tuple {8} against key {5} by a KeyDef on
/// field 0 (.unsigned). 8 > 5 → .gt → 1.
export fn kd_compare_key_gt(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var tup = tuple.Tuple.new(.{@as(u64, 8)}, alloc) catch return fail("new");
    defer tup.deinit();

    const parts = [_]KeyPartDef{.{ .fieldno = 0, .type = .unsigned }};
    var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
    defer kd.deinit();

    const ord: i64 = switch (kd.compareWithKey(tup, .{@as(u64, 5)}, alloc) catch return fail("compareWithKey")) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return proc.returnValue(ctx, ord);
}

/// idx_extract() -> the primary key extracted from the row {42,"v"} of space
/// "kd" (pk on field 1) by the index's own key_def. The bytes are the
/// MessagePack key [42], returned via `box_return_mp` so Lua sees {42}.
export fn idx_extract(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var s = box.Space.byName("kd") catch return fail("byName");
    const tup = (s.get(.{@as(u64, 42)}) catch return fail("get")) orelse return fail("no row");

    const key = s.primary().extractKey(tup, alloc) catch return fail("extract");
    defer alloc.free(key);

    return c.box_return_mp(ctx.?, key.ptr, key.ptr + key.len);
}

/// kd_repeat() -> 1 after building+extracting+deinit'ing a KeyDef N times in a
/// loop. Each iteration frees the extracted bytes and the
/// key_def, so memory stays bounded under repetition.
export fn kd_repeat(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const parts = [_]KeyPartDef{
        .{ .fieldno = 0, .type = .unsigned },
        .{ .fieldno = 1, .type = .string },
    };
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var tup = tuple.Tuple.new(.{ @as(u64, 7), "abc", @as(u64, 5) }, alloc) catch return fail("new");
        defer tup.deinit();
        var kd = KeyDef.init(&parts, alloc) catch return fail("keydef");
        defer kd.deinit();
        const key = kd.extractKey(tup, alloc) catch return fail("extract");
        alloc.free(key);
    }
    return proc.returnValue(ctx, @as(i64, 1));
}
