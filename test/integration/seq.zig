//! Integration coverage for the box `Sequence` handle (src/seq.zig) against a
//! live Tarantool. Procs use the raw C ABI and return their result via
//! `proc.returnValue`, mirroring region.zig/keydef.zig. The sequences `s` and
//! `u` are created by the Lua driver (`seq.lua`), not from here.
//!
//! These procs prove end to end:
//!   * `byName` resolves a sequence through the public box layer and the id it
//!     yields matches `box.space._sequence` (`seq_byname_id`);
//!   * the next/current/set/reset cycle advances exactly as specified
//!     (`seq_cycle`);
//!   * `byId` and `byName` address the same host sequence (`seq_byid_matches`);
//!   * a missing name surfaces as `error.NoSuchSequence` (`seq_no_such`);
//!   * `current()` on a never-advanced sequence surfaces as `error.SeqOp` —
//!     fail-fast, never a silent 0 (`seq_current_unadvanced`).

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const seq = t.seq;
const msgpack = t.msgpack;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// seq_byname_id() -> the id of sequence "s" as resolved by `byName`, returned
/// as i64. The Lua driver cross-checks it against the id from
/// box.space._sequence.index.name.
export fn seq_byname_id(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = seq.Sequence.byName("s") catch return fail("byName s");
    return proc.returnValue(ctx, @as(i64, s.id));
}

/// seq_cycle() -> 0 iff the next/current/set/reset cycle on sequence "s"
/// matches the exact expected sequence; otherwise `fail` with the offending
/// step, with exact i64 comparisons:
///   next==1 (start), next==2, current==2, set(10)+next==11, reset+next==1.
export fn seq_cycle(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = seq.Sequence.byName("s") catch return fail("byName s");

    if ((s.next() catch return fail("next 1")) != 1) return fail("next 1 != 1");
    if ((s.next() catch return fail("next 2")) != 2) return fail("next 2 != 2");
    if ((s.current() catch return fail("current")) != 2) return fail("current != 2");

    s.set(10) catch return fail("set 10");
    if ((s.next() catch return fail("next after set")) != 11) return fail("next after set != 11");

    s.reset() catch return fail("reset");
    if ((s.next() catch return fail("next after reset")) != 1) return fail("next after reset != 1");

    return proc.returnValue(ctx, @as(i64, 0));
}

/// seq_byid_matches(id) -> the value produced by `byId(id).next()`. The id is
/// decoded from the proc args (the Lua driver passes the id from
/// box.space._sequence). The driver asserts this advances the SAME sequence as
/// the named handle — i.e. it continues the shared counter rather than starting
/// a fresh one.
export fn seq_byid_matches(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const params = msgpack.decode(struct { u32 }, &dec) catch return fail("seq_byid_matches: bad args");
    const id = params[0];

    const s = seq.Sequence.byId(id);
    const v = s.next() catch return fail("byId next");
    return proc.returnValue(ctx, v);
}

/// seq_no_such() -> 1 iff `byName("nope")` yields exactly `error.NoSuchSequence`.
/// Any other outcome fails.
export fn seq_no_such(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    if (seq.Sequence.byName("nope")) |_| {
        return fail("byName nope resolved unexpectedly");
    } else |e| switch (e) {
        error.NoSuchSequence => return proc.returnValue(ctx, @as(i64, 1)),
        else => return fail("byName nope: wrong error"),
    }
}

/// seq_current_unadvanced() -> 1 iff `current()` on a never-advanced sequence
/// (the driver's freshly-created/reset sequence "u") yields exactly
/// `error.SeqOp` — fail-fast, no silent 0. Any other outcome fails.
export fn seq_current_unadvanced(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const s = seq.Sequence.byName("u") catch return fail("byName u");
    if (s.current()) |_| {
        return fail("current on unadvanced returned a value");
    } else |e| switch (e) {
        error.SeqOp => return proc.returnValue(ctx, @as(i64, 1)),
    }
}
