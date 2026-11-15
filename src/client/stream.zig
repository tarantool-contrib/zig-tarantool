//! `Stream` — an interactive (multi-request) transaction over a `Connection`.
//!
//! A stream is nothing more than a client-assigned id carried in the STREAM_ID
//! (0x0a) header key of every request that belongs to it. The server gives each
//! distinct STREAM_ID its own transaction fiber, so BEGIN/COMMIT/ROLLBACK and any
//! DML issued through `Stream.space` compose atomically — while requests OUTSIDE
//! the stream (plain `conn.space`) stay autocommit and, under MVCC, do not see the
//! stream's uncommitted writes. Every stream request is an ordinary sync-matched
//! roundtrip: streams add zero concurrency (single-in-flight is unchanged) — they
//! are just one more header key.
//!
//! ID assignment: the id is derived from `conn.nextSync()` — a per-connection
//! monotonic counter. STREAM_IDs only need to be UNIQUE per connection (the
//! server keys transactions by connection+stream_id), and nextSync already
//! guarantees that. The one sync value spent on the id is not otherwise used as a
//! request sync, so there is no collision with the frames' own syncs.
//!
//! DEFERRED (v1 scope, plan): stream-scoped `call`/`eval` (the transactional DML
//! path is the use case and needs no connection-level builder changes) and
//! batch×stream composition (a `Batch` does not yet thread a per-frame stream_id).
//! Both are additive layers over the STREAM_ID header already plumbed here.
//!
//! MISUSE: there is no client-side state machine beyond the id — a COMMIT
//! without a prior BEGIN, or DML after COMMIT, surfaces as the server's
//! `error.ServerError`, not a local guard.

const std = @import("std");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");
const connection = @import("connection.zig");
const space_mod = @import("space.zig");

const iproto = proto.iproto;
const request = iproto.request;
const Connection = connection.Connection;
const Space = space_mod.Space;
const Error = connection.Error;
const RequestError = connection.RequestError;

/// A value handle binding a live connection to one interactive transaction by
/// `id`. Cheap to copy; holds no owned state. Open via `Stream.open(conn)`;
/// drive with `begin`/`commit`/`rollback`; scope DML with `space(name)`.
pub const Stream = struct {
    conn: *Connection,
    /// The STREAM_ID carried by every frame of this transaction (unique per
    /// connection). Assigned by `open` from `conn.nextSync()`.
    id: u64,

    /// Open a stream on `conn`. Requires the server to have negotiated both
    /// STREAMS (feature 0) and TRANSACTIONS (feature 1) — else
    /// `error.UnsupportedServer`. Does NO I/O: BEGIN is a separate, explicit
    /// `begin()` call (a stream may be opened and its space handles taken before
    /// the transaction actually starts). The id comes from `conn.nextSync()`
    /// (see the module note on uniqueness).
    pub fn open(conn: *Connection) Error!Stream {
        if (!conn.hasFeature(.streams) or !conn.hasFeature(.transactions)) {
            return error.UnsupportedServer;
        }
        return .{ .conn = conn, .id = conn.nextSync() };
    }

    /// BEGIN (0x0e): start the transaction bound to this stream. v1 sends no
    /// options (empty body). A server error (e.g. a BEGIN while one is already
    /// active on this stream) surfaces as `error.ServerError`.
    pub fn begin(s: Stream) RequestError!void {
        try s.control(request.begin);
    }

    /// COMMIT (0x0f): commit this stream's transaction. A COMMIT without a live
    /// BEGIN surfaces as the server's `error.ServerError`.
    pub fn commit(s: Stream) RequestError!void {
        try s.control(request.commit);
    }

    /// ROLLBACK (0x10): abort this stream's transaction, discarding its writes.
    pub fn rollback(s: Stream) RequestError!void {
        try s.control(request.rollback);
    }

    /// BEGIN/COMMIT/ROLLBACK share one shape: build the tiny `builder` frame
    /// (header{TYPE,SYNC,STREAM_ID} ++ empty body) and roundtrip it. The reply
    /// carries no DATA; an OK reply is success, a server error is raised by
    /// `roundtrip`.
    fn control(s: Stream, comptime builder: fn (*msgpack.Buffer, u64, u64) anyerror!void) RequestError!void {
        const sync = s.conn.nextSync();
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        builder(&buf, sync, s.id) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable, // the proto builders only fail on allocation
        };
        _ = try s.conn.roundtrip(buf.items(), sync);
    }

    /// Bind a `Space` by name to THIS stream: the returned handle carries this
    /// stream's id, so every DML frame it builds rides the STREAM_ID header and
    /// joins the transaction. Infallible, no I/O — identical shape to
    /// `Connection.space`, only with `stream_id` set (names resolve
    /// server-side; a bad name surfaces as `error.ServerError` on first use).
    pub fn space(s: Stream, name: []const u8) Space {
        return .{ .conn = s.conn, .name = name, .stream_id = s.id };
    }
};

// ---------------------------------------------------------------------------
// Tests (pure; the live begin/commit/rollback path is covered by the stream harness)
//
// The proto frame bytes for BEGIN/COMMIT/ROLLBACK and stream-scoped DML are
// oracle-checked in iproto.zig. Here we verify the client composition: feature
// gating, id assignment, and that `space()` propagates the id.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// featureBit mirror (connection.zig keeps its own private): bit i for feature i.
fn featureMask(features: []const iproto.Feature) u64 {
    var m: u64 = 0;
    for (features) |f| m |= @as(u64, 1) << @backingInt(f);
    return m;
}

test "open requires STREAMS and TRANSACTIONS features (else UnsupportedServer)" {
    var conn: Connection = undefined;
    conn.sync = 0;

    // Both features present -> opens.
    conn.features = featureMask(&.{ .streams, .transactions });
    const s = try Stream.open(&conn);
    try testing.expectEqual(@as(u64, 0), s.id); // first nextSync

    // Missing TRANSACTIONS -> UnsupportedServer.
    conn.features = featureMask(&.{.streams});
    try testing.expectError(error.UnsupportedServer, Stream.open(&conn));

    // Missing STREAMS -> UnsupportedServer.
    conn.features = featureMask(&.{.transactions});
    try testing.expectError(error.UnsupportedServer, Stream.open(&conn));

    // Neither -> UnsupportedServer.
    conn.features = 0;
    try testing.expectError(error.UnsupportedServer, Stream.open(&conn));
}

test "open assigns a monotonic id from nextSync; each open is a fresh id" {
    var conn: Connection = undefined;
    conn.sync = 5;
    conn.features = featureMask(&.{ .streams, .transactions });

    const a = try Stream.open(&conn);
    const b = try Stream.open(&conn);
    try testing.expectEqual(@as(u64, 5), a.id);
    try testing.expectEqual(@as(u64, 6), b.id);
    try testing.expect(a.id != b.id);
}

test "space() propagates the stream id into the Space handle" {
    var conn: Connection = undefined;
    conn.sync = 0;
    conn.features = featureMask(&.{ .streams, .transactions });

    const s = try Stream.open(&conn);
    const sp = s.space("users");
    try testing.expectEqual(@as(?u64, s.id), sp.stream_id);
    try testing.expectEqualStrings("users", sp.name);
    try testing.expectEqual(&conn, sp.conn);
}
