# Stored procedures

A stored procedure of a module is a C function that Tarantool calls as
`<module>.<symbol>`. This page writes procedures with `proc.exportProc`, which
derives the C function from a plain Zig function, and with `proc.exportRaw`,
which leaves the arguments and the results to you. It extends the module of
[Your first module](../get-started/first-module.md).

## Typed procedures

`src/procs.zig`:

```zig
//! procs: the shapes a typed stored procedure can take.

const std = @import("std");
const t = @import("tarantool");

/// procs.clamp(x, lo, hi) -> x limited to [lo, hi], or the error EmptyRange.
fn clamp(x: i64, lo: i64, hi: i64) !i64 {
    if (lo > hi) return error.EmptyRange;
    return std.math.clamp(x, lo, hi);
}

/// procs.parse_u64(s) -> the number, or nil when s is not one.
fn parseU64(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

const Point = struct { x: i64, y: i64 };

/// procs.mid({x=, y=}, {x=, y=}) -> {x=, y=}: maps in, a map out.
fn mid(a: Point, b: Point) Point {
    return .{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) };
}

/// procs.swap({a, b}) -> {b, a}: an array in, an array out.
fn swap(pair: struct { []const u8, []const u8 }) struct { []const u8, []const u8 } {
    return .{ pair[1], pair[0] };
}

/// procs.label(n, unit) -> '<n> <unit>', or '<n>' when unit is nil.
fn label(n: i64, unit: ?[]const u8) ![]const u8 {
    const region = t.region.allocator();
    if (unit) |u| return std.fmt.allocPrint(region, "{d} {s}", .{ n, u });
    return std.fmt.allocPrint(region, "{d}", .{n});
}

comptime {
    t.proc.exportProc("clamp", clamp);
    t.proc.exportProc("parse_u64", parseU64);
    t.proc.exportProc("mid", mid);
    t.proc.exportProc("swap", swap);
    t.proc.exportProc("label", label);
}
```

Each `exportProc(name, f)` exports a C symbol `name` that:

1. decodes the argument array of the call into the parameters of `f`, by their
   types, as [Encoding](../concepts/encoding.md#messagepack-to-zig) lists;
2. calls `f`;
3. encodes the result as the value the call returns, or fails the call with the
   name of the Zig error that `f` returned.

The C symbol can differ from the Zig name: `parseU64` is exported as
`parse_u64`. Put the `exportProc` calls in a `comptime` block of the root
source file of the module, or of a file it imports.

## Declare and call them

```lua
for _, name in ipairs({ 'clamp', 'parse_u64', 'mid', 'swap', 'label' }) do
    box.schema.func.create('procs.' .. name, { language = 'C', if_not_exists = true })
end

local function call(name, ...)
    return box.func['procs.' .. name]:call({ ... })
end

call('clamp', 15, 0, 10)                   -- 10
call('clamp', 1, 10, 0)                    -- error: EmptyRange
call('parse_u64', '42')                    -- 42
call('parse_u64', 'forty-two')             -- nil
call('mid', { x = 0, y = 0 }, { x = 4, y = 2 }) -- {x = 2, y = 1}
call('swap', { 'a', 'b' })                 -- {'b', 'a'}
call('label', 3, 'kg')                     -- '3 kg'
call('label', 3, box.NULL)                 -- '3'
```

The same functions are callable over the network: `conn:call('procs.clamp',
{15, 0, 10})` in net.box, `conn.call("procs.clamp", .{ 15, 0, 10 }, i64)` in the
Zig client. A user other than admin needs the right to execute them:

```lua
box.schema.user.grant('app', 'execute', 'function', 'procs.clamp')
```

Creating a `language = 'C'` function needs `execute` on `universe` since
Tarantool 3.7.2, 3.8.2 and 3.9.0; create them as admin.

## Arguments

- **The arity is exact.** A call with fewer or more arguments than `f` has
  parameters fails with `wrong argument count`, and `f` is not called.
- **An optional parameter still takes an argument.** `?T` accepts nil, but the
  nil must be there: in Lua, `{3, nil}` is a table of one element, so pass
  `box.NULL`, as the `label` call above does.
- **The types are exact.** A string where `f` takes an integer fails with
  `NotInt`; an integer where it takes `f64` fails with `NotFloat`. See
  [Encoding](../concepts/encoding.md#messagepack-to-zig).
- **A string argument is borrowed.** It is a slice of the request, valid until
  the procedure returns.

## Results

| `f` returns | The call returns |
|-------------|------------------|
| a value | that value, encoded |
| `?T` | the value, or nil for `null` |
| `void`, `!void` | nothing |
| `!T` | the value, or fails with the error |

A procedure returns one value. To return several, or a tuple, write a raw one.

A result allocated on the fiber region, as `label` does, needs no free: the
wrapper encodes it before Tarantool reclaims the region.

## Errors

A Zig error returned by a typed procedure fails the call: Tarantool raises a
`ClientError` with code 102, `ER_PROC_C`, and the name of the error as its
message. A box operation that fails returns `error.BoxOp`, which a typed
procedure reports as `BoxOp`. To keep the message of Tarantool instead, for
example `Duplicate key exists in unique index "pk"`, write a raw procedure with
`exportRaw`: it reports `error.BoxOp` with the error Tarantool set.

## Raw procedures

A raw procedure has the C signature of a stored procedure: it gets the arguments
as a MessagePack array, between `args` and `args_end`, and returns its results
through `ctx`. Each `proc.returnValue(ctx, value)` adds one value to the
results; `proc.returnTuple(ctx, tuple)` adds a tuple.

`src/stats.zig`:

```zig
//! stats.stats(...) -> count, sum, mean of any numbers, integers or floats.

const std = @import("std");
const t = @import("tarantool");
const msgpack = t.msgpack;

fn stats(ctx: ?*t.c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) !c_int {
    const gpa = std.heap.c_allocator;
    var dec = msgpack.Decoder.init(args[0 .. @intFromPtr(args_end) - @intFromPtr(args)]);
    const all = try dec.decodeValue(gpa);
    defer msgpack.freeValue(gpa, all);

    if (all.array.len == 0) return t.proc.fail(error.NoNumbers, "stats() needs at least one number");

    var sum: f64 = 0;
    for (all.array) |v| sum += switch (v) {
        .uint => |u| @floatFromInt(u),
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.NotANumber,
    };
    const n: f64 = @floatFromInt(all.array.len);

    // Three results: each returnValue adds one.
    if (t.proc.returnValue(ctx, all.array.len) != 0) return -1;
    if (t.proc.returnValue(ctx, sum) != 0) return -1;
    return t.proc.returnValue(ctx, sum / n);
}

comptime {
    t.proc.exportRaw("stats", stats);
}
```

```lua
box.schema.func.create('stats.stats', { language = 'C', if_not_exists = true })
box.func['stats.stats']:call({ 1, 2, 4.5 })   -- 3, 7.5, 2.5
box.func['stats.stats']:call({})              -- error: stats() needs at least one number
box.func['stats.stats']:call({ 1, 'two' })    -- error: NotANumber
```

`exportRaw(name, f)` exports `f`, which returns `!c_int`: 0 on success, or -1
after it set an error. When `f` returns a Zig error, the wrapper fails the call:

- with the error Tarantool set, for `error.BoxOp`;
- with the name of the error, for any other error.

`proc.fail(e, message)` does the same with a message of your own and returns
-1. To fail with an error code of your choice, set it and return -1:

```zig
t.err.setBoxError(t.c.ER_PROC_C, "out of stock");
return -1;
```

A raw procedure decides how to decode its arguments, so it can take what a
typed one cannot: a variable number of arguments, or a value of either type, as
`stats` takes integers and floats as `msgpack.Value`.

## Next

- [Spaces and indexes](spaces-and-indexes.md): read and write data, and return
  tuples.
- [Transactions](transactions.md): make several writes atomic.
- [Errors](../reference/errors.md): every error of the SDK and how it reaches
  the caller.
