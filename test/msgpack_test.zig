//! Unit tests for the msgpack codec. Pure Zig, no Tarantool dependency.
const std = @import("std");
const testing = std.testing;
const msgpack = @import("tarantool").msgpack;
const ext = msgpack.ext;

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

// ---- fixture vectors (known canonical encodings) ----

test "fixture: positive fixint" {
    try expectBytes(@as(u8, 42), &.{0x2a});
}
test "fixture: negative fixint" {
    try expectBytes(@as(i64, -1), &.{0xff});
}
test "fixture: false / true / nil" {
    try expectBytes(false, &.{0xc2});
    try expectBytes(true, &.{0xc3});
    try expectBytes(@as(?u8, null), &.{0xc0});
}
test "fixture: fixstr" {
    try expectBytes(@as([]const u8, "abc"), &.{ 0xa3, 'a', 'b', 'c' });
}
test "fixture: string literal" {
    try expectBytes("abc", &.{ 0xa3, 'a', 'b', 'c' });
}
test "fixture: tuple struct -> array" {
    try expectBytes(.{ @as(u8, 1), @as(u8, 2), @as(u8, 3) }, &.{ 0x93, 1, 2, 3 });
}
test "fixture: uint8 boundary" {
    try expectBytes(@as(u16, 200), &.{ 0xcc, 200 });
    try expectBytes(@as(u32, 0x1234), &.{ 0xcd, 0x12, 0x34 });
}

// ---- round trips through concrete decode(T) ----

fn roundTrip(comptime T: type, value: T) !void {
    var buf = try enc(value);
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(T, &dec);
    try testing.expectEqual(value, got);
    try testing.expectEqual(buf.items().len, dec.pos); // consumed fully
}

test "roundtrip: unsigned boundaries" {
    for ([_]u64{ 0, 1, 127, 128, 255, 256, 65535, 65536, 0xffffffff, 0x1_0000_0000, std.math.maxInt(u64) }) |v| {
        try roundTrip(u64, v);
    }
}
test "roundtrip: signed boundaries" {
    for ([_]i64{ -1, -32, -33, -128, -129, -32768, -32769, std.math.minInt(i32), std.math.minInt(i64), 0, 127, 1000 }) |v| {
        try roundTrip(i64, v);
    }
}
test "roundtrip: bool / float / optional" {
    try roundTrip(bool, true);
    try roundTrip(bool, false);
    try roundTrip(f64, 3.5);
    try roundTrip(?u32, null);
    try roundTrip(?u32, 7);
}
test "roundtrip: enum" {
    const E = enum(u8) { x = 1, y = 2, z = 200 };
    try roundTrip(E, .z);
}
test "roundtrip: fixed array of non-u8" {
    const arr = [_]u16{ 1, 1000, 65535 };
    var buf = try enc(arr);
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode([3]u16, &dec);
    try testing.expectEqualSlices(u16, &arr, &got);
}

test "roundtrip: []const u8 borrows str" {
    var buf = try enc(@as([]const u8, "hello"));
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode([]const u8, &dec);
    try testing.expectEqualStrings("hello", got);
}

test "Bin newtype -> bin family" {
    const b = msgpack.Bin{ .bytes = &.{ 0xde, 0xad } };
    var buf = try enc(b);
    defer buf.deinit();
    try testing.expectEqualSlices(u8, &.{ 0xc4, 0x02, 0xde, 0xad }, buf.items());
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(msgpack.Bin, &dec);
    try testing.expectEqualSlices(u8, b.bytes, got.bytes);
}

test "tuple struct roundtrip (mixed types)" {
    const Row = struct { u32, []const u8 };
    const row: Row = .{ 7, "ok" };
    var buf = try enc(row);
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(Row, &dec);
    try testing.expectEqual(@as(u32, 7), got[0]);
    try testing.expectEqualStrings("ok", got[1]);
}

test "named struct -> map roundtrip" {
    const P = struct { x: u8, y: i16 };
    const p: P = .{ .x = 3, .y = -1000 };
    var buf = try enc(p);
    defer buf.deinit();
    // map header with 2 entries
    try testing.expectEqual(@as(u8, 0x82), buf.items()[0]);
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(P, &dec);
    try testing.expectEqual(p, got);
}

// ---- positional aggregate codec: encodeArray / decodeArray ----

test "encodeArray: named struct -> array" {
    const P = struct { x: u8, y: u8 };
    const p: P = .{ .x = 1, .y = 2 };
    var buf = msgpack.Buffer.init(a);
    defer buf.deinit();
    try msgpack.encodeArray(&buf, p);
    // positional: same bytes as the equivalent tuple struct .{1, 2}
    try testing.expectEqualSlices(u8, &.{ 0x92, 1, 2 }, buf.items());
}

test "decodeArray: array -> named struct roundtrip" {
    const Row = struct { id: u32, name: []const u8 };
    const row: Row = .{ .id = 7, .name = "ok" };
    var buf = msgpack.Buffer.init(a);
    defer buf.deinit();
    try msgpack.encodeArray(&buf, row);
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decodeArray(Row, &dec);
    try testing.expectEqual(@as(u32, 7), got.id);
    try testing.expectEqualStrings("ok", got.name);
    try testing.expectEqual(buf.items().len, dec.pos); // consumed fully
}

test "decodeArray: arity mismatch" {
    const Row = struct { a: u8, b: u8 };
    // fixarray(3) into a 2-field Row
    var dec = msgpack.Decoder.init(&.{ 0x93, 1, 2, 3 });
    try testing.expectError(error.ArityMismatch, msgpack.decodeArray(Row, &dec));
}

test "decodeArray: per-field type mismatch" {
    const Row = struct { a: u8, b: u8 };
    // fixarray(2): first elem int, second elem a str -> NotInt (no coercion)
    var dec = msgpack.Decoder.init(&.{ 0x92, 1, 0xa1, 'x' });
    try testing.expectError(error.NotInt, msgpack.decodeArray(Row, &dec));
}

// ---- dynamic Value ----

test "dynamic decodeValue covers scalars and containers" {
    var buf = try enc(.{ @as(u8, 1), @as([]const u8, "a"), false });
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    defer msgpack.freeValue(a, v);
    try testing.expect(v == .array);
    try testing.expectEqual(@as(usize, 3), v.array.len);
    try testing.expectEqual(@as(u64, 1), v.array[0].uint);
    try testing.expectEqualStrings("a", v.array[1].str);
    try testing.expectEqual(false, v.array[2].bool);
}

test "decodeValue frees partial array on truncation (no leak)" {
    // fixarray(3) then only one element, then EOF on the second decode.
    var dec = msgpack.Decoder.init(&.{ 0x93, 0x01 });
    try testing.expectError(error.Truncated, dec.decodeValue(a));
    // testing.allocator panics at test end if the partial array slice leaked.
}

test "decodeValue frees partial map on truncation (no leak)" {
    // fixmap(1), key "k" (fixstr), then EOF before the value.
    var dec = msgpack.Decoder.init(&.{ 0x81, 0xa1, 'k' });
    try testing.expectError(error.Truncated, dec.decodeValue(a));
}

// ---- errors: fail fast ----

test "decode error: type mismatch" {
    var buf = try enc(@as([]const u8, "x"));
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    try testing.expectError(error.NotInt, msgpack.decode(u8, &dec));
}
test "decode error: overflow on narrow target" {
    var buf = try enc(@as(u32, 1000));
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    try testing.expectError(error.Overflow, msgpack.decode(u8, &dec));
}
test "decode error: truncated buffer" {
    var dec = msgpack.Decoder.init(&.{0xcc}); // uint8 tag, no payload
    try testing.expectError(error.Truncated, msgpack.decode(u16, &dec));
}
test "decode error: tuple arity mismatch" {
    var buf = try enc(.{ @as(u8, 1), @as(u8, 2) });
    defer buf.deinit();
    const Row = struct { u8, u8, u8 };
    var dec = msgpack.Decoder.init(buf.items());
    try testing.expectError(error.ArityMismatch, msgpack.decode(Row, &dec));
}

// ---- ext types ----

test "ext: uuid round trips and parses" {
    const bytes = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const e = ext.Ext{ .type = @backingInt(ext.Type.uuid), .data = &bytes };
    var buf = try enc(e);
    defer buf.deinit();
    // fixext16 = 0xd8, type byte 0x02, then 16 bytes
    try testing.expectEqual(@as(u8, 0xd8), buf.items()[0]);
    try testing.expectEqual(@as(u8, 0x02), buf.items()[1]);
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const u = try ext.parseUuid(v.ext);
    try testing.expectEqualSlices(u8, &bytes, &u.bytes);
}

test "ext: Uuid struct encodes and round trips" {
    const u = ext.Uuid{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } };
    var buf = try enc(u);
    defer buf.deinit();
    // fixext16 = 0xd8, type byte 0x02, then 16 bytes
    try testing.expectEqual(@as(u8, 0xd8), buf.items()[0]);
    try testing.expectEqual(@as(u8, 0x02), buf.items()[1]);
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const parsed = try ext.parseUuid(v.ext);
    try testing.expectEqualSlices(u8, &u.bytes, &parsed.bytes);
}

test "ext: datetime 8-byte form round trips" {
    const dt = ext.Datetime{ .seconds = 1717459200 };
    var buf = try enc(dt);
    defer buf.deinit();
    // fixext8 = 0xd7, type byte 0x04, then 8 bytes
    try testing.expectEqual(@as(u8, 0xd7), buf.items()[0]);
    try testing.expectEqual(@as(u8, 0x04), buf.items()[1]);
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const parsed = try ext.parseDatetime(v.ext);
    try testing.expectEqual(dt, parsed);
}

test "ext: datetime 16-byte form round trips" {
    const dt = ext.Datetime{
        .seconds = -1717459200,
        .nsec = 123456789,
        .tzoffset = -180,
        .tzindex = 42,
    };
    var buf = try enc(dt);
    defer buf.deinit();
    // ext8 marker for 16-byte payload: fixext16 = 0xd8, type byte 0x04
    try testing.expectEqual(@as(u8, 0xd8), buf.items()[0]);
    try testing.expectEqual(@as(u8, 0x04), buf.items()[1]);
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const parsed = try ext.parseDatetime(v.ext);
    try testing.expectEqual(dt, parsed);
}

// ---- decimal ext ----

/// Parse `s`, format back, and assert the canonical text round trips.
fn expectDecimalText(s: []const u8, expected: []const u8) !void {
    const d = try ext.Decimal.fromString(s);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, d.toString(&buf));
}

/// fromString -> pack -> parseDecimal -> toString must reproduce `expected`.
fn expectDecimalRoundTrip(s: []const u8, expected: []const u8) !void {
    const d = try ext.Decimal.fromString(s);
    var pbuf: [21]u8 = undefined;
    const payload = d.pack(&pbuf);
    const back = try ext.parseDecimal(.{ .type = @backingInt(ext.Type.decimal), .data = payload });
    var tbuf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, back.toString(&tbuf));
}

test "decimal: text round trips (canonical forms)" {
    try expectDecimalText("0", "0");
    try expectDecimalText("-0", "0"); // -0 normalizes to non-negative zero
    try expectDecimalText("123", "123"); // integer, scale 0
    try expectDecimalText("-123", "-123");
    try expectDecimalText("1.5", "1.5");
    try expectDecimalText("1.50", "1.50"); // trailing zero preserved (scale 2)
    try expectDecimalText("0.001", "0.001"); // leading fractional zeros via scale
    try expectDecimalText("-0.001", "-0.001");
}

test "decimal: pack round trips through parseDecimal" {
    try expectDecimalRoundTrip("0", "0");
    try expectDecimalRoundTrip("-0", "0");
    try expectDecimalRoundTrip("123", "123");
    try expectDecimalRoundTrip("-123", "-123");
    try expectDecimalRoundTrip("1.5", "1.5");
    try expectDecimalRoundTrip("1.50", "1.50");
    try expectDecimalRoundTrip("0.001", "0.001");
    try expectDecimalRoundTrip("-0.001", "-0.001");
    // 38 significant digits (max)
    try expectDecimalRoundTrip(
        "12345678901234567890123456789012345678",
        "12345678901234567890123456789012345678",
    );
    try expectDecimalRoundTrip(
        "-1.2345678901234567890123456789012345678",
        "-1.2345678901234567890123456789012345678",
    );
}

test "decimal: worked-example byte layout (1.5)" {
    const d = try ext.Decimal.fromString("1.5");
    var pbuf: [21]u8 = undefined;
    const payload = d.pack(&pbuf);
    // payload = [scale=0x01, 0x01, 0x5C]
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x5c }, payload);
}

test "decimal: encode() emits MP_EXT type 1" {
    const d = try ext.Decimal.fromString("1.5");
    var buf = try enc(d);
    defer buf.deinit();
    // 3-byte payload -> ext8 (0xc7), len 3, type 0x01
    try testing.expectEqual(@as(u8, 0xc7), buf.items()[0]);
    try testing.expectEqual(@as(u8, 0x03), buf.items()[1]);
    try testing.expectEqual(@as(u8, 0x01), buf.items()[2]);
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const back = try ext.parseDecimal(v.ext);
    var tbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("1.5", back.toString(&tbuf));
}

test "decimal: fromString rejects malformed / out of range" {
    try testing.expectError(error.InvalidDecimal, ext.Decimal.fromString(""));
    try testing.expectError(error.InvalidDecimal, ext.Decimal.fromString("12.34.56"));
    try testing.expectError(error.InvalidDecimal, ext.Decimal.fromString("12a"));
    try testing.expectError(error.InvalidDecimal, ext.Decimal.fromString("-"));
    try testing.expectError(error.InvalidDecimal, ext.Decimal.fromString("."));
    // 39 significant digits -> out of range
    try testing.expectError(
        error.DecimalTooLong,
        ext.Decimal.fromString("123456789012345678901234567890123456789"),
    );
}

test "decimal: parseDecimal rejects negative wire scale" {
    // scale byte 0xFF (i8 -1) is a scientific-notation magnitude this codec
    // cannot represent — must error, not trap toString's @intCast.
    const e = ext.Ext{ .type = @backingInt(ext.Type.decimal), .data = &.{ 0xff, 0x1c } };
    try testing.expectError(error.InvalidDecimal, ext.parseDecimal(e));
}

// ---- structural mpEncode/mpDecode codec hook ----

/// Dummy hooked type: encodes as a fixext4 (type byte 42) carrying a
/// big-endian u32. Declares the structural codec pair, so `msgpack.encode`/
/// `decode` must dispatch to these methods rather than the map/tuple path.
const Hooked = struct {
    v: u32,
    const ext_type: i8 = 42;

    pub fn mpEncode(self: Hooked, w: anytype) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, self.v, .big);
        try w.writeByte(0xd6); // fixext4
        try w.writeByte(@bitCast(ext_type));
        try w.writeAll(&payload);
    }

    pub fn mpDecode(dec: *msgpack.Decoder) msgpack.DecodeError!Hooked {
        const e = try msgpack.decode(ext.Ext, dec);
        if (e.type != ext_type or e.data.len != 4) return error.InvalidExt;
        return .{ .v = std.mem.readInt(u32, e.data[0..4], .big) };
    }
};

test "hook: encode dispatches to mpEncode (exact bytes)" {
    try expectBytes(Hooked{ .v = 0x01020304 }, &.{ 0xd6, 42, 0x01, 0x02, 0x03, 0x04 });
}

test "hook: decode dispatches to mpDecode (round trip)" {
    var buf = try enc(Hooked{ .v = 0xdeadbeef });
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(Hooked, &dec);
    try testing.expectEqual(@as(u32, 0xdeadbeef), got.v);
}

test "hook: a struct without the decls still takes the map path" {
    // A plain named struct has neither mpEncode nor mpDecode: it must still
    // encode as a map and round-trip through the generic path.
    const Plain = struct { a: u8, b: u8 };
    var buf = try enc(Plain{ .a = 1, .b = 2 });
    defer buf.deinit();
    // map header (0x82) then two string-keyed entries — NOT a fixext.
    try testing.expectEqual(@as(u8, 0x82), buf.items()[0]);
    var dec = msgpack.Decoder.init(buf.items());
    const got = try msgpack.decode(Plain, &dec);
    try testing.expectEqual(@as(u8, 1), got.a);
    try testing.expectEqual(@as(u8, 2), got.b);
}

test "hook: mpDecode error.InvalidExt propagates" {
    // A fixext4 with the wrong type byte (7, not 42) makes Hooked.mpDecode
    // surface error.InvalidExt, which must propagate through msgpack.decode.
    const bytes = [_]u8{ 0xd6, 7, 0x00, 0x00, 0x00, 0x00 };
    var dec = msgpack.Decoder.init(&bytes);
    try testing.expectError(error.InvalidExt, msgpack.decode(Hooked, &dec));
}

// ---- interval MP_EXT type 6 (probe-pinned wire format) ----

/// pack `iv` into a fresh payload buffer and assert it equals `bytes`.
fn expectIntervalPack(iv: ext.Interval, bytes: []const u8) !void {
    var pbuf: [ext.interval_max_packed_len]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes, iv.pack(&pbuf));
}

/// pack∘parse must reproduce every field of `iv`.
fn expectIntervalRoundTrip(iv: ext.Interval) !void {
    var pbuf: [ext.interval_max_packed_len]u8 = undefined;
    const payload = iv.pack(&pbuf);
    const back = try ext.parseInterval(.{ .type = @backingInt(ext.Type.interval), .data = payload });
    try testing.expectEqual(iv, back);
}

test "interval: pack worked-example payloads" {
    try expectIntervalPack(.{}, &.{ 0x01, 0x08, 0x01 });
    try expectIntervalPack(.{ .adjust = .excess }, &.{0x00});
    try expectIntervalPack(.{ .year = 1 }, &.{ 0x02, 0x00, 0x01, 0x08, 0x01 });
    try expectIntervalPack(.{ .day = -33 }, &.{ 0x02, 0x03, 0xd0, 0xdf, 0x08, 0x01 });
    try expectIntervalPack(
        .{ .sec = 5_000_000_000 },
        &.{ 0x02, 0x06, 0xcf, 0x00, 0x00, 0x00, 0x01, 0x2a, 0x05, 0xf2, 0x00, 0x08, 0x01 },
    );
    // year..nsec = 1..8, adjust = last
    try expectIntervalPack(
        .{ .year = 1, .month = 2, .week = 3, .day = 4, .hour = 5, .min = 6, .sec = 7, .nsec = 8, .adjust = .last },
        &.{ 0x09, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x07, 0x08, 0x08, 0x02 },
    );
}

test "interval: encode() emits MP_EXT type 6 (host-identical bytes)" {
    try expectBytes(ext.Interval{}, &.{ 0xc7, 0x03, 0x06, 0x01, 0x08, 0x01 });
    try expectBytes(ext.Interval{ .sec = 200 }, &.{ 0xc7, 0x06, 0x06, 0x02, 0x06, 0xcc, 0xc8, 0x08, 0x01 });
    try expectBytes(
        ext.Interval{ .sec = -5_000_000_000 },
        &.{ 0xc7, 0x0d, 0x06, 0x02, 0x06, 0xd3, 0xff, 0xff, 0xff, 0xfe, 0xd5, 0xfa, 0x0e, 0x00, 0x08, 0x01 },
    );
    // framing cases: fixext1 / fixext4 / fixext8 (matches encodeExt policy)
    try expectBytes(ext.Interval{ .adjust = .excess }, &.{ 0xd4, 0x06, 0x00 });
    try expectBytes(ext.Interval{ .sec = 200, .adjust = .excess }, &.{ 0xd6, 0x06, 0x01, 0x06, 0xcc, 0xc8 });
    try expectBytes(
        ext.Interval{ .day = 4, .hour = 5, .sec = 200, .adjust = .excess },
        &.{ 0xd7, 0x06, 0x03, 0x03, 0x04, 0x04, 0x05, 0x06, 0xcc, 0xc8 },
    );
}

test "interval: pack round trips through parseInterval" {
    // every field individually, both signs
    inline for (.{ "year", "month", "week", "day", "hour", "min", "sec", "nsec" }) |f| {
        var pos: ext.Interval = .{};
        @field(pos, f) = 42;
        try expectIntervalRoundTrip(pos);
        var neg: ext.Interval = .{};
        @field(neg, f) = -42;
        try expectIntervalRoundTrip(neg);
    }
    // all-fields combo
    try expectIntervalRoundTrip(.{
        .year = 1,
        .month = 2,
        .week = 3,
        .day = 4,
        .hour = 5,
        .min = 6,
        .sec = 7,
        .nsec = 8,
        .adjust = .last,
    });
    // all three adjust values
    try expectIntervalRoundTrip(.{ .adjust = .excess });
    try expectIntervalRoundTrip(.{ .adjust = .none });
    try expectIntervalRoundTrip(.{ .adjust = .last });
    // i64 extremes on sec
    try expectIntervalRoundTrip(.{ .sec = std.math.maxInt(i64), .adjust = .excess });
    try expectIntervalRoundTrip(.{ .sec = std.math.minInt(i64), .adjust = .excess });

    // via decodeValue -> .ext -> parseInterval
    var buf = try enc(ext.Interval{ .day = 4, .hour = 5, .sec = 200, .adjust = .excess });
    defer buf.deinit();
    var dec = msgpack.Decoder.init(buf.items());
    const v = try dec.decodeValue(a);
    try testing.expect(v == .ext);
    const back = try ext.parseInterval(v.ext);
    try testing.expectEqual(ext.Interval{ .day = 4, .hour = 5, .sec = 200, .adjust = .excess }, back);
}

test "interval: parse defaults missing adjust to .excess" {
    // payload {0x00}: empty (count 0) => all-zero + .excess
    const zero = try ext.parseInterval(.{ .type = 6, .data = &.{0x00} });
    try testing.expectEqual(ext.Interval{ .adjust = .excess }, zero);
    // payload {0x01,0x08,0x01}: adjust field present with value none
    const none = try ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x08, 0x01 } });
    try testing.expectEqual(ext.Interval{ .adjust = .none }, none);
}

test "interval: parse is fail-fast" {
    // wrong ext type
    try testing.expectError(error.WrongExtType, ext.parseInterval(.{ .type = 4, .data = &.{0x00} }));
    // empty payload (no count byte)
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{} }));
    // truncated pair (count promises 1 entry, but no id/value)
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{0x01} }));
    // truncated value (id present, value missing)
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x06 } }));
    // unknown field id 9
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x09, 0x00 } }));
    // adjust value 3 (> 2)
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x08, 0x03 } }));
    // trailing bytes after the pairs (count 1, but two pairs present)
    try testing.expectError(
        error.InvalidInterval,
        ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x06, 0x07, 0x08, 0x01 } }),
    );
    // cc-form field id: id byte reads as raw 0xcc = 204, host-parity reject
    try testing.expectError(error.InvalidInterval, ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0xcc, 0x06, 0x07 } }));
}

test "interval: parse host-parity lenient forms" {
    // duplicate field id: last wins (host: plain switch assignment)
    const dup = try ext.parseInterval(.{ .type = 6, .data = &.{ 0x02, 0x06, 0x07, 0x06, 0x09 } });
    try testing.expectEqual(ext.Interval{ .sec = 9, .adjust = .excess }, dup);
    // cc-form *value*: values are full int tokens, so 0xcc 0x07 = uint8 7 is accepted
    const cc = try ext.parseInterval(.{ .type = 6, .data = &.{ 0x01, 0x06, 0xcc, 0x07 } });
    try testing.expectEqual(ext.Interval{ .sec = 7, .adjust = .excess }, cc);
}
