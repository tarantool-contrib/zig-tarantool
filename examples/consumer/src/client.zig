//! A standalone program that talks to Tarantool over iproto. Installed as
//! `zig-out/bin/hello-client`; connects as guest to `TT_URI`
//! (default `127.0.0.1:3301`), pings and evaluates an expression.

const std = @import("std");
const client = @import("tarantool-client");

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("TT_URI") orelse "127.0.0.1:3301";
    var conn = try client.Connection.connect(init.gpa, init.io, .{
        .address = address,
        .user = "guest",
        .password = "",
    });
    defer conn.close();

    try conn.ping();
    const two = try conn.eval("return 1 + 1", .{}, i64);
    std.debug.print("1 + 1 = {d}\n", .{two});
}
