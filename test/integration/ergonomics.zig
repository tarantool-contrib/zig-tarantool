//! Integration coverage for the SDK ergonomics trio:
//! Space `*Discard` write variants, `Tuple.get(i, T, alloc)`, and the host-error
//! surfacing helpers `proc.fail` / `err.lastMessage`. Host-bound, so this driver
//! IS the behavioral coverage. (Item 2 — `transaction(f, args)` — is covered by
//! the box.lua and bank.lua drivers, which still pass after the signature change.)

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;
const update = t.update;

fn setErr(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// True if a row with primary key `id` exists (releases the borrowed tuple).
fn exists(s: box.Space, id: u64) !bool {
    const row = (try s.get(.{id})) orelse return false;
    row.deinit();
    return true;
}

/// erg_discard() -> 1. Exercises all five `*Discard` write variants and confirms
/// each lands via a follow-up `get`.
export fn erg_discard(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");

    s.insertDiscard(.{ @as(u64, 1), @as(i64, 10), @as([]const u8, "alice") }) catch return setErr("insertDiscard");
    if (!(exists(s, 1) catch return setErr("get"))) return setErr("after insert");

    s.replaceDiscard(.{ @as(u64, 1), @as(i64, 20), @as([]const u8, "alice2") }) catch return setErr("replaceDiscard");
    s.updateDiscard(.{@as(u64, 1)}, .{update.add(1, @as(i64, 5))}) catch return setErr("updateDiscard");

    s.upsertDiscard(.{ @as(u64, 2), @as(i64, 1), @as([]const u8, "bob") }, .{update.add(1, @as(i64, 0))}) catch return setErr("upsertDiscard");
    if (!(exists(s, 2) catch return setErr("get"))) return setErr("after upsert");

    s.deleteDiscard(.{@as(u64, 1)}) catch return setErr("deleteDiscard");
    if (exists(s, 1) catch return setErr("get")) return setErr("delete did not remove");

    return proc.returnValue(ctx, @as(i64, 1));
}

/// erg_typed_get() -> 42. Reads an int and a string field via `Tuple.get`, then
/// proves absent -> null and wrong-T -> error.
export fn erg_typed_get(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");
    s.replaceDiscard(.{ @as(u64, 7), @as(i64, 42), @as([]const u8, "carol") }) catch return setErr("seed");

    const row = (s.get(.{@as(u64, 7)}) catch return setErr("get")) orelse return setErr("no row");
    defer row.deinit();

    const n = (row.get(1, i64, std.heap.c_allocator) catch return setErr("get int")) orelse return setErr("int absent");
    if (n != 42) return setErr("int field wrong");

    const name = (row.get(2, []const u8, std.heap.c_allocator) catch return setErr("get str")) orelse return setErr("str absent");
    if (!std.mem.eql(u8, name, "carol")) return setErr("str field wrong");

    // Absent field index -> null (not an error).
    if ((row.get(9, i64, std.heap.c_allocator) catch return setErr("get absent")) != null) return setErr("absent field not null");

    // Wrong T (decode a string field as i64) -> error, never a silent coercion.
    if (row.get(2, i64, std.heap.c_allocator)) |_| return setErr("type mismatch should error") else |_| {}

    return proc.returnValue(ctx, n);
}

/// erg_fail_boxop() -> raises. A duplicate-key insert is a BoxOp; `proc.fail`
/// keeps the host's real "Duplicate key" message rather than the fallback.
export fn erg_fail_boxop(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = ctx;
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");
    s.replaceDiscard(.{ @as(u64, 100), @as(i64, 1), @as([]const u8, "x") }) catch return setErr("seed");
    s.insertDiscard(.{ @as(u64, 100), @as(i64, 2), @as([]const u8, "y") }) catch |e|
        return proc.fail(e, "fallback-should-not-appear");
    return setErr("expected duplicate-key failure");
}

/// erg_fail_fallback() -> raises. Seeds a STALE host error, then fails with a
/// non-BoxOp error (NoSuchSpace); `proc.fail` must surface the fallback, never
/// the stale message (the no-stale-error guard).
export fn erg_fail_fallback(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = ctx;
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");
    s.replaceDiscard(.{ @as(u64, 200), @as(i64, 1), @as([]const u8, "z") }) catch return setErr("seed");
    // Seed a stale "Duplicate key" host error and ignore it.
    s.insertDiscard(.{ @as(u64, 200), @as(i64, 2), @as([]const u8, "z2") }) catch {};
    // A non-BoxOp failure: the fallback must win over the stale host error.
    _ = box.Space.byName("definitely_no_such_space") catch |e| return proc.fail(e, "erg-fallback-msg");
    return setErr("expected NoSuchSpace");
}

/// erg_last_message() -> raises. Composes a message from the host error text via
/// `err.lastMessage` ("erg: " ++ host) and surfaces it.
export fn erg_last_message(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = ctx;
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");
    s.replaceDiscard(.{ @as(u64, 300), @as(i64, 1), @as([]const u8, "w") }) catch return setErr("seed");
    s.insertDiscard(.{ @as(u64, 300), @as(i64, 2), @as([]const u8, "w2") }) catch {
        var buf: [256]u8 = undefined;
        const host = err.lastMessage(&buf) orelse return setErr("no host message");
        var composed: [320]u8 = undefined;
        const m = std.fmt.bufPrint(&composed, "erg: {s}", .{host}) catch return setErr("compose");
        err.setBoxError(c.ER_PROC_C, m);
        return -1;
    };
    return setErr("expected duplicate-key failure");
}

/// erg_last_error() -> the host's last-error code. Performs the same duplicate-key
/// insert as `erg_fail_boxop`, swallows the failure, then reads the host's last
/// error via `err.lastError`. Asserts the message is non-empty and returns the
/// host's numeric error code (ER_TUPLE_FOUND = 3).
export fn erg_last_error(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = box.Space.byName("erg") catch return setErr("no space erg");
    s.replaceDiscard(.{ @as(u64, 500), @as(i64, 1), @as([]const u8, "le") }) catch return setErr("seed");
    s.insertDiscard(.{ @as(u64, 500), @as(i64, 2), @as([]const u8, "le2") }) catch {};
    const e = err.lastError() orelse return setErr("no last error");
    const msg = std.mem.span(@as([*:0]const u8, @ptrCast(e.message)));
    if (msg.len == 0) return setErr("empty message");
    return proc.returnValue(ctx, @as(i64, @intCast(e.code)));
}

/// erg_raw_nospace() -> raises "NoSuchSpace". A `proc.exportRaw` body that hits a
/// pure-Zig error (no host error set): exportRaw maps it via `proc.fail` to
/// `@errorName`.
fn ergRawNospace(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) !c_int {
    _ = args;
    _ = args_end;
    _ = try box.Space.byName("definitely_no_such_space");
    return proc.returnValue(ctx, @as(i64, 0));
}

/// erg_raw_dupkey() -> raises the host "Duplicate key" message. A `proc.exportRaw`
/// body whose box op returns -1 (error.BoxOp): exportRaw keeps the host message
/// rather than the error name.
fn ergRawDupkey(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) !c_int {
    _ = args;
    _ = args_end;
    const s = try box.Space.byName("erg");
    try s.replaceDiscard(.{ @as(u64, 400), @as(i64, 1), @as([]const u8, "a") });
    try s.insertDiscard(.{ @as(u64, 400), @as(i64, 2), @as([]const u8, "b") });
    return proc.returnValue(ctx, @as(i64, 0));
}

comptime {
    proc.exportRaw("erg_raw_nospace", ergRawNospace);
    proc.exportRaw("erg_raw_dupkey", ergRawDupkey);
}
