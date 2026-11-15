//! Unit tests for the pure update-op module. No Tarantool dependency.
const std = @import("std");
const testing = std.testing;
const tarantool = @import("tarantool");
const msgpack = tarantool.msgpack;
const update = tarantool.update;

const a = testing.allocator;

/// Encode `value` into a fresh buffer; caller frees.
fn enc(value: anytype) !msgpack.Buffer {
    var buf = msgpack.Buffer.init(a);
    errdefer buf.deinit();
    try msgpack.encode(&buf, value);
    return buf;
}

/// Assert that encoding `value` yields exactly `bytes`.
fn expectBytes(value: anytype, bytes: []const u8) !void {
    var buf = try enc(value);
    defer buf.deinit();
    try testing.expectEqualSlices(u8, bytes, buf.items());
}

// ---- operator strings match Tarantool ----

test "Operator.str matches Tarantool operator chars" {
    try testing.expectEqualStrings("=", update.Operator.set.str());
    try testing.expectEqualStrings("!", update.Operator.insert.str());
    try testing.expectEqualStrings("+", update.Operator.add.str());
    try testing.expectEqualStrings("-", update.Operator.sub.str());
    try testing.expectEqualStrings("&", update.Operator.band.str());
    try testing.expectEqualStrings("|", update.Operator.bor.str());
    try testing.expectEqualStrings("^", update.Operator.bxor.str());
    try testing.expectEqualStrings("#", update.Operator.delete.str());
    try testing.expectEqualStrings(":", update.Operator.splice.str());
}

// ---- constructors encode to the right op arrays ----

test "set encodes to [\"=\", 1, \"x\"]" {
    // fixarray(3), fixstr "=", fixint 1, fixstr "x"
    try expectBytes(update.set(1, "x"), &.{ 0x93, 0xa1, '=', 0x01, 0xa1, 'x' });
}

test "delete encodes to a 3-element array" {
    // fixarray(3), fixstr "#", fixint 2, fixint 3
    try expectBytes(update.delete(2, 3), &.{ 0x93, 0xa1, '#', 0x02, 0x03 });
}

test "splice encodes to a 5-element array" {
    // fixarray(5), fixstr ":", field 1, start 0, len 2, replacement "ab"
    try expectBytes(update.splice(1, 0, 2, "ab"), &.{ 0x95, 0xa1, ':', 0x01, 0x00, 0x02, 0xa2, 'a', 'b' });
}

// ---- runtime Ops builder matches the comptime tuple form ----

test "Ops with two pushes equals the comptime tuple-of-constructors" {
    var ops = update.Ops.init(a);
    defer ops.deinit();
    try ops.push(update.set(1, "x"));
    try ops.push(update.add(2, @as(i64, 5)));
    try testing.expectEqual(@as(u32, 2), ops.count);

    var dyn = try ops.toBuffer(a);
    defer dyn.deinit();

    var cmp = try enc(.{ update.set(1, "x"), update.add(2, @as(i64, 5)) });
    defer cmp.deinit();

    try testing.expectEqualSlices(u8, cmp.items(), dyn.items());
    // sanity: a 2-element array-of-arrays
    try testing.expectEqual(@as(u8, 0x92), dyn.items()[0]);
}

// ---- encodeOps: single path for both op forms (IF1) ----

test "encodeOps accepts an *Ops builder" {
    var ops = update.Ops.init(a);
    defer ops.deinit();
    try ops.push(update.set(1, "x"));

    var buf = try update.encodeOps(a, &ops);
    defer buf.deinit();

    var direct = try ops.toBuffer(a);
    defer direct.deinit();
    try testing.expectEqualSlices(u8, direct.items(), buf.items());
}

test "encodeOps accepts a comptime tuple of constructors" {
    var buf = try update.encodeOps(a, .{ update.set(1, "x"), update.delete(2, 1) });
    defer buf.deinit();

    var cmp = try enc(.{ update.set(1, "x"), update.delete(2, 1) });
    defer cmp.deinit();
    try testing.expectEqualSlices(u8, cmp.items(), buf.items());
}
