//! Integration coverage for the fiber introspection / current-fiber / attr
//! surface (src/fiber.zig: FiberInfo, find, FiberAttr, spawnWithAttr,
//! currentName/setCurrentName/currentCsw, Fiber.name/setName/csw) against a live
//! Tarantool. Introspection and a real scheduler can only be exercised on a host
//! event loop, so this driver IS the behavioral coverage (the `zig build test`
//! smoke only type-checks the surface). Procs use the raw C ABI and return their
//! result via `proc.returnValue`, mirroring fiber.zig.
//!
//! These procs prove end to end:
//!   * the current fiber's name round-trips through setCurrentName/currentName
//!     and a spawned fiber's name round-trips through setName/name before join
//!     (`fi_name_roundtrip`);
//!   * the current fiber's context-switch count strictly increases across real
//!     yields driven by a co-fiber (`fi_csw_increases`);
//!   * a live fiber is locatable by id via `find`, the read-only view's id
//!     matches the handle, and a never-allocated id resolves to null
//!     (`fi_find_by_id`, `fi_find_missing`);
//!   * a FiberAttr with an enlarged stack size runs a deep recursive body to
//!     completion and the same attr is reusable for a second spawn
//!     (`fi_spawn_big_stack`).

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

// --- Fiber bodies (passed as comptime func to spawn/spawnWithAttr) -----------

/// Parks cooperatively until cancelled, then returns a sentinel. Used as a
/// long-lived target so a handle's id is findable while the fiber is alive.
fn parkBody() i64 {
    while (!fiber.isCancelled()) fiber.yield();
    return 123;
}

/// Yields a few times so the spawning fiber, when it reschedules, observes real
/// context switches against this ready co-fiber (drives `currentCsw` upward).
fn coYieldBody() void {
    var i: usize = 0;
    while (i < 3) : (i += 1) fiber.reschedule();
}

/// A deterministic deep recursion that consumes stack with a per-frame array,
/// returning a checksum. `.never_inline` + a `volatile` sink defeat tail-call
/// optimization so the frames actually nest and consume stack (would otherwise
/// collapse to a loop). Per call: a 96-byte array (12 x u64) is touched, so the
/// effective stack data is ~depth * 96 bytes plus frame overhead.
const recurse_frame_words = 12; // 12 * 8 = 96 bytes of array per frame

var recurse_sink: u64 = 0;

fn deepRecurse(depth: i64) i64 {
    if (depth == 0) return 0;
    var buf: [recurse_frame_words]u64 = undefined;
    var i: usize = 0;
    while (i < recurse_frame_words) : (i += 1) {
        buf[i] = @as(u64, @intCast(depth)) +% i;
    }
    // Volatile sink so the optimizer cannot prove `buf` dead and elide the frame.
    const sink: *volatile u64 = &recurse_sink;
    sink.* +%= buf[@as(usize, @intCast(depth)) % recurse_frame_words];
    const rest = @call(.never_inline, deepRecurse, .{depth - 1});
    return rest +% depth;
}

// --- Procs ------------------------------------------------------------------

/// fi_name_roundtrip() -> 1. setCurrentName/currentName round-trips on the
/// current (proc) fiber, and setName/name round-trips on a spawned fiber while
/// it is still alive (before join). Returns 1 only if both checks held.
export fn fi_name_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    fiber.setCurrentName("zig-cur");
    if (!std.mem.eql(u8, fiber.currentName(), "zig-cur")) return fail("currentName mismatch");

    var f = fiber.spawn("parker", parkBody, .{}) catch return fail("spawn");
    f.setName("zig-spawned");
    const named_ok = std.mem.eql(u8, f.name(), "zig-spawned");

    // Let the parked fiber finish and reap it (no leak), regardless of the check.
    f.cancel();
    _ = f.join();

    if (!named_ok) return fail("spawned name mismatch");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// fi_csw_increases() -> delta (> 0). Reads currentCsw, drives real context
/// switches by rescheduling against a ready co-fiber, then reads currentCsw
/// again. Returns the strictly-positive delta; the body itself asserts c1 > c0.
export fn fi_csw_increases(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    // A ready co-fiber so each reschedule is a genuine context switch.
    fiber.spawnDetached("co-yielder", coYieldBody, .{}) catch return fail("spawnDetached");

    const c0 = fiber.currentCsw();
    var n: usize = 0;
    while (n < 3) : (n += 1) fiber.reschedule();
    const c1 = fiber.currentCsw();

    if (c1 <= c0) return fail("currentCsw did not increase across yields");
    return proc.returnValue(ctx, @as(i64, @intCast(c1 - c0)));
}

/// fi_find_by_id() -> 1. Spawns a parked fiber, finds it by the handle's id via
/// the read-only FiberInfo view, asserts the view's id matches, then
/// cancels + joins. Returns 1 only if the view resolved and ids matched.
export fn fi_find_by_id(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var f = fiber.spawn("findme", parkBody, .{}) catch return fail("spawn");
    const fid = f.id();

    const view = fiber.find(fid) orelse {
        f.cancel();
        _ = f.join();
        return fail("find(live id) returned null");
    };
    const id_ok = view.id() == fid;

    f.cancel();
    _ = f.join();

    if (!id_ok) return fail("find view id mismatch");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// fi_handle_csw() -> 1. Spawns a parked fiber (loops `fiber.yield()` until
/// cancelled), drives real context switches by rescheduling — each reschedule
/// hands control to the ready parked child, bumping ITS csw — then reads the
/// child's context-switch count two ways: directly off the handle (`f.csw()`,
/// src/fiber.zig:96) and via the read-only `find` view (`FiberInfo.csw`, :120).
/// Asserts both are > 0 and equal (handle == view), then cancels + joins.
/// Returns 1 only if both checks held.
export fn fi_handle_csw(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var f = fiber.spawn("csw-parker", parkBody, .{}) catch return fail("spawn");

    // Reschedule against the ready parked child so it actually context-switches.
    var n: usize = 0;
    while (n < 3) : (n += 1) fiber.reschedule();

    const a = f.csw();
    const v = (fiber.find(f.id()) orelse {
        f.cancel();
        _ = f.join();
        return fail("find(live id) returned null");
    }).csw();

    f.cancel();
    _ = f.join();

    if (a == 0) return fail("handle csw did not increase");
    if (a != v) return fail("handle csw != find-view csw");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// fi_find_missing() -> 1. A never-allocated id resolves to null, NOT an error.
/// Returns 1 when find is null. 0xFFFFFFFF is far above any live fiber id
/// in this short-lived process.
export fn fi_find_missing(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (fiber.find(0xFFFFFFFF) != null) return fail("find(unused id) was non-null");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// fi_spawn_big_stack() -> checksum. Builds a FiberAttr, sets an enlarged stack
/// (asserting getStackSize() >= requested), and runs a deep recursive
/// body to completion via spawnWithAttr. Reuses the SAME attr for a second
/// spawn and asserts both runs produced the identical checksum. Returns
/// the checksum so the Lua side pins the expected value.
export fn fi_spawn_big_stack(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var attr = fiber.FiberAttr.init() catch return fail("FiberAttr.init");
    defer attr.deinit();

    // The live host default fiber stack is ~516 KiB (528384 bytes observed), so a
    // 512 KiB request would be SMALLER than the default and prove nothing about
    // Request a comfortably larger 4 MiB stack so the deep body below — sized
    // to overflow the default — runs ONLY because the stack was enlarged.
    const requested: usize = 4 * 1024 * 1024;
    attr.setStackSize(requested) catch return fail("setStackSize");
    // setstacksize may round up; assert >=, never strict ==.
    if (attr.getStackSize() < requested) return fail("getStackSize < requested");

    // 240-byte frames (confirmed by disasm) x 2500 ~= 600 KiB, which overflows the
    // ~516 KiB default stack but fits the 4 MiB attr.
    const depth: i64 = 2500;

    var f1 = fiber.spawnWithAttr("deep-1", attr, deepRecurse, .{depth}) catch return fail("spawnWithAttr #1");
    const r1 = f1.join();

    // The same attr drives a second spawn (borrowed, not consumed).
    var f2 = fiber.spawnWithAttr("deep-2", attr, deepRecurse, .{depth}) catch return fail("spawnWithAttr #2");
    const r2 = f2.join();

    if (r1 != r2) return fail("reused-attr spawns disagreed");
    return proc.returnValue(ctx, r1);
}
