//! Integration module exercising the box CRUD, tuple access, and transaction
//! helpers against a live Tarantool. Procs use the raw C ABI and return
//! results solely via `box_return_mp` with a self-encoded MessagePack buffer.
//! The space and primary index are created from `box.lua`, not from here.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const box = t.box;
const txn = t.txn;
const msgpack = t.msgpack;

/// Return `value` to the caller as a single MessagePack-encoded result.
/// Encodes into a fresh `c_allocator` buffer; `box_return_mp` copies, so the
/// buffer is freed right after. On encode failure sets the host error
/// and returns -1, never a partial buffer.
fn returnMp(ctx: ?*c.box_function_ctx_t, value: anytype) c_int {
    var buf = msgpack.Buffer.init(std.heap.c_allocator);
    defer buf.deinit();
    msgpack.encode(&buf, value) catch return -1;
    const bytes = buf.items();
    return c.box_return_mp(ctx.?, bytes.ptr, bytes.ptr + bytes.len);
}

fn setErr(msg: []const u8) c_int {
    t.err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// box_roundtrip(id, name): insert {id, name} into space 't', get it back by
/// key {id}, delete it, and return the name field (field index 1) read from
/// the fetched tuple. Proves insert/get/delete and tuple field access.
export fn box_roundtrip(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const params = msgpack.decode(struct { u32, []const u8 }, &dec) catch
        return setErr("box_roundtrip: bad args");
    const id = params[0];
    const name = params[1];

    const space = box.Space.byName("t") catch return setErr("no space t");

    {
        const inserted = space.insert(.{ id, name }) catch return setErr("insert failed");
        if (inserted) |tup| tup.deinit();
    }

    const got = space.get(.{id}) catch return setErr("get failed");
    if (got == null) return setErr("get returned nothing");
    const tup = got.?;
    defer tup.deinit();

    // Read field 1 (the name) back as a schema-less value, then return it.
    const f = tup.field(1, std.heap.c_allocator) catch return setErr("field decode failed");
    if (f == null) return setErr("missing field 1");
    const name_back = switch (f.?) {
        .str => |s| s,
        else => return setErr("field 1 not a string"),
    };

    // Stash result before further box calls invalidate the borrowed slice.
    const rc = returnMp(ctx, name_back);

    const deleted = space.delete(.{id}) catch return setErr("delete failed");
    if (deleted) |d| d.deinit();

    return rc;
}

/// box_count(): return the number of fields of the tuple {id} inserted then
/// fetched — used to sanity-check fieldCount/decode. Inserts {99,"z"}, decodes
/// it as a tuple struct, deletes it, returns the decoded id (99).
export fn box_decode(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;

    const space = box.Space.byName("t") catch return setErr("no space t");

    {
        const inserted = space.insert(.{ @as(u32, 99), "z" }) catch return setErr("insert failed");
        if (inserted) |tup| tup.deinit();
    }

    const got = space.get(.{@as(u32, 99)}) catch return setErr("get failed");
    if (got == null) return setErr("get returned nothing");
    const tup = got.?;
    defer tup.deinit();

    const decoded = tup.decode(struct { u32, []const u8 }, std.heap.c_allocator) catch
        return setErr("decode failed");
    const fc = tup.fieldCount();
    const id_back = decoded[0];

    const rc = returnMp(ctx, .{ id_back, fc });

    const deleted = space.delete(.{@as(u32, 99)}) catch return setErr("delete failed");
    if (deleted) |d| d.deinit();

    return rc;
}

/// box_txn_rollback_proc(id): inside a transaction, insert {id,"keep"} then
/// force the closure to fail; the helper rolls the transaction back. Returns
/// true (the proc itself succeeds — it asserts the rollback by reporting it
/// handled the error). After this runs, box.lua verifies the row is absent.
export fn box_txn_rollback_proc(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const params = msgpack.decode(struct { u32 }, &dec) catch
        return setErr("bad args");
    const id = params[0];

    const Ctx = struct {
        var key: u32 = 0;
        fn body() !void {
            const space = try box.Space.byName("t");
            const inserted = try space.insert(.{ key, "keep" });
            if (inserted) |tup| tup.deinit();
            // Force a failure so the transaction rolls back.
            return error.Forced;
        }
    };
    Ctx.key = id;

    // The transaction must surface the forced error after rolling back.
    txn.transaction(Ctx.body, .{}) catch |e| {
        if (e != error.Forced) return setErr("unexpected txn error");
        // Expected: rollback happened, row should not exist.
        return returnMp(ctx, true);
    };

    return setErr("transaction unexpectedly committed");
}

/// box_txn_commit_proc(id): inside a transaction, insert {id,"committed"} and
/// return normally so the helper commits. Returns true. box.lua then verifies
/// the row is present.
export fn box_txn_commit_proc(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const params = msgpack.decode(struct { u32 }, &dec) catch
        return setErr("bad args");
    const id = params[0];

    const Ctx = struct {
        var key: u32 = 0;
        fn body() !void {
            const space = try box.Space.byName("t");
            const inserted = try space.insert(.{ key, "committed" });
            if (inserted) |tup| tup.deinit();
        }
    };
    Ctx.key = id;

    txn.transaction(Ctx.body, .{}) catch return setErr("commit txn failed");
    return returnMp(ctx, true);
}
