//! MessagePack codec with first-class Tarantool MP_EXT support.
//!
//! Carries no Tarantool C dependency: the SDK and the network client share it.
//! Encoding conventions are explicit, never guessed: `[]const u8` and
//! string/array-of-u8 encode as `str`; binary uses the `Bin` newtype; tuple
//! structs encode as positional `array`, named structs as `map`. Decode is
//! fail-fast: type and arity mismatches are errors, never coercions.
//!
//! Guide: https://tarantool-contrib.github.io/zig-tarantool/concepts/encoding/

const std = @import("std");
pub const ext = @import("ext.zig");

pub const Bin = struct { bytes: []const u8 };

pub const KV = struct { key: Value, value: Value };

/// Schema-less MessagePack value, for dynamic decode.
pub const Value = union(enum) {
    nil,
    bool: bool,
    uint: u64,
    int: i64,
    float: f64,
    str: []const u8,
    bin: []const u8,
    array: []const Value,
    map: []const KV,
    ext: ext.Ext,
};

/// Minimal growable byte sink satisfying the `encode` writer contract
/// (`writeByte`/`writeAll`). Decoupled from std.Io so the codec is stable
/// across Zig releases.
pub const Buffer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Buffer {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Buffer) void {
        self.list.deinit(self.gpa);
    }
    pub fn writeByte(self: *Buffer, b: u8) !void {
        try self.list.append(self.gpa, b);
    }
    pub fn writeAll(self: *Buffer, bytes: []const u8) !void {
        try self.list.appendSlice(self.gpa, bytes);
    }
    pub fn items(self: *const Buffer) []const u8 {
        return self.list.items;
    }
};

// ===========================================================================
// Encoding
// ===========================================================================

fn writeIntBE(w: anytype, comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    try w.writeAll(&b);
}

fn encodeUint(w: anytype, v: u64) !void {
    if (v < 0x80) {
        try w.writeByte(@intCast(v));
    } else if (v <= 0xff) {
        try w.writeByte(0xcc);
        try w.writeByte(@intCast(v));
    } else if (v <= 0xffff) {
        try w.writeByte(0xcd);
        try writeIntBE(w, u16, @intCast(v));
    } else if (v <= 0xffffffff) {
        try w.writeByte(0xce);
        try writeIntBE(w, u32, @intCast(v));
    } else {
        try w.writeByte(0xcf);
        try writeIntBE(w, u64, v);
    }
}

fn encodeInt(w: anytype, v: i64) !void {
    if (v >= 0) return encodeUint(w, @intCast(v));
    if (v >= -32) {
        try w.writeByte(@bitCast(@as(i8, @intCast(v)))); // negative fixint
    } else if (v >= -128) {
        try w.writeByte(0xd0);
        try w.writeByte(@bitCast(@as(i8, @intCast(v))));
    } else if (v >= -32768) {
        try w.writeByte(0xd1);
        try writeIntBE(w, i16, @intCast(v));
    } else if (v >= -2147483648) {
        try w.writeByte(0xd2);
        try writeIntBE(w, i32, @intCast(v));
    } else {
        try w.writeByte(0xd3);
        try writeIntBE(w, i64, v);
    }
}

fn encodeFloat(w: anytype, v: f64) !void {
    try w.writeByte(0xcb);
    try writeIntBE(w, u64, @bitCast(v));
}

fn encodeStr(w: anytype, s: []const u8) !void {
    const n = s.len;
    if (n < 32) {
        try w.writeByte(0xa0 | @as(u8, @intCast(n)));
    } else if (n <= 0xff) {
        try w.writeByte(0xd9);
        try w.writeByte(@intCast(n));
    } else if (n <= 0xffff) {
        try w.writeByte(0xda);
        try writeIntBE(w, u16, @intCast(n));
    } else {
        try w.writeByte(0xdb);
        try writeIntBE(w, u32, @intCast(n));
    }
    try w.writeAll(s);
}

fn encodeBin(w: anytype, s: []const u8) !void {
    const n = s.len;
    if (n <= 0xff) {
        try w.writeByte(0xc4);
        try w.writeByte(@intCast(n));
    } else if (n <= 0xffff) {
        try w.writeByte(0xc5);
        try writeIntBE(w, u16, @intCast(n));
    } else {
        try w.writeByte(0xc6);
        try writeIntBE(w, u32, @intCast(n));
    }
    try w.writeAll(s);
}

pub fn encodeArrayHeader(w: anytype, n: usize) !void {
    if (n < 16) {
        try w.writeByte(0x90 | @as(u8, @intCast(n)));
    } else if (n <= 0xffff) {
        try w.writeByte(0xdc);
        try writeIntBE(w, u16, @intCast(n));
    } else {
        try w.writeByte(0xdd);
        try writeIntBE(w, u32, @intCast(n));
    }
}

fn encodeMapHeader(w: anytype, n: usize) !void {
    if (n < 16) {
        try w.writeByte(0x80 | @as(u8, @intCast(n)));
    } else if (n <= 0xffff) {
        try w.writeByte(0xde);
        try writeIntBE(w, u16, @intCast(n));
    } else {
        try w.writeByte(0xdf);
        try writeIntBE(w, u32, @intCast(n));
    }
}

fn encodeExt(w: anytype, t: i8, data: []const u8) !void {
    const n = data.len;
    switch (n) {
        1 => try w.writeByte(0xd4),
        2 => try w.writeByte(0xd5),
        4 => try w.writeByte(0xd6),
        8 => try w.writeByte(0xd7),
        16 => try w.writeByte(0xd8),
        else => {
            if (n <= 0xff) {
                try w.writeByte(0xc7);
                try w.writeByte(@intCast(n));
            } else if (n <= 0xffff) {
                try w.writeByte(0xc8);
                try writeIntBE(w, u16, @intCast(n));
            } else {
                try w.writeByte(0xc9);
                try writeIntBE(w, u32, @intCast(n));
            }
        },
    }
    try w.writeByte(@bitCast(t));
    try w.writeAll(data);
}

fn encodeValue(w: anytype, v: Value) !void {
    switch (v) {
        .nil => try w.writeByte(0xc0),
        .bool => |b| try w.writeByte(if (b) 0xc3 else 0xc2),
        .uint => |u| try encodeUint(w, u),
        .int => |i| try encodeInt(w, i),
        .float => |f| try encodeFloat(w, f),
        .str => |s| try encodeStr(w, s),
        .bin => |s| try encodeBin(w, s),
        .array => |xs| {
            try encodeArrayHeader(w, xs.len);
            for (xs) |x| try encodeValue(w, x);
        },
        .map => |kvs| {
            try encodeMapHeader(w, kvs.len);
            for (kvs) |kv| {
                try encodeValue(w, kv.key);
                try encodeValue(w, kv.value);
            }
        },
        .ext => |e| try encodeExt(w, e.type, e.data),
    }
}

/// Encode any supported Zig value into `w` (a `Buffer` or anything with
/// `writeByte`/`writeAll`). Dispatch is at comptime over the value's type.
///
/// Structural ext-codec hook: a struct type that declares
/// `pub fn mpEncode(self, w: anytype) !void` owns its own wire form — `encode`
/// calls it and the method must write exactly ONE complete msgpack value. This
/// lets a host-bound type (e.g. `decimal.Decimal`) plug its codec in without
/// `msgpack/` ever naming it (the dispatch is `@hasDecl`, structural).
pub fn encode(w: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Value) return encodeValue(w, value);
    if (T == Bin) return encodeBin(w, value.bytes);
    if (T == ext.Ext) return encodeExt(w, value.type, value.data);
    if (T == ext.Uuid) return encodeExt(w, @backingInt(ext.Type.uuid), &value.bytes);
    if (T == ext.Datetime) {
        var dt_buf: [16]u8 = undefined;
        return encodeExt(w, @backingInt(ext.Type.datetime), value.pack(&dt_buf));
    }
    if (T == ext.Decimal) {
        // max payload: 1 scale byte + ceil((38 + 1) / 2) = 1 + 20 = 21 bytes.
        var dec_buf: [21]u8 = undefined;
        return encodeExt(w, @backingInt(ext.Type.decimal), value.pack(&dec_buf));
    }
    if (T == ext.Interval) {
        var iv_buf: [ext.interval_max_packed_len]u8 = undefined;
        return encodeExt(w, @backingInt(ext.Type.interval), value.pack(&iv_buf));
    }

    switch (@typeInfo(T)) {
        .bool => try w.writeByte(if (value) 0xc3 else 0xc2),
        .int => |info| switch (info.signedness) {
            .signed => try encodeInt(w, @intCast(value)),
            .unsigned => try encodeUint(w, @intCast(value)),
        },
        .comptime_int => {
            if (value < 0) try encodeInt(w, value) else try encodeUint(w, value);
        },
        .float, .comptime_float => try encodeFloat(w, @floatCast(value)),
        .optional => {
            if (value) |v| try encode(w, v) else try w.writeByte(0xc0);
        },
        .null => try w.writeByte(0xc0),
        .void => try w.writeByte(0xc0),
        .@"enum" => try encode(w, @backingInt(value)),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                try encodeStr(w, value)
            else {
                try encodeArrayHeader(w, value.len);
                for (value) |e| try encode(w, e);
            },
            .one => {
                const ci = @typeInfo(p.child);
                if (ci == .array) {
                    if (ci.array.child == u8) {
                        try encodeStr(w, value);
                    } else {
                        try encodeArrayHeader(w, ci.array.len);
                        for (value) |e| try encode(w, e);
                    }
                } else @compileError("encode: unsupported single-item pointer to " ++ @typeName(p.child));
            },
            else => @compileError("encode: unsupported pointer size for " ++ @typeName(T)),
        },
        .array => |arr| if (arr.child == u8)
            try encodeStr(w, &value)
        else {
            try encodeArrayHeader(w, arr.len);
            for (value) |e| try encode(w, e);
        },
        .@"struct" => |s| {
            // Structural ext-codec hook: a struct that declares `mpEncode`
            // owns its own wire form and writes exactly ONE complete msgpack
            // value here (keeps `msgpack/` host-type-free — the check is
            // structural). See `decode` for the reciprocal `mpDecode`.
            if (comptime @hasDecl(T, "mpEncode")) return value.mpEncode(w);
            if (s.is_tuple) {
                try encodeArrayHeader(w, s.field_names.len);
                inline for (s.field_names) |name| try encode(w, @field(value, name));
            } else {
                try encodeMapHeader(w, s.field_names.len);
                inline for (s.field_names) |name| {
                    try encodeStr(w, name);
                    try encode(w, @field(value, name));
                }
            }
        },
        else => @compileError("encode: unsupported type " ++ @typeName(T)),
    }
}

/// Encode any struct (named or tuple) as a positional msgpack array: an
/// N-element array header followed by each field encoded in declaration order.
/// Unlike `encode`, named structs are emitted as arrays (not maps).
pub fn encodeArray(w: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("encodeArray: expected a struct, got " ++ @typeName(T));
    const s = info.@"struct";
    try encodeArrayHeader(w, s.field_names.len);
    inline for (s.field_names) |name| try encode(w, @field(value, name));
}

// ===========================================================================
// Decoding
// ===========================================================================

pub const DecodeError = error{
    Truncated,
    NotInt,
    NotBool,
    NotFloat,
    NotStr,
    NotBin,
    NotArray,
    NotMap,
    NotExt,
    Overflow,
    ArityMismatch,
    UnknownField,
    MissingField,
    OutOfMemory,
    /// A structural `mpDecode` hook read a well-formed msgpack value whose
    /// payload is not a valid instance of the target type (see the hook
    /// contract on `decode`).
    InvalidExt,
};

pub const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Decoder {
        return .{ .buf = buf };
    }

    fn take(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn byte(self: *Decoder) DecodeError!u8 {
        return (try self.take(1))[0];
    }
    fn peek(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
        return self.buf[self.pos];
    }
    fn intBE(self: *Decoder, comptime T: type) DecodeError!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .big);
    }

    fn readArrayHeader(self: *Decoder) DecodeError!usize {
        const t = try self.byte();
        if (t & 0xf0 == 0x90) return t & 0x0f;
        return switch (t) {
            0xdc => try self.intBE(u16),
            0xdd => try self.intBE(u32),
            else => error.NotArray,
        };
    }
    fn readMapHeader(self: *Decoder) DecodeError!usize {
        const t = try self.byte();
        if (t & 0xf0 == 0x80) return t & 0x0f;
        return switch (t) {
            0xde => try self.intBE(u16),
            0xdf => try self.intBE(u32),
            else => error.NotMap,
        };
    }
    fn readStr(self: *Decoder) DecodeError![]const u8 {
        const t = try self.byte();
        const n: usize = if (t & 0xe0 == 0xa0) t & 0x1f else switch (t) {
            0xd9 => try self.byte(),
            0xda => try self.intBE(u16),
            0xdb => try self.intBE(u32),
            else => return error.NotStr,
        };
        return self.take(n);
    }
    fn readBin(self: *Decoder) DecodeError![]const u8 {
        const t = try self.byte();
        const n: usize = switch (t) {
            0xc4 => try self.byte(),
            0xc5 => try self.intBE(u16),
            0xc6 => try self.intBE(u32),
            else => return error.NotBin,
        };
        return self.take(n);
    }
    fn readExt(self: *Decoder) DecodeError!ext.Ext {
        const t = try self.byte();
        const n: usize = switch (t) {
            0xd4 => 1,
            0xd5 => 2,
            0xd6 => 4,
            0xd7 => 8,
            0xd8 => 16,
            0xc7 => try self.byte(),
            0xc8 => try self.intBE(u16),
            0xc9 => try self.intBE(u32),
            else => return error.NotExt,
        };
        const type_byte: i8 = @bitCast(try self.byte());
        return .{ .type = type_byte, .data = try self.take(n) };
    }

    /// Read any integer token into a wide accumulator. Signedness preserved.
    fn readIntWide(self: *Decoder) DecodeError!i128 {
        const t = try self.byte();
        if (t < 0x80) return t; // positive fixint
        if (t >= 0xe0) return @as(i8, @bitCast(t)); // negative fixint
        return switch (t) {
            0xcc => try self.intBE(u8),
            0xcd => try self.intBE(u16),
            0xce => try self.intBE(u32),
            0xcf => try self.intBE(u64),
            0xd0 => try self.intBE(i8),
            0xd1 => try self.intBE(i16),
            0xd2 => try self.intBE(i32),
            0xd3 => try self.intBE(i64),
            else => error.NotInt,
        };
    }

    fn decodeInt(self: *Decoder, comptime T: type) DecodeError!T {
        const v = try self.readIntWide();
        return std.math.cast(T, v) orelse error.Overflow;
    }

    fn decodeFloat(self: *Decoder) DecodeError!f64 {
        const t = try self.byte();
        return switch (t) {
            0xca => @as(f32, @bitCast(try self.intBE(u32))),
            0xcb => @bitCast(try self.intBE(u64)),
            else => error.NotFloat,
        };
    }

    /// Decode a schema-less value. Containers allocate via `gpa`; the caller
    /// owns and frees array/map slices (recursively).
    pub fn decodeValue(self: *Decoder, gpa: std.mem.Allocator) DecodeError!Value {
        const t = try self.peek();
        // nil / bool
        if (t == 0xc0) {
            _ = try self.byte();
            return .nil;
        }
        if (t == 0xc2 or t == 0xc3) {
            _ = try self.byte();
            return .{ .bool = t == 0xc3 };
        }
        // float
        if (t == 0xca or t == 0xcb) return .{ .float = try self.decodeFloat() };
        // str
        if (t & 0xe0 == 0xa0 or t == 0xd9 or t == 0xda or t == 0xdb)
            return .{ .str = try self.readStr() };
        // bin
        if (t == 0xc4 or t == 0xc5 or t == 0xc6) return .{ .bin = try self.readBin() };
        // ext
        if ((t >= 0xd4 and t <= 0xd8) or (t >= 0xc7 and t <= 0xc9))
            return .{ .ext = try self.readExt() };
        // array
        if (t & 0xf0 == 0x90 or t == 0xdc or t == 0xdd) {
            const n = try self.readArrayHeader();
            const xs = try gpa.alloc(Value, n);
            errdefer gpa.free(xs);
            var i: usize = 0;
            errdefer for (xs[0..i]) |x| freeValue(gpa, x);
            while (i < n) : (i += 1) xs[i] = try self.decodeValue(gpa);
            return .{ .array = xs };
        }
        // map
        if (t & 0xf0 == 0x80 or t == 0xde or t == 0xdf) {
            const n = try self.readMapHeader();
            const kvs = try gpa.alloc(KV, n);
            errdefer gpa.free(kvs);
            var i: usize = 0;
            errdefer for (kvs[0..i]) |kv| {
                freeValue(gpa, kv.key);
                freeValue(gpa, kv.value);
            };
            while (i < n) : (i += 1) {
                const key = try self.decodeValue(gpa);
                errdefer freeValue(gpa, key);
                const value = try self.decodeValue(gpa);
                kvs[i] = .{ .key = key, .value = value };
            }
            return .{ .map = kvs };
        }
        // remaining tokens are integers (fixints + intN/uintN)
        const wide = try self.readIntWide();
        if (wide >= 0) return .{ .uint = @intCast(wide) };
        return .{ .int = @intCast(wide) };
    }
};

/// Recursively free a `Value` produced by `Decoder.decodeValue`: frees array and
/// map backing slices and their children. Scalars and borrowed str/bin are
/// no-ops (they point into the decoder buffer, not the allocator).
pub fn freeValue(gpa: std.mem.Allocator, v: Value) void {
    switch (v) {
        .array => |xs| {
            for (xs) |x| freeValue(gpa, x);
            gpa.free(xs);
        },
        .map => |kvs| {
            for (kvs) |kv| {
                freeValue(gpa, kv.key);
                freeValue(gpa, kv.value);
            }
            gpa.free(kvs);
        },
        else => {},
    }
}

/// Decode a concrete (fixed-shape) type. Allocation-free: `[]const u8` and
/// `Bin` borrow from the decoder buffer; structs/arrays/optionals/enums are
/// flat. For schema-less data use `Decoder.decodeValue`.
///
/// Structural ext-codec hook (reciprocal of `encode`'s): a struct type that
/// declares `pub fn mpDecode(*Decoder) DecodeError!T` reads exactly ONE
/// complete msgpack value and returns itself; a well-formed value with a
/// payload that is not a valid instance surfaces as `error.InvalidExt`. Errors
/// are restricted to `DecodeError` so the hook composes with generic decoding.
pub fn decode(comptime T: type, dec: *Decoder) DecodeError!T {
    if (T == Bin) return .{ .bytes = try dec.readBin() };
    if (T == ext.Ext) return dec.readExt();

    switch (@typeInfo(T)) {
        .bool => {
            const t = try dec.byte();
            return switch (t) {
                0xc2 => false,
                0xc3 => true,
                else => error.NotBool,
            };
        },
        .int => return dec.decodeInt(T),
        .float => return @floatCast(try dec.decodeFloat()),
        .optional => |o| {
            if ((try dec.peek()) == 0xc0) {
                _ = try dec.byte();
                return null;
            }
            return try decode(o.child, dec);
        },
        .@"enum" => |e| return @fromBackingInt(@intCast(try dec.decodeInt(e.tag_type))),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return dec.readStr();
            @compileError("decode: unsupported pointer type " ++ @typeName(T));
        },
        .array => |arr| {
            const n = try dec.readArrayHeader();
            if (n != arr.len) return error.ArityMismatch;
            var out: T = undefined;
            for (&out) |*e| e.* = try decode(arr.child, dec);
            return out;
        },
        .@"struct" => |s| {
            // Structural ext-codec hook (reciprocal of `encode`'s `mpEncode`):
            // a struct that declares `mpDecode` reads exactly ONE complete
            // msgpack value and returns itself; a malformed payload surfaces
            // through `DecodeError` (typically `InvalidExt`). The check is
            // structural — `msgpack/` never names a host type.
            if (comptime @hasDecl(T, "mpDecode")) return T.mpDecode(dec);
            if (s.is_tuple) {
                const n = try dec.readArrayHeader();
                if (n != s.field_names.len) return error.ArityMismatch;
                var out: T = undefined;
                inline for (s.field_names, s.field_types) |name, ty| {
                    @field(out, name) = try decode(ty, dec);
                }
                return out;
            }
            const n = try dec.readMapHeader();
            var out: T = undefined;
            var seen: [s.field_names.len]bool = @splat(false);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const key = try dec.readStr();
                var matched = false;
                inline for (s.field_names, s.field_types, 0..) |name, ty, fi| {
                    if (!matched and std.mem.eql(u8, key, name)) {
                        @field(out, name) = try decode(ty, dec);
                        seen[fi] = true;
                        matched = true;
                    }
                }
                if (!matched) return error.UnknownField;
            }
            inline for (s.field_names, s.field_types, 0..) |name, ty, fi| {
                if (!seen[fi]) {
                    if (@typeInfo(ty) == .optional) {
                        @field(out, name) = null;
                    } else return error.MissingField;
                }
            }
            return out;
        },
        else => @compileError("decode: unsupported type " ++ @typeName(T)),
    }
}

/// Decode a positional msgpack array into any struct (named or tuple): reads an
/// N-element array header, returns `error.ArityMismatch` if N != the struct's
/// field count, then decodes each element positionally into declaration order.
/// No silent coercion: a per-field type mismatch surfaces the codec's decode
/// error.
pub fn decodeArray(comptime T: type, dec: *Decoder) DecodeError!T {
    const info = @typeInfo(T);
    if (info != .@"struct")
        @compileError("decodeArray: expected a struct, got " ++ @typeName(T));
    const s = info.@"struct";
    const n = try dec.readArrayHeader();
    if (n != s.field_names.len) return error.ArityMismatch;
    var out: T = undefined;
    inline for (s.field_names, s.field_types) |name, ty| {
        @field(out, name) = try decode(ty, dec);
    }
    return out;
}
