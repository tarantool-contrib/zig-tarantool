//! Raw + typed stored-proc layers.
//!
//! The raw layer is the C ABI contract: a proc is
//! `fn(*box_function_ctx_t, [*c]const u8, [*c]const u8) callconv(.c) c_int`
//! that returns its result solely through `box_return_mp`. `returnValue`
//! and `setBoxError` are the only primitives a hand-written raw proc needs.
//!
//! The typed layer (`exportProc`) is built strictly on top of the raw layer:
//! it reflects a plain Zig function's parameters, decodes the msgpack
//! argument array into them (fail-fast on arity/type mismatch →), calls the
//! function, and routes its result back through `returnValue`, or surfaces a
//! returned Zig error through `setBoxError` and a -1 return.

const std = @import("std");
const c = @import("c.zig");
const msgpack = @import("msgpack");
const error_ = @import("error.zig");
const tuple_mod = @import("tuple.zig");
const region = @import("region.zig");

/// The exact C ABI of a Tarantool C stored proc. Hand-written procs may
/// use this alias; the typed layer synthesizes functions of this shape.
pub const RawProc = fn (
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int;

/// Encode `value` to MessagePack and return it to the caller via
/// `box_return_mp`. The scratch is encoded on the fiber region under a per-call
/// savepoint and reclaimed before returning; this is safe because
/// `box_return_mp` copies the bytes synchronously. Returns the C
/// status from `box_return_mp` (0 ok / -1 err), or -1 with the host error set if
/// encoding fails (never return a partial buffer).
pub fn returnValue(ctx: ?*c.box_function_ctx_t, value: anytype) c_int {
    var svp = region.Savepoint.save();
    defer svp.restore();
    var buf = msgpack.Buffer.init(region.allocator());
    defer buf.deinit();

    msgpack.encode(&buf, value) catch |e| {
        error_.setBoxError(c.ER_PROC_C, @errorName(e));
        return -1;
    };

    const items = buf.items();
    const begin: [*c]const u8 = items.ptr;
    return c.box_return_mp(ctx.?, begin, begin + items.len);
}

/// Return `t` to the caller via `box_return_tuple` — the single bridge a proc
/// uses to return a tuple. Returns the C status from `box_return_tuple`
/// (0 ok / -1 err). The tuple's reference is unaffected; the caller still owns
/// and must `deinit` its handle.
pub fn returnTuple(ctx: ?*c.box_function_ctx_t, t: tuple_mod.Tuple) c_int {
    return c.box_return_tuple(ctx.?, t.raw);
}

/// Fail a stored proc: return -1, surfacing a host error.
///
/// `error.BoxOp` is the single error value a box op returns on a host -1, which
/// proves the failing `box_*` call just set a fresh host error. Only then
/// is the host's existing error kept — and only if one is actually present.
/// For every other error value (or a missing host error), `fallback` is set
/// under `ER_PROC_C`, so a stale host error from an earlier op is never
/// surfaced as if it belonged to this failure.
pub fn fail(e: anyerror, fallback: []const u8) c_int {
    if (e != error.BoxOp or error_.lastError() == null) error_.setBoxError(c.ER_PROC_C, fallback);
    return -1;
}

/// Export a hand-written raw proc `f` that may return a Zig error, under the C
/// symbol `name`. The synthesized `callconv(.c)` wrapper runs `f` and, on a
/// returned error, maps it through `fail(e, @errorName(e))` — `error.BoxOp`
/// keeps the host's real message, every other error sets `ER_PROC_C` to the
/// error name (built on `fail`). On success it returns `f`'s `c_int`
/// unchanged. `f` owns the args decode, `ctx`, and the result
/// (`returnValue`/`returnTuple`); its shape is `RawProc` plus an error union:
/// `fn(ctx, args, args_end) anyerror!c_int`.
pub fn exportRaw(comptime name: []const u8, comptime f: anytype) void {
    const Wrapper = struct {
        fn call(
            ctx: ?*c.box_function_ctx_t,
            args: [*c]const u8,
            args_end: [*c]const u8,
        ) callconv(.c) c_int {
            return f(ctx, args, args_end) catch |e| fail(e, @errorName(e));
        }
    };
    @export(&Wrapper.call, .{ .name = name, .linkage = .strong });
}

/// Export a plain Zig function `f` as a Tarantool C stored proc under the C
/// symbol `name`. Built on the raw layer: a `callconv(.c)` wrapper of
/// `RawProc` shape is synthesized that
///   1. decodes the msgpack argument array into `f`'s parameters, checking
///      arity and per-element types (fail-fast →),
///   2. calls `f`,
///   3. on a returned Zig error, sets the host error and returns -1,
///   4. otherwise returns the result via `returnValue` (or 0 for `void`).
pub fn exportProc(comptime name: []const u8, comptime f: anytype) void {
    const F = @TypeOf(f);
    const fn_info = @typeInfo(F).@"fn";

    // Build a tuple struct mirroring f's parameters. Decoding this tuple reads
    // the msgpack array header and enforces arity (error.ArityMismatch) and
    // per-field types via the codec — the typed layer adds no new parsing.
    const ArgsTuple = std.meta.ArgsTuple(F);

    const Wrapper = struct {
        fn call(
            ctx: ?*c.box_function_ctx_t,
            args: [*c]const u8,
            args_end: [*c]const u8,
        ) callconv(.c) c_int {
            const len = @intFromPtr(args_end) - @intFromPtr(args);
            const bytes: []const u8 = args[0..len];

            var dec = msgpack.Decoder.init(bytes);
            const tuple = msgpack.decode(ArgsTuple, &dec) catch |e| {
                // Arity and type mismatches surface as the proc error.
                const msg = if (e == error.ArityMismatch)
                    "wrong argument count"
                else
                    @errorName(e);
                error_.setBoxError(c.ER_PROC_C, msg);
                return -1;
            };

            const ret_type = fn_info.return_type.?;
            switch (@typeInfo(ret_type)) {
                .error_union => |eu| {
                    const result = @call(.auto, f, tuple) catch |e| {
                        error_.setBoxError(c.ER_PROC_C, @errorName(e));
                        return -1;
                    };
                    // A void proc returns no values: return 0 without any
                    // `box_return_*`. An empty `box_return_mp` range is not "no
                    // value" — older Tarantool (seen on 3.5) appends it as one
                    // garbage value.
                    if (eu.payload == void) return 0;
                    return returnValue(ctx, result);
                },
                .void => {
                    @call(.auto, f, tuple);
                    return 0;
                },
                else => {
                    const result = @call(.auto, f, tuple);
                    return returnValue(ctx, result);
                },
            }
        }
    };

    @export(&Wrapper.call, .{ .name = name, .linkage = .strong });
}
