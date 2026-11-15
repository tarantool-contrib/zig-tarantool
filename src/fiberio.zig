//! `std.Io` over Tarantool fibers/coio — an in-process, fiber-yielding I/O
//! backend so stored procedures can drive `tarantool-client` (net.box in Zig)
//! without blocking the TX thread. Network waits park the calling fiber in
//! `coio_wait` and resume it when the fd is ready, instead of blocking the
//! event loop in a syscall.
//!
//! FIBER-CONTEXT CONTRACT: `io()` MUST be called from a fiber running on the TX
//! thread (every stored proc is). The waits go through `coio_wait`/`coio_close`,
//! which are only valid inside a fiber — calling from a foreign (non-fiber)
//! thread is undefined, the same precondition every other `coio` API carries.
//!
//! STRATEGY (all-panic vtable): only the net paths the in-process client
//! actually exercises are implemented — `netConnectIp`, `netClose`, and the
//! `net_read`/`net_write` operations of `operate`. EVERY other `std.Io.VTable` entry panics loudly BY NAME:
//! an unimplemented path never silently no-ops or returns a bogus value; it
//! aborts with `fiberio: <entry> not implemented`. The implemented set is the
//! empirical answer to "what does the connector need" — grow it only when a run
//! surfaces a named panic.
//!
//! The POSIX mechanics (iovec assembly, EOF/error mapping, the sendmsg splat
//! handling, address conversion) mirror `std.Io.Threaded`'s posix net helpers —
//! the maintained reference for this Zig version — with one change: every place
//! Threaded blocks in the syscall, fiberio uses a non-blocking fd and yields via
//! `coio.wait` on `EAGAIN`/`EINPROGRESS`, then retries.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const assert = std.debug.assert;

const coio = @import("coio.zig");
const c = @import("c.zig");

// `std.Io`-scope names referenced verbatim by the generated panic stubs below,
// so their (real, version-pinned) `VTable` signatures resolve unchanged. Unused
// top-level aliases are permitted in Zig and keep the stub block a faithful copy
// of the ground-truth `Io.VTable` declaration.
const Io = std.Io;
const net = Io.net;
const Dir = Io.Dir;
const File = Io.File;
const Terminal = Io.Terminal;
const Clock = Io.Clock;
const Timeout = Io.Timeout;
const Timestamp = Io.Timestamp;
const Duration = Io.Duration;
const Group = Io.Group;
const Batch = Io.Batch;
const Operation = Io.Operation;
const AnyFuture = Io.AnyFuture;
const Cancelable = Io.Cancelable;
const ConcurrentError = Io.ConcurrentError;
const CancelProtection = Io.CancelProtection;
const RandomSecureError = Io.RandomSecureError;
const LockedStderr = Io.LockedStderr;
const Queue = Io.Queue;

const ns_per_s: f64 = std.time.ns_per_s;

/// Tarantool's `TIMEOUT_INFINITY`: ~100 years in seconds. `coio_wait` treats
/// this as "wait forever" — the seconds value used for a `.none` timeout and for
/// the (untimed) read/write waits, matching Threaded's blocking-forever posix
/// syscalls.
const timeout_infinity: f64 = 365.0 * 24.0 * 60.0 * 60.0 * 100.0;

/// Cap on scatter/gather segments per syscall — mirrors `Threaded.max_iovecs_len`.
const max_iovecs_len = 8;
/// Backing buffer for byte-pattern splat expansion — mirrors `Threaded.splat_buffer_size`.
const splat_buffer_size = 64;

/// A stateless `std.Io` whose network operations yield the calling fiber over
/// `coio` instead of blocking the TX thread. The vtable is static and `userdata`
/// is unused. MUST be called from a fiber (see the file-level contract).
pub fn io() std.Io {
    return .{ .userdata = null, .vtable = &vtable };
}

// ---------------------------------------------------------------------------
// Timeout mapping
// ---------------------------------------------------------------------------

/// Map an `Io.Timeout` to the `coio.wait` seconds value, or `null` for
/// "wait forever" (`.none`). `.duration` converts its nanoseconds directly.
/// `.deadline` is measured against the host clock matching its `Clock` and
/// clamped to zero (an already-elapsed deadline polls once). NOTE: a `.deadline`
/// on a monotonic clock (`.awake`/`.boot`) is only meaningful if it was produced
/// against this backend's own clock; fiberio does not implement `now`, so the
/// client never constructs such deadlines — it passes `.none` or `.duration`.
fn timeoutToSeconds(t: std.Io.Timeout) ?f64 {
    return switch (t) {
        .none => null,
        .duration => |d| nanosToSeconds(d.raw.nanoseconds),
        .deadline => |d| blk: {
            const remaining = nanosToSeconds(d.raw.nanoseconds) - hostClockSeconds(d.clock);
            break :blk if (remaining < 0) 0 else remaining;
        },
    };
}

/// Nanoseconds (`i96`) to fractional seconds — a pure, comptime-evaluable map.
fn nanosToSeconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / ns_per_s;
}

/// Current host time in seconds for the given `Clock` (host-bound; used only for
/// `.deadline` timeouts). Maps the std clock kinds onto Tarantool's `clock_*`.
fn hostClockSeconds(clock: std.Io.Clock) f64 {
    return switch (clock) {
        .real => c.clock_realtime(),
        .awake, .boot => c.clock_monotonic(),
        .cpu_process => c.clock_process(),
        .cpu_thread => c.clock_thread(),
    };
}

// ---------------------------------------------------------------------------
// Implemented net vtable entries (fiber-yielding over coio)
// ---------------------------------------------------------------------------

fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    _ = userdata;
    const family = posixAddressFamily(address);
    const mode: u32 = switch (options.mode) {
        .stream => posix.SOCK.STREAM,
        .dgram => posix.SOCK.DGRAM,
        .seqpacket => posix.SOCK.SEQPACKET,
        .raw => posix.SOCK.RAW,
        .rdm => posix.SOCK.RDM,
    };
    const protocol: u32 = if (options.protocol) |p| @backingInt(p) else 0;

    const fd = try openNonblockSocket(family, mode, protocol);
    errdefer closeFd(fd);

    var storage: PosixAddress = undefined;
    const addr_len = addressToPosix(address, &storage);

    // Non-blocking connect: an immediate SUCCESS is already connected; an
    // in-flight connect (EINPROGRESS/EAGAIN/EALREADY) yields until the socket is
    // writable, honoring the caller's timeout, then confirms via SO_ERROR.
    if (!try posixConnect(fd, &storage.any, addr_len)) {
        const secs = timeoutToSeconds(options.timeout) orelse timeout_infinity;
        _ = coio.wait(fd, .{ .write = true }, secs) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            error.CoioOp => return error.Unexpected,
        };
        try checkSockError(fd);
    }

    var name_storage: PosixAddress = undefined;
    var name_len: posix.socklen_t = @sizeOf(PosixAddress);
    try posixGetSockName(fd, &name_storage.any, &name_len);
    return .{ .handle = fd, .address = addressFromPosix(&name_storage) };
}

/// `Operation.net_read`. Control data (ancillary messages) is not supported:
/// the client never asks for it, so a non-empty `control` buffer panics by name.
fn netRead(fd: net.Socket.Handle, data: [][]u8, control: []u8) Operation.NetRead.Error!net.Stream.ReadResult {
    if (control.len != 0) @panic("fiberio: net_read with control data not implemented");
    var iovecs_buffer: [max_iovecs_len]posix.iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    const dest = iovecs_buffer[0..i];
    assert(dest.len > 0 and dest[0].len > 0);

    while (true) {
        const rc = posix.system.readv(fd, dest.ptr, @intCast(dest.len));
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .data_len = @intCast(rc) },
            .INTR => continue,
            .AGAIN => {
                try waitReadable(fd);
                continue;
            },
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN => return error.SocketUnconnected,
            .PIPE => return error.SocketUnconnected,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NETDOWN => return error.NetworkDown,
            else => return error.Unexpected,
        }
    }
}

/// `Operation.net_write`.
fn netWrite(
    fd: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    control: []const u8,
) Operation.NetWrite.Error!usize {
    var iovecs: [max_iovecs_len]posix.iovec_const = undefined;
    var msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = 0,
        .control = if (control.len == 0) null else @constCast(control.ptr),
        .controllen = @intCast(control.len),
        .flags = 0,
    };
    addBuf(&iovecs, &msg.iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &msg.iovlen, bytes);
    const pattern = data[data.len - 1];

    var splat_backup_buffer: [splat_buffer_size]u8 = undefined;
    if (iovecs.len - msg.iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &msg.iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &splat_backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(&iovecs, &msg.iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - msg.iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(&iovecs, &msg.iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(&iovecs, &msg.iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                addBuf(&iovecs, &msg.iovlen, pattern);
            },
        },
    };

    const flags = posix.MSG.NOSIGNAL;
    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => {
                try waitWritable(fd);
                continue;
            },
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .CONNRESET => return error.ConnectionResetByPeer,
            .PIPE => return error.SocketUnconnected,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketUnconnected,
            .NETDOWN => return error.NetworkDown,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
    _ = userdata;
    for (sockets) |s| coio.close(s.handle) catch {
        // `netClose` is infallible by the vtable contract (returns void). A
        // failed `coio_close` on a caller-owned client fd is unrecoverable and
        // unactionable — there is no channel to surface it and nothing to retry.
        // This is NOT a masked genuine-failure fallback: the fd is being torn
        // down regardless of the syscall's result.
    };
}

// ---------------------------------------------------------------------------
// coio-yielding wait helpers
// ---------------------------------------------------------------------------

// The read/write error sets have no Timeout: these waits are infinite and
// never time out, and a coio failure is surfaced honestly as Unexpected.

fn waitReadable(fd: net.Socket.Handle) Operation.NetRead.Error!void {
    _ = coio.wait(fd, .{ .read = true }, timeout_infinity) catch |e| switch (e) {
        error.Timeout, error.CoioOp => return error.Unexpected,
    };
}

fn waitWritable(fd: net.Socket.Handle) Operation.NetWrite.Error!void {
    _ = coio.wait(fd, .{ .write = true }, timeout_infinity) catch |e| switch (e) {
        error.Timeout, error.CoioOp => return error.Unexpected,
    };
}

/// `VTable.operate`: only the stream ops the client uses (`net_read`,
/// `net_write`) are implemented; every other operation panics by name.
fn operate(userdata: ?*anyopaque, operation: Operation) Cancelable!Operation.Result {
    _ = userdata;
    return switch (operation) {
        .net_read => |o| .{ .net_read = netRead(o.socket_handle, o.data, o.control) },
        .net_write => |o| .{ .net_write = netWrite(o.socket_handle, o.header, o.data, o.splat, o.control) },
        inline else => |_, tag| @panic("fiberio: operate(." ++ @tagName(tag) ++ ") not implemented"),
    };
}

// ---------------------------------------------------------------------------
// POSIX socket primitives (raw syscalls; std.posix dropped the blocking wrappers)
// ---------------------------------------------------------------------------

fn openNonblockSocket(
    family: posix.sa_family_t,
    mode: u32,
    protocol: u32,
) net.IpAddress.ConnectError!posix.fd_t {
    // Darwin's socket() ignores NONBLOCK/CLOEXEC type flags, so pass the bare
    // mode and set both via fcntl afterward (portable across the platforms this
    // SDK targets).
    const rc = posix.system.socket(family, mode, protocol);
    const fd: posix.fd_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
        .INVAL, .PROTOTYPE => return error.ProtocolUnsupportedBySystem,
        else => return error.Unexpected,
    };
    errdefer closeFd(fd);
    try setNonblockCloexec(fd);
    return fd;
}

fn setNonblockCloexec(fd: posix.fd_t) net.IpAddress.ConnectError!void {
    const fl = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(fl) != .SUCCESS) return error.Unexpected;
    const flags: usize = @as(usize, @intCast(fl)) | (1 << @bitOffsetOf(posix.O, "NONBLOCK"));
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags)) != .SUCCESS) return error.Unexpected;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.Unexpected;
}

/// Returns true if the socket connected immediately, false if the connect is in
/// flight (caller must wait for writability). Real failures map to ConnectError.
fn posixConnect(
    fd: posix.fd_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) net.IpAddress.ConnectError!bool {
    while (true) {
        switch (posix.errno(posix.system.connect(fd, addr, addr_len))) {
            .SUCCESS => return true,
            .INTR => continue,
            .ISCONN => return true,
            .INPROGRESS, .AGAIN, .ALREADY => return false,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.Timeout,
            .ACCES, .PERM => return error.AccessDenied,
            .NETDOWN => return error.NetworkDown,
            else => return error.Unexpected,
        }
    }
}

/// Read SO_ERROR after a deferred connect; a non-zero value is the real connect
/// outcome mapped to a ConnectError (no silent success).
fn checkSockError(fd: posix.fd_t) net.IpAddress.ConnectError!void {
    var errcode: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&errcode), &len)) != .SUCCESS) {
        return error.Unexpected;
    }
    if (errcode == 0) return;
    return switch (@as(posix.E, @fromBackingInt(@intCast(errcode)))) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.Timeout,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .NETDOWN => error.NetworkDown,
        .ACCES, .PERM => error.AccessDenied,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        else => error.Unexpected,
    };
}

fn posixGetSockName(
    fd: posix.fd_t,
    addr: *posix.sockaddr,
    addr_len: *posix.socklen_t,
) net.IpAddress.ConnectError!void {
    while (true) {
        switch (posix.errno(posix.system.getsockname(fd, addr, addr_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

const iovlen_t = @FieldType(posix.msghdr_const, "iovlen");

fn addBuf(v: []posix.iovec_const, i: *iovlen_t, bytes: []const u8) void {
    // The OS validates the pointer before the length, so zero-length segments
    // must be omitted (mirrors Threaded.addBuf).
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
    i.* += 1;
}

// ---------------------------------------------------------------------------
// Address conversion (verbatim from Threaded's posix helpers)
// ---------------------------------------------------------------------------

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

fn posixAddressFamily(a: *const net.IpAddress) posix.sa_family_t {
    return switch (a.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

fn addressFromPosix(p: *const PosixAddress) net.IpAddress {
    return switch (p.any.family) {
        posix.AF.INET => .{ .ip4 = address4FromPosix(&p.in) },
        posix.AF.INET6 => .{ .ip6 = address6FromPosix(&p.in6) },
        else => .{ .ip4 = .loopback(0) },
    };
}

fn addressToPosix(a: *const net.IpAddress, storage: *PosixAddress) posix.socklen_t {
    return switch (a.*) {
        .ip4 => |ip4| {
            storage.in = address4ToPosix(ip4);
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |*ip6| {
            storage.in6 = address6ToPosix(ip6);
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn address4FromPosix(in: *const posix.sockaddr.in) net.Ip4Address {
    return .{ .port = std.mem.bigToNative(u16, in.port), .bytes = @bitCast(in.addr) };
}

fn address6FromPosix(in6: *const posix.sockaddr.in6) net.Ip6Address {
    return .{
        .port = std.mem.bigToNative(u16, in6.port),
        .bytes = in6.addr,
        .flow = in6.flowinfo,
        .interface = .{ .index = in6.scope_id },
    };
}

fn address4ToPosix(a: net.Ip4Address) posix.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
}

fn address6ToPosix(a: *const net.Ip6Address) posix.sockaddr.in6 {
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .flowinfo = a.flow,
        .addr = a.bytes,
        .scope_id = a.interface.index,
    };
}

// ---------------------------------------------------------------------------
// The static vtable: four fiber-yielding net entries + all-panic for the rest.
// The panic stubs are a faithful transcription of the real `std.Io.VTable`
// declaration (this Zig version) — regenerate them if the toolchain moves.
// ---------------------------------------------------------------------------

const vtable: std.Io.VTable = .{
    .netConnectIp = netConnectIp,
    .netClose = netClose,
    .operate = operate,
    .crashHandler = struct {
        fn f(_: ?*anyopaque) void {
            @panic("fiberio: crashHandler not implemented");
        }
    }.f,
    .async = struct {
        fn f(_: ?*anyopaque, _: []u8, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*AnyFuture {
            @panic("fiberio: async not implemented");
        }
    }.f,
    .concurrent = struct {
        fn f(_: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (context: *const anyopaque, result: *anyopaque) void) ConcurrentError!*AnyFuture {
            @panic("fiberio: concurrent not implemented");
        }
    }.f,
    .await = struct {
        fn f(_: ?*anyopaque, _: *AnyFuture, _: []u8, _: std.mem.Alignment) void {
            @panic("fiberio: await not implemented");
        }
    }.f,
    .cancel = struct {
        fn f(_: ?*anyopaque, _: *AnyFuture, _: []u8, _: std.mem.Alignment) void {
            @panic("fiberio: cancel not implemented");
        }
    }.f,
    .groupAsync = struct {
        fn f(_: ?*anyopaque, _: *Group, _: []const u8, _: std.mem.Alignment, _: *const fn (context: *const anyopaque) void) void {
            @panic("fiberio: groupAsync not implemented");
        }
    }.f,
    .groupConcurrent = struct {
        fn f(_: ?*anyopaque, _: *Group, _: []const u8, _: std.mem.Alignment, _: *const fn (context: *const anyopaque) void) ConcurrentError!void {
            @panic("fiberio: groupConcurrent not implemented");
        }
    }.f,
    .groupAwait = struct {
        fn f(_: ?*anyopaque, _: *Group, _: *anyopaque) Cancelable!void {
            @panic("fiberio: groupAwait not implemented");
        }
    }.f,
    .groupCancel = struct {
        fn f(_: ?*anyopaque, _: *Group, _: *anyopaque) void {
            @panic("fiberio: groupCancel not implemented");
        }
    }.f,
    .recancel = struct {
        fn f(_: ?*anyopaque) void {
            @panic("fiberio: recancel not implemented");
        }
    }.f,
    .swapCancelProtection = struct {
        fn f(_: ?*anyopaque, _: CancelProtection) CancelProtection {
            @panic("fiberio: swapCancelProtection not implemented");
        }
    }.f,
    .checkCancel = struct {
        fn f(_: ?*anyopaque) Cancelable!void {
            @panic("fiberio: checkCancel not implemented");
        }
    }.f,
    .futexWait = struct {
        fn f(_: ?*anyopaque, _: *const u32, _: u32, _: Timeout) Cancelable!void {
            @panic("fiberio: futexWait not implemented");
        }
    }.f,
    .futexWaitUncancelable = struct {
        fn f(_: ?*anyopaque, _: *const u32, _: u32) void {
            @panic("fiberio: futexWaitUncancelable not implemented");
        }
    }.f,
    .futexWake = struct {
        fn f(_: ?*anyopaque, _: *const u32, _: u32) void {
            @panic("fiberio: futexWake not implemented");
        }
    }.f,
    .batchAwaitAsync = struct {
        fn f(_: ?*anyopaque, _: *Batch) Cancelable!void {
            @panic("fiberio: batchAwaitAsync not implemented");
        }
    }.f,
    .batchAwaitConcurrent = struct {
        fn f(_: ?*anyopaque, _: *Batch, _: Timeout) Batch.AwaitConcurrentError!void {
            @panic("fiberio: batchAwaitConcurrent not implemented");
        }
    }.f,
    .batchCancel = struct {
        fn f(_: ?*anyopaque, _: *Batch) void {
            @panic("fiberio: batchCancel not implemented");
        }
    }.f,
    .dirCreateDir = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.Permissions) Dir.CreateDirError!void {
            @panic("fiberio: dirCreateDir not implemented");
        }
    }.f,
    .dirCreateDirPath = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
            @panic("fiberio: dirCreateDirPath not implemented");
        }
    }.f,
    .dirCreateDirPathOpen = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.Permissions, _: Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir {
            @panic("fiberio: dirCreateDirPathOpen not implemented");
        }
    }.f,
    .dirOpenDir = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.OpenOptions) Dir.OpenError!Dir {
            @panic("fiberio: dirOpenDir not implemented");
        }
    }.f,
    .dirStat = struct {
        fn f(_: ?*anyopaque, _: Dir) Dir.StatError!Dir.Stat {
            @panic("fiberio: dirStat not implemented");
        }
    }.f,
    .dirStatFile = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
            @panic("fiberio: dirStatFile not implemented");
        }
    }.f,
    .dirAccess = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.AccessOptions) Dir.AccessError!void {
            @panic("fiberio: dirAccess not implemented");
        }
    }.f,
    .dirCreateFile = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.CreateFileOptions) File.OpenError!File {
            @panic("fiberio: dirCreateFile not implemented");
        }
    }.f,
    .dirCreateFileAtomic = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!File.Atomic {
            @panic("fiberio: dirCreateFileAtomic not implemented");
        }
    }.f,
    .dirOpenFile = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.OpenFileOptions) File.OpenError!File {
            @panic("fiberio: dirOpenFile not implemented");
        }
    }.f,
    .dirClose = struct {
        fn f(_: ?*anyopaque, _: []const Dir) void {
            @panic("fiberio: dirClose not implemented");
        }
    }.f,
    .dirRead = struct {
        fn f(_: ?*anyopaque, _: *Dir.Reader, _: []Dir.Entry) Dir.Reader.Error!usize {
            @panic("fiberio: dirRead not implemented");
        }
    }.f,
    .dirRealPath = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []u8) Dir.RealPathError!usize {
            @panic("fiberio: dirRealPath not implemented");
        }
    }.f,
    .dirRealPathFile = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: []u8) Dir.RealPathFileError!usize {
            @panic("fiberio: dirRealPathFile not implemented");
        }
    }.f,
    .dirDeleteFile = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8) Dir.DeleteFileError!void {
            @panic("fiberio: dirDeleteFile not implemented");
        }
    }.f,
    .dirDeleteDir = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8) Dir.DeleteDirError!void {
            @panic("fiberio: dirDeleteDir not implemented");
        }
    }.f,
    .dirRename = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir, _: []const u8) Dir.RenameError!void {
            @panic("fiberio: dirRename not implemented");
        }
    }.f,
    .dirRenamePreserve = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir, _: []const u8) Dir.RenamePreserveError!void {
            @panic("fiberio: dirRenamePreserve not implemented");
        }
    }.f,
    .dirSymLink = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: []const u8, _: Dir.SymLinkFlags) Dir.SymLinkError!void {
            @panic("fiberio: dirSymLink not implemented");
        }
    }.f,
    .dirReadLink = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: []u8) Dir.ReadLinkError!usize {
            @panic("fiberio: dirReadLink not implemented");
        }
    }.f,
    .dirSetOwner = struct {
        fn f(_: ?*anyopaque, _: Dir, _: ?File.Uid, _: ?File.Gid) Dir.SetOwnerError!void {
            @panic("fiberio: dirSetOwner not implemented");
        }
    }.f,
    .dirSetFileOwner = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: ?File.Uid, _: ?File.Gid, _: Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void {
            @panic("fiberio: dirSetFileOwner not implemented");
        }
    }.f,
    .dirSetPermissions = struct {
        fn f(_: ?*anyopaque, _: Dir, _: Dir.Permissions) Dir.SetPermissionsError!void {
            @panic("fiberio: dirSetPermissions not implemented");
        }
    }.f,
    .dirSetFilePermissions = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: File.Permissions, _: Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void {
            @panic("fiberio: dirSetFilePermissions not implemented");
        }
    }.f,
    .dirSetTimestamps = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void {
            @panic("fiberio: dirSetTimestamps not implemented");
        }
    }.f,
    .dirHardLink = struct {
        fn f(_: ?*anyopaque, _: Dir, _: []const u8, _: Dir, _: []const u8, _: Dir.HardLinkOptions) Dir.HardLinkError!void {
            @panic("fiberio: dirHardLink not implemented");
        }
    }.f,
    .fileStat = struct {
        fn f(_: ?*anyopaque, _: File) File.StatError!File.Stat {
            @panic("fiberio: fileStat not implemented");
        }
    }.f,
    .fileLength = struct {
        fn f(_: ?*anyopaque, _: File) File.LengthError!u64 {
            @panic("fiberio: fileLength not implemented");
        }
    }.f,
    .fileClose = struct {
        fn f(_: ?*anyopaque, _: []const File) void {
            @panic("fiberio: fileClose not implemented");
        }
    }.f,
    .fileWritePositional = struct {
        fn f(_: ?*anyopaque, _: File, _: []const u8, _: []const []const u8, _: usize, _: u64) File.WritePositionalError!usize {
            @panic("fiberio: fileWritePositional not implemented");
        }
    }.f,
    .fileWriteFileStreaming = struct {
        fn f(_: ?*anyopaque, _: File, _: []const u8, _: *Io.File.Reader, _: Io.Limit) File.Writer.WriteFileError!usize {
            @panic("fiberio: fileWriteFileStreaming not implemented");
        }
    }.f,
    .fileWriteFilePositional = struct {
        fn f(_: ?*anyopaque, _: File, _: []const u8, _: *Io.File.Reader, _: Io.Limit, _: u64) File.WriteFilePositionalError!usize {
            @panic("fiberio: fileWriteFilePositional not implemented");
        }
    }.f,
    .fileReadPositional = struct {
        fn f(_: ?*anyopaque, _: File, _: []const []u8, _: u64) File.ReadPositionalError!usize {
            @panic("fiberio: fileReadPositional not implemented");
        }
    }.f,
    .fileSeekBy = struct {
        fn f(_: ?*anyopaque, _: File, _: i64) File.SeekError!void {
            @panic("fiberio: fileSeekBy not implemented");
        }
    }.f,
    .fileSeekTo = struct {
        fn f(_: ?*anyopaque, _: File, _: u64) File.SeekError!void {
            @panic("fiberio: fileSeekTo not implemented");
        }
    }.f,
    .fileSync = struct {
        fn f(_: ?*anyopaque, _: File) File.SyncError!void {
            @panic("fiberio: fileSync not implemented");
        }
    }.f,
    .fileIsTty = struct {
        fn f(_: ?*anyopaque, _: File) Cancelable!bool {
            @panic("fiberio: fileIsTty not implemented");
        }
    }.f,
    .fileEnableAnsiEscapeCodes = struct {
        fn f(_: ?*anyopaque, _: File) File.EnableAnsiEscapeCodesError!void {
            @panic("fiberio: fileEnableAnsiEscapeCodes not implemented");
        }
    }.f,
    .fileSupportsAnsiEscapeCodes = struct {
        fn f(_: ?*anyopaque, _: File) Cancelable!bool {
            @panic("fiberio: fileSupportsAnsiEscapeCodes not implemented");
        }
    }.f,
    .fileSetLength = struct {
        fn f(_: ?*anyopaque, _: File, _: u64) File.SetLengthError!void {
            @panic("fiberio: fileSetLength not implemented");
        }
    }.f,
    .fileSetOwner = struct {
        fn f(_: ?*anyopaque, _: File, _: ?File.Uid, _: ?File.Gid) File.SetOwnerError!void {
            @panic("fiberio: fileSetOwner not implemented");
        }
    }.f,
    .fileSetPermissions = struct {
        fn f(_: ?*anyopaque, _: File, _: File.Permissions) File.SetPermissionsError!void {
            @panic("fiberio: fileSetPermissions not implemented");
        }
    }.f,
    .fileSetTimestamps = struct {
        fn f(_: ?*anyopaque, _: File, _: File.SetTimestampsOptions) File.SetTimestampsError!void {
            @panic("fiberio: fileSetTimestamps not implemented");
        }
    }.f,
    .fileLock = struct {
        fn f(_: ?*anyopaque, _: File, _: File.Lock) File.LockError!void {
            @panic("fiberio: fileLock not implemented");
        }
    }.f,
    .fileTryLock = struct {
        fn f(_: ?*anyopaque, _: File, _: File.Lock) File.LockError!bool {
            @panic("fiberio: fileTryLock not implemented");
        }
    }.f,
    .fileUnlock = struct {
        fn f(_: ?*anyopaque, _: File) void {
            @panic("fiberio: fileUnlock not implemented");
        }
    }.f,
    .fileDowngradeLock = struct {
        fn f(_: ?*anyopaque, _: File) File.DowngradeLockError!void {
            @panic("fiberio: fileDowngradeLock not implemented");
        }
    }.f,
    .fileRealPath = struct {
        fn f(_: ?*anyopaque, _: File, _: []u8) File.RealPathError!usize {
            @panic("fiberio: fileRealPath not implemented");
        }
    }.f,
    .fileHardLink = struct {
        fn f(_: ?*anyopaque, _: File, _: Dir, _: []const u8, _: File.HardLinkOptions) File.HardLinkError!void {
            @panic("fiberio: fileHardLink not implemented");
        }
    }.f,
    .fileMemoryMapCreate = struct {
        fn f(_: ?*anyopaque, _: File, _: File.MemoryMap.CreateOptions) File.MemoryMap.CreateError!File.MemoryMap {
            @panic("fiberio: fileMemoryMapCreate not implemented");
        }
    }.f,
    .fileMemoryMapDestroy = struct {
        fn f(_: ?*anyopaque, _: *File.MemoryMap) void {
            @panic("fiberio: fileMemoryMapDestroy not implemented");
        }
    }.f,
    .fileMemoryMapSetLength = struct {
        fn f(_: ?*anyopaque, _: *File.MemoryMap, _: usize) File.MemoryMap.SetLengthError!void {
            @panic("fiberio: fileMemoryMapSetLength not implemented");
        }
    }.f,
    .fileMemoryMapRead = struct {
        fn f(_: ?*anyopaque, _: *File.MemoryMap) File.ReadPositionalError!void {
            @panic("fiberio: fileMemoryMapRead not implemented");
        }
    }.f,
    .fileMemoryMapWrite = struct {
        fn f(_: ?*anyopaque, _: *File.MemoryMap) File.WritePositionalError!void {
            @panic("fiberio: fileMemoryMapWrite not implemented");
        }
    }.f,
    .processExecutableOpen = struct {
        fn f(_: ?*anyopaque, _: Dir.OpenFileOptions) std.process.OpenExecutableError!File {
            @panic("fiberio: processExecutableOpen not implemented");
        }
    }.f,
    .processExecutablePath = struct {
        fn f(_: ?*anyopaque, _: []u8) std.process.ExecutablePathError!usize {
            @panic("fiberio: processExecutablePath not implemented");
        }
    }.f,
    .lockStderr = struct {
        fn f(_: ?*anyopaque, _: ?Terminal.Mode) Cancelable!LockedStderr {
            @panic("fiberio: lockStderr not implemented");
        }
    }.f,
    .tryLockStderr = struct {
        fn f(_: ?*anyopaque, _: ?Terminal.Mode) Cancelable!?LockedStderr {
            @panic("fiberio: tryLockStderr not implemented");
        }
    }.f,
    .unlockStderr = struct {
        fn f(_: ?*anyopaque) void {
            @panic("fiberio: unlockStderr not implemented");
        }
    }.f,
    .processCurrentPath = struct {
        fn f(_: ?*anyopaque, _: []u8) std.process.CurrentPathError!usize {
            @panic("fiberio: processCurrentPath not implemented");
        }
    }.f,
    .processSetCurrentDir = struct {
        fn f(_: ?*anyopaque, _: Dir) std.process.SetCurrentDirError!void {
            @panic("fiberio: processSetCurrentDir not implemented");
        }
    }.f,
    .processSetCurrentPath = struct {
        fn f(_: ?*anyopaque, _: []const u8) std.process.SetCurrentPathError!void {
            @panic("fiberio: processSetCurrentPath not implemented");
        }
    }.f,
    .processReplace = struct {
        fn f(_: ?*anyopaque, _: std.process.ReplaceOptions) std.process.ReplaceError {
            @panic("fiberio: processReplace not implemented");
        }
    }.f,
    .processSpawn = struct {
        fn f(_: ?*anyopaque, _: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
            @panic("fiberio: processSpawn not implemented");
        }
    }.f,
    .childWait = struct {
        fn f(_: ?*anyopaque, _: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
            @panic("fiberio: childWait not implemented");
        }
    }.f,
    .childKill = struct {
        fn f(_: ?*anyopaque, _: *std.process.Child) void {
            @panic("fiberio: childKill not implemented");
        }
    }.f,
    .progressParentFile = struct {
        fn f(_: ?*anyopaque) std.Progress.ParentFileError!File {
            @panic("fiberio: progressParentFile not implemented");
        }
    }.f,
    .now = struct {
        fn f(_: ?*anyopaque, _: Clock) Timestamp {
            @panic("fiberio: now not implemented");
        }
    }.f,
    .clockResolution = struct {
        fn f(_: ?*anyopaque, _: Clock) Clock.ResolutionError!Duration {
            @panic("fiberio: clockResolution not implemented");
        }
    }.f,
    .sleep = struct {
        fn f(_: ?*anyopaque, _: Timeout) Cancelable!void {
            @panic("fiberio: sleep not implemented");
        }
    }.f,
    .random = struct {
        fn f(_: ?*anyopaque, _: []u8) void {
            @panic("fiberio: random not implemented");
        }
    }.f,
    .randomSecure = struct {
        fn f(_: ?*anyopaque, _: []u8) RandomSecureError!void {
            @panic("fiberio: randomSecure not implemented");
        }
    }.f,
    .netListenIp = struct {
        fn f(_: ?*anyopaque, _: *const net.IpAddress, _: net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Socket {
            @panic("fiberio: netListenIp not implemented");
        }
    }.f,
    .netAccept = struct {
        fn f(_: ?*anyopaque, _: net.Socket.Handle, _: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
            @panic("fiberio: netAccept not implemented");
        }
    }.f,
    .netBindIp = struct {
        fn f(_: ?*anyopaque, _: *const net.IpAddress, _: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket {
            @panic("fiberio: netBindIp not implemented");
        }
    }.f,
    .netListenUnix = struct {
        fn f(_: ?*anyopaque, _: *const net.UnixAddress, _: net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle {
            @panic("fiberio: netListenUnix not implemented");
        }
    }.f,
    .netConnectUnix = struct {
        fn f(_: ?*anyopaque, _: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
            @panic("fiberio: netConnectUnix not implemented");
        }
    }.f,
    .netSocketCreatePair = struct {
        fn f(_: ?*anyopaque, _: net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket {
            @panic("fiberio: netSocketCreatePair not implemented");
        }
    }.f,
    .inheritParentDir = struct {
        fn f(_: ?*anyopaque, _: Dir.Handle) Io.InheritParentHandleError!Dir {
            @panic("fiberio: inheritParentDir not implemented");
        }
    }.f,
    .inheritParentFile = struct {
        fn f(_: ?*anyopaque, _: File.Handle, _: File.Flags) Io.InheritParentHandleError!File {
            @panic("fiberio: inheritParentFile not implemented");
        }
    }.f,
    .netWriteFile = struct {
        fn f(_: ?*anyopaque, _: net.Socket.Handle, _: []const u8, _: *Io.File.Reader, _: Io.Limit) net.Stream.Writer.WriteFileError!usize {
            @panic("fiberio: netWriteFile not implemented");
        }
    }.f,
    .netShutdown = struct {
        fn f(_: ?*anyopaque, _: net.Socket.Handle, _: net.ShutdownHow) net.ShutdownError!void {
            @panic("fiberio: netShutdown not implemented");
        }
    }.f,
    .netInterfaceNameResolve = struct {
        fn f(_: ?*anyopaque, _: *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface {
            @panic("fiberio: netInterfaceNameResolve not implemented");
        }
    }.f,
    .netInterfaceName = struct {
        fn f(_: ?*anyopaque, _: net.Interface) net.Interface.NameError!net.Interface.Name {
            @panic("fiberio: netInterfaceName not implemented");
        }
    }.f,
    .netLookup = struct {
        fn f(_: ?*anyopaque, _: net.HostName, _: *Queue(net.HostName.LookupResult), _: net.HostName.LookupOptions) net.HostName.LookupError!void {
            @panic("fiberio: netLookup not implemented");
        }
    }.f,
};

// Pure, comptime-evaluable timeout-mapping checks (run whenever this module is
// compiled — e.g. the integration `.so` build). No host call, so they hold at
// comptime regardless of linking (mirrors coio.zig's Events comptime block).
comptime {
    std.debug.assert(timeoutToSeconds(.none) == null);
    std.debug.assert(timeoutToSeconds(.{ .duration = .{ .raw = .{ .nanoseconds = 1_500_000_000 }, .clock = .awake } }).? == 1.5);
    std.debug.assert(timeoutToSeconds(.{ .duration = .{ .raw = .{ .nanoseconds = 0 }, .clock = .awake } }).? == 0.0);
    std.debug.assert(timeoutToSeconds(.{ .duration = .{ .raw = .{ .nanoseconds = 5_000_000_000 }, .clock = .real } }).? == 5.0);
    std.debug.assert(nanosToSeconds(2_500_000_000) == 2.5);
}

test {
    // Reference the public surface + implemented entries so their bodies are
    // type-checked when this file is a test root.
    _ = &io;
    _ = &netConnectIp;
    _ = &netRead;
    _ = &netWrite;
    _ = &netClose;
    _ = &timeoutToSeconds;
    _ = &nanosToSeconds;
    try std.testing.expectEqual(@as(?f64, null), timeoutToSeconds(.none));
    try std.testing.expectEqual(@as(f64, 1.5), timeoutToSeconds(.{ .duration = .{ .raw = .{ .nanoseconds = 1_500_000_000 }, .clock = .awake } }).?);
    try std.testing.expectEqual(@as(f64, 2.5), nanosToSeconds(2_500_000_000));
}
