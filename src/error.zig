//! Zig error set ↔ Tarantool box errors.
//!
//! A failing stored proc must surface through `box_error_set` and return -1; it
//! must never return a partially-written result buffer. `setBoxError` is the
//! single bridge from a Zig `[]const u8` message into the host's error stack;
//! `lastError` reads the host's last error back as a borrowed `BoxError` view.

const std = @import("std");
const c = @import("c.zig");

/// SDK-level error set surfaced to callers. The msgpack codec has its own
/// `DecodeError`; this set names the failures the proc layer raises directly.
pub const Error = error{
    /// A stored proc was called with the wrong number of arguments.
    WrongArgCount,
};

/// Borrowed view over the host's last box error. The string pointers are owned
/// by the host error object and are only valid until the next box call mutates
/// the error stack; copy them if you need to retain them.
pub const BoxError = struct {
    code: u32,
    message: [*c]const u8,
    type: [*c]const u8,
};

/// Largest message length copied into the host error. Longer messages are
/// truncated to keep the stack buffer fixed-size (no runtime allocation here).
pub const max_message_len = 256;

/// Set the host's last error to `code` with `msg`. `box_error_set` takes a
/// printf-style format; we always pass `"%s"` with a null-terminated copy of
/// `msg` so the message is treated as literal data, never as a format string.
/// Truncates `msg` to `max_message_len` bytes.
pub fn setBoxError(code: u32, msg: []const u8) void {
    var buf: [max_message_len + 1]u8 = undefined;
    const n = @min(msg.len, max_message_len);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    _ = c.box_error_set("zig", 0, code, "%s", &buf);
}

/// Read the host's last error, or null if none is set.
pub fn lastError() ?BoxError {
    const e = c.box_error_last() orelse return null;
    return .{
        .code = c.box_error_code(e),
        .message = c.box_error_message(e),
        .type = c.box_error_type(e),
    };
}

/// Copy the host's last error message into `buf` and return the copied slice,
/// or null when no host error is set. The host message is a
/// NUL-terminated C string valid only until the next box call, so it is copied
/// synchronously; the result is truncated to `buf.len` and contains no NUL.
/// No host-owned pointer escapes — the returned slice points into `buf`.
pub fn lastMessage(buf: []u8) ?[]const u8 {
    const e = lastError() orelse return null;
    const msg = std.mem.span(@as([*:0]const u8, @ptrCast(e.message)));
    const n = @min(msg.len, buf.len);
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}
