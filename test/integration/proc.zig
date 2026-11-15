//! Integration module for the raw + typed stored-proc layers.
//!
//! Exercises three procs inside a live Tarantool:
//!   * `proc_add`   — a typed `fn(i64, i64) !i64`, exported via `exportProc`,
//!                    proving param decode + arity check + result encode.
//!   * `proc_raw`   — a hand-written `RawProc`, proving the raw escape hatch.
//!   * `proc_fail`  — a typed proc that returns a Zig error, proving the error
//!                    surfaces through `box_error_set`.

const t = @import("tarantool");
const c = t.c;
const proc = t.proc;

/// Typed proc: sum two integers. Declared as an error union so the typed
/// wrapper's error path is also compiled; here it never fails.
fn add(a: i64, b: i64) !i64 {
    return a + b;
}

/// Typed proc that always fails, to prove error propagation.
fn boom(x: i64) !i64 {
    _ = x;
    return error.Boom;
}

comptime {
    proc.exportProc("proc_add", add);
    proc.exportProc("proc_fail", boom);
}

/// Raw proc (the escape hatch): returns the msgpack integer 7, built by
/// hand and returned through `returnValue` — the same primitive the typed layer
/// uses, but with no reflection.
export fn proc_raw(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) callconv(.c) c_int {
    _ = args;
    _ = args_end;
    return proc.returnValue(ctx, @as(i64, 7));
}
