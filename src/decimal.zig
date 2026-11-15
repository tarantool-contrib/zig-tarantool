//! Typed decimal: a host-bound `Decimal` value type over Tarantool's
//! `box_decimal_*` C family (this module is legitimately Tarantool-bound and
//! imports `c.zig`; it also imports `msgpack` for the ext bridge, but stays out
//! of `msgpack/` so that codec tree remains `c.zig`-free).
//!
//! `Decimal` embeds the full 64-byte `box_decimal_t` storage (`raw`) and has
//! value semantics: every method returns a NEW value and never mutates `self`.
//! The host's rounding ops mutate their `dec` in place (module.h "return @a dec
//! (changed)"), so those wrappers `dup` first and mutate the copy. The
//! `internal` words are never read or written by SDK code — the only access to
//! `raw` is taking its address for a host call. Because we always embed
//! and stack-initialize the full storage before the first host call, returning
//! a freshly-initialized stack `Decimal` by value is the single sanctioned
//! struct copy; every OTHER duplication goes through `dup` (`box_decimal_copy`),
//! never `memcpy`/assignment from a host-owned pointer.
//!
//! Error model: the header documents every fallible `box_decimal_*` as
//! returning NULL on error and never promises to set the box diagnostic, so a
//! NULL return maps to a plain Zig error and the wrappers NEVER consult
//! `box_error_last` — a stale host diag would otherwise misattribute. NULL is
//! `error.InvalidDecimal` for construct/decode, `error.Overflow` for
//! toInt/toUint, and `error.DecimalError` for arithmetic/rounding/math.

const std = @import("std");
const c = @import("c.zig");
const msgpack = @import("msgpack");

/// Buffer size that holds any `toString` result (= `BOX_DECIMAL_STRING_BUFFER_SIZE`).
pub const string_buffer_size: usize = c.BOX_DECIMAL_STRING_BUFFER_SIZE;

/// A NULL host return from an arithmetic/rounding/math op — overflow,
/// division by zero, a domain error (e.g. `sqrt(-1)`), or a scale out of
/// range. No diag is read.
pub const Error = error{DecimalError};

/// A typed decimal number. See the module comment for the value-semantics,
/// copy, and error-model contracts.
pub const Decimal = extern struct {
    raw: c.box_decimal_t,

    // ---- construct ----

    /// The value `0`. The host documents a non-NULL return; discarded.
    pub fn zero() Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_zero(&out.raw);
        return out;
    }

    /// Parse a decimal from its string form. A NULL host return (malformed
    /// input, too many digits) maps to `error.InvalidDecimal`.
    pub fn fromString(s: [:0]const u8) error{InvalidDecimal}!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_from_string(&out.raw, s.ptr) orelse return error.InvalidDecimal;
        return out;
    }

    /// Convert from a binary float. NaN/Inf/too-precise → `error.InvalidDecimal`.
    pub fn fromFloat(v: f64) error{InvalidDecimal}!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_from_double(&out.raw, v) orelse return error.InvalidDecimal;
        return out;
    }

    /// Exact conversion from a signed 64-bit integer. Infallible.
    pub fn fromInt(v: i64) Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_from_int64(&out.raw, v);
        return out;
    }

    /// Exact conversion from an unsigned 64-bit integer. Infallible.
    pub fn fromUint(v: u64) Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_from_uint64(&out.raw, v);
        return out;
    }

    // ---- convert ----

    /// Render into `buf` and return the NUL-terminated result as a sentinel
    /// slice. `buf` is sized to hold any decimal's string form.
    pub fn toString(self: *const Decimal, buf: *[string_buffer_size]u8) [:0]const u8 {
        c.box_decimal_to_string(&self.raw, buf);
        const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..n :0];
    }

    /// Convert to a signed 64-bit integer. A NULL host return (out of range)
    /// maps to `error.Overflow`.
    pub fn toInt(self: *const Decimal) error{Overflow}!i64 {
        var out: i64 = undefined;
        _ = c.box_decimal_to_int64(&self.raw, &out) orelse return error.Overflow;
        return out;
    }

    /// Convert to an unsigned 64-bit integer. A NULL host return (out of range,
    /// negative) maps to `error.Overflow`.
    pub fn toUint(self: *const Decimal) error{Overflow}!u64 {
        var out: u64 = undefined;
        _ = c.box_decimal_to_uint64(&self.raw, &out) orelse return error.Overflow;
        return out;
    }

    // ---- inspect ----

    /// Number of significant decimal digits.
    pub fn precision(self: *const Decimal) i32 {
        return @intCast(c.box_decimal_precision(&self.raw));
    }

    /// Number of digits after the decimal point (negative exponent).
    pub fn scale(self: *const Decimal) i32 {
        return @intCast(c.box_decimal_scale(&self.raw));
    }

    /// Whether the value has no fractional part.
    pub fn isInt(self: *const Decimal) bool {
        return c.box_decimal_is_int(&self.raw);
    }

    /// Whether the value is negative.
    pub fn isNeg(self: *const Decimal) bool {
        return c.box_decimal_is_neg(&self.raw);
    }

    // ---- compare + copy ----

    /// Total order over decimals (across differing sign/scale/precision).
    pub fn order(lhs: *const Decimal, rhs: *const Decimal) std.math.Order {
        return std.math.order(c.box_decimal_compare(&lhs.raw, &rhs.raw), 0);
    }

    /// The explicit copy path (`box_decimal_copy`) — THE sanctioned duplication
    /// of a live decimal. Returns an independent value.
    pub fn dup(self: *const Decimal) Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_copy(&out.raw, &self.raw);
        return out;
    }

    // ---- arithmetic (binary; NULL → error.DecimalError) ----

    /// `lhs + rhs`. Overflow → `error.DecimalError`.
    pub fn add(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_add(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    /// `lhs - rhs`. Overflow → `error.DecimalError`.
    pub fn sub(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_sub(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    /// `lhs * rhs`. Overflow → `error.DecimalError`.
    pub fn mul(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_mul(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    /// `lhs / rhs`. Division by zero / overflow → `error.DecimalError`.
    pub fn div(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_div(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    /// `lhs % rhs` (`box_decimal_remainder`). Division by zero → `error.DecimalError`.
    pub fn rem(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_remainder(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    /// `lhs ^ rhs`. Domain/overflow error → `error.DecimalError`.
    pub fn pow(lhs: *const Decimal, rhs: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_pow(&out.raw, &lhs.raw, &rhs.raw) orelse return error.DecimalError;
        return out;
    }

    // ---- unary infallible ----

    /// Negation (`box_decimal_minus`). Infallible.
    pub fn neg(self: *const Decimal) Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_minus(&out.raw, &self.raw);
        return out;
    }

    /// Absolute value. Infallible.
    pub fn abs(self: *const Decimal) Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_abs(&out.raw, &self.raw);
        return out;
    }

    /// Strip trailing fractional zeros (dup-then-trim; host mutates in place,
    /// documents no failure — the return is discarded). Infallible.
    pub fn trim(self: *const Decimal) Decimal {
        var out = self.dup();
        _ = c.box_decimal_trim(&out.raw);
        return out;
    }

    // ---- unary fallible math (NULL → error.DecimalError) ----

    /// Square root. `sqrt` of a negative → `error.DecimalError`.
    pub fn sqrt(self: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_sqrt(&out.raw, &self.raw) orelse return error.DecimalError;
        return out;
    }

    /// Natural logarithm. Domain error (`ln` of ≤ 0) → `error.DecimalError`.
    pub fn ln(self: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_ln(&out.raw, &self.raw) orelse return error.DecimalError;
        return out;
    }

    /// Base-10 logarithm. Domain error → `error.DecimalError`.
    pub fn log10(self: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_log10(&out.raw, &self.raw) orelse return error.DecimalError;
        return out;
    }

    /// Exponential (`e^self`). Overflow → `error.DecimalError`.
    pub fn exp(self: *const Decimal) Error!Decimal {
        var out: Decimal = undefined;
        _ = c.box_decimal_exp(&out.raw, &self.raw) orelse return error.DecimalError;
        return out;
    }

    // ---- rounding (dup-then-mutate; NULL = scale out of range) ----

    /// Round to `to_scale` fractional digits (half away from zero). Scale out
    /// of range → `error.DecimalError`.
    pub fn round(self: *const Decimal, to_scale: i32) Error!Decimal {
        var out = self.dup();
        _ = c.box_decimal_round(&out.raw, @intCast(to_scale)) orelse return error.DecimalError;
        return out;
    }

    /// Round toward zero to `to_scale` fractional digits. Scale out of range →
    /// `error.DecimalError`.
    pub fn floor(self: *const Decimal, to_scale: i32) Error!Decimal {
        var out = self.dup();
        _ = c.box_decimal_floor(&out.raw, @intCast(to_scale)) orelse return error.DecimalError;
        return out;
    }

    /// Set the scale to exactly `to_scale` digits (padding or rounding). Scale
    /// out of range → `error.DecimalError`.
    pub fn rescale(self: *const Decimal, to_scale: i32) Error!Decimal {
        var out = self.dup();
        _ = c.box_decimal_rescale(&out.raw, @intCast(to_scale)) orelse return error.DecimalError;
        return out;
    }

    // ---- msgpack ext bridge (raw ext bytes <-> Decimal) ----

    /// Decode from a raw MP_EXT value's payload. The `Ext` carries the
    /// header-less payload that `box_decimal_mp_decode_data` expects. A wrong
    /// ext type or a malformed payload maps to `error.InvalidDecimal`.
    pub fn fromExt(e: msgpack.ext.Ext) error{InvalidDecimal}!Decimal {
        if (e.type != @backingInt(msgpack.ext.Type.decimal)) return error.InvalidDecimal;
        var out: Decimal = undefined;
        var ptr: [*c]const u8 = e.data.ptr;
        _ = c.box_decimal_mp_decode_data(&out.raw, &ptr, @intCast(e.data.len)) orelse
            return error.InvalidDecimal;
        return out;
    }

    /// Size in bytes of the FULL msgpack ext value (header included) this
    /// decimal encodes to (`box_decimal_mp_sizeof`).
    pub fn extSizeof(self: *const Decimal) u32 {
        return c.box_decimal_mp_sizeof(&self.raw);
    }

    /// Encode the COMPLETE msgpack ext value (header + payload) into `buf` and
    /// return the written slice. Asserts `buf` is large enough (fail-fast —
    /// `extSizeof` is the exact need).
    pub fn encodeExt(self: *const Decimal, buf: []u8) []const u8 {
        std.debug.assert(self.extSizeof() <= buf.len);
        const end = c.box_decimal_mp_encode(&self.raw, buf.ptr);
        const n = @intFromPtr(end) - @intFromPtr(buf.ptr);
        return buf[0..n];
    }

    // ---- structural codec-hook pair (consumed by msgpack.encode/decode) ----

    /// Hook: write this decimal as one complete msgpack ext value. Any decimal's
    /// full encoding is ≤ ~30 bytes; the 64-byte scratch is ample and the
    /// `encodeExt` assert guards it.
    pub fn mpEncode(self: Decimal, w: anytype) !void {
        var buf: [64]u8 = undefined;
        try w.writeAll(self.encodeExt(&buf));
    }

    /// Hook: decode this decimal from one complete msgpack ext value. A payload
    /// that is not a valid decimal surfaces as `error.InvalidExt` (the hook
    /// contract's malformed-payload error).
    pub fn mpDecode(dec: *msgpack.Decoder) msgpack.DecodeError!Decimal {
        const e = try msgpack.decode(msgpack.ext.Ext, dec);
        return fromExt(e) catch error.InvalidExt;
    }
};
