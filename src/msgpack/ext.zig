//! Tarantool MessagePack extension types (MP_EXT).
//!
//! Stores every ext as a raw `{ type, data }` and provides a typed pack/parse
//! pair for all four scalar ext types — uuid (2), datetime (4), decimal (1),
//! interval (6). Pure and std-only (no `c.zig` import), so the codec is
//! connector-reusable.

const std = @import("std");

/// Tarantool-assigned MP_EXT type codes.
pub const Type = enum(i8) {
    decimal = 1,
    uuid = 2,
    @"error" = 3,
    datetime = 4,
    interval = 6,
    _,
};

/// A raw MessagePack extension value: a type byte plus opaque payload.
pub const Ext = struct {
    type: i8,
    data: []const u8,

    pub fn kind(self: Ext) Type {
        return @fromBackingInt(@intCast(self.type));
    }
};

/// A Tarantool UUID: 16 raw bytes. A struct (not a `[16]u8` alias) so `encode()`
/// can dispatch on the type and emit an MP_EXT type-2 value.
pub const Uuid = struct { bytes: [16]u8 };

pub fn parseUuid(e: Ext) !Uuid {
    if (e.type != @backingInt(Type.uuid)) return error.WrongExtType;
    if (e.data.len != 16) return error.InvalidUuid;
    var u: Uuid = undefined;
    @memcpy(&u.bytes, e.data[0..16]);
    return u;
}

/// Tarantool datetime ext: 8-byte little-endian epoch seconds, with an optional
/// 8-byte tail (nsec u32, tzoffset i16, tzindex i16), all little-endian.
pub const Datetime = struct {
    seconds: i64,
    nsec: u32 = 0,
    tzoffset: i16 = 0,
    tzindex: i16 = 0,

    /// Canonical encoded length: 8 bytes when nsec/tzoffset/tzindex are all
    /// zero, else 16.
    pub fn packedLen(self: Datetime) usize {
        return if (self.nsec == 0 and self.tzoffset == 0 and self.tzindex == 0) 8 else 16;
    }

    /// Serialize little-endian into `buf`, returning the canonical 8- or
    /// 16-byte prefix. The exact inverse of `parseDatetime`: seconds
    /// (i64→u64 bitcast) at [0..8]; when the tail is present, nsec u32 at
    /// [8..12], tzoffset i16 (bitcast u16) at [12..14], tzindex i16 at [14..16].
    pub fn pack(self: Datetime, buf: *[16]u8) []u8 {
        std.mem.writeInt(u64, buf[0..8], @bitCast(self.seconds), .little);
        if (self.packedLen() == 8) return buf[0..8];
        std.mem.writeInt(u32, buf[8..12], self.nsec, .little);
        std.mem.writeInt(u16, buf[12..14], @bitCast(self.tzoffset), .little);
        std.mem.writeInt(u16, buf[14..16], @bitCast(self.tzindex), .little);
        return buf[0..16];
    }
};

pub fn parseDatetime(e: Ext) !Datetime {
    if (e.type != @backingInt(Type.datetime)) return error.WrongExtType;
    if (e.data.len != 8 and e.data.len != 16) return error.InvalidDatetime;
    var dt: Datetime = .{ .seconds = @bitCast(std.mem.readInt(u64, e.data[0..8], .little)) };
    if (e.data.len == 16) {
        dt.nsec = std.mem.readInt(u32, e.data[8..12], .little);
        dt.tzoffset = @bitCast(std.mem.readInt(u16, e.data[12..14], .little));
        dt.tzindex = @bitCast(std.mem.readInt(u16, e.data[14..16], .little));
    }
    return dt;
}

/// Maximum number of significant decimal digits Tarantool stores.
pub const decimal_max_digits = 38;

/// A Tarantool DECIMAL (MP_EXT type 1), allocator-free and string-backed.
///
/// Holds the significant digits most-significant-first (no arithmetic, just
/// parse/format/pack/unpack). `scale` is the number of digits AFTER the decimal
/// point, i.e. value = (sign) digits * 10^-scale. Canonical zero is the single
/// digit "0" with scale 0 and `negative = false` so round-trips are stable.
pub const Decimal = struct {
    negative: bool = false,
    /// Significant digits, each 0..9, most-significant first.
    digits: [decimal_max_digits]u8 = undefined,
    ndigits: u8 = 0,
    /// Number of digits after the decimal point (i.e. -exponent).
    scale: i8 = 0,

    /// Parse sign / integer part / optional '.' / fractional part. Fail-fast:
    /// rejects empty, multiple dots, non-digit characters, a bare sign or
    /// dot, and more than `decimal_max_digits` significant digits (no silent
    /// truncation). Trailing zeros are preserved (scale carries them, matching
    /// Tarantool). Canonical zero is "0", scale 0, non-negative (covers "-0").
    pub fn fromString(s: []const u8) !Decimal {
        if (s.len == 0) return error.InvalidDecimal;
        var i: usize = 0;
        var negative = false;
        if (s[0] == '+' or s[0] == '-') {
            negative = s[0] == '-';
            i += 1;
        }
        // Collect raw digits (both sides of the dot) and the scale.
        var raw: [decimal_max_digits + 1]u8 = undefined;
        var n: usize = 0;
        var scale: usize = 0;
        var seen_dot = false;
        var seen_digit = false;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.') {
                if (seen_dot) return error.InvalidDecimal;
                seen_dot = true;
                continue;
            }
            if (c < '0' or c > '9') return error.InvalidDecimal;
            seen_digit = true;
            if (n >= raw.len) return error.DecimalTooLong;
            raw[n] = c - '0';
            n += 1;
            if (seen_dot) scale += 1;
        }
        if (!seen_digit) return error.InvalidDecimal;

        // Canonicalize the coefficient to significant digits only: strip all
        // leading zeros (keeping at least one digit), independent of the dot
        // position, with `scale` unchanged. This matches Tarantool's decimal
        // representation, where `0.001` is coefficient `1` with scale 3 (not
        // `0001`) — required for byte-identical encoding.
        var start: usize = 0;
        while (start + 1 < n and raw[start] == 0) {
            start += 1;
        }
        const sig = raw[start..n];

        // Canonical zero: a single 0 digit, scale 0, non-negative.
        var all_zero = true;
        for (sig) |d| {
            if (d != 0) {
                all_zero = false;
                break;
            }
        }
        if (all_zero) {
            var z: Decimal = .{ .negative = false, .ndigits = 1, .scale = 0 };
            z.digits[0] = 0;
            return z;
        }

        if (sig.len > decimal_max_digits) return error.DecimalTooLong;

        var d: Decimal = .{ .negative = negative, .ndigits = @intCast(sig.len), .scale = @intCast(scale) };
        @memcpy(d.digits[0..sig.len], sig);
        return d;
    }

    /// Format into `buf` (needs up to ndigits + sign + dot + leading "0").
    /// The inverse of `fromString` for canonical values.
    pub fn toString(self: Decimal, buf: []u8) []u8 {
        var pos: usize = 0;
        if (self.negative) {
            buf[pos] = '-';
            pos += 1;
        }
        const nd = self.ndigits;
        const scale: usize = @intCast(self.scale);
        if (scale == 0) {
            for (self.digits[0..nd]) |dig| {
                buf[pos] = '0' + dig;
                pos += 1;
            }
            return buf[0..pos];
        }
        if (scale >= nd) {
            // value < 1: "0." then (scale - nd) leading zeros then digits.
            buf[pos] = '0';
            pos += 1;
            buf[pos] = '.';
            pos += 1;
            var k: usize = 0;
            while (k < scale - nd) : (k += 1) {
                buf[pos] = '0';
                pos += 1;
            }
            for (self.digits[0..nd]) |dig| {
                buf[pos] = '0' + dig;
                pos += 1;
            }
            return buf[0..pos];
        }
        // Dot sits inside the digit run, (nd - scale) digits before it.
        const int_len = nd - scale;
        for (self.digits[0..int_len]) |dig| {
            buf[pos] = '0' + dig;
            pos += 1;
        }
        buf[pos] = '.';
        pos += 1;
        for (self.digits[int_len..nd]) |dig| {
            buf[pos] = '0' + dig;
            pos += 1;
        }
        return buf[0..pos];
    }

    /// Emit the MP_EXT type-1 packed-BCD payload into `buf` (needs up to
    /// `1 + ceil((decimal_max_digits + 1) / 2)` = 21 bytes). The exact inverse
    /// of `parseDecimal`:
    ///   payload = [scale: int8] ++ BCD
    /// where the nibble stream is `d1 d2 ... dN SIGN` (sign 0x0c non-negative,
    /// 0x0d negative), left-padded with a single 0 nibble when N+1 is odd so it
    /// is byte-aligned at the FRONT, then packed two nibbles per byte.
    pub fn pack(self: Decimal, buf: []u8) []u8 {
        buf[0] = @bitCast(self.scale);
        const nd = self.ndigits;
        const sign_nibble: u8 = if (self.negative) 0x0d else 0x0c;
        const nibble_count = @as(usize, nd) + 1; // digits + sign
        const pad = nibble_count % 2; // 1 leading 0 nibble when odd
        const total = nibble_count + pad;
        const nbytes = total / 2;

        var bi: usize = 1; // byte cursor in buf, after the scale byte
        var high = true; // whether the next nibble lands in the high half
        // Reset the BCD region.
        var z: usize = 0;
        while (z < nbytes) : (z += 1) buf[1 + z] = 0;

        // Emit the leading pad nibble (a zero) if present by simply advancing
        // the nibble cursor; buf is already zeroed so the high nibble stays 0.
        if (pad == 1) high = false;

        var k: usize = 0;
        while (k < nd) : (k += 1) {
            placeNibble(buf, &bi, &high, self.digits[k]);
        }
        placeNibble(buf, &bi, &high, sign_nibble);
        return buf[0 .. 1 + nbytes];
    }

    fn placeNibble(buf: []u8, bi: *usize, high: *bool, nib: u8) void {
        if (high.*) {
            buf[bi.*] |= nib << 4;
            high.* = false;
        } else {
            buf[bi.*] |= nib & 0x0f;
            high.* = true;
            bi.* += 1;
        }
    }
};

/// Inverse of `Decimal.pack`. Reads the scale byte, unpacks the BCD
/// nibbles (the last nibble is the sign), and rebuilds the canonical Decimal.
/// Fail-fast on a wrong ext type, empty payload, an invalid sign nibble, a
/// digit nibble > 9, or a digit count beyond `decimal_max_digits`.
pub fn parseDecimal(e: Ext) !Decimal {
    if (e.type != @backingInt(Type.decimal)) return error.WrongExtType;
    if (e.data.len < 2) return error.InvalidDecimal;
    const scale: i8 = @bitCast(e.data[0]);
    // A negative wire scale denotes a scientific-notation magnitude (e.g. `1e3`)
    // that this string-backed `Decimal` cannot represent — `scale` is always the
    // count of fractional digits (≥0). Reject it rather than let `toString`'s
    // `@intCast(usize)` trap on a negative value (fail-fast; keeps the scale≥0
    // invariant that makes that cast safe).
    if (scale < 0) return error.InvalidDecimal;
    const bcd = e.data[1..];

    // Expand to a nibble stream (high then low for each byte).
    var nibbles: [(decimal_max_digits + 2)]u8 = undefined;
    var nn: usize = 0;
    for (bcd) |b| {
        if (nn + 2 > nibbles.len) return error.InvalidDecimal;
        nibbles[nn] = b >> 4;
        nibbles[nn + 1] = b & 0x0f;
        nn += 2;
    }
    if (nn == 0) return error.InvalidDecimal;

    // Last nibble is the sign; the rest (minus any leading pad nibble) are digits.
    const sign = nibbles[nn - 1];
    const negative = switch (sign) {
        0x0c => false,
        0x0d => true,
        else => return error.InvalidDecimal,
    };
    var digits = nibbles[0 .. nn - 1];
    // Drop a single leading pad nibble if the original stream was odd-length
    // (we always pad with exactly one zero nibble at the front).
    if (digits.len > 0 and digits.len % 2 == 1 and digits[0] == 0) {
        digits = digits[1..];
    }
    // Strip remaining leading zeros, keeping at least one digit.
    var start: usize = 0;
    while (start + 1 < digits.len and digits[start] == 0) start += 1;
    digits = digits[start..];

    for (digits) |d| {
        if (d > 9) return error.InvalidDecimal;
    }

    // Canonical zero.
    var all_zero = true;
    for (digits) |d| {
        if (d != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        var z: Decimal = .{ .negative = false, .ndigits = 1, .scale = 0 };
        z.digits[0] = 0;
        return z;
    }

    if (digits.len > decimal_max_digits) return error.InvalidDecimal;
    var d: Decimal = .{ .negative = negative, .ndigits = @intCast(digits.len), .scale = scale };
    @memcpy(d.digits[0..digits.len], digits);
    return d;
}

/// dt_adjust wire values (mp_interval.c: DT_EXCESS/DT_LIMIT/DT_SNAP).
pub const Adjust = enum(u8) { excess = 0, none = 1, last = 2 };

/// Max `Interval.pack` payload: 1 count + 8×(1 id + 9 value) + 2 adjust = 83.
pub const interval_max_packed_len = 83;

/// Tarantool INTERVAL (MP_EXT type 6). Field names mirror Lua's
/// `datetime.interval`; all-i64 because the host's constructor limits for
/// sec/day/hour/min exceed i32. Default `adjust` is `.none` — matching
/// `datetime.interval.new`'s default, so a default `Interval` round-trips as
/// the value Lua would default-construct (`c7 03 06 01 08 01`).
pub const Interval = struct {
    year: i64 = 0,
    month: i64 = 0,
    week: i64 = 0,
    day: i64 = 0,
    hour: i64 = 0,
    min: i64 = 0,
    sec: i64 = 0,
    nsec: i64 = 0,
    adjust: Adjust = .none,

    /// Canonical payload (host byte-identical): a raw `count` byte,
    /// then `count` `(field_id, value)` pairs in ascending id order with zero
    /// fields skipped; `adjust` is emitted iff `!= .excess`. Field ids are
    /// written as one raw byte (they equal `mp_encode_uint` fixints for 0..8);
    /// values use the smallest msgpack int token (uint family when >= 0).
    pub fn pack(self: Interval, buf: *[interval_max_packed_len]u8) []u8 {
        var pos: usize = 1; // buf[0] holds the count, filled in at the end
        var count: u8 = 0;
        const fields = [_]i64{
            self.year, self.month, self.week, self.day,
            self.hour, self.min,   self.sec,  self.nsec,
        };
        inline for (fields, 0..) |v, id| {
            if (v != 0) {
                buf[pos] = @intCast(id); // field id 0..7 as a raw byte
                pos += 1;
                pos += putIntToken(buf[pos..], v);
                count += 1;
            }
        }
        if (self.adjust != .excess) {
            buf[pos] = 8; // adjust field id
            pos += 1;
            pos += putUintToken(buf[pos..], @backingInt(self.adjust));
            count += 1;
        }
        buf[0] = count;
        return buf[0..pos];
    }
};

/// Inverse of `Interval.pack`. Wrong ext type -> `error.WrongExtType`; anything
/// malformed (empty payload, truncated pair, unknown field id, `cc`-form field
/// id read as a raw byte outside 0..8, adjust wire value > 2, a value outside
/// i64, trailing bytes) -> `error.InvalidInterval`. Missing fields are zero;
/// missing adjust is `.excess` (wire 0, NOT the `.none` constructor default). Duplicate ids: last wins (host decode parity).
pub fn parseInterval(e: Ext) !Interval {
    if (e.type != @backingInt(Type.interval)) return error.WrongExtType;
    if (e.data.len == 0) return error.InvalidInterval;
    const count = e.data[0]; // raw u8 (mp_load_u8 on the host)
    var iv: Interval = .{ .adjust = .excess }; // absent adjust => excess
    var data = e.data[1..];
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (data.len == 0) return error.InvalidInterval;
        const id = data[0]; // raw byte (mp_load_u8 on the host)
        data = data[1..];
        const tok = try readIntToken(data);
        data = data[tok.len..];
        switch (id) {
            0 => iv.year = tok.value,
            1 => iv.month = tok.value,
            2 => iv.week = tok.value,
            3 => iv.day = tok.value,
            4 => iv.hour = tok.value,
            5 => iv.min = tok.value,
            6 => iv.sec = tok.value,
            7 => iv.nsec = tok.value,
            8 => iv.adjust = switch (tok.value) {
                0 => .excess,
                1 => .none,
                2 => .last,
                else => return error.InvalidInterval,
            },
            else => return error.InvalidInterval,
        }
    }
    if (data.len != 0) return error.InvalidInterval; // trailing bytes
    return iv;
}

// --- private msgpack int-token helpers (self-contained; keeps ext.zig
//     std-only, no msgpack.zig import — Design choice 1). Pinned to the same
//     probe fixtures as msgpack.zig's private encoders. ---

/// Write `v` as the smallest-form msgpack uint token into `buf`; return length.
fn putUintToken(buf: []u8, v: u64) usize {
    if (v < 0x80) {
        buf[0] = @intCast(v);
        return 1;
    } else if (v <= 0xff) {
        buf[0] = 0xcc;
        buf[1] = @intCast(v);
        return 2;
    } else if (v <= 0xffff) {
        buf[0] = 0xcd;
        std.mem.writeInt(u16, buf[1..3], @intCast(v), .big);
        return 3;
    } else if (v <= 0xffffffff) {
        buf[0] = 0xce;
        std.mem.writeInt(u32, buf[1..5], @intCast(v), .big);
        return 5;
    } else {
        buf[0] = 0xcf;
        std.mem.writeInt(u64, buf[1..9], v, .big);
        return 9;
    }
}

/// Write `v` as the smallest-form msgpack int token into `buf`; return length.
/// Uint family when `v >= 0`, signed-int family otherwise (host encoder parity).
fn putIntToken(buf: []u8, v: i64) usize {
    if (v >= 0) return putUintToken(buf, @intCast(v));
    if (v >= -32) {
        buf[0] = @bitCast(@as(i8, @intCast(v))); // negative fixint
        return 1;
    } else if (v >= -128) {
        buf[0] = 0xd0;
        buf[1] = @bitCast(@as(i8, @intCast(v)));
        return 2;
    } else if (v >= -32768) {
        buf[0] = 0xd1;
        std.mem.writeInt(i16, buf[1..3], @intCast(v), .big);
        return 3;
    } else if (v >= -2147483648) {
        buf[0] = 0xd2;
        std.mem.writeInt(i32, buf[1..5], @intCast(v), .big);
        return 5;
    } else {
        buf[0] = 0xd3;
        std.mem.writeInt(i64, buf[1..9], v, .big);
        return 9;
    }
}

const IntToken = struct { value: i64, len: usize };

/// Read any msgpack int token from the front of `data` into an i64. Fail-fast:
/// a truncated token, a non-int lead byte, or a uint64 value beyond i64 all
/// yield `error.InvalidInterval`.
fn readIntToken(data: []const u8) !IntToken {
    if (data.len == 0) return error.InvalidInterval;
    const t = data[0];
    if (t < 0x80) return .{ .value = t, .len = 1 }; // positive fixint
    if (t >= 0xe0) return .{ .value = @as(i8, @bitCast(t)), .len = 1 }; // negative fixint
    switch (t) {
        0xcc => {
            if (data.len < 2) return error.InvalidInterval;
            return .{ .value = data[1], .len = 2 };
        },
        0xcd => {
            if (data.len < 3) return error.InvalidInterval;
            return .{ .value = std.mem.readInt(u16, data[1..3], .big), .len = 3 };
        },
        0xce => {
            if (data.len < 5) return error.InvalidInterval;
            return .{ .value = std.mem.readInt(u32, data[1..5], .big), .len = 5 };
        },
        0xcf => {
            if (data.len < 9) return error.InvalidInterval;
            const u = std.mem.readInt(u64, data[1..9], .big);
            return .{ .value = std.math.cast(i64, u) orelse return error.InvalidInterval, .len = 9 };
        },
        0xd0 => {
            if (data.len < 2) return error.InvalidInterval;
            return .{ .value = @as(i8, @bitCast(data[1])), .len = 2 };
        },
        0xd1 => {
            if (data.len < 3) return error.InvalidInterval;
            return .{ .value = std.mem.readInt(i16, data[1..3], .big), .len = 3 };
        },
        0xd2 => {
            if (data.len < 5) return error.InvalidInterval;
            return .{ .value = std.mem.readInt(i32, data[1..5], .big), .len = 5 };
        },
        0xd3 => {
            if (data.len < 9) return error.InvalidInterval;
            return .{ .value = std.mem.readInt(i64, data[1..9], .big), .len = 9 };
        },
        else => return error.InvalidInterval,
    }
}
