# Decimals and extensions

Tarantool stores decimals, UUIDs, datetimes and intervals as MessagePack
extensions. The SDK computes with decimals through the C API of Tarantool, and
the `msgpack` module encodes and decodes all four. This page shows both in the
module `money`.

## The module

`src/money.zig`:

```zig
//! money: decimal arithmetic, and the extension types of Tarantool.

const t = @import("tarantool");
const Decimal = t.decimal.Decimal;
const ext = t.msgpack.ext;

/// money.total(price, qty, tax_percent) -> price * qty * (1 + tax_percent / 100),
/// rounded to cents.
fn total(price: Decimal, qty: u32, tax_percent: Decimal) !Decimal {
    const hundred = Decimal.fromInt(100);
    const one = Decimal.fromInt(1);
    const rate = try (try tax_percent.div(&hundred)).add(&one);
    const amount = try price.mul(&Decimal.fromUint(qty));
    return (try amount.mul(&rate)).round(2);
}

/// money.split(amount, n) -> the share of each of n, rounded down to cents.
fn split(amount: Decimal, n: u32) !Decimal {
    return (try amount.div(&Decimal.fromUint(n))).floor(2);
}

/// money.cents(amount) -> the amount in cents, as an integer.
fn cents(amount: Decimal) !i64 {
    return (try amount.mul(&Decimal.fromInt(100))).toInt();
}

/// money.uuid_version(uuid) -> the version of a UUID.
fn uuidVersion(e: ext.Ext) !u8 {
    const u = try ext.parseUuid(e);
    return u.bytes[6] >> 4;
}

/// money.epoch(datetime) -> its Unix time, in seconds.
fn epoch(e: ext.Ext) !i64 {
    return (try ext.parseDatetime(e)).seconds;
}

/// money.nil_uuid() -> 00000000-0000-0000-0000-000000000000
fn nilUuid() ext.Uuid {
    return .{ .bytes = @splat(0) };
}

comptime {
    t.proc.exportProc("total", total);
    t.proc.exportProc("split", split);
    t.proc.exportProc("cents", cents);
    t.proc.exportProc("uuid_version", uuidVersion);
    t.proc.exportProc("epoch", epoch);
    t.proc.exportProc("nil_uuid", nilUuid);
}
```

```lua
local decimal = require('decimal')
for _, name in ipairs({ 'total', 'split', 'cents', 'uuid_version', 'epoch', 'nil_uuid' }) do
    box.schema.func.create('money.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['money.' .. name]:call({ ... })
end

call('total', decimal.new('19.99'), 3, decimal.new('20'))   -- 71.96
call('split', decimal.new('100'), 3)                        -- 33.33
call('cents', decimal.new('12.34'))                         -- 1234
call('total', 19.99, 3, decimal.new('20'))                  -- error: NotExt
call('uuid_version', require('uuid').new())                 -- 4
call('epoch', require('datetime').new({ year = 2026, month = 1, day = 1 })) -- 1767225600
call('nil_uuid')                                            -- 00000000-0000-0000-0000-000000000000
```

## Decimals

`tarantool.decimal.Decimal` is the decimal of Tarantool, up to 38 digits, with
its arithmetic. It is a value: every operation returns a new decimal.

| Group | Functions |
|-------|-----------|
| Make | `zero()`, `fromInt(i64)`, `fromUint(u64)`, `fromFloat(f64)`, `fromString(s)` |
| Convert | `toInt()`, `toUint()`, `toString(&buf)` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `rem`, `pow`, `neg`, `abs` |
| Functions | `sqrt`, `ln`, `log10`, `exp` |
| Rounding | `round(scale)`, half away from zero; `floor(scale)`, toward zero; `rescale(scale)`; `trim()` |
| Inspect | `order(&other)`, `precision()`, `scale()`, `isInt()`, `isNeg()` |

The binary operations take the other operand by pointer: `a.add(&b)`. A result
out of range, a division by zero or a logarithm of a negative fails with
`error.DecimalError`; a string or a float that is no decimal with
`error.InvalidDecimal`; `toInt` of a decimal too large with `error.Overflow`.

`toString` writes into a buffer of `decimal.string_buffer_size` bytes:

```zig
var buf: [t.decimal.string_buffer_size]u8 = undefined;
const text = amount.toString(&buf); // [:0]const u8
```

A `Decimal` encodes as the decimal extension, and decodes from it only: a stored
procedure that takes one fails on a plain number with `NotExt`, as the fourth
call above does. A Lua function of [`lua.exportModule`](lua-modules.md) takes
and returns the `decimal` of Lua.

`Decimal` needs Tarantool to compute, so it lives in the `tarantool` module.
`msgpack.ext.Decimal`, in `msgpack`, carries the digits of a decimal without
computing with them, for the network client: `fromString`, `toString`, and it
encodes as the extension.

## UUIDs, datetimes, intervals

`msgpack.ext` has a type for each extension of Tarantool:

| Type | Extension | Fields |
|------|-----------|--------|
| `ext.Uuid` | UUID, 2 | `bytes: [16]u8` |
| `ext.Datetime` | datetime, 4 | `seconds`, `nsec`, `tzoffset` in minutes, `tzindex` |
| `ext.Interval` | interval, 6 | `year`, `month`, `week`, `day`, `hour`, `min`, `sec`, `nsec`, `adjust` |
| `ext.Decimal` | decimal, 1 | the digits, the scale and the sign |
| `ext.Ext` | any | `type`, the code, and `data`, the payload |

Each of them encodes as its extension. To decode, take an `ext.Ext` and parse
it: `ext.parseUuid(e)`, `ext.parseDatetime(e)`, `ext.parseInterval(e)`,
`ext.parseDecimal(e)`. Each fails when the extension is of another type, and
`e.kind()` tells the type. A field of a tuple read with `Tuple.field` is a
`msgpack.Value` whose `.ext` holds the same `Ext`.
