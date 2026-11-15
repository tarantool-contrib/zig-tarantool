//! Integration coverage for the MP_EXT codec: proves the pure
//! `ext.Uuid` / `ext.Datetime` / `ext.Decimal` / `ext.Interval` encoders
//! against the live host.
//!
//! Three proofs, all asserted by the Lua driver (`ext.lua`):
//!   - `ext_roundtrip`: build a tuple carrying a uuid, a datetime, a
//!     decimal, and an interval via the pure codec, `replace` it into a typed
//!     space, and let Lua read the row back and assert each field as its native
//!     Tarantool type.
//!   - `dec_oracle`: for a fixed set of decimal strings, encode each via
//!     the pure codec AND via the host `box_decimal_from_string` +
//!     `box_decimal_mp_encode`, then assert the two MessagePack byte slices are
//!     byte-identical. `box_decimal_mp_encode` emits the COMPLETE ext value
//!     (marker + type + payload) — the same thing `t.msgpack.encode` produces —
//!     so the comparison is over the full encoded slices. The first divergence
//!     fails loudly with the offending string; nothing is lenient.
//!   - `interval_reencode`: the live byte-oracle for interval, which
//!     has NO host C API to bind. Lua passes `datetime.interval.new{...}`; the
//!     proc decodes the host's MP_EXT bytes with `parseInterval` and re-encodes
//!     the resulting `ext.Interval` with the pure codec, returning the bytes as
//!     a msgpack str. Lua asserts they equal `msgpack.encode(itv)` per sample —
//!     proving decode (host→pure) and encode (pure ≡ host) with no C ABI.
//!
//! The host decimal ABI (`box_decimal_*`) lives only in `c.zig` and is touched
//! only here + in `c_verify`; the shipped `ext.zig`/`msgpack.zig` stay
//! pure. `box_decimal_t` is treated as opaque stack storage. Interval has
//! no host C API at all — its oracle is entirely `msgpack.encode` in Lua.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;
const msgpack = t.msgpack;
const ext = t.msgpack.ext;

const alloc = std.heap.c_allocator;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// The fixed UUID round-tripped by `ext_roundtrip`. Big-endian textual form
/// "00112233-4455-6677-8899-aabbccddeeff" — the bytes are stored in that order.
const sample_uuid = ext.Uuid{ .bytes = .{
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
} };

/// 2021-01-01T00:00:00Z = 1609459200 epoch seconds. nsec/tz all zero → the
/// canonical 8-byte datetime form.
const sample_dt = ext.Datetime{ .seconds = 1609459200 };

const sample_decimal_str = "3.14159";

/// The interval round-tripped by `ext_roundtrip`, probed live for `__eq` and
/// storage behavior. Mixes a positive field, a negative field, and adjust=last.
const sample_interval = ext.Interval{ .year = 1, .day = -3, .sec = 7, .adjust = .last };

/// ext_roundtrip() -> 1 after building {1, uuid, datetime, decimal} via the
/// pure codec and replacing it into space "x". The Lua side reads the row back
/// and asserts each field as its native type.
export fn ext_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const dec = ext.Decimal.fromString(sample_decimal_str) catch return fail("fromString");

    // Replace encodes its argument as a MessagePack array via the SAME pure
    // codec (`msgpack.encode`) that produces each MP_EXT value — so the typed
    // space's acceptance of these bytes is the round-trip proof.
    const s = box.Space.byName("x") catch return fail("byName");
    if (s.replace(.{ @as(u64, 1), sample_uuid, sample_dt, dec, sample_interval })) |maybe| {
        if (maybe) |stored| stored.deinit();
    } else |_| return fail("replace");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// interval_reencode(itv) -> the pure codec's re-encoding of `itv`'s bytes, as
/// a msgpack str. The live byte-oracle for interval: decode the host's
/// MP_EXT bytes with `parseInterval`, re-encode the `ext.Interval` with the pure
/// codec. Lua asserts the result equals `msgpack.encode(itv)` per sample. Any
/// decode/parse failure fails loudly.
export fn interval_reencode(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const v = dec.decodeValue(alloc) catch return fail("interval_reencode: decode");
    defer msgpack.freeValue(alloc, v);
    if (v != .array or v.array.len < 1) return fail("interval_reencode: expected 1-arg array");
    if (v.array[0] != .ext) return fail("interval_reencode: arg not an ext");
    const iv = ext.parseInterval(v.array[0].ext) catch return fail("interval_reencode: parseInterval");

    var buf = msgpack.Buffer.init(alloc);
    defer buf.deinit();
    msgpack.encode(&buf, iv) catch return fail("interval_reencode: encode");
    // Return as msgpack str (not Bin) so Lua receives a plain string it can `==`
    // against msgpack.encode(itv) — avoids varbinary-vs-string equality quirks.
    return proc.returnValue(ctx, @as([]const u8, buf.items()));
}

/// The decimal strings the oracle cross-checks. Mix of zero, positive,
/// negative, integer, trailing-zero (scale-carrying), sub-1 with leading zeros,
/// and the full 38-digit precision.
const oracle_strings = [_][:0]const u8{
    "0",
    "1.5",
    "-12.34",
    "123",
    "1.50",
    "0.001",
    "-0.0007",
    "12345678901234567890123456789012345678",
};

/// dec_oracle() -> the number of strings whose pure encoding is byte-identical
/// to the host's `box_decimal_mp_encode` output. On the first mismatch it
/// fails loudly with the offending string. `box_decimal_mp_encode` writes the
/// FULL msgpack ext value, so we compare it against the full pure encoding of an
/// `ext.Decimal`.
export fn dec_oracle(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    inline for (oracle_strings) |s| {
        // Pure path: parse + encode via the shipped codec.
        const dec = ext.Decimal.fromString(s) catch return fail("pure fromString: " ++ s);
        var buf = msgpack.Buffer.init(alloc);
        defer buf.deinit();
        msgpack.encode(&buf, dec) catch return fail("pure encode: " ++ s);
        const pure = buf.items();

        // Host path: from_string into stack storage, then mp_encode.
        var hdec: c.box_decimal_t = undefined;
        if (c.box_decimal_from_string(&hdec, s.ptr) == null) return fail("host from_string: " ++ s);
        const need = c.box_decimal_mp_sizeof(&hdec);
        var hbuf: [64]u8 = undefined;
        if (need > hbuf.len) return fail("host sizeof too large: " ++ s);
        const hend = c.box_decimal_mp_encode(&hdec, &hbuf);
        const host_len = @intFromPtr(hend) - @intFromPtr(&hbuf[0]);
        const host = hbuf[0..host_len];

        if (!std.mem.eql(u8, pure, host)) return fail("mismatch: " ++ s);
    }

    return proc.returnValue(ctx, @as(i64, oracle_strings.len));
}
