//! Integration module exercising the `box.info` introspection namespace and
//! `Space.truncate` against a live Tarantool. Procs use the raw C ABI and
//! return results via `box_return_mp`. The space `t` is created from
//! `introspect_test.lua`, not from here.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const box = t.box;
const info = box.info;
const msgpack = t.msgpack;

/// Return `value` as a single MessagePack-encoded result (box.zig style).
fn returnMp(ctx: ?*c.box_function_ctx_t, value: anytype) c_int {
    var buf = msgpack.Buffer.init(std.heap.c_allocator);
    defer buf.deinit();
    msgpack.encode(&buf, value) catch return -1;
    const bytes = buf.items();
    return c.box_return_mp(ctx.?, bytes.ptr, bytes.ptr + bytes.len);
}

fn setErr(msg: []const u8) c_int {
    t.err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// intro_snapshot(): assert the writable-instance invariants in-proc and return
/// true. status running, not RO, no reason, non-negative LSN, and the slab
/// used<=size / quota>0 relations.
export fn intro_snapshot(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (info.status() != .running) return setErr("status not running");
    if (info.isRo()) return setErr("instance unexpectedly read-only");
    if (info.roReason() != null) return setErr("roReason non-null while writable");

    const l = info.lsn() orelse return setErr("lsn null on bootstrapped instance");
    if (l < 0) return setErr("lsn negative");

    if (info.slab(.quota_size) == 0) return setErr("quota_size is zero");
    if (info.slab(.arena_used) > info.slab(.arena_size)) return setErr("arena_used > arena_size");
    if (info.slab(.items_used) > info.slab(.items_size)) return setErr("items_used > items_size");

    return returnMp(ctx, true);
}

/// intro_ro_probe(): on a read-only instance, assert isRo, a non-empty reason,
/// and that waitRo(true, 1) returns immediately; return the reason string.
export fn intro_ro_probe(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (!info.isRo()) return setErr("instance not read-only");
    {
        const reason = info.roReason() orelse return setErr("roReason null while RO");
        if (reason.len == 0) return setErr("roReason empty");
    }
    // Already RO: this must return ok (0) instantly.
    info.waitRo(true, 1) catch return setErr("waitRo(true,1) did not report RO");

    // Re-fetch for the return; the instance is still RO. returnMp copies the
    // borrowed string during encode before any further box call.
    const reason = info.roReason() orelse return setErr("roReason null on re-fetch");
    return returnMp(ctx, reason);
}

/// intro_wait_ro(ro, timeout): call waitRo and report the outcome as a string.
/// The timeout is decoded flexibly: Tarantool encodes an integral Lua number
/// (e.g. `1`, `5`) as a msgpack integer, not a float, so accept int or float.
export fn intro_wait_ro(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const v = dec.decodeValue(std.heap.c_allocator) catch
        return setErr("intro_wait_ro: decode failed");
    defer msgpack.freeValue(std.heap.c_allocator, v);

    const arr = switch (v) {
        .array => |a| a,
        else => return setErr("intro_wait_ro: expected an array"),
    };
    if (arr.len != 2) return setErr("intro_wait_ro: expected 2 args");
    const ro = switch (arr[0]) {
        .bool => |b| b,
        else => return setErr("intro_wait_ro: arg0 not a bool"),
    };
    const timeout: f64 = switch (arr[1]) {
        .float => |f| f,
        .uint => |u| @floatFromInt(u),
        .int => |i| @floatFromInt(i),
        else => return setErr("intro_wait_ro: arg1 not a number"),
    };

    info.waitRo(ro, timeout) catch |e| switch (e) {
        error.Timeout => return returnMp(ctx, "timeout"),
        error.Cancelled => return returnMp(ctx, "cancelled"),
    };
    return returnMp(ctx, "ok");
}

/// intro_wait_ro_cancel(): spawn an inner fiber parked in waitRo(true, 5),
/// cancel it, join (never join_timeout — it poisons the fiber), and assert the
/// result is error.Cancelled. Only the inner fiber is cancelled, never the proc
/// fiber. Returns true.
export fn intro_wait_ro_cancel(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const Body = struct {
        fn run() info.WaitError!void {
            return info.waitRo(true, 5);
        }
    };

    // spawn runs the fiber up to its first yield: it enters box_wait_ro and
    // parks before control returns here.
    const fib = t.fiber.spawn("intro_wait_cancel", Body.run, .{}) catch
        return setErr("spawn failed");
    fib.cancel();
    const res = fib.join();
    if (res) |_| {
        return setErr("expected Cancelled, got ok");
    } else |e| {
        if (e != error.Cancelled) return setErr("expected Cancelled");
    }
    return returnMp(ctx, true);
}

/// intro_schema_version(): return box.info.schemaVersion().
export fn intro_schema_version(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return returnMp(ctx, info.schemaVersion());
}

/// intro_lsn(): return box.info.lsn() (non-null on a bootstrapped instance).
export fn intro_lsn(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const l = info.lsn() orelse return setErr("lsn null");
    return returnMp(ctx, l);
}

/// intro_truncate(): truncate space `t`; a -1 host return surfaces via setErr.
export fn intro_truncate(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const space = box.Space.byName("t") catch return setErr("no space t");
    space.truncate() catch return setErr("truncate failed");
    return returnMp(ctx, true);
}
