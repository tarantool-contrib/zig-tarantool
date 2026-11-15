# Known issues

What does not work yet, or works in a way that may surprise you. Open work is
tracked in the
[GitHub issues](https://github.com/tarantool-contrib/zig-tarantool/issues).

## Platforms and versions

- **Modules need Tarantool 3.5.** On 3.0 to 3.4 a module fails to load with an
  undefined symbol, such as `box_tuple_data`. The network client works with 3.0
  and later.
- **macOS is tested against one Tarantool.** Homebrew has one version of
  Tarantool, so CI runs the suite on macOS against that one; macOS on Intel is
  built, not run.
- **No releases.** The package has no versions; depend on a commit.

## Stored procedures and Lua functions

- **An integer does not decode into a float.** An `f64` parameter fails with
  `NotFloat` on `1`, and Lua sends every whole number as an integer, `1.0`
  included. Pass a fraction, or take the argument as a `msgpack.Value` in a raw
  procedure. Lua functions of `lua.exportModule` are not affected: they read Lua
  numbers.
- **A typed procedure loses the message of Tarantool.** A typed procedure that
  returns `error.BoxOp` fails with the message `BoxOp`; a raw procedure and a
  Lua function report the message Tarantool set.
- **Arguments have an exact arity.** An optional parameter still takes an
  argument: pass `box.NULL`, since a `nil` at the end of a Lua table is not in
  it.
- **Slices do not decode.** A typed procedure cannot take `[]T` other than a
  string; a Lua function can.

## The box API

- **No DDL.** There is no API to create spaces or indexes: do it in Lua
  ([#8](https://github.com/tarantool-contrib/zig-tarantool/issues/8)).
- **No `Index.deleteRange`** of Tarantool 3.9 yet
  ([#3](https://github.com/tarantool-contrib/zig-tarantool/issues/3)).
- **Triggers go through Lua.** The triggers of spaces and transactions are
  registered on the Lua state of the instance, since the C API has none.

## The network client

- **The address is an IP address.** `host:port` takes a numeric host; resolve
  names first.
- **Only `chap-sha1`.** No `pap-sha256` and no TLS
  ([#2](https://github.com/tarantool-contrib/zig-tarantool/issues/2)).
- **No SQL** ([#6](https://github.com/tarantool-contrib/zig-tarantool/issues/6))
  and **no pagination** of `select`
  ([#7](https://github.com/tarantool-contrib/zig-tarantool/issues/7)).
- **One request at a time.** A connection waits for each reply; use a `Batch` to
  send several. Two fibers or threads must not share a connection without a
  lock.
- **No background reader.** Watcher events arrive only while you call into the
  connection
  ([#15](https://github.com/tarantool-contrib/zig-tarantool/issues/15)).
- **Streams take no options.** `begin` sends no isolation level or timeout, and
  calls and batches cannot join a stream
  ([#14](https://github.com/tarantool-contrib/zig-tarantool/issues/14)).
- **Index handles read only.** `space.index(name)` has `get` and `select`; an
  update or a delete goes through the primary key.
- **`decodeRow` takes one tuple.** It needs the MessagePack of a single tuple,
  while the raw requests return the array of the reply.

## Inside Tarantool

- **`fiberio.io()` does the network only.** Files, timers, `async` and the rest
  of `std.Io` panic with the name of the operation. An evented `std.Io` example
  is open work
  ([#1](https://github.com/tarantool-contrib/zig-tarantool/issues/1)).
- **`symresolve` needs a symbol table.** On a stripped executable it resolves
  nothing.
