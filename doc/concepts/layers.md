# Modules and layers

zig-tarantool is four Zig modules in one package. Inside them, every typed API
sits on a raw one that you can use directly. This page describes both
structures.

## The four modules

| Module | Imports | What it is |
|--------|---------|------------|
| `msgpack` | std | The MessagePack codec. It has no Tarantool dependency. |
| `tarantool-proto` | `msgpack` | The protocol types that do not depend on where the code runs: iterator types, select options, update operations, the iproto constants. |
| `tarantool` | `msgpack`, `tarantool-proto`, the C API of Tarantool | The in-process SDK: everything a module does inside Tarantool. |
| `tarantool-client` | `msgpack`, `tarantool-proto` | The iproto network client. |

The imports only go down the table. `tarantool-client` cannot import
`tarantool`, because the build does not give it that import. So the client
compiles and runs in a program that has no Tarantool to resolve the `box_*`
symbols against. `zig build purity` checks this: it compiles a module that
crosses the boundary and expects the compilation to fail.

A module built with [`addModule`](../reference/build.md#addmodule) can import
all four. A program built with
[`addExecutable`](../reference/build.md#addexecutable) gets every module except
`tarantool`.

The SDK re-exports what it shares with the other modules, so a module only needs
`@import("tarantool")`:

| Name in `tarantool` | Is |
|---------------------|----|
| `tarantool.msgpack` | the `msgpack` module |
| `tarantool.query` | `tarantool-proto`'s `query`: `IteratorType`, `SelectOptions` |
| `tarantool.update` | `tarantool-proto`'s `update`: update operations |

A module that runs the network client inside Tarantool also imports
`tarantool-client`, see
[The client in a stored procedure](../how-to/client-in-a-procedure.md).

## How a module reaches Tarantool

A module is a shared library with undefined symbols: `box_insert`,
`fiber_new`, `lua_pushnil`, and the rest of the C API of Tarantool. The
library is not linked against Tarantool. Tarantool exports these symbols from
its own executable, and the dynamic loader binds them when Tarantool loads the
module with `dlopen`.

So:

- A module builds without Tarantool installed, and cross-compiles: `zig build
  -Dtarget=aarch64-macos` makes a `.dylib` on Linux.
- A module loads only into a Tarantool that exports every symbol it uses. That
  is 3.5 or later, see [Install](../get-started/install.md#requirements).
- A missing symbol shows when Tarantool loads the module: at the first call of
  one of its functions, or at `require`. It does not show at build time.

`tarantool.c` declares the C API by hand, in Zig: the functions, the opaque
types, the constants. Every Tarantool symbol the SDK uses is declared there.
`zig build verify-cabi -Dverify-cabi=true` translates the real `module.h` and
compares every declaration with it, see
[Testing](../project/testing.md#check-the-c-api).

## Raw and typed layers

Each part of the SDK has a raw layer that maps the C API one to one, and a typed
layer built only from the raw one. You can drop to the raw layer whenever the
typed one does not fit.

| Area | Raw | Typed |
|------|-----|-------|
| Stored procedures | `fn(ctx, args, args_end) callconv(.c) c_int`, `proc.returnValue`, `proc.exportRaw` | `proc.exportProc(name, f)` with a plain Zig `f` |
| Data | `box.Space`, `box.Index`, `box.Tuple`, `Index.iterator` | `box.Typed(Row)`, `Index.range(Row, ...)`, `Index.top` |
| Lua functions | a `lua_CFunction` over `lua.Lua` | a plain Zig function in `lua.exportModule` |
| Client requests | `callRaw`, `insertRaw`, ... over pre-encoded MessagePack | `call`, `insert`, ... over Zig values |
| Anything else | `tarantool.c`, the C API itself | |

The typed layers add no parsing of their own: they encode and decode through
`msgpack`, and call the raw layer.

## Hidden symbols

Some functions of Tarantool are not in its public C API. They are compiled into
the executable, but they are not exported, so `dlsym` does not find them.
`tarantool.symresolve.resolve(name)` finds such a symbol: it reads the full
symbol table of the executable, `.symtab` on Linux and `LC_SYMTAB` on macOS. You
then cast the pointer to the type of the function.

It is an escape hatch. The internal functions of Tarantool change between
versions without notice, and a stripped executable has no symbol table at all.
See [Introspection](../how-to/introspection.md#hidden-symbols).
