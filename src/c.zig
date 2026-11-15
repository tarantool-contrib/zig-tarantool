//! Hand-written `extern` declarations for the Tarantool C module ABI subset
//! this SDK uses. Single source of truth for the ABI. Symbols are left
//! undefined and resolved from the host `tarantool` process at `dlopen`.
//!
//! Signatures mirror `module.h` (Tarantool ≥ 3.5, the supported floor). The
//! optional translate-c parity check lives in `c_verify.zig`, gated behind
//! `-Dverify-cabi`, and is
//! never imported by runtime code.

const std = @import("std");
const builtin = @import("builtin");

pub const box_function_ctx_t = opaque {};
pub const box_tuple_t = opaque {};
pub const box_tuple_format_t = opaque {};
pub const box_iterator_t = opaque {};
pub const box_tuple_iterator_t = opaque {};
pub const box_error_t = opaque {};
pub const box_key_def_t = opaque {};
pub const box_txn_savepoint_t = opaque {};
pub const box_latch_t = opaque {};
pub const fiber = opaque {};
pub const fiber_attr = opaque {};
pub const fiber_cond = opaque {};

/// A `va_list` as a C function receives it in a parameter. Where `va_list` is
/// an array type (x86_64 SysV, s390x, 32-bit PowerPC SysV) the parameter decays
/// to a pointer to the first element, so a callback must take a pointer; taking
/// `std.builtin.VaList` by value there reads garbage. On aarch64 outside Apple
/// platforms (AAPCS64) `va_list` is a 32-byte struct, which the C calling
/// convention passes by reference: a pointer to `VaListAapcs64`, read by hand,
/// since Zig 0.17.1 disables `std.builtin.VaList` there under LLVM.
/// Elsewhere `va_list` is a plain pointer or a by-value struct and matches
/// `std.builtin.VaList` as is.
pub const VaListParam = switch (builtin.cpu.arch) {
    .x86_64, .s390x, .powerpc, .powerpcle => if (@typeInfo(std.builtin.VaList) == .pointer)
        std.builtin.VaList
    else
        *std.builtin.VaList,
    .aarch64 => if (builtin.os.tag.isDarwin() or builtin.os.tag == .windows)
        std.builtin.VaList
    else
        *VaListAapcs64,
    else => std.builtin.VaList,
};

/// The AAPCS64 `va_list` ("Procedure Call Standard for the Arm 64-bit
/// Architecture", appendix "Variable argument lists"): the next stacked
/// argument, the ends of the general and the vector register save areas, and
/// the negative offsets from those ends of the next register argument.
pub const VaListAapcs64 = extern struct {
    stack: [*]u8,
    gr_top: [*]u8,
    vr_top: [*]u8,
    gr_offs: c_int,
    vr_offs: c_int,
};

/// Read the next vararg of a `va_list` parameter as a pointer — the per-call
/// context channel of `fiber_start` and `coio_call` trampolines. Inline: it
/// must expand inside the `callconv(.c)` trampoline that owns the va_list.
pub inline fn vaArgPtr(ap: VaListParam) ?*anyopaque {
    if (VaListParam == *VaListAapcs64) {
        // va_arg of an 8-byte integer class argument: from the general
        // register save area while it lasts, else from the stack.
        const offs = ap.gr_offs;
        if (offs < 0 and offs + 8 <= 0) {
            ap.gr_offs = offs + 8;
            const slot: *align(1) const ?*anyopaque = @ptrCast(ap.gr_top - @as(usize, @intCast(-offs)));
            return slot.*;
        }
        if (offs < 0) ap.gr_offs = offs + 8;
        const slot: *align(1) const ?*anyopaque = @ptrCast(ap.stack);
        ap.stack += 8;
        return slot.*;
    }
    if (VaListParam == std.builtin.VaList) {
        var copy = ap;
        return @cVaArg(&copy, ?*anyopaque);
    }
    return @cVaArg(ap, ?*anyopaque);
}

/// Fiber entry point. The closure pointer is delivered through `fiber_start`'s
/// varargs and read via `vaArgPtr` in the trampoline (see `fiber.zig`);
/// `fiber_set_ctx`/`fiber_get_ctx` is NOT used — it does not deliver the pointer
/// inside a `fiber_start`-launched trampoline on this host.
pub const fiber_func = ?*const fn (VaListParam) callconv(.c) c_int;

// ---- stored-proc return ----
pub extern fn box_return_mp(ctx: *box_function_ctx_t, mp: [*c]const u8, mp_end: [*c]const u8) c_int;
pub extern fn box_return_tuple(ctx: *box_function_ctx_t, tuple: *box_tuple_t) c_int;

// ---- schema lookup ----
pub extern fn box_space_id_by_name(name: [*c]const u8, len: u32) u32;
pub extern fn box_index_id_by_name(space_id: u32, name: [*c]const u8, len: u32) u32;

/// Returned by `box_space_id_by_name`/`box_index_id_by_name` on not-found, and
/// the general "nil id" sentinel. Note: `INT32_MAX`, not `UINT32_MAX`.
pub const BOX_ID_NIL: u32 = 0x7fff_ffff;

// ---- CRUD ----
pub extern fn box_insert(space_id: u32, tuple: [*c]const u8, tuple_end: [*c]const u8, result: ?*?*box_tuple_t) c_int;
pub extern fn box_replace(space_id: u32, tuple: [*c]const u8, tuple_end: [*c]const u8, result: ?*?*box_tuple_t) c_int;
pub extern fn box_delete(space_id: u32, index_id: u32, key: [*c]const u8, key_end: [*c]const u8, result: ?*?*box_tuple_t) c_int;
pub extern fn box_update(space_id: u32, index_id: u32, key: [*c]const u8, key_end: [*c]const u8, ops: [*c]const u8, ops_end: [*c]const u8, index_base: c_int, result: ?*?*box_tuple_t) c_int;
pub extern fn box_upsert(space_id: u32, index_id: u32, tuple: [*c]const u8, tuple_end: [*c]const u8, ops: [*c]const u8, ops_end: [*c]const u8, index_base: c_int, result: ?*?*box_tuple_t) c_int;
pub extern fn box_index_get(space_id: u32, index_id: u32, key: [*c]const u8, key_end: [*c]const u8, result: *?*box_tuple_t) c_int;

// ---- index iteration & stats ----
pub extern fn box_index_iterator(space_id: u32, index_id: u32, itype: c_int, key: [*c]const u8, key_end: [*c]const u8) ?*box_iterator_t;
pub extern fn box_iterator_next(iterator: *box_iterator_t, result: *?*box_tuple_t) c_int;
pub extern fn box_iterator_free(iterator: *box_iterator_t) void;
pub extern fn box_index_min(space_id: u32, index_id: u32, key: [*c]const u8, key_end: [*c]const u8, result: *?*box_tuple_t) c_int;
pub extern fn box_index_max(space_id: u32, index_id: u32, key: [*c]const u8, key_end: [*c]const u8, result: *?*box_tuple_t) c_int;
pub extern fn box_index_count(space_id: u32, index_id: u32, itype: c_int, key: [*c]const u8, key_end: [*c]const u8) isize;
pub extern fn box_index_len(space_id: u32, index_id: u32) isize;
pub extern fn box_index_bsize(space_id: u32, index_id: u32) isize;
pub extern fn box_index_random(space_id: u32, index_id: u32, rnd: u32, result: *?*box_tuple_t) c_int;

// ---- tuple access ----
pub extern fn box_tuple_format_default() *box_tuple_format_t;
pub extern fn box_tuple_new(format: *box_tuple_format_t, data: [*c]const u8, end: [*c]const u8) ?*box_tuple_t;
pub extern fn box_tuple_ref(tuple: *box_tuple_t) c_int;
pub extern fn box_tuple_unref(tuple: *box_tuple_t) void;
pub extern fn box_tuple_field_count(tuple: *box_tuple_t) u32;
pub extern fn box_tuple_bsize(tuple: *box_tuple_t) usize;
pub extern fn box_tuple_data(tuple: *box_tuple_t, bsize: *usize) [*c]const u8;
pub extern fn box_tuple_field(tuple: *box_tuple_t, fieldno: u32) [*c]const u8;
pub extern fn box_tuple_iterator(tuple: *box_tuple_t) ?*box_tuple_iterator_t;
pub extern fn box_tuple_iterator_free(it: *box_tuple_iterator_t) void;
pub extern fn box_tuple_position(it: *box_tuple_iterator_t) u32;
pub extern fn box_tuple_rewind(it: *box_tuple_iterator_t) void;
pub extern fn box_tuple_seek(it: *box_tuple_iterator_t, fieldno: u32) [*c]const u8;
pub extern fn box_tuple_next(it: *box_tuple_iterator_t) [*c]const u8;
pub extern fn box_tuple_update(tuple: *box_tuple_t, expr: [*c]const u8, expr_end: [*c]const u8) ?*box_tuple_t;

// ---- key_def + tuple key ops ----
pub extern fn box_key_def_new(fields: [*c]u32, types: [*c]u32, part_count: u32) ?*box_key_def_t;
pub extern fn box_key_def_delete(key_def: *box_key_def_t) void;
pub extern fn box_key_def_extract_key(key_def: *box_key_def_t, tuple: *box_tuple_t, multikey_idx: c_int, key_size: *u32) [*c]u8;
pub extern fn box_tuple_compare(a: *box_tuple_t, b: *box_tuple_t, key_def: *box_key_def_t) c_int;
pub extern fn box_tuple_compare_with_key(a: *box_tuple_t, key_b: [*c]const u8, key_def: *box_key_def_t) c_int;
pub extern fn box_tuple_extract_key(tuple: *box_tuple_t, space_id: u32, index_id: u32, key_size: *u32) [*c]u8;

// ---- decimal (module.h :3375-4003) ----
//
// `box_decimal_t` is a VALUE type — 8 u64 words (64 bytes) sized to hold any
// decimal, meant to be stack-allocated and passed by pointer to the host fns.
// The layout is unspecified and the real data may occupy fewer bytes (the tail
// may be unallocated when the value is host-owned), so:
//   - never read/write `internal[]` directly;
//   - copy a value ONLY via `box_decimal_copy` — never `memcpy`/struct-assign
//     from a host-owned decimal (its tail bytes may be unmapped).
// Our SDK always embeds the full 64-byte storage and initializes it on the
// stack before the first host call, so returning a freshly-initialized stack
// value by value is the single sanctioned struct copy. Consumed by the
// host-bound `decimal.zig` (typed arithmetic type) + `c_verify` parity.
pub const box_decimal_t = extern struct { internal: [8]u64 };

/// Buffer size that holds any `box_decimal_to_string` result (module.h :3421).
pub const BOX_DECIMAL_STRING_BUFFER_SIZE: usize = 128;

// properties
pub extern fn box_decimal_precision(dec: *const box_decimal_t) c_int;
pub extern fn box_decimal_scale(dec: *const box_decimal_t) c_int;
pub extern fn box_decimal_is_int(dec: *const box_decimal_t) bool;
pub extern fn box_decimal_is_neg(dec: *const box_decimal_t) bool;
// constructors
pub extern fn box_decimal_zero(dec: *box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_from_string(dec: *box_decimal_t, str: [*c]const u8) ?*box_decimal_t;
pub extern fn box_decimal_from_double(dec: *box_decimal_t, d: f64) ?*box_decimal_t;
pub extern fn box_decimal_from_int64(dec: *box_decimal_t, num: i64) ?*box_decimal_t;
pub extern fn box_decimal_from_uint64(dec: *box_decimal_t, num: u64) ?*box_decimal_t;
// copy
pub extern fn box_decimal_copy(dest: *box_decimal_t, src: *const box_decimal_t) ?*box_decimal_t;
// conversions
pub extern fn box_decimal_to_string(dec: *const box_decimal_t, buf: [*c]u8) void;
pub extern fn box_decimal_to_int64(dec: *const box_decimal_t, num: *i64) ?*const box_decimal_t;
pub extern fn box_decimal_to_uint64(dec: *const box_decimal_t, num: *u64) ?*const box_decimal_t;
// rounding (host mutates `dec` in place)
pub extern fn box_decimal_round(dec: *box_decimal_t, scale: c_int) ?*box_decimal_t;
pub extern fn box_decimal_floor(dec: *box_decimal_t, scale: c_int) ?*box_decimal_t;
pub extern fn box_decimal_trim(dec: *box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_rescale(dec: *box_decimal_t, scale: c_int) ?*box_decimal_t;
// compare + arithmetic
pub extern fn box_decimal_compare(lhs: *const box_decimal_t, rhs: *const box_decimal_t) c_int;
pub extern fn box_decimal_abs(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_minus(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_add(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_sub(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_mul(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_div(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_remainder(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
// math
pub extern fn box_decimal_log10(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_ln(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_pow(res: *box_decimal_t, lhs: *const box_decimal_t, rhs: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_exp(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
pub extern fn box_decimal_sqrt(res: *box_decimal_t, dec: *const box_decimal_t) ?*box_decimal_t;
// msgpack codec
pub extern fn box_decimal_mp_sizeof(dec: *const box_decimal_t) u32;
pub extern fn box_decimal_mp_encode(dec: *const box_decimal_t, data: [*c]u8) [*c]u8;
pub extern fn box_decimal_mp_decode(dec: *box_decimal_t, data: *[*c]const u8) ?*box_decimal_t;
pub extern fn box_decimal_mp_decode_data(dec: *box_decimal_t, data: *[*c]const u8, size: u32) ?*box_decimal_t;

// ---- region (per-fiber scratch arena) ----
pub extern fn box_region_used() usize;
pub extern fn box_region_alloc(size: usize) ?*anyopaque;
pub extern fn box_region_aligned_alloc(size: usize, alignment: usize) ?*anyopaque;
pub extern fn box_region_truncate(size: usize) void;

// ---- errors ----
pub extern fn box_error_set(file: [*c]const u8, line: c_uint, code: u32, format: [*c]const u8, ...) c_int;
pub extern fn box_error_last() ?*box_error_t;
pub extern fn box_error_code(err: *box_error_t) u32;
pub extern fn box_error_message(err: *box_error_t) [*c]const u8;
pub extern fn box_error_type(err: *box_error_t) [*c]const u8;

// ---- transactions ----
pub extern fn box_txn() bool;
pub extern fn box_txn_begin() c_int;
pub extern fn box_txn_commit() c_int;
pub extern fn box_txn_rollback() c_int;
pub extern fn box_txn_id() i64;
pub extern fn box_txn_savepoint() ?*box_txn_savepoint_t;
pub extern fn box_txn_rollback_to_savepoint(savepoint: *box_txn_savepoint_t) c_int;
pub extern fn box_txn_isolation() c_int;
pub extern fn box_txn_set_isolation(level: u32) c_int;
pub extern fn box_txn_set_timeout(timeout: f64) c_int;
pub extern fn box_txn_make_sync() void;
pub extern fn box_txn_alloc(size: usize) ?*anyopaque;

// ---- sequences ----
pub extern fn box_sequence_next(seq_id: u32, result: *i64) c_int;
pub extern fn box_sequence_current(seq_id: u32, result: *i64) c_int;
pub extern fn box_sequence_set(seq_id: u32, value: i64) c_int;
pub extern fn box_sequence_reset(seq_id: u32) c_int;

// ---- instance introspection & maintenance ----
pub const box_slab_info_type = enum(c_int) {
    items_size = 0,
    items_used = 1,
    arena_size = 2,
    arena_used = 3,
    quota_size = 4,
    quota_used = 5,
};
pub extern fn box_status() [*c]const u8;
pub extern fn box_is_ro() bool;
pub extern fn box_wait_ro(ro: bool, timeout: f64) c_int;
pub extern fn box_ro_reason() [*c]const u8;
pub extern fn box_schema_version() u64;
pub extern fn box_info_lsn() i64;
pub extern fn box_slab_info(slab_info_type: box_slab_info_type) u64;
pub extern fn box_truncate(space_id: u32) c_int;

// ---- on_shutdown trigger ----
//
// The ONLY trigger-registration entry point in the public C module ABI
// (module.h:501-503). `new_handler == NULL` finds and deletes the trigger whose
// function pointer equals `old_handler`; both NULL is an error. Failure returns
// -1 and sets errno (EINVAL/ENOMEM), NOT a box diag (module.h:484-499). The
// handler receives the `arg` void* it was registered with; every other trigger
// surface (txn on_commit/on_rollback, space on_replace) goes through the Lua
// bridge below (src/trigger.zig) — the header exposes no native form of them.
pub extern fn box_on_shutdown(arg: ?*anyopaque, new_handler: ?*const fn (?*anyopaque) callconv(.c) c_int, old_handler: ?*const fn (?*anyopaque) callconv(.c) c_int) c_int;

// ---- fibers ----
pub extern fn fiber_self() ?*fiber;
pub extern fn fiber_new(name: [*:0]const u8, f: fiber_func) ?*fiber;
pub extern fn fiber_start(callee: *fiber, ...) void;
pub extern fn fiber_set_ctx(f: ?*fiber, ctx: ?*anyopaque) void;
pub extern fn fiber_get_ctx(f: ?*fiber) ?*anyopaque;
pub extern fn fiber_set_joinable(f: ?*fiber, yesno: bool) void;
pub extern fn fiber_join(f: *fiber) c_int;
pub extern fn fiber_join_timeout(f: *fiber, timeout: f64) c_int;
pub extern fn fiber_yield() void;
pub extern fn fiber_sleep(s: f64) void;
pub extern fn fiber_wakeup(f: *fiber) void;
pub extern fn fiber_cancel(f: *fiber) void;
pub extern fn fiber_is_cancelled() bool;
pub extern fn fiber_reschedule() void;
pub extern fn fiber_id(f: *const fiber) u64;
pub extern fn fiber_clock() f64;
pub extern fn fiber_attr_new() ?*fiber_attr;
pub extern fn fiber_attr_delete(attr: *fiber_attr) void;
pub extern fn fiber_attr_setstacksize(attr: *fiber_attr, stack_size: usize) c_int;
pub extern fn fiber_attr_getstacksize(attr: *fiber_attr) usize;
pub extern fn fiber_new_ex(name: [*:0]const u8, attr: ?*const fiber_attr, f: fiber_func) ?*fiber;
pub extern fn fiber_name(f: ?*const fiber) [*:0]const u8;
pub extern fn fiber_set_name_n(f: ?*fiber, name: [*]const u8, len: u32) void;
pub extern fn fiber_csw(f: ?*const fiber) u64;
pub extern fn fiber_find(fid: u64) ?*fiber;
pub extern fn fiber_time() f64;
pub extern fn fiber_time64() i64;
pub extern fn fiber_clock64() i64;

// ---- fiber cond ----
pub extern fn fiber_cond_new() ?*fiber_cond;
pub extern fn fiber_cond_delete(cond: *fiber_cond) void;
pub extern fn fiber_cond_signal(cond: *fiber_cond) void;
pub extern fn fiber_cond_broadcast(cond: *fiber_cond) void;
pub extern fn fiber_cond_wait_timeout(cond: *fiber_cond, timeout: f64) c_int;
pub extern fn fiber_cond_wait(cond: *fiber_cond) c_int;

// ---- latch (fiber mutex) ----
pub extern fn box_latch_new() ?*box_latch_t;
pub extern fn box_latch_delete(latch: *box_latch_t) void;
pub extern fn box_latch_lock(latch: *box_latch_t) void;
pub extern fn box_latch_trylock(latch: *box_latch_t) c_int;
pub extern fn box_latch_unlock(latch: *box_latch_t) void;

// ---- clock (host wall/CPU clocks) ----
// The `*64` variants return `int64_t` (signed) — the header says "returns the
// time as 64 bit signed integer", matching fiber_time64/fiber_clock64 above.
// Doubles are seconds; `*64` are nanoseconds (Tarantool clock contract).
pub extern fn clock_realtime() f64;
pub extern fn clock_monotonic() f64;
pub extern fn clock_process() f64;
pub extern fn clock_thread() f64;
pub extern fn clock_realtime64() i64;
pub extern fn clock_monotonic64() i64;
pub extern fn clock_process64() i64;
pub extern fn clock_thread64() i64;

// ---- coio (fd readiness) ----
pub const COIO_READ: c_int = 0x1;
pub const COIO_WRITE: c_int = 0x2;
pub extern fn coio_wait(fd: c_int, event: c_int, timeout: f64) c_int;
pub extern fn coio_close(fd: c_int) c_int;

/// Callback for `coio_call`: runs OFF the tx thread on a worker pthread — it
/// must NOT touch box, the region, fibers, or the Lua state. Its single context
/// pointer travels through `coio_call`'s varargs and is read via `vaArgPtr`
/// (`src/coio.zig`), NEVER a side-channel — the ctx-pointer trampoline gotcha
/// carried over from `fiber_func` (`c.zig:24`). Returns `ssize_t`.
pub const coio_call_func = ?*const fn (VaListParam) callconv(.c) isize;

/// Run `func` on the coio worker-thread pool, yielding the calling fiber until
/// it completes; extra varargs are forwarded to `func`'s `va_list` (module.h
/// :1147-1148). `-1` with `errno = ENOMEM` means the task was never created;
/// otherwise the return is `func`'s own (errno preserved) — the SDK
/// disambiguates via a trampoline ran-flag, not errno (`src/coio.zig`).
pub extern fn coio_call(func: coio_call_func, ...) isize;

/// Fiber-friendly `getaddrinfo(3)` (module.h :1166-1169). `0` on success (free
/// `res` with `std.c.freeaddrinfo`), `-1` on error with the box diag set — the
/// return value is NOT `getaddrinfo(3)`-compatible. `struct addrinfo` is the
/// libc type `std.c.addrinfo` (libc, not Tarantool ABI, so verify-cabi's
/// `assertSame` compares only param count + varargs).
pub extern fn coio_getaddrinfo(host: [*c]const u8, port: [*c]const u8, hints: ?*const std.c.addrinfo, res: *?*std.c.addrinfo, timeout: f64) c_int;
// NOTE (live-verified): `coio_getaddrinfo` does NOT set diag `ER_TIMEOUT`
// on timeout. This host sets `ER_SYSTEM` (115) for BOTH timeout and resolver
// failure; only the error TYPE distinguishes them (`"TimedOut"` vs
// `"SystemError"`). `src/coio.zig`'s `getAddrInfo` therefore branches on the
// error-class name, not the code — so no `ER_TIMEOUT` constant is pinned here.

// ---- say (logging) ----
//
// The host's own log sink (`box.cfg{log=...}`), reached through two extern
// VARIABLES — a first for this file, which so far only bound functions. The
// `say*()` macros in module.h wrap a `static inline` level check plus a call
// through the `_say` fn pointer; the check is reimplemented as `say.enabled`
// and the pointer is called directly by `src/say.zig`.

/// The `_say` sink signature: `(level, file, line, error, format, ...)`. `level`
/// is an `enum say_level` value; `error` may be NULL; `format` is a printf
/// format string (we always pass a literal `"%s"` — src/say.zig).
pub const sayfunc_t = ?*const fn (c_int, [*c]const u8, c_int, [*c]const u8, [*c]const u8, ...) callconv(.c) void;

/// The host's current log sink. This is the first extern VARIABLE bound in
/// c.zig; the host SWAPS it on log rotation, so src/say.zig reads it per call
/// and never caches the pointer. `CFORMAT(printf, 5, 6)` in module.h is a
/// checker attribute with no ABI effect.
pub extern var _say: sayfunc_t;

/// The host's current log-level threshold. `say_log_level_is_enabled(level)` is
/// `static inline` in module.h (`level <= log_level`); it is reimplemented as
/// `say.enabled` reading this variable per call.
pub extern var log_level: c_int;

/// MT-safe `strerror`, used to build the `error` argument of `_say` for the
/// syserror path (feeds `say.sysError`; the host appends `": <strerror>"`).
pub extern fn _say_strerror(errnum: c_int) [*c]const u8;

/// Generic client error code (ER_PROC_C); used as the default for Zig errors
/// surfaced from a stored proc.
pub const ER_PROC_C: u32 = 102;

// ---- lua (authoring Lua C modules) ----
//
// LuaJIT + Tarantool's `luaT_*`/`luaL_*` extensions, exported by the host
// `tarantool` binary and resolved at dlopen like the `box_*` symbols above.
// Declarations mirror the vendored headers under `vendor/tarantool/`
// (lua.h/lauxlib.h) and `module.h` (the int64/cdata + tuple extensions); the
// `assertSame` parity check lives in `c_verify.zig`.

pub const lua_State = opaque {};

/// A Lua-callable C function: receives the state, returns the number of values
/// it left on the stack. The exact ABI a `lua.zig` export synthesizes.
pub const lua_CFunction = ?*const fn (?*lua_State) callconv(.c) c_int;

/// One name→function entry of a module registration array. `luaL_register`
/// consumes a NUL-terminated (`.name == null`) array of these.
pub const luaL_Reg = extern struct { name: [*c]const u8, func: lua_CFunction };

// Lua value type tags (lua.h); the subset `lua.zig`'s `pull` dispatches on.
pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
/// LuaJIT extension tag for cdata (`LAST_TT+2`); `lua_type` returns it for the
/// int64/uint64 cdata that `luaL_to/pushint64` produce. Not in the public lua.h,
/// so it has no `c_verify` parity entry — the value is fixed by LuaJIT's ABI.
pub const LUA_TCDATA: c_int = 10;

// LuaJIT pseudo-indices (lua.h:37/:39). The registry holds `luaL_ref` anchors
// (trigger closure identity for deregistration); the globals index reaches
// `box.*`. Both are comptime-pinned against the header in `c_verify.zig`.
// `lua_upvalueindex(i)` (lua.h:40, `LUA_GLOBALSINDEX-(i)`) is a macro, so it is
// reimplemented in src/trigger.zig rather than bound here (same stance as
// say.enabled reimplementing the inline level check).
pub const LUA_REGISTRYINDEX: c_int = -10000;
pub const LUA_GLOBALSINDEX: c_int = -10002;

// stack manipulation + type inspection
pub extern fn lua_gettop(L: *lua_State) c_int;
pub extern fn lua_settop(L: *lua_State, idx: c_int) void;
pub extern fn lua_type(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_pushvalue(L: *lua_State, idx: c_int) void;

// push (C -> stack)
pub extern fn lua_pushnil(L: *lua_State) void;
pub extern fn lua_pushboolean(L: *lua_State, b: c_int) void;
pub extern fn lua_pushnumber(L: *lua_State, n: f64) void;
pub extern fn lua_pushlstring(L: *lua_State, s: [*c]const u8, l: usize) void;
pub extern fn lua_pushcclosure(L: *lua_State, fn_: lua_CFunction, n: c_int) void;
/// Push `p` as a light userdata (a raw pointer value, no metatable/`__gc`).
/// The trigger bridge rides the Zig `context` pointer through here as a closure
/// upvalue; the trampoline reads it back with `lua_touserdata` (lua.h:173).
pub extern fn lua_pushlightuserdata(L: *lua_State, p: ?*anyopaque) void;

// access (stack -> C); non-raising readers
pub extern fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_tonumber(L: *lua_State, idx: c_int) f64;
pub extern fn lua_tolstring(L: *lua_State, idx: c_int, len: *usize) [*c]const u8;
/// The value at `idx` as a raw pointer (light userdata → its pointer; full
/// userdata → its block; otherwise NULL). Non-raising (lua.h:155).
pub extern fn lua_touserdata(L: *lua_State, idx: c_int) ?*anyopaque;

// tables
pub extern fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
pub extern fn lua_rawgeti(L: *lua_State, idx: c_int, n: c_int) void;
pub extern fn lua_rawseti(L: *lua_State, idx: c_int, n: c_int) void;
pub extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*c]const u8) void;
pub extern fn lua_setfield(L: *lua_State, idx: c_int, k: [*c]const u8) void;
pub extern fn lua_next(L: *lua_State, idx: c_int) c_int;
pub extern fn lua_objlen(L: *lua_State, idx: c_int) usize;

// lauxlib: module registration + the terminal error raise (longjmp; varargs)
pub extern fn luaL_register(L: *lua_State, libname: [*c]const u8, l: [*c]const luaL_Reg) void;
pub extern fn luaL_error(L: *lua_State, fmt: [*c]const u8, ...) c_int;
/// Pop the value on top of the stack and store it in the table at `t`
/// (typically `LUA_REGISTRYINDEX`), returning an integer key that retrieves it
/// with `lua_rawgeti(t, ref)`. The trigger bridge anchors an on_replace closure
/// here so its identity survives for deregistration (lauxlib.h:62).
pub extern fn luaL_ref(L: *lua_State, t: c_int) c_int;
/// Release a `luaL_ref` anchor: remove the reference `ref` from table `t` so
/// its value can be collected (lauxlib.h:63).
pub extern fn luaL_unref(L: *lua_State, t: c_int, ref: c_int) void;

// Tarantool int64/uint64 cdata helpers (module.h). `to*` are non-raising.
pub extern fn luaL_pushint64(L: *lua_State, val: i64) void;
pub extern fn luaL_pushuint64(L: *lua_State, val: u64) void;
pub extern fn luaL_toint64(L: *lua_State, idx: c_int) i64;
pub extern fn luaL_touint64(L: *lua_State, idx: c_int) u64;

// Tarantool tuple bridge (module.h). `luaT_istuple` is the non-raising form
// (returns null on a non-tuple); `luaT_pushtuple` takes its own host reference
// and installs a `__gc` unref.
pub extern fn luaT_istuple(L: *lua_State, idx: c_int) ?*box_tuple_t;
pub extern fn luaT_pushtuple(L: *lua_State, tuple: *box_tuple_t) void;

// Tarantool decimal bridge (module.h:4013-4030). `luaT_pushdecimal` pushes a
// COPY of `dec`; `luaT_isdecimal` is the non-raising check-and-get
// (returns the pointer on a decimal cdata, null otherwise). `luaT_newdecimal`
// is bound for family completeness even though the lua.zig bridge only calls
// push/is.
pub extern fn luaT_newdecimal(L: *lua_State) *box_decimal_t;
pub extern fn luaT_pushdecimal(L: *lua_State, dec: *const box_decimal_t) *box_decimal_t;
pub extern fn luaT_isdecimal(L: *lua_State, idx: c_int) ?*box_decimal_t;

// calling INTO Lua (trigger registration, Lua-bridge helpers). `luaT_state`
// returns the global Lua state Tarantool runs on (module.h:1413-1414); a
// C-proc fiber may borrow it for a balanced, non-yielding push/call sequence.
// `luaT_call` is `lua_call` with proper Tarantool error support (module.h:
// 1390-1391): on a Lua error it returns nonzero and sets the fiber diag instead
// of longjmp-ing, so the caller maps nonzero → error and reads the box diag.
// (The sanctioned DDL/SQL pattern is `luaT_dostring`/`luaT_call` on
// `box.schema.*`/`box.execute` from user code — module.h:1400-1401; that extern
// is deliberately deferred with its helper and NOT bound here.)
pub extern fn luaT_state() ?*lua_State;
pub extern fn luaT_call(L: *lua_State, nargs: c_int, nreturns: c_int) c_int;
