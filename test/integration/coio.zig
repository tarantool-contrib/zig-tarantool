//! Integration coverage for the cooperative fd-readiness free functions
//! (src/coio.zig: `wait`/`close`) against a live Tarantool. `coio_wait` parks a
//! fiber on the host event loop, so this driver IS the behavioral coverage (the
//! `zig build test` smoke only type-checks the surface and the comptime bitcast).
//! Procs use the raw C ABI and return their result via `proc.returnValue`,
//! mirroring fiber.zig/cond.zig. Every waiter fiber is spawned via `fiber.spawn`
//! (the closure travels through fiber_start's varargs — we never hand-roll
//! fiber_set_ctx, which is unreliable on this host).
//!
//! The driver owns the fds it waits on (coio owns no host resource). It
//! sets them non-blocking itself via `fcntl` (is the DRIVER's precondition
//! to satisfy; coio performs no implicit fcntl). Note on Zig: this host's
//! 0.16 std.posix dropped `pipe`/`fcntl`/`write`/`read`/`close`, so the driver
//! uses the libc shims in `std.c` directly (the build links libc for the host).
//!
//! These procs prove end to end:
//!   * a fiber parked in `wait(read, .read)` wakes with `Events.read == true`
//!     once a byte is written to the write end (`coio_wait_readable`);
//!   * a `wait` with nothing to read returns `Error.Timeout` — a 0 host return
//!     is an ERROR, never an empty Events (`coio_wait_timeout`);
//!   * `close` on the fd a fiber is parked on synchronously wakes that fiber so
//!     it unblocks at all (`coio_close_wakes_waiter` — we assert
//!     only that it returns, not which arm).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;
const coio = t.coio;

/// libc shims: this host's Zig 0.16 std.posix no longer exposes
/// pipe/fcntl/write/read/close, so we call libc directly (the host links libc).
const libc = std.c;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Close both ends of a pipe — used on the setup/spawn error paths so a failed
/// proc does not leak fds into the long-running Tarantool process.
fn closePair(read_fd: libc.fd_t, write_fd: libc.fd_t) void {
    _ = libc.close(read_fd);
    _ = libc.close(write_fd);
}

/// Make `fd` non-blocking (is the driver's precondition to satisfy — coio
/// does no implicit fcntl). Returns false on any libc failure (no silent
/// fallback: the proc turns this into a `fail`).
fn setNonBlocking(fd: libc.fd_t) bool {
    const flags = libc.fcntl(fd, libc.F.GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(libc.O{ .NONBLOCK = true });
    return libc.fcntl(fd, libc.F.SETFL, @as(c_int, @intCast(flags)) | nonblock) >= 0;
}

// --- File-scope shared state (reset at the top of each proc) -----------------

/// Set true by the readable-waiter once `wait` returned without error.
var readable_ok: bool = false;
/// The `Events` the readable-waiter observed (only meaningful when readable_ok).
var readable_events: coio.Events = .{};
/// Set true by the close-waiter the instant its `wait` returns by ANY arm
/// (fired Events, Timeout, or CoioOp) — the point is it unblocked at all.
var close_waiter_unblocked: bool = false;

// --- Fiber bodies (passed as comptime func to fiber.spawn) -------------------

/// Parks in `wait(fd, .read, 1.0)`; on a clean (>0) return records the Events
/// and success. An error leaves readable_ok = false (the proc then fails).
fn readableWaiter(fd: c_int) void {
    const ev = coio.wait(fd, .{ .read = true }, 1.0) catch return;
    readable_events = ev;
    readable_ok = true;
}

/// Parks in `wait(fd, .read, 5.0)` — a long timeout, so it would hang here
/// unless woken. Records that it unblocked REGARDLESS of which arm it returns
/// by: success, Timeout, or CoioOp all count as "it returned".
fn closeWaiter(fd: c_int) void {
    _ = coio.wait(fd, .{ .read = true }, 5.0) catch {
        close_waiter_unblocked = true;
        return;
    };
    close_waiter_unblocked = true;
}

// --- Procs ------------------------------------------------------------------

/// coio_events_bits() -> 1. Pure bitcast helpers — no fd, no fiber. Verifies
/// toInt/fromInt/isEmpty return the exact COIO_READ/COIO_WRITE bit values.
export fn coio_events_bits(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if ((coio.Events{ .read = true }).toInt() != 1) return fail("toInt read");
    if ((coio.Events{ .read = true, .write = true }).toInt() != 3) return fail("toInt rw");
    const d = coio.Events.fromInt(2);
    if (!(d.write and !d.read)) return fail("fromInt 2");
    if (!(coio.Events{}).isEmpty()) return fail("isEmpty empty");
    if ((coio.Events{ .read = true }).isEmpty()) return fail("isEmpty read");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_wait_readable() -> 1. Create a non-blocking pipe; spawn a fiber that
/// parks in `wait(read_fd, .read, 1.0)`. spawn runs the waiter to its first
/// yield (the coio_wait park), then the proc writes one byte to the write end
/// and joins. Returns 1 iff the waiter woke with `Events.read == true`.
export fn coio_wait_readable(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    readable_ok = false;
    readable_events = .{};

    var fds: [2]libc.fd_t = undefined;
    if (libc.pipe(&fds) != 0) return fail("pipe");
    const read_fd = fds[0];
    const write_fd = fds[1];
    if (!setNonBlocking(read_fd) or !setNonBlocking(write_fd)) {
        closePair(read_fd, write_fd);
        return fail("fcntl");
    }

    var f = fiber.spawn("coio-readable", readableWaiter, .{@as(c_int, read_fd)}) catch {
        closePair(read_fd, write_fd);
        return fail("spawn");
    };

    // The waiter is now parked in coio_wait (spawn ran it to its first yield).
    // Make the read end readable; the host event loop wakes the waiter. The
    // waiter still holds read_fd, so on a write failure we join it (it will time
    // out) before closing, rather than leaking the fiber or the fds.
    const byte = [_]u8{0};
    if (libc.write(write_fd, &byte, 1) != 1) {
        f.join();
        closePair(read_fd, write_fd);
        return fail("write");
    }

    f.join();

    _ = libc.close(read_fd);
    _ = libc.close(write_fd);

    if (!readable_ok) return fail("wait did not return Events");
    if (!readable_events.read) return fail("Events.read not set");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_wait_timeout() -> 1. Create a non-blocking pipe but write NOTHING; in
/// the proc's own fiber, `wait(read_fd, .read, 0.01)` must return Error.Timeout
/// (a 0 host return is an ERROR, never an empty Events). Returns 1 iff
/// exactly Timeout was observed.
export fn coio_wait_timeout(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var fds: [2]libc.fd_t = undefined;
    if (libc.pipe(&fds) != 0) return fail("pipe");
    const read_fd = fds[0];
    const write_fd = fds[1];
    if (!setNonBlocking(read_fd) or !setNonBlocking(write_fd)) {
        closePair(read_fd, write_fd);
        return fail("fcntl");
    }

    var timed_out = false;
    _ = coio.wait(read_fd, .{ .read = true }, 0.01) catch |e| switch (e) {
        error.Timeout => timed_out = true,
        error.CoioOp => {
            closePair(read_fd, write_fd);
            return fail("wait returned CoioOp, expected Timeout");
        },
    };

    closePair(read_fd, write_fd);

    if (!timed_out) return fail("wait did not time out");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_close_wakes_waiter() -> 1. Spawn a fiber that parks in
/// `wait(read_fd, .read, 5.0)` (a long timeout, so it would hang if not woken).
/// spawn runs it to that park; the proc then `coio.close(read_fd)` which BOTH
/// closes the fd AND synchronously schedules the waiter's wakeup. We do
/// NOT also close read_fd (coio.close already did). Join, then close
/// the write end. Returns 1 iff the waiter unblocked at all (assert it
/// returned, NOT which arm).
export fn coio_close_wakes_waiter(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    close_waiter_unblocked = false;

    var fds: [2]libc.fd_t = undefined;
    if (libc.pipe(&fds) != 0) return fail("pipe");
    const read_fd = fds[0];
    const write_fd = fds[1];
    if (!setNonBlocking(read_fd) or !setNonBlocking(write_fd)) {
        closePair(read_fd, write_fd);
        return fail("fcntl");
    }

    // Spawn first: the waiter runs to its coio_wait park before spawn returns.
    var f = fiber.spawn("coio-close", closeWaiter, .{@as(c_int, read_fd)}) catch {
        closePair(read_fd, write_fd);
        return fail("spawn");
    };

    // Wake the parked waiter by closing the fd it is parked on (close both
    // closes read_fd and schedules the wakeup). Do NOT std.c.close(read_fd) too.
    coio.close(read_fd) catch {
        // coio.close owns read_fd's state on failure — don't double-close it;
        // reap the waiter (its 5s timeout guarantees it returns) and close the
        // write end so neither the fiber nor write_fd leaks.
        f.join();
        _ = libc.close(write_fd);
        return fail("coio.close");
    };

    f.join();

    _ = libc.close(write_fd);

    if (!close_waiter_unblocked) return fail("waiter did not unblock on close");
    return proc.returnValue(ctx, @as(i64, 1));
}
