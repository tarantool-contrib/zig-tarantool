//! Transaction helper (command) — run a closure inside a host
//! transaction, committing on success and rolling back on any propagated
//! error.
//!
//! `transaction(f, args)` begins a box transaction, calls `f` with `args`
//! forwarded via `@call`, and commits if `f` returns normally. If `f` returns
//! an error, the `errdefer` rolls the transaction back and the error propagates
//! unchanged (never swallowed). A failed begin/commit surfaces as
//! `error.BoxOp`. With `args = .{}` it behaves identically to a zero-arg `f`.

const std = @import("std");
const c = @import("c.zig");

pub const Error = error{
    /// `box_txn_begin` or `box_txn_commit` returned -1; the host error stack
    /// holds details.
    BoxOp,
    /// A savepoint operation was attempted with no active transaction
    /// (`box_txn()` is false).
    NoTxn,
    /// A `Savepoint` was rolled back against a different transaction than the
    /// one it was taken in: the captured txn id no longer matches the live one
    /// (the cross-transaction crash guard).
    StaleSavepoint,
    /// An isolation change was attempted after the first DML in the transaction
    /// (host diag: "Operation is not permitted when there is an active
    /// transaction"). Isolation must be set before any statement.
    TxnStarted,
    /// `box_txn_alloc` returned NULL — the txn memory pool is exhausted.
    OutOfMemory,
};

/// Transaction isolation level, mirroring `enum txn_isolation_level` from
/// `module.h` (values pinned in `c_verify.zig`). `.default` (0) means "use the
/// `box.cfg` default"; the host's `box_txn_isolation` never returns it by
/// design. `.linearizable` additionally requires replication configuration.
pub const IsolationLevel = enum(u32) {
    default,
    read_committed,
    read_confirmed,
    best_effort,
    linearizable,
};

/// Options applied by `transactionWith` between `box_txn_begin` and `f`. The
/// `.default`/`null`/`false` defaults make `transactionWith(.{}, f, args)`
/// behave identically to the plain `transaction(f, args)`.
pub const Options = struct {
    /// Isolation level; applied only when not `.default` (host rejects an
    /// explicit `TXN_ISOLATION_DEFAULT`). Must precede the first DML — the
    /// wrapper ordering guarantees this.
    isolation: IsolationLevel = .default,
    /// Rollback timeout in seconds; `null` means the `box.cfg` default. Applied
    /// before `f` runs.
    timeout: ?f64 = null,
    /// When true, `makeSync` is called on `f`'s success path immediately before
    /// commit — the transaction commits synchronously (synchro quorum).
    sync: bool = false,
};

/// The success type of `f`'s return: the payload of `!T`, or `T` itself if `f`
/// does not return an error union.
fn RetOf(comptime f: anytype) type {
    const ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Run `f` inside a host transaction, forwarding `args` (a tuple) to `f` via
/// `@call(.auto, f, args)`. Commits on success; rolls back and propagates on
/// error. `f` may return `T`, `void`, `!T`, or `!void`. Pass `.{}` for a
/// zero-arg `f`.
pub fn transaction(comptime f: anytype, args: anytype) !RetOf(f) {
    return transactionWith(.{}, f, args);
}

/// Like `transaction`, but applies `opts` (isolation, timeout, sync) to the
/// transaction. The ordering is load-bearing: begin → setIsolation →
/// setTimeout → f → (sync? makeSync) → commit. Isolation and timeout are applied
/// before `f` runs any DML, so the host's "before the first DML" constraint is
/// unviolable on this path. A setter error propagates through the `errdefer`,
/// rolling the transaction back — it never leaks.
pub fn transactionWith(opts: Options, comptime f: anytype, args: anytype) !RetOf(f) {
    if (c.box_txn_begin() != 0) return Error.BoxOp;
    errdefer _ = c.box_txn_rollback();

    if (opts.isolation != .default) try setIsolation(opts.isolation);
    if (opts.timeout) |t| try setTimeout(t);

    const r = try @call(.auto, f, args);

    if (opts.sync) try makeSync();
    if (c.box_txn_commit() != 0) return Error.BoxOp;
    return r;
}

/// The id of the current fiber's transaction, or `null` if none is active.
///
/// Thin wrapper over `box_txn_id`, which returns -1 when there is no active
/// transaction (the id uniquely names the live transaction and is not
/// reused within the window a `Savepoint` is held).
pub fn id() ?i64 {
    const v = c.box_txn_id();
    return if (v == -1) null else v;
}

/// Whether the current fiber has an active transaction. Thin wrapper over
/// `box_txn`.
pub fn active() bool {
    return c.box_txn();
}

/// The isolation level of the current transaction, or `null` if there is no
/// active transaction (the host returns -1). The host never returns
/// `.default`/0 by design, but 0 is a valid enum member so `@enumFromInt` is
/// safe either way.
pub fn isolation() ?IsolationLevel {
    const v = c.box_txn_isolation();
    return if (v == -1) null else @fromBackingInt(@intCast(@as(u32, @intCast(v))));
}

/// Set the isolation level of the current transaction. Must be called before
/// the first DML. Requires an active transaction (`error.NoTxn` otherwise); a
/// call after the first DML yields `error.TxnStarted` — with a valid enum value
/// after the NoTxn guard, ER_ACTIVE_TRANSACTION is the only reachable -1
/// (verified live).
pub fn setIsolation(level: IsolationLevel) Error!void {
    if (!c.box_txn()) return Error.NoTxn;
    if (c.box_txn_set_isolation(@backingInt(level)) != 0) return Error.TxnStarted;
}

/// Set the rollback timeout (seconds) of the current transaction: when it
/// expires the transaction is rolled back. Requires an active transaction
/// (`error.NoTxn` otherwise). A host -1 — timeout <= 0 or the rollback timer is
/// already started — surfaces as `error.BoxOp`; the host diag distinguishes the
/// cause.
pub fn setTimeout(seconds: f64) Error!void {
    if (!c.box_txn()) return Error.NoTxn;
    if (c.box_txn_set_timeout(seconds) != 0) return Error.BoxOp;
}

/// Make the current transaction synchronous: its commit waits for the synchro
/// quorum. Requires an active transaction — the host function dereferences the
/// current txn, so the `box_txn()` guard (`error.NoTxn`) is a crash guard, not
/// just an error map.
pub fn makeSync() Error!void {
    if (!c.box_txn()) return Error.NoTxn;
    c.box_txn_make_sync();
}

/// A handle to a point within the current transaction that the transaction can
/// be rolled back to without aborting it (owns no freeable resource and
/// exposes no `deinit` — the host reclaims the savepoint memory at transaction
/// end).
///
/// `txn_id` records the transaction the savepoint was taken in, so `rollback`
/// can refuse to act against a different transaction (the crash guard).
pub const Savepoint = struct {
    handle: *c.box_txn_savepoint_t,
    txn_id: i64,

    /// Capture a savepoint in the current transaction.
    ///
    /// Requires an active transaction (`error.NoTxn` otherwise). A null return
    /// from the host — a client or memory error — surfaces as `error.BoxOp`,
    /// never a silent fallback.
    pub fn save() Error!Savepoint {
        if (!c.box_txn()) return Error.NoTxn;
        const h = c.box_txn_savepoint() orelse return Error.BoxOp;
        return .{ .handle = h, .txn_id = c.box_txn_id() };
    }

    /// Roll the transaction back to this savepoint, discarding statements made
    /// after it while leaving the transaction active.
    ///
    /// The guard order is load-bearing: the host call
    /// `box_txn_rollback_to_savepoint` is statically unreachable unless there is
    /// an active transaction (`error.NoTxn` otherwise) AND its id equals the one
    /// captured at `save` (`error.StaleSavepoint` otherwise). A host failure on
    /// the rollback itself surfaces as `error.BoxOp`.
    ///
    /// The id guard catches only cross-transaction misuse: rolling back to
    /// a savepoint after the original transaction ended and a new one began. It
    /// does NOT catch same-transaction invalidation — a savepoint made unusable
    /// because a prior rollback to an OLDER sibling discarded it shares the same
    /// txn id, so guarding against that case is the caller's responsibility.
    pub fn rollback(self: Savepoint) Error!void {
        if (!c.box_txn()) return Error.NoTxn;
        if (c.box_txn_id() != self.txn_id) return Error.StaleSavepoint;
        if (c.box_txn_rollback_to_savepoint(self.handle) != 0) return Error.BoxOp;
    }
};

/// Allocate `size` bytes on the txn memory pool, aligned to `alignment`. The
/// pool is reclaimed wholesale by the host at commit/rollback — there is no free.
/// Requires an active transaction: `box_txn_alloc` dereferences the
/// current txn, so the `box_txn()` guard (`error.NoTxn`) is a crash guard.
///
/// The header promises no alignment. For `alignment <= 8` the host's
/// uint64-aligned txn region already satisfies it — call directly and
/// `assert` the guarantee (fail-fast on a non-contractual property). For
/// `alignment > 8` over-allocate and align the address forward manually, the
/// only general path (the txn pool has no `aligned_alloc` variant, unlike
/// `box_region_aligned_alloc`).
fn allocRaw(size: usize, comptime alignment: usize) Error![*]u8 {
    if (!c.box_txn()) return Error.NoTxn;
    if (alignment <= 8) {
        const p = c.box_txn_alloc(size) orelse return Error.OutOfMemory;
        std.debug.assert(@intFromPtr(p) % alignment == 0);
        return @ptrCast(p);
    }
    const raw = c.box_txn_alloc(size + alignment - 1) orelse return Error.OutOfMemory;
    const aligned = std.mem.alignForward(usize, @intFromPtr(raw), alignment);
    return @ptrFromInt(aligned);
}

/// Allocate a single `T` on the txn memory pool. Lives until commit/rollback;
/// no free. `error.NoTxn` outside a transaction, `error.OutOfMemory` on
/// pool exhaustion.
pub fn alloc(comptime T: type) Error!*T {
    const p = try allocRaw(@sizeOf(T), @alignOf(T));
    return @ptrCast(@alignCast(p));
}

/// Allocate a slice of `n` `T`s on the txn memory pool. Lives until
/// commit/rollback; no free. `error.OutOfMemory` on pool exhaustion or if
/// `n * @sizeOf(T)` overflows.
pub fn allocSlice(comptime T: type, n: usize) Error![]T {
    const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return Error.OutOfMemory;
    const p = try allocRaw(bytes, @alignOf(T));
    const ptr: [*]T = @ptrCast(@alignCast(p));
    return ptr[0..n];
}
