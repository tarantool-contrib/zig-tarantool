//! Write into Tarantool's own log (the `box.cfg{log=...}` destination, with the
//! host's level filtering and line format) from Zig module code, instead of
//! stderr. A host-bound module: it imports `c.zig` and calls the host `_say`
//! sink directly. The `say*()` C macros cannot be bound (they wrap a
//! `static inline` level check), so the check is reimplemented as `enabled` and
//! the sink is called through `c._say`.
//!
//! Discipline mirrors `error.zig`'s `setBoxError`: module text is formatted in
//! Zig first and handed to `_say` through a literal `"%s"`, so it can never be
//! interpreted as a printf format string. Formatting goes into one fixed
//! stack buffer with no allocation on the log path; the sink pointer is
//! read per call and never cached, because the host swaps it on log rotation;
//! and `enabled()` gates before formatting so a filtered `debug` costs
//! only an extern-var load and a compare.
//!
//! The position stamped into every line is the static `("zig", 0)` pair that
//! `error.zig` already uses. Zig has no caller-location mechanism, and
//! `@src()` inside these (inline) wrappers reports the wrapper's OWN location,
//! not the caller's (verified on the 0.16 toolchain) — so it would mislabel
//! every line with `say.zig:NN`. Callers embed context in the message instead.

const std = @import("std");
const c = @import("c.zig");

/// Log severity levels, matching `enum say_level` in module.h (values pinned by
/// c_verify's `assertLevel`, module.h:509-519). `fatal` is present for
/// completeness but is deliberately NOT exposed as a helper: the host ties
/// S_FATAL to panic paths and module.h says "do not use this value directly".
pub const Level = enum(c_int) {
    fatal = 0,
    syserror = 1,
    err = 2,
    crit = 3,
    warn = 4,
    info = 5,
    verbose = 6,
    debug = 7,
};

/// Fixed stack buffer size for a formatted log line. Longer lines are
/// truncated with a trailing `...` marker; log lines have no business being
/// larger, and this keeps the log path allocation-free.
pub const max_line_len = 1024;

/// Whether `level` would be emitted at the host's current threshold. Reads the
/// extern `log_level` per call (the host updates it live on
/// `box.cfg{log_level=...}`), reimplementing the `static inline`
/// `say_log_level_is_enabled` (module.h:552-556).
pub fn enabled(level: Level) bool {
    return @backingInt(level) <= c.log_level;
}

/// The single funnel onto the host sink. Gates on `enabled` before formatting;
/// reads `c._say` per call and drops the line silently if it is null
/// rather than crashing; formats into one fixed stack buffer with no
/// allocation, truncating with `...` on overflow; and hands the result to
/// `_say` through a literal `"%s"` at the static `("zig", 0)` position. `err_str` becomes `_say`'s `error` argument (null for the plain levels;
/// the strerror text for `sysError`).
fn emit(level: Level, err_str: [*c]const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    const f = c._say orelse return;

    var buf: [max_line_len]u8 = undefined;
    const msg: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch blk: {
        // Overflow: stamp the tail with `...` and a NUL, use the full buffer.
        @memcpy(buf[max_line_len - 4 ..][0..3], "...");
        buf[max_line_len - 1] = 0;
        break :blk buf[0 .. max_line_len - 1 :0];
    };

    f(@backingInt(level), "zig", 0, err_str, "%s", msg.ptr);
}

/// Log at ERROR level. `fmt`/`args` are Zig-format (not printf); the formatted
/// text is passed as data, never as a format string.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, null, fmt, args);
}

/// Log at CRIT level.
pub fn crit(comptime fmt: []const u8, args: anytype) void {
    emit(.crit, null, fmt, args);
}

/// Log at WARN level.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, null, fmt, args);
}

/// Log at INFO level.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(.info, null, fmt, args);
}

/// Log at VERBOSE level.
pub fn verbose(comptime fmt: []const u8, args: anytype) void {
    emit(.verbose, null, fmt, args);
}

/// Log at DEBUG level.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    emit(.debug, null, fmt, args);
}

/// Log at SYSERROR level with the message for `errnum` appended by the host.
/// Passes `_say_strerror(errnum)` as `_say`'s `error` argument; the host renders
/// `<message>: <strerror>`, exactly like the `say_syserror()` macro
/// (module.h:626-627).
pub fn sysError(errnum: i32, comptime fmt: []const u8, args: anytype) void {
    emit(.syserror, c._say_strerror(@intCast(errnum)), fmt, args);
}

/// Adapter for `std.log`. Set
/// `pub const std_options: std.Options = .{ .logFn = tarantool.say.stdLogFn };`
/// in the module root, and every `std.log` call in the module (and its deps)
/// lands in the Tarantool log. Maps `std.log.Level` → `Level`
/// (`.err→.err, .warn→.warn, .info→.info, .debug→.debug`); a non-`.default`
/// scope is prefixed `(<scope>): ` like std's default logger.
pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const lvl: Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const full_fmt = if (scope == .default)
        fmt
    else
        "(" ++ @tagName(scope) ++ "): " ++ fmt;
    emit(lvl, null, full_fmt, args);
}

test {
    // Compile-smoke only: logging needs a live host, so this references
    // the public surface at comptime without running any of it. The level
    // helpers and stdLogFn are generic (`anytype` args), so referencing their
    // addresses alone would NOT type-check `emit`'s body — force it by taking
    // the address of a NON-generic wrapper that calls each with concrete args
    // (`_ = &emit` alone does not compile the generic body).
    _ = &enabled;
    const Probe = struct {
        fn all() void {
            err("e={d}", .{@as(i64, 1)});
            crit("c={d}", .{@as(i64, 1)});
            warn("w={d}", .{@as(i64, 1)});
            info("i={d}", .{@as(i64, 1)});
            verbose("v={d}", .{@as(i64, 1)});
            debug("d={d}", .{@as(i64, 1)});
            sysError(2, "s={d}", .{@as(i64, 1)});
            stdLogFn(.info, .default, "std={d}", .{@as(i64, 1)});
            stdLogFn(.warn, .my_scope, "scoped={d}", .{@as(i64, 1)});
        }
    };
    _ = &Probe.all;
}
