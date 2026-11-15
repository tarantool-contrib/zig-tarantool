# Network client

`tarantool-client` is an iproto connector: a Zig program uses it to work with
Tarantool over the network. This page goes through a program that does each
kind of request: CRUD, calls, batches, the schema, watchers and a transaction.
[Your first client](../get-started/first-client.md) sets up a project for it.

## The server

`shop.lua`:

```lua
require('fio').mktree('data')
box.cfg{
    memtx_dir = 'data',
    wal_dir = 'data',
    listen = '127.0.0.1:3301',
    memtx_use_mvcc_engine = true, -- for the transaction over a stream
}
box.once('shop', function()
    box.schema.user.create('shop', { password = 'secret' })
    box.schema.user.grant('shop', 'read,write,execute', 'universe')
    local products = box.schema.space.create('products', {
        format = {
            { name = 'id', type = 'unsigned' },
            { name = 'name', type = 'string' },
            { name = 'price', type = 'unsigned' },
        },
    })
    products:create_index('pk', { parts = { 'id' } })
    products:create_index('by_name', { parts = { 'name' } })
end)
box.broadcast('price_list', 7)
```

```console
$ tarantool shop.lua
```

## The program

`src/shop.zig`:

```zig
//! shop: every kind of request of tarantool-client, against shop.lua.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");
const update = @import("tarantool-proto").update;

/// A row of `products`: id, name, price.
const Product = struct { u64, []const u8, u64 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var conn = try client.Connection.connect(gpa, init.io, .{
        .address = "127.0.0.1:3301",
        .user = "shop",
        .password = "secret",
    });
    defer conn.close();

    // CRUD, by the name of the space. Row = void discards the result.
    const products = conn.space("products");
    _ = try products.replace(.{ 1, "tea", 300 }, void);
    _ = try products.replace(.{ 2, "coffee", 450 }, void);
    _ = try products.replace(.{ 3, "cocoa", 380 }, void);

    const tea = (try products.get(.{1}, Product)).?;
    std.debug.print("get: {s} costs {d}\n", .{ tea[1], tea[2] });

    // Field numbers count from 0: 2 is the price.
    const cheaper = (try products.update(.{2}, .{update.sub(2, 50)}, Product)).?;
    std.debug.print("update: {s} costs {d}\n", .{ cheaper[1], cheaper[2] });

    // A request the server refuses: error.ServerError, details in last_error.
    if (products.insert(.{ 1, "green tea", 320 }, void)) |_| {
        unreachable;
    } else |err| switch (err) {
        error.ServerError => std.debug.print("insert: {s}\n", .{conn.last_error.?.message}),
        else => return err,
    }

    // A secondary index, and a range.
    const cocoa = (try products.index("by_name").get(.{"cocoa"}, Product)).?;
    std.debug.print("by name: cocoa is {d}\n", .{cocoa[0]});
    const from_two = try products.select(gpa, .{2}, .{ .iterator = .ge, .limit = 10 }, Product);
    defer gpa.free(from_two);
    std.debug.print("select: {d} products from id 2\n", .{from_two.len});

    // Calls and evals decode their single result.
    const count = try conn.call("box.space.products:count", .{}, u64);
    const total = try conn.eval("return ... + box.space.products:get(1)[3]", .{100}, u64);
    std.debug.print("call: {d} products; eval: {d}\n", .{ count, total });

    // A batch: three requests, one write, the replies matched to them.
    var batch = conn.batch(gpa);
    defer batch.deinit();
    const h_ping = try batch.ping();
    const h_get = try batch.get(products, .{3});
    const h_count = try batch.call("box.space.products:count", .{});
    try batch.execute();
    try batch.expectOk(h_ping);
    const third = (try batch.decodeMaybe(h_get, Product)).?;
    const n = try batch.decodeOne(h_count, u64);
    std.debug.print("batch: {s}, {d} products\n", .{ third[1], n });

    // The schema: spaces, their formats and indexes, fetched once and cached.
    const schema = try conn.schema();
    const info = schema.space("products").?;
    std.debug.print("schema: products has {d} fields, the second is {s}\n", .{ info.format.len, info.format[1].name });

    // Watchers: the current value once, or every change.
    const version = try conn.watchOnce("price_list", ?i64);
    try conn.watch("price_list");
    const event = try conn.waitEvent(); // the current value comes first
    var dec = msgpack.Decoder.init(event.data.?);
    std.debug.print("watch: {s} = {d}, once: {?d}\n", .{ event.key, try msgpack.decode(i64, &dec), version });

    // An interactive transaction, over a stream of its own.
    var tx = try client.Stream.open(&conn);
    try tx.begin();
    _ = try tx.space("products").replace(.{ 4, "mate", 500 }, void);
    try tx.rollback();
    const mate = try products.get(.{4}, Product);
    std.debug.print("stream: mate after the rollback: {?s}\n", .{if (mate) |m| m[1] else null});
}
```

```console
$ zig build && ./zig-out/bin/shop
get: tea costs 300
update: coffee costs 400
insert: Duplicate key exists in unique index "pk" in space "products" with old tuple - [1, "tea", 300] and new tuple - [1, "green tea", 320]
by name: cocoa is 3
select: 2 products from id 2
call: 3 products; eval: 400
batch: cocoa, 3 products
schema: products has 3 fields, the second is name
watch: price_list = 7, once: 7
stream: mate after the rollback: null
```

## Connect

`Connection.connect(gpa, io, options)` opens a TCP connection, reads the
greeting, negotiates the protocol features, and logs in:

| Option | Default | Is |
|--------|---------|----|
| `.address` | | `host:port`, with a numeric IPv4 or IPv6 host |
| `.user` | `"guest"` | the user to log in as |
| `.password` | `""` | its password; a guest with no password skips the login |
| `.timeout` | `.none` | a `std.Io.Timeout` for the connect |

The login uses `chap-sha1`, the default of Tarantool Community Edition. The
server must be Tarantool 3.0 or later: the client names spaces and indexes in
its requests, which older servers do not accept, and `connect` fails with
`error.UnsupportedServer`. `conn.hasFeature(feature)` tells which features the
server negotiated.

`gpa` backs the buffers of the connection; `close()` frees them. Call it exactly
once.

`io` does the network operations. In `main`, it is the `init.io` of the Zig
runtime. Inside Tarantool, it is `tarantool.fiberio.io()`, see
[The client in a stored procedure](client-in-a-procedure.md).

## CRUD

`conn.space(name)` is a handle for the requests to a space. It does no I/O: the
server resolves the name in each request, so a wrong name fails at the first
request, with `error.ServerError`.

| Method | Returns |
|--------|---------|
| `insert(row, Row)`, `replace(row, Row)` | the stored tuple as `Row` |
| `get(key, Row)` | the tuple, or `null`; `error.MoreThanOne` if the key matches several |
| `delete(key, Row)`, `update(key, ops, Row)` | the tuple, or `null` if no tuple has the key |
| `upsert(row, ops)` | nothing: an upsert returns no tuple |
| `select(gpa, key, options, Row)` | a slice of rows, which you free with `gpa` |
| `index(name)` | a handle with `get` and `select` on a secondary index |

`Row` is the type to decode the tuple into, usually a tuple struct, or `void`
to discard it. The update operations are those of `tarantool-proto`'s
`update`, with field numbers from 0, as in
[Spaces and indexes](spaces-and-indexes.md#update-operations).

Each method has a raw twin, `insertRaw`, `getRaw`, `selectRaw`, ..., which takes
the row or the key as encoded MessagePack and returns the `DATA` of the reply as
MessagePack.

## Calls and evals

`call(name, args, Result)` calls a function, `eval(expr, args, Result)` runs Lua
code. `args` is a tuple, `.{ a, b }`, encoded as the argument array. `Result`
is the type of the one value the function returns: a function that returns two
values fails with `error.ArityMismatch`; use a tuple struct for a function that
returns a table. `Result = void` ignores the result.

`callRaw(name, args_mp)` and `evalRaw(expr, args_mp)` take the arguments as
MessagePack, and return all the results as MessagePack.

## Errors

A request the server refuses fails with `error.ServerError`. `conn.last_error`
holds the details until the next server error:

| Field | Is |
|-------|----|
| `code` | the error code of Tarantool |
| `message` | its message |
| `raw` | the error stack as MessagePack, if the server sent one |

The other errors are about the connection itself: `ConnectionClosed`,
`ReadFailed`, `WriteFailed`, `ProtocolError`. After one of them, close the
connection. See [Errors](../reference/errors.md#the-network-client).

## Batches

A connection waits for the reply to each request before it sends the next. A
`Batch` sends many requests in one write and reads all the replies:

1. `conn.batch(gpa)` opens one.
2. `insert`, `replace`, `delete`, `get`, `select`, `update`, `upsert`, `call`,
   `eval`, `ping` add a request and return a handle.
3. `execute()` sends them and reads the replies.
4. `decodeOne(h, Row)`, `decodeMaybe(h, Row)` and `decodeMany(h, gpa, Row)`
   decode a reply; `expectOk(h)` checks one; `serverError(h)` returns the error
   of a request that failed, while the others still succeed.
5. `deinit()` frees the replies.

A batch runs once. `decodeOne` decodes the one tuple of a reply, or the one
result of a call or an eval: `decodeOne(h_count, u64)` above.

## The schema

`conn.schema()` fetches the spaces and indexes the user can see, and caches
them. Each reply carries the schema version of the server; when it changes, the
next `schema()` fetches again. `refreshSchema()` fetches at once.

```zig
const info = schema.space("products").?;     // *const Schema.SpaceInfo
for (info.format) |field| _ = field;         // .name, .type, .is_nullable
const pk = info.index("pk").?;               // .id, .unique, .parts
_ = pk;
```

`client.decodeRow(Row, info, tuple_mp)` decodes a tuple into a named struct by
the names of the fields in the format, in any order; an optional field of `Row`
takes a missing tail of the tuple as `null`.

## Watchers

`box.broadcast(key, value)` on the server publishes a value; a client watches
it:

- `watchOnce(key, Result)` reads the current value, as one request.
- `watch(key)` subscribes. The server sends the current value at once, and
  then each new one.
- `waitEvent()` waits for the next event; `pollEvent()` returns one only if it
  has arrived already. An event has the `key` and the value as MessagePack, in
  `data`, or `null` if the key has no value.
- `unwatch(key)` unsubscribes.

The connection has no thread of its own: events arrive while you call
`waitEvent`, or while a request reads its reply, and wait in a queue.

## Transactions

`client.Stream.open(&conn)` opens a stream: requests that share a transaction on
the server. `begin()`, `commit()` and `rollback()` drive it, and
`stream.space(name)` is a space handle whose requests belong to the stream. The
server needs `memtx_use_mvcc_engine = true` for a transaction on memtx that
spans requests.

## Lifetimes

A decoded string borrows the buffer of the connection, and the next request
overwrites it. `tea[1]` above is valid until the `update` that follows it. See
[Lifetimes](../concepts/lifetimes.md#the-network-client).
