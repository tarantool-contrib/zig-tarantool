//! Example Tarantool C module: a cooperative producer/consumer pipeline over a
//! single proc call, demonstrating the **fiber** + **channel** subsystems
//! together.
//!
//! `pipeline_sum(n)` spawns a consumer fiber, passing it a pointer to a bounded
//! `fiber.Channel(i64)`; the proc (the producer) sends `1..n` into the channel,
//! parking on a full buffer until the consumer drains it — real bounded
//! backpressure (capacity 4, so for n > 4 the producer genuinely blocks). It
//! then closes the channel and joins the consumer, returning the consumer-
//! computed sum. The channel is a local passed by pointer to the consumer fiber
//! (the producer outlives and joins it), so no file-scope globals are needed.
//!
//! Build into `pipeline.so`; see test/integration/pipeline.lua.

const t = @import("tarantool");
const fiber = t.fiber;
const proc = t.proc;

const std = @import("std");
const c_allocator = std.heap.c_allocator;

/// The consumer fiber body: drain the channel until it is closed AND empty,
/// parking inside `recv` whenever it is empty (the channel handles the cond
/// handoff). `recv` returns `null` once the channel is closed and drained; a
/// cancellation surfaces as an error and ends the consumer early with whatever
/// it has summed so far (`catch return total`). Returns the running sum.
fn consume(ch: *fiber.Channel(i64)) i64 {
    var total: i64 = 0;
    while (ch.recv() catch return total) |v| total += v;
    return total;
}

/// pipeline_sum(n) -> i64: produce `1..n` through the channel and return the sum
/// the consumer fiber computed (== n*(n+1)/2).
fn pipelineSum(n: i64) !i64 {
    var ch = try fiber.Channel(i64).init(4, c_allocator);
    defer ch.deinit(); // safe: runs after join, so no fiber remains parked

    var consumer = try fiber.spawn("consumer", consume, .{&ch});

    var i: i64 = 1;
    while (i <= n) : (i += 1) try ch.send(i); // parks while full -> backpressure

    // No more work: close the channel so the consumer drains the rest then sees
    // closed-and-empty and finishes.
    ch.close();
    return consumer.join();
}

comptime {
    proc.exportProc("pipeline_sum", pipelineSum);
}
