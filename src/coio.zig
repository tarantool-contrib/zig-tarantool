//! Cooperative fd readiness: host-bound free functions over Tarantool's
//! `coio_wait`/`coio_close` C functions (this module is legitimately
//! Tarantool-bound and imports `c.zig`, like `fiber.zig`/`cond.zig`).
//!
//! Unlike `Cond`/`Sequence`, coio owns NO host resource: there is no handle
//! and no `deinit`. `wait` and `close` are free functions — the
//! `fd` is caller-owned. The caller MUST pass a non-blocking fd: this is
//! a documented precondition, NOT enforced — coio performs no implicit
//! `fcntl`.
//!
//! Every non-success host path becomes a Zig error — no silent fallback. A `0`
//! return from `coio_wait` is `Error.Timeout`; a negative is `Error.CoioOp`;
//! only a `>0` return yields a (non-empty) `Events`. `close` maps any
//! non-zero return to `Error.CoioOp`.
//!
//! Two further host paths run blocking work OFF the tx thread. `call` offloads
//! a callback onto Tarantool's coio worker-thread pool and yields the calling
//! fiber until it completes — the sanctioned escape hatch for file IO, DNS, or
//! heavy syscalls that would otherwise stall the event loop. The callback runs
//! on a plain worker pthread: it MUST NOT touch box, the region, fibers, or the
//! Lua state (this is the #1 misuse of coio_call — say so loudly). `getAddrInfo`
//! is the fiber-friendly `getaddrinfo(3)` built on the same offload inside the
//! host, adding the timeout raw `getaddrinfo` cannot express.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

/// A host `coio_*` call failed (`coio_wait` returned negative, or `coio_close`
/// returned non-zero), or `coio_wait` timed out.
pub const Error = error{
    /// A host `coio_*` call reported failure — no silent fallback.
    CoioOp,
    /// `wait` ran out of time before the fd became ready (a `0` host return).
    Timeout,
};

/// A readiness event mask, bit-compatible with the host `COIO_READ`/
/// `COIO_WRITE` constants. Backed by `c_int` so `toInt`/`fromInt` are pure
/// `@bitCast` round-trips: `read` is bit 0 (`COIO_READ`), `write` is bit
/// 1 (`COIO_WRITE`), and the remaining bits are reserved padding.
pub const Events = packed struct(c_int) {
    read: bool = false,
    write: bool = false,
    _pad: u30 = 0,

    /// The host `c_int` mask for this event set — a pure `@bitCast`.
    pub fn toInt(self: Events) c_int {
        return @bitCast(self);
    }

    /// Decode a host `c_int` mask — a pure `@bitCast`. Faithful over the
    /// full `c_int` because `coio_wait`'s `>0` return carries only the
    /// `COIO_READ|COIO_WRITE` bits, so `_pad` reads back zero.
    pub fn fromInt(v: c_int) Events {
        return @bitCast(v);
    }

    /// True when neither `read` nor `write` is set.
    pub fn isEmpty(self: Events) bool {
        return !self.read and !self.write;
    }
};

/// Wait up to `timeout` seconds for `fd` to become ready for any of `events`
/// (a yield point — its interaction with an open box txn is host-defined
/// and left to the caller). Precondition: `fd` is non-blocking (NOT
/// enforced — no implicit `fcntl`).
///
/// A `0` host return is `Error.Timeout`; a negative is `Error.CoioOp`; only a
/// `>0` return yields an `Events`, and that `Events` is always non-empty.
pub fn wait(fd: c_int, events: Events, timeout: f64) Error!Events {
    const r = c.coio_wait(fd, events.toInt(), timeout);
    if (r == 0) return Error.Timeout;
    if (r < 0) return Error.CoioOp;
    return Events.fromInt(r);
}

/// Close `fd` and synchronously wake any fiber blocked in `wait` on it.
/// The `fd` is caller-owned; a non-zero host return surfaces as
/// `Error.CoioOp` — no silent fallback.
pub fn close(fd: c_int) Error!void {
    if (c.coio_close(fd) != 0) return Error.CoioOp;
}

/// The host never ran the callback at all — task creation failed (`coio_call`
/// returned `-1` with `errno = ENOMEM`, module.h :1131). Distinct from a
/// callback that ran and itself returned `-1`, which is a value, not this error.
pub const CallError = error{OffloadFailed};

/// Run `func(ctx)` on Tarantool's coio worker-thread pool; the calling fiber
/// yields until it returns. This is a yield point.
///
/// DANGER: `func` runs on a plain worker pthread, OFF the tx thread. It MUST
/// NOT call any box API, use the fiber region, spawn/touch fibers, or enter the
/// Lua state — none of those are thread-safe off tx. Restrict `func` to
/// self-contained blocking work (file IO, DNS, syscalls) over the `ctx` it is
/// handed. `func` cannot be cancelled mid-flight: fiber cancellation is only
/// observed once `func` returns.
///
/// Returns `func`'s own `isize` verbatim — including a negative return, which
/// is DATA, not failure. `error.OffloadFailed` is raised only when the host
/// failed to create the task and never ran `func`. The disambiguation is
/// a ran-flag set inside our trampoline, not the diag and not errno: the host's
/// `-1`/ENOMEM infra-failure channel is indistinguishable from a callback's own
/// `-1`/ENOMEM by inspection, so we observe directly whether `func` ran.
///
/// No heap allocation: the closure frame lives on the caller's stack, valid
/// because `coio_call` returns only after the task completes or is never
/// created — the worker never touches the frame after `coio_call`
/// returns, and the `ran` read is race-free.
pub fn call(comptime Ctx: type, comptime func: fn (*Ctx) isize, ctx: *Ctx) CallError!isize {
    const Frame = struct { ctx: *Ctx, ran: bool = false };
    var frame: Frame = .{ .ctx = ctx };

    const Tramp = struct {
        // Runs on the worker pthread. The frame pointer travels through
        // `coio_call`'s varargs and is read via `c.vaArgPtr` — the same channel as
        // `fiber_start`'s trampoline; a ctx side-channel does NOT survive here.
        fn cb(ap: c.VaListParam) callconv(.c) isize {
            const fr: *Frame = @ptrCast(@alignCast(c.vaArgPtr(ap).?));
            fr.ran = true;
            return func(fr.ctx);
        }
    };

    const r = c.coio_call(&Tramp.cb, &frame);
    if (r == -1 and !frame.ran) return CallError.OffloadFailed;
    return r;
}

/// A `getAddrInfo` failure: the host timed out (`error.Timeout`, diag error
/// type `"TimedOut"`) or the resolver failed for any other reason
/// (`error.ResolveFailed` — resolver error, cancellation, unknown host; the
/// diag message stays reachable via `error.lastMessage`).
pub const GetAddrInfoError = error{ Timeout, ResolveFailed };

/// A caller-owned `getaddrinfo(3)` result chain. `deinit` frees the whole list
/// via `std.c.freeaddrinfo` exactly once; `iterator` walks the `next`
/// chain non-destructively.
pub const AddrInfoList = struct {
    head: *std.c.addrinfo,

    pub const Iterator = struct {
        cur: ?*std.c.addrinfo,

        /// Return the current node and advance; null at the end of the chain.
        pub fn next(self: *Iterator) ?*std.c.addrinfo {
            const node = self.cur orelse return null;
            self.cur = node.next;
            return node;
        }
    };

    /// Free the entire result chain. Call exactly once; the list is unusable
    /// afterward.
    pub fn deinit(self: AddrInfoList) void {
        std.c.freeaddrinfo(self.head);
    }

    /// Walk the `ai_next` chain starting at the head.
    pub fn iterator(self: AddrInfoList) Iterator {
        return .{ .cur = self.head };
    }
};

/// Fiber-friendly `getaddrinfo(3)`: resolves `host`/`port` on the coio pool
/// (the host offloads internally) with a `timeout` in seconds, yielding the
/// calling fiber meanwhile. `hints` is an optional libc `addrinfo` filter.
/// The returned list is caller-owned — free it with `AddrInfoList.deinit`.
///
/// A `-1` host return maps via the box diag: diag error TYPE
/// `"TimedOut"` → `error.Timeout`, any other diag (or none) →
/// `error.ResolveFailed`. The diag CODE cannot be used: this host sets
/// `ER_SYSTEM` (115) for BOTH the timeout (type `TimedOut`) and resolver
/// failure (type `SystemError`), so only the stable error-class name
/// distinguishes them (live-verified).
/// A `0` return with a null result is also `error.ResolveFailed` — never a
/// silent empty list (house no-silent-fallback rule).
pub fn getAddrInfo(host: [:0]const u8, port: ?[:0]const u8, hints: ?*const std.c.addrinfo, timeout: f64) GetAddrInfoError!AddrInfoList {
    var res: ?*std.c.addrinfo = null;
    if (c.coio_getaddrinfo(host.ptr, if (port) |p| p.ptr else null, hints, &res, timeout) != 0) {
        if (err.lastError()) |e| {
            const ty = std.mem.span(@as([*:0]const u8, @ptrCast(e.type)));
            if (std.mem.eql(u8, ty, "TimedOut")) return GetAddrInfoError.Timeout;
        }
        return GetAddrInfoError.ResolveFailed;
    }
    return .{ .head = res orelse return GetAddrInfoError.ResolveFailed };
}

test {
    // Reference the public surface so the host-bound paths are type-checked.
    _ = &wait;
    _ = &close;
    _ = &Events.toInt;
    _ = &Events.fromInt;
    _ = &Events.isEmpty;
    _ = &getAddrInfo;
    _ = &AddrInfoList.deinit;
    _ = &AddrInfoList.iterator;
    _ = &AddrInfoList.Iterator.next;

    // Force monomorphization of the `call` generic body with a concrete `Ctx`
    // so its body (trampoline + ran-flag branch) is actually type-checked
    // (`_ = &call` alone does NOT compile the generic body;
    // mirrored from fiber.zig's spawn probe).
    const Probe = struct {
        n: isize,
        fn body(self: *@This()) isize {
            return self.n;
        }
    };
    _ = &struct {
        fn force(p: *Probe) CallError!isize {
            return call(Probe, Probe.body, p);
        }
    }.force;

    // Pure compile-time check: Events <-> c_int is a lossless @bitCast
    // mapping read/write bit-for-bit onto COIO_READ/COIO_WRITE. No host call,
    // so this runs at comptime regardless of whether the test binary links.
    comptime {
        std.debug.assert((Events{ .read = true }).toInt() == c.COIO_READ);
        std.debug.assert((Events{ .write = true }).toInt() == c.COIO_WRITE);
        std.debug.assert((Events{ .read = true, .write = true }).toInt() == (c.COIO_READ | c.COIO_WRITE));
        std.debug.assert(Events.fromInt(c.COIO_READ).read == true);
        std.debug.assert(Events.fromInt(c.COIO_READ).write == false);
        std.debug.assert(Events.fromInt(c.COIO_WRITE).write == true);
        std.debug.assert(Events.fromInt(c.COIO_WRITE).read == false);
        std.debug.assert((Events{}).isEmpty() == true);
        std.debug.assert(!(Events{ .read = true }).isEmpty());
    }
}
