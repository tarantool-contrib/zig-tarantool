//! Integration coverage for `symresolve` against the live Tarantool binary.
//!
//! `symresolve.resolve` reads the main image's FULL symbol table
//! (`.symtab`/`LC_SYMTAB`), so it must find symbols that `dlsym` cannot — the
//! whole point of the module. Each proc returns 1/0 for one property; the Lua
//! driver asserts each with a clear message.
//!
//!   * exported_matches_dlsym — for an EXPORTED symbol (`box_txn_begin`, in
//!     module.h), resolve() finds it AND the address equals dlsym's. This
//!     proves the slide/base math, not just non-null.
//!   * hidden_found — a HIDDEN internal (`txn_begin`, present in the full
//!     table, absent from the dynamic table) resolves to non-null.
//!   * hidden_absent_from_dlsym — the same hidden symbol is NOT findable via
//!     dlsym, proving resolve() reaches strictly further.
//!   * missing_is_null / empty_is_null — well-formed misses.

const std = @import("std");
const builtin = @import("builtin");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;

/// An exported Tarantool C-API function (declared in module.h) — present in
/// BOTH the dynamic table and the full table.
const exported_symbol = "box_txn_begin";

/// An internal function hidden by `-fvisibility=hidden` — present in the full
/// table only. dlsym returns null for it; resolve() must not.
const hidden_symbol = "txn_begin";

extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// RTLD_DEFAULT: search every loaded image in the default order. `(void*)-2`
/// on Apple platforms, `NULL` on Linux/glibc.
const RTLD_DEFAULT: ?*anyopaque = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
    else => null,
};

fn boolResult(ctx: ?*c.box_function_ctx_t, ok: bool) c_int {
    return proc.returnValue(ctx, @as(u64, if (ok) 1 else 0));
}

/// resolve() finds the exported symbol and agrees with dlsym on its address.
export fn exported_matches_dlsym(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    const via_resolve = t.symresolve.resolve(exported_symbol);
    const via_dlsym = dlsym(RTLD_DEFAULT, exported_symbol);
    return boolResult(ctx, via_resolve != null and via_resolve == via_dlsym);
}

/// resolve() finds the hidden internal symbol.
export fn hidden_found(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return boolResult(ctx, t.symresolve.resolve(hidden_symbol) != null);
}

/// The hidden symbol is genuinely hidden — dlsym cannot see it. (If this
/// returned 0, the "hidden" symbol would be exported and the test meaningless.)
export fn hidden_absent_from_dlsym(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return boolResult(ctx, dlsym(RTLD_DEFAULT, hidden_symbol) == null);
}

/// A name no symbol table carries resolves to null (well-formed miss).
export fn missing_is_null(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return boolResult(ctx, t.symresolve.resolve("zig_tarantool_no_such_symbol_xyz") == null);
}

/// The empty name resolves to null without touching the symbol table.
export fn empty_is_null(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return boolResult(ctx, t.symresolve.resolve("") == null);
}
