//! Integration coverage for `box.Typed(Row)`: the typed
//! space view mapping a named struct to a positional row. Host-bound, so this
//! driver IS the behavioral coverage — the `[]const u8` copy-out + `free` path
//! (`acct`), the scalar-only no-alloc path (`nums`), `del` removing a row,
//! absent → null, and an arity mismatch surfacing a decode error.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;

const alloc = std.heap.c_allocator;

const Acct = struct { id: []const u8, balance: i64 };
const Nums = struct { k: u64, v: i64 };
const Acct3 = struct { id: []const u8, balance: i64, extra: i64 };

const TAcct = box.Typed(Acct);
const TNums = box.Typed(Nums);
const TAcct3 = box.Typed(Acct3);

fn setErr(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// typed_acct_roundtrip() -> 100. put/get a `[]const u8` + i64 row (the alloc +
/// `free` copy-out path), then `del` and confirm `get` -> null.
/// The duped row is freed at function exit via `defer`.
export fn typed_acct_roundtrip(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const accts = TAcct.byName("acct") catch return setErr("no space acct");

    accts.put(.{ .id = "alice", .balance = 100 }) catch return setErr("put");

    const got = (accts.get(.{"alice"}, alloc) catch return setErr("get")) orelse return setErr("row absent");
    defer TAcct.free(got, alloc);
    if (!std.mem.eql(u8, got.id, "alice")) return setErr("id wrong");
    if (got.balance != 100) return setErr("balance wrong");

    accts.del(.{"alice"}) catch return setErr("del");
    if ((accts.get(.{"alice"}, alloc) catch return setErr("get-after-del")) != null) return setErr("del did not remove");

    return proc.returnValue(ctx, @as(i64, 100));
}

/// typed_nums_scalar() -> 42. A scalar-only row round-trips with no allocation;
/// `free` is a no-op. Returns the i64 value field.
export fn typed_nums_scalar(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const nums = TNums.byName("nums") catch return setErr("no space nums");

    nums.put(.{ .k = 7, .v = 42 }) catch return setErr("put");

    const got = (nums.get(.{@as(u64, 7)}, alloc) catch return setErr("get")) orelse return setErr("row absent");
    defer TNums.free(got, alloc); // no-op for a scalar-only Row
    if (got.k != 7) return setErr("k wrong");
    if (got.v != 42) return setErr("v wrong");

    return proc.returnValue(ctx, got.v);
}

/// typed_insert_dup() -> 1. The put/insert contrast in one proc: `insert` of a
/// fresh pk succeeds; a second `insert` on the same pk fails with
/// `error.BoxOp` and the host's "Duplicate key exists…" diag; `put` on that
/// same pk still replaces (the replace path is unaffected); `get` confirms the
/// replaced value. Cleans up its row so the proc is re-runnable.
export fn typed_insert_dup(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const nums = TNums.byName("nums") catch return setErr("no space nums");

    nums.del(.{@as(u64, 99)}) catch return setErr("pre-del"); // defensive: clear any stale row

    nums.insert(.{ .k = 99, .v = 1 }) catch return setErr("fresh insert should succeed");

    // A duplicate pk must fail with BoxOp carrying the host's "Duplicate" diag.
    if (nums.insert(.{ .k = 99, .v = 2 })) |_| {
        return setErr("duplicate insert should fail");
    } else |e| {
        if (e != box.Error.BoxOp) return setErr("duplicate insert wrong error");
        var mbuf: [256]u8 = undefined;
        const msg = err.lastMessage(&mbuf) orelse return setErr("no host diag on duplicate");
        if (std.mem.indexOf(u8, msg, "Duplicate") == null) return setErr("diag missing 'Duplicate'");
    }

    // put (replace) on the same pk is unaffected by the failed insert.
    nums.put(.{ .k = 99, .v = 3 }) catch return setErr("put replace should succeed");

    const got = (nums.get(.{@as(u64, 99)}, alloc) catch return setErr("get")) orelse return setErr("row absent after put");
    defer TNums.free(got, alloc);
    if (got.v != 3) return setErr("put did not replace");

    nums.del(.{@as(u64, 99)}) catch return setErr("cleanup del");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// typed_absent() -> 0. A `get` of a missing key returns null, not an error.
export fn typed_absent(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const accts = TAcct.byName("acct") catch return setErr("no space acct");

    if ((accts.get(.{"ghost"}, alloc) catch return setErr("get")) != null) return setErr("ghost should be absent");

    return proc.returnValue(ctx, @as(i64, 0));
}

/// typed_mismatch() -> 1. A 2-field row read through a 3-field `Row` surfaces
/// `error.ArityMismatch` from `decodeArray` — never a silent truncation.
/// The proc converts that error into a normal return of 1; any other outcome
/// (silent success) trips `setErr` and fails the Lua side.
export fn typed_mismatch(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const accts = TAcct.byName("acct") catch return setErr("no space acct");
    accts.put(.{ .id = "m", .balance = 1 }) catch return setErr("put");

    const accts3 = TAcct3.byName("acct") catch return setErr("no space acct(3)");
    if (accts3.get(.{"m"}, alloc)) |maybe| {
        if (maybe) |row| TAcct3.free(row, alloc);
        return setErr("arity mismatch should error");
    } else |_| {
        return proc.returnValue(ctx, @as(i64, 1));
    }
}
