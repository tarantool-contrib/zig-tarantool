# zig-tarantool

zig-tarantool lets you write Tarantool code in Zig. You can write stored
procedures and Lua modules that run inside the Tarantool process, and programs
that talk to Tarantool over the network.

> **Pre-release.** The package has no versions yet: depend on it at a commit,
> and expect its API to change between commits.

## What it does

- **Stored procedures in Zig.** A plain Zig function becomes a
  `language = 'C'` function of Tarantool. Its arguments are decoded from
  MessagePack by the types of its parameters, its result is encoded back, and a
  Zig error it returns fails the call.
- **The box API in Zig.** Spaces, indexes, tuples, transactions, sequences,
  fibers, channels, triggers, decimals and the logger, typed and with explicit
  lifetimes, over the C API of Tarantool (`module.h`).
- **Lua modules in Zig.** A struct of Zig functions becomes a module that
  `require()` loads, with Lua values converted to Zig types and back.
- **A network client.** An iproto connector for programs outside Tarantool:
  CRUD, calls, pipelined batches, the schema, watchers and interactive
  transactions. It runs over any `std.Io`, including one that makes a stored
  procedure yield its fiber while it waits for the network.

## Try it

A stored procedure:

```zig
const t = @import("tarantool");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

comptime {
    t.proc.exportProc("add", add);
}
```

built into `hello.so` and called from Tarantool:

```lua
box.schema.func.create('hello.add', { language = 'C' })
box.func['hello.add']:call({ 1, 2 }) -- 3
```

[Your first module](get-started/first-module.md) walks through it, from an
empty directory to the call.

## Where to go

- [Get started](get-started/install.md): install the tools, build a module,
  write a client program, build a module as part of a tt package.
- [Concepts](concepts/layers.md): the modules of the package, how Zig values
  map to MessagePack, who owns what, and how fibers yield.
- [How-to](how-to/stored-procedures.md): stored procedures, spaces and
  indexes, transactions, fibers, Lua modules, the network client, triggers,
  logging, decimals, building with tt.
- [Reference](reference/build.md): the build helpers and steps, the API by
  module, the errors.
- [Project](project/testing.md): how the package is tested, and what does not
  work yet.

The [examples](https://github.com/tarantool-contrib/zig-tarantool/tree/master/examples)
directory holds complete modules, each with a luatest suite that runs it
against a live Tarantool.
