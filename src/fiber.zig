//! Fibers: a host-bound `Fiber(Result)` handle and spawn helpers over
//! Tarantool's `fiber_*` C functions (this module is legitimately
//! Tarantool-bound and imports `c.zig`, like `seq.zig`/`txn.zig`).
//!
//! `spawn` is the sole constructor of a joinable `Fiber(Result)`: it
//! always marks the fiber joinable before returning, so `join` — reachable only
//! through a handle — can never hit the host "not joinable" panic.
//! `spawnDetached` returns no handle, never sets joinable, and requires a
//! `void`-returning body. Both route the user body through a per-spawn,
//! monomorphized `Closure.tramp`; the closure pointer reaches it through
//! `fiber_start`'s varargs, read via `c.vaArgPtr` (the trampoline always
//! returns 0; the result travels through a typed slot, never the fiber's int).
//!
//! Why varargs and not `fiber_set_ctx`/`fiber_get_ctx`: on Tarantool
//! 3.8, `fiber_get_ctx(NULL)` inside a `fiber_start`-launched
//! trampoline does not return the pointer set by `fiber_set_ctx` (verified live;
//! a probe read the wrong pointer). `fiber_start(callee, ...)` → `c.vaArgPtr` is the
//! channel that works.
//!
//! `fiber_join_timeout` is deliberately NOT wrapped: on timeout it sets
//! `FIBER_JOIN_BEEN_INVOKED` and never clears it, so any later join panics the
//! host ("join of a joined fiber detected") and the fiber leaks unreapably.
//! Core exposes only the always-correct infinite `join`.

const std = @import("std");
const c = @import("c.zig");

const c_allocator = std.heap.c_allocator;

/// Bounded MPMC channel `Channel(T)` over `cond.Cond` + an allocator, re-exported
/// so the public API is `fiber.Channel(T)`. See `channel.zig`.
pub const Channel = @import("channel.zig").Channel;

pub const Error = error{
    /// `fiber_new` returned NULL, or a closure allocation failed (out of
    /// memory) — no silent fallback.
    FiberOp,
};

/// The (unwrapped) return type of `func` — the value the fiber body produces.
fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// A handle to a spawned, joinable fiber producing a `Result`.
///
/// Constructed only by `spawn`. Single-consumer: join the fiber to
/// completion exactly once and do not reuse the handle afterward. Double-join
/// is caller error and is deliberately NOT runtime-guarded (the guard would
/// read freed memory), exactly as `std.Thread.join`.
pub fn Fiber(comptime Result: type) type {
    return struct {
        const Self = @This();

        handle: *c.fiber,
        result: *Result,

        /// Block until the fiber finishes and return its result (read from the
        /// typed slot, not the fiber's int return). Frees the result slot.
        /// The handle must not be reused after this.
        pub fn join(self: Self) Result {
            _ = c.fiber_join(self.handle);
            const r = self.result.*;
            c_allocator.destroy(self.result);
            return r;
        }

        /// Request cooperative cancellation of the fiber.
        pub fn cancel(self: Self) void {
            c.fiber_cancel(self.handle);
        }

        /// Wake a sleeping/yielded fiber.
        pub fn wakeup(self: Self) void {
            c.fiber_wakeup(self.handle);
        }

        /// The fiber's numeric id.
        pub fn id(self: Self) u64 {
            return c.fiber_id(self.handle);
        }

        /// The fiber's name (NUL-terminated, stable for the call, not retained
        /// across yields).
        pub fn name(self: Self) [:0]const u8 {
            return std.mem.span(c.fiber_name(self.handle));
        }

        /// Set the fiber's name (the host copies `n`; ownership is established
        /// via this handle).
        pub fn setName(self: Self, n: []const u8) void {
            c.fiber_set_name_n(self.handle, n.ptr, @intCast(n.len));
        }

        /// The fiber's context-switch count.
        pub fn csw(self: Self) u64 {
            return c.fiber_csw(self.handle);
        }
    };
}

/// A borrowed, read-only view of a fiber located by `find`: exposes
/// id/name/csw and nothing that mutates lifecycle (no join/cancel/wakeup/setName)
/// and owns no result slot. It must NEVER be joined — it is not a `Fiber(Result)`
/// and holds no slot to read or free.
pub const FiberInfo = struct {
    handle: *c.fiber,

    /// The fiber's numeric id.
    pub fn id(self: FiberInfo) u64 {
        return c.fiber_id(self.handle);
    }

    /// The fiber's name (NUL-terminated, stable for the call).
    pub fn name(self: FiberInfo) [:0]const u8 {
        return std.mem.span(c.fiber_name(self.handle));
    }

    /// The fiber's context-switch count.
    pub fn csw(self: FiberInfo) u64 {
        return c.fiber_csw(self.handle);
    }
};

/// Look up a live fiber by id, returning a borrowed read-only `FiberInfo` or
/// `null` if no such fiber exists. A NULL `fiber_find` means absence, NOT an
/// error.
pub fn find(fid: u64) ?FiberInfo {
    const f = c.fiber_find(fid) orelse return null;
    return .{ .handle = f };
}

/// The shared spawn path behind `spawn` and `spawnWithAttr`: the only
/// place the closure/trampoline/joinable/result-slot machinery lives. The single
/// fiber-creation call branches on `attr_opt`: a NULL attr goes through plain
/// `fiber_new` (byte-identical to core `spawn` semantics), a non-NULL attr
/// through `fiber_new_ex` for a custom stack size — one body, only
/// re-parameterized by `attr_opt`. NOTE: this host's `fiber_new_ex` (at
/// `fiber_new_ex+76`) dereferences the attr unconditionally — module.h documents
/// a NULL attr as allowed, but this build segfaults on it — so the NULL path MUST
/// use `fiber_new`, never `fiber_new_ex(name, NULL, ...)`.
fn spawnImpl(name: [:0]const u8, attr_opt: ?*const c.fiber_attr, comptime func: anytype, args: anytype) Error!Fiber(ReturnType(func)) {
    const Result = ReturnType(func);

    const Closure = struct {
        args: @TypeOf(args),
        result_ptr: *Result,

        fn tramp(ap: c.VaListParam) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(c.vaArgPtr(ap).?));
            self.result_ptr.* = @call(.auto, func, self.args);
            c_allocator.destroy(self);
            return 0;
        }
    };

    // OOM from the closure allocations surfaces through `Error.FiberOp`, the
    // same channel as a NULL `fiber_new_ex` — no silent fallback.
    const result = c_allocator.create(Result) catch return Error.FiberOp;
    errdefer c_allocator.destroy(result);

    const cl = c_allocator.create(Closure) catch return Error.FiberOp;
    errdefer c_allocator.destroy(cl);
    cl.* = .{ .args = args, .result_ptr = result };

    // Both creation calls copy the name, so the temporary `name` is safe.
    // The NULL-attr path uses plain `fiber_new` (this host's `fiber_new_ex`
    // NULL-derefs a NULL attr); a real attr uses `fiber_new_ex`.
    const f = (if (attr_opt) |a|
        c.fiber_new_ex(name.ptr, a, &Closure.tramp)
    else
        c.fiber_new(name.ptr, &Closure.tramp)) orelse return Error.FiberOp;
    c.fiber_set_joinable(f, true);
    // The closure pointer is passed through `fiber_start`'s varargs and read by
    // the trampoline via `c.vaArgPtr` — the documented per-fiber argument channel.
    // (`fiber_get_ctx(NULL)` is unreliable inside the trampoline here.)
    c.fiber_start(f, cl);

    return .{ .handle = f, .result = result };
}

/// Spawn a joinable fiber running `func(args...)` and return its handle.
///
/// Always sets the fiber joinable before returning, so the returned
/// handle's `join` can never hit the host "not joinable" panic. A NULL
/// `fiber_new` surfaces as `Error.FiberOp` — no silent fallback. Note
/// `fiber_start` runs the new fiber up to its first yield/completion, so `spawn`
/// is itself a yield point.
pub fn spawn(name: [:0]const u8, comptime func: anytype, args: anytype) Error!Fiber(ReturnType(func)) {
    return spawnImpl(name, null, func, args);
}

/// A persistent, reusable handle to a `fiber_attr` — the fiber-creation
/// attributes (notably stack size) used by `spawnWithAttr`.
///
/// Owns exactly one `*c.fiber_attr`: `init` creates it, `deinit` frees it once.
/// A single `FiberAttr` is BORROWED, not consumed, by `spawnWithAttr`, so
/// it may drive many spawns and outlive every fiber it created.
pub const FiberAttr = struct {
    raw: *c.fiber_attr,

    /// Allocate a fresh `fiber_attr` with host defaults. A NULL
    /// `fiber_attr_new` surfaces as `Error.FiberOp` — no silent fallback.
    pub fn init() Error!FiberAttr {
        const raw = c.fiber_attr_new() orelse return Error.FiberOp;
        return .{ .raw = raw };
    }

    /// Free the underlying `fiber_attr` (exactly once). Precondition: no
    /// `spawnWithAttr` is mid-flight against this attr — trivially held in
    /// single-threaded cooperative code, where no other fiber runs between the
    /// `spawnWithAttr` return and this call.
    pub fn deinit(self: FiberAttr) void {
        c.fiber_attr_delete(self.raw);
    }

    /// Set the stack size (in bytes) for fibers created with this attr. A
    /// non-zero return surfaces as `Error.FiberOp` — no silent fallback.
    pub fn setStackSize(self: FiberAttr, bytes: usize) Error!void {
        if (c.fiber_attr_setstacksize(self.raw, bytes) != 0) return Error.FiberOp;
    }

    /// The stack size (in bytes) currently configured on this attr.
    pub fn getStackSize(self: FiberAttr) usize {
        return c.fiber_attr_getstacksize(self.raw);
    }
};

/// Spawn a joinable fiber running `func(args...)` with the creation attributes
/// in `attr` (notably a custom, typically larger, stack size), returning its
/// handle.
///
/// Identical to `spawn` (same shared `spawnImpl`, same joinable
/// guarantee and `Error.FiberOp` failure channel) except the fiber is created
/// via `fiber_new_ex` with `attr`. The attr is BORROWED, not consumed: it is
/// reusable across many `spawnWithAttr` calls and the created fiber retains no
/// pointer into it, so the caller still owns and must `deinit` it.
pub fn spawnWithAttr(name: [:0]const u8, attr: FiberAttr, comptime func: anytype, args: anytype) Error!Fiber(ReturnType(func)) {
    return spawnImpl(name, attr.raw, func, args);
}

/// Spawn a detached fiber running `func(args...)`; no handle is returned and
/// the fiber is never made joinable.
///
/// `func` must return `void` (compile error otherwise): a detached fiber
/// has no joiner, so a returned value would be silently dropped. The closure
/// (holding only `args`) is freed by the trampoline after the body returns.
pub fn spawnDetached(name: [:0]const u8, comptime func: anytype, args: anytype) Error!void {
    if (ReturnType(func) != void) @compileError("spawnDetached func must return void");

    const Closure = struct {
        args: @TypeOf(args),

        fn tramp(ap: c.VaListParam) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(c.vaArgPtr(ap).?));
            _ = @call(.auto, func, self.args);
            c_allocator.destroy(self);
            return 0;
        }
    };

    // OOM surfaces through `Error.FiberOp`, as in `spawn`.
    const cl = c_allocator.create(Closure) catch return Error.FiberOp;
    errdefer c_allocator.destroy(cl);
    cl.* = .{ .args = args };

    // fiber_new copies the name, so the temporary `name` is safe.
    const f = c.fiber_new(name.ptr, &Closure.tramp) orelse return Error.FiberOp;
    // The closure pointer is passed through `fiber_start`'s varargs and read by
    // the trampoline via `c.vaArgPtr` — the documented per-fiber argument channel.
    // (`fiber_get_ctx(NULL)` is unreliable inside the trampoline here.)
    c.fiber_start(f, cl);
}

/// Sleep the current fiber for `s` seconds (a yield point).
pub fn sleep(s: f64) void {
    c.fiber_sleep(s);
}

/// Yield the current fiber, rescheduling it after pending ready fibers.
pub fn yield() void {
    c.fiber_yield();
}

/// Reschedule the current fiber (cooperative yield to the scheduler).
pub fn reschedule() void {
    c.fiber_reschedule();
}

/// Whether the current fiber has a pending cancellation request.
pub fn isCancelled() bool {
    return c.fiber_is_cancelled();
}

/// The current fiber's name (NUL-terminated; `fiber_name(NULL)` => current).
pub fn currentName() [:0]const u8 {
    return std.mem.span(c.fiber_name(null));
}

/// Set the current fiber's name (the host copies `n`; `NULL` fiber => current).
pub fn setCurrentName(n: []const u8) void {
    c.fiber_set_name_n(null, n.ptr, @intCast(n.len));
}

/// The current fiber's context-switch count (`fiber_csw(NULL)` => current).
pub fn currentCsw() u64 {
    return c.fiber_csw(null);
}

/// Wall-clock time in seconds (cached per event-loop iteration).
pub fn time() f64 {
    return c.fiber_time();
}

/// Wall-clock time in microseconds (cached per event-loop iteration).
pub fn time64() i64 {
    return c.fiber_time64();
}

/// Monotonic time in seconds (cached per event-loop iteration).
pub fn clock() f64 {
    return c.fiber_clock();
}

/// Monotonic time in microseconds (cached per event-loop iteration).
pub fn clock64() i64 {
    return c.fiber_clock64();
}

test {
    // Compile-smoke only: fibers need a live host, so this references the
    // public surface at comptime without running any of it.
    _ = Fiber(void);
    _ = Fiber(u32);
    _ = &spawn;
    _ = &spawnDetached;
    _ = &sleep;
    _ = &yield;
    _ = &reschedule;
    _ = &isCancelled;

    // Introspection / current-fiber / clock surface.
    _ = FiberInfo;
    _ = FiberAttr;
    _ = &FiberAttr.init;
    _ = &FiberAttr.deinit;
    _ = &FiberAttr.setStackSize;
    _ = &FiberAttr.getStackSize;
    _ = &find;
    _ = &currentName;
    _ = &setCurrentName;
    _ = &currentCsw;
    _ = &time;
    _ = &time64;
    _ = &clock;
    _ = &clock64;
    // `Fiber(u32)`'s introspection methods.
    _ = &Fiber(u32).name;
    _ = &Fiber(u32).setName;
    _ = &Fiber(u32).csw;

    // Force monomorphization of the `spawnWithAttr` generic body with a concrete
    // func so its body is actually type-checked (`_ = &spawnWithAttr` alone does
    // NOT compile the generic body).
    const Probe = struct {
        fn body(x: u32) u32 {
            return x +% 1;
        }
    };
    _ = &struct {
        fn force(attr: FiberAttr) Error!Fiber(u32) {
            return spawnWithAttr("probe", attr, Probe.body, .{@as(u32, 7)});
        }
    }.force;
}
