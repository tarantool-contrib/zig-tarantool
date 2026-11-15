# Errors

The SDK reports failures as Zig errors, and turns them into errors of
Tarantool or Lua at the boundary. This page lists the errors by module, and
what the caller of a procedure, of a Lua function or of a client request sees.

## What the caller sees

| Where the Zig error comes from | The caller gets |
|--------------------------------|-----------------|
| a typed procedure, `exportProc` | a `ClientError`, code 102 (`ER_PROC_C`), with the name of the error as the message |
| a raw procedure, `exportRaw`, returning `error.BoxOp` | the error Tarantool set, with its own type, code and message |
| a raw procedure returning another error | a `ClientError` 102 with the name of the error |
| `proc.fail(err, message)` | as above, with `message` instead of the name |
| `err.setBoxError(code, message)` and `return -1` | a `ClientError` with that code and message |
| a Lua function of `lua.exportModule` | a Lua error: the message of Tarantool for `error.BoxOp`, the name of the error otherwise |
| an `on_replace` trigger | the same, as the error of the statement that fired it |

A typed procedure reports `error.BoxOp` as `BoxOp`, without the message of
Tarantool; write a raw procedure to keep it. In Lua, the error object has the
fields `type`, `code` and `message`:

```lua
local ok, e = pcall(box.func['procs.clamp'].call, box.func['procs.clamp'], { 1, 10, 0 })
e.code     -- 102
e.message  -- EmptyRange
```

## The error of Tarantool

When a box operation fails, Tarantool sets the error of the fiber and the SDK
returns `error.BoxOp`. `tarantool.err` reads and sets that error:

| Function | Does |
|----------|------|
| `lastError()` | the error, as `BoxError{ code, message, type }`, or `null`; its strings are valid until the next box call |
| `lastMessage(&buf)` | copies the message into `buf`, and returns the copy, or `null` |
| `setBoxError(code, message)` | sets the error; the message is cut at 256 bytes |

An error that is not `error.BoxOp` comes from the SDK, and the error of Tarantool
may be one left over from an earlier operation: read it only after `BoxOp`.

## Errors by module

| Module | Errors |
|--------|--------|
| `box` | `NoSuchSpace`, `NoSuchIndex`: the name does not exist; `BoxOp`: Tarantool failed the operation |
| `tuple` | `NewFailed`, `UpdateFailed`, `NullTupleData` |
| `txn` | `BoxOp`; `NoTxn`: no active transaction; `StaleSavepoint`: the savepoint belongs to another transaction; `TxnStarted`: the isolation is set after the first write; `OutOfMemory` |
| `seq` | `SeqOp`: Tarantool failed the operation; `NoSuchSequence` |
| `keydef` | `KeyDefFailed`, `ExtractFailed` |
| `fiber` | `FiberOp`: the fiber was not created |
| `fiber.Channel` | `InvalidCapacity`, `Closed`, `Cancelled` |
| `cond` | `CondOp`, `Timeout`, `Cancelled` |
| `latch` | `LatchOp` |
| `coio` | `Timeout`, `CoioOp`; `OffloadFailed` from `call`; `Timeout`, `ResolveFailed` from `getAddrInfo` |
| `box.info.waitRo` | `Timeout`, `Cancelled` |
| `trigger` | `TriggerOp`: the registration failed; `NoTxn` |
| `decimal` | `DecimalError`: the operation failed; `InvalidDecimal`: not a decimal; `Overflow`: out of the integer range |
| `lua`, the typed functions | `ArityMismatch`, `TypeMismatch`, `Overflow`, and the errors of the function |
| `proc`, the typed procedures | `wrong argument count`, and the errors of decoding |

## Decoding

`msgpack.DecodeError`, from `msgpack.decode`, from the arguments of a typed
procedure, and from the results of the client:

| Error | The input |
|-------|-----------|
| `NotInt`, `NotBool`, `NotFloat`, `NotStr`, `NotBin`, `NotArray`, `NotMap`, `NotExt` | has another type |
| `Overflow` | is an integer out of the range of the type |
| `ArityMismatch` | is an array of another length |
| `UnknownField`, `MissingField` | is a map with a key that is no field, or without one that is |
| `Truncated` | ends in the middle of a value |
| `InvalidExt` | is an extension whose payload is not valid for the type |
| `OutOfMemory` | needed memory for a dynamic value, and there was none |

## The network client

`client.Error`, plus the errors of decoding and of the socket:

| Error | Means | The connection |
|-------|-------|----------------|
| `ServerError` | the server refused the request; `conn.last_error` has the details | usable |
| `AuthFailed` | the login failed | closed by `connect` |
| `MoreThanOne` | `get` matched several tuples | usable |
| `UnsupportedServer` | the server lacks a feature the client needs, such as Tarantool before 3.0 | closed by `connect` |
| `InvalidAddress` | the address is not `host:port` with a numeric host | not opened |
| `ConnectionClosed`, `ReadFailed`, `WriteFailed` | the connection broke | close it |
| `ProtocolError` | the reply violates the protocol | close it |

`connect` also returns the errors of `std.Io.net` for the socket, such as
`ConnectionRefused` and `Timeout`.
