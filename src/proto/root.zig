//! tarantool-proto — backend-independent Tarantool protocol types.
//!
//! Depends on `msgpack` + std only; carries no host (box_*) ABI. This is the
//! shared wire/protocol layer the SDK and the connector both build on.

/// Backend-independent query types (iterator kinds, select options).
pub const query = @import("query.zig");

/// Backend-independent update-op constructors and runtime ops builder.
pub const update = @import("update.zig");

/// Pure iproto protocol constants (request/response types, keys, features).
pub const iproto = @import("iproto.zig");

/// 128-byte greeting parse (version/uuid/salt).
pub const greeting = @import("greeting.zig");

/// chap-sha1 scramble over pure std.crypto.
pub const auth = @import("auth.zig");

test {
    _ = query;
    _ = update;
    _ = iproto;
    _ = greeting;
    _ = auth;
}
