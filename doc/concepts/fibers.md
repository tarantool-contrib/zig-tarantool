# Fibers and yields

Tarantool runs the requests of its users in fibers: coroutines on a single
thread, the TX thread, that switch only when one of them yields. A stored
procedure runs in the fiber of its request. This page says what that means for
Zig code, and which calls of the SDK yield.

## One thread, cooperative switching

While a procedure runs and does not yield, no other request of the instance
runs. That makes code between two yields atomic with respect to the other
fibers. It also means that a procedure that computes for a second, or blocks in
a system call, stalls the whole instance for that second.

So in a module:

- **Do not block the thread.** `std.Thread.sleep`, a blocking `read` of a
  socket, a `std.Io.Threaded` network call: each of them stops every fiber.
  Use the fiber versions: `fiber.sleep`, `coio.wait`, `fiberio.io()`.
- **Offload what has to block.** `coio.call(Ctx, func, &ctx)` runs `func` on a
  worker thread of Tarantool and yields the fiber until it returns. `func` must
  not touch the box, the region, fibers or Lua: none of them are thread-safe.
- **Assume a yield invalidates what you read.** After a yield, other fibers may
  have changed the spaces. Read again, or do the work in a transaction.

## What yields

| Call | Yields |
|------|--------|
| `fiber.sleep`, `fiber.yield`, `fiber.reschedule` | always |
| `fiber.spawn`, `spawnWithAttr`, `spawnDetached` | yes: the new fiber runs first, until its first yield |
| `Fiber.join` | until the fiber ends |
| `cond.Cond.wait`, `waitTimeout`, `waitUntil` | until a signal or the timeout |
| `latch.Latch.lock` | when the latch is held |
| `fiber.Channel.send`, `recv` | when the channel is full, or empty |
| `coio.wait`, `coio.call`, `coio.getAddrInfo` | yes |
| every network operation over `fiberio.io()` | while it waits for the socket |
| `info.waitRo` | until the state changes or the timeout |
| a commit of a transaction | while the write-ahead log is written, unless the engine has nothing to write |
| `Space` and `Index` operations on memtx | no |

A yield inside a transaction matters: memtx aborts a transaction that yields,
unless the instance runs the MVCC engine (`memtx_use_mvcc_engine = true`). See
[Transactions](../how-to/transactions.md).

## Cancellation

`Fiber.cancel` asks a fiber to stop; it does not stop it. The fiber sees the
request at its next yield: the waits of the SDK return `error.Cancelled`, and
`fiber.isCancelled()` turns true. A fiber body that loops without waiting
should check `fiber.isCancelled()` itself.

## Network I/O from a fiber

`tarantool.fiberio.io()` is a `std.Io` whose network operations do not block
the thread. A socket is non-blocking; when a read or a write would block, the
fiber waits in `coio.wait` and Tarantool runs other fibers until the socket is
ready. The network client takes a `std.Io`, so with this one it runs inside a
stored procedure:

```zig
var conn = try client.Connection.connect(gpa, t.fiberio.io(), .{ .address = uri });
```

Only the operations the client needs are implemented: connecting to an IP
address, reading, writing and closing a socket. The rest of `std.Io`, such as
files, timers and `async`, panics with the name of the operation. See
[The client in a stored procedure](../how-to/client-in-a-procedure.md).
