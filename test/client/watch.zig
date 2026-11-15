//! Harness exe: exercise the live `tarantool-client` WATCHER surface (the
//! caller-pumped event mailbox — watch/waitEvent/pollEvent/unwatch/watchOnce,
//! with auto-re-arm) against the server the luatest `watch` group starts.
//! Standalone binary importing `tarantool-client` and LINKING with no `box_*`
//! symbols — the module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, and drives the watch protocol against a known-broadcast
//! key `wkey`. The luatest group's before_each broadcasts `wkey = 100` BEFORE the
//! exe runs, so the initial EVENT after WATCH carries a deterministic value
//! (simpler than the never-broadcast null case). Prints TAP-ish lines (`ok - …` /
//! `not ok - … (<detail>)`); exits 1 on the FIRST failing check, 0 once every
//! check passed — the luatest driver asserts the exit code and surfaces the
//! captured TAP on failure.
//!
//! Ack/coalescing: after two rapid broadcasts (43 then 44) with
//! a single intervening re-arm, the exe prints the value the live server actually
//! delivered — 44 if the server coalesced 43 away, or 43 if 43 landed first and 44
//! trails. BOTH are correct live truths (the interleave is nondeterministic); the
//! exe asserts the delivered value is one of {43, 44} and prints which, pinning
//! the observed behavior rather than forcing an expectation.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");

const Connection = client.Connection;

const wkey = "wkey";
const initial_value: i64 = 100; // broadcast by the luatest group's before_each

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const uri = env.get("TT_URI") orelse return missing("TT_URI");
    const user = env.get("TT_USER") orelse return missing("TT_USER");
    const pass = env.get("TT_PASS") orelse return missing("TT_PASS");

    var conn = Connection.connect(gpa, io, .{
        .address = uri,
        .user = user,
        .password = pass,
    }) catch |e| return fail("connect as test user", @errorName(e));
    defer conn.close();

    return run(&conn);
}

/// The check sequence over an established connection. Returns 0 iff every check
/// passed, else 1 (after the first failing check printed its `not ok` line).
fn run(conn: *Connection) u8 {
    // 1. watch(wkey) -> waitEvent -> the initial EVENT carries the pre-broadcast
    //    value (100). key matches; data decodes to the known value.
    {
        conn.watch(wkey) catch |e| return fail("watch(wkey)", @errorName(e));
        const ev = conn.waitEvent() catch |e| return fail("waitEvent initial", @errorName(e));
        if (!std.mem.eql(u8, ev.key, wkey)) return failFmt("initial event key", "got key '{s}'", .{ev.key});
        const v = decodeI64(ev.data) catch |e| return fail("initial event data decode", @errorName(e));
        if (v != initial_value) return failFmt("initial event data", "got {d}, want {d}", .{ v, initial_value });
        ok("watch: initial EVENT carries the pre-broadcast value (100)");
    }

    // 2. eval box.broadcast(wkey, 42) -> waitEvent -> 42. Depending on the wire
    //    interleave the EVENT is either parked during the eval roundtrip or read
    //    fresh here — both correct; the delivered value is 42 either way.
    {
        broadcast(conn, 42) catch |e| return fail("broadcast(42)", @errorName(e));
        const ev = conn.waitEvent() catch |e| return fail("waitEvent after broadcast(42)", @errorName(e));
        const v = decodeI64(ev.data) catch |e| return fail("event(42) data decode", @errorName(e));
        if (v != 42) return failFmt("event after broadcast(42)", "got {d}, want 42", .{v});
        ok("watch: broadcast(42) -> waitEvent delivers 42");
    }

    // 3. Two rapid broadcasts (43 then 44) with a single intervening re-arm.
    //    The server may coalesce 43 away (delivering 44) or land 43 first — assert
    //    the delivered value is one of {43, 44} and PRINT which (deliverable).
    {
        broadcast(conn, 43) catch |e| return fail("broadcast(43)", @errorName(e));
        broadcast(conn, 44) catch |e| return fail("broadcast(44)", @errorName(e));
        const ev = conn.waitEvent() catch |e| return fail("waitEvent after broadcast(43,44)", @errorName(e));
        const v = decodeI64(ev.data) catch |e| return fail("event(43/44) data decode", @errorName(e));
        if (v != 43 and v != 44) return failFmt("coalescing event", "got {d}, want 43 or 44", .{v});
        if (v == 44) {
            ok("watch: coalescing — broadcast(43),broadcast(44) delivered 44 (43 coalesced away)");
        } else {
            ok("watch: coalescing — broadcast(43),broadcast(44) delivered 43 (43 landed first, 44 trails)");
        }
    }

    // 4. pollEvent on an empty queue -> null (it does NO I/O, so a value pending
    //    unread on the socket does not appear here).
    {
        if (conn.pollEvent()) |ev| return failFmt("pollEvent empty", "expected null, got key '{s}'", .{ev.key});
        ok("watch: pollEvent on an empty queue -> null");
    }

    // 5. unwatch(wkey) -> broadcast(99) -> ping -> pollEvent -> null: after
    //    unregistering, the read path DROPS any further EVENTs for wkey (both the
    //    post-unwatch broadcast and any pre-unwatch event still in flight).
    {
        conn.unwatch(wkey) catch |e| return fail("unwatch(wkey)", @errorName(e));
        broadcast(conn, 99) catch |e| return fail("broadcast(99) after unwatch", @errorName(e));
        conn.ping() catch |e| return fail("ping after unwatch", @errorName(e)); // pump the socket
        if (conn.pollEvent()) |ev| return failFmt("drop-after-unwatch", "expected null, got key '{s}'", .{ev.key});
        ok("watch: unwatch drops later events (pollEvent -> null)");
    }

    // 6. watchOnce(wkey) -> the current value, which is the LAST broadcast (99). An
    //    ordinary roundtrip (no registration, no re-arm, no mailbox).
    {
        const v = conn.watchOnce(wkey, ?i64) catch |e| return fail("watchOnce(wkey)", @errorName(e));
        const got = v orelse return fail("watchOnce(wkey) value", "expected 99, got null");
        if (got != 99) return failFmt("watchOnce(wkey)", "got {d}, want 99 (last broadcast)", .{got});
        ok("watch: watchOnce(wkey) -> 99 (the last broadcast value)");
    }

    // 7. The connection is still fully usable after all the watch traffic.
    {
        conn.ping() catch |e| return fail("ping after watch surface", @errorName(e));
        const two = conn.eval("return 1 + 1", .{}, i64) catch |e| return fail("eval 1+1", @errorName(e));
        if (two != 2) return failFmt("eval 1+1", "got {d}, want 2", .{two});
        ok("watch: connection still usable (ping + eval)");
    }

    return 0;
}

/// eval `box.broadcast('wkey', <v>)` — fire the notification and discard the
/// (empty) return. The value rides EVENT_DATA to every armed watcher.
fn broadcast(conn: *Connection, v: i64) !void {
    var buf: [64]u8 = undefined;
    const expr = std.fmt.bufPrint(&buf, "box.broadcast('{s}', {d})", .{ wkey, v }) catch unreachable;
    try conn.eval(expr, .{}, void);
}

/// Decode the raw EVENT_DATA msgpack (an integral scalar) into an i64. A null
/// payload (key holds no value) is a decode failure the caller reports — the
/// broadcasts in this harness always carry a value.
fn decodeI64(data: ?[]const u8) !i64 {
    const bytes = data orelse return error.EventDataAbsent;
    var dec = msgpack.Decoder.init(bytes);
    return msgpack.decode(i64, &dec);
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

/// `fail` with a formatted detail (e.g. an unexpected value).
fn failFmt(name: []const u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "detail too long to format";
    return fail(name, detail);
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
