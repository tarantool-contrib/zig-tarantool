//! Integration coverage for the `Cond` handle (src/cond.zig) against a live
//! Tarantool. A fiber cond is meaningless without a real host scheduler (the
//! `zig build test` smoke only type-checks the surface), so this driver IS the
//! behavioral coverage. Procs use the raw C ABI and return their result via
//! `proc.returnValue`, mirroring fiber.zig. Every waiter fiber is spawned via
//! `fiber.spawn` (the closure travels through fiber_start's varargs — we never
//! hand-roll fiber_set_ctx, which is unreliable on this host).
//!
//! These procs prove end to end:
//!   * signal wakes exactly one waiter, which observes the predicate flipped
//!     before the signal (`cond_signal_handshake`);
//!   * broadcast makes all current waiters runnable (`cond_broadcast_multi`,
//! — final count, driven over enough reschedules);
//!   * a waitTimeout timeout does NOT poison the cond — it stays reusable
//!     (`cond_timeout_then_reuse`, the headline contrast with the dropped
//!     fiber_join_timeout);
//!   * a wait surfaces Error.Cancelled on fiber cancel without crashing the host
//!     (`cond_cancel_waiter`);
//!   * waitUntil returns ok when the predicate holds and Error.Timeout within
//!     the deadline when it never does (`cond_wait_until`).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;
const cond = t.cond;

const Cond = cond.Cond;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Sentinel a cancelled waiter stores when it sees Error.Cancelled.
const CANCEL_SENTINEL: i64 = 42;

// --- File-scope shared state (reset at the top of each proc) -----------------

/// Flipped by a proc before it signals; a waiter re-checks it after each wake
///  and reports whether it observed the flip.
var predicate: bool = false;
/// Bumped by each broadcast waiter once it wakes.
var woke_count: i64 = 0;
/// Set by the cancelled waiter to CANCEL_SENTINEL iff it saw Error.Cancelled.
var cancel_observed: i64 = 0;
/// Set by the handshake waiter to 1 iff it observed the flipped predicate.
var handshake_ok: i64 = 0;
/// Set by the post-timeout reuse waiter to 1 iff its wait woke cleanly.
var reuse_ok: i64 = 0;
/// Set by the waitUntil waiter to 1 iff its predicate-driven wait returned ok.
var until_ok: i64 = 0;
/// A predicate that never flips, for the waitUntil timeout leg.
var never: bool = false;

// --- Predicates for waitUntil ------------------------------------------------

fn predFn(ctx: *const bool) bool {
    return ctx.*;
}

fn neverFn(ctx: *const bool) bool {
    // Structurally never true (the timeout leg must not depend on the
    // `never` variable staying false); the `*const bool` shape only matches
    // waitUntil's `pred: fn (@TypeOf(context)) bool` against `&never`.
    _ = ctx;
    return false;
}

// --- Fiber bodies (passed as comptime func to fiber.spawn) -------------------

/// Loops `cond.wait()` re-checking the predicate after each wake (raw wait
/// does NOT loop internally). Records whether it ultimately saw the flip.
fn handshakeWaiter(co: Cond) void {
    while (!predicate) {
        co.wait() catch return; // Cancelled: leave handshake_ok = 0.
    }
    handshake_ok = 1;
}

/// One broadcast waiter: waits once (re-checking the predicate per), then
/// bumps the shared count.
fn broadcastWaiter(co: Cond) void {
    while (!predicate) {
        co.wait() catch return;
    }
    woke_count += 1;
}

/// Post-timeout reuse waiter: waits, re-checking the predicate; on a clean
/// wake with the predicate set, records reuse success.
fn reuseWaiter(co: Cond) void {
    while (!predicate) {
        co.wait() catch return;
    }
    reuse_ok = 1;
}

/// Cancel waiter: an infinite wait that surfaces Error.Cancelled on cancel.
/// Records the sentinel iff it saw exactly Cancelled.
fn cancelWaiter(co: Cond) void {
    co.wait() catch |e| switch (e) {
        error.Cancelled => {
            cancel_observed = CANCEL_SENTINEL;
            return;
        },
        else => return,
    };
    // A spurious-but-clean wake would be wrong here; leave cancel_observed = 0.
}

/// waitUntil waiter: blocks on the predicate via waitUntil; the proc flips
/// `predicate` then signals (predicate-before-signal). Records ok on success.
fn untilWaiter(co: Cond) void {
    co.waitUntil(&predicate, predFn, 1.0) catch return;
    until_ok = 1;
}

// --- Procs ------------------------------------------------------------------

/// cond_signal_handshake() -> 1. Spawn a waiter that loops cond.wait() until the
/// shared predicate flips; flip the predicate BEFORE signalling (the
/// woken fiber observes the flip), signal one waiter, reschedule to let it run,
/// join. Returns 1 iff the waiter observed the flipped predicate.
export fn cond_signal_handshake(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    predicate = false;
    handshake_ok = 0;

    var co = Cond.init() catch return fail("cond init");
    var f = fiber.spawn("hs-waiter", handshakeWaiter, .{co}) catch return fail("spawn");

    // The waiter has run to its first cond.wait() (spawn yields). Flip the
    // predicate before signalling so the woken fiber observes it.
    predicate = true;
    co.signal();
    fiber.reschedule();
    f.join();
    co.deinit(); // safe: the only waiter has joined.

    return proc.returnValue(ctx, handshake_ok);
}

/// cond_broadcast_multi() -> 3. Spawn N=3 waiters each doing cond.wait() then
/// bumping woke_count; flip the predicate, broadcast, then drive reschedules to
/// let all waiters wake (a broadcast may need >1 scheduler pass). Joins all,
/// returns the FINAL woke_count (asserts 3 Lua-side).
export fn cond_broadcast_multi(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    predicate = false;
    woke_count = 0;

    var co = Cond.init() catch return fail("cond init");

    const N = 3;
    var fibers: [N]@TypeOf(fiber.spawn("", broadcastWaiter, .{co}) catch unreachable) = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        fibers[i] = fiber.spawn("bc-waiter", broadcastWaiter, .{co}) catch return fail("spawn");
    }

    // Flip before broadcasting so every woken waiter sees it.
    predicate = true;
    co.broadcast();

    // Drive a bounded number of reschedules; assert the FINAL count, not an
    // intermediate ordering. With 3 waiters one pass usually suffices, but give
    // ample slack — if 3 wakeups never land, that is a finding (do NOT loosen).
    var passes: usize = 0;
    while (passes < 16) : (passes += 1) fiber.reschedule();

    i = 0;
    while (i < N) : (i += 1) fibers[i].join();
    co.deinit(); // safe: all waiters joined.

    return proc.returnValue(ctx, woke_count);
}

/// cond_timeout_then_reuse() -> 1. In the proc's OWN fiber, waitTimeout(0.01)
/// with no signal -> Error.Timeout. Then REUSE the same cond: spawn a waiter,
/// flip the predicate, signal, join. Returns 1 iff BOTH the timeout fired AND
/// the reuse woke cleanly (a timeout does not poison the cond).
export fn cond_timeout_then_reuse(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    predicate = false;
    reuse_ok = 0;

    var co = Cond.init() catch return fail("cond init");

    var timed_out = false;
    co.waitTimeout(0.01) catch |e| switch (e) {
        error.Timeout => timed_out = true,
        else => return fail("expected Timeout"),
    };

    // Reuse the SAME cond after the timeout.
    var f = fiber.spawn("reuse-waiter", reuseWaiter, .{co}) catch return fail("spawn");
    predicate = true;
    co.signal();
    fiber.reschedule();
    f.join();
    co.deinit(); // safe: the only waiter has joined.

    const both: i64 = if (timed_out and reuse_ok == 1) 1 else 0;
    return proc.returnValue(ctx, both);
}

/// cond_cancel_waiter() -> CANCEL_SENTINEL (42). Spawn a waiter on an infinite
/// cond.wait(); cancel it via the Fiber handle; the wait surfaces
/// Error.Cancelled and the waiter stores the sentinel; join. Returns the
/// sentinel iff the waiter saw Cancelled — and the host did not crash.
export fn cond_cancel_waiter(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    cancel_observed = 0;

    var co = Cond.init() catch return fail("cond init");
    var f = fiber.spawn("cancel-waiter", cancelWaiter, .{co}) catch return fail("spawn");

    // The waiter is parked in cond.wait(). Cancel wakes it with -1, which
    // surfaces as Error.Cancelled.
    f.cancel();
    fiber.reschedule();
    f.join();
    co.deinit(); // safe: the only waiter has joined.

    return proc.returnValue(ctx, cancel_observed);
}

/// cond_wait_until() -> 1. Exercises waitUntil both ways:
///   (a) a waiter blocks on waitUntil(&predicate, predFn, 1.0); the proc flips
///       the predicate then signals (predicate-before-signal) -> waiter returns
///       ok (until_ok == 1);
///   (b) in the proc's OWN fiber, waitUntil(&never, neverFn, 0.02) with a
///       predicate that stays false returns Error.Timeout within the deadline.
///
/// Returns 1 iff BOTH hold.
export fn cond_wait_until(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    predicate = false;
    never = false;
    until_ok = 0;

    var co = Cond.init() catch return fail("cond init");

    // (a) predicate-driven waitUntil wakes after the proc flips + signals.
    var f = fiber.spawn("until-waiter", untilWaiter, .{co}) catch return fail("spawn");
    predicate = true;
    co.signal();
    fiber.reschedule();
    f.join();

    // (b) a never-true predicate returns Timeout within the deadline.
    var timed_out = false;
    co.waitUntil(&never, neverFn, 0.02) catch |e| switch (e) {
        error.Timeout => timed_out = true,
        else => return fail("expected Timeout from waitUntil"),
    };

    co.deinit(); // safe: the (a) waiter joined; (b) ran in this fiber.

    const both: i64 = if (until_ok == 1 and timed_out) 1 else 0;
    return proc.returnValue(ctx, both);
}
