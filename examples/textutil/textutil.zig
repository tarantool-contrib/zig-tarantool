//! A `require()`-able Lua module written in Zig. Built to `textutil.so`
//! (`textutil.dylib` on macOS); `require('textutil')` calls the
//! `luaopen_textutil` entry point that `lua.exportModule` emits.
//!
//!   local textutil = require('textutil')
//!   textutil.upper('hello')        --> 'HELLO'
//!   textutil.words('  a bb  ccc ') --> 3ULL
//!   textutil.divmod(17, 5)         --> 3LL, 2LL
//!   textutil.divmod(1, 0)          --> error: DivByZero
//!
//! Every entry is a plain Zig function: arguments are decoded off the Lua stack
//! by type, the result is pushed back, and a returned Zig error is raised as a
//! Lua error. A wrong argument type raises instead of being coerced. Zig
//! integers cross as 64-bit cdata (`int64_t`/`uint64_t`), which compare equal
//! to plain Lua numbers (`textutil.words('a b') == 2`).

const std = @import("std");
const t = @import("tarantool");
const lua = t.lua;
const region = t.region;

/// ASCII upper-case copy of `s`. The copy lives on the fiber region: the
/// wrapper bounds the call with a region savepoint, and Lua copies the string
/// when it is pushed, so nothing leaks.
fn upper(s: []const u8) ![]const u8 {
    const out = try region.allocator().alloc(u8, s.len);
    for (s, out) |ch, *o| o.* = std.ascii.toUpper(ch);
    return out;
}

/// Number of whitespace-separated words in `s`.
fn words(s: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var n: u64 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Quotient and remainder as two Lua return values.
fn divmod(a: i64, b: i64) !lua.Multi(struct { i64, i64 }) {
    if (b == 0) return error.DivByZero;
    return lua.multi(.{ @divTrunc(a, b), @mod(a, b) });
}

comptime {
    lua.exportModule("textutil", .{
        .upper = upper,
        .words = words,
        .divmod = divmod,
    });
}
