# Lifetimes

Zig has no garbage collector, and Tarantool owns much of the memory that a
module touches: tuples, the fiber region, the error of the last call. This page
says who owns each buffer, how long it lives, and which functions copy for you.

## Tuples

A tuple is memory of Tarantool, counted by references. A `box.Tuple` holds one
reference, and `deinit` releases it.

- **A tuple returned by a read or a write is yours.** `Space.get`, `insert`,
  `replace`, `delete`, `update`, `Index.get`, `min`, `max`, `random`,
  `Iterator.next` and `Index.select` hand back tuples with a reference you
  own. Call `deinit` once you are done:

  ```zig
  if (try space.get(.{key})) |row| {
      defer row.deinit();
      // read row here
  }
  ```

- **A tuple you do not need is still yours.** `replace` returns the stored
  tuple, so `_ = try space.replace(...)` leaks a reference. Release it, or use
  the `*Discard` variant, which runs the same operation and releases the result:
  `insertDiscard`, `replaceDiscard`, `deleteDiscard`, `updateDiscard`,
  `upsertDiscard`.

- **A tuple from a `Cursor` is borrowed.** `Index.cursor` yields tuples it
  releases itself, at the next `next` or at `deinit`. Copy out what must outlive
  that.

- **A string read from a tuple is a slice of the tuple.** `Tuple.get(i,
  []const u8, alloc)`, `Tuple.decode` and `Tuple.decodeRow` return slices into
  the tuple's data; they are valid while you hold the tuple. `dupe` them to keep
  them longer.

The typed functions copy for you: `box.Typed(Row).get`, `Range(Row).next` and
`Index.top` copy every string field of the row into the allocator you pass, and
release the tuple before they return. `Typed(Row).free`, `Range(Row).free` and
`Range(Row).freeSlice` free those copies.

## The fiber region

The region is a per-fiber stack of scratch memory in Tarantool.
`tarantool.region.allocator()` allocates on it; its `free` does nothing.
Tarantool reclaims the region of a stored procedure when the call ends, so
memory a procedure allocates there needs no free, and a procedure may return a
string that lives there:

```zig
fn greet(name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(t.region.allocator(), "Hello, {s}!", .{name});
}
```

A loop that allocates on the region on each step grows it until the call ends.
`region.Savepoint` gives the memory back earlier:

```zig
for (keys) |key| {
    const svp = t.region.Savepoint.save();
    defer svp.restore(); // everything allocated on the region since save()
    const scratch = try t.region.allocator().alloc(u8, 4096);
    _ = scratch;
    _ = key;
}
```

The box operations encode their arguments on the region under a savepoint of
their own, and restore it before they return. A function that takes an allocator
and may be given the region, such as `Tuple.new(values, alloc)`, takes no
savepoint: if you pass `region.allocator()`, the savepoint is yours.

A fiber you spawn has a region of its own, which Tarantool frees when the fiber
ends. In a fiber that runs for long, bound every use of the region with a
savepoint.

## Arguments of a stored procedure

The arguments of a call are a buffer of Tarantool that lives until the call
returns. A typed procedure's `[]const u8` parameters are slices of it: use them
during the call, and copy what you store elsewhere. Storing it in a space copies
it, so `space.replace(.{ key, value })` needs no copy.

A Lua function made by `lua.exportModule` gets its `[]const u8` arguments copied
to the region, because a Lua string lives only while it is on the Lua stack.

## Errors of Tarantool

When a box operation fails, it returns `error.BoxOp`, and the message is in the
error of the fiber, in Tarantool: `tarantool.err.lastError()` points to it. That
pointer is valid until the next box call replaces the error.
`err.lastMessage(&buf)` copies the message into a buffer of yours.

## Fiber objects

`fiber.Channel`, `cond.Cond`, `latch.Latch` and `fiber.FiberAttr` own memory of
Tarantool and free it in `deinit`. Free them only when no fiber waits on them:
join the fibers that use a channel before its `deinit`. In a debug build,
`Channel.deinit` and `Latch.deinit` check this and panic.

A `fiber.Fiber(T)` handle owns the result slot of the fiber, which `join` frees.
Join it exactly once.

## The network client

A connection reads each reply into its own buffer, and decoded values borrow it:

- A `[]const u8` in the result of `call`, `eval`, `get`, `insert`, `select`
  and the rest is valid until the next request on the same connection.
- `select` returns a slice you free with the allocator you passed; the strings
  in its rows still borrow the connection's buffer.
- The results of a `Batch` live in the batch, until its `deinit`.
- A watcher event lives until the next `waitEvent` or `pollEvent`.

Copy what must live longer, as the proxy example does before it closes its
connection:

```zig
const row = try conn.space("kv").get(.{key}, struct { []const u8, []const u8 }) orelse return null;
return try t.region.allocator().dupe(u8, row[1]);
```

`conn.last_error` belongs to the connection until the next error or `close`.
