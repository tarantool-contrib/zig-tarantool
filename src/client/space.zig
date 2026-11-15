//! `Space` — an infallible value handle over a `Connection` that speaks the
//! data (DML) verbs by SPACE NAME (names-in-DML, no schema fetch).
//!
//! Every method is one proto request builder + one `roundtrip`; this module
//! adds zero wire-format code (client-core carries over). Typed variants
//! encode `anytype` rows/keys positionally to an MP_ARRAY (the `encodeArgs`
//! idiom from connection.zig) and decode the reply's DATA into a comptime
//! `Row` type; `Row == void` discards DATA. Raw variants take/return
//! pre-encoded msgpack slices.
//!
//! Primary-index targeting: `Space` methods OMIT INDEX_NAME (null), so the
//! server defaults to index 0. Secondary-index reads go through `Index`
//! (`space.index(name)`), which sends INDEX_NAME so the server targets that
//! index; on a non-unique index a `get` can legitimately raise `MoreThanOne`.
//!
//! THE BUILD/SEND SEAM (batching prep):
//! frame construction lives in the private `frame*` builders — each appends one
//! complete request frame to a caller-supplied buffer and returns its SYNC,
//! doing NO I/O. Sending is `conn.roundtrip(buf.items(), sync)`. Space methods
//! compose the two halves; a future `batch()` calls the BUILD half repeatedly
//! into one buffer, then sends once. Keep them separable.
//!
//! LIFETIMES: a decoded `Row` with slice fields (e.g. `[]const u8`) and
//! every raw DATA slice BORROW the connection's `resp_buf` — valid only until
//! the next request on that connection (single in-flight). Copy before the
//! next call if a value must outlive it. `select` allocates only the result
//! array (caller-owned, freed via the passed `gpa`); its ELEMENTS still borrow
//! `resp_buf`, so copy the whole slice out before the next request if needed.

const std = @import("std");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");
const connection = @import("connection.zig");

const iproto = proto.iproto;
const query = proto.query;
const request = iproto.request;
const Allocator = std.mem.Allocator;
const Connection = connection.Connection;
const RequestError = connection.RequestError;

/// A value handle binding a live connection to a space by name. Cheap to copy;
/// holds no owned state. `name` is BORROWED — the caller keeps it alive
/// (typically a string literal). Construct via `Connection.space(name)`.
pub const Space = struct {
    conn: *Connection,
    /// Space name, borrowed (see the struct doc). Resolved server-side per
    /// request; a bad name surfaces as `error.ServerError` on first use.
    name: []const u8,
    /// Interactive-transaction stream selector. `null` (the default via
    /// `Connection.space`) sends plain, autocommit DML — byte-identical to the
    /// pre-stream form. A `Stream` (`stream.zig`) hands out spaces carrying its
    /// id via `Stream.space`, so every frame this handle builds rides the same
    /// STREAM_ID header and joins that transaction.
    stream_id: ?u64 = null,

    // ---- typed verbs ------------------------------------------------------

    /// INSERT `row` (a tuple/struct or array/slice, encoded positionally as the
    /// tuple) and decode the inserted tuple into `Row`. `Row == void` discards
    /// it. A duplicate primary key surfaces as `error.ServerError`.
    /// OWNERSHIP: slice fields in the returned `Row` borrow `resp_buf` (valid
    /// until the next request); copy before the next call if needed.
    pub fn insert(s: Space, row: anytype, comptime Row: type) RequestError!Row {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, row);
        return decodeOne(Row, try s.insertRaw(buf.items()));
    }

    /// REPLACE `row` (encoded like `insert`) and decode the stored tuple into
    /// `Row`. Same ownership contract as `insert`.
    pub fn replace(s: Space, row: anytype, comptime Row: type) RequestError!Row {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, row);
        return decodeOne(Row, try s.replaceRaw(buf.items()));
    }

    /// DELETE the tuple matching `key` (a tuple/struct or array/slice) on the
    /// PRIMARY index and decode the deleted tuple into `Row`; `null` when no
    /// tuple matched. `Row == void` discards it. Same ownership contract as
    /// `insert` (the returned row borrows `resp_buf`).
    pub fn delete(s: Space, key: anytype, comptime Row: type) RequestError!?Row {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, key);
        return decodeDeleted(Row, try s.deleteRaw(buf.items()));
    }

    /// GET the single tuple matching `key` on the PRIMARY index, decoded into
    /// `Row`; `null` when there is no match. Implemented as SELECT
    /// `iterator=.eq, limit=2`: two matches yield `error.MoreThanOne` (`get` never silently drops a row). `Row == void` discards the tuple.
    /// OWNERSHIP: the returned row borrows `resp_buf`; copy before the next call.
    pub fn get(s: Space, key: anytype, comptime Row: type) RequestError!?Row {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, key);
        return decodeUnique(Row, try s.getRaw(buf.items()));
    }

    /// UPDATE the tuple matching `key` on the PRIMARY index with `ops` (a tuple
    /// of `proto.update` op constructors — `set`/`add`/`del`/… — or a runtime
    /// `update.Ops` builder, encoded verbatim via `proto.update.encodeOps`)
    /// and decode the updated tuple into `Row`; `null` when no tuple matched
    /// (UPDATE affects zero or one tuple). `Row == void` discards it. On the wire
    /// the ops ride under TUPLE (0x21) — the proto builder handles that. Same
    /// ownership contract as `insert` (the returned row borrows `resp_buf`).
    pub fn update(s: Space, key: anytype, ops: anytype, comptime Row: type) RequestError!?Row {
        var key_buf = msgpack.Buffer.init(s.conn.gpa);
        defer key_buf.deinit();
        try encodeTuple(&key_buf, key);
        var ops_buf = try proto.update.encodeOps(s.conn.gpa, ops);
        defer ops_buf.deinit();
        return decodeUpdated(Row, try s.updateRaw(key_buf.items(), ops_buf.items()));
    }

    /// UPSERT `row` (inserted when absent) applying `ops` on a primary-key
    /// conflict. `ops` is encoded like `update`'s but rides under OPS (0x28) on
    /// the wire (the proto builder handles the key). UPSERT is fire-and-forget:
    /// it never returns DATA, so there is nothing to decode — a match/no-match is
    /// only observable via a follow-up `get`/`select`. Always targets the primary
    /// key (no index variant).
    pub fn upsert(s: Space, row: anytype, ops: anytype) RequestError!void {
        var tuple_buf = msgpack.Buffer.init(s.conn.gpa);
        defer tuple_buf.deinit();
        try encodeTuple(&tuple_buf, row);
        var ops_buf = try proto.update.encodeOps(s.conn.gpa, ops);
        defer ops_buf.deinit();
        try s.upsertRaw(tuple_buf.items(), ops_buf.items());
    }

    /// SELECT the tuples matching `key` on the PRIMARY index under `opts`
    /// (iterator/offset/limit, consumed verbatim), decoding each into `Row`.
    /// Returns a freshly `gpa`-allocated `[]Row` (CALLER FREES via the same `gpa`);
    /// an empty match yields an empty slice. `opts.limit == null` (unbounded) maps
    /// to the wire's `std.math.maxInt(u32)`.
    /// OWNERSHIP: only the outer array is owned; each `Row`'s slice fields BORROW
    /// `resp_buf` and are invalidated by the next request — copy the whole result
    /// out first if it must outlive that.
    pub fn select(s: Space, gpa: Allocator, key: anytype, opts: query.SelectOptions, comptime Row: type) RequestError![]Row {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, key);
        return decodeRows(gpa, Row, try s.selectRaw(buf.items(), opts));
    }

    // ---- raw verbs (pre-encoded msgpack escape hatch) ----------------

    /// INSERT a PRE-ENCODED tuple MP_ARRAY; returns the reply's raw DATA (the
    /// `[inserted_tuple]` array) as msgpack bytes, or null when the reply carried
    /// no DATA. The slice BORROWS `resp_buf` (valid until the next request).
    pub fn insertRaw(s: Space, tuple_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        const sync = try s.frameInsert(&buf, tuple_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    /// REPLACE with a PRE-ENCODED tuple MP_ARRAY. Return/ownership semantics are
    /// identical to `insertRaw`.
    pub fn replaceRaw(s: Space, tuple_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        const sync = try s.frameReplace(&buf, tuple_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    /// DELETE by a PRE-ENCODED key MP_ARRAY on the primary index. Returns the raw
    /// DATA (`[deleted_tuple]` or `[]`) or null. Ownership like `insertRaw`.
    pub fn deleteRaw(s: Space, key_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        const sync = try s.frameDelete(&buf, key_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    /// GET by a PRE-ENCODED key MP_ARRAY: runs the `eq/limit=2` primary-index
    /// SELECT and returns the raw DATA (`[]`, `[t]`, or `[t0,t1]`) or null. The
    /// arity interpretation (`MoreThanOne` on two) lives in the typed `get`; this
    /// escape hatch returns the bytes verbatim. Ownership like `insertRaw`.
    pub fn getRaw(s: Space, key_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        // null INDEX_NAME -> primary index.
        const sync = try s.frameGet(&buf, null, key_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    /// UPDATE by a PRE-ENCODED key MP_ARRAY on the primary index, applying the
    /// PRE-ENCODED `ops_mp` (a MessagePack array-of-ops, e.g. from
    /// `proto.update.encodeOps`). Returns the raw DATA (`[updated_tuple]` or `[]`)
    /// or null. Ownership like `insertRaw`.
    pub fn updateRaw(s: Space, key_mp: []const u8, ops_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        // null INDEX_NAME -> primary index (update-via-secondary is a later task).
        const sync = try s.frameUpdate(&buf, null, key_mp, ops_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    /// UPSERT a PRE-ENCODED tuple MP_ARRAY applying the PRE-ENCODED `ops_mp` on a
    /// primary-key conflict. Returns nothing — UPSERT never carries DATA.
    pub fn upsertRaw(s: Space, tuple_mp: []const u8, ops_mp: []const u8) RequestError!void {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        const sync = try s.frameUpsert(&buf, tuple_mp, ops_mp);
        _ = try s.conn.roundtrip(buf.items(), sync);
    }

    /// SELECT by a PRE-ENCODED key MP_ARRAY on the primary index under `opts`;
    /// returns the raw DATA (the whole tuples array) or null. The typed decode
    /// (into `[]Row`) lives in `select`; this returns the bytes verbatim.
    /// Ownership like `insertRaw`.
    pub fn selectRaw(s: Space, key_mp: []const u8, opts: query.SelectOptions) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(s.conn.gpa);
        defer buf.deinit();
        // null INDEX_NAME -> primary index.
        const sync = try s.frameSelect(&buf, null, opts, key_mp);
        return okData(try s.conn.roundtrip(buf.items(), sync));
    }

    // ---- BUILD half of the seam (no I/O) ----------------------------------
    //
    // THE INTERNAL BATCH SEAM (`batch.zig`):
    // each `frame*` appends one complete request frame to `buf` and returns its
    // SYNC, doing NO I/O. `Space`/`Index` compose one of these with a single
    // `roundtrip`; `Batch` calls them repeatedly into ONE buffer, then flushes
    // once. `pub` ONLY so the sibling `batch.zig` file can reach them (Zig has no
    // file-private-within-a-package) — NOT part of the user API. Callers use the
    // typed/raw verbs above or the batch verb adders; do not build frames by hand.

    pub fn frameInsert(s: Space, buf: *msgpack.Buffer, tuple_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.insertStream(buf, sync, s.stream_id, s.name, tuple_mp);
        return sync;
    }

    pub fn frameReplace(s: Space, buf: *msgpack.Buffer, tuple_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.replaceStream(buf, sync, s.stream_id, s.name, tuple_mp);
        return sync;
    }

    pub fn frameDelete(s: Space, buf: *msgpack.Buffer, key_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        // null INDEX_NAME -> primary index (index 0).
        try request.deleteStream(buf, sync, s.stream_id, s.name, null, key_mp);
        return sync;
    }

    /// Unique lookup: eq iterator, limit 2 (so a second match is observable as
    /// MoreThanOne), offset 0. `index_name == null` -> primary index; a name
    /// (from `Index`) targets that secondary index. Batch seam (see the section
    /// note above): `pub` for `batch.zig`, not user API.
    pub fn frameGet(s: Space, buf: *msgpack.Buffer, index_name: ?[]const u8, key_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.selectStream(buf, sync, s.stream_id, s.name, index_name, .eq, 2, 0, key_mp);
        return sync;
    }

    /// Range SELECT: `opts` verbatim. `opts.limit == null` (unbounded) maps to the
    /// wire's `maxInt(u32)` sentinel — see `selectLimit`. `index_name` as `frameGet`.
    /// Batch seam (see the section note above): `pub` for `batch.zig`, not user API.
    pub fn frameSelect(s: Space, buf: *msgpack.Buffer, index_name: ?[]const u8, opts: query.SelectOptions, key_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.selectStream(buf, sync, s.stream_id, s.name, index_name, opts.iterator, selectLimit(opts.limit), opts.offset, key_mp);
        return sync;
    }

    pub fn frameUpdate(s: Space, buf: *msgpack.Buffer, index_name: ?[]const u8, key_mp: []const u8, ops_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.updateStream(buf, sync, s.stream_id, s.name, index_name, key_mp, ops_mp);
        return sync;
    }

    pub fn frameUpsert(s: Space, buf: *msgpack.Buffer, tuple_mp: []const u8, ops_mp: []const u8) RequestError!u64 {
        const sync = s.conn.nextSync();
        try request.upsertStream(buf, sync, s.stream_id, s.name, tuple_mp, ops_mp);
        return sync;
    }

    // ---- index handle factory ---------------------------------------------

    /// Bind a SECONDARY index of this space by name for read access (`get`/
    /// `select`). Infallible, no I/O — the name resolves server-side per request
    /// (a bad name surfaces as `error.ServerError` on first use, like `Space`).
    /// `name` is BORROWED (kept alive by the caller, typically a literal).
    pub fn index(s: Space, name: []const u8) Index {
        return .{ .space = s, .name = name };
    }
};

/// A read handle over a SECONDARY index of a `Space`: the same `get`/`select`
/// surface, but every request carries INDEX_NAME so the server targets this
/// index instead of the primary. Reuses `Space`'s frame builders (passing
/// `name` where `Space` passes `null`) — zero duplicated wire logic. Cheap to
/// copy; construct via `space.index(name)`. Read subset only for now:
/// update/delete-via-secondary arrive with the schema-aware sibling.
pub const Index = struct {
    space: Space,
    /// Index name, borrowed (see the struct doc).
    name: []const u8,

    /// GET the single tuple matching `key` on THIS index, decoded into `Row`;
    /// `null` when there is no match, `error.MoreThanOne` when the (possibly
    /// non-unique) index matches two or more. `Row == void` discards the
    /// tuple. OWNERSHIP: the returned row borrows `resp_buf`.
    pub fn get(i: Index, key: anytype, comptime Row: type) RequestError!?Row {
        var buf = msgpack.Buffer.init(i.space.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, key);
        return decodeUnique(Row, try i.getRaw(buf.items()));
    }

    /// SELECT the tuples matching `key` on THIS index under `opts`, decoded into a
    /// `gpa`-owned `[]Row` (CALLER FREES). Semantics/ownership identical to
    /// `Space.select` (limit-null maps to `maxInt(u32)`; elements borrow `resp_buf`).
    pub fn select(i: Index, gpa: Allocator, key: anytype, opts: query.SelectOptions, comptime Row: type) RequestError![]Row {
        var buf = msgpack.Buffer.init(i.space.conn.gpa);
        defer buf.deinit();
        try encodeTuple(&buf, key);
        return decodeRows(gpa, Row, try i.selectRaw(buf.items(), opts));
    }

    /// GET by a PRE-ENCODED key MP_ARRAY on THIS index; raw DATA or null. The
    /// arity interpretation (`MoreThanOne`) lives in the typed `get`. Ownership
    /// like `Space.insertRaw`.
    pub fn getRaw(i: Index, key_mp: []const u8) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(i.space.conn.gpa);
        defer buf.deinit();
        const sync = try i.space.frameGet(&buf, i.name, key_mp);
        return okData(try i.space.conn.roundtrip(buf.items(), sync));
    }

    /// SELECT by a PRE-ENCODED key MP_ARRAY on THIS index under `opts`; raw DATA
    /// or null. Ownership like `Space.insertRaw`.
    pub fn selectRaw(i: Index, key_mp: []const u8, opts: query.SelectOptions) RequestError!?[]const u8 {
        var buf = msgpack.Buffer.init(i.space.conn.gpa);
        defer buf.deinit();
        const sync = try i.space.frameSelect(&buf, i.name, opts, key_mp);
        return okData(try i.space.conn.roundtrip(buf.items(), sync));
    }
};

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested without sockets)
// ---------------------------------------------------------------------------

/// Extract the raw DATA slice from a roundtrip result. `roundtrip` guarantees an
/// OK response (server errors are raised before it returns), so `.err` is
/// unreachable — mirrors connection.zig's `okData`.
fn okData(resp: iproto.Response) ?[]const u8 {
    return switch (resp.result) {
        .ok => |data| data,
        .err => unreachable,
    };
}

/// Encode a row or key `value` into `buf` as a single positional MP_ARRAY (the
/// wire tuple/key shape). A tuple/struct is emitted field-order via
/// `encodeArray` (a named struct becomes a positional array, not a map); an
/// array/slice goes through `encode` (already an MP_ARRAY). Any other shape is a
/// compile error — rows/keys must be array-like, never a bare scalar. Identical
/// idiom to connection.zig's `encodeArgs`. `pub` so `batch.zig` reuses this one
/// encoder for its rows/keys AND call/eval args (same MP_ARRAY shape) — batch
/// seam, not user API.
pub fn encodeTuple(buf: *msgpack.Buffer, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => try msgpack.encodeArray(buf, value),
        .array, .pointer => try msgpack.encode(buf, value),
        else => @compileError("space row/key must be a tuple/struct or array/slice (MP_ARRAY), got " ++ @typeName(T)),
    }
}

/// msgpack.zig keeps its array-header reader private, so this reads the one
/// framing token the DATA-arity logic needs (mirrors iproto.zig's `readMapLen`).
/// Leaf tuples are still decoded entirely by the codec (`msgpack.decode`).
fn readArrayLen(dec: *msgpack.Decoder) msgpack.DecodeError!usize {
    if (dec.pos >= dec.buf.len) return error.Truncated;
    const t = dec.buf[dec.pos];
    dec.pos += 1;
    if (t & 0xf0 == 0x90) return t & 0x0f;
    switch (t) {
        0xdc => {
            if (dec.pos + 2 > dec.buf.len) return error.Truncated;
            const v = std.mem.readInt(u16, dec.buf[dec.pos..][0..2], .big);
            dec.pos += 2;
            return v;
        },
        0xdd => {
            if (dec.pos + 4 > dec.buf.len) return error.Truncated;
            const v = std.mem.readInt(u32, dec.buf[dec.pos..][0..4], .big);
            dec.pos += 4;
            return v;
        },
        else => return error.NotArray,
    }
}

/// insert/replace: the DML DATA is EXACTLY one affected tuple. Decode it into
/// `Row`; `Row == void` discards it. Absent DATA or an arity other than 1 is a
/// wire-contract violation (`error.ProtocolError`) — never a defaulted-empty row.
/// `pub` so `batch.zig` reuses it (batch seam, not user API).
pub fn decodeOne(comptime Row: type, data: ?[]const u8) RequestError!Row {
    if (comptime Row == void) return;
    const bytes = data orelse return error.ProtocolError;
    var dec = msgpack.Decoder.init(bytes);
    if ((try readArrayLen(&dec)) != 1) return error.ProtocolError;
    return try msgpack.decode(Row, &dec);
}

/// Decode a DATA array under a "0 or 1" contract: 0 tuples -> null, 1 -> the
/// decoded `Row`, >=2 -> `excess`. `Row == void` yields a present-but-empty
/// value (`{}`) for one match, `null` for none. Absent DATA (no DATA key at all)
/// is treated as no match (null). `pub` so `batch.zig`'s `decodeMaybe` reuses it
/// (batch seam, not user API).
pub fn decodeCapped(comptime Row: type, data: ?[]const u8, comptime excess: RequestError) RequestError!?Row {
    const bytes = data orelse return null;
    var dec = msgpack.Decoder.init(bytes);
    const n = try readArrayLen(&dec);
    if (n == 0) return null;
    if (n > 1) return excess;
    if (comptime Row == void) return {};
    return try msgpack.decode(Row, &dec);
}

/// delete: 0 -> null, 1 -> the deleted row. A delete returning >1 tuples
/// violates the wire contract (`error.ProtocolError`).
fn decodeDeleted(comptime Row: type, data: ?[]const u8) RequestError!?Row {
    return decodeCapped(Row, data, error.ProtocolError);
}

/// get: 0 -> null, 1 -> the row, >=2 -> `error.MoreThanOne`.
fn decodeUnique(comptime Row: type, data: ?[]const u8) RequestError!?Row {
    return decodeCapped(Row, data, error.MoreThanOne);
}

/// update: 0 -> null (no tuple matched), 1 -> the updated row. An UPDATE affects
/// at most one tuple (single key on one index), so >1 violates the wire contract
/// (`error.ProtocolError`).
fn decodeUpdated(comptime Row: type, data: ?[]const u8) RequestError!?Row {
    return decodeCapped(Row, data, error.ProtocolError);
}

/// select: decode the ENTIRE DATA array-of-tuples into a fresh `gpa`-owned
/// `[]Row` (caller frees). Absent DATA (no DATA key) yields an empty slice. Only
/// the outer array is owned; each `Row`'s slice fields borrow the underlying
/// bytes (which borrow `resp_buf`) — see the module lifetime note. The array
/// header may be fixarray, array16 (0xdc) or array32 (0xdd): `readArrayLen`
/// handles all three (the live server framed even small DATA as array32).
/// `pub` so `batch.zig`'s `decodeMany` reuses it (batch seam, not user API).
pub fn decodeRows(gpa: Allocator, comptime Row: type, data: ?[]const u8) RequestError![]Row {
    const bytes = data orelse return gpa.alloc(Row, 0);
    var dec = msgpack.Decoder.init(bytes);
    const n = try readArrayLen(&dec);
    const rows = try gpa.alloc(Row, n);
    errdefer gpa.free(rows);
    for (rows) |*row| row.* = try msgpack.decode(Row, &dec);
    return rows;
}

/// Map a `SelectOptions.limit` to the wire's `u32`: `null` (unbounded) becomes
/// `maxInt(u32)`, the largest cap the protocol can express. `request.select`
/// takes a plain `u32`, so this is the single site translating "no limit".
fn selectLimit(limit: ?u32) u32 {
    return limit orelse std.math.maxInt(u32);
}

// ---------------------------------------------------------------------------
// Tests (pure; the live DML path is smoke-tested by the harness)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encodeTuple: a row tuple encodes to the same MP_ARRAY the codec emits" {
    const row = .{ @as(u32, 1), @as([]const u8, "x") };

    var got = msgpack.Buffer.init(testing.allocator);
    defer got.deinit();
    try encodeTuple(&got, row);

    var want = msgpack.Buffer.init(testing.allocator);
    defer want.deinit();
    try msgpack.encodeArray(&want, row);

    try testing.expectEqualSlices(u8, want.items(), got.items());
    // hand oracle: fixarray(2) 01 str1 'x'
    try testing.expectEqualSlices(u8, &[_]u8{ 0x92, 0x01, 0xa1, 0x78 }, got.items());
}

test "encodeTuple: a single-element key encodes to a 1-array" {
    var got = msgpack.Buffer.init(testing.allocator);
    defer got.deinit();
    try encodeTuple(&got, .{@as(u32, 42)});
    try testing.expectEqualSlices(u8, &[_]u8{ 0x91, 0x2a }, got.items());
}

test "readArrayLen: fixarray count and rejects non-array lead byte" {
    var d0 = msgpack.Decoder.init(&[_]u8{0x90});
    try testing.expectEqual(@as(usize, 0), try readArrayLen(&d0));
    var d2 = msgpack.Decoder.init(&[_]u8{ 0x92, 0x01, 0x02 });
    try testing.expectEqual(@as(usize, 2), try readArrayLen(&d2));
    var dm = msgpack.Decoder.init(&[_]u8{0x80}); // fixmap, not an array
    try testing.expectError(error.NotArray, readArrayLen(&dm));
}

test "decodeUnique: 0/1/2 DATA arity -> null / row / MoreThanOne" {
    const Row = struct { u32, []const u8 };
    // 0 tuples: [] -> null
    try testing.expectEqual(@as(?Row, null), try decodeUnique(Row, &[_]u8{0x90}));
    // 1 tuple: [[1,'x']] -> the row
    const one = [_]u8{ 0x91, 0x92, 0x01, 0xa1, 0x78 };
    const got = (try decodeUnique(Row, &one)).?;
    try testing.expectEqual(@as(u32, 1), got[0]);
    try testing.expectEqualStrings("x", got[1]);
    // 2 tuples: [[1],[2]] -> MoreThanOne
    const two = [_]u8{ 0x92, 0x91, 0x01, 0x91, 0x02 };
    try testing.expectError(error.MoreThanOne, decodeUnique(Row, &two));
    // absent DATA -> null (no match)
    try testing.expectEqual(@as(?Row, null), try decodeUnique(Row, null));
}

test "decodeUnique: Row = void distinguishes present ({}) from absent (null)" {
    const one = [_]u8{ 0x91, 0x90 }; // [[]] one (empty) tuple
    try testing.expect((try decodeUnique(void, &one)) != null);
    try testing.expect((try decodeUnique(void, &[_]u8{0x90})) == null);
}

test "decodeDeleted: 0 -> null, 1 -> row, >1 -> ProtocolError" {
    const Row = struct { u32 };
    try testing.expectEqual(@as(?Row, null), try decodeDeleted(Row, &[_]u8{0x90}));
    const one = [_]u8{ 0x91, 0x91, 0x07 }; // [[7]]
    try testing.expectEqual(@as(u32, 7), (try decodeDeleted(Row, &one)).?[0]);
    const two = [_]u8{ 0x92, 0x91, 0x01, 0x91, 0x02 };
    try testing.expectError(error.ProtocolError, decodeDeleted(Row, &two));
}

test "decodeOne: exactly one tuple; absent/empty/multi is ProtocolError" {
    const Row = struct { u32, u32 };
    const one = [_]u8{ 0x91, 0x92, 0x01, 0x02 }; // [[1,2]]
    const got = try decodeOne(Row, &one);
    try testing.expectEqual(@as(u32, 1), got[0]);
    try testing.expectEqual(@as(u32, 2), got[1]);
    // no DATA at all
    try testing.expectError(error.ProtocolError, decodeOne(Row, null));
    // empty DATA array (no affected tuple)
    try testing.expectError(error.ProtocolError, decodeOne(Row, &[_]u8{0x90}));
    // two tuples
    const two = [_]u8{ 0x92, 0x92, 0x01, 0x02, 0x92, 0x03, 0x04 };
    try testing.expectError(error.ProtocolError, decodeOne(Row, &two));
}

test "decodeOne: Row = void ignores DATA entirely" {
    const one = [_]u8{ 0x91, 0x92, 0x01, 0x02 };
    try decodeOne(void, &one);
    try decodeOne(void, null); // void never inspects DATA
}

test "decodeUpdated: 0 -> null, 1 -> row, >1 -> ProtocolError" {
    const Row = struct { u32 };
    try testing.expectEqual(@as(?Row, null), try decodeUpdated(Row, &[_]u8{0x90}));
    const one = [_]u8{ 0x91, 0x91, 0x09 }; // [[9]]
    try testing.expectEqual(@as(u32, 9), (try decodeUpdated(Row, &one)).?[0]);
    const two = [_]u8{ 0x92, 0x91, 0x01, 0x91, 0x02 };
    try testing.expectError(error.ProtocolError, decodeUpdated(Row, &two));
    // absent DATA -> null (no match)
    try testing.expectEqual(@as(?Row, null), try decodeUpdated(Row, null));
}

test "decodeRows: array32 (0xdd) multi-row typed decode, plus empty and absent" {
    const Row = struct { u32, []const u8 };
    // Live finding: the server frames DATA with an array32 header even for a
    // small array. [[1,'a'],[2,'bb']] under an explicit 0xdd header.
    const data = [_]u8{
        0xdd, 0x00, 0x00, 0x00, 0x02, // array32, len 2
        0x92, 0x01, 0xa1, 0x61, // [1,'a']
        0x92, 0x02, 0xa2, 0x62, 0x62, // [2,'bb']
    };
    const rows = try decodeRows(testing.allocator, Row, &data);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u32, 1), rows[0][0]);
    try testing.expectEqualStrings("a", rows[0][1]);
    try testing.expectEqual(@as(u32, 2), rows[1][0]);
    try testing.expectEqualStrings("bb", rows[1][1]);

    // empty array -> empty slice
    const empty = try decodeRows(testing.allocator, Row, &[_]u8{0x90});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // absent DATA (no DATA key) -> empty slice, not an error
    const none = try decodeRows(testing.allocator, Row, null);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "selectLimit: null (unbounded) maps to maxInt(u32); a set cap passes through" {
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), selectLimit(null));
    try testing.expectEqual(@as(u32, 10), selectLimit(10));
    try testing.expectEqual(@as(u32, 0), selectLimit(0));
}

test "frameInsert threads stream_id into the header (STREAM_ID present, body unchanged)" {
    // A Space carrying a stream_id builds an insert frame whose header is the
    // 3-entry {TYPE, SYNC, STREAM_ID} form; only nextSync is touched on conn.
    var conn: Connection = undefined;
    conn.sync = 0;
    const s = Space{ .conn = &conn, .name = "s", .stream_id = 4 };

    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    const sync = try s.frameInsert(&buf, &[_]u8{ 0x92, 0x01, 0x02 }); // tuple [1,2]
    try testing.expectEqual(@as(u64, 0), sync);

    // oracle (live tarantool msgpack): size ++ header{insert,sync0,STREAM_ID 4}
    // ++ body{SPACE_NAME 's', TUPLE [1,2]}. The `0a 04` is the STREAM_ID key.
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x0f, 0x83, 0x00, 0x02, 0x01, 0x00, 0x0a, 0x04, 0x82, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &expected, buf.items());

    // Parse the header back: type/sync survive, and decodeHeader walks the
    // STREAM_ID key without tripping (it rides through as an unknown-to-Header key).
    const fr = try iproto.readFrame(buf.items());
    var dec = msgpack.Decoder.init(fr.payload);
    const hdr = try iproto.decodeHeader(testing.allocator, &dec);
    try testing.expectEqual(@as(u32, @backingInt(iproto.RequestType.insert)), hdr.type);
    try testing.expectEqual(@as(u64, 0), hdr.sync);
}

test "frameInsert with null stream_id keeps the plain 2-entry header (byte-identical)" {
    var conn: Connection = undefined;
    conn.sync = 0;
    const s = Space{ .conn = &conn, .name = "s" }; // stream_id defaults to null

    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    _ = try s.frameInsert(&buf, &[_]u8{ 0x92, 0x01, 0x02 });

    // oracle: 2-entry header {TYPE, SYNC} — no STREAM_ID key, unchanged from the
    // pre-stream form. size 13 = 0x0d.
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x0d, 0x82, 0x00, 0x02, 0x01, 0x00, 0x82, 0x5e, 0xa1, 0x73, 0x21, 0x92, 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &expected, buf.items());
}

test "frameSelect threads stream_id (get shape carries STREAM_ID)" {
    var conn: Connection = undefined;
    conn.sync = 0;
    const s = Space{ .conn = &conn, .name = "s", .stream_id = 4 };

    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    _ = try s.frameGet(&buf, null, &[_]u8{ 0x91, 0x01 }); // key [1], primary

    // oracle (live): header{select,sync0,STREAM_ID 4} ++ body{space,iter eq,
    // limit 2, offset 0, key [1]} (map5). size 0x14.
    const expected = [_]u8{ 0xce, 0x00, 0x00, 0x00, 0x14, 0x83, 0x00, 0x01, 0x01, 0x00, 0x0a, 0x04, 0x85, 0x5e, 0xa1, 0x73, 0x14, 0x00, 0x12, 0x02, 0x13, 0x00, 0x20, 0x91, 0x01 };
    try testing.expectEqualSlices(u8, &expected, buf.items());
}

test "update ops encode through proto.update to the wire ops array (TUPLE-side body)" {
    // The `ops: anytype` a caller hands `update`/`upsert` goes verbatim through
    // proto.update.encodeOps. Assert the produced array-of-ops bytes:
    // [["=",1,5],["+",2,1]].
    var b = try proto.update.encodeOps(
        testing.allocator,
        .{ proto.update.set(1, @as(i64, 5)), proto.update.add(2, @as(i64, 1)) },
    );
    defer b.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{
        0x92, // array2 (two ops)
        0x93, 0xa1, 0x3d, 0x01, 0x05, // ["=",1,5]
        0x93, 0xa1, 0x2b, 0x02, 0x01, // ["+",2,1]
    }, b.items());
}
