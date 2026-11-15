//! Bounded MPMC channel — `Channel(T)` — a reusable cross-fiber producer/consumer
//! handoff over `cond.Cond` + an allocator. Pure Zig: no new C externs;
//! the only host dependency is transitive, through `cond.Cond`.
//!
//! A `Channel(T)` owns a `capacity`-slot ring buffer (allocator-owned at `init`,
//! freed once at `deinit`) and two conds: `not_empty` (receivers park
//! here while the buffer is empty and open) and `not_full` (senders park here
//! while the buffer is full and open). Two conds, signal-per-op: a `send` that
//! stores an item signals `not_empty`, a `recv` that frees a slot signals
//! `not_full`, so each wakeup targets a waiter that can make progress. The
//! cond predicate-recheck loop absorbs a lost race — a woken receiver that
//! finds the item already taken by a sibling re-parks. `close` broadcasts both
//! so every parked fiber observes `closed` and exits.
//!
//! MPMC correctness rests on cooperative scheduling: a fiber runs without
//! preemption between yield points, and the only yields inside `Channel` are the
//! `cond.wait` calls. So the predicate-check → buffer-mutate sequence in `send`/
//! `recv` is atomic without locking.
//!
//! `T` is a value type: buffered items at `deinit` are dropped with no per-item
//! cleanup. `deinit` precondition: no fiber is still parked on the channel
//! — the caller joins all sender/receiver fibers first. Debug-asserted via the
//! `senders_parked`/`receivers_parked` counters (the by-value `cond.Cond` can't
//! carry the count across a fiber that captured a copy), so a missed join traps
//! in tests instead of silently freeing a cond out from under a parked fiber.

const std = @import("std");
const cond = @import("cond.zig");

pub const Error = error{
    /// `init` was called with `capacity < 1`. Capacity-0 rendezvous needs a
    /// different hand-off protocol (YAGNI) — never a silent clamp.
    InvalidCapacity,
    /// `send` on a closed channel, or a channel that closed while the sender was
    /// parked: the value is never stored.
    Closed,
    /// A parked `send`/`recv` was interrupted by fiber cancellation, propagated
    /// from `cond.wait` — never collapsed into a value or `null`.
    Cancelled,
};

/// A bounded MPMC channel of `T`. Construct with `init`, tear down with
/// `deinit`. Any number of producer/consumer fibers may share one channel.
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        closed: bool,
        not_empty: cond.Cond,
        not_full: cond.Cond,
        alloc: std.mem.Allocator,
        /// Fibers currently parked in `send`/`recv` (debug guard for `deinit`). Tracked on the channel's stable `*Self`, not on the by-value
        /// conds. Nonzero at `deinit` means a producer/consumer was never joined.
        senders_parked: usize,
        receivers_parked: usize,

        /// Allocate a `capacity`-slot ring buffer and two conds. `capacity < 1`
        /// is `Error.InvalidCapacity` — no silent clamp. A failed
        /// buffer or cond allocation surfaces as an error and frees whatever was
        /// already allocated (errdefer), leaking nothing.
        pub fn init(capacity: usize, alloc: std.mem.Allocator) !Self {
            if (capacity < 1) return Error.InvalidCapacity;

            const buf = try alloc.alloc(T, capacity);
            errdefer alloc.free(buf);

            const not_empty = try cond.Cond.init();
            errdefer not_empty.deinit();

            const not_full = try cond.Cond.init();

            return .{
                .buf = buf,
                .head = 0,
                .tail = 0,
                .count = 0,
                .capacity = capacity,
                .closed = false,
                .not_empty = not_empty,
                .not_full = not_full,
                .alloc = alloc,
                .senders_parked = 0,
                .receivers_parked = 0,
            };
        }

        /// Free the ring buffer and both conds exactly once. Precondition:
        /// no fiber is parked on the channel — the caller joins all sender/
        /// receiver fibers first. Debug-asserted via the parked counters (compiled out in ReleaseFast/Small), so a missed join fails loudly in
        /// tests instead of silently. Do not use the handle after `deinit`.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.senders_parked == 0 and self.receivers_parked == 0);
            self.alloc.free(self.buf);
            self.not_empty.deinit();
            self.not_full.deinit();
        }

        fn isFull(self: *const Self) bool {
            return self.count == self.capacity;
        }

        fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Store `value`, parking on `not_full` while the buffer is full and the
        /// channel is open. `Error.Closed` if the channel is or becomes
        /// closed before the value is stored — even with free space;
        /// `Error.Cancelled` if a parked sender is cancelled. On success, signals
        /// `not_empty` so one parked receiver makes progress.
        pub fn send(self: *Self, value: T) !void {
            while (!self.closed and self.isFull()) {
                self.senders_parked += 1;
                defer self.senders_parked -= 1; // runs on wake AND on Cancelled
                try self.not_full.wait();
            }
            if (self.closed) return Error.Closed;

            self.buf[self.tail] = value;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;

            self.not_empty.signal();
        }

        /// Return the oldest buffered value, parking on `not_empty` while the
        /// buffer is empty and the channel is open. Once closed, drains
        /// remaining items FIFO and only then returns `null`.
        /// `Error.Cancelled` if a parked receiver is cancelled — never collapsed
        /// into `null`. On a successful pop, signals `not_full` so one
        /// parked sender makes progress.
        pub fn recv(self: *Self) !?T {
            while (!self.closed and self.isEmpty()) {
                self.receivers_parked += 1;
                defer self.receivers_parked -= 1; // runs on wake AND on Cancelled
                try self.not_empty.wait();
            }
            if (self.isEmpty()) return null; // closed and drained

            const value = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;

            self.not_full.signal();
            return value;
        }

        /// Mark the channel closed and broadcast both conds, waking every parked
        /// sender and receiver so each observes `closed` and exits.
        /// Idempotent. After `close`, `send` → `Error.Closed`; `recv` drains the
        /// remaining items FIFO then returns `null`.
        pub fn close(self: *Self) void {
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }
    };
}

test {
    // Compile-smoke only: a channel needs a live host scheduler (through its
    // conds), so this references the public surface at comptime and forces
    // monomorphization of `Channel(i64)` without running any of it.
    const Ch = Channel(i64);
    _ = &Ch.init;
    _ = &Ch.deinit;
    _ = &Ch.send;
    _ = &Ch.recv;
    _ = &Ch.close;
    _ = Error.InvalidCapacity;
    _ = Error.Closed;
    _ = Error.Cancelled;
}
