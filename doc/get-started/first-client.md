# Your first client

This page writes a Zig program that connects to Tarantool over the network and
calls the stored procedure of [Your first module](first-module.md). It extends
the `hello` project of that page.

A client program does not run inside Tarantool and does not import
`tarantool`: it imports `tarantool-client`, the iproto connector of the package.

## Start a server

The server serves `hello.add` to the guest user on port 3301.

`server.lua`:

```lua
local ext = require('tarantool').build.mod_format
package.cpath = 'zig-out/lib/?.' .. ext .. ';' .. package.cpath

require('fio').mktree('data')
box.cfg{ memtx_dir = 'data', wal_dir = 'data', listen = '127.0.0.1:3301' }

box.schema.func.create('hello.add', { language = 'C', if_not_exists = true })
box.schema.func.create('hello.greet', { language = 'C', if_not_exists = true })
box.schema.user.grant('guest', 'execute', 'function', 'hello.add', { if_not_exists = true })
```

```console
$ tarantool server.lua
```

The server keeps running; use another terminal for the rest.

## Write the program

`src/client.zig`:

```zig
//! Connect to 127.0.0.1:3301 as guest, call hello.add, and show what a denied
//! call looks like.

const std = @import("std");
const client = @import("tarantool-client");

pub fn main(init: std.process.Init) !void {
    var conn = try client.Connection.connect(init.gpa, init.io, .{
        .address = "127.0.0.1:3301",
    });
    defer conn.close();

    try conn.ping();

    const sum = try conn.call("hello.add", .{ 1, 2 }, i64);
    std.debug.print("hello.add(1, 2) = {d}\n", .{sum});

    // The guest may not call hello.greet: the server answers with an error,
    // which the connection keeps in last_error.
    if (conn.call("hello.greet", .{"Zig"}, []const u8)) |_| {
        unreachable;
    } else |err| switch (err) {
        error.ServerError => std.debug.print("hello.greet: {s}\n", .{conn.last_error.?.message}),
        else => return err,
    }
}
```

- `Connection.connect(gpa, io, options)` opens a TCP connection, reads the
  greeting and logs in. The address is `host:port` with a numeric IP. With no
  `.user`, it logs in as `guest`, and a guest with no password skips the
  authentication request.
- `io` is the `std.Io` the connection does its network operations through.
  `init.io` is the one `main` gets from the Zig runtime. Inside a stored
  procedure, the package offers one that yields the fiber instead, see
  [The client in a stored procedure](../how-to/client-in-a-procedure.md).
- `call(name, args, Result)` encodes `args` as the argument array and decodes
  the value the function returns into `Result`.
- A request the server refuses fails with `error.ServerError`;
  `conn.last_error` holds its code and message until the next error.

## Build and run it

Add the program to `build.zig`, after the module:

```zig
    const cli = tarantool.addExecutable(b, .{
        .name = "hello-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(cli);
```

`addExecutable` makes a program that can import `tarantool-client`, but not
`tarantool`: the in-process API needs a Tarantool to run in. A program installs
as usual, with `b.installArtifact`.

```console
$ zig build
$ ./zig-out/bin/hello-client
hello.add(1, 2) = 3
hello.greet: Execute access to function 'hello.greet' is denied for user 'guest'
```

## Next

- [Network client](../how-to/network-client.md): CRUD, batches, the schema,
  watchers, transactions.
- [Encoding](../concepts/encoding.md): what a Zig type becomes on the wire, and
  back.
