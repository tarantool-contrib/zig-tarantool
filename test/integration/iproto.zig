//! Live parity coverage for the pure iproto protocol layer:
//! proves every Zig-pinned iproto constant against the running server's
//! `box.iproto.type`/`.key`/`.feature`, and cross-checks the wire encoders
//! (scramble chain + a full SELECT frame) against the live runtime. This is the
//! connector's analog of `verify-cabi` — the pins in `tarantool-proto`'s
//! `iproto.zig` are asserted equal to what the server actually reports.
//!
//! The stored procs here are deliberately thin: they surface the Zig pins and
//! encoder outputs; every assertion lives in the Lua driver (`iproto_test.lua`),
//! which owns the live `box.iproto` tables and the digest machinery.
//!
//!   - `iproto_type_pins` / `iproto_key_pins` / `iproto_feature_pins`: return
//!     the pinned enum as a `name -> value` msgpack map, built by reflection
//!     over the Zig enum (so a dropped/renamed pin changes the count Lua sees,
//!     never silently). The type map additionally carries the standalone
//!     `TYPE_ERROR` mask.
//!   - `iproto_scramble(salt)`: chap-sha1 scramble of a FIXED test password
//!     against the caller's 20-byte salt, returned as raw bytes so Lua can
//!     recompute it via `digest.sha1` + `bit.bxor` and assert byte equality.
//!   - `iproto_build_select_frame()`: one complete SELECT request frame built
//!     with `request.select` (fixed sync/space/index/iterator/limit/offset/key),
//!     returned raw so Lua can strip the 5-byte size prefix, `msgpack.decode`
//!     the header and body maps, and assert every key/value (names-in-DML:
//!     SPACE_NAME present, SPACE_ID absent).
//!
//! This module imports `tarantool-proto` directly (the SDK does not re-export
//! iproto); the pure layer stays msgpack+std-only — nothing host-bound
//! leaks into it.

const std = @import("std");
const t = @import("tarantool");
const p = @import("tarantool-proto");

const c = t.c;
const proc = t.proc;
const err = t.err;
const msgpack = t.msgpack;

const iproto = p.iproto;
const auth = p.auth;

const alloc = std.heap.c_allocator;

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

// ---------------------------------------------------------------------------
// Constant pins, reflected straight off the Zig enums (no hand re-listing, so
// the maps and their counts track `iproto.zig` verbatim).
// ---------------------------------------------------------------------------

/// `name -> value` KV pairs for every field of enum `E`.
fn enumKVs(comptime E: type) [@typeInfo(E).@"enum".field_names.len]msgpack.KV {
    const info = @typeInfo(E).@"enum";
    var kvs: [info.field_names.len]msgpack.KV = undefined;
    for (info.field_names, info.field_values, 0..) |name, value, i| {
        kvs[i] = .{ .key = .{ .str = name }, .value = .{ .uint = value } };
    }
    return kvs;
}

/// RequestType pins + the standalone TYPE_ERROR mask (which is a `const`, not an
/// enum member).
const type_pins = enumKVs(iproto.RequestType) ++
    [_]msgpack.KV{.{ .key = .{ .str = "TYPE_ERROR" }, .value = .{ .uint = iproto.TYPE_ERROR } }};

const key_pins = enumKVs(iproto.Key);
const feature_pins = enumKVs(iproto.Feature);

export fn iproto_type_pins(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, msgpack.Value{ .map = &type_pins });
}

export fn iproto_key_pins(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, msgpack.Value{ .map = &key_pins });
}

export fn iproto_feature_pins(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, msgpack.Value{ .map = &feature_pins });
}

// ---------------------------------------------------------------------------
// scramble cross-check
// ---------------------------------------------------------------------------

/// The plaintext the parity scramble is computed over. Must match the Lua
/// driver's `test_password` exactly — Lua recomputes the digest chain with the
/// same password and salt and asserts the bytes are identical.
const test_password = "iproto-parity-secret";

/// iproto_scramble(salt) -> chap-sha1 scramble of `test_password` against the
/// 20-byte `salt`, as raw bytes (MP_STR). Fails loudly on a wrong-length salt.
export fn iproto_scramble(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const v = dec.decodeValue(alloc) catch return fail("scramble: decode");
    defer msgpack.freeValue(alloc, v);
    if (v != .array or v.array.len != 1) return fail("scramble: expected 1-arg array");
    const salt = switch (v.array[0]) {
        .str => |s| s,
        .bin => |s| s,
        else => return fail("scramble: salt must be a string"),
    };
    if (salt.len != 20) return fail("scramble: salt must be 20 bytes");

    const digest = auth.scramble(test_password, salt[0..20]);
    return proc.returnValue(ctx, @as([]const u8, &digest));
}

// ---------------------------------------------------------------------------
// SELECT frame fixture
// ---------------------------------------------------------------------------

// Fixed SELECT parameters — the Lua driver hard-asserts each of these against
// the decoded frame, so they are the oracle here.
const sel_sync: u64 = 0x1234; // multi-byte, so Lua exercises MP_UINT decode
const sel_space = "tester";
const sel_index = "primary";
const sel_limit: u32 = 100;
const sel_offset: u32 = 5;
// pre-encoded key array [42]: MP_ARRAY(1) ++ 42.
const sel_key = [_]u8{ 0x91, 0x2a };

/// iproto_build_select_frame() -> one complete SELECT request frame (size prefix
/// ++ header map ++ body map) as raw bytes. Lua strips the prefix, decodes the
/// two maps, and asserts every key/value (names-in-DML: SPACE_NAME present,
/// SPACE_ID/INDEX_ID absent).
export fn iproto_build_select_frame(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    var buf = msgpack.Buffer.init(alloc);
    defer buf.deinit();
    iproto.request.select(&buf, sel_sync, sel_space, sel_index, .eq, sel_limit, sel_offset, &sel_key) catch
        return fail("select: build");
    return proc.returnValue(ctx, @as([]const u8, buf.items()));
}
