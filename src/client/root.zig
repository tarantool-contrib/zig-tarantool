//! tarantool-client — the iproto network client.
//!
//! `Connection.connect` opens a connection (greeting, feature negotiation,
//! chap-sha1 login); on it: typed and raw CRUD by space name (`Space`,
//! `Index`), `call`/`eval`, pipelined `Batch`es, a cached `Schema`, watchers
//! and interactive transactions over a `Stream`. All I/O goes through the
//! `std.Io` passed to `connect`: `std.Io.Threaded` in a program,
//! `tarantool.fiberio.io()` inside a stored procedure.
//!
//! The module imports only `msgpack` + `tarantool-proto` + std; it
//! names no host (box_*) ABI — a linking test exe proves the purity.
//!
//! Guide: https://tarantool-contrib.github.io/zig-tarantool/how-to/network-client/

const connection = @import("connection.zig");
const space = @import("space.zig");
const schema = @import("schema.zig");
const batch = @import("batch.zig");
const stream = @import("stream.zig");

/// A live iproto connection: connect/handshake/auth/close, ping.
pub const Connection = connection.Connection;

/// A space value handle over a `Connection`: typed + raw DML (insert/replace/
/// delete/get/update/upsert/select). Construct via `Connection.space(name)`. The
/// `error.MoreThanOne` signal a unique `get` may raise lives in `Error`.
pub const Space = space.Space;

/// A read handle over a secondary index of a `Space` (`get`/`select`, typed +
/// raw). Construct via `space.index(name)`.
pub const Index = space.Index;

/// An interactive transaction over a `Connection`: `begin`/`commit`/`rollback`
/// plus `space(name)` for stream-scoped DML (every frame carries STREAM_ID).
/// Construct via `Stream.open(conn)`. See `stream.zig`.
pub const Stream = stream.Stream;

/// A pipelined request batch over a `Connection`: build N frames with the verb
/// adders, `execute()` to flush them in one write and read all N replies matched
/// by sync, then read per-handle results (arena-owned, valid until `deinit`).
/// Construct via `Connection.batch(gpa)`. See `batch.zig`.
pub const Batch = batch.Batch;

/// A batch slot index returned by every `Batch` verb adder.
pub const Handle = batch.Handle;

/// Per-slot server-error details from a `Batch` (`batch.serverError(h)`).
pub const ServerErrorInfo = batch.ServerErrorInfo;

/// Options for `Connection.connect` (address / user / password / timeout).
pub const ConnectOptions = connection.ConnectOptions;

/// Owned copy of a server error response (`Connection.last_error`).
pub const ServerError = connection.ServerError;

/// Client-level error family (transport/protocol/auth/server).
pub const Error = connection.Error;

/// Error set of `Connection.connect`.
pub const ConnectError = connection.ConnectError;

/// Error set of a request roundtrip (e.g. `Connection.ping`).
pub const RequestError = connection.RequestError;

/// An owned, drift-aware snapshot of the server schema (spaces/indexes/formats),
/// fetched lazily via `Connection.schema()`. See `schema.zig` for the value model
/// (`Schema.SpaceInfo`, `Field`, `IndexInfo`, `Part`).
pub const Schema = schema.Schema;

/// Decode a raw msgpack tuple into a named struct by field NAME against a
/// space's format (order-independent; optional fields absorb missing nullable
/// tails). Slice leaves borrow the input bytes. See `schema.zig`.
pub const decodeRow = schema.decodeRow;

/// Error set of `decodeRow` (codec decode errors + `FieldNotInFormat`).
pub const DecodeRowError = schema.DecodeRowError;

test {
    _ = connection;
    _ = space;
    _ = schema;
    _ = batch;
    _ = stream;
}
