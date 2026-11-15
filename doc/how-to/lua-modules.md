# Lua modules

A module can be a Lua module too: `require('geo')` loads `geo.so` and calls its
`luaopen_geo`, which returns a table of functions. `lua.exportModule` makes that
entry point from a struct of Zig functions. This page writes one, with typed
functions and a raw one.

## The module

`src/geo.zig`:

```zig
//! geo: a Lua module of plain Zig functions.

const std = @import("std");
const t = @import("tarantool");
const lua = t.lua;

const Point = struct { lat: f64, lon: f64 };

/// geo.distance(a, b) -> the great-circle distance in km.
fn distance(a: Point, b: Point) f64 {
    const rad = std.math.pi / 180.0;
    const dlat = (b.lat - a.lat) * rad;
    const dlon = (b.lon - a.lon) * rad;
    const h = std.math.pow(f64, @sin(dlat / 2), 2) +
        @cos(a.lat * rad) * @cos(b.lat * rad) * std.math.pow(f64, @sin(dlon / 2), 2);
    return 2 * 6371.0 * std.math.asin(@sqrt(h));
}

/// geo.bounds(points) -> the south-west corner, the north-east corner.
fn bounds(points: []const Point) !lua.Multi(struct { Point, Point }) {
    if (points.len == 0) return error.NoPoints;
    var sw = points[0];
    var ne = points[0];
    for (points[1..]) |p| {
        sw = .{ .lat = @min(sw.lat, p.lat), .lon = @min(sw.lon, p.lon) };
        ne = .{ .lat = @max(ne.lat, p.lat), .lon = @max(ne.lon, p.lon) };
    }
    return lua.multi(.{ sw, ne });
}

/// geo.parse('55.75,37.62') -> {55.75, 37.62}, or nil.
fn parse(s: []const u8) ?struct { f64, f64 } {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const lat = std.fmt.parseFloat(f64, s[0..comma]) catch return null;
    const lon = std.fmt.parseFloat(f64, s[comma + 1 ..]) catch return null;
    return .{ lat, lon };
}

/// geo.name(tuple) -> field 2 of a box.tuple.
fn name(row: t.box.Tuple) ![]const u8 {
    return (try row.get(1, []const u8, std.heap.c_allocator)) orelse error.NoName;
}

/// geo.nargs(...) -> the number of arguments: a raw lua_CFunction.
fn nargs(L: ?*t.c.lua_State) callconv(.c) c_int {
    const l = lua.Lua.init(L.?);
    l.pushInt64(l.top());
    return 1;
}

comptime {
    lua.exportModule("geo", .{
        .distance = distance,
        .bounds = bounds,
        .parse = parse,
        .name = name,
        .nargs = nargs,
    });
}
```

```lua
local geo = require('geo')

math.floor(geo.distance({ lat = 55.75, lon = 37.62 }, { lat = 59.94, lon = 30.31 })) -- 635
geo.bounds({ { lat = 1, lon = 5 }, { lat = 3, lon = 2 } }) -- {lat = 1, lon = 2}, {lat = 3, lon = 5}
geo.bounds({})                                  -- error: NoPoints
geo.parse('55.75,37.62')                        -- {55.75, 37.62}
geo.parse('north')                              -- nil
geo.name(box.tuple.new({ 7, 'Moscow' }))        -- Moscow
geo.nargs(1, 'a', nil)                          -- 3
geo.distance({ lat = 1 }, { lat = 2, lon = 2 }) -- error: TypeMismatch
```

`exportModule(name, defs)` exports `luaopen_<name>`, which builds a table with
one function per field of `defs`. Lua looks for the module as it does for any
C module: `geo.so`, or `geo.dylib` on macOS, on `package.cpath`. A module may
export both stored procedures and `luaopen_<name>`.

## Typed functions

A field of `defs` that is a plain Zig function is wrapped: its arguments are
read from the Lua stack by the types of its parameters, and its result is
pushed back.

| Zig parameter | Takes |
|---------------|-------|
| `bool` | a boolean |
| `f32`, `f64` | a number |
| an integer type | a number, or an `int64_t` or `uint64_t` cdata, in range; else `error.Overflow` |
| `[]const u8` | a string, copied to the fiber region |
| `[]T` | a table used as an array |
| a tuple struct | a table used as an array, one element per field |
| a named struct | a table, a key per field |
| `?T` | nil, or what `T` takes |
| `box.Tuple` | a `box.tuple` |
| `decimal.Decimal` | a decimal |

| Zig result | Lua value |
|------------|-----------|
| `bool`, `f32`, `f64` | a boolean, a number |
| a signed integer type | an `int64_t` cdata |
| an unsigned integer type | a `uint64_t` cdata |
| `[]const u8` | a string |
| `[]T`, a tuple struct | an array table |
| a named struct | a table with a key per field |
| `?T` | nil for `null` |
| `box.Tuple` | a `box.tuple`; the wrapper releases the reference you return |
| `decimal.Decimal` | a decimal |
| `lua.Multi(struct { A, B })` | two values, `A` and `B` |
| `void` | nothing |

- **The arity is exact.** A call with a different number of arguments fails
  with `ArityMismatch`, even when the missing ones are optional: pass nil.
- **The types are exact.** A string where a number is expected fails with
  `TypeMismatch`, and so does a missing key of a named struct whose field is
  not optional.
- **Integers are 64-bit cdata.** They compare equal to Lua numbers:
  `geo.nargs(1, 2) == 2` is true. `tonumber()` turns one into a number.
- **The fiber region holds the scratch.** Strings and arrays taken from Lua,
  and anything `f` allocates on the region, live until the function returns;
  the wrapper restores the region after it pushed the result.
- **Errors are Lua errors.** A Zig error returned by `f` is raised with its
  name. `error.BoxOp` is raised with the message of Tarantool, for example
  `Duplicate key exists in unique index "pk"`.

### Several results

`lua.Multi(T)`, where `T` is a tuple struct, returns each field as a value of
its own. `lua.multi(.{ a, b })` builds one when every element is known at run
time only. With a constant element, such as a string literal, declare the type
and fill `.values`:

```zig
fn nameAge() lua.Multi(struct { []const u8, i64 }) {
    return .{ .values = .{ "bob", 30 } };
}
```

A plain tuple struct, without `Multi`, returns one array table, as `parse`
does.

## Raw functions

A field of `defs` whose type is `fn (?*c.lua_State) callconv(.c) c_int` is
registered as it is: a `lua_CFunction`, which reads its arguments from the Lua
stack, pushes its results and returns their number. `lua.Lua.init(L.?)` wraps
the state with the stack operations:

| Method | Does |
|--------|------|
| `top()`, `typeOf(i)`, `pop(n)` | the number of values, the type of one, pop |
| `pushNil`, `pushBool`, `pushNumber`, `pushInt64`, `pushUint64`, `pushLString` | push a value |
| `toBool`, `toNumber`, `toInt64`, `toUint64`, `toLString` | read a value; none of them raises |
| `newTable`, `getField`, `setField`, `rawGetI`, `rawSetI`, `objLen` | tables |
| `raise(message)` | raise a Lua error; it does not return |

`raise` jumps out of the function with `longjmp`, past any `defer` of the
Zig frames in between. Raise only from the outermost frame of the function,
after everything that needs a cleanup has run; `lua.raiseErr(l, err)` raises a
Zig error the way the typed wrapper does.
