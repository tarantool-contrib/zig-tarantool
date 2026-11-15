//! Pure iproto protocol constants, pinned from a live `box.iproto` dump
//! (Tarantool 3.8.0) — never from memory. Every value here is re-asserted
//! against `box.iproto.type`/`.key`/`.feature` by the luatest parity suite,
//! the connector's analog of `verify-cabi`.
//!
//! The constants come first; framing (frame writer/reader, header codec,
//! request builders, response envelope parser) follows below them.

const std = @import("std");
const msgpack = @import("msgpack");
const query = @import("query.zig");

// ---------------------------------------------------------------------------
// Request / response types (box.iproto.type)
// ---------------------------------------------------------------------------

/// iproto request/response message types. Non-exhaustive (`_`): the wire
/// carries many types outside the v1 surface (replication, SQL, watchers,
/// error responses `0x8000|code`) that must decode without trapping. Values
/// pinned from `box.iproto.type`.
pub const RequestType = enum(u32) {
    /// Successful response type.
    ok = 0x00,
    select = 0x01,
    insert = 0x02,
    replace = 0x03,
    update = 0x04,
    delete = 0x05,
    auth = 0x07,
    eval = 0x08,
    upsert = 0x09,
    call = 0x0a,
    /// Interactive-transaction control (STREAM_ID header key selects the stream).
    begin = 0x0e,
    commit = 0x0f,
    rollback = 0x10,
    ping = 0x40,
    id = 0x49,
    /// Watcher protocol: register/ack (WATCH), deregister (UNWATCH), the
    /// server-pushed state notification (EVENT), and the one-shot read
    /// (WATCH_ONCE). Values pinned from the live `box.iproto.type` dump (3.8.0).
    watch = 0x4a,
    unwatch = 0x4b,
    event = 0x4c,
    watch_once = 0x4d,
    /// session.push chunk — out of scope in v1 (treated as a protocol error).
    chunk = 0x80,
    _,
};

/// Response error mask: `box.iproto.type.TYPE_ERROR`. An error response has
/// type `TYPE_ERROR | code`; the low 15 bits carry the server error code.
pub const TYPE_ERROR: u32 = 0x8000;

/// True when a response type encodes a server error (`TYPE_ERROR` bit set).
pub fn isError(t: u32) bool {
    return (t & TYPE_ERROR) != 0;
}

/// Server error code carried in an error response type (`t & 0x7fff`).
pub fn errorCode(t: u32) u32 {
    return t & 0x7fff;
}

// ---------------------------------------------------------------------------
// Header / body keys (box.iproto.key)
// ---------------------------------------------------------------------------

/// iproto MP_MAP keys used by the v1 surface. Values pinned from
/// `box.iproto.key`.
pub const Key = enum(u8) {
    request_type = 0x00,
    sync = 0x01,
    schema_version = 0x05,
    /// Interactive-transaction stream selector; a header key (like SYNC), not a
    /// body key. Present only on stream-scoped requests.
    stream_id = 0x0a,
    space_id = 0x10,
    index_id = 0x11,
    limit = 0x12,
    offset = 0x13,
    iterator = 0x14,
    key = 0x20,
    tuple = 0x21,
    function_name = 0x22,
    user_name = 0x23,
    expr = 0x27,
    ops = 0x28,
    data = 0x30,
    /// Plain error message (`ERROR_24`), always present on error responses.
    error_24 = 0x31,
    /// Structured MP_ERROR stack, kept as raw bytes in v1.
    err = 0x52,
    /// ID request: protocol version the client speaks.
    version = 0x54,
    /// ID request/response: feature bit list.
    features = 0x55,
    auth_type = 0x5b,
    space_name = 0x5e,
    index_name = 0x5f,
    /// Watcher notification (EVENT frame) body keys: the notified key name
    /// (always present) and the current payload (absent when the key has no
    /// value). Pinned from the live `box.iproto.key` dump (3.8.0).
    event_key = 0x57,
    event_data = 0x58,
};

// ---------------------------------------------------------------------------
// Feature bits (box.iproto.feature)
// ---------------------------------------------------------------------------

/// iproto feature bits negotiated via the ID request. The value is the bit
/// position in the FEATURES list. Pinned from `box.iproto.feature` (3.8.0).
pub const Feature = enum(u6) {
    streams = 0,
    transactions = 1,
    error_extension = 2,
    watchers = 3,
    pagination = 4,
    space_and_index_names = 5,
    watch_once = 6,
    dml_tuple_extension = 7,
    call_ret_tuple_extension = 8,
    call_arg_tuple_extension = 9,
    fetch_snapshot_cursor = 10,
    is_sync = 11,
    insert_arrow = 12,
};

// ---------------------------------------------------------------------------
// Framing constants + shared values
// ---------------------------------------------------------------------------

/// Protocol version the v1 client advertises in the ID request (`VERSION 0x54`).
/// Pinned from a live probe on 3.8.0 (`box.iproto.protocol_version` == 10).
pub const protocol_version: u64 = 10;

/// Feature bits the v1 client requests in ID. The server replies with its
/// FULL feature set (not the intersection); the client intersects locally.
/// `watchers`/`watch_once` are advertised so the server delivers EVENT packets
/// and honours WATCH_ONCE — Tarantool gates watcher delivery on the client
/// having set the WATCHERS feature bit in ID, and interactive transactions
/// need STREAMS + TRANSACTIONS advertised the same way (listed in bit order so the on-wire FEATURES array reads 0,1,2,3,5,6).
pub const v1_features = [_]Feature{ .streams, .transactions, .error_extension, .watchers, .space_and_index_names, .watch_once };

/// The only auth mechanism v1 implements (chap-sha1, the sole CE default).
pub const chap_sha1: []const u8 = "chap-sha1";

/// Errors raised while parsing a wire frame that are not msgpack-structural.
pub const FrameError = error{
    /// A CHUNK (0x80, session.push) response arrived — out of scope in v1.
    ProtocolError,
    /// A header/body map lacked a mandatory key (REQUEST_TYPE, SYNC, or — on
    /// an error response — ERROR_24).
    MalformedFrame,
};

/// Full error set surfaced by the readers/parser: msgpack-structural
/// (`Truncated`, `NotMap`, `Overflow`, …) plus the frame-level cases above.
pub const ParseError = msgpack.DecodeError || FrameError;

// ---------------------------------------------------------------------------
// Frame writer
// ---------------------------------------------------------------------------
//
// Packet layout (live-probed): `MP_UINT size ++ header MP_MAP ++ body
// MP_MAP`. The size is written the way Tarantool writes it — `0xce` + u32 BE, a
// fixed 5-byte prefix — so it can be reserved before the packet is encoded and
// backpatched once the length is known (the reservation trick).

/// msgpack does not export a map-header encoder; the v1 maps are all tiny
/// (≤ 6 keys) so `fixmap` covers every real case. The wider branches mirror
/// `msgpack.zig`'s `encodeMapHeader` for defensiveness and stay byte-identical.
fn putMapHeader(buf: *msgpack.Buffer, n: usize) !void {
    if (n < 16) {
        try buf.writeByte(0x80 | @as(u8, @intCast(n)));
    } else if (n <= 0xffff) {
        try buf.writeByte(0xde);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(n), .big);
        try buf.writeAll(&b);
    } else {
        try buf.writeByte(0xdf);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(n), .big);
        try buf.writeAll(&b);
    }
}

/// Reserve the 5-byte `0xce`+u32BE size prefix at the buffer's current tail and
/// return its offset. Pair with `endFrame` once the packet is fully encoded.
pub fn beginFrame(buf: *msgpack.Buffer) !usize {
    const pos = buf.items().len;
    try buf.writeByte(0xce);
    try buf.writeAll(&[_]u8{ 0, 0, 0, 0 });
    return pos;
}

/// Backpatch the size prefix reserved by `beginFrame` with the number of bytes
/// written after it. Pure memory write — cannot fail.
pub fn endFrame(buf: *msgpack.Buffer, size_pos: usize) void {
    const packet_len = buf.list.items.len - size_pos - 5;
    std.mem.writeInt(u32, buf.list.items[size_pos + 1 ..][0..4], @intCast(packet_len), .big);
}

/// Encode a request header map into `buf`. With `stream_id == null` this is the
/// 2-entry `{REQUEST_TYPE, SYNC}` map (byte-identical to the pre-stream form —
/// the oracle tests prove this); a non-null `stream_id` adds the STREAM_ID key
/// (0x0a, after SYNC) for a 3-entry interactive-transaction header. Responses
/// additionally carry SCHEMA_VERSION, but the client only ever writes requests.
pub fn encodeHeader(buf: *msgpack.Buffer, rtype: RequestType, sync: u64, stream_id: ?u64) !void {
    try putMapHeader(buf, if (stream_id != null) 3 else 2);
    try msgpack.encode(buf, Key.request_type);
    try msgpack.encode(buf, rtype);
    try msgpack.encode(buf, Key.sync);
    try msgpack.encode(buf, sync);
    if (stream_id) |sid| {
        try msgpack.encode(buf, Key.stream_id);
        try msgpack.encode(buf, sid);
    }
}

/// Open a request frame: reserve the size prefix and write the header map with
/// `stream_id` (null → the plain 2-entry header; a value adds STREAM_ID for an
/// interactive-transaction request). Returns the size-prefix offset for the
/// matching `endFrame`.
fn beginRequest(buf: *msgpack.Buffer, rtype: RequestType, sync: u64, stream_id: ?u64) !usize {
    const pos = try beginFrame(buf);
    try encodeHeader(buf, rtype, sync, stream_id);
    return pos;
}

// ---------------------------------------------------------------------------
// Request body builders (the 11 v1 types)
// ---------------------------------------------------------------------------
//
// Each builder appends one complete frame (size ++ header ++ body) to `buf`.
// Composite payloads — tuples, keys, args, ops — arrive as *pre-encoded*
// msgpack slices (each a single well-formed value, typically an array) and are
// written verbatim. This is the simpler v1 shape; typed layering over the codec
// lives in the client. DML builders carry names, never ids (SPACE_NAME 0x5e /
// INDEX_NAME 0x5f) — this module never emits SPACE_ID/INDEX_ID.
//
// Interactive transactions (STREAM_ID): the DML builders take a trailing
// `stream_id: ?u64` threaded straight into the header (null → the plain header,
// byte-identical to the pre-stream form — oracle-checked). BEGIN/COMMIT/ROLLBACK
// are their own tiny builders below. CALL/EVAL take no stream_id in v1
// (stream-scoped call/eval is not supported yet).
pub const request = struct {
    /// PING (0x40): empty body.
    pub fn ping(buf: *msgpack.Buffer, sync: u64) !void {
        const pos = try beginRequest(buf, .ping, sync, null);
        try putMapHeader(buf, 0);
        endFrame(buf, pos);
    }

    /// BEGIN (0x0e): open the interactive transaction bound to `stream_id`.
    /// Empty body — v1 sends no options (TXN_ISOLATION/TIMEOUT deferred). The
    /// STREAM_ID header is mandatory (a BEGIN without it is a non-stream,
    /// legacy no-op); callers always pass a real id.
    pub fn begin(buf: *msgpack.Buffer, sync: u64, stream_id: u64) !void {
        try txnControl(buf, .begin, sync, stream_id);
    }

    /// COMMIT (0x0f): commit the transaction bound to `stream_id`. Empty body.
    pub fn commit(buf: *msgpack.Buffer, sync: u64, stream_id: u64) !void {
        try txnControl(buf, .commit, sync, stream_id);
    }

    /// ROLLBACK (0x10): roll back the transaction bound to `stream_id`. Empty body.
    pub fn rollback(buf: *msgpack.Buffer, sync: u64, stream_id: u64) !void {
        try txnControl(buf, .rollback, sync, stream_id);
    }

    /// BEGIN/COMMIT/ROLLBACK share the shape `header{TYPE,SYNC,STREAM_ID} ++
    /// empty body`; only the type differs.
    fn txnControl(buf: *msgpack.Buffer, rtype: RequestType, sync: u64, stream_id: u64) !void {
        const pos = try beginRequest(buf, rtype, sync, stream_id);
        try putMapHeader(buf, 0);
        endFrame(buf, pos);
    }

    /// ID (0x49): VERSION + FEATURES. No AUTH_TYPE in the request. Sent
    /// before AUTH; it bypasses the session auth check.
    pub fn id(buf: *msgpack.Buffer, sync: u64, features: []const Feature) !void {
        const pos = try beginRequest(buf, .id, sync, null);
        try putMapHeader(buf, 2);
        try msgpack.encode(buf, Key.version);
        try msgpack.encode(buf, protocol_version);
        try msgpack.encode(buf, Key.features);
        try msgpack.encode(buf, features);
        endFrame(buf, pos);
    }

    /// AUTH (0x07): USER_NAME + TUPLE `["chap-sha1", scramble20]`. The scramble
    /// is a ready 20-byte digest (auth.zig's job — this builder takes it as a
    /// parameter, no dependency on that module) and goes on the wire as MP_STR.
    pub fn auth(buf: *msgpack.Buffer, sync: u64, user: []const u8, scramble: *const [20]u8) !void {
        const pos = try beginRequest(buf, .auth, sync, null);
        try putMapHeader(buf, 2);
        try msgpack.encode(buf, Key.user_name);
        try msgpack.encode(buf, user);
        try msgpack.encode(buf, Key.tuple);
        try msgpack.encodeArrayHeader(buf, 2);
        try msgpack.encode(buf, chap_sha1);
        try msgpack.encode(buf, scramble); // *const [20]u8 -> MP_STR
        endFrame(buf, pos);
    }

    // --- DML builders: autocommit + stream-scoped pairs ---------------------
    //
    // Each DML verb comes in two forms sharing one implementation: the plain
    // `verb(...)` (autocommit — no STREAM_ID, its original pre-stream signature,
    // so existing callers and the integration harness are untouched) and
    // `verbStream(..., stream_id, ...)` which threads STREAM_ID into the header
    // for interactive transactions. The plain form is a one-line delegate with
    // `stream_id = null`, byte-identical to the pre-stream frame (oracle-checked);
    // `space.zig` calls the `*Stream` form with its handle's `stream_id` (null for
    // a plain space, a real id for a `Stream`-scoped one).

    /// SELECT (0x01) autocommit: space/index by name, iterator, limit, offset, and
    /// a pre-encoded key array. A null `index_name` OMITS the INDEX_NAME key
    /// entirely, so the server defaults to the primary index (index 0).
    pub fn select(
        buf: *msgpack.Buffer,
        sync: u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        iterator: query.IteratorType,
        limit: u32,
        offset: u32,
        key: []const u8,
    ) !void {
        try selectStream(buf, sync, null, space_name, index_name, iterator, limit, offset, key);
    }

    /// SELECT bound to `stream_id` (interactive transaction). Same body as
    /// `select`; STREAM_ID rides the header when non-null.
    pub fn selectStream(
        buf: *msgpack.Buffer,
        sync: u64,
        stream_id: ?u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        iterator: query.IteratorType,
        limit: u32,
        offset: u32,
        key: []const u8,
    ) !void {
        const pos = try beginRequest(buf, .select, sync, stream_id);
        try putMapHeader(buf, if (index_name != null) 6 else 5);
        try msgpack.encode(buf, Key.space_name);
        try msgpack.encode(buf, space_name);
        if (index_name) |name| {
            try msgpack.encode(buf, Key.index_name);
            try msgpack.encode(buf, name);
        }
        try msgpack.encode(buf, Key.iterator);
        try msgpack.encode(buf, iterator);
        try msgpack.encode(buf, Key.limit);
        try msgpack.encode(buf, limit);
        try msgpack.encode(buf, Key.offset);
        try msgpack.encode(buf, offset);
        try msgpack.encode(buf, Key.key);
        try buf.writeAll(key);
        endFrame(buf, pos);
    }

    /// INSERT (0x02) autocommit: space by name + a pre-encoded tuple array.
    pub fn insert(buf: *msgpack.Buffer, sync: u64, space_name: []const u8, tuple: []const u8) !void {
        try insertStream(buf, sync, null, space_name, tuple);
    }

    /// INSERT bound to `stream_id` (interactive transaction).
    pub fn insertStream(buf: *msgpack.Buffer, sync: u64, stream_id: ?u64, space_name: []const u8, tuple: []const u8) !void {
        try spaceTuple(buf, .insert, sync, stream_id, space_name, tuple);
    }

    /// REPLACE (0x03) autocommit: space by name + a pre-encoded tuple array.
    pub fn replace(buf: *msgpack.Buffer, sync: u64, space_name: []const u8, tuple: []const u8) !void {
        try replaceStream(buf, sync, null, space_name, tuple);
    }

    /// REPLACE bound to `stream_id` (interactive transaction).
    pub fn replaceStream(buf: *msgpack.Buffer, sync: u64, stream_id: ?u64, space_name: []const u8, tuple: []const u8) !void {
        try spaceTuple(buf, .replace, sync, stream_id, space_name, tuple);
    }

    /// INSERT/REPLACE share the body `{SPACE_NAME, TUPLE}`; only the type differs.
    fn spaceTuple(buf: *msgpack.Buffer, rtype: RequestType, sync: u64, stream_id: ?u64, space_name: []const u8, tuple: []const u8) !void {
        const pos = try beginRequest(buf, rtype, sync, stream_id);
        try putMapHeader(buf, 2);
        try msgpack.encode(buf, Key.space_name);
        try msgpack.encode(buf, space_name);
        try msgpack.encode(buf, Key.tuple);
        try buf.writeAll(tuple);
        endFrame(buf, pos);
    }

    /// UPDATE (0x04) autocommit: space/index by name, a pre-encoded key array, and
    /// the operations array. On the wire the ops ride under TUPLE (0x21) — UPDATE
    /// does not use OPS (0x28); that key is UPSERT-only. A null `index_name`
    /// OMITS the INDEX_NAME key so the server defaults to the primary index.
    pub fn update(
        buf: *msgpack.Buffer,
        sync: u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        key: []const u8,
        ops: []const u8,
    ) !void {
        try updateStream(buf, sync, null, space_name, index_name, key, ops);
    }

    /// UPDATE bound to `stream_id` (interactive transaction).
    pub fn updateStream(
        buf: *msgpack.Buffer,
        sync: u64,
        stream_id: ?u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        key: []const u8,
        ops: []const u8,
    ) !void {
        const pos = try beginRequest(buf, .update, sync, stream_id);
        try putMapHeader(buf, if (index_name != null) 4 else 3);
        try msgpack.encode(buf, Key.space_name);
        try msgpack.encode(buf, space_name);
        if (index_name) |name| {
            try msgpack.encode(buf, Key.index_name);
            try msgpack.encode(buf, name);
        }
        try msgpack.encode(buf, Key.key);
        try buf.writeAll(key);
        try msgpack.encode(buf, Key.tuple);
        try buf.writeAll(ops);
        endFrame(buf, pos);
    }

    /// DELETE (0x05) autocommit: space/index by name + a pre-encoded key array. A
    /// null `index_name` OMITS the INDEX_NAME key so the server defaults to the
    /// primary index.
    pub fn delete(
        buf: *msgpack.Buffer,
        sync: u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        key: []const u8,
    ) !void {
        try deleteStream(buf, sync, null, space_name, index_name, key);
    }

    /// DELETE bound to `stream_id` (interactive transaction).
    pub fn deleteStream(
        buf: *msgpack.Buffer,
        sync: u64,
        stream_id: ?u64,
        space_name: []const u8,
        index_name: ?[]const u8,
        key: []const u8,
    ) !void {
        const pos = try beginRequest(buf, .delete, sync, stream_id);
        try putMapHeader(buf, if (index_name != null) 3 else 2);
        try msgpack.encode(buf, Key.space_name);
        try msgpack.encode(buf, space_name);
        if (index_name) |name| {
            try msgpack.encode(buf, Key.index_name);
            try msgpack.encode(buf, name);
        }
        try msgpack.encode(buf, Key.key);
        try buf.writeAll(key);
        endFrame(buf, pos);
    }

    /// UPSERT (0x09) autocommit: space by name, the tuple to insert (TUPLE 0x21),
    /// and the operations to apply on conflict (OPS 0x28). Always uses the primary
    /// key, so no index name.
    pub fn upsert(
        buf: *msgpack.Buffer,
        sync: u64,
        space_name: []const u8,
        tuple: []const u8,
        ops: []const u8,
    ) !void {
        try upsertStream(buf, sync, null, space_name, tuple, ops);
    }

    /// UPSERT bound to `stream_id` (interactive transaction).
    pub fn upsertStream(
        buf: *msgpack.Buffer,
        sync: u64,
        stream_id: ?u64,
        space_name: []const u8,
        tuple: []const u8,
        ops: []const u8,
    ) !void {
        const pos = try beginRequest(buf, .upsert, sync, stream_id);
        try putMapHeader(buf, 3);
        try msgpack.encode(buf, Key.space_name);
        try msgpack.encode(buf, space_name);
        try msgpack.encode(buf, Key.tuple);
        try buf.writeAll(tuple);
        try msgpack.encode(buf, Key.ops);
        try buf.writeAll(ops);
        endFrame(buf, pos);
    }

    /// CALL (0x0a): function name + a pre-encoded args array (under TUPLE 0x21).
    /// Never CALL_16 (0x06).
    pub fn call(buf: *msgpack.Buffer, sync: u64, function_name: []const u8, args: []const u8) !void {
        const pos = try beginRequest(buf, .call, sync, null);
        try putMapHeader(buf, 2);
        try msgpack.encode(buf, Key.function_name);
        try msgpack.encode(buf, function_name);
        try msgpack.encode(buf, Key.tuple);
        try buf.writeAll(args);
        endFrame(buf, pos);
    }

    /// EVAL (0x08): Lua expression + a pre-encoded args array (under TUPLE 0x21).
    pub fn eval(buf: *msgpack.Buffer, sync: u64, expr: []const u8, args: []const u8) !void {
        const pos = try beginRequest(buf, .eval, sync, null);
        try putMapHeader(buf, 2);
        try msgpack.encode(buf, Key.expr);
        try msgpack.encode(buf, expr);
        try msgpack.encode(buf, Key.tuple);
        try buf.writeAll(args);
        endFrame(buf, pos);
    }

    /// WATCH (0x4a): register/re-arm interest in `key`. Body `{EVENT_KEY: key}`.
    /// Fire-and-forget — the server sends NO response, only an asynchronous EVENT
    /// (0x4c) when the key is broadcast. Re-sending WATCH is the ack that re-arms
    /// delivery (watcher pump model).
    pub fn watch(buf: *msgpack.Buffer, sync: u64, key: []const u8) !void {
        try eventKeyRequest(buf, .watch, sync, key);
    }

    /// UNWATCH (0x4b): drop interest in `key`. Body `{EVENT_KEY: key}`.
    /// Fire-and-forget (no response). After this the server sends no further
    /// EVENTs for `key` on this connection.
    pub fn unwatch(buf: *msgpack.Buffer, sync: u64, key: []const u8) !void {
        try eventKeyRequest(buf, .unwatch, sync, key);
    }

    /// WATCH_ONCE (0x4d): request the current value of `key` as an ordinary
    /// request/response (no watcher registration, no re-arm). Body
    /// `{EVENT_KEY: key}`; the reply carries the value under IPROTO_DATA (0x30).
    pub fn watchOnce(buf: *msgpack.Buffer, sync: u64, key: []const u8) !void {
        try eventKeyRequest(buf, .watch_once, sync, key);
    }

    /// WATCH/UNWATCH/WATCH_ONCE share the body `{EVENT_KEY: key}`; only the type
    /// differs. `key` goes on the wire as MP_STR.
    fn eventKeyRequest(buf: *msgpack.Buffer, rtype: RequestType, sync: u64, key: []const u8) !void {
        const pos = try beginRequest(buf, rtype, sync, null);
        try putMapHeader(buf, 1);
        try msgpack.encode(buf, Key.event_key);
        try msgpack.encode(buf, key);
        endFrame(buf, pos);
    }
};

// ---------------------------------------------------------------------------
// Frame reader + header decode
// ---------------------------------------------------------------------------

/// A framed packet split from an input buffer: the payload is the header MP_MAP
/// followed by the body MP_MAP (everything after the size prefix).
pub const Frame = struct {
    /// header MP_MAP ++ body MP_MAP (the packet bytes after the size prefix).
    payload: []const u8,
    /// Total bytes consumed from the input (size prefix + payload length).
    consumed: usize,
};

/// Decoded request/response header. `schema_version` is present on responses
/// (SCHEMA_VERSION 0x05) and absent on requests.
pub const Header = struct {
    type: u32,
    sync: u64,
    schema_version: ?u64,
};

/// Read the size prefix — *any* MP_UINT, not just the `0xce` form we write —
/// and return the packet payload plus total bytes consumed. A payload shorter
/// than the declared size is `error.Truncated`.
pub fn readFrame(bytes: []const u8) ParseError!Frame {
    var dec = msgpack.Decoder.init(bytes);
    const size = try msgpack.decode(u64, &dec);
    const start = dec.pos;
    if (start + size > bytes.len) return error.Truncated;
    return .{ .payload = bytes[start .. start + size], .consumed = start + size };
}

/// msgpack.zig does not expose a map-header *reader* (its `readMapHeader` is
/// private), so this reads the one framing token the parser needs. Value bytes
/// are still handled entirely by the codec (`decode`, `decodeValue`).
fn readMapLen(dec: *msgpack.Decoder) ParseError!usize {
    if (dec.pos >= dec.buf.len) return error.Truncated;
    const t = dec.buf[dec.pos];
    dec.pos += 1;
    if (t & 0xf0 == 0x80) return t & 0x0f;
    switch (t) {
        0xde => {
            if (dec.pos + 2 > dec.buf.len) return error.Truncated;
            const v = std.mem.readInt(u16, dec.buf[dec.pos..][0..2], .big);
            dec.pos += 2;
            return v;
        },
        0xdf => {
            if (dec.pos + 4 > dec.buf.len) return error.Truncated;
            const v = std.mem.readInt(u32, dec.buf[dec.pos..][0..4], .big);
            dec.pos += 4;
            return v;
        },
        else => return error.NotMap,
    }
}

/// Advance `dec` past one complete msgpack value and return its raw byte span.
/// Uses the codec's own walker (`decodeValue`) so no token logic is duplicated;
/// the transient container allocation is freed immediately.
fn captureValue(gpa: std.mem.Allocator, dec: *msgpack.Decoder) ParseError![]const u8 {
    const start = dec.pos;
    const v = try dec.decodeValue(gpa);
    msgpack.freeValue(gpa, v);
    return dec.buf[start..dec.pos];
}

/// Read an N-byte big-endian unsigned length prefix off `dec` and advance.
fn readLen(dec: *msgpack.Decoder, comptime nbytes: usize) ParseError!usize {
    if (dec.pos + nbytes > dec.buf.len) return error.Truncated;
    var v: usize = 0;
    inline for (0..nbytes) |i| v = (v << 8) | dec.buf[dec.pos + i];
    dec.pos += nbytes;
    return v;
}

/// Advance `dec` past exactly `n` payload bytes (bounds-checked).
fn eat(dec: *msgpack.Decoder, n: usize) ParseError!void {
    if (dec.pos + n > dec.buf.len) return error.Truncated;
    dec.pos += n;
}

/// Advance `dec` past one complete msgpack value WITHOUT allocating — the
/// no-gpa analog of `captureValue`, used by `parseEvent` (whose pinned signature
/// carries no allocator: EVENT frames are read on the hot path and every
/// returned slice borrows the frame). A structural token walker: it mirrors the
/// codec's type dispatch (`msgpack.Decoder.decodeValue`) but only advances the
/// cursor, recursing over arrays/maps by element count.
fn skipValue(dec: *msgpack.Decoder) ParseError!void {
    if (dec.pos >= dec.buf.len) return error.Truncated;
    const t = dec.buf[dec.pos];
    dec.pos += 1;
    // fixint (positive 0x00–0x7f and negative 0xe0–0xff): no payload.
    if (t < 0x80 or t >= 0xe0) return;
    // fixstr 0xa0–0xbf.
    if (t & 0xe0 == 0xa0) return eat(dec, t & 0x1f);
    // fixarray 0x90–0x9f.
    if (t & 0xf0 == 0x90) {
        var i: usize = 0;
        while (i < (t & 0x0f)) : (i += 1) try skipValue(dec);
        return;
    }
    // fixmap 0x80–0x8f.
    if (t & 0xf0 == 0x80) {
        var i: usize = 0;
        while (i < (t & 0x0f)) : (i += 1) {
            try skipValue(dec);
            try skipValue(dec);
        }
        return;
    }
    switch (t) {
        0xc0, 0xc2, 0xc3 => {}, // nil, false, true
        0xcc, 0xd0 => try eat(dec, 1), // uint8 / int8
        0xcd, 0xd1 => try eat(dec, 2), // uint16 / int16
        0xca, 0xce, 0xd2 => try eat(dec, 4), // float32 / uint32 / int32
        0xcb, 0xcf, 0xd3 => try eat(dec, 8), // float64 / uint64 / int64
        0xc4, 0xd9 => try eat(dec, try readLen(dec, 1)), // bin8 / str8
        0xc5, 0xda => try eat(dec, try readLen(dec, 2)), // bin16 / str16
        0xc6, 0xdb => try eat(dec, try readLen(dec, 4)), // bin32 / str32
        0xd4 => try eat(dec, 1 + 1), // fixext1 (type + 1 byte)
        0xd5 => try eat(dec, 1 + 2), // fixext2
        0xd6 => try eat(dec, 1 + 4), // fixext4
        0xd7 => try eat(dec, 1 + 8), // fixext8
        0xd8 => try eat(dec, 1 + 16), // fixext16
        0xc7 => try eat(dec, 1 + try readLen(dec, 1)), // ext8  (len, type, data)
        0xc8 => try eat(dec, 1 + try readLen(dec, 2)), // ext16
        0xc9 => try eat(dec, 1 + try readLen(dec, 4)), // ext32
        0xdc => {
            const n = try readLen(dec, 2);
            var i: usize = 0;
            while (i < n) : (i += 1) try skipValue(dec);
        },
        0xdd => {
            const n = try readLen(dec, 4);
            var i: usize = 0;
            while (i < n) : (i += 1) try skipValue(dec);
        },
        0xde => {
            const n = try readLen(dec, 2);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try skipValue(dec);
                try skipValue(dec);
            }
        },
        0xdf => {
            const n = try readLen(dec, 4);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try skipValue(dec);
                try skipValue(dec);
            }
        },
        else => return error.Truncated, // 0xc1 (never-used) and any gap
    }
}

/// Advance `dec` past one complete msgpack value and return its raw byte span,
/// without allocating (the no-gpa analog of `captureValue`, over `skipValue`).
fn spanOf(dec: *msgpack.Decoder) ParseError![]const u8 {
    const start = dec.pos;
    try skipValue(dec);
    return dec.buf[start..dec.pos];
}

/// Decode a header map off `dec`. Recognises REQUEST_TYPE, SYNC, and
/// SCHEMA_VERSION; any other key is skipped (its value walked and discarded via
/// the codec). REQUEST_TYPE and SYNC are mandatory — their absence is
/// `error.MalformedFrame`.
pub fn decodeHeader(gpa: std.mem.Allocator, dec: *msgpack.Decoder) ParseError!Header {
    const n = try readMapLen(dec);
    var rtype: ?u32 = null;
    var sync: ?u64 = null;
    var schema: ?u64 = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = try msgpack.decode(u8, dec);
        switch (k) {
            @backingInt(Key.request_type) => rtype = try msgpack.decode(u32, dec),
            @backingInt(Key.sync) => sync = try msgpack.decode(u64, dec),
            @backingInt(Key.schema_version) => schema = try msgpack.decode(u64, dec),
            else => msgpack.freeValue(gpa, try dec.decodeValue(gpa)),
        }
    }
    return .{
        .type = rtype orelse return error.MalformedFrame,
        .sync = sync orelse return error.MalformedFrame,
        .schema_version = schema,
    };
}

// ---------------------------------------------------------------------------
// Response envelope parser
// ---------------------------------------------------------------------------

/// A server error response: the low 15 bits of the response type (`code`), the
/// always-present plain ERROR_24 message, and the structured MP_ERROR stack
/// kept as raw msgpack bytes (no typed decode in v1) — null if the server
/// omitted it (pre-error_extension peers).
pub const ResponseError = struct {
    code: u32,
    message: []const u8,
    stack: ?[]const u8,
};

/// The body outcome: `ok` carries the DATA (0x30) payload as raw bytes, or null
/// when the response has no DATA (e.g. PING, a mutation with no return); `err`
/// carries the decoded error envelope.
pub const Result = union(enum) {
    ok: ?[]const u8,
    err: ResponseError,
};

/// A fully parsed response frame. All slices (message, DATA, ERROR stack) borrow
/// from the input `frame` bytes — they do not outlive it.
pub const Response = struct {
    sync: u64,
    schema_version: ?u64,
    result: Result,
};

/// Parse a complete response frame into its envelope. The ok/error split is
/// driven by the header type: a CHUNK (0x80) is `error.ProtocolError` (out of
/// scope in v1); `TYPE_ERROR`-masked types produce `.err` (ERROR_24 required,
/// ERROR 0x52 kept raw); everything else is `.ok` with the raw DATA (or null).
///
/// `gpa` backs only transient walks of skipped/raw values; every returned slice
/// borrows from `frame`.
pub fn parseResponse(gpa: std.mem.Allocator, frame: []const u8) ParseError!Response {
    const fr = try readFrame(frame);
    var dec = msgpack.Decoder.init(fr.payload);
    const hdr = try decodeHeader(gpa, &dec);

    if (hdr.type == @backingInt(RequestType.chunk)) return error.ProtocolError;

    const n = try readMapLen(&dec);
    var data: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var stack: ?[]const u8 = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = try msgpack.decode(u8, &dec);
        switch (k) {
            @backingInt(Key.data) => data = try captureValue(gpa, &dec),
            @backingInt(Key.error_24) => message = try msgpack.decode([]const u8, &dec),
            @backingInt(Key.err) => stack = try captureValue(gpa, &dec),
            else => msgpack.freeValue(gpa, try dec.decodeValue(gpa)),
        }
    }

    if (isError(hdr.type)) {
        return .{
            .sync = hdr.sync,
            .schema_version = hdr.schema_version,
            // ERROR_24 is always present on an error response; its absence
            // is a malformed frame, not a defaulted-empty message.
            .result = .{ .err = .{
                .code = errorCode(hdr.type),
                .message = message orelse return error.MalformedFrame,
                .stack = stack,
            } },
        };
    }
    return .{ .sync = hdr.sync, .schema_version = hdr.schema_version, .result = .{ .ok = data } };
}

// ---------------------------------------------------------------------------
// EVENT frame parser (watcher notifications)
// ---------------------------------------------------------------------------

/// A decoded watcher notification (an EVENT 0x4c frame's body). `key` is the
/// notified key name (EVENT_KEY 0x57, always present); `data` is the current
/// payload as raw msgpack (EVENT_DATA 0x58), or null when the key holds no
/// value. Both slices borrow the input `frame` — the caller must copy them to
/// retain past the frame's lifetime (the connection's mailbox owns copies).
pub const Event = struct {
    key: []const u8,
    data: ?[]const u8,
};

/// Parse an EVENT frame's body. The header (already known to be EVENT-typed by
/// the read loop) is walked and discarded; the body must carry EVENT_KEY
/// (absence is `error.MalformedFrame`) and may carry EVENT_DATA (kept raw). No
/// allocator: every returned slice borrows `frame` (see `Event`). This does not
/// touch `parseResponse` — the read loop peeks the header type and routes EVENT
/// frames here instead.
pub fn parseEvent(frame: []const u8) ParseError!Event {
    const fr = try readFrame(frame);
    var dec = msgpack.Decoder.init(fr.payload);

    // Walk past the header map (REQUEST_TYPE/SYNC[/SCHEMA_VERSION]); its values
    // are irrelevant to the notification body.
    const hn = try readMapLen(&dec);
    var h: usize = 0;
    while (h < hn) : (h += 1) {
        try skipValue(&dec); // key
        try skipValue(&dec); // value
    }

    const n = try readMapLen(&dec);
    var key: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = try msgpack.decode(u8, &dec);
        switch (k) {
            @backingInt(Key.event_key) => key = try msgpack.decode([]const u8, &dec),
            @backingInt(Key.event_data) => data = try spanOf(&dec),
            else => try skipValue(&dec),
        }
    }
    return .{ .key = key orelse return error.MalformedFrame, .data = data };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isError over OK, error type, and boundaries" {
    try std.testing.expect(!isError(@backingInt(RequestType.ok)));
    try std.testing.expect(!isError(@backingInt(RequestType.select)));
    try std.testing.expect(!isError(0x7fff)); // top non-error value
    try std.testing.expect(isError(TYPE_ERROR)); // code 0 error
    try std.testing.expect(isError(TYPE_ERROR | 9));
    try std.testing.expect(isError(0xffff));
}

test "errorCode strips the error mask" {
    try std.testing.expectEqual(@as(u32, 9), errorCode(TYPE_ERROR | 9));
    try std.testing.expectEqual(@as(u32, 0), errorCode(TYPE_ERROR));
    try std.testing.expectEqual(@as(u32, 0x7fff), errorCode(0xffff));
    // ER_WRONG_SCHEMA_VERSION (109) as an error type.
    try std.testing.expectEqual(@as(u32, 109), errorCode(TYPE_ERROR | 109));
}

test "RequestType values pinned from box.iproto.type" {
    try std.testing.expectEqual(@as(u32, 0x00), @backingInt(RequestType.ok));
    try std.testing.expectEqual(@as(u32, 0x01), @backingInt(RequestType.select));
    try std.testing.expectEqual(@as(u32, 0x07), @backingInt(RequestType.auth));
    try std.testing.expectEqual(@as(u32, 0x0a), @backingInt(RequestType.call));
    try std.testing.expectEqual(@as(u32, 0x40), @backingInt(RequestType.ping));
    try std.testing.expectEqual(@as(u32, 0x49), @backingInt(RequestType.id));
    try std.testing.expectEqual(@as(u32, 0x80), @backingInt(RequestType.chunk));
    // Watch/stream additions — pinned from the live box.iproto.type dump (3.8.0).
    try std.testing.expectEqual(@as(u32, 0x0e), @backingInt(RequestType.begin));
    try std.testing.expectEqual(@as(u32, 0x0f), @backingInt(RequestType.commit));
    try std.testing.expectEqual(@as(u32, 0x10), @backingInt(RequestType.rollback));
    try std.testing.expectEqual(@as(u32, 0x4a), @backingInt(RequestType.watch));
    try std.testing.expectEqual(@as(u32, 0x4b), @backingInt(RequestType.unwatch));
    try std.testing.expectEqual(@as(u32, 0x4c), @backingInt(RequestType.event));
    try std.testing.expectEqual(@as(u32, 0x4d), @backingInt(RequestType.watch_once));
    // Non-exhaustive: an unknown/replication type decodes without trapping.
    try std.testing.expectEqual(@as(u32, 66), @backingInt(@as(RequestType, @fromBackingInt(@intCast(66)))));
}

test "Key values pinned from box.iproto.key" {
    try std.testing.expectEqual(@as(u8, 0x00), @backingInt(Key.request_type));
    try std.testing.expectEqual(@as(u8, 0x01), @backingInt(Key.sync));
    try std.testing.expectEqual(@as(u8, 0x21), @backingInt(Key.tuple));
    try std.testing.expectEqual(@as(u8, 0x23), @backingInt(Key.user_name));
    try std.testing.expectEqual(@as(u8, 0x31), @backingInt(Key.error_24));
    try std.testing.expectEqual(@as(u8, 0x52), @backingInt(Key.err));
    try std.testing.expectEqual(@as(u8, 0x5b), @backingInt(Key.auth_type));
    try std.testing.expectEqual(@as(u8, 0x5e), @backingInt(Key.space_name));
    try std.testing.expectEqual(@as(u8, 0x5f), @backingInt(Key.index_name));
    // Watch/stream additions — pinned from the live box.iproto.key dump (3.8.0).
    try std.testing.expectEqual(@as(u8, 0x0a), @backingInt(Key.stream_id));
    try std.testing.expectEqual(@as(u8, 0x57), @backingInt(Key.event_key));
    try std.testing.expectEqual(@as(u8, 0x58), @backingInt(Key.event_data));
}

test "Feature bits pinned from box.iproto.feature" {
    try std.testing.expectEqual(@as(u6, 2), @backingInt(Feature.error_extension));
    try std.testing.expectEqual(@as(u6, 5), @backingInt(Feature.space_and_index_names));
    try std.testing.expectEqual(@as(u6, 0), @backingInt(Feature.streams));
    try std.testing.expectEqual(@as(u6, 12), @backingInt(Feature.insert_arrow));
}

// ---------------------------------------------------------------------------
// Framing tests
//
// Fixture provenance: byte-equality fixtures marked `// oracle:` were
// cross-generated with the live Tarantool 3.8.0 `require('msgpack').encode`
// (bodies assembled by explicit per-token concatenation in this module's
// documented key order — every leaf token is what tarantool emits). The client
// integration tests re-assert the wire against the live server end to end.
// ---------------------------------------------------------------------------

/// Body of a request frame built with a 1-byte type and a 1-byte sync: the
/// header is exactly `82 00 <type> 01 <sync>` (5 bytes) after the 5-byte size
/// prefix, so the body starts at offset 10.
fn bodyOf(buf: *const msgpack.Buffer) []const u8 {
    return buf.items()[10..];
}

test "ping frame matches full tarantool oracle (size+header+empty body)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try request.ping(&buf, 7);
    // oracle: ce 00 00 00 06 82 00 40 01 07 80
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x06, 0x82, 0x00, 0x40, 0x01, 0x07, 0x80 };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
}

test "watch frame matches full tarantool oracle (size+header+{EVENT_KEY:key})" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try request.watch(&buf, 7, "k");
    // oracle: ce 00 00 00 09 82 00 4a 01 07 81 57 a1 6b
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x09, 0x82, 0x00, 0x4a, 0x01, 0x07, 0x81, 0x57, 0xa1, 0x6b };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
}

test "unwatch/watch_once share the WATCH body; only the header type differs" {
    var w = msgpack.Buffer.init(std.testing.allocator);
    defer w.deinit();
    try request.watch(&w, 7, "k");
    var u = msgpack.Buffer.init(std.testing.allocator);
    defer u.deinit();
    try request.unwatch(&u, 7, "k");
    var o = msgpack.Buffer.init(std.testing.allocator);
    defer o.deinit();
    try request.watchOnce(&o, 7, "k");

    // Bodies (after the 5-byte size prefix + 5-byte header) are byte-identical.
    try std.testing.expectEqualSlices(u8, w.items()[10..], u.items()[10..]);
    try std.testing.expectEqualSlices(u8, w.items()[10..], o.items()[10..]);
    // Header type bytes: WATCH 0x4a, UNWATCH 0x4b, WATCH_ONCE 0x4d.
    try std.testing.expectEqual(@as(u8, 0x4a), w.items()[7]);
    try std.testing.expectEqual(@as(u8, 0x4b), u.items()[7]);
    try std.testing.expectEqual(@as(u8, 0x4d), o.items()[7]);
}

test "id body matches oracle {VERSION:10, FEATURES:[0,1,2,3,5,6]}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try request.id(&buf, 1, &v1_features);
    // oracle: 82 54 0a 55 96 00 01 02 03 05 06 (streams, transactions,
    // error_extension, watchers, space_and_index_names, watch_once — the v1
    // client's advertised set)
    const expected = [_]u8{ 0x82, 0x54, 0x0a, 0x55, 0x96, 0x00, 0x01, 0x02, 0x03, 0x05, 0x06 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x49), buf.items()[7]); // ID type in header
}

test "auth body matches oracle {USER_NAME, TUPLE:[chap-sha1, scramble]}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const scramble: [20]u8 = @splat(0xab);
    try request.auth(&buf, 1, "u", &scramble);
    // oracle: 82 23 a1 75 21 92 a9 63686170...31 b4 ab*20
    const expected = [_]u8{ 0x82, 0x23, 0xa1, 0x75, 0x21, 0x92, 0xa9 } ++
        "chap-sha1".* ++ [_]u8{0xb4} ++ @as([20]u8, @splat(0xab));
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x07), buf.items()[7]); // AUTH type
}

test "select body matches oracle {space,index,iterator,limit,offset,key}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 }; // pre-encoded [1]
    try request.select(&buf, 1, "s", "pk", .eq, 100, 0, &key);
    // oracle: 86 5e a1 73 5f a2 70 6b 14 00 12 64 13 00 20 91 01
    const expected = [_]u8{ 0x86, 0x5e, 0xa1, 0x73, 0x5f, 0xa2, 0x70, 0x6b, 0x14, 0x00, 0x12, 0x64, 0x13, 0x00, 0x20, 0x91, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x01), buf.items()[7]); // SELECT type
}

test "insert/replace body matches oracle {SPACE_NAME, TUPLE}" {
    const tuple = [_]u8{ 0x92, 0x01, 0x02 }; // pre-encoded [1,2]
    // oracle: 82 5e a1 73 21 92 01 02
    const expected = [_]u8{ 0x82, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02 };

    var ins = msgpack.Buffer.init(std.testing.allocator);
    defer ins.deinit();
    try request.insert(&ins, 1, "s", &tuple);
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&ins));
    try std.testing.expectEqual(@as(u8, 0x02), ins.items()[7]); // INSERT type

    var rep = msgpack.Buffer.init(std.testing.allocator);
    defer rep.deinit();
    try request.replace(&rep, 1, "s", &tuple);
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&rep));
    try std.testing.expectEqual(@as(u8, 0x03), rep.items()[7]); // REPLACE type
}

test "update body matches oracle {space,index,KEY,TUPLE:ops}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 };
    const ops = [_]u8{ 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 }; // [['+',2,1]]
    try request.update(&buf, 1, "s", "pk", &key, &ops);
    // oracle: 84 5e a1 73 5f a2 70 6b 20 91 01 21 91 93 a1 2b 02 01
    const expected = [_]u8{ 0x84, 0x5e, 0xa1, 0x73, 0x5f, 0xa2, 0x70, 0x6b, 0x20, 0x91, 0x01, 0x21, 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x04), buf.items()[7]); // UPDATE type
}

test "delete body matches oracle {space,index,KEY}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 };
    try request.delete(&buf, 1, "s", "pk", &key);
    // oracle: 83 5e a1 73 5f a2 70 6b 20 91 01
    const expected = [_]u8{ 0x83, 0x5e, 0xa1, 0x73, 0x5f, 0xa2, 0x70, 0x6b, 0x20, 0x91, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x05), buf.items()[7]); // DELETE type
}

// --- optional INDEX_NAME: null omits the key, server defaults to index 0 ---
//
// Oracle leaves cross-generated with live Tarantool 3.8.0 `msgpack.encode`
// (per-token, in this module's documented key order); the map header drops by
// one vs. the with-name form above. The with-name form stays covered by the
// unchanged tests above.

test "select body OMITS INDEX_NAME when index_name is null (map 5)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 }; // pre-encoded [1]
    try request.select(&buf, 1, "s", null, .eq, 100, 0, &key);
    // oracle: 85 5e a1 73 14 00 12 64 13 00 20 91 01
    const expected = [_]u8{ 0x85, 0x5e, 0xa1, 0x73, 0x14, 0x00, 0x12, 0x64, 0x13, 0x00, 0x20, 0x91, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x01), buf.items()[7]); // SELECT type
}

test "update body OMITS INDEX_NAME when index_name is null (map 3)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 };
    const ops = [_]u8{ 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 }; // [['+',2,1]]
    try request.update(&buf, 1, "s", null, &key, &ops);
    // oracle: 83 5e a1 73 20 91 01 21 91 93 a1 2b 02 01
    const expected = [_]u8{ 0x83, 0x5e, 0xa1, 0x73, 0x20, 0x91, 0x01, 0x21, 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x04), buf.items()[7]); // UPDATE type
}

test "delete body OMITS INDEX_NAME when index_name is null (map 2)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 };
    try request.delete(&buf, 1, "s", null, &key);
    // oracle: 82 5e a1 73 20 91 01
    const expected = [_]u8{ 0x82, 0x5e, 0xa1, 0x73, 0x20, 0x91, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x05), buf.items()[7]); // DELETE type
}

test "upsert body matches oracle {SPACE_NAME, TUPLE, OPS}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const tuple = [_]u8{ 0x92, 0x01, 0x02 };
    const ops = [_]u8{ 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 };
    try request.upsert(&buf, 1, "s", &tuple, &ops);
    // oracle: 83 5e a1 73 21 92 01 02 28 91 93 a1 2b 02 01
    const expected = [_]u8{ 0x83, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02, 0x28, 0x91, 0x93, 0xa1, 0x2b, 0x02, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, bodyOf(&buf));
    try std.testing.expectEqual(@as(u8, 0x09), buf.items()[7]); // UPSERT type
}

test "call/eval bodies match oracle (args under TUPLE 0x21)" {
    const args = [_]u8{ 0x92, 0x01, 0x02 }; // [1,2]
    var c = msgpack.Buffer.init(std.testing.allocator);
    defer c.deinit();
    try request.call(&c, 1, "f", &args);
    // oracle: 82 22 a1 66 21 92 01 02
    const call_expected = [_]u8{ 0x82, 0x22, 0xa1, 0x66, 0x21, 0x92, 0x01, 0x02 };
    try std.testing.expectEqualSlices(u8, &call_expected, bodyOf(&c));
    try std.testing.expectEqual(@as(u8, 0x0a), c.items()[7]); // CALL type

    var e = msgpack.Buffer.init(std.testing.allocator);
    defer e.deinit();
    const no_args = [_]u8{0x90}; // []
    try request.eval(&e, 1, "return 1", &no_args);
    // oracle: 82 27 a8 72 65 74 75 72 6e 20 31 21 90
    const eval_expected = [_]u8{ 0x82, 0x27, 0xa8 } ++ "return 1".* ++ [_]u8{ 0x21, 0x90 };
    try std.testing.expectEqualSlices(u8, &eval_expected, bodyOf(&e));
    try std.testing.expectEqual(@as(u8, 0x08), e.items()[7]); // EVAL type
}

test "beginFrame/endFrame backpatch the 0xce+u32BE size prefix" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const pos = try beginFrame(&buf);
    try buf.writeAll(&[_]u8{ 0xaa, 0xbb, 0xcc }); // 3-byte packet
    endFrame(&buf, pos);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xce, 0x00, 0x00, 0x00, 0x03, 0xaa, 0xbb, 0xcc }, buf.items());
}

test "readFrame accepts a non-0xce MP_UINT size (fixint prefix)" {
    // A size written as a positive fixint, not the 0xce form we emit.
    const bytes = [_]u8{ 0x03, 0xaa, 0xbb, 0xcc };
    const fr = try readFrame(&bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0xcc }, fr.payload);
    try std.testing.expectEqual(@as(usize, 4), fr.consumed);
}

test "readFrame reports Truncated on a short payload" {
    const bytes = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x10, 0x01 }; // claims 16, has 1
    try std.testing.expectError(error.Truncated, readFrame(&bytes));
}

test "round-trip: build then read back header (type/sync/schema)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try request.ping(&buf, 12345); // multi-byte sync
    const fr = try readFrame(buf.items());
    var dec = msgpack.Decoder.init(fr.payload);
    const hdr = try decodeHeader(std.testing.allocator, &dec);
    try std.testing.expectEqual(@as(u32, @backingInt(RequestType.ping)), hdr.type);
    try std.testing.expectEqual(@as(u64, 12345), hdr.sync);
    try std.testing.expectEqual(@as(?u64, null), hdr.schema_version); // requests carry no schema
}

test "decodeHeader requires REQUEST_TYPE and SYNC" {
    // A header map with only SYNC -> MalformedFrame.
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try putMapHeader(&buf, 1);
    try msgpack.encode(&buf, Key.sync);
    try msgpack.encode(&buf, @as(u64, 9));
    var dec = msgpack.Decoder.init(buf.items());
    try std.testing.expectError(error.MalformedFrame, decodeHeader(std.testing.allocator, &dec));
}

test "parseResponse OK frame -> raw DATA slice, sync, schema" {
    // oracle OK frame: header {TYPE:0, SYNC:5, SCHEMA:42}, body {DATA:[[1,'x']]}
    const frame = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x0e, 0x83, 0x00, 0x00, 0x01, 0x05, 0x05, 0x2a, 0x81, 0x30, 0x91, 0x92, 0x01, 0xa1, 0x78 };
    const resp = try parseResponse(std.testing.allocator, &frame);
    try std.testing.expectEqual(@as(u64, 5), resp.sync);
    try std.testing.expectEqual(@as(?u64, 42), resp.schema_version);
    switch (resp.result) {
        .ok => |data| {
            // oracle DATA raw: 91 92 01 a1 78 ([[1,'x']])
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x91, 0x92, 0x01, 0xa1, 0x78 }, data.?);
        },
        .err => return error.TestUnexpectedError,
    }
}

test "parseResponse error frame -> code, ERROR_24 message, raw ERROR stack" {
    // oracle ERR frame: header {TYPE:0x8005, SYNC:3, SCHEMA:99},
    // body {ERROR_24:'boom', ERROR:{0:[]}}
    const frame = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x14, 0x83, 0x00, 0xcd, 0x80, 0x05, 0x01, 0x03, 0x05, 0x63, 0x82, 0x31, 0xa4, 0x62, 0x6f, 0x6f, 0x6d, 0x52, 0x81, 0x00, 0x90 };
    const resp = try parseResponse(std.testing.allocator, &frame);
    try std.testing.expectEqual(@as(u64, 3), resp.sync);
    try std.testing.expectEqual(@as(?u64, 99), resp.schema_version);
    switch (resp.result) {
        .ok => return error.TestUnexpectedError,
        .err => |e| {
            try std.testing.expectEqual(@as(u32, 5), e.code);
            try std.testing.expectEqualStrings("boom", e.message);
            // ERROR 0x52 kept raw: 81 00 90 ({0:[]})
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x00, 0x90 }, e.stack.?);
        },
    }
}

test "parseResponse OK frame with no DATA -> ok(null)" {
    // header {TYPE:0, SYNC:1}, empty body (e.g. a PING reply).
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const pos = try beginFrame(&buf);
    try encodeHeader(&buf, .ok, 1, null);
    try putMapHeader(&buf, 0);
    endFrame(&buf, pos);
    const resp = try parseResponse(std.testing.allocator, buf.items());
    switch (resp.result) {
        .ok => |data| try std.testing.expectEqual(@as(?[]const u8, null), data),
        .err => return error.TestUnexpectedError,
    }
}

test "parseResponse CHUNK type -> ProtocolError" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const pos = try beginFrame(&buf);
    try encodeHeader(&buf, .chunk, 1, null);
    try putMapHeader(&buf, 0);
    endFrame(&buf, pos);
    try std.testing.expectError(error.ProtocolError, parseResponse(std.testing.allocator, buf.items()));
}

// ---------------------------------------------------------------------------
// Watch/stream framing tests
//
// Oracle leaves cross-generated with live Tarantool 3.8.0 `msgpack.encode`
// (per-token, in this module's documented key order — REQUEST_TYPE, SYNC, then
// STREAM_ID for the header; EVENT_KEY, EVENT_DATA for the body).
// ---------------------------------------------------------------------------

test "encodeHeader with stream_id -> 3-entry map {TYPE, SYNC, STREAM_ID}" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try encodeHeader(&buf, .begin, 7, 3);
    // oracle: 83 00 0e 01 07 0a 03
    const expected = [_]u8{ 0x83, 0x00, 0x0e, 0x01, 0x07, 0x0a, 0x03 };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
}

test "encodeHeader with stream_id: COMMIT form" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try encodeHeader(&buf, .commit, 1, 2);
    // oracle: 83 00 0f 01 01 0a 02
    const expected = [_]u8{ 0x83, 0x00, 0x0f, 0x01, 0x01, 0x0a, 0x02 };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
}

test "begin/commit/rollback frames match tarantool oracle (header+STREAM_ID+empty body)" {
    // oracle (live tarantool msgpack.encode, per-token): size ++ 3-entry header
    // {TYPE,SYNC,STREAM_ID} ++ empty body 0x80.
    var b = msgpack.Buffer.init(std.testing.allocator);
    defer b.deinit();
    try request.begin(&b, 7, 3);
    // oracle: ce 00 00 00 08 83 00 0e 01 07 0a 03 80
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xce, 0x00, 0x00, 0x00, 0x08, 0x83, 0x00, 0x0e, 0x01, 0x07, 0x0a, 0x03, 0x80 }, b.items());

    var c = msgpack.Buffer.init(std.testing.allocator);
    defer c.deinit();
    try request.commit(&c, 1, 2);
    // oracle: ce 00 00 00 08 83 00 0f 01 01 0a 02 80
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xce, 0x00, 0x00, 0x00, 0x08, 0x83, 0x00, 0x0f, 0x01, 0x01, 0x0a, 0x02, 0x80 }, c.items());

    var r = msgpack.Buffer.init(std.testing.allocator);
    defer r.deinit();
    try request.rollback(&r, 5, 9);
    // oracle: ce 00 00 00 08 83 00 10 01 05 0a 09 80
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xce, 0x00, 0x00, 0x00, 0x08, 0x83, 0x00, 0x10, 0x01, 0x05, 0x0a, 0x09, 0x80 }, r.items());
}

test "insert with stream_id carries STREAM_ID in the header, body unchanged" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const tuple = [_]u8{ 0x92, 0x01, 0x02 }; // pre-encoded [1,2]
    try request.insertStream(&buf, 1, 4, "s", &tuple);
    // oracle (live): ce 00 00 00 0f 83 00 02 01 01 0a 04 82 5e a1 73 21 92 01 02
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x0f, 0x83, 0x00, 0x02, 0x01, 0x01, 0x0a, 0x04, 0x82, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02 };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
    // header carries STREAM_ID (0x0a) — parse it back via decodeHeader (which
    // walks unknown keys, so STREAM_ID rides through) and confirm type/sync.
    const fr = try readFrame(buf.items());
    var dec = msgpack.Decoder.init(fr.payload);
    const hdr = try decodeHeader(std.testing.allocator, &dec);
    try std.testing.expectEqual(@as(u32, @backingInt(RequestType.insert)), hdr.type);
    try std.testing.expectEqual(@as(u64, 1), hdr.sync);
    // body still {SPACE_NAME 's', TUPLE [1,2]} — the stream_id lives in the header.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02 }, buf.items()[12..]);
}

test "select with stream_id: STREAM_ID header, body identical to the null form" {
    // The frameGet shape (eq, limit 2, offset 0, primary index).
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const key = [_]u8{ 0x91, 0x01 };
    try request.selectStream(&buf, 1, 4, "s", null, .eq, 2, 0, &key);
    // oracle (live): ce 00 00 00 14 83 00 01 01 01 0a 04 85 5e a1 73 14 00 12 02 13 00 20 91 01
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x14, 0x83, 0x00, 0x01, 0x01, 0x01, 0x0a, 0x04, 0x85, 0x5e, 0xa1, 0x73, 0x14, 0x00, 0x12, 0x02, 0x13, 0x00, 0x20, 0x91, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected, buf.items());
}

test "encodeHeader stream_id==null is byte-identical to the 2-entry form" {
    // The additive-key proof: null must not perturb the pre-stream bytes.
    var with_null = msgpack.Buffer.init(std.testing.allocator);
    defer with_null.deinit();
    try encodeHeader(&with_null, .begin, 7, null);
    // oracle: 82 00 0e 01 07
    const expected = [_]u8{ 0x82, 0x00, 0x0e, 0x01, 0x07 };
    try std.testing.expectEqualSlices(u8, &expected, with_null.items());
}

/// Build a full EVENT frame (size ++ header ++ body) for parser fixtures: header
/// {REQUEST_TYPE:EVENT, SYNC:0}, body {EVENT_KEY:key} plus EVENT_DATA when
/// `data_mp` is non-null (written verbatim as a pre-encoded value).
fn buildEventFrame(buf: *msgpack.Buffer, key: []const u8, data_mp: ?[]const u8) !void {
    const pos = try beginFrame(buf);
    try encodeHeader(buf, .event, 0, null);
    try putMapHeader(buf, if (data_mp != null) 2 else 1);
    try msgpack.encode(buf, Key.event_key);
    try msgpack.encode(buf, key);
    if (data_mp) |d| {
        try msgpack.encode(buf, Key.event_data);
        try buf.writeAll(d);
    }
    endFrame(buf, pos);
}

test "parseEvent: EVENT_KEY + EVENT_DATA (raw slice borrows frame)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const data = [_]u8{ 0x92, 0x01, 0x02 }; // pre-encoded [1,2]
    try buildEventFrame(&buf, "config.foo", &data);
    // oracle body: 82 57 aa "config.foo" 58 92 01 02
    const expected_body = [_]u8{ 0x82, 0x57, 0xaa } ++ "config.foo".* ++ [_]u8{ 0x58, 0x92, 0x01, 0x02 };
    // body starts after size prefix (5) + header {TYPE:EVENT,SYNC:0} (5 bytes).
    try std.testing.expectEqualSlices(u8, &expected_body, buf.items()[10..]);

    const ev = try parseEvent(buf.items());
    try std.testing.expectEqualStrings("config.foo", ev.key);
    try std.testing.expectEqualSlices(u8, &data, ev.data.?);
}

test "parseEvent: EVENT_KEY only -> data null" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buildEventFrame(&buf, "k", null);
    // oracle body: 81 57 a1 6b
    const expected_body = [_]u8{ 0x81, 0x57, 0xa1, 0x6b };
    try std.testing.expectEqualSlices(u8, &expected_body, buf.items()[10..]);

    const ev = try parseEvent(buf.items());
    try std.testing.expectEqualStrings("k", ev.key);
    try std.testing.expectEqual(@as(?[]const u8, null), ev.data);
}

test "parseEvent: missing EVENT_KEY -> MalformedFrame" {
    // A body carrying only EVENT_DATA (no key) is malformed.
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const pos = try beginFrame(&buf);
    try encodeHeader(&buf, .event, 0, null);
    try putMapHeader(&buf, 1);
    try msgpack.encode(&buf, Key.event_data);
    try msgpack.encode(&buf, @as(u64, 9));
    endFrame(&buf, pos);
    try std.testing.expectError(error.MalformedFrame, parseEvent(buf.items()));
}

test "parseEvent: unknown body key skipped, EVENT_DATA span exact for nested value" {
    // A nested map+array under EVENT_DATA exercises skipValue's recursion; an
    // extra unrecognised key ahead of it must be walked without disturbing the
    // captured span.
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    const pos = try beginFrame(&buf);
    try encodeHeader(&buf, .event, 0, null);
    try putMapHeader(&buf, 3);
    // unknown key 0x7f -> str "zz"
    try msgpack.encode(&buf, @as(u8, 0x7f));
    try msgpack.encode(&buf, @as([]const u8, "zz"));
    try msgpack.encode(&buf, Key.event_key);
    try msgpack.encode(&buf, @as([]const u8, "cfg"));
    try msgpack.encode(&buf, Key.event_data);
    // nested: {1: [10, "x"]} -> 81 01 92 0a a1 78
    const nested = [_]u8{ 0x81, 0x01, 0x92, 0x0a, 0xa1, 0x78 };
    try buf.writeAll(&nested);
    endFrame(&buf, pos);

    const ev = try parseEvent(buf.items());
    try std.testing.expectEqualStrings("cfg", ev.key);
    try std.testing.expectEqualSlices(u8, &nested, ev.data.?);
}

test "decodeHeader decodes an EVENT header (spot-test, gpa path unchanged)" {
    var buf = msgpack.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buildEventFrame(&buf, "k", null);
    const fr = try readFrame(buf.items());
    var dec = msgpack.Decoder.init(fr.payload);
    const hdr = try decodeHeader(std.testing.allocator, &dec);
    try std.testing.expectEqual(@as(u32, @backingInt(RequestType.event)), hdr.type);
    try std.testing.expectEqual(@as(u64, 0), hdr.sync);
}
