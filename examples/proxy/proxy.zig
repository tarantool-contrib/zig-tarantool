//! Stored procedures that talk to *another* Tarantool instance over iproto —
//! net.box, written in Zig. Built to `proxy.so` (`proxy.dylib` on macOS).
//!
//!   box.schema.func.create('proxy.put', {language = 'C'})
//!   box.schema.func.create('proxy.get', {language = 'C'})
//!   box.func['proxy.put']:call{'127.0.0.1:3302', 'hello', 'world'}
//!   box.func['proxy.get']:call{'127.0.0.1:3302', 'hello'} --> 'world'
//!
//! The remote instance needs a `kv` space {key string, value string} that the
//! connecting user (guest here) may read and write.
//!
//! `tarantool-client` is IO-agnostic; `tarantool.fiberio.io()` hands it a
//! `std.Io` whose network waits park the calling fiber in `coio_wait`. While a
//! proc waits for the remote answer, the TX thread keeps serving other requests
//! — the instance may even call itself.

const std = @import("std");
const t = @import("tarantool");
const client = @import("tarantool-client");

const gpa = std.heap.c_allocator;

/// Never wait on a dead peer forever: the connect gives up after 3 seconds.
const connect_timeout: std.Io.Timeout = .{
    .duration = .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake },
};

/// A row of the remote `kv` space.
const Row = struct { []const u8, []const u8 };

fn connect(uri: []const u8) !client.Connection {
    return client.Connection.connect(gpa, t.fiberio.io(), .{
        .address = uri,
        .timeout = connect_timeout,
    });
}

/// proxy.put(uri, key, value): replace `{key, value}` in the remote `kv`.
fn put(uri: []const u8, key: []const u8, value: []const u8) !void {
    var conn = try connect(uri);
    defer conn.close();
    _ = try conn.space("kv").replace(.{ key, value }, void);
}

/// proxy.get(uri, key) -> value | nil: read `key` from the remote `kv`.
fn get(uri: []const u8, key: []const u8) !?[]const u8 {
    var conn = try connect(uri);
    defer conn.close();
    const row = try conn.space("kv").get(.{key}, Row) orelse return null;
    // Decoded strings borrow the connection's receive buffer, which `close`
    // frees: copy the value out first. The fiber region outlives the call's
    // result encoding, which copies it again into the reply.
    return try t.region.allocator().dupe(u8, row[1]);
}

comptime {
    t.proc.exportProc("put", put);
    t.proc.exportProc("get", get);
}
