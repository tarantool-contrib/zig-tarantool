# API by module

This page lists the public declarations of the package, by module, with a line
on each and a link to the page that shows it in use. The
[generated API reference](../api/index.html) has every declaration with its
doc comment, its signature and its source: for example
[`tarantool.box.Space`](../api/index.html#tarantool.box.Space),
[`tarantool-client.Connection`](../api/index.html#tarantool-client.Connection),
[`msgpack.encode`](../api/index.html#msgpack.encode).

## tarantool

`@import("tarantool")`, in a module only.

| Declaration | Is | See |
|-------------|----|-----|
| `proc.exportProc(name, f)` | exports a plain Zig function as a stored procedure | [Stored procedures](../how-to/stored-procedures.md) |
| `proc.exportRaw(name, f)` | exports `fn(ctx, args, args_end) !c_int` as a stored procedure | [Stored procedures](../how-to/stored-procedures.md#raw-procedures) |
| `proc.returnValue(ctx, value)`, `proc.returnTuple(ctx, tuple)` | add a result to a call | |
| `proc.fail(err, message)` | fails a raw procedure | |
| `proc.RawProc` | the C type of a stored procedure | |
| `box.Space` | a space: `byName`, `insert`, `replace`, `get`, `delete`, `update`, `upsert`, `truncate`, the `*Discard` variants, `primary`, `index`, `indexById` | [Spaces and indexes](../how-to/spaces-and-indexes.md#spaces) |
| `box.Index` | an index: `get`, `min`, `max`, `count`, `len`, `bsize`, `random`, `select`, `iterator`, `cursor`, `range`, `top`, `update`, `extractKey` | [Spaces and indexes](../how-to/spaces-and-indexes.md#indexes) |
| `box.Iterator`, `box.Cursor`, `box.Range(Row)` | walks over an index: owning, borrowing, typed | |
| `box.Typed(Row)` | a space as rows of a named struct: `put`, `insert`, `get`, `del`, `free` | [Spaces and indexes](../how-to/spaces-and-indexes.md#typed-rows) |
| `box.info` | the state of the instance: `status`, `isRo`, `waitRo`, `roReason`, `schemaVersion`, `lsn`, `slab` | [Introspection](../how-to/introspection.md) |
| `box.Tuple`, `tuple.Tuple` | a tuple: `get`, `field`, `decode`, `decodeRow`, `fieldCount`, `bsize`, `fieldIterator`, `new`, `update`, `deinit` | [Spaces and indexes](../how-to/spaces-and-indexes.md#reading-a-tuple) |
| `txn.transaction(f, args)`, `txn.transactionWith(options, f, args)` | runs `f` in a transaction | [Transactions](../how-to/transactions.md) |
| `txn.Savepoint` | a savepoint: `save`, `rollback` | [Transactions](../how-to/transactions.md#savepoints) |
| `txn.active`, `id`, `isolation`, `setIsolation`, `setTimeout`, `makeSync`, `alloc`, `allocSlice` | the active transaction | |
| `seq.Sequence` | a sequence: `byName`, `byId`, `next`, `current`, `set`, `reset` | [Spaces and indexes](../how-to/spaces-and-indexes.md#sequences) |
| `keydef.KeyDef` | a key definition: `init`, `compare`, `compareWithKey`, `extractKey` | [Spaces and indexes](../how-to/spaces-and-indexes.md#key-definitions) |
| `fiber.spawn`, `spawnWithAttr`, `spawnDetached` | start a fiber | [Fibers](../how-to/fibers.md) |
| `fiber.Fiber(R)` | a fiber to join: `join`, `cancel`, `wakeup`, `id`, `name`, `setName`, `csw` | |
| `fiber.FiberAttr`, `fiber.find`, `fiber.FiberInfo` | stack size; look up a fiber | |
| `fiber.sleep`, `yield`, `reschedule`, `isCancelled`, `time`, `clock`, ... | the current fiber | |
| `fiber.Channel(T)` | a bounded channel: `send`, `recv`, `close` | [Fibers](../how-to/fibers.md#channels) |
| `cond.Cond` | a condition variable: `wait`, `waitTimeout`, `waitUntil`, `signal`, `broadcast` | [Fibers](../how-to/fibers.md#condition-variables-and-latches) |
| `latch.Latch` | a mutex for fibers: `lock`, `tryLock`, `unlock`, `withLock` | |
| `coio.wait`, `coio.close` | wait until a file descriptor is ready | [Fibers](../how-to/fibers.md#worker-threads) |
| `coio.call`, `coio.getAddrInfo` | run a function, or resolve a name, on a worker thread | |
| `fiberio.io()` | a `std.Io` whose network I/O yields the fiber | [The client in a stored procedure](../how-to/client-in-a-procedure.md) |
| `lua.exportModule(name, defs)` | exports `luaopen_<name>` for `require` | [Lua modules](../how-to/lua-modules.md) |
| `lua.Lua`, `lua.Multi`, `lua.multi`, `lua.raiseErr` | the Lua stack, several results, errors | |
| `trigger.onReplace`, `trigger.SpaceTrigger` | a trigger on the writes to a space | [Triggers](../how-to/triggers.md) |
| `trigger.onCommit`, `onRollback`, `onShutdown`, `removeShutdown` | triggers on a transaction and on the shutdown | |
| `say.err`, `crit`, `warn`, `info`, `verbose`, `debug`, `sysError`, `enabled`, `stdLogFn` | the log | [Logging](../how-to/logging.md) |
| `decimal.Decimal` | a decimal and its arithmetic | [Decimals and extensions](../how-to/decimals-and-extensions.md) |
| `region.allocator()`, `region.Savepoint` | the fiber region as an allocator | [Lifetimes](../concepts/lifetimes.md#the-fiber-region) |
| `err.lastError()`, `err.lastMessage(buf)`, `err.setBoxError(code, message)` | the error of Tarantool | [Errors](errors.md) |
| `clock.realtime`, `monotonic`, `process`, `thread` | the system clocks | [Introspection](../how-to/introspection.md#clocks) |
| `symresolve.resolve(name)` | the address of a symbol that Tarantool does not export | [Introspection](../how-to/introspection.md#hidden-symbols) |
| `c` | the C API of Tarantool, declared in Zig | [Modules and layers](../concepts/layers.md#how-a-module-reaches-tarantool) |
| `msgpack`, `query`, `update` | re-exports, see below | |

## tarantool-client

`@import("tarantool-client")`, in a module or a program.

| Declaration | Is | See |
|-------------|----|-----|
| `Connection` | a connection: `connect`, `close`, `ping`, `call`, `eval`, `callRaw`, `evalRaw`, `space`, `batch`, `schema`, `refreshSchema`, `watch`, `unwatch`, `waitEvent`, `pollEvent`, `watchOnce`, `hasFeature`, `last_error` | [Network client](../how-to/network-client.md) |
| `ConnectOptions` | `address`, `user`, `password`, `timeout` | [Network client](../how-to/network-client.md#connect) |
| `Space`, `Index` | requests to a space and to an index, typed and raw | [Network client](../how-to/network-client.md#crud) |
| `Batch`, `Handle`, `ServerErrorInfo` | pipelined requests | [Network client](../how-to/network-client.md#batches) |
| `Schema`, `decodeRow` | the schema of the server; a tuple decoded by field names | [Network client](../how-to/network-client.md#the-schema) |
| `Stream` | an interactive transaction: `open`, `begin`, `commit`, `rollback`, `space` | [Network client](../how-to/network-client.md#transactions) |
| `Error`, `ConnectError`, `RequestError`, `ServerError` | the errors | [Errors](errors.md#the-network-client) |

## tarantool-proto

`@import("tarantool-proto")`; the SDK re-exports `query` and `update`.

| Declaration | Is |
|-------------|----|
| `query.IteratorType` | the iterators: `.eq`, `.req`, `.all`, `.lt`, `.le`, `.ge`, `.gt`, the bitset and spatial ones |
| `query.SelectOptions` | `iterator`, `offset`, `limit` |
| `update.set`, `insert`, `add`, `sub`, `band`, `bor`, `bxor`, `delete`, `splice` | the update operations |
| `update.Ops` | update operations built at run time |
| `iproto`, `greeting`, `auth` | the protocol: its constants, the greeting, the `chap-sha1` scramble |

## msgpack

`@import("msgpack")`, or `tarantool.msgpack`.

| Declaration | Is | See |
|-------------|----|-----|
| `encode(w, value)`, `encodeArray(w, value)` | encode a value; any struct as an array | [Encoding](../concepts/encoding.md) |
| `decode(T, &dec)`, `decodeArray(T, &dec)` | decode into a type; an array into a named struct | |
| `Decoder` | a decoder over bytes: `init`, `decodeValue` | |
| `Buffer` | a growable byte buffer: `init`, `items`, `deinit` | |
| `Value`, `KV`, `freeValue` | a dynamic value | [Encoding](../concepts/encoding.md#dynamic-values) |
| `Bin` | binary data, as opposed to a string | |
| `ext.Uuid`, `Datetime`, `Interval`, `Decimal`, `Ext` and their `parse*` | the extension types of Tarantool | [Decimals and extensions](../how-to/decimals-and-extensions.md#uuids-datetimes-intervals) |
| `DecodeError` | the errors of decoding | [Errors](errors.md#decoding) |
