//! Host wall/CPU clocks: thin 1:1 wrappers over Tarantool's `clock_*` C
//! functions (this module is Tarantool-bound and imports `c.zig`). Completes
//! the timing story next to `fiber.clock`/`fiber.time` (event-loop time) — this
//! family is the `clock_gettime(2)` real/monotonic/CPU clocks.
//!
//! Each function is exactly one host call with zero arithmetic: the
//! `f64` variants return SECONDS, the `*64` variants return NANOSECONDS as a
//! signed `i64` (the header's "64 bit signed integer"; ns is Tarantool's clock
//! contract). No unit conversion happens here.

const c = @import("c.zig");

/// Wall-clock (settable, system-wide) time, in seconds. Backed by
/// `CLOCK_REALTIME` (`clock_gettime(2)`).
pub fn realtime() f64 {
    return c.clock_realtime();
}

/// Wall-clock (settable, system-wide) time, in nanoseconds. Backed by
/// `CLOCK_REALTIME`.
pub fn realtime64() i64 {
    return c.clock_realtime64();
}

/// Monotonic (nonsettable, non-decreasing) time, in seconds. Backed by
/// `CLOCK_MONOTONIC`.
pub fn monotonic() f64 {
    return c.clock_monotonic();
}

/// Monotonic (nonsettable, non-decreasing) time, in nanoseconds. Backed by
/// `CLOCK_MONOTONIC`.
pub fn monotonic64() i64 {
    return c.clock_monotonic64();
}

/// CPU time consumed by this process (all threads), in seconds. Backed by
/// `CLOCK_PROCESS_CPUTIME_ID`.
pub fn process() f64 {
    return c.clock_process();
}

/// CPU time consumed by this process (all threads), in nanoseconds. Backed by
/// `CLOCK_PROCESS_CPUTIME_ID`.
pub fn process64() i64 {
    return c.clock_process64();
}

/// CPU time consumed by this thread, in seconds. Backed by
/// `CLOCK_THREAD_CPUTIME_ID`.
pub fn thread() f64 {
    return c.clock_thread();
}

/// CPU time consumed by this thread, in nanoseconds. Backed by
/// `CLOCK_THREAD_CPUTIME_ID`.
pub fn thread64() i64 {
    return c.clock_thread64();
}

test {
    // Compile-smoke only: clocks are host syscall wrappers, so this references
    // the public surface at comptime without running any of it.
    _ = &realtime;
    _ = &realtime64;
    _ = &monotonic;
    _ = &monotonic64;
    _ = &process;
    _ = &process64;
    _ = &thread;
    _ = &thread64;
}
