//! tarantool — the in-process SDK: code that Tarantool loads as a C module.
//!
//! Stored procedures (`proc`), the box API (`box`, `tuple`, `txn`, `seq`,
//! `keydef`), fibers and their synchronization (`fiber`, `cond`, `latch`,
//! `coio`, `fiberio`), Lua modules (`lua`), triggers, logging, decimals.
//! Every typed layer sits on a raw one; `c` is the C API of Tarantool itself.
//! The `box_*` symbols resolve from the Tarantool process at load time
//! (Tarantool 3.5 or later).
//!
//! Guides: https://tarantool-contrib.github.io/zig-tarantool/

/// MessagePack codec (Tarantool-dependency-free).
pub const msgpack = @import("msgpack");

/// Backend-independent query types (iterator kinds, select options).
pub const query = @import("tarantool-proto").query;

/// Backend-independent update-op constructors and runtime ops builder.
pub const update = @import("tarantool-proto").update;

/// Key-definition module: `FieldType`, `KeyPartDef`, and the host-bound `KeyDef`.
pub const keydef = @import("keydef.zig");

/// Hand-written Tarantool C ABI declarations.
pub const c = @import("c.zig");

/// Raw + typed stored-proc layers.
pub const proc = @import("proc.zig");

/// Zig error set ↔ Tarantool box errors.
pub const err = @import("error.zig");

/// Box data API: spaces and CRUD.
pub const box = @import("box.zig");

/// Tuple access.
pub const tuple = @import("tuple.zig");

/// Transaction helper.
pub const txn = @import("txn.zig");

/// Box region as a Zig `Allocator` + `Savepoint`.
pub const region = @import("region.zig");

/// Box sequences: `Sequence` handle over `box_sequence_*`.
pub const seq = @import("seq.zig");

/// Fibers: `Fiber(Result)` handle and spawn helpers over `fiber_*`.
pub const fiber = @import("fiber.zig");

/// Fiber condition variable: Cond handle over fiber_cond_*.
pub const cond = @import("cond.zig");

/// Fiber mutex: Latch handle over box_latch_*.
pub const latch = @import("latch.zig");

/// Host wall/CPU clocks over clock_* (seconds f64, nanoseconds i64).
pub const clock = @import("clock.zig");

/// Cooperative fd readiness waiting over coio_wait/coio_close.
pub const coio = @import("coio.zig");

/// `std.Io` backed by fiber-yielding coio waits — lets stored procs drive the
/// in-process `tarantool-client` without blocking the TX thread. MUST be called
/// from a fiber (every stored proc is); see `fiberio.io`.
pub const fiberio = @import("fiberio.zig");

/// Authoring Lua C modules: `Lua` stack handle + `exportModule` (`luaopen`).
pub const lua = @import("lua.zig");

/// Resolve hidden host symbols (absent from `dlsym`) via the main binary's
/// full symbol table — the escape hatch for unstable internal APIs.
pub const symresolve = @import("symresolve.zig");

/// Tarantool log from Zig: level helpers over _say, std.log adapter.
pub const say = @import("say.zig");

/// Typed decimal: host-bound `Decimal` arithmetic type over `box_decimal_*`.
pub const decimal = @import("decimal.zig");

/// Trigger registration: shutdown (C ABI), txn commit/rollback + space on_replace (Lua bridge).
pub const trigger = @import("trigger.zig");
