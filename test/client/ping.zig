//! Harness exe: exercise the live `tarantool-client` connect/ping/auth path
//! against the server the luatest `client` group starts. Standalone binary —
//! importing `tarantool-client` and LINKING with no `box_*` symbols available is
//! itself the module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` (and optional `TT_DEAD_PORT`) from the
//! environment, runs a fixed sequence of checks, and prints TAP-ish lines
//! (`ok - <name>` / `not ok - <name> (<detail>)`). Exits 1 on the FIRST failing
//! check, 0 once every check passed — the luatest driver asserts the exit code
//! and surfaces the captured TAP text on failure.
//!
//! The `io` is the runtime's default `std.Io.Threaded` implementation, handed in
//! via `std.process.Init` (which also carries the parsed environment and a gpa);
//! the client itself never names an Io implementation.

const std = @import("std");
const client = @import("tarantool-client");

const Connection = client.Connection;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const uri = env.get("TT_URI") orelse return missing("TT_URI");
    const user = env.get("TT_USER") orelse return missing("TT_USER");
    const pass = env.get("TT_PASS") orelse return missing("TT_PASS");
    const dead_port = env.get("TT_DEAD_PORT") orelse "1";

    // 1. connect as the granted test user -> ping -> close.
    {
        var conn = Connection.connect(gpa, io, .{
            .address = uri,
            .user = user,
            .password = pass,
        }) catch |e| return fail("connect as test user", @errorName(e));
        conn.ping() catch |e| {
            conn.close();
            return fail("ping as test user", @errorName(e));
        };
        conn.close();
        ok("connect+ping+close as test user");
    }

    // 2. connect as guest with an empty password (AUTH skipped) -> ping.
    {
        var conn = Connection.connect(gpa, io, .{
            .address = uri,
            .user = "guest",
            .password = "",
        }) catch |e| return fail("connect as guest", @errorName(e));
        conn.ping() catch |e| {
            conn.close();
            return fail("ping as guest", @errorName(e));
        };
        conn.close();
        ok("connect+ping+close as guest");
    }

    // 3. connect as the test user with a WRONG password -> expect AuthFailed.
    {
        if (Connection.connect(gpa, io, .{
            .address = uri,
            .user = user,
            .password = "wrong-password-on-purpose",
        })) |conn_val| {
            var conn = conn_val;
            conn.close();
            return fail("wrong password rejected", "connect unexpectedly succeeded");
        } else |e| switch (e) {
            error.AuthFailed => ok("wrong password -> error.AuthFailed"),
            else => return fail("wrong password rejected", @errorName(e)),
        }
    }

    // 4. connect to a dead port on the same host -> expect a connect error.
    {
        const colon = std.mem.lastIndexOfScalar(u8, uri, ':') orelse
            return fail("dead port errors", "TT_URI has no host:port form");
        const host = uri[0..colon];
        var addr_buf: [64]u8 = undefined;
        const dead_addr = std.fmt.bufPrint(&addr_buf, "{s}:{s}", .{ host, dead_port }) catch
            return fail("dead port errors", "dead address does not fit buffer");
        if (Connection.connect(gpa, io, .{
            .address = dead_addr,
            .user = user,
            .password = pass,
        })) |conn_val| {
            var conn = conn_val;
            conn.close();
            return fail("dead port errors", "connect to dead port unexpectedly succeeded");
        } else |_| {
            ok("connect to dead port errors");
        }
    }

    return 0;
}

/// Print a passing TAP line.
fn ok(name: []const u8) void {
    std.debug.print("ok - {s}\n", .{name});
}

/// Print a failing TAP line and yield the process exit code (1).
fn fail(name: []const u8, detail: []const u8) u8 {
    std.debug.print("not ok - {s} ({s})\n", .{ name, detail });
    return 1;
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
