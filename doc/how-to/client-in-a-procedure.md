# The client in a stored procedure

A stored procedure can query another Tarantool instance: the network client
runs inside Tarantool as well as outside it. Given `tarantool.fiberio.io()`, it
does its network I/O by yielding the fiber of the procedure instead of blocking
the thread, as net.box does in Lua. This page writes such procedures.

## The module

`src/relay.zig`:

```zig
//! relay: stored procedures that read another instance over iproto.

const std = @import("std");
const t = @import("tarantool");
const client = @import("tarantool-client");

fn connect(uri: []const u8) !client.Connection {
    return client.Connection.connect(std.heap.c_allocator, t.fiberio.io(), .{
        .address = uri,
        // Give up on a dead peer after 2 seconds instead of waiting forever.
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = 2 * std.time.ns_per_s },
            .clock = .awake,
        } },
    });
}

/// relay.count(uri, space) -> the number of tuples in a space of uri.
fn count(uri: []const u8, space: []const u8) !u64 {
    var conn = try connect(uri);
    defer conn.close();
    const name = try std.fmt.allocPrint(t.region.allocator(), "box.space.{s}:count", .{space});
    return conn.call(name, .{}, u64);
}

/// relay.get(uri, key) -> the value of key in the kv space of uri, or nil.
fn get(uri: []const u8, key: []const u8) !?[]const u8 {
    var conn = try connect(uri);
    defer conn.close();
    const row = try conn.space("kv").get(.{key}, struct { []const u8, []const u8 }) orelse return null;
    // The string borrows the buffer of the connection, which close() frees:
    // copy it to the region, where the result is encoded from.
    return try t.region.allocator().dupe(u8, row[1]);
}

comptime {
    t.proc.exportProc("count", count);
    t.proc.exportProc("get", get);
}
```

The instance can query itself, which shows that the procedure yields: while
`get` waits for the reply, the same thread serves the request it sent.

```lua
box.cfg{ listen = '127.0.0.1:3302' }
local kv = box.schema.space.create('kv', { if_not_exists = true })
kv:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })
kv:replace({ 'lang', 'zig' })
box.schema.user.grant('guest', 'read', 'space', 'kv', { if_not_exists = true })
box.schema.user.grant('guest', 'execute', 'universe', nil, { if_not_exists = true })

box.schema.func.create('relay.count', { language = 'C', if_not_exists = true })
box.schema.func.create('relay.get', { language = 'C', if_not_exists = true })

box.func['relay.count']:call({ '127.0.0.1:3302', 'kv' })   -- 1
box.func['relay.get']:call({ '127.0.0.1:3302', 'lang' })   -- zig
box.func['relay.get']:call({ '127.0.0.1:3302', 'rust' })   -- nil
box.func['relay.get']:call({ '127.0.0.1:1', 'lang' })      -- error: ConnectionRefused
```

## How it works

`fiberio.io()` returns a `std.Io` that keeps no state. Its sockets are
non-blocking: when a read, a write or a connect would block, the fiber waits in
`coio.wait`, and the TX thread runs other fibers until the socket is ready.
The client is the same code as in a standalone program; only the `io` differs.

- **Call it from a fiber.** Every stored procedure runs in one, and so does a
  fiber you spawn. A worker thread of `coio.call` does not.
- **Only the network is implemented.** Connecting to an IP address, reading,
  writing and closing a socket: what the client needs. Every other operation of
  `std.Io`, such as files, timers or `async`, panics with its name.
- **The address is numeric.** As everywhere in the client, `host:port` takes an
  IP address; resolve a name with
  [`coio.getAddrInfo`](fibers.md#worker-threads) first.
- **Set a timeout.** Without `.timeout`, a connect to a host that does not
  answer waits for as long as the operating system does. A refused connect fails
  at once.

## Connections

The procedures above open a connection per call, which costs a round trip of
greeting and login each time. A connection can outlive the call, in a global,
but it handles one request at a time: two fibers that use it at once mix their
requests. Guard a shared connection with a [latch](fibers.md#condition-variables-and-latches),
or keep one per fiber.

A connection allocates with the allocator you give it; `std.heap.c_allocator`
works in any fiber. Close a connection in the fiber that uses it.

## Transactions

A procedure that waits on the network yields, and memtx aborts a transaction
that yields unless the instance runs the MVCC engine. Query the other instance
before or after a local transaction, not inside it. See
[Transactions](transactions.md#yields-in-a-transaction).
