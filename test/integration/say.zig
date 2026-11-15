//! Integration coverage for the `say` logging module (src/say.zig) against a
//! live Tarantool. Logging is meaningless without a real host sink (the
//! `zig build test` smoke only type-checks the surface), so this driver IS the
//! behavioral coverage: each proc logs a unique marker and the luatest driver
//! (`test/luatest/say_test.lua`) observes it through `srv:grep_log`.
//!
//! This file IS the root module of `say.so`, so its `std_options` override
//! takes effect for the whole module — routing every `std.log` call through the
//! Tarantool log via `say.stdLogFn` (the std.log adapter case).
//!
//! Procs use the raw C ABI and return their result via `proc.returnValue`,
//! mirroring `test/integration/cond.zig`.

const std = @import("std");
const t = @import("tarantool");
const c = t.c;
const proc = t.proc;
const err = t.err;
const say = t.say;

/// Route the whole module's std.log through the Tarantool log (the adapter
/// case). Because this file is the root of `say.so`, the override is honored.
pub const std_options: std.Options = .{ .logFn = say.stdLogFn };

fn fail(comptime msg: []const u8) c_int {
    err.setBoxError(c.ER_PROC_C, msg);
    return -1;
}

/// say_levels() -> 1. Logs one fixed marker per level helper, each with a
/// formatted arg (proving the Zig-format path). The luatest driver greps each
/// marker with its severity tag.
export fn say_levels(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    say.err("ZIGSAY_ERR n={d}", .{42});
    say.crit("ZIGSAY_CRIT n={d}", .{42});
    say.warn("ZIGSAY_WARN n={d}", .{42});
    say.info("ZIGSAY_INFO n={d}", .{42});
    say.verbose("ZIGSAY_VERBOSE n={d}", .{42});
    say.debug("ZIGSAY_DEBUG n={d}", .{42});
    return proc.returnValue(ctx, @as(i64, 1));
}

/// say_enabled_debug() -> 0|1. Reports `say.enabled(.debug)` at the host's
/// current threshold (probe: `box.cfg{log_level=...}` must reach the C
/// global our `enabled()` reads).
export fn say_enabled_debug(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, @as(i64, @intFromBool(say.enabled(.debug))));
}

/// say_fmt_passthrough() -> 1. Logs a marker containing printf specifiers as
/// literal DATA: the percent text must appear verbatim, proving it
/// never reached `_say`'s format parameter.
export fn say_fmt_passthrough(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    say.info("ZIGSAY_FMT %s %d %n", .{});
    return proc.returnValue(ctx, @as(i64, 1));
}

/// say_truncation() -> 1. Logs a >1 KiB line: it must appear
/// truncated with the trailing `...` marker, and the server must stay alive.
export fn say_truncation(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    say.info("ZIGSAY_TRUNC " ++ @as([2000]u8, @splat('A')), .{});
    return proc.returnValue(ctx, @as(i64, 1));
}

/// say_syserror() -> 1. Logs at SYSERROR level with errno 2 (ENOENT); the host
/// appends `": No such file or directory"` (the say_syserror macro shape).
export fn say_syserror(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    say.sysError(2, "ZIGSAY_SYS open failed", .{});
    return proc.returnValue(ctx, @as(i64, 1));
}

/// say_stdlog() -> 1. Emits via `std.log.info`; the module's `std_options`
/// override routes it into the Tarantool log through `say.stdLogFn`.
export fn say_stdlog(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    std.log.info("ZIGSAY_STDLOG via std", .{});
    return proc.returnValue(ctx, @as(i64, 1));
}

/// say_debug_filtered() -> 1. Logs a single marker at DEBUG level. Used at
/// log_level=5 (info): the marker must NOT reach the log (the filtering case).
export fn say_debug_filtered(ctx: ?*c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    say.debug("ZIGSAY_FILTERED n={d}", .{7});
    return proc.returnValue(ctx, @as(i64, 1));
}
