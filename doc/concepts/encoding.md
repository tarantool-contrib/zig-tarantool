# Encoding

Tarantool stores tuples and passes arguments as MessagePack. The `msgpack` module
encodes and decodes Zig values by their types, at compile time. The stored
procedures, the box API and the client all go through it. This page lists what
each Zig type becomes, and what decodes into it.

The rule is that nothing is guessed: a value of the wrong type is an error,
never a conversion.

## Zig to MessagePack

| Zig value | MessagePack |
|-----------|-------------|
| `bool` | bool |
| an integer type | int, in the shortest form; a non-negative value of a signed type is written as unsigned, as Tarantool does |
| `f32`, `f64` | float 64 |
| `[]const u8`, `[N]u8`, `*const [N]u8` (a string literal) | str |
| `msgpack.Bin{ .bytes = b }` | bin |
| a slice or an array of anything else | array |
| a tuple struct, `.{ a, b }` | array, the fields in order |
| a named struct, `struct { id: u64, name: []const u8 }` | map, the field names as keys |
| `?T` | `T`, or nil for `null` |
| `void`, `null` | nil |
| an `enum` | its integer value |
| `msgpack.Value` | the value it holds |
| `msgpack.ext.Uuid`, `Datetime`, `Decimal`, `Interval`, `Ext` | the extension type of Tarantool, see [Decimals and extensions](../how-to/decimals-and-extensions.md) |
| `tarantool.decimal.Decimal` | the decimal extension |

A tuple of Tarantool is a MessagePack array, so a row or a key is a tuple
struct: `.{ 1, "alice" }`, `.{key}`. A named struct encodes as a map, which is
not a tuple. The functions that take a row, such as `box.Typed(Row).put`, encode
the named struct `Row` as an array instead, the fields in their declaration
order.

## MessagePack to Zig

`msgpack.decode(T, &decoder)` reads exactly one value into `T`:

| Zig type | Accepts | Fails with |
|----------|---------|------------|
| `bool` | bool | `NotBool` |
| an integer type | int or uint that fits the type | `NotInt`, `Overflow` |
| `f32`, `f64` | float 32 or float 64 | `NotFloat` |
| `[]const u8` | str | `NotStr` |
| `msgpack.Bin` | bin | `NotBin` |
| `[N]T` | an array of exactly N elements | `NotArray`, `ArityMismatch` |
| a tuple struct | an array with one element per field | `NotArray`, `ArityMismatch` |
| a named struct | a map whose keys are field names | `NotMap`, `UnknownField`, `MissingField` |
| `?T` | nil, as `null`, or what `T` accepts | |
| an `enum` | its integer value | |
| `msgpack.ext.Ext` | any extension | `NotExt` |

A few consequences:

- **An integer is not a float.** Lua writes a number that has no fractional part
  as an integer, so `box.func['m.f']:call({ 1 })` fails on an `f64` parameter
  with `NotFloat`, and so does `1.0`. A parameter that takes both needs the
  dynamic `msgpack.Value`, decoded in a raw procedure, see
  [Stored procedures](../how-to/stored-procedures.md#raw-procedures).
- **A string is not binary.** A `[]const u8` takes a str only; a varbinary field
  of Tarantool is a bin and decodes into `msgpack.Bin`.
- **A named struct is strict.** A key of the map that names no field is
  `UnknownField`. A field missing from the map is `MissingField`, unless it is
  optional, then it is `null`.
- **Slices other than strings do not decode.** `msgpack.decode` allocates
  nothing, so it decodes fixed shapes only: `[]i64` is a compile error. For
  arrays of unknown length use `msgpack.Value` or walk the array with the
  `Decoder`.

## Borrowed strings

Decoding allocates nothing: a decoded `[]const u8` is a slice of the input
buffer. So a string decoded from a tuple lives as long as the tuple, and one
decoded from a network reply lives until the next request on the connection.
[Lifetimes](lifetimes.md) lists who owns each buffer, and the functions that
copy for you.

## Dynamic values

`msgpack.Value` holds any MessagePack value:

```zig
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
```

`decoder.decodeValue(gpa)` decodes into it; the arrays and maps are allocated
with `gpa`, and `msgpack.freeValue(gpa, value)` frees them. The strings borrow
the input, as above. `Tuple.field(i, alloc)` returns a field of a tuple as a
`Value`.

## The codec on its own

```zig
const msgpack = @import("msgpack"); // or @import("tarantool").msgpack in a module

var buf = msgpack.Buffer.init(gpa);
defer buf.deinit();
try msgpack.encode(&buf, .{ 1, "alice", true });

var dec = msgpack.Decoder.init(buf.items());
const row = try msgpack.decode(struct { u64, []const u8, bool }, &dec);
```

`msgpack.Buffer` is a growable byte buffer; `encode` writes to anything with
`writeByte` and `writeAll`. `msgpack.encodeArray(w, value)` writes any struct as
an array, and `msgpack.decodeArray(T, &dec)` reads one into a named struct.

A struct can define its own encoding: if it declares
`pub fn mpEncode(self, w: anytype) !void` and
`pub fn mpDecode(dec: *msgpack.Decoder) msgpack.DecodeError!Self`, `encode` and
`decode` call them. `tarantool.decimal.Decimal` uses this.
