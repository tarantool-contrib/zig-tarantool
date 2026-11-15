//! Integration coverage for the typed `decimal.Decimal`: drives the
//! host-bound arithmetic type, the msgpack ext bridge, and the typed-proc
//! payoff end to end against a live Tarantool (`decimal_test.lua`).
//!
//! Procs (each counter-returning proc returns a small int the Lua driver
//! asserts; the bridge/typed procs are cross-checked against Lua's built-in
//! `decimal` module — the same host library, the truth):
//!   * dec_roundtrip — string round-trip incl. 38-digit precision, trailing-zero
//!     scale, `-0`; invalid strings → `error.InvalidDecimal`.
//!   * dec_arith     — `0.1 + 0.2 == 0.3` exactly, `x - x == 0`, `x * 0 == 0`,
//!     division by zero → `error.DecimalError`.
//!   * dec_inspect   — orderings across sign/scale/precision + isInt/isNeg/scale.
//!   * dec_math      — `sqrt(4) == 2`, `pow(2, 10) == 1024`, `ln(-1)`/`sqrt(-1)`
//!     → `error.DecimalError`.
//!   * dec_bridge    — read the decimal field Lua inserted (hook decode via
//!     `Tuple.get`), double it, `replace` back (hook encode via `replace`).
//!   * dec_add       — a typed `fn(Decimal, Decimal) !Decimal`: the end-to-end
//!     payoff, decimal args in and a decimal out with zero proc.zig changes.
//!   * dec_copy      — `dup` then round the copy; the original is unchanged.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;
const decimal = t.decimal;
const Decimal = decimal.Decimal;

const alloc = std.heap.c_allocator;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Strings that are already in canonical form: `toString(fromString(s)) == s`.
/// Covers zero, positive, negative, trailing-zero scale, sub-1 leading zeros,
/// and the full 38-digit precision.
const canon = [_][:0]const u8{
    "0",
    "1.5",
    "-12.34",
    "123",
    "1.50",
    "0.001",
    "12345678901234567890123456789012345678",
};

/// dec_roundtrip() -> canon.len after asserting every canonical string round
/// trips through `fromString`/`toString`, `-0` compares equal to zero, and each
/// malformed string is rejected with `error.InvalidDecimal` (Design test 1).
export fn dec_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var buf: [decimal.string_buffer_size]u8 = undefined;
    inline for (canon) |s| {
        const d = Decimal.fromString(s) catch return fail("fromString: " ++ s);
        if (!std.mem.eql(u8, d.toString(&buf), s)) return fail("toString mismatch: " ++ s);
    }
    // `-0` canonicalizes to compare-equal to zero.
    const nz = Decimal.fromString("-0") catch return fail("fromString -0");
    const z = Decimal.zero();
    if (nz.order(&z) != .eq) return fail("-0 != 0");
    // Malformed strings are rejected, no silent fallback.
    inline for ([_][:0]const u8{ "", "12.34.56", "abc", "1.2.3" }) |bad| {
        if (Decimal.fromString(bad)) |_| {
            return fail("accepted malformed: " ++ bad);
        } else |e| if (e != error.InvalidDecimal) return fail("wrong error: " ++ bad);
    }
    return proc.returnValue(ctx, @as(i64, canon.len));
}

/// dec_arith() -> 1 (Design test 2): the float-vs-decimal money shot plus
/// identities and the division-by-zero error path.
export fn dec_arith(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const a = Decimal.fromString("0.1") catch return fail("0.1");
    const b = Decimal.fromString("0.2") catch return fail("0.2");
    const three = Decimal.fromString("0.3") catch return fail("0.3");
    const z = Decimal.zero();

    const sum = a.add(&b) catch return fail("add");
    if (sum.order(&three) != .eq) return fail("0.1 + 0.2 != 0.3");

    const diff = a.sub(&a) catch return fail("sub");
    if (diff.order(&z) != .eq) return fail("x - x != 0");

    const prod = a.mul(&z) catch return fail("mul");
    if (prod.order(&z) != .eq) return fail("x * 0 != 0");

    if (a.div(&z)) |_| {
        return fail("division by zero accepted");
    } else |e| if (e != error.DecimalError) return fail("div-by-zero wrong error");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// dec_inspect() -> 1 (Design test 3): inspection + orderings.
export fn dec_inspect(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const frac = Decimal.fromString("-12.340") catch return fail("frac");
    if (!frac.isNeg()) return fail("not neg");
    if (frac.isInt()) return fail("unexpected int");
    if (frac.scale() != 3) return fail("scale != 3");

    const whole = Decimal.fromString("42") catch return fail("whole");
    if (whole.isNeg()) return fail("unexpected neg");
    if (!whole.isInt()) return fail("not int");
    if (whole.scale() != 0) return fail("scale != 0");

    const small = Decimal.fromString("1.5") catch return fail("small");
    const big = Decimal.fromString("1.50001") catch return fail("big");
    const neg = Decimal.fromString("-1") catch return fail("neg");
    if (small.order(&big) != .lt) return fail("1.5 !< 1.50001");
    if (neg.order(&small) != .lt) return fail("-1 !< 1.5");
    if (big.order(&big) != .eq) return fail("x != x");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// dec_math() -> 1 (Design test 4): math ops + domain errors.
export fn dec_math(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const four = Decimal.fromString("4") catch return fail("4");
    const two = Decimal.fromString("2") catch return fail("2");
    const ten = Decimal.fromString("10") catch return fail("10");
    const kib = Decimal.fromString("1024") catch return fail("1024");

    const root = four.sqrt() catch return fail("sqrt");
    if (root.order(&two) != .eq) return fail("sqrt(4) != 2");

    const p = two.pow(&ten) catch return fail("pow");
    if (p.order(&kib) != .eq) return fail("pow(2,10) != 1024");

    const neg = Decimal.fromString("-1") catch return fail("-1");
    if (neg.ln()) |_| {
        return fail("ln(-1) accepted");
    } else |e| if (e != error.DecimalError) return fail("ln wrong error");
    if (neg.sqrt()) |_| {
        return fail("sqrt(-1) accepted");
    } else |e| if (e != error.DecimalError) return fail("sqrt wrong error");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// dec_bridge() -> 1 (Design test 5): read the decimal field Lua inserted into
/// space "dd" (hook decode via `Tuple.get`), double it, and `replace` the row
/// back (hook encode via `replace`'s `msgpack.encode`). No proc.zig changes.
export fn dec_bridge(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = box.Space.byName("dd") catch return fail("byName dd");
    var row = (s.get(.{@as(u64, 1)}) catch return fail("get")) orelse return fail("no row");
    defer row.deinit();
    const d = (row.get(1, Decimal, alloc) catch return fail("field decode")) orelse return fail("no field");

    const two = Decimal.fromInt(2);
    const doubled = d.mul(&two) catch return fail("mul");
    s.replaceDiscard(.{ @as(u64, 1), doubled }) catch return fail("replace");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// Typed proc (Design test 6): decimal args in, a decimal out. The whole
/// round-trip rides the structural codec hook — `exportProc` decodes the args
/// tuple and encodes the result through `msgpack`, with zero proc.zig changes.
fn decAdd(a: Decimal, b: Decimal) !Decimal {
    return a.add(&b);
}

/// dec_copy() -> 1 (Design test 7): `dup` then round the copy; the original is
/// unchanged (value semantics / copy discipline).
export fn dec_copy(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const d = Decimal.fromString("1.999") catch return fail("1.999");
    const copy = d.dup();
    const rounded = copy.round(0) catch return fail("round");

    // The copy rounded to a different value...
    if (rounded.order(&d) == .eq) return fail("round was a no-op");
    // ...while the original still equals a fresh parse (untouched).
    const fresh = Decimal.fromString("1.999") catch return fail("fresh");
    if (d.order(&fresh) != .eq) return fail("original mutated");
    if (d.scale() != 3) return fail("original scale changed");

    return proc.returnValue(ctx, @as(i64, 1));
}

comptime {
    proc.exportProc("dec_add", decAdd);
}
