//! Integration coverage for the box region allocator + `Savepoint` (IF1) and
//! for the per-call savepoint adoption inside the box CRUD layer (IF2).
//!
//! These procs prove three things end to end against a live host:
//!   * the region allocator hands back usable, correctly-sized scratch
//!     (`region_alloc_sum`);
//!   * a `Savepoint` reclaims everything allocated within its scope, so region
//!     usage returns to exactly the pre-scope mark (`region_net_zero`);
//!   * the box CRUD layer's internal per-call savepoints (IF2) also reclaim, so
//!     a full insert/get/delete round-trip leaves region usage flat
//!     (`region_box_crud`).
//!
//! The Lua driver invokes each proc twice and asserts the net `used()` delta is
//! 0 on BOTH calls — confirming region usage stays flat across repeated
//! invocations and does not grow unbounded.

const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const box = t.box;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// region_alloc_sum() -> the sum of all bytes written across N region-allocated
/// buffers, filled with a known pattern. Proves the allocator returns usable,
/// distinct, correctly-sized memory. All scratch lives inside one caller-owned
/// `Savepoint` scope and is reclaimed on scope exit.
///
/// We allocate buffers of sizes 1..=8, fill buffer k entirely with byte value k,
/// then sum every byte. Expected sum = sum over k in 1..=8 of (k * k) =
/// 1+4+9+16+25+36+49+64 = 204.
export fn region_alloc_sum(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    var sum: i64 = 0;
    {
        var svp = t.region.Savepoint.save();
        defer svp.restore();
        const a = t.region.allocator();

        var k: usize = 1;
        while (k <= 8) : (k += 1) {
            const buf = a.alloc(u8, k) catch return fail("alloc");
            // Write a known pattern, then read it back to prove the memory is
            // genuinely usable (not aliased / not zero-length).
            for (buf) |*byte| byte.* = @intCast(k);
            for (buf) |byte| sum += @as(i64, byte);
        }
    }
    return proc.returnValue(ctx, sum);
}

/// region_net_zero() -> the net change in `region.used()` measured across a
/// `Savepoint` scope: capture m0, open a savepoint, allocate and exercise
/// several buffers, close the scope (restore), then return
/// `used() - m0`. Must be 0: the savepoint reclaims everything.
///
/// The Lua driver calls this twice and asserts both results are 0, confirming
/// repeated invocations do not grow region usage.
export fn region_net_zero(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const m0 = t.region.used();
    {
        var svp = t.region.Savepoint.save();
        defer svp.restore();
        const a = t.region.allocator();

        // A handful of differently-sized buffers; touch each so the host cannot
        // optimize the allocation away.
        var acc: u8 = 0;
        var k: usize = 0;
        while (k < 5) : (k += 1) {
            const buf = a.alloc(u8, 16 + k * 32) catch return fail("alloc");
            for (buf) |*byte| byte.* = @intCast(k);
            acc +%= buf[buf.len - 1];
        }
        // Defeat dead-store elimination of `acc` without affecting the result.
        if (acc == 0xAB) return fail("unreachable pattern");
    }

    const delta: i64 = @as(i64, @intCast(t.region.used())) - @as(i64, @intCast(m0));
    return proc.returnValue(ctx, delta);
}

/// region_truncate() -> 1. Proves that `region.truncate(mark)` restores
/// `region.used()` to exactly the saved mark.
///
/// Captures `m` before any allocation, allocates 64 bytes via the region
/// allocator (so `used()` must grow), then calls `truncate(m)` and asserts
/// `used() == m`. Returns 1 on success.
export fn region_truncate(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const m = t.region.used();
    _ = t.region.allocator().alloc(u8, 64) catch return fail("alloc");
    if (t.region.used() <= m) return fail("used() did not grow after alloc");
    t.region.truncate(m);
    if (t.region.used() != m) return fail("used() != mark after truncate");
    return proc.returnValue(ctx, @as(i64, 1));
}

/// region_box_crud(id) -> the net change in `region.used()` across a full
/// insert / get / delete round-trip on space "t". Proves the box CRUD layer's
/// internal per-call savepoints (IF2) reclaim their encode scratch, leaving
/// region usage flat. Must be 0.
///
/// The space "t" with a primary key on field 1 (unsigned) is created by the Lua
/// driver. Every returned tuple is host-ref'd and released via `deinit` before
/// the delta is measured.
export fn region_box_crud(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const m0 = t.region.used();

    const space = box.Space.byName("t") catch return fail("byName");

    var inserted = (space.insert(.{ @as(i64, 4242), "region" }) catch return fail("insert")) orelse
        return fail("insert null");
    inserted.deinit();

    var got = (space.get(.{@as(i64, 4242)}) catch return fail("get")) orelse
        return fail("get null");
    got.deinit();

    var deleted = (space.delete(.{@as(i64, 4242)}) catch return fail("delete")) orelse
        return fail("delete null");
    deleted.deinit();

    const delta: i64 = @as(i64, @intCast(t.region.used())) - @as(i64, @intCast(m0));
    return proc.returnValue(ctx, delta);
}
