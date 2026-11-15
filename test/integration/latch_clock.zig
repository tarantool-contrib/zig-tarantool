//! Integration coverage for the `Latch` fiber-mutex handle (src/latch.zig) and
//! the `clock` wrappers (src/clock.zig) against a live Tarantool. Both are
//! host-bound — a latch is meaningless without a real scheduler and the clocks
//! are host syscall wrappers — so `zig build test` only type-checks the surface;
//! this driver IS the behavioral coverage. Procs use the raw C ABI and return
//! their result via `proc.returnValue`, mirroring cond.zig. Every waiter fiber
//! is spawned via `fiber.spawn` (the closure travels through fiber_start's
//! varargs — we never hand-roll fiber_set_ctx, which is unreliable on this host).
//!
//! Procs prove end to end:
//!   * mutual exclusion — `tryLock` on a held latch is false; a parked `lock`
//!     acquires only after the owner unlocks (`latch_mutex`);
//!   * FIFO grant order — two waiters parked in known order acquire in that
//!     order, deterministic by park-order construction, zero sleeps
//!     (`latch_fifo`);
//!   * `withLock` releases on BOTH the value and error return paths
//!     (`latch_with_lock`);
//!   * `tryLock` on a latch held by the CALLING fiber returns false without
//!     deadlocking (`latch_trylock_self`);
//!   * clock monotonic growth, the `*64 ≈ double × 1e9` units cross-check, and
//!     CPU-clock advance across a busy loop (`clock_invariants`);
//!   * a module-side realtime for the Lua-vs-module wall-clock window
//!     (`clock_realtime_now`).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;
const latch = t.latch;
const clock = t.clock;

const Latch = latch.Latch;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

// --- File-scope shared state (reset at the top of each proc) -----------------

/// `latch_mutex`: waiter B records `tryLock()` while the proc holds the latch
/// (must be false). Init to `true` so a never-run waiter fails the check loudly.
var mtx_try_while_held: bool = true;
/// `latch_mutex`: waiter B sets this after it acquires the latch post-unlock.
var mtx_acquired: bool = false;

/// `latch_fifo`: acquisition order recorded by the two waiters, in the slot
/// named by `fifo_n` at the moment each acquires.
var fifo_order: [2]i64 = .{ 0, 0 };
var fifo_n: usize = 0;

// --- Fiber bodies (passed as comptime func to fiber.spawn) -------------------

/// `latch_mutex` waiter B: records `tryLock()` while the proc still holds the
/// latch (runs before spawn returns) — expected false — then parks in
/// `lock()`. When the proc unlocks, ownership passes here: sets the
/// acquired flag and unlocks.
fn mutexWaiter(la: Latch) void {
    mtx_try_while_held = la.tryLock(); // latch held by proc -> false
    la.lock(); // parks; resumes after the proc unlocks
    mtx_acquired = true;
    la.unlock();
}

/// `latch_fifo` waiter: acquires the latch (parking in FIFO request order),
/// records its `val` in the next slot, and unlocks.
fn fifoWaiter(la: Latch, val: i64) void {
    la.lock();
    fifo_order[fifo_n] = val;
    fifo_n += 1;
    la.unlock();
}

// --- withLock closures -------------------------------------------------------

fn incrFn(ctx: *i64) i64 {
    ctx.* += 1;
    return ctx.*;
}

fn boomFn(ctx: *i64) error{Boom}!i64 {
    ctx.* += 1;
    return error.Boom;
}

// --- busy loop for the CPU-clock leg -----------------------------------------

fn busyLoop(iters: u64) u64 {
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) sum +%= i *% 2654435761;
    return sum;
}

// --- Procs ------------------------------------------------------------------

/// latch_mutex() -> 1. Proc locks the latch, spawns waiter B. B records
/// `tryLock()` while the latch is held (false) then parks in `lock()` — both
/// before spawn returns. Proc unlocks; a bounded reschedule loop lets B
/// acquire, record, unlock, exit; proc joins B and deinits. Returns 1 iff the
/// try-while-held was false AND B acquired after the unlock. No
/// sleeps — only explicit reschedules.
export fn latch_mutex(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    mtx_try_while_held = true;
    mtx_acquired = false;

    const la = Latch.init() catch return fail("latch init");
    la.lock();

    var f = fiber.spawn("mtx-waiter", mutexWaiter, .{la}) catch return fail("spawn");

    // B has recorded try-while-held and is parked in lock(). Handing over.
    la.unlock();

    var passes: usize = 0;
    while (!mtx_acquired and passes < 16) : (passes += 1) fiber.reschedule();

    f.join();
    la.deinit(); // safe: B has joined; the latch is unlocked.

    const ok: i64 = if (!mtx_try_while_held and mtx_acquired) 1 else 0;
    return proc.returnValue(ctx, ok);
}

/// latch_fifo() -> 12. FIFO choreography with every yield point explicit and
/// zero sleeps. Proc locks (uncontended, no yield), spawns B (records 1)
/// then C (records 2). B parks in lock() when its spawn returns; C parks behind
/// B — the queue is B,C by construction, not by timing. Proc unlocks
/// (ownership -> B), then a bounded reschedule loop lets B acquire/record/unlock
/// then C. Joins both, deinits. Returns `order[0]*10 + order[1]` = 12; a short
/// `fifo_n` (broke) yields a wrong code — a loud finding, not a flake.
export fn latch_fifo(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    fifo_order = .{ 0, 0 };
    fifo_n = 0;

    const la = Latch.init() catch return fail("latch init");
    la.lock(); // uncontended, no yield

    var fb = fiber.spawn("fifo-b", fifoWaiter, .{ la, @as(i64, 1) }) catch return fail("spawn b");
    var fc = fiber.spawn("fifo-c", fifoWaiter, .{ la, @as(i64, 2) }) catch return fail("spawn c");

    // B is parked ahead of C by construction. Hand ownership to B.
    la.unlock();

    var passes: usize = 0;
    while (fifo_n < 2 and passes < 16) : (passes += 1) fiber.reschedule();

    fb.join();
    fc.join();
    la.deinit(); // safe: both waiters joined; the latch is unlocked.

    return proc.returnValue(ctx, fifo_order[0] * 10 + fifo_order[1]);
}

/// latch_with_lock() -> 1. `withLock(&counter, incrFn)` returns the value path
/// (1); `withLock(&x, boomFn)` returns error.Boom, caught. After EACH call the
/// latch must be free — `tryLock()` true then `unlock()` — proving the `defer`
/// released on both the return and error paths.
export fn latch_with_lock(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const la = Latch.init() catch return fail("latch init");

    // Value path: withLock returns f's value and releases.
    var counter: i64 = 0;
    const r = la.withLock(&counter, incrFn);
    const value_ok = r == 1 and counter == 1;
    const rel_after_value = la.tryLock();
    if (rel_after_value) la.unlock();

    // Error path: withLock propagates the error and still releases (defer).
    var x: i64 = 0;
    var caught = false;
    if (la.withLock(&x, boomFn)) |_| {
        // unexpected success — leave caught = false so the proc returns 0.
    } else |e| switch (e) {
        error.Boom => caught = true,
    }
    const rel_after_error = la.tryLock();
    if (rel_after_error) la.unlock();

    la.deinit(); // safe: the latch is unlocked.

    const ok: i64 = if (value_ok and rel_after_value and caught and rel_after_error) 1 else 0;
    return proc.returnValue(ctx, ok);
}

/// latch_trylock_self() -> 1. In the proc's OWN fiber: `lock()`; `tryLock()`
/// must be false (a self-held latch reports held, no deadlock/recursion);
/// `unlock()`; `tryLock()` must now be true; `unlock()`; deinit.
export fn latch_trylock_self(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const la = Latch.init() catch return fail("latch init");

    la.lock();
    const held = la.tryLock(); // self-held -> false
    la.unlock();

    const free = la.tryLock(); // now uncontended -> true
    if (free) la.unlock();

    la.deinit(); // safe: the latch is unlocked.

    const ok: i64 = if (!held and free) 1 else 0;
    return proc.returnValue(ctx, ok);
}

/// clock_invariants() -> 1. (a) monotonic grows across a 10ms sleep (a sleep is
/// fine here — this tests time, not scheduling order). (b) adjacent
/// `*64 / 1e9 ≈ double` for both monotonic and realtime (the live units
/// cross-check). (c) process/thread CPU clocks advance across a busy loop
/// (busy-loop direction only, never asserted across a sleep — with a
/// bounded loop-growth retry per).
export fn clock_invariants(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    // (a) monotonic grows across a sleep.
    const m1 = clock.monotonic();
    fiber.sleep(0.01);
    const grew = clock.monotonic() > m1;

    // (b) *64 (ns) / 1e9 within a loose epsilon of the double (s), adjacent.
    const mono_d = clock.monotonic();
    const mono_ns = clock.monotonic64();
    const mono_units = @abs(@as(f64, @floatFromInt(mono_ns)) / 1e9 - mono_d) < 1.0;
    const rt_d = clock.realtime();
    const rt_ns = clock.realtime64();
    const rt_units = @abs(@as(f64, @floatFromInt(rt_ns)) / 1e9 - rt_d) < 1.0;

    // (c) CPU clocks tick across a busy loop; grow the loop if a coarse clock
    // reads 0, bounded — never assert the sleep direction.
    const p1 = clock.process();
    const t1 = clock.thread();
    var iters: u64 = 10_000_000;
    var acc: u64 = 0;
    var proc_grew = false;
    var thread_grew = false;
    var attempts: u32 = 0;
    while (attempts < 8 and !(proc_grew and thread_grew)) : (attempts += 1) {
        acc +%= busyLoop(iters);
        proc_grew = clock.process() > p1;
        thread_grew = clock.thread() > t1;
        iters *= 2;
    }
    std.mem.doNotOptimizeAway(acc);

    const ok: i64 = if (grew and mono_units and rt_units and proc_grew and thread_grew) 1 else 0;
    return proc.returnValue(ctx, ok);
}

/// clock_realtime_now() -> f64. The module's wall-clock reading, for the
/// Lua-side window check against the host Lua's `require('clock').realtime()`.
export fn clock_realtime_now(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, clock.realtime());
}
