//! Fiber mutex: a host-bound `Latch` handle over Tarantool's `box_latch_*` C
//! functions — the missing sibling of `Cond` for critical sections that span
//! yields (this module is legitimately Tarantool-bound and imports `c.zig`,
//! like `cond.zig`/`fiber.zig`).
//!
//! `Latch` owns exactly one `*c.box_latch_t`: `init` creates it,
//! `deinit` frees it exactly once. `lock`/`tryLock`/`unlock` are thin
//! one-host-call wrappers; `withLock` is the sole composite
//! (lock; defer unlock; call) and releases on both the value and error paths.
//!
//! Host guarantees this module surfaces:
//!   * FIFO grant order — "Locks are acquired in the strict order as they were
//!     requested" (module.h); `lock` is a yield point when contended.
//!   * `tryLock` never blocks and never recurses: on a latch held by ANY fiber
//!     (including the caller) it reports "held" and maps host `1 → false`; host
//!     `0 → true` means acquired.
//!
//! Preconditions:
//!   * `deinit` requires an unlocked latch. An unlocked latch cannot have
//!     parked waiters (waiters only park while it is held), so this also means
//!     "no fiber is waiting". Documented caller obligation, backed by a cheap
//!     debug probe under `runtime_safety` (compiled out in ReleaseFast/Small) —
//!     the `Channel.deinit` stance, not a release-mode runtime guard.
//!   * `unlock` requires that the calling fiber owns the latch (host contract).
//!
//! There is NO timed lock: the host offers none, and this module does not fake
//! one with a trylock+sleep loop. `Cond` remains the tool for timed
//! waiting.

const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    /// `box_latch_new` returned NULL (out of memory) — no silent fallback (mirrors the `CondOp`/`SeqOp` module-named Op error family).
    LatchOp,
};

/// A host-bound fiber mutex. Owns a `*c.box_latch_t` and frees it on `deinit`.
/// Construct with `init`.
pub const Latch = struct {
    raw: *c.box_latch_t,

    /// Allocate a new latch. A NULL `box_latch_new` (OOM) surfaces as
    /// `Error.LatchOp` — no silent fallback.
    pub fn init() Error!Latch {
        const raw = c.box_latch_new() orelse return Error.LatchOp;
        return .{ .raw = raw };
    }

    /// Free the underlying host latch. Precondition: the latch is unlocked
    ///  — which also implies no fiber is parked waiting on it (waiters only
    /// park while it is held). Documented caller obligation, backed by a debug
    /// probe under `runtime_safety` (compiled out in ReleaseFast/Small): a held
    /// latch traps loudly instead of freeing under an owner. Cooperative
    /// scheduling guarantees no yield between the probe's trylock and unlock. Do
    /// not use the handle after `deinit`.
    pub fn deinit(self: Latch) void {
        if (std.debug.runtime_safety) {
            std.debug.assert(c.box_latch_trylock(self.raw) == 0);
            c.box_latch_unlock(self.raw);
        }
        c.box_latch_delete(self.raw);
    }

    /// Acquire the latch, waiting indefinitely if it is held (a yield point when
    /// contended). Grants are FIFO in request order (host guarantee).
    pub fn lock(self: Latch) void {
        c.box_latch_lock(self.raw);
    }

    /// Try to acquire without blocking. Returns `true` if acquired (host `0`),
    /// `false` if the latch is currently held by any fiber, including the caller
    /// (host `1`) — never inverted, never an error.
    pub fn tryLock(self: Latch) bool {
        return c.box_latch_trylock(self.raw) == 0;
    }

    /// Release the latch. Precondition: the calling fiber owns it (host
    /// contract). Hands ownership to the first parked waiter, if any.
    pub fn unlock(self: Latch) void {
        c.box_latch_unlock(self.raw);
    }

    /// Run `f(context)` with the latch held, releasing it on BOTH the value and
    /// error return paths. Threads state through `context` at comptime —
    /// the same ctx-first + comptime-fn mechanism as `Cond.waitUntil`
    /// (`src/cond.zig`), no heap allocation.
    ///
    /// `f` must be a concrete (non-generic) function taking exactly
    /// `@TypeOf(context)`; its return type is passed through, including error
    /// unions. A generic `f` has `return_type == null` and fails loudly at
    /// compile time.
    pub fn withLock(self: Latch, context: anytype, comptime f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        self.lock();
        defer self.unlock();
        return f(context);
    }
};

test {
    // Compile-smoke only: a latch is meaningless without a live host scheduler,
    // so this references the public surface at comptime without running any of
    // it.
    _ = &Latch.init;
    _ = &Latch.deinit;
    _ = &Latch.lock;
    _ = &Latch.tryLock;
    _ = &Latch.unlock;
    // Force monomorphization of the `withLock` generic body with a concrete
    // context + fn — including one whose `f` returns an error union — so its
    // body is actually type-checked (`_ = &withLock` alone does NOT compile the
    // generic body). Also checks the `defer unlock` fires
    // on the error path.
    const Probe = struct {
        fn incr(ctx: *i64) i64 {
            ctx.* += 1;
            return ctx.*;
        }
        fn boom(ctx: *i64) error{Boom}!i64 {
            ctx.* += 1;
            return error.Boom;
        }
    };
    const Force = struct {
        fn forceValue(self: Latch, n: *i64) i64 {
            return self.withLock(n, Probe.incr);
        }
        fn forceError(self: Latch, n: *i64) error{Boom}!i64 {
            return self.withLock(n, Probe.boom);
        }
    };
    _ = &Force.forceValue;
    _ = &Force.forceError;
}
