//! Trigger registration for Zig-authored Tarantool modules.
//!
//! Three surfaces a C module can reach, unified behind one module:
//!
//!   * **process shutdown** — the ONE native trigger in the public C ABI
//!     (`box_on_shutdown`, module.h:501-503). Matched/removed by function
//!     pointer; errno-based failure, no box diag.
//!   * **transaction on_commit / on_rollback** — no native form exists in the
//!     header; registered through the Lua bridge (`box.on_commit` /
//!     `box.on_rollback`). One-shot and scoped to the *current* transaction.
//!   * **space on_replace** — likewise Lua-bridge (`space:on_replace`);
//!     persistent until removed via the returned `SpaceTrigger` handle.
//!
//! The Lua-bridge shape (probe-verified): borrow the global
//! `luaT_state` L, open a balanced stack frame (`base = gettop`,
//! `defer settop(base)`), push the target Lua function plus a Zig
//! `lua_CFunction` trampoline whose `context` rides a **lightuserdata upvalue**,
//! and `luaT_call` the registration. The trampoline reads its ctx back from the
//! upvalue and invokes the comptime-monomorphized `f` — the same "state travels
//! through a context pointer, closure is a comptime fn" shape as `cond.waitUntil`
//! (no heap, no globals). The on_replace trampoline uses `lua.zig`'s
//! body/raise split: all fallible work runs in a plain Zig `body` that
//! never longjmps, and `lua.raiseErr` is called only after `body` (and its
//! tuple-unref defers) unwound.
//!
//! DDL / SQL are NOT bound here: the sanctioned pattern is a user-side
//! `luaT_dostring("box.schema.space.create(...)")` / `luaT_call` on
//! `box.schema.*` or `box.execute` over this same `luaT_state` bridge
//! (module.h:1400-1401). `luaT_dostring` is deliberately left unbound until a
//! DDL/SQL helper needs it — this module's 7 externs cover triggers alone.

const std = @import("std");
const c = @import("c.zig");
const lua = @import("lua.zig");
const tuple = @import("tuple.zig");

pub const Error = error{
    /// A `luaT_call` registration returned nonzero (the fiber diag holds the
    /// Lua error), `luaT_state` was NULL, or `box_on_shutdown` returned -1
    /// (errno-based for shutdown — no box diag on that path).
    TriggerOp,
    /// `onCommit`/`onRollback` was called with no active transaction. The host
    /// rejects txn-trigger registration outside a transaction, so this is a
    /// pre-guard (same stance as `txn.setIsolation`).
    NoTxn,
};

/// Reimplementation of the `lua_upvalueindex(i)` macro (lua.h:40,
/// `LUA_GLOBALSINDEX - i`): a pseudo-index addressing the i-th upvalue of the
/// running C closure. Same stance as `say.enabled` reimplementing an inline.
inline fn upvalueIndex(i: c_int) c_int {
    return c.LUA_GLOBALSINDEX - i;
}

/// Fail-fast comptime guard: a trigger `context` must be a single-item pointer,
/// so it rides a `void *` / lightuserdata losslessly and casts back cleanly.
fn assertSingleItemPtr(comptime Ctx: type) void {
    const info = @typeInfo(Ctx);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("trigger: context must be a single-item pointer, got " ++ @typeName(Ctx));
}

// ---- process shutdown (native C ABI, box_on_shutdown) -----------------------

/// Comptime-monomorphized shutdown trampoline: one distinct `handler` symbol per
/// `(Ctx, f)` pair, so `removeShutdown` matches the same pointer `onShutdown`
/// registered (box_on_shutdown matches by function pointer).
fn Shut(comptime Ctx: type, comptime f: fn (Ctx) void) type {
    return struct {
        fn handler(arg: ?*anyopaque) callconv(.c) c_int {
            f(@ptrCast(@alignCast(arg.?)));
            return 0;
        }
    };
}

/// Register `f` to run when the server shuts down gracefully (module.h:484-503).
/// `context` must be a single-item pointer; it rides the `void *arg` and is
/// handed back to `f`. Removal matches by handler function pointer — each
/// `(Ctx, f)` pair monomorphizes a distinct trampoline, so
/// `removeShutdown(context, f)` with the same pair removes exactly this handler.
/// A -1 host return (EINVAL/ENOMEM — errno, NOT a box diag) surfaces as
/// `Error.TriggerOp`.
pub fn onShutdown(context: anytype, comptime f: fn (@TypeOf(context)) void) Error!void {
    const Ctx = @TypeOf(context);
    comptime assertSingleItemPtr(Ctx);
    if (c.box_on_shutdown(context, &Shut(Ctx, f).handler, null) != 0)
        return Error.TriggerOp;
}

/// Deregister a handler previously registered with `onShutdown(context, f)`.
/// The `(context, f)` pair must match the registration so the same trampoline
/// pointer is found (`new_handler == NULL` deletes the trigger whose function is
/// `old_handler`). A -1 host return (e.g. no such trigger) surfaces as
/// `Error.TriggerOp`.
pub fn removeShutdown(context: anytype, comptime f: fn (@TypeOf(context)) void) Error!void {
    const Ctx = @TypeOf(context);
    comptime assertSingleItemPtr(Ctx);
    if (c.box_on_shutdown(null, null, &Shut(Ctx, f).handler) != 0)
        return Error.TriggerOp;
}

// ---- transaction triggers (Lua bridge; one-shot, current txn only) ----------

/// Comptime txn trampoline: reads its ctx from the lightuserdata upvalue and
/// calls the infallible `f`. Returns 0 (no Lua results, never raises).
fn TxnTramp(comptime Ctx: type, comptime f: fn (Ctx) void) type {
    return struct {
        fn cb(L: ?*c.lua_State) callconv(.c) c_int {
            const p = c.lua_touserdata(L.?, upvalueIndex(1));
            f(@ptrCast(@alignCast(p.?)));
            return 0;
        }
    };
}

/// Shared registration path for `box.on_commit` / `box.on_rollback`. Requires an
/// active transaction (`Error.NoTxn`). Opens a balanced frame on the global L,
/// pushes `box.<method>` and a ctx-carrying closure, and
/// `luaT_call`s the registration; a nonzero return is `Error.TriggerOp`.
fn txnTrigger(
    comptime method: [:0]const u8,
    context: anytype,
    comptime f: fn (@TypeOf(context)) void,
) Error!void {
    const Ctx = @TypeOf(context);
    comptime assertSingleItemPtr(Ctx);
    if (!c.box_txn()) return Error.NoTxn;

    const L = c.luaT_state() orelse return Error.TriggerOp;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);

    c.lua_getfield(L, c.LUA_GLOBALSINDEX, "box"); // [box]
    c.lua_getfield(L, -1, method.ptr); // [box, box.<method>]
    c.lua_pushlightuserdata(L, context); // [box, method, ctx]
    c.lua_pushcclosure(L, &TxnTramp(Ctx, f).cb, 1); // [box, method, closure]
    // luaT_call treats index -2 (method) as the function and -1 (closure) as its
    // single arg; `box` stays underneath and is dropped by the defer.
    if (c.luaT_call(L, 1, 0) != 0) return Error.TriggerOp;
}

/// Register `f` to run once, after WAL write, when the CURRENT transaction
/// commits (`box.on_commit`). Requires an active transaction (`Error.NoTxn`).
/// One-shot and txn-scoped: it does not carry into a later transaction.
///
/// `context` must be a single-item pointer that OUTLIVES transaction end —
/// static, heap, or fiber-owned storage, NOT the proc stack frame if commit can
/// happen after the registering call returns. `f` is infallible by type: an
/// on_commit callback runs after the point of no return, so an error return
/// would be a lie. `f` must not yield.
pub fn onCommit(context: anytype, comptime f: fn (@TypeOf(context)) void) Error!void {
    return txnTrigger("on_commit", context, f);
}

/// Register `f` to run when the CURRENT transaction rolls back
/// (`box.on_rollback`). Requires an active transaction (`Error.NoTxn`). One-shot
/// and txn-scoped. Same `context` lifetime + no-yield rules as `onCommit`.
pub fn onRollback(context: anytype, comptime f: fn (@TypeOf(context)) void) Error!void {
    return txnTrigger("on_rollback", context, f);
}

// ---- space on_replace (Lua bridge; persistent until removed) ----------------

/// The DML operation that fired an on_replace trigger, decoded from the host's
/// UPPERCASE op string (probe: `"REPLACE"`; Lua reference lists all five).
pub const Op = enum { insert, update, delete, replace, upsert };

/// Decode the host's op string into `Op`. An unrecognized string is
/// `Error.TriggerOp` — loud, never a silent default (design).
fn decodeOp(s: []const u8) Error!Op {
    if (std.mem.eql(u8, s, "INSERT")) return .insert;
    if (std.mem.eql(u8, s, "UPDATE")) return .update;
    if (std.mem.eql(u8, s, "DELETE")) return .delete;
    if (std.mem.eql(u8, s, "REPLACE")) return .replace;
    if (std.mem.eql(u8, s, "UPSERT")) return .upsert;
    return Error.TriggerOp;
}

/// The arguments an on_replace trigger receives, decoded from the 4 Lua args
/// (old, new, space-name, op). Tuples are borrowed-for-call: ref'd before `f`
/// and released after; `space` aliases Lua-owned memory valid only for the
/// duration of `f`.
pub const ReplaceEvent = struct {
    /// The pre-image, or null for an insert-like replace (no prior tuple).
    old: ?tuple.Tuple,
    /// The post-image, or null for a delete.
    new: ?tuple.Tuple,
    /// The space name (Lua-owned; valid only during `f` — copy to retain).
    space: []const u8,
    /// The DML operation that fired the trigger.
    op: Op,
};

/// Comptime on_replace trampoline with the body/raise split: `body` does
/// all fallible work with non-raising accessors and surfaces failures as Zig
/// errors; `cb` runs the single longjmp (`lua.raiseErr`) only after `body` (and
/// its tuple-unref defers) fully returned.
fn ReplaceTramp(
    comptime Ctx: type,
    comptime f: fn (Ctx, ReplaceEvent) anyerror!void,
) type {
    return struct {
        fn body(L: *c.lua_State) anyerror!void {
            const ctx: Ctx = @ptrCast(@alignCast(c.lua_touserdata(L, upvalueIndex(1)).?));

            // old/new: borrowed-for-call (ref before f, unref after — the
            // lua.zig:271-274 discipline). luaT_istuple returns null for nil.
            var old_t: ?tuple.Tuple = null;
            if (c.luaT_istuple(L, 1)) |raw| {
                _ = c.box_tuple_ref(raw);
                old_t = tuple.Tuple.init(raw);
            }
            defer if (old_t) |tt| tt.deinit();

            var new_t: ?tuple.Tuple = null;
            if (c.luaT_istuple(L, 2)) |raw| {
                _ = c.box_tuple_ref(raw);
                new_t = tuple.Tuple.init(raw);
            }
            defer if (new_t) |tt| tt.deinit();

            var slen: usize = undefined;
            const sp = c.lua_tolstring(L, 3, &slen);
            const space_name: []const u8 = if (sp == null) "" else sp[0..slen];

            var oplen: usize = undefined;
            const opp = c.lua_tolstring(L, 4, &oplen);
            if (opp == null) return Error.TriggerOp;
            const op = try decodeOp(opp[0..oplen]);

            try f(ctx, .{ .old = old_t, .new = new_t, .space = space_name, .op = op });
        }

        fn cb(L: ?*c.lua_State) callconv(.c) c_int {
            const state = L.?;
            body(state) catch |e| return lua.raiseErr(lua.Lua.init(state), e);
            return 0;
        }
    };
}

/// A live on_replace registration. Owns exactly one Lua registry ref anchoring
/// the closure's identity (needed for deregistration — the host matches by the
/// same closure object). `remove()` deregisters and releases the ref
/// exactly once; the handle is dead after (no double-remove guard beyond this
/// doc — same stance as `Latch.deinit`).
pub const SpaceTrigger = struct {
    space_id: u32,
    ref: c_int,

    /// Deregister this trigger (`space:on_replace(nil, anchored_closure)`) and
    /// release the registry ref. A host failure (e.g. the space was dropped, so
    /// `box.space[id]` is nil) surfaces as `Error.TriggerOp`; the ref is
    /// released regardless (the handle is single-use).
    pub fn remove(self: SpaceTrigger) Error!void {
        const L = c.luaT_state() orelse return Error.TriggerOp;
        const base = c.lua_gettop(L);
        defer c.lua_settop(L, base);

        c.lua_getfield(L, c.LUA_GLOBALSINDEX, "box"); // [box]
        c.lua_getfield(L, -1, "space"); // [box, space]
        c.lua_rawgeti(L, -1, @intCast(self.space_id)); // [box, space, obj]
        c.lua_getfield(L, -1, "on_replace"); // [box, space, obj, on_replace]
        c.lua_pushvalue(L, -2); // self (obj): [.., on_replace, obj]
        c.lua_pushnil(L); // new trigger = nil: [.., obj, nil]
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, self.ref); // old = anchored closure
        // obj:on_replace(nil, closure) → function=on_replace, 3 args (obj,nil,closure).
        const rc = c.luaT_call(L, 3, 0);
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, self.ref);
        if (rc != 0) return Error.TriggerOp;
    }
};

/// Register `f` as a persistent on_replace trigger on the space identified by
/// `space_id` (`box.Space.id`, src/box.zig:40, composes directly). The trigger
/// fires on every INSERT/UPDATE/DELETE/REPLACE/UPSERT until `remove()`.
///
/// An error returned by `f` is raised into Lua after the trampoline body unwinds
/// — the host then aborts and rolls back the triggering STATEMENT only. In
/// autocommit that is the whole implicit transaction; but an enclosing EXPLICIT
/// `box.begin()` transaction stays active with prior statements intact and
/// `box.commit()` succeeds — the error propagates to the DML caller only
/// (verify-probed on 3.8). `error.BoxOp` surfaces the host diag message
/// (the `lua.raiseErr` map); any other error surfaces by name.
///
/// `context` must be a single-item pointer that stays valid until `remove()`
/// returns — the trigger is PERSISTENT (static/heap/fiber-owned; never a stack
/// frame that unwinds while the trigger is live).
pub fn onReplace(
    space_id: u32,
    context: anytype,
    comptime f: fn (@TypeOf(context), ReplaceEvent) anyerror!void,
) Error!SpaceTrigger {
    const Ctx = @TypeOf(context);
    comptime assertSingleItemPtr(Ctx);

    const L = c.luaT_state() orelse return Error.TriggerOp;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);

    // Build the closure and anchor a copy in the registry so its identity
    // survives for deregistration. `closure_idx` is its absolute stack
    // slot, stable across the pushes below.
    c.lua_pushlightuserdata(L, context); // [ctx]
    c.lua_pushcclosure(L, &ReplaceTramp(Ctx, f).cb, 1); // [closure]
    const closure_idx = base + 1;
    c.lua_pushvalue(L, closure_idx); // [closure, closure]
    const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX); // pops copy → [closure]

    // Resolve obj = box.space[space_id] and call obj:on_replace(closure).
    c.lua_getfield(L, c.LUA_GLOBALSINDEX, "box"); // [closure, box]
    c.lua_getfield(L, -1, "space"); // [closure, box, space]
    c.lua_rawgeti(L, -1, @intCast(space_id)); // [closure, box, space, obj]
    c.lua_getfield(L, -1, "on_replace"); // [.., obj, on_replace]
    c.lua_pushvalue(L, -2); // self (obj): [.., on_replace, obj]
    c.lua_pushvalue(L, closure_idx); // arg: [.., obj, closure]
    // obj:on_replace(closure) → function=on_replace, 2 args (obj, closure).
    if (c.luaT_call(L, 2, 0) != 0) {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        return Error.TriggerOp;
    }

    return .{ .space_id = space_id, .ref = ref };
}

test {
    // Compile-smoke: monomorphize every generic with a concrete ctx + fn so the
    // generic bodies are type-checked (an address
    // take of the generic alone does NOT compile its body). Host symbols link-fail
    // under `zig test src/trigger.zig`; that is expected and means it type-checked.
    const Probe = struct {
        fn bump(ctx: *i64) void {
            ctx.* += 1;
        }
        fn onRep(ctx: *i64, ev: ReplaceEvent) anyerror!void {
            ctx.* += 1;
            if (ev.op == .delete) return error.Veto;
        }
    };
    _ = &struct {
        fn force() Error!void {
            var x: i64 = 0;
            try onShutdown(&x, Probe.bump);
            try removeShutdown(&x, Probe.bump);
            try onCommit(&x, Probe.bump);
            try onRollback(&x, Probe.bump);
            const handle = try onReplace(512, &x, Probe.onRep);
            try handle.remove();
        }
    }.force;
}
