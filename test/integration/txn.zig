//! Integration coverage for the transaction savepoint surface (`txn.id`,
//! `txn.active`, `txn.Savepoint`) against a live host.
//!
//! These procs prove four things end to end:
//!   * outside any transaction (autocommit proc context) `txn.id()` is null and
//!     `txn.active()` is false (`txn_outside_clean`);
//!   * a savepoint taken mid-transaction rolls back the statements made after it
//!     while leaving earlier statements and the transaction itself intact
//!     (`txn_sp_roundtrip` — the Lua driver asserts the persisted/rolled-back
//!     rows);
//!   * `Savepoint.save()` refuses to act with no active transaction, yielding
//!     `error.NoTxn` (`txn_sp_no_txn`);
//!   * `Savepoint.rollback()` refuses to act against a *different* transaction
//!     than the one it was taken in, yielding `error.StaleSavepoint` WITHOUT
//!     touching the host (`txn_sp_stale` — the cross-transaction guard).
//!
//! `txn_sp_stale` deliberately tests only the CROSS-transaction case (commit
//! txn1, begin txn2, attempt rollback): the same-txn older-sibling
//! invalidation shares the txn id, would reach the host, and may
//! crash the live process — so it is never probed here.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;
const txn = t.txn;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// txn_outside_clean() -> 1 if, at proc entry (an autocommit context with no
/// active transaction), `txn.id()` is null and `txn.active()` is false; else 0.
export fn txn_outside_clean(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const clean = txn.id() == null and !txn.active();
    return proc.returnValue(ctx, @as(i64, if (clean) 1 else 0));
}

/// txn_sp_roundtrip() -> 0 on the success path; any error fails the proc.
///
/// Begins a transaction, inserts {1001,"a"}, asserts the transaction is live and
/// has an id, captures a savepoint, inserts {1002,"b"}, rolls back to the
/// savepoint (discarding {1002,"b"}), then commits. {1001,"a"} persists and
/// {1002,"b"} does not — the Lua driver asserts the resulting rows.
export fn txn_sp_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const space = box.Space.byName("t") catch return fail("byName");

    if (c.box_txn_begin() != 0) return fail("txn_begin");

    var a = (space.insert(.{ @as(i64, 1001), "a" }) catch {
        _ = c.box_txn_rollback();
        return fail("insert a");
    }) orelse {
        _ = c.box_txn_rollback();
        return fail("insert a null");
    };
    a.deinit();

    if (!txn.active() or txn.id() == null) {
        _ = c.box_txn_rollback();
        return fail("txn not active after insert");
    }

    var sp = txn.Savepoint.save() catch {
        _ = c.box_txn_rollback();
        return fail("savepoint save");
    };

    var b = (space.insert(.{ @as(i64, 1002), "b" }) catch {
        _ = c.box_txn_rollback();
        return fail("insert b");
    }) orelse {
        _ = c.box_txn_rollback();
        return fail("insert b null");
    };
    b.deinit();

    sp.rollback() catch {
        _ = c.box_txn_rollback();
        return fail("savepoint rollback");
    };

    if (c.box_txn_commit() != 0) {
        // A failed commit may leave the txn open depending on host version;
        // roll back defensively before failing, mirroring transaction()'s
        // errdefer (src/txn.zig:40) so no transaction dangles past the proc.
        _ = c.box_txn_rollback();
        return fail("txn_commit");
    }

    return proc.returnValue(ctx, @as(i64, 0));
}

/// txn_sp_no_txn() -> 1 if, at proc entry (no active transaction),
/// `Savepoint.save()` yields `error.NoTxn`; else 0. A returned savepoint or any
/// other error is a failure of the guard.
export fn txn_sp_no_txn(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (txn.Savepoint.save()) |_| {
        // Got a savepoint with no active transaction: guard did not fire.
        return proc.returnValue(ctx, @as(i64, 0));
    } else |e| switch (e) {
        error.NoTxn => return proc.returnValue(ctx, @as(i64, 1)),
        else => return proc.returnValue(ctx, @as(i64, 0)),
    }
}

/// txn_sp_stale() -> 1 if rolling back a savepoint captured in txn1 against a
/// *different* live txn2 yields `error.StaleSavepoint`; else 0.
///
/// Begins an empty txn1, captures a savepoint, commits txn1 (the savepoint's id
/// now names a finished transaction), begins txn2, then attempts the rollback:
/// the id guard must catch the mismatch and return `error.StaleSavepoint`
/// WITHOUT calling the host. No rows are written, so no space is polluted.
/// This is the CROSS-transaction case only — same-txn invalidation is
/// never probed here.
export fn txn_sp_stale(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (c.box_txn_begin() != 0) return fail("txn1 begin");

    var sp = txn.Savepoint.save() catch {
        _ = c.box_txn_rollback();
        return fail("savepoint save");
    };

    if (c.box_txn_commit() != 0) return fail("txn1 commit");

    if (c.box_txn_begin() != 0) return fail("txn2 begin");

    if (sp.rollback()) |_| {
        // Rollback succeeded against a different transaction: guard did not fire.
        _ = c.box_txn_rollback();
        return proc.returnValue(ctx, @as(i64, 0));
    } else |e| switch (e) {
        error.StaleSavepoint => {
            if (c.box_txn_rollback() != 0) return fail("txn2 rollback");
            return proc.returnValue(ctx, @as(i64, 1));
        },
        else => {
            _ = c.box_txn_rollback();
            return proc.returnValue(ctx, @as(i64, 0));
        },
    }
}

// ---- txn extras: isolation / timeout / sync / alloc ----
//
// Every proc below runs on the MVCC server (`txn-mvcc`,
// `memtx_use_mvcc_engine = true`, `replication_synchro_quorum = 1`, promoted):
// without MVCC a fiber yield inside a memtx transaction aborts it via the wrong
// path, and the sync commit needs a claimed limbo.

/// Inner closure for `txn_iso_roundtrip`: fails unless the wrapper set the
/// isolation to `.read_committed` before `f` runs.
fn expectReadCommitted() !void {
    if (txn.isolation() != .read_committed) return error.WrongIsolation;
}

/// txn_iso_roundtrip() -> 1 iff isolation is null outside the txn, observed as
/// `.read_committed` inside `transactionWith(.{ .isolation = .read_committed })`,
/// and null again after commit.
export fn txn_iso_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (txn.isolation() != null) return proc.returnValue(ctx, @as(i64, 0));

    txn.transactionWith(.{ .isolation = .read_committed }, expectReadCommitted, .{}) catch
        return proc.returnValue(ctx, @as(i64, 0));

    if (txn.isolation() != null) return proc.returnValue(ctx, @as(i64, 0));
    return proc.returnValue(ctx, @as(i64, 1));
}

/// txn_iso_after_dml() -> 1 iff `setIsolation` after the first DML yields
/// `error.TxnStarted`. Begins a txn, inserts {2001,"i"}, attempts to change the
/// isolation (must fail), then rolls the whole txn back so no row persists.
export fn txn_iso_after_dml(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const space = box.Space.byName("t") catch return fail("byName");

    if (c.box_txn_begin() != 0) return fail("txn begin");
    space.insertDiscard(.{ @as(i64, 2001), "i" }) catch {
        _ = c.box_txn_rollback();
        return fail("insert");
    };

    const res = txn.setIsolation(.read_confirmed);
    _ = c.box_txn_rollback();

    if (res) |_| {
        return proc.returnValue(ctx, @as(i64, 0));
    } else |e| switch (e) {
        error.TxnStarted => return proc.returnValue(ctx, @as(i64, 1)),
        else => return proc.returnValue(ctx, @as(i64, 0)),
    }
}

/// Inner closure for `txn_timeout_expired`: inserts {2002,"t"} then sleeps past
/// the 0.05s timeout so the rollback timer aborts the txn mid-`f`.
fn insertThenSleep() !void {
    const space = try box.Space.byName("t");
    try space.insertDiscard(.{ @as(i64, 2002), "t" });
    c.fiber_sleep(0.1);
}

/// txn_timeout_expired() -> 1 iff `transactionWith(.{ .timeout = 0.05 })` errors
/// (the commit sees the timer-aborted txn) with the diag "Transaction has been
/// aborted by timeout". {2002} must not persist (asserted by the driver).
export fn txn_timeout_expired(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (txn.transactionWith(.{ .timeout = 0.05 }, insertThenSleep, .{})) |_| {
        // Commit succeeded despite the timeout: the abort path did not fire.
        return proc.returnValue(ctx, @as(i64, 0));
    } else |_| {
        var buf: [256]u8 = undefined;
        const msg = err.lastMessage(&buf) orelse return proc.returnValue(ctx, @as(i64, 0));
        if (std.mem.eql(u8, msg, "Transaction has been aborted by timeout"))
            return proc.returnValue(ctx, @as(i64, 1));
        return proc.returnValue(ctx, @as(i64, 0));
    }
}

/// Inner closure for `txn_timeout_ok`: inserts {2003,"ok"} well within the 5s
/// timeout.
fn insertOk() !void {
    const space = try box.Space.byName("t");
    try space.insertDiscard(.{ @as(i64, 2003), "ok" });
}

/// txn_timeout_ok() -> 0 on success: a timeout that is never hit commits
/// normally and {2003} persists (asserted by the driver).
export fn txn_timeout_ok(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    txn.transactionWith(.{ .timeout = 5 }, insertOk, .{}) catch return fail("timeout_ok txn");
    return proc.returnValue(ctx, @as(i64, 0));
}

/// Inner closure for `txn_sync_commit`: inserts {2004,"s"}.
fn insertSync() !void {
    const space = try box.Space.byName("t");
    try space.insertDiscard(.{ @as(i64, 2004), "s" });
}

/// txn_sync_commit() -> 0 on success: `transactionWith(.{ .sync = true })`
/// commits synchronously on the quorum-1 promoted server and {2004} persists.
export fn txn_sync_commit(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    txn.transactionWith(.{ .sync = true }, insertSync, .{}) catch return fail("sync_commit txn");
    return proc.returnValue(ctx, @as(i64, 0));
}

/// Exercises alloc/allocSlice/over-aligned alloc in one yield-free section.
/// Errors on any round-trip mismatch or alignment violation.
fn allocWork() !void {
    const p = try txn.alloc(u64);
    p.* = 0xDEAD_BEEF_CAFE_F00D;
    if (p.* != 0xDEAD_BEEF_CAFE_F00D) return error.AllocMismatch;

    const s = try txn.allocSlice(u8, 4096);
    for (s) |*b| b.* = 0xAB;
    for (s) |b| if (b != 0xAB) return error.SliceMismatch;

    const Over = struct { v: u64 align(64) };
    const o = try txn.alloc(Over);
    if (@intFromPtr(o) % 64 != 0) return error.Misaligned;
    o.v = 12345;
    if (o.v != 12345) return error.OverMismatch;
}

/// txn_alloc_roundtrip() -> 1 iff: `alloc` outside a txn yields `error.NoTxn`,
/// and inside a transaction the u64 / 4096-byte slice / 64-aligned struct all
/// round-trip (the over-align path is exercised by the aligned struct).
export fn txn_alloc_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    if (txn.alloc(u64)) |_| {
        // Allocation succeeded with no active txn: the crash guard did not fire.
        return proc.returnValue(ctx, @as(i64, 0));
    } else |e| switch (e) {
        error.NoTxn => {},
        else => return proc.returnValue(ctx, @as(i64, 0)),
    }

    txn.transaction(allocWork, .{}) catch return proc.returnValue(ctx, @as(i64, 0));
    return proc.returnValue(ctx, @as(i64, 1));
}

/// Inner closure for the MVCC visibility pair: 1 if {3001} is visible in
/// `sync_t`, 0 if not.
fn seesSyncT() !i64 {
    const space = try box.Space.byName("sync_t");
    if (try space.get(.{@as(i64, 3001)})) |tup| {
        var m = tup;
        m.deinit();
        return 1;
    }
    return 0;
}

/// txn_read_committed_sees() -> 1 iff a `.read_committed` reader sees the
/// committed-not-confirmed {3001} parked in the limbo.
export fn txn_read_committed_sees(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const v = txn.transactionWith(.{ .isolation = .read_committed }, seesSyncT, .{}) catch
        return fail("read_committed txn");
    return proc.returnValue(ctx, v);
}

/// txn_read_confirmed_sees() -> 1 iff a `.read_confirmed` reader sees {3001}
/// (expected 0 while it is committed-not-confirmed).
export fn txn_read_confirmed_sees(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const v = txn.transactionWith(.{ .isolation = .read_confirmed }, seesSyncT, .{}) catch
        return fail("read_confirmed txn");
    return proc.returnValue(ctx, v);
}
