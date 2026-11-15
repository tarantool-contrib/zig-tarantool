//! Integration coverage for Index/Space update + upsert over the update-ops
//! module. Space `t` has fields (id unsigned, n integer, s string) plus an
//! untyped trailing field, a primary index on id. Created from Lua.
//!
//! Procs exercise every operator in both forms — the comptime
//! tuple-of-constructors and the runtime `Ops` builder — plus upsert in its
//! insert and update modes, a type-mismatched `+` (surfaced as a -1 → Lua
//! error), negative field addressing and insert/delete bounds.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const box = t.box;
const proc = t.proc;
const err = t.err;
const msgpack = t.msgpack;
const update = t.update;

const alloc = std.heap.c_allocator;

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

fn space() !box.Space {
    return box.Space.byName("t");
}

/// A msgpack integer `Value` may decode as `.uint` (non-negative) or `.int`
/// (negative); normalize both to i64.
fn asInt(v: msgpack.Value) !i64 {
    return switch (v) {
        .uint => |u| @intCast(u),
        .int => |i| i,
        else => error.NotAnInt,
    };
}

/// up_set_comptime(id, v) -> n field after `= n v` via the comptime form.
/// Field 1 is `n` (0-based).
export fn up_set_comptime(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.update(.{a[0]}, .{update.set(1, a[1])}) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    const n = (row.field(1, alloc) catch return fail("field")) orelse return fail("no field");
    return proc.returnValue(ctx, asInt(n) catch return fail("not int"));
}

/// up_arith(id, op, v) -> n field after applying an arithmetic op via the Ops
/// builder. op: 0=+ 1=- 2=& 3=| 4=^
export fn up_arith(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(3, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");

    var ops = update.Ops.init(alloc);
    defer ops.deinit();
    switch (a[1]) {
        0 => ops.push(update.add(1, a[2])) catch return fail("push"),
        1 => ops.push(update.sub(1, a[2])) catch return fail("push"),
        2 => ops.push(update.band(1, a[2])) catch return fail("push"),
        3 => ops.push(update.bor(1, a[2])) catch return fail("push"),
        4 => ops.push(update.bxor(1, a[2])) catch return fail("push"),
        else => return fail("bad op"),
    }

    const row = (s.update(.{a[0]}, &ops) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    const n = (row.field(1, alloc) catch return fail("field")) orelse return fail("no field");
    return proc.returnValue(ctx, asInt(n) catch return fail("not int"));
}

/// up_splice(id) -> the spliced `s` field. Replaces 3 chars at offset 0 of `s`
/// (field 2) with "XYZ" via the comptime form.
export fn up_splice(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.update(.{a[0]}, .{update.splice(2, 0, 3, "XYZ")}) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    const v = (row.field(2, alloc) catch return fail("field")) orelse return fail("no field");
    return proc.returnValue(ctx, v.str);
}

/// up_insert_field(id) -> field count after `! 4 <"INS">` (insert a 5th field).
export fn up_insert_field(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.update(.{a[0]}, .{update.insert(4, "INS")}) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    return proc.returnValue(ctx, @as(i64, @intCast(row.fieldCount())));
}

/// up_delete_field(id, count) -> field count after deleting `count` fields at
/// field 3 (the last data field) via the Ops builder.
export fn up_delete_field(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    var ops = update.Ops.init(alloc);
    defer ops.deinit();
    ops.push(update.delete(3, @intCast(a[1]))) catch return fail("push");
    const row = (s.update(.{a[0]}, &ops) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    return proc.returnValue(ctx, @as(i64, @intCast(row.fieldCount())));
}

/// up_type_mismatch(id) -> never returns a value: `+ 2 1` on a string field
/// must surface as a host error (-1 → Lua error).
export fn up_type_mismatch(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = ctx;
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    // Field 2 is the string `s`; `+` on it must fail in the host.
    const row = (s.update(.{a[0]}, .{update.add(2, @as(i64, 1))}) catch return fail("expected type error")) orelse
        return fail("no row");
    row.deinit();
    return fail("expected type error but update succeeded");
}

/// up_neg_field(id, v) -> last field after `= -1 v` (negative addressing).
/// -1 targets the last field of the tuple.
export fn up_neg_field(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.update(.{a[0]}, .{update.set(-1, a[1])}) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    const last = row.fieldCount() - 1;
    const v = (row.field(last, alloc) catch return fail("field")) orelse return fail("no field");
    return proc.returnValue(ctx, asInt(v) catch return fail("not int"));
}

/// up_insert_oob(id) -> field count after `! 9 <"X">`. Tarantool pads with nulls
/// rather than erroring on an out-of-range insert: the tuple grows to
/// field 9 + 1 = 10 fields.
export fn up_insert_oob(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.update(.{a[0]}, .{update.insert(9, "X")}) catch return fail("update")) orelse return fail("no row");
    defer row.deinit();
    return proc.returnValue(ctx, @as(i64, @intCast(row.fieldCount())));
}

/// up_delete_oob(id, field, count) -> 1 iff deleting a format-required field
/// surfaces a host error (only format-violating deletes error; deletes
/// past the tuple end are silent no-ops).
export fn up_delete_oob(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(3, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    var ops = update.Ops.init(alloc);
    defer ops.deinit();
    ops.push(update.delete(a[1], @intCast(a[2]))) catch return fail("push");
    if (s.update(.{a[0]}, &ops)) |maybe| {
        if (maybe) |row| row.deinit();
        return fail("expected format-violation error");
    } else |e| {
        if (e == box.Error.BoxOp) return proc.returnValue(ctx, @as(i64, 1));
        return fail("wrong error");
    }
}

/// up_neg_oob(id) -> 1 iff `= -9 <99>` (past the front of the tuple) surfaces a
/// host error (negative field numbers address from the end and error when
/// they fall before field 0).
export fn up_neg_oob(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    if (s.update(.{a[0]}, .{update.set(-9, @as(i64, 99))})) |maybe| {
        if (maybe) |row| row.deinit();
        return fail("expected out-of-range negative field error");
    } else |e| {
        if (e == box.Error.BoxOp) return proc.returnValue(ctx, @as(i64, 1));
        return fail("wrong error");
    }
}

/// up_upsert_insert(id, n) -> 1. Upsert with no existing key inserts the tuple.
/// upsert returns null; success is signalled by 1.
export fn up_upsert_insert(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = s.upsert(.{ a[0], a[1], "u", "v" }, .{update.add(1, @as(i64, 100))}) catch return fail("upsert");
    if (row) |r| {
        r.deinit();
        return fail("upsert returned a tuple");
    }
    return proc.returnValue(ctx, @as(i64, 1));
}

/// up_upsert_update(id, delta) -> 1. Upsert on an existing key applies the ops.
export fn up_upsert_update(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(2, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = s.upsert(.{ a[0], @as(i64, 0), "u", "v" }, .{update.add(1, a[1])}) catch return fail("upsert");
    if (row) |r| {
        r.deinit();
        return fail("upsert returned a tuple");
    }
    return proc.returnValue(ctx, @as(i64, 1));
}

/// read_n(id) -> the `n` field of the row (helper to observe upsert effects).
export fn read_n(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const a = argN(1, args, args_end) catch return fail("args");
    const s = space() catch return fail("no space");
    const row = (s.get(.{a[0]}) catch return fail("get")) orelse return fail("no row");
    defer row.deinit();
    const n = (row.field(1, alloc) catch return fail("field")) orelse return fail("no field");
    return proc.returnValue(ctx, asInt(n) catch return fail("not int"));
}
