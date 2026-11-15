//! Integration coverage for trigger registration (src/trigger.zig) against a
//! live Tarantool. Triggers are meaningless without a real host (global Lua
//! state, box runtime, WAL, graceful shutdown), so this driver IS the behavioral
//! coverage — `zig build test` only compile-smokes the surface. Procs use the
//! raw C ABI and return via `proc.returnValue`, mirroring cond.zig; the shutdown
//! proc takes a path argument, so it goes through the typed `proc.exportProc`.
//!
//! These procs prove end to end:
//!   * on_commit fires exactly once, after WAL write, and is one-shot — a second
//!     bare transaction does not re-fire it (`trig_commit`);
//!   * on_rollback fires on `box_txn_rollback` (`trig_rollback`);
//!   * registering a txn trigger outside a transaction is rejected
//!     (`trig_no_txn` → `Error.NoTxn`);
//!   * on_replace fires with the decoded op + new tuple, and deregistration via
//!     the handle stops it firing (`trig_replace_lifecycle`);
//!   * an error from an on_replace trigger aborts the triggering STATEMENT: in
//!     autocommit the tuple never lands (`trig_replace_abort`);
//!   * ...and in an EXPLICIT transaction only that statement is rolled back —
//!     the transaction stays active and commits with prior statements intact
//!     (`trig_replace_abort_txn` second leg);
//!   * an on_shutdown handler runs during graceful stop (`trig_shutdown_reg` +
//!     the runner-side stop/sentinel check), and removeShutdown round-trips.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;
const txn = t.txn;
const trigger = t.trigger;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// Name of the test space the luatest driver creates before calling the procs.
const SPACE = "trig_s";
/// Key whose replace the selective veto trigger rejects (`trig_replace_abort_txn`).
const VETO_KEY: i64 = 999;

// --- File-scope shared state (reset at the top of each proc) -----------------

var commit_counter: i64 = 0;
var rollback_counter: i64 = 0;
var notxn_dummy: i64 = 0;
var fired_count: i64 = 0;
var last_op: trigger.Op = .insert;
var last_field0: i64 = 0;
var abort_dummy: i64 = 0;

// --- Trigger callbacks -------------------------------------------------------

/// Infallible txn callback: bumps its ctx counter (exercises ctx delivery).
fn bump(ctx: *i64) void {
    ctx.* += 1;
}

/// on_replace observer: bumps ctx, records the op and the new tuple's field 0.
fn record(ctx: *i64, ev: trigger.ReplaceEvent) anyerror!void {
    ctx.* += 1;
    last_op = ev.op;
    if (ev.new) |nt| last_field0 = (try nt.get(0, i64, t.region.allocator())) orelse -1;
}

/// on_replace veto: fails unconditionally, aborting the triggering statement.
fn veto(ctx: *i64, ev: trigger.ReplaceEvent) anyerror!void {
    _ = ctx;
    _ = ev;
    return error.Veto;
}

/// on_replace selective veto: fails only for `VETO_KEY`, so a transaction can
/// mix an accepted statement with a vetoed one (`trig_replace_abort_txn`).
fn vetoOnKey(ctx: *i64, ev: trigger.ReplaceEvent) anyerror!void {
    _ = ctx;
    if (ev.new) |nt| {
        const k = (try nt.get(0, i64, t.region.allocator())) orelse return;
        if (k == VETO_KEY) return error.Veto;
    }
}

// --- Transaction-trigger procs ----------------------------------------------

/// Body run inside the first (committing) transaction: register on_commit, then
/// do a real DML so the commit is non-empty.
fn commitBody(space: box.Space) !void {
    try trigger.onCommit(&commit_counter, bump);
    try space.replaceDiscard(.{ @as(i64, 1), @as(i64, 100) });
}

/// Body for a second bare transaction: a DML only, NO re-registration — proves
/// the on_commit trigger was one-shot (it must not fire again).
fn bareBody(space: box.Space) !void {
    try space.replaceDiscard(.{ @as(i64, 2), @as(i64, 200) });
}

/// trig_commit() -> 1. Register on_commit inside a committing transaction; after
/// commit the counter is 1 (fired once, after WAL). A second bare transaction
/// leaves it 1 — the trigger was one-shot and txn-scoped.
export fn trig_commit(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    commit_counter = 0;

    const space = box.Space.byName(SPACE) catch return fail("no space");
    txn.transaction(commitBody, .{space}) catch return fail("commit txn");
    if (commit_counter != 1) return fail("on_commit did not fire once");

    txn.transaction(bareBody, .{space}) catch return fail("bare txn");
    if (commit_counter != 1) return fail("on_commit re-fired (not one-shot)");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// trig_rollback() -> 1. In a manual transaction, register on_rollback, do one
/// DML, then roll back — the trigger fires exactly once on `box_txn_rollback`.
export fn trig_rollback(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    rollback_counter = 0;

    const space = box.Space.byName(SPACE) catch return fail("no space");
    if (c.box_txn_begin() != 0) return fail("begin");
    trigger.onRollback(&rollback_counter, bump) catch {
        _ = c.box_txn_rollback();
        return fail("onRollback");
    };
    space.replaceDiscard(.{ @as(i64, 3), @as(i64, 300) }) catch {
        _ = c.box_txn_rollback();
        return fail("dml");
    };
    if (c.box_txn_rollback() != 0) return fail("rollback");
    if (rollback_counter != 1) return fail("on_rollback did not fire once");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// trig_no_txn() -> 1. Registering a txn trigger with no active transaction is
/// rejected by the pre-guard (`Error.NoTxn`).
export fn trig_no_txn(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    trigger.onCommit(&notxn_dummy, bump) catch |e| {
        if (e == error.NoTxn) return proc.returnValue(ctx, @as(i64, 1));
        return fail("expected NoTxn");
    };
    return fail("onCommit outside txn did not error");
}

// --- Space on_replace procs --------------------------------------------------

/// trig_replace_lifecycle() -> 1. Register on_replace, do a replace: the trigger
/// fires once with op == .replace and the new tuple's field 0 decoded.
/// Deregister via the handle; a second replace does NOT fire it.
export fn trig_replace_lifecycle(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    fired_count = 0;
    last_op = .insert;
    last_field0 = 0;

    const space = box.Space.byName(SPACE) catch return fail("no space");
    const handle = trigger.onReplace(space.id, &fired_count, record) catch return fail("onReplace");

    space.replaceDiscard(.{ @as(i64, 10), @as(i64, 42) }) catch return fail("replace");
    if (fired_count != 1) return fail("trigger did not fire once");
    if (last_op != .replace) return fail("op != replace");
    if (last_field0 != 10) return fail("decoded field 0 mismatch");

    handle.remove() catch return fail("remove");

    space.replaceDiscard(.{ @as(i64, 11), @as(i64, 43) }) catch return fail("replace after remove");
    if (fired_count != 1) return fail("trigger fired after remove");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// trig_replace_abort() -> 1. An on_replace trigger that errors aborts the
/// triggering statement. In autocommit that is the whole implicit txn: the
/// replace returns -1 (Error.BoxOp) and the tuple never lands.
export fn trig_replace_abort(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const space = box.Space.byName(SPACE) catch return fail("no space");
    const handle = trigger.onReplace(space.id, &abort_dummy, veto) catch return fail("onReplace");

    var aborted = false;
    space.replaceDiscard(.{ @as(i64, 20), @as(i64, 99) }) catch {
        aborted = true;
    };

    const got = space.get(.{@as(i64, 20)}) catch {
        handle.remove() catch {};
        return fail("get");
    };
    const absent = got == null;
    if (got) |gt| gt.deinit();

    handle.remove() catch return fail("remove");

    return proc.returnValue(ctx, @as(i64, if (aborted and absent) 1 else 0));
}

/// trig_replace_abort_txn() -> 1. The statement-only rollback contract inside an
/// EXPLICIT transaction (second leg): a prior accepted statement survives,
/// the vetoed statement is rolled back, the transaction stays active, and
/// `box_txn_commit` succeeds with the accepted row committed and the vetoed row
/// absent. This is the behavior the `onReplace` doc comment promises.
export fn trig_replace_abort_txn(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const space = box.Space.byName(SPACE) catch return fail("no space");
    const handle = trigger.onReplace(space.id, &abort_dummy, vetoOnKey) catch return fail("onReplace");

    if (c.box_txn_begin() != 0) {
        handle.remove() catch {};
        return fail("begin");
    }

    // Accepted statement (not the veto key) — must survive the sibling abort.
    space.replaceDiscard(.{ @as(i64, 500), @as(i64, 1) }) catch {
        _ = c.box_txn_rollback();
        handle.remove() catch {};
        return fail("accepted dml");
    };

    // Vetoed statement — the trigger errors, aborting only THIS statement.
    var stmt_aborted = false;
    space.replaceDiscard(.{ VETO_KEY, @as(i64, 2) }) catch {
        stmt_aborted = true;
    };

    // The enclosing transaction must still be active: not poisoned.
    const still_active = c.box_txn();
    const committed = c.box_txn_commit() == 0;

    handle.remove() catch return fail("remove");

    // Post-commit: accepted row present, vetoed row absent.
    const acc = space.get(.{@as(i64, 500)}) catch return fail("get accepted");
    const acc_present = acc != null;
    if (acc) |gt| gt.deinit();

    const vet = space.get(.{VETO_KEY}) catch return fail("get vetoed");
    const vet_absent = vet == null;
    if (vet) |gt| gt.deinit();

    const ok = stmt_aborted and still_active and committed and acc_present and vet_absent;
    return proc.returnValue(ctx, @as(i64, if (ok) 1 else 0));
}

// --- Shutdown proc (typed: takes a path argument) ----------------------------

/// Static context for the sentinel-writing shutdown handler: it runs after the
/// registering proc has returned, so the path must live in static storage, not
/// the proc stack frame.
const ShutCtx = struct {
    path: [512]u8 = undefined,
    len: usize = 0,
};
var shut_ctx: ShutCtx = .{};
var roundtrip_dummy: i64 = 0;

/// The on_shutdown handler: create the sentinel file at the registered path via
/// a raw libc `open(O_CREAT)` (Zig 0.16's std.fs is Io-interface-bound; the C
/// ABI is stable and adequate here). The file exists once `open` returns, so the
/// fd is not closed — the process is exiting. Best-effort; errors are ignored.
fn writeSentinel(ctx: *ShutCtx) void {
    ctx.path[ctx.len] = 0; // NUL-terminate in place (len < buffer, guarded on register).
    const pz: [*:0]const u8 = @ptrCast(&ctx.path);
    _ = std.c.open(pz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
}

/// A second handler used only to prove removeShutdown round-trips.
fn roundtripHandler(ctx: *i64) void {
    ctx.* += 1;
}

/// trig_shutdown_reg(path) -> 1. Register a shutdown handler that writes a
/// sentinel file at `path` (the runner asserts it appears after a graceful
/// stop), and round-trip a second handler through register+remove.
fn shutdownReg(path: []const u8) anyerror!i64 {
    if (path.len >= shut_ctx.path.len) return error.PathTooLong; // room for the NUL.
    @memcpy(shut_ctx.path[0..path.len], path);
    shut_ctx.len = path.len;

    try trigger.onShutdown(&shut_ctx, writeSentinel);

    // register + immediate remove of a distinct handler: both must succeed.
    try trigger.onShutdown(&roundtrip_dummy, roundtripHandler);
    try trigger.removeShutdown(&roundtrip_dummy, roundtripHandler);

    return 1;
}

comptime {
    proc.exportProc("trig_shutdown_reg", shutdownReg);
}
