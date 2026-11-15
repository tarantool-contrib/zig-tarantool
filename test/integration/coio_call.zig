//! Integration coverage for the blocking-work offload + fiber-friendly
//! getaddrinfo (src/coio.zig: `call`/`getAddrInfo`) against a live Tarantool.
//! `coio_call` runs a callback on a worker pthread while the calling fiber
//! yields, so this driver IS the behavioral coverage (the `zig build test`
//! smoke only type-checks the surface). Procs use the raw C ABI and return
//! their result via `proc.returnValue`, mirroring coio.zig/fiber.zig. The
//! offload ticker fiber is spawned via `fiber.spawn` (never hand-rolled).
//!
//! These procs prove end to end:
//!   * a callback that sleeps then returns a magic value round-trips exactly
//!     (`coio_call_roundtrip`);
//!   * a callback that itself returns `-1` comes back as the VALUE `-1`, NOT
//!     `error.OffloadFailed` (`coio_call_negative_passthrough` — the
//!     ran-flag proof);
//!   * the tx event loop keeps running while the worker thread blocks
//!     (`coio_call_loop_alive` observable side);
//!   * `getAddrInfo("localhost")` resolves to ≥1 entry with a non-null addr and
//!     deinits cleanly (`coio_getaddrinfo_localhost`);
//!   * a nonexistent TLD yields `error.ResolveFailed`, not a crash
//!     (`coio_getaddrinfo_bad_host`);
//!   * a 1e-9 s timeout yields `error.Timeout` — validates the "TimedOut"
//!     error-type diag mapping live (`coio_getaddrinfo_tiny_timeout`).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;
const coio = t.coio;

/// libc shims: this host's Zig 0.16 std.posix no longer exposes nanosleep, so
/// we call libc directly (the host links libc).
const libc = std.c;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Sleep `ns` nanoseconds on whatever thread we run on (the coio worker for the
/// offload callbacks). Blocking on purpose — that is what coio_call is for.
fn sleepNs(ns: i64) void {
    var ts: libc.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    _ = libc.nanosleep(&ts, null);
}

// --- Offload callbacks (passed as comptime func to coio.call) ----------------

const RoundtripCtx = struct { magic: i64 };

/// Runs OFF the tx thread: a real ~50ms blocking sleep, then returns the magic
/// so the caller can prove the value round-trips through the worker pool.
fn roundtripCb(ctx: *RoundtripCtx) isize {
    sleepNs(50 * std.time.ns_per_ms);
    return @intCast(ctx.magic);
}

const EmptyCtx = struct {};

/// Returns the value `-1` — which must come back as data, NOT OffloadFailed.
fn negativeCb(_: *EmptyCtx) isize {
    return -1;
}

const SleepCtx = struct { ns: i64 };

/// Blocks the worker thread for `ns`; return value unused. Proves the tx loop
/// stays live while the worker sleeps.
fn sleepCb(ctx: *SleepCtx) isize {
    sleepNs(ctx.ns);
    return 0;
}

// --- File-scope shared state for the loop-alive ticker (reset per proc) -------

var ticks: u64 = 0;
var tick_stop: bool = false;

/// A tx-thread fiber that bumps `ticks` every 2ms until told to stop. If the tx
/// event loop keeps running during the offload, this advances several times.
fn ticker() void {
    while (!tick_stop) {
        ticks += 1;
        fiber.sleep(0.002);
    }
}

// --- Procs -------------------------------------------------------------------

/// coio_call_roundtrip() -> 1. A callback that sleeps ~50ms then returns a magic
/// value; the offloaded return must equal it exactly.
export fn coio_call_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var cctx = RoundtripCtx{ .magic = 424_242 };
    const r = coio.call(RoundtripCtx, roundtripCb, &cctx) catch return fail("call offload failed");
    if (r != 424_242) return fail("roundtrip value mismatch");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_call_negative_passthrough() -> 1. A callback that returns `-1` must
/// surface as the VALUE `-1`, never `error.OffloadFailed` — the ran-flag proof:
/// a `-1` from a callback that ran is data, not infra failure.
export fn coio_call_negative_passthrough(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var cctx = EmptyCtx{};
    const r = coio.call(EmptyCtx, negativeCb, &cctx) catch return fail("callback -1 misread as OffloadFailed");
    if (r != -1) return fail("passthrough value not -1");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_call_loop_alive() -> 1. Spawn a ticker fiber, then offload a ~50ms
/// blocking sleep. If the tx event loop kept running while the worker slept,
/// the ticker advanced several times; assert it advanced at all.
export fn coio_call_loop_alive(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    ticks = 0;
    tick_stop = false;

    var f = fiber.spawn("coio-ticker", ticker, .{}) catch return fail("spawn ticker");

    var sctx = SleepCtx{ .ns = 50 * std.time.ns_per_ms };
    _ = coio.call(SleepCtx, sleepCb, &sctx) catch {
        tick_stop = true;
        f.join();
        return fail("call offload failed");
    };

    tick_stop = true;
    f.join();

    if (ticks < 2) return fail("tx loop did not advance during offload");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_getaddrinfo_localhost() -> 1. Resolve localhost:80; the list has ≥1
/// entry and a non-null addr on the first; deinit is clean.
export fn coio_getaddrinfo_localhost(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const list = coio.getAddrInfo("localhost", "80", null, 5.0) catch return fail("getAddrInfo localhost failed");
    defer list.deinit();

    var it = list.iterator();
    const first = it.next() orelse return fail("localhost yielded no entries");
    if (first.addr == null) return fail("first entry has null addr");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// coio_getaddrinfo_bad_host() -> 1. A nonexistent `.invalid` TLD must yield
/// `error.ResolveFailed` (RFC 2606, fails locally). A `Timeout` here is a FAIL,
/// not a mask — the switch is exhaustive.
export fn coio_getaddrinfo_bad_host(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    _ = coio.getAddrInfo("definitely-not-a-host.invalid", null, null, 5.0) catch |e| switch (e) {
        error.ResolveFailed => return proc.returnValue(ctx, @as(i64, 1)),
        error.Timeout => return fail("bad host timed out instead of ResolveFailed"),
    };
    return fail("bad host resolved unexpectedly");
}

/// coio_getaddrinfo_tiny_timeout() -> 1. A 1e-9 s timeout on a real lookup must
/// yield `error.Timeout` — validates the "TimedOut" error-type diag mapping
/// live.
export fn coio_getaddrinfo_tiny_timeout(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    _ = coio.getAddrInfo("tarantool.org", null, null, 1e-9) catch |e| switch (e) {
        error.Timeout => return proc.returnValue(ctx, @as(i64, 1)),
        error.ResolveFailed => return fail("tiny timeout gave ResolveFailed, not Timeout"),
    };
    return fail("tiny timeout resolved unexpectedly");
}
