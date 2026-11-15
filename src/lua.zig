//! Authoring Lua C modules in Zig.
//!
//! This is the Lua analog of `proc.zig`: instead of stored procs returned through
//! `box_return_mp`, it exposes `require()`-able Lua modules. The boundary is the
//! LuaJIT C stack (`lua_*`/`luaL_*`) plus Tarantool's int64/cdata extensions, all
//! resolved from the host at dlopen.
//!
//! `Lua` is a thin handle over `*lua_State` carrying the stack primitives.
//! `exportModule(name, defs)` builds a `luaL_Reg` table from `defs` and emits the
//! `luaopen_<name>` entry point the host calls on `require('<name>')`. A
//! `defs` entry is either a raw `lua_CFunction` (used verbatim) or a plain Zig
//! function (typed-wrapped: args decoded off the stack, result encoded back).

const std = @import("std");
const c = @import("c.zig");
const region = @import("region.zig");
const error_ = @import("error.zig");
const tuple_mod = @import("tuple.zig");
const decimal_mod = @import("decimal.zig");

/// A Lua-callable C function, by value: receives the state, returns the number
/// of results it left on the stack. The shape a raw `defs` entry must have.
pub const RawFn = fn (?*c.lua_State) callconv(.c) c_int;

/// Thin handle over a host `lua_State`. Construct from the pointer a
/// `lua_CFunction` receives (`Lua.init(L.?)`); copies freely (it holds only the
/// pointer). Readers (`to*`) are the non-raising LuaJIT accessors — they never
/// longjmp, so they are safe to call with live Zig `defer`s on the frame.
pub const Lua = struct {
    L: *c.lua_State,

    pub fn init(L: *c.lua_State) Lua {
        return .{ .L = L };
    }

    /// Number of values currently on the stack (also the last index).
    pub fn top(self: Lua) c_int {
        return c.lua_gettop(self.L);
    }

    /// The Lua type tag (`c.LUA_T*`) of the value at `idx`.
    pub fn typeOf(self: Lua, idx: c_int) c_int {
        return c.lua_type(self.L, idx);
    }

    pub fn pushNil(self: Lua) void {
        c.lua_pushnil(self.L);
    }

    pub fn pushBool(self: Lua, b: bool) void {
        c.lua_pushboolean(self.L, if (b) 1 else 0);
    }

    pub fn pushNumber(self: Lua, n: f64) void {
        c.lua_pushnumber(self.L, n);
    }

    /// Push `v` as a 64-bit signed cdata (full precision, not a `lua_Number`).
    pub fn pushInt64(self: Lua, v: i64) void {
        c.luaL_pushint64(self.L, v);
    }

    /// Push `v` as a 64-bit unsigned cdata.
    pub fn pushUint64(self: Lua, v: u64) void {
        c.luaL_pushuint64(self.L, v);
    }

    /// Push `s` as a Lua string. The host copies the bytes synchronously,
    /// so `s` need not outlive the call.
    pub fn pushLString(self: Lua, s: []const u8) void {
        c.lua_pushlstring(self.L, s.ptr, s.len);
    }

    pub fn toBool(self: Lua, idx: c_int) bool {
        return c.lua_toboolean(self.L, idx) != 0;
    }

    pub fn toNumber(self: Lua, idx: c_int) f64 {
        return c.lua_tonumber(self.L, idx);
    }

    /// The value at `idx` as a borrowed byte slice, or null if it is not a
    /// string. The slice aliases Lua-owned memory valid only while the value
    /// stays on the stack — copy out anything that must outlive it.
    pub fn toLString(self: Lua, idx: c_int) ?[]const u8 {
        var len: usize = undefined;
        const p = c.lua_tolstring(self.L, idx, &len);
        if (p == null) return null;
        return p[0..len];
    }

    pub fn toInt64(self: Lua, idx: c_int) i64 {
        return c.luaL_toint64(self.L, idx);
    }

    pub fn toUint64(self: Lua, idx: c_int) u64 {
        return c.luaL_touint64(self.L, idx);
    }

    /// Create and push an empty table.
    pub fn newTable(self: Lua) void {
        c.lua_createtable(self.L, 0, 0);
    }

    /// Push `t[k]` where `t` is the table at `idx` (`k` NUL-terminated).
    pub fn getField(self: Lua, idx: c_int, k: [*c]const u8) void {
        c.lua_getfield(self.L, idx, k);
    }

    /// Set `t[k]` from the value on top of the stack (popped), `t` at `idx`.
    pub fn setField(self: Lua, idx: c_int, k: [*c]const u8) void {
        c.lua_setfield(self.L, idx, k);
    }

    /// Push `t[n]` (raw, 1-based), `t` at `idx`.
    pub fn rawGetI(self: Lua, idx: c_int, n: c_int) void {
        c.lua_rawgeti(self.L, idx, n);
    }

    /// Set `t[n]` (raw, 1-based) from the value on top (popped), `t` at `idx`.
    pub fn rawSetI(self: Lua, idx: c_int, n: c_int) void {
        c.lua_rawseti(self.L, idx, n);
    }

    /// Length of the value at `idx` (`#` operator semantics for tables/strings).
    pub fn objLen(self: Lua, idx: c_int) usize {
        return c.lua_objlen(self.L, idx);
    }

    /// Pop `n` values off the top of the stack.
    pub fn pop(self: Lua, n: c_int) void {
        c.lua_settop(self.L, -n - 1);
    }

    /// Raise a Lua error carrying `msg` as literal text and never return — the
    /// single longjmp site of the typed layer, called only after every Zig
    /// `defer` on the frame has unwound. `msg` is copied and truncated to
    /// the stack buffer; `"%s"` keeps it from being read as a format string.
    pub fn raise(self: Lua, msg: []const u8) c_int {
        var buf: [256]u8 = undefined;
        const n = @min(msg.len, buf.len - 1);
        @memcpy(buf[0..n], msg[0..n]);
        buf[n] = 0;
        return c.luaL_error(self.L, "%s", &buf);
    }
};

/// Opt-in multi-return marker: a typed export returning `Multi(T)` (T a tuple
/// struct) yields one Lua value per element, in order. A PLAIN tuple struct
/// return still becomes a single Lua array-table (non-breaking).
pub fn Multi(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("lua.Multi(T): T must be a tuple struct, got " ++ @typeName(T));
    return struct {
        pub const __lua_multi = {}; // detection marker
        values: T,
    };
}

/// Value helper: `return lua.multi(.{ q, r });`
/// LIMITATION (verify-proven, Zig 0.16): works only when EVERY element is
/// runtime-known. An anonymous tuple literal captures comptime-known elements
/// (e.g. a string literal) as comptime fields, making `Multi(@TypeOf(values))`
/// a distinct type from any declarable return type — compile error. For
/// comptime-known elements, declare the return type explicitly and direct-init:
/// `fn nameAge() lua.Multi(struct { []const u8, i64 }) {
///      return .{ .values = .{ "bob", 30 } }; }`
pub fn multi(values: anytype) Multi(@TypeOf(values)) {
    return .{ .values = values };
}

/// Export `defs` as a `require('<name>')`-able Lua module by emitting the
/// `luaopen_<name>` C symbol. Each field of the `defs` struct becomes a
/// function in the module table under its field name: a raw `lua_CFunction`
/// (`RawFn` value or `*const RawFn`) is registered verbatim, any other plain Zig
/// function is typed-wrapped (`typedWrap`).
pub fn exportModule(comptime name: [:0]const u8, comptime defs: anytype) void {
    const Mod = struct {
        const reg = buildReg(defs);
        fn open(L: ?*c.lua_State) callconv(.c) c_int {
            c.luaL_register(L.?, name, &reg);
            return 1;
        }
    };
    @export(&Mod.open, .{ .name = "luaopen_" ++ name, .linkage = .strong });
}

/// Build the NUL-terminated `luaL_Reg` array for `defs` at comptime.
fn buildReg(comptime defs: anytype) [@typeInfo(@TypeOf(defs)).@"struct".field_names.len + 1]c.luaL_Reg {
    const fields = @typeInfo(@TypeOf(defs)).@"struct".field_names;
    var arr: [fields.len + 1]c.luaL_Reg = undefined;
    for (fields, 0..) |name, i| {
        arr[i] = .{ .name = name.ptr, .func = wrapEntry(@field(defs, name)) };
    }
    arr[fields.len] = .{ .name = null, .func = null };
    return arr;
}

/// Resolve one `defs` entry to a `lua_CFunction`: a raw `lua_CFunction` is used
/// verbatim; any other plain Zig function is typed-wrapped (`typedWrap`).
fn wrapEntry(comptime entry: anytype) c.lua_CFunction {
    const E = @TypeOf(entry);
    if (E == RawFn) return &entry;
    if (E == *const RawFn) return entry;
    return typedWrap(entry);
}

/// Synthesize a `lua_CFunction` from a plain Zig function `f`. The args are
/// decoded from the Lua stack into `f`'s parameters and the result is encoded
/// back, via the **body/raise split**: `body` does all fallible work using
/// only non-raising accessors and surfaces failures as Zig errors; the outer
/// `callconv(.c)` wrapper runs the single longjmp (`raise`) only after `body` has
/// fully returned, so no Zig `defer` is ever skipped.
fn typedWrap(comptime f: anytype) c.lua_CFunction {
    const F = @TypeOf(f);
    const fn_info = @typeInfo(F).@"fn";
    const Args = std.meta.ArgsTuple(F);

    const Wrapper = struct {
        /// Never longjmps. Owns a region savepoint bounding any scratch the arg
        /// decode or `f`'s returned slice allocates; restored after the result is
        /// pushed — safe because `push` copies into Lua.
        fn body(lua: Lua) anyerror!c_int {
            if (lua.top() != fn_info.param_types.len) return error.ArityMismatch;

            var sp = region.Savepoint.save();
            defer sp.restore();

            var args: Args = undefined;
            // Count of args successfully pulled so far. Registered before the
            // pull loop so a mid-loop pull failure still releases the refs that
            // earlier tuple args acquired — only slots `i < pulled` are live
            // (borrowed-for-call). LIFO with sp.restore — order irrelevant.
            var pulled: usize = 0;
            defer inline for (fn_info.param_types, 0..) |p, i| {
                if (p.? == tuple_mod.Tuple and i < pulled) args[i].deinit();
            };
            inline for (fn_info.param_types, 0..) |p, i| {
                args[i] = try pull(p.?, lua, @intCast(i + 1));
                pulled = i + 1;
            }

            switch (@typeInfo(fn_info.return_type.?)) {
                .error_union => |eu| {
                    const r = try @call(.auto, f, args);
                    if (eu.payload == void) return 0;
                    return try pushReturn(lua, r);
                },
                .void => {
                    @call(.auto, f, args);
                    return 0;
                },
                else => {
                    return try pushReturn(lua, @call(.auto, f, args));
                },
            }
        }

        fn call(L: ?*c.lua_State) callconv(.c) c_int {
            const lua = Lua.init(L.?);
            return body(lua) catch |e| raiseErr(lua, e);
        }
    };
    return &Wrapper.call;
}

/// Push `f`'s return value(s) and return the Lua result count. A `lua.Multi`
/// return fans out: each `values` field is pushed in declaration order through
/// `pushResult`, so a per-element `tuple.Tuple` ref is released exactly as a
/// single return would be. Any other return is a single value (count 1).
/// A pure dispatch shim — it owns no conversion logic (that stays in `push`).
fn pushReturn(lua: Lua, r: anytype) anyerror!c_int {
    const R = @TypeOf(r);
    if (@typeInfo(R) == .@"struct" and @hasDecl(R, "__lua_multi")) {
        const fields = @typeInfo(@TypeOf(r.values)).@"struct".field_names;
        inline for (fields) |name| try pushResult(lua, @field(r.values, name));
        return @intCast(fields.len);
    }
    try pushResult(lua, r);
    return 1;
}

/// Push `f`'s result, then release a returned `tuple.Tuple`'s ref — the wrapper
/// owns the return, and `luaT_pushtuple` already took its own ref + `__gc`.
/// A non-tuple result has nothing to release.
fn pushResult(lua: Lua, r: anytype) anyerror!void {
    try push(lua, r);
    if (@TypeOf(r) == tuple_mod.Tuple) r.deinit();
}

/// Map a Zig error to a Lua error (the terminal longjmp). `error.BoxOp` with a
/// host error present surfaces the host message; otherwise the error name. Called only from the `callconv(.c)` frame after `body` returned.
///
/// Public because it is the canonical Zig-error→Lua-error map: `src/trigger.zig`
/// reuses it verbatim in its on_replace trampoline's body/raise split, so a Veto
/// error raised from a trigger surfaces exactly like a typed-proc error.
pub fn raiseErr(lua: Lua, e: anyerror) c_int {
    if (e == error.BoxOp) {
        var buf: [error_.max_message_len]u8 = undefined;
        if (error_.lastMessage(&buf)) |m| return lua.raise(m);
    }
    return lua.raise(@errorName(e));
}

/// Decode the Lua value at `idx` into a `T`. Uses only non-raising accessors and
/// returns `error.TypeMismatch`/`error.Overflow` on a bad value — never longjmps
/// and never silently coerces. `[]const u8` borrows Lua-owned memory
/// valid only while the value stays on the stack.
fn pull(comptime T: type, lua: Lua, idx: c_int) anyerror!T {
    // tuple.Tuple is itself a struct, so it must be matched before the generic
    // struct case. The decoded handle owns a fresh ref (luaT_istuple borrows);
    // `body` releases it after the call (borrowed-for-call).
    if (T == tuple_mod.Tuple) {
        const raw = c.luaT_istuple(lua.L, idx) orelse return error.TypeMismatch;
        _ = c.box_tuple_ref(raw);
        return tuple_mod.Tuple.init(raw);
    }
    // decimal.Decimal is also a struct — match before the generic struct case.
    // A plain Lua number is NOT a decimal cdata: luaT_isdecimal returns null and
    // we surface TypeMismatch (no coercion). The value crosses by COPY
    // (box_decimal_copy into a caller-owned Decimal); no Lua-stack pointer escapes.
    if (T == decimal_mod.Decimal) {
        const p = c.luaT_isdecimal(lua.L, idx) orelse return error.TypeMismatch;
        var out: decimal_mod.Decimal = undefined;
        _ = c.box_decimal_copy(&out.raw, p); // host documents dest-on-success
        return out;
    }
    return switch (@typeInfo(T)) {
        .bool => blk: {
            if (lua.typeOf(idx) != c.LUA_TBOOLEAN) return error.TypeMismatch;
            break :blk lua.toBool(idx);
        },
        .float => blk: {
            if (lua.typeOf(idx) != c.LUA_TNUMBER) return error.TypeMismatch;
            break :blk @floatCast(lua.toNumber(idx));
        },
        .int => |info| blk: {
            const tag = lua.typeOf(idx);
            if (tag != c.LUA_TNUMBER and tag != c.LUA_TCDATA) return error.TypeMismatch;
            if (info.signedness == .unsigned) {
                break :blk std.math.cast(T, lua.toUint64(idx)) orelse error.Overflow;
            }
            break :blk std.math.cast(T, lua.toInt64(idx)) orelse error.Overflow;
        },
        .optional => |info| blk: {
            const tag = lua.typeOf(idx);
            if (tag == c.LUA_TNIL or tag == c.LUA_TNONE) break :blk null;
            break :blk try pull(info.child, lua, idx);
        },
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) @compileError("lua.pull: unsupported pointer type " ++ @typeName(T));
            // []const u8 ↔ string, duped into the region so it never aliases
            // Lua-owned memory past the stack value's lifetime.
            if (ptr.child == u8) {
                if (lua.typeOf(idx) != c.LUA_TSTRING) return error.TypeMismatch;
                break :blk try region.allocator().dupe(u8, lua.toLString(idx).?);
            }
            // []T ↔ 1-based array, allocated on the region.
            if (lua.typeOf(idx) != c.LUA_TTABLE) return error.TypeMismatch;
            const tidx = absIndex(lua, idx);
            const arr = try region.allocator().alloc(ptr.child, lua.objLen(tidx));
            for (arr, 0..) |*slot, i| {
                lua.rawGetI(tidx, @intCast(i + 1));
                slot.* = try pull(ptr.child, lua, -1);
                lua.pop(1);
            }
            break :blk arr;
        },
        .@"struct" => |st| blk: {
            if (lua.typeOf(idx) != c.LUA_TTABLE) return error.TypeMismatch;
            const tidx = absIndex(lua, idx);
            var result: T = undefined;
            // Tuple struct ↔ 1-based array; named struct ↔ string-keyed table.
            inline for (st.field_names, st.field_types, 0..) |name, ty, i| {
                if (st.is_tuple) lua.rawGetI(tidx, @intCast(i + 1)) else lua.getField(tidx, name.ptr);
                @field(result, name) = try pull(ty, lua, -1);
                lua.pop(1);
            }
            break :blk result;
        },
        else => @compileError("lua.pull: unsupported type " ++ @typeName(T)),
    };
}

/// Resolve a possibly-relative stack index to an absolute one, so it stays valid
/// across the pushes/pops an aggregate decode performs.
fn absIndex(lua: Lua, idx: c_int) c_int {
    return if (idx < 0) lua.top() + idx + 1 else idx;
}

/// Encode `value` onto the Lua stack. The push copies bytes into
/// Lua-managed memory, so region-backed scratch may be reclaimed after.
fn push(lua: Lua, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    // luaT_pushtuple takes its own ref + installs a __gc unref; the Zig handle's
    // ownership is unchanged here (the caller still deinits it).
    if (T == tuple_mod.Tuple) {
        c.luaT_pushtuple(lua.L, value.raw);
        return;
    }
    // decimal.Decimal pushes a host-side COPY (luaT_pushdecimal); the
    // caller's value is unchanged and box_decimal_t is never memcpy'd.
    if (T == decimal_mod.Decimal) {
        _ = c.luaT_pushdecimal(lua.L, &value.raw);
        return;
    }
    switch (@typeInfo(T)) {
        .bool => lua.pushBool(value),
        .float => lua.pushNumber(@floatCast(value)),
        .int => |info| if (info.signedness == .unsigned)
            lua.pushUint64(@intCast(value))
        else
            lua.pushInt64(@intCast(value)),
        .optional => if (value) |v| try push(lua, v) else lua.pushNil(),
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("lua.push: unsupported pointer type " ++ @typeName(T));
            if (ptr.child == u8) {
                lua.pushLString(value);
            } else {
                lua.newTable();
                for (value, 0..) |elem, i| {
                    try push(lua, elem);
                    lua.rawSetI(-2, @intCast(i + 1));
                }
            }
        },
        .@"struct" => |st| {
            lua.newTable();
            inline for (st.field_names, 0..) |name, i| {
                try push(lua, @field(value, name));
                if (st.is_tuple) lua.rawSetI(-2, @intCast(i + 1)) else lua.setField(-2, name.ptr);
            }
        },
        else => @compileError("lua.push: unsupported type " ++ @typeName(T)),
    }
}
