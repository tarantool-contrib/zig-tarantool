//! Integration module for the Lua C-API authoring layer.
//!
//! Built to `zig-out/lib/luamod.so`; `require('luamod')` in the driver calls the
//! emitted `luaopen_luamod`. Exercises a single raw `lua_CFunction` (`echo`)
//! routed through `exportModule` — proving the module loads, a function in its
//! table is callable, the `Lua` stack primitives round-trip a string, and a bad
//! argument raises rather than coerces.
//!
//! Named `luamod`, not `lua`: a driver script `lua.lua` lands on Tarantool's
//! `package.path` (the script's own directory) and would shadow `require('lua')`.

const t = @import("tarantool");
const c = t.c;
const lua = t.lua;
const region = t.region;
const tuple = t.tuple;
const decimal = t.decimal;

/// Raw entry: return argument 1 unchanged, or raise if it is not a string.
fn echo(L: ?*c.lua_State) callconv(.c) c_int {
    const s = lua.Lua.init(L.?);
    const arg = s.toLString(1) orelse return s.raise("echo: expected a string");
    s.pushLString(arg);
    return 1;
}

/// Typed: sum two 64-bit integers (in/out as int64 cdata).
fn add(a: i64, b: i64) i64 {
    return a + b;
}

/// Typed: concatenate two strings. Allocates the result on the fiber region;
/// the typed wrapper owns the bounding savepoint and the host copies the bytes
/// out of the pushed string, so the scratch is reclaimed after the call.
fn concat(a: []const u8, b: []const u8) ![]const u8 {
    const out = try region.allocator().alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Typed: optional in, optional out (nil ↔ null) — increments when present.
fn incOpt(x: ?i64) ?i64 {
    return if (x) |v| v + 1 else null;
}

/// Named struct ↔ Lua table (string keys).
const Point = struct { x: i64, y: i64 };
fn bump(p: Point) Point {
    return .{ .x = p.x + 1, .y = p.y + 1 };
}

/// Tuple struct ↔ Lua array (1-based).
fn swap(p: struct { i64, i64 }) struct { i64, i64 } {
    return .{ p[1], p[0] };
}

/// Slice ↔ Lua array.
fn sumI64(xs: []const i64) i64 {
    var s: i64 = 0;
    for (xs) |x| s += x;
    return s;
}

/// Typed: sum two unsigned 64-bit integers (in/out as uint64 cdata, full u64 range).
fn addU64(a: u64, b: u64) u64 {
    return a + b;
}

/// Tuple bridge: take a box.tuple, return a new 2-field tuple `{field0+1, "ok"}`.
/// The arg is borrowed-for-call; the returned tuple is created (and ref'd) here
/// and handed to the wrapper, which pushes it and releases this handle.
fn tupleBump(tup: tuple.Tuple) !tuple.Tuple {
    const first = (try tup.get(0, i64, region.allocator())) orelse return error.NoField;
    return tuple.Tuple.new(.{ first + 1, "ok" }, region.allocator());
}

/// Decimal bridge: pull a decimal cdata, add 1, push the result (copy both
/// ways). A plain Lua number/string is not a decimal cdata, so the pull raises
/// TypeMismatch (no coercion) before this body runs.
fn decIncr(d: decimal.Decimal) !decimal.Decimal {
    const one = decimal.Decimal.fromInt(1);
    return d.add(&one);
}

/// Multi-return: two i64 results (quotient, remainder), or an error on b == 0.
/// Runtime elements, so the `lua.multi` value helper applies.
fn divmod(a: i64, b: i64) !lua.Multi(struct { i64, i64 }) {
    if (b == 0) return error.DivByZero;
    return lua.multi(.{ @divTrunc(a, b), @mod(a, b) });
}

/// Multi-return with a mixed string+int shape. `lua.multi` does NOT compile for
/// a comptime string literal (verify-proven), so this uses the documented
/// direct-init form with an explicit return type — proving region-scratch
/// string pushes compose in a Multi fan-out and pinning the `multi` limitation.
fn nameAge() lua.Multi(struct { []const u8, i64 }) {
    return .{ .values = .{ "bob", 30 } };
}

comptime {
    lua.exportModule("luamod", .{
        .echo = echo,
        .add = add,
        .concat = concat,
        .inc_opt = incOpt,
        .bump = bump,
        .swap = swap,
        .sum_i64 = sumI64,
        .add_u64 = addU64,
        .tuple_bump = tupleBump,
        .dec_incr = decIncr,
        .divmod = divmod,
        .name_age = nameAge,
    });
}
