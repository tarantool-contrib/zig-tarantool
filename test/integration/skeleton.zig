//! Walking-skeleton C module: the smallest proc that loads, runs, and returns.
//! Proves the build emits a Tarantool-loadable `.so` and that an exported C-ABI
//! symbol can return a MessagePack result via `box_return_mp`.

const t = @import("tarantool");
const c = t.c;

/// Returns the MessagePack integer 42, ignoring its arguments.
export fn skeleton_const(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const mp = [_]u8{0x2a}; // msgpack positive fixint 42
    const begin: [*c]const u8 = &mp;
    return c.box_return_mp(ctx.?, begin, begin + mp.len);
}
