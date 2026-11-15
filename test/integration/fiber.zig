//! Integration coverage for the `Fiber(Result)` handle and spawn helpers
//! (src/fiber.zig) against a live Tarantool. Fibers need a real host event loop,
//! so this driver IS the behavioral coverage (the `zig build test` smoke only
//! type-checks the surface). Procs use the raw C ABI and return their result via
//! `proc.returnValue`, mirroring seq.zig.
//!
//! These procs prove end to end:
//!   * spawn makes a fiber joinable and join collects its body's result
//!     (`fib_spawn_join`);
//!   * spawnDetached runs the body to its first yield before returning to the
//!     caller, and the body completes on a later yield without crashing
//!     (`fib_detached_counter`);
//!   * cancel + join cooperatively unwinds a yielding loop and join collects the
//!     sentinel (`fib_cancel_join`);
//!   * join blocks across a real sleep-yield and collects the body's result
//!     (`fib_join_after_sleep`: result via the typed slot, freed once).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;
const msgpack = t.msgpack;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// File-scope counter mutated by the detached fiber body. The proc resets it
/// each call so repeated calls observe a clean progression.
var detached_counter: i64 = 0;

// --- Fiber bodies (passed as comptime func to spawn/spawnDetached) ----------

fn addBody(a: i64, b: i64) i64 {
    return a + b;
}

fn detachedBody() void {
    detached_counter += 1;
    // `reschedule` re-queues this fiber before yielding so it resumes on the
    // next scheduler pass; a bare `yield` would park it with no waker. (See the
    // proc below, which also reschedules to hand control to the scheduler.)
    fiber.reschedule();
    detached_counter += 10;
}

fn cancelBody() i64 {
    while (!fiber.isCancelled()) fiber.yield();
    return 7;
}

fn sleeperBody() i64 {
    fiber.sleep(0.05);
    return 99;
}

fn longSleepBody() i64 {
    // A long park: without an early `wakeup` the join below would block until
    // this 100s sleep elapses, which luatest's timeout turns into a failing
    // hang. `wakeup` resumes the fiber early, so join collects 7 promptly.
    fiber.sleep(100);
    return 7;
}

// --- Procs ------------------------------------------------------------------

/// fib_spawn_join(a, b) -> a + b, computed inside a spawned fiber and collected
/// by `join` (spawn always yields a joinable handle).
export fn fib_spawn_join(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const p = msgpack.decode(struct { i64, i64 }, &dec) catch return fail("fib_spawn_join: bad args");

    var f = fiber.spawn("adder", addBody, .{ p[0], p[1] }) catch return fail("spawn");
    return proc.returnValue(ctx, f.join());
}

/// fib_detached_counter() -> 11. spawnDetached runs detachedBody up to its first
/// reschedule before returning here (counter==1); the proc then reschedules
/// so the detached body resumes past its reschedule and completes (counter==11,
/// closure freed without crash). The exact 11 proves: ran before returning (1),
/// resumed after reschedule (11), completed.
export fn fib_detached_counter(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    detached_counter = 0;
    fiber.spawnDetached("bump", detachedBody, .{}) catch return fail("spawnDetached");
    // detachedBody already ran to its first reschedule, so counter == 1.
    // `reschedule` hands control to the scheduler (re-queuing this fiber) so the
    // detached body — which re-queued itself — resumes, runs `+= 10`, and
    // completes (closure freed) before this fiber runs again: counter == 11.
    fiber.reschedule();
    return proc.returnValue(ctx, detached_counter);
}

/// fib_cancel_join() -> 7. cancelBody yields while not cancelled; spawn runs it
/// to that first yield. `cancel` flips isCancelled and wakes it, so the
/// loop exits and returns the sentinel; `join` collects it (cooperative cancel,
/// no crash).
export fn fib_cancel_join(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var f = fiber.spawn("canceler", cancelBody, .{}) catch return fail("spawn");
    f.cancel();
    return proc.returnValue(ctx, f.join());
}

/// fib_join_after_sleep() -> 99. The spawned body sleeps (a real yield, so it
/// does NOT complete during spawn's synchronous run) and returns 99; `join`
/// blocks across the sleep and collects the result from the typed slot,
/// freeing it once.
export fn fib_join_after_sleep(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var f = fiber.spawn("sleeper", sleeperBody, .{}) catch return fail("spawn");
    return proc.returnValue(ctx, f.join());
}

/// fib_wakeup() -> 7. The spawned body parks on a long `sleep(100)`; `wakeup`
/// resumes it early so `join` collects the sentinel (7) promptly instead of
/// blocking until the sleep elapses. A regression where wakeup is a no-op leaves
/// the body parked, so join hangs and luatest's timeout fails the test.
export fn fib_wakeup(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var f = fiber.spawn("sleeper-wakeup", longSleepBody, .{}) catch return fail("spawn");
    f.wakeup();
    const r = f.join();
    return proc.returnValue(ctx, r);
}
