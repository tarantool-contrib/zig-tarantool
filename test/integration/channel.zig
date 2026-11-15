//! Integration coverage for `fiber.Channel(T)` (src/channel.zig) against a live
//! Tarantool. A bounded fiber channel is meaningless without a real host
//! scheduler (the `zig build test` smoke only type-checks the surface), so this
//! driver IS the behavioral coverage. Procs use the raw C ABI and return their
//! result via `proc.returnValue`, mirroring cond.zig/ergonomics.zig; on a failure
//! path they set a box error and return -1. Every fiber is spawned via
//! `fiber.spawn`, and every proc joins all fibers before `deinit` (a
//! fiber still parked at `deinit` is UB).
//!
//! The five procs prove end to end:
//!   * MPMC: 2 producers + 2 consumers share one channel; the combined total is
//!     N(N+1)/2, and signal-per-op suffices with >1 waiter per side
//!     (`chan_mpmc`);
//!   * close-then-drain: a closed channel yields its buffered items FIFO then
//!     `null` (`chan_close_drain`);
//!   * send-after-close is `error.Closed` even with free space
//!     (`chan_send_after_close`);
//!   * FIFO ring wraparound across a fill→drain→refill cycle (`chan_wraparound`);
//!   * full-buffer parking: on a cap-1 channel the second send parks until a
//!     consumer drains the first (`chan_backpressure`).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const fiber = t.fiber;

const Chan = fiber.Channel(i64);
const c_allocator = std.heap.c_allocator;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

// --- File-scope per-consumer sums (reset at the top of each proc) -------------
// Consumer fibers sum into their own slot so the combine is race-free; the proc
// joins them before reading (cooperative single thread).

var consumer_sum: [2]i64 = .{ 0, 0 };

/// Producer body: send the inclusive range `lo..hi` into the channel. Returns the
/// count sent (or stops early if the channel closes unexpectedly — a finding).
fn produce(ch: *Chan, lo: i64, hi: i64) i64 {
    var sent: i64 = 0;
    var i: i64 = lo;
    while (i <= hi) : (i += 1) {
        ch.send(i) catch return sent; // unexpected close ends early -> count short
        sent += 1;
    }
    return sent;
}

/// Consumer body: drain into `consumer_sum[slot]` until the channel is closed and
/// empty (`recv` -> null). A cancellation ends it early with what it has.
fn consumeInto(ch: *Chan, slot: usize) void {
    while (ch.recv() catch return) |v| consumer_sum[slot] += v;
}

/// chan_mpmc(n) -> n(n+1)/2. Spawn 2 producers (each sends a disjoint half of
/// 1..n) and 2 consumers (each sums into its own slot). Join the producers first
/// (they run to completion, parking on a full buffer while the consumers drain),
/// THEN close so the consumers drain the remainder and see null, THEN join the
/// consumers (join before deinit). Returns the combined total; the .lua
/// asserts it equals n(n+1)/2 (signal-per-op under 2P/2C).
export fn chan_mpmc(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const n: i64 = 1000;
    consumer_sum = .{ 0, 0 };

    var ch = Chan.init(8, c_allocator) catch return fail("channel init");

    const mid = @divTrunc(n, 2); // first producer sends 1..mid, second mid+1..n
    var p0 = fiber.spawn("prod-0", produce, .{ &ch, @as(i64, 1), mid }) catch return fail("spawn p0");
    var p1 = fiber.spawn("prod-1", produce, .{ &ch, mid + 1, n }) catch return fail("spawn p1");
    var co0 = fiber.spawn("cons-0", consumeInto, .{ &ch, @as(usize, 0) }) catch return fail("spawn c0");
    var co1 = fiber.spawn("cons-1", consumeInto, .{ &ch, @as(usize, 1) }) catch return fail("spawn c1");

    // Join producers: each blocks here until that producer has sent its whole
    // half (parking on a full buffer in between while the consumers drain).
    const sent = p0.join() + p1.join();
    if (sent != n) return fail("producers sent short (unexpected close)");

    // Now that no more items will be sent, close so the consumers drain the rest
    // then observe closed-and-empty (recv -> null) and finish.
    ch.close();
    co0.join();
    co1.join();
    ch.deinit(); // safe: all four fibers joined.

    const total = consumer_sum[0] + consumer_sum[1];
    return proc.returnValue(ctx, total);
}

/// chan_close_drain() -> 1. Send 3 items into a cap-4 channel, close(), then recv
/// must yield them FIFO (1,2,3) and the 4th recv must be null (a closed
/// channel drains its buffer in order before nulling). Runs entirely in the
/// proc's own fiber (no parking, so no other fiber is needed). Returns 1 iff all
/// four observations hold.
export fn chan_close_drain(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var ch = Chan.init(4, c_allocator) catch return fail("channel init");
    defer ch.deinit(); // safe: no fiber ever parks on this channel.

    ch.send(1) catch return fail("send 1");
    ch.send(2) catch return fail("send 2");
    ch.send(3) catch return fail("send 3");
    ch.close();

    const a = (ch.recv() catch return fail("recv a")) orelse return fail("a was null");
    const b = (ch.recv() catch return fail("recv b")) orelse return fail("b was null");
    const d = (ch.recv() catch return fail("recv c")) orelse return fail("c was null");
    const e = ch.recv() catch return fail("recv d"); // must be null (drained)

    const ok: i64 = if (a == 1 and b == 2 and d == 3 and e == null) 1 else 0;
    return proc.returnValue(ctx, ok);
}

/// chan_send_after_close() -> 1. close() then send must be error.Closed even with
/// free space. Returns 1 iff send raised exactly error.Closed.
export fn chan_send_after_close(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var ch = Chan.init(4, c_allocator) catch return fail("channel init");
    defer ch.deinit(); // safe: no fiber parks.

    ch.close();
    if (ch.send(1)) |_| {
        return fail("send after close should fail");
    } else |send_err| switch (send_err) {
        error.Closed => return proc.returnValue(ctx, @as(i64, 1)),
        else => return fail("send after close: wrong error"),
    }
}

/// chan_wraparound() -> 1. cap 2; interleave send/recv past capacity so head/tail
/// wrap modulo capacity: send 1,2 (full); recv -> 1; send 3 (tail wraps);
/// recv -> 2; recv -> 3. Asserts strict FIFO across the wrap. Single-fiber (the
/// buffer never blocks because each send has a freed slot). Returns 1 iff order
/// held.
export fn chan_wraparound(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var ch = Chan.init(2, c_allocator) catch return fail("channel init");
    defer ch.deinit(); // safe: no fiber parks.

    ch.send(1) catch return fail("send 1");
    ch.send(2) catch return fail("send 2"); // buffer now full
    const a = (ch.recv() catch return fail("recv a")) orelse return fail("a null"); // 1
    ch.send(3) catch return fail("send 3"); // tail wraps to slot 0
    const b = (ch.recv() catch return fail("recv b")) orelse return fail("b null"); // 2
    const d = (ch.recv() catch return fail("recv c")) orelse return fail("c null"); // 3

    const ok: i64 = if (a == 1 and b == 2 and d == 3) 1 else 0;
    return proc.returnValue(ctx, ok);
}

// --- chan_backpressure shared state -------------------------------------------
// The consumer records the order in which it received items so the proc can prove
// the second send genuinely parked until the consumer drained the first.

var bp_first_recv: i64 = 0;
var bp_second_recv: i64 = 0;
var bp_recv_count: usize = 0;

/// Backpressure consumer: drain a cap-1 channel into the bp_* slots until closed.
fn bpConsume(ch: *Chan) void {
    while (ch.recv() catch return) |v| {
        if (bp_recv_count == 0) bp_first_recv = v else if (bp_recv_count == 1) bp_second_recv = v;
        bp_recv_count += 1;
    }
}

/// chan_backpressure() -> 1. cap 1: a consumer fiber drains; the producer (this
/// proc's fiber) sends 10 then 20 — the buffer holds 1, so the second send parks
/// until the consumer drains the first. Observable via the proc's own csw: the
/// second `send` MUST context-switch (yield to the consumer) at least once, which
/// would not happen if the second item fit without parking (full-buffer
/// parking). Returns 1 iff the second send parked AND the consumer saw 10 then 20.
export fn chan_backpressure(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    bp_first_recv = 0;
    bp_second_recv = 0;
    bp_recv_count = 0;

    var ch = Chan.init(1, c_allocator) catch return fail("channel init");

    var co = fiber.spawn("bp-cons", bpConsume, .{&ch}) catch return fail("spawn cons");

    ch.send(10) catch return fail("send 10"); // fits the single slot, no park

    const csw_before = fiber.currentCsw();
    ch.send(20) catch return fail("send 20"); // buffer full -> must park (csw++)
    const parked = fiber.currentCsw() > csw_before;

    ch.close();
    co.join();
    ch.deinit(); // safe: consumer joined.

    const ok: i64 = if (parked and bp_first_recv == 10 and bp_second_recv == 20) 1 else 0;
    return proc.returnValue(ctx, ok);
}
