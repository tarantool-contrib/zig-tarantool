//! Fiber condition variable: a host-bound `Cond` handle over Tarantool's
//! `fiber_cond_*` C functions (this module is legitimately Tarantool-bound and
//! imports `c.zig`, like `fiber.zig`/`seq.zig`).
//!
//! `Cond` owns exactly one `*c.fiber_cond`: `init` creates it,
//! `deinit` frees it exactly once. The raw `wait`/`waitTimeout` are thin
//! one-host-call wrappers that never loop internally: a `0` return means
//! "woke" (signal or spurious) and maps to `void`; the caller re-checks its own
//! predicate. A host `-1` always surfaces as an `Error`, never `void`:
//! `wait` can only fail with `Error.Cancelled` (infinite wait, the only
//! -1 cause is cancellation); `waitTimeout` disambiguates via
//! `fiber_is_cancelled()` into `Error.Cancelled` or `Error.Timeout`.
//!
//! `waitUntil` is the sole composite: it loops over `waitTimeout` against
//! an absolute deadline computed once from `fiber_clock()` at entry, so it
//! returns within `timeout` of entry regardless of spurious wakeups; the
//! deadline does NOT reset on a spurious wake.

const c = @import("c.zig");

pub const Error = error{
    /// `fiber_cond_new` returned NULL (out of memory) — no silent fallback.
    CondOp,
    /// `waitTimeout`/`waitUntil` ran out of time before being woken.
    Timeout,
    /// A wait was interrupted by fiber cancellation (`fiber_is_cancelled()`).
    Cancelled,
};

/// A host-bound fiber condition variable. Owns a `*c.fiber_cond` and frees it
/// on `deinit`. Construct with `init`.
pub const Cond = struct {
    raw: *c.fiber_cond,

    /// Allocate a new fiber cond. A NULL `fiber_cond_new` (OOM) surfaces as
    /// `Error.CondOp` — no silent fallback.
    pub fn init() Error!Cond {
        const raw = c.fiber_cond_new() orelse return Error.CondOp;
        return .{ .raw = raw };
    }

    /// Free the underlying host cond. Precondition: no fiber is currently
    /// waiting on this cond. This is a documented caller obligation, NOT
    /// runtime-guarded. Do not use the handle after `deinit`.
    pub fn deinit(self: Cond) void {
        c.fiber_cond_delete(self.raw);
    }

    /// Wake one waiter, if any (after this, exactly one waiter becomes
    /// runnable).
    pub fn signal(self: Cond) void {
        c.fiber_cond_signal(self.raw);
    }

    /// Wake all waiters (after this, every current waiter becomes runnable).
    pub fn broadcast(self: Cond) void {
        c.fiber_cond_broadcast(self.raw);
    }

    /// Wait indefinitely until signalled (a yield point). A `0` host
    /// return ("woke": signal or spurious) maps to `void`; the caller re-checks
    /// its own predicate. The only `-1` cause for an infinite wait is
    /// cancellation, so it surfaces as `Error.Cancelled`.
    pub fn wait(self: Cond) Error!void {
        if (c.fiber_cond_wait(self.raw) != 0) return Error.Cancelled;
    }

    /// Wait up to `seconds` until signalled (a yield point). A `0` host
    /// return ("woke") maps to `void`. A `-1` is disambiguated by reading
    /// `fiber_is_cancelled()` immediately: `Error.Cancelled` if a
    /// cancellation is pending, otherwise `Error.Timeout`. A timeout does
    /// not poison the cond — it stays reusable.
    pub fn waitTimeout(self: Cond, seconds: f64) Error!void {
        if (c.fiber_cond_wait_timeout(self.raw, seconds) != 0)
            return if (c.fiber_is_cancelled()) Error.Cancelled else Error.Timeout;
    }

    /// Wait until `pred(context)` holds or `timeout` seconds elapse from entry.
    ///
    /// The deadline is absolute, computed once from `fiber_clock()` at entry
    /// (monotonic non-decreasing, so the loop terminates), and does NOT
    /// reset on spurious wakeups — so this returns within `timeout` of entry
    /// regardless of non-signal wakes. `pred` is consulted at entry and
    /// after every wake. A `Cancelled` from any inner wait propagates
    /// immediately; a spurious wake or inner timeout re-evaluates `pred` at the
    /// loop top. Returns `Error.Timeout` if the deadline passes before `pred`
    /// holds.
    pub fn waitUntil(self: Cond, context: anytype, comptime pred: fn (@TypeOf(context)) bool, timeout: f64) Error!void {
        const deadline = c.fiber_clock() + timeout;
        while (!pred(context)) {
            const remaining = deadline - c.fiber_clock();
            if (remaining <= 0) return Error.Timeout;
            self.waitTimeout(remaining) catch |e| switch (e) {
                error.Cancelled => return error.Cancelled,
                error.Timeout => {},
                error.CondOp => unreachable,
            };
        }
    }
};

test {
    // Compile-smoke only: conds need a live host, so this references the public
    // surface at comptime without running any of it.
    _ = &Cond.init;
    _ = &Cond.deinit;
    _ = &Cond.signal;
    _ = &Cond.broadcast;
    _ = &Cond.wait;
    _ = &Cond.waitTimeout;
    // Force monomorphization of the `waitUntil` generic body with a concrete
    // context + pred so its body is actually type-checked (`_ = &waitUntil`
    // alone does NOT compile the generic body).
    const Probe = struct {
        fn pred(ctx: *const bool) bool {
            return ctx.*;
        }
    };
    _ = &struct {
        fn force(self: Cond, flag: *const bool) Error!void {
            return self.waitUntil(flag, Probe.pred, 0.0);
        }
    }.force;
}
