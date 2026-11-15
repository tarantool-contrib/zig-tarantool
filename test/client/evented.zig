//! Loop-independence smoke — PARKED on Zig 0.16.0.
//!
//! Intent: run the SAME `tarantool-client` against a live server over the
//! platform *evented* `std.Io` backend instead of the runtime's default
//! `std.Io.Threaded`, proving the client names no Io implementation and rides
//! any backend. On macOS that backend is `std.Io.Kqueue`
//! (Zig 0.16 ships per-backend Io types — Kqueue/Uring/Dispatch/Threaded — not a
//! single unified "Evented"). The exe would construct the Kqueue loop EXPLICITLY
//! (NOT take `init.io`, which is Threaded-backed) and drive the client from a
//! `io.async(...)` green-thread task.
//!
//! FINDING (Zig 0.16.0, aarch64-macos): the evented smoke cannot be built, and
//! even if it could it could not run. Two independent blockers in the shipped
//! std:
//!
//!  1. COMPILE-LEVEL: `std.Io.Kqueue.io()` does not compile against this Zig's
//!     `std.Io.VTable`. Its vtable initializer sets `.fileWriteStreaming` and
//!     `.fileReadStreaming` ($STD/Io/Kqueue.zig:637,639), fields that no longer
//!     exist in `Io.VTable` — streaming file I/O migrated to the batched
//!     `file_write_streaming` operation ($STD/Io.zig ~258/297), and the
//!     maintained `Threaded` backend already dropped those vtable fields. So
//!     `kq.io()` yields `error: no field named 'fileWriteStreaming' in struct
//!     'Io.VTable'`. The Kqueue backend is stale vs. the vtable it targets; you
//!     cannot obtain an `Io` from it at all. Merely referencing `kq.io()` here
//!     would break `zig build test`/`integration`.
//!
//!  2. RUNTIME-LEVEL (would bite next, once #1 is fixed upstream): the macOS
//!     Kqueue vtable slots on the client's send/close path are unconditional
//!     `@panic("TODO")` — `netWrite`, `netClose`, `netShutdown`, `netConnectUnix`
//!     ($STD/Io/Kqueue.zig), plus the `.AGAIN` arms of `posixConnect`/
//!     `netSendOne`. The client sends via `net.Stream.Writer.drain ->
//!     io.vtable.netWrite` and tears down via `net.Stream.close ->
//!     io.vtable.netClose` ($STD/Io/net.zig), so the flow would abort inside
//!     `Connection.connect` at the first request write (ID negotiation), right
//!     after the greeting `netRead` (which IS implemented) succeeds. A `@panic`
//!     is uncatchable, so the exe could not run-and-recover.
//!
//! Neither a Threaded fallback (that is the default path, already covered by the
//! `client` group — it proves nothing about loop-independence) nor a faked pass
//! is acceptable. So this exe is PARKED behind an explicit env skip: the luatest
//! `evented` case runs it with `TT_EVENTED_SKIP=1`, the exe prints a documented
//! skip line and exits 0. Run WITHOUT the env it exits 1 with the finding — a
//! loud reminder the smoke is parked, not silently green.
//!
//! WHEN FIXED (a future Zig makes `std.Io.Kqueue` build against `Io.VTable` and
//! implements its netWrite/netClose/netShutdown): restore the real flow here
//! (construct `std.Io.Kqueue` with a thread-safe gpa, `kq.io()`, drive
//! connect->ping->insert->get->close inside `io.async`), and drop
//! `TT_EVENTED_SKIP=1` from `test/luatest/evented_test.lua` so the case asserts
//! the live round trip. Reads `TT_URI`/`TT_USER`/`TT_PASS` like the sibling
//! harness exes; prints TAP-ish lines.

const std = @import("std");

// The `tarantool-client` import is retained: linking this exe with NO box_*
// symbols is the same module-purity proof the other test/client/* exes carry,
// and it keeps this harness wired to the client it will
// drive once the backend is restored.
const client = @import("tarantool-client");

comptime {
    // Reference the client surface so the import is not stripped: the clean link
    // (no host ABI) is the purity proof, independent of the parked flow.
    _ = client.Connection;
}

pub fn main(init: std.process.Init) u8 {
    const env = init.environ_map;

    if (env.get("TT_EVENTED_SKIP")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            std.debug.print(
                "ok - SKIP evented Io smoke: std.Io.Kqueue is unbuildable on this " ++
                    "Zig (io() sets removed Io.VTable fields fileWriteStreaming/" ++
                    "fileReadStreaming) and its netWrite/netClose are @panic(\"TODO\"); " ++
                    "see test/client/evented.zig header + $STD/Io/Kqueue.zig\n",
                .{},
            );
            return 0;
        }
    }

    // No skip: the smoke is parked (see file header). Fail loudly rather
    // than pretend — never silently fall back to std.Io.Threaded.
    std.debug.print(
        "not ok - evented Io smoke is parked on this Zig (std.Io.Kqueue unbuildable; " ++
            "run under TT_EVENTED_SKIP=1, or restore the flow once the backend lands)\n",
        .{},
    );
    return 1;
}
