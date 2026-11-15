//! The API reference of zig-tarantool, generated from the doc comments of its
//! four modules:
//!
//! * `tarantool` — the in-process SDK: stored procedures, the box API, fibers,
//!   Lua modules, triggers, logging. Imported by modules that Tarantool loads.
//! * `client` — `tarantool-client`, the iproto network client.
//! * `proto` — `tarantool-proto`, the protocol types shared by both: iterator
//!   types, select options, update operations.
//! * `msgpack` — the MessagePack codec.
//!
//! The guides are at https://tarantool-contrib.github.io/zig-tarantool/.
//! This file only exists for `zig build docs`; nothing imports it.

pub const tarantool = @import("tarantool");
pub const client = @import("tarantool-client");
pub const proto = @import("tarantool-proto");
pub const msgpack = @import("msgpack");
