//! `Batch` — pipelined requests over the frame seam: build N request frames with the verb adders, `execute()`
//! to write them all in ONE flush, then read ALL N responses (any order,
//! matched by SYNC) into a batch-owned arena, and read per-handle results.
//!
//! WHY read-all (not lazy per-handle waits): after `execute()` returns the
//! connection is IDLE and immediately usable — no outstanding responses
//! leak across other `Connection` calls. The read loop never assumes FIFO:
//! iproto dispatches to TX and replies as work completes, so a response can
//! arrive out of order; each frame is parked into its slot by matching SYNC.
//!
//! LIFETIMES: every response frame is COPIED into the batch's arena and
//! parsed THERE, so a handle's result slices stay valid until `deinit()` — a
//! LONGER lifetime than a normal request (whose result dies at the next request
//! on the connection). The connection's `resp_buf` is only staging during the
//! read loop.
//!
//! ERRORS: a per-request SERVER error does not fail the batch — it is parked in
//! that slot and surfaced per handle (`dataRaw`/`serverError`/the typed decoders
//! raise `error.ServerError` for that handle only; every batch has N independent
//! error channels, NOT the connection's single `last_error`). A TRANSPORT error
//! mid-`execute` (write/read/parse) POISONS the connection: `execute` returns
//! the transport error and the caller MUST close the connection — the wire
//! position is unknown and there is no half-recovery machinery in v1.
//!
//! ONE FLIGHT: a batch is build → execute → read → deinit. Reuse is not
//! supported — any adder or a second `execute()` after `execute()` returns
//! `error.BatchConsumed`.

const std = @import("std");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");
const connection = @import("connection.zig");
const space_mod = @import("space.zig");

const iproto = proto.iproto;
const query = proto.query;
const request = iproto.request;
const Allocator = std.mem.Allocator;
const Connection = connection.Connection;
const RequestError = connection.RequestError;
const Space = space_mod.Space;

/// A slot index into the batch, returned by every verb adder and passed to the
/// result accessors. Stable for the batch's lifetime.
pub const Handle = u32;

/// Errors from a verb adder or `execute`: the connection request family plus the
/// one-flight guard. `BatchConsumed` means an adder ran, or `execute` was called,
/// after the batch was already executed (reuse is unsupported, v1).
pub const BatchError = RequestError || error{BatchConsumed};

/// Per-slot server-error details, arena-owned (valid until `deinit`). Distinct
/// from the connection's single `last_error`: a batch has one of these PER failed
/// handle. `raw` is the structured MP_ERROR (0x52) stack as raw msgpack bytes, or
/// null when the peer omitted it.
pub const ServerErrorInfo = struct {
    code: u32,
    message: []const u8,
    raw: ?[]const u8,
};

/// A parked response outcome. `ok` carries the raw DATA (0x30) payload (or null
/// when the reply had none, e.g. PING/UPSERT); `err` carries the parked server
/// error. Both variants' slices are ARENA-owned (the copied+reparsed frame).
const Outcome = union(enum) {
    ok: ?[]const u8,
    err: ServerErrorInfo,
};

/// One request slot: the SYNC stamped at build time and the outcome parked by
/// the read loop. `outcome == null` means pending (not yet filled).
const Slot = struct {
    sync: u64,
    outcome: ?Outcome = null,
};

pub const Batch = struct {
    conn: *Connection,
    /// Backs the frame buffer, the slot list, and the arena's child allocator.
    gpa: Allocator,
    /// Owns the copied+parsed response frames; freed wholesale by `deinit`.
    arena: std.heap.ArenaAllocator,
    /// The single build buffer: every adder appends one complete request frame
    /// here; `execute` flushes the whole thing in one `sendFrame`.
    frames: msgpack.Buffer,
    /// One entry per added request, in add order (index == `Handle`).
    slots: std.ArrayList(Slot),
    /// Set by `execute`; once true, adders and a second `execute` are rejected.
    executed: bool,

    /// Construct an empty batch bound to `conn`. No I/O, no allocation. Prefer
    /// `conn.batch(gpa)`.
    pub fn init(conn: *Connection, gpa: Allocator) Batch {
        return .{
            .conn = conn,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .frames = msgpack.Buffer.init(gpa),
            .slots = .empty,
            .executed = false,
        };
    }

    /// Free everything the batch owns: the arena (all parked results), the slot
    /// list, and the frame buffer. Call exactly once.
    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
        self.slots.deinit(self.gpa);
        self.frames.deinit();
    }

    // ---- verb adders (build a frame, park a pending slot) -----------------
    //
    // Each mirrors the corresponding `Space`/`Connection` verb's typed parameter
    // shape but takes NO `Row` type and does NO I/O: it appends one frame to the
    // shared build buffer (via the pub `frame*` seam / proto request builders)
    // and returns a `Handle`. Decoding is deferred to the accessors after
    // `execute`. Adding after `execute` is `error.BatchConsumed`.

    /// INSERT `row` (tuple/struct or array/slice, positional MP_ARRAY).
    pub fn insert(self: *Batch, space: Space, row: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var tb = msgpack.Buffer.init(self.gpa);
        defer tb.deinit();
        try space_mod.encodeTuple(&tb, row);
        return self.push(try space.frameInsert(&self.frames, tb.items()));
    }

    /// REPLACE `row` (encoded like `insert`).
    pub fn replace(self: *Batch, space: Space, row: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var tb = msgpack.Buffer.init(self.gpa);
        defer tb.deinit();
        try space_mod.encodeTuple(&tb, row);
        return self.push(try space.frameReplace(&self.frames, tb.items()));
    }

    /// DELETE the tuple matching `key` on the PRIMARY index.
    pub fn delete(self: *Batch, space: Space, key: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var kb = msgpack.Buffer.init(self.gpa);
        defer kb.deinit();
        try space_mod.encodeTuple(&kb, key);
        return self.push(try space.frameDelete(&self.frames, kb.items()));
    }

    /// GET the unique tuple matching `key` on the PRIMARY index (eq/limit=2; a
    /// second match surfaces as `error.MoreThanOne` from `decodeMaybe`).
    pub fn get(self: *Batch, space: Space, key: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var kb = msgpack.Buffer.init(self.gpa);
        defer kb.deinit();
        try space_mod.encodeTuple(&kb, key);
        return self.push(try space.frameGet(&self.frames, null, kb.items()));
    }

    /// SELECT tuples matching `key` on the PRIMARY index under `opts`.
    pub fn select(self: *Batch, space: Space, key: anytype, opts: query.SelectOptions) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var kb = msgpack.Buffer.init(self.gpa);
        defer kb.deinit();
        try space_mod.encodeTuple(&kb, key);
        return self.push(try space.frameSelect(&self.frames, null, opts, kb.items()));
    }

    /// UPDATE the tuple matching `key` on the PRIMARY index with `ops` (a tuple of
    /// `proto.update` op constructors or a runtime `update.Ops`).
    pub fn update(self: *Batch, space: Space, key: anytype, ops: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var kb = msgpack.Buffer.init(self.gpa);
        defer kb.deinit();
        try space_mod.encodeTuple(&kb, key);
        var ob = try proto.update.encodeOps(self.gpa, ops);
        defer ob.deinit();
        return self.push(try space.frameUpdate(&self.frames, null, kb.items(), ob.items()));
    }

    /// UPSERT `row` (inserted when absent) applying `ops` on a primary-key
    /// conflict. Never carries DATA — read it back with `expectOk`.
    pub fn upsert(self: *Batch, space: Space, row: anytype, ops: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var tb = msgpack.Buffer.init(self.gpa);
        defer tb.deinit();
        try space_mod.encodeTuple(&tb, row);
        var ob = try proto.update.encodeOps(self.gpa, ops);
        defer ob.deinit();
        return self.push(try space.frameUpsert(&self.frames, tb.items(), ob.items()));
    }

    /// CALL `name` with `args` (tuple/struct or array/slice, positional MP_ARRAY).
    /// Connection-level (no space) — built via the proto request builder the way
    /// `Connection.callRaw` does.
    pub fn call(self: *Batch, name: []const u8, args: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var ab = msgpack.Buffer.init(self.gpa);
        defer ab.deinit();
        try space_mod.encodeTuple(&ab, args);
        const sync = self.conn.nextSync();
        try request.call(&self.frames, sync, name, ab.items());
        return self.push(sync);
    }

    /// EVAL the Lua `expr` with `args`. Connection-level, like `call`.
    pub fn eval(self: *Batch, expr: []const u8, args: anytype) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        var ab = msgpack.Buffer.init(self.gpa);
        defer ab.deinit();
        try space_mod.encodeTuple(&ab, args);
        const sync = self.conn.nextSync();
        try request.eval(&self.frames, sync, expr, ab.items());
        return self.push(sync);
    }

    /// PING. Connection-level; read it back with `expectOk`.
    pub fn ping(self: *Batch) BatchError!Handle {
        if (self.executed) return error.BatchConsumed;
        const sync = self.conn.nextSync();
        try request.ping(&self.frames, sync);
        return self.push(sync);
    }

    /// Append a pending slot for a just-built frame's `sync` and return its
    /// handle (the slot index).
    fn push(self: *Batch, sync: u64) BatchError!Handle {
        const h: Handle = @intCast(self.slots.items.len);
        try self.slots.append(self.gpa, .{ .sync = sync });
        return h;
    }

    // ---- execute (write-all, then read-all-N) -----------------------------

    /// Flush every built frame in ONE write, then read exactly N responses,
    /// parking each by SYNC into its slot (arena-owned copy). An empty batch is a
    /// no-op success. After this returns the connection is idle.
    ///
    /// A per-request SERVER error is parked, not raised (surfaces per handle). A
    /// TRANSPORT error (write/read/parse) or a protocol violation (unknown SYNC /
    /// double-fill -> `error.ProtocolError`) is returned and POISONS the
    /// connection — the caller must close it. Reuse -> `error.BatchConsumed`.
    pub fn execute(self: *Batch) BatchError!void {
        if (self.executed) return error.BatchConsumed;
        self.executed = true;
        if (self.slots.items.len == 0) return; // empty batch: nothing to send.

        try self.conn.sendFrame(self.frames.items());

        var remaining = self.slots.items.len;
        while (remaining > 0) : (remaining -= 1) {
            // Read one frame into the connection's resp_buf (staging); its parsed
            // form there borrows resp_buf and is discarded — ingestFrame copies
            // the RAW frame into the arena and reparses so results outlive it.
            _ = try self.conn.readOneFrame();
            try self.ingestFrame(self.conn.resp_buf.items);
        }
    }

    /// Park ONE raw response frame: copy it into the arena, parse THERE (so the
    /// result slices are arena-owned), apply the shared schema drift mark, and
    /// match its SYNC to a pending slot. An unknown SYNC or a SYNC whose slot is
    /// already filled (double-fill) is `error.ProtocolError`.
    ///
    /// This is the pure core of the read loop — exercised directly by the unit
    /// tests over synthesized in-memory frames (no socket), which is where the
    /// out-of-order matching is proven.
    fn ingestFrame(self: *Batch, raw: []const u8) RequestError!void {
        const a = self.arena.allocator();
        const copy = try a.dupe(u8, raw);
        const resp = try iproto.parseResponse(a, copy);
        self.conn.applySchemaVersion(resp.schema_version);
        const idx = self.findPending(resp.sync) orelse return error.ProtocolError;
        self.slots.items[idx].outcome = outcomeFrom(resp.result);
    }

    /// Linear scan for the PENDING slot stamped with `sync` (N is small). Returns
    /// null when no slot carries that sync OR its slot is already filled — both
    /// are protocol violations the caller maps to `error.ProtocolError`.
    fn findPending(self: *Batch, sync: u64) ?usize {
        for (self.slots.items, 0..) |slot, i| {
            if (slot.sync == sync and slot.outcome == null) return i;
        }
        return null;
    }

    // ---- result accessors (post-execute) ----------------------------------

    /// Raw DATA payload for handle `h`: the OK reply's DATA bytes (or null when
    /// the reply had none), or `error.ServerError` when the slot parked a server
    /// error (details via `serverError`). Arena-owned — valid until `deinit`.
    pub fn dataRaw(self: *Batch, h: Handle) RequestError!?[]const u8 {
        const oc = self.outcomeOf(h);
        return switch (oc.*) {
            .ok => |d| d,
            .err => error.ServerError,
        };
    }

    /// The parked server error for handle `h`, or null when the slot succeeded.
    /// The returned pointer (and its slices) are arena-owned — valid until
    /// `deinit`. Per-slot: unrelated to the connection's `last_error`.
    pub fn serverError(self: *Batch, h: Handle) ?*const ServerErrorInfo {
        const oc = self.outcomeOf(h);
        return switch (oc.*) {
            .err => &oc.err,
            .ok => null,
        };
    }

    /// Decode handle `h`'s DATA as EXACTLY one tuple into `Row` (insert/replace
    /// contract; absent/empty/multi -> `error.ProtocolError`). Surfaces the
    /// slot's `error.ServerError` first. Slice fields in `Row` are arena-owned.
    pub fn decodeOne(self: *Batch, h: Handle, comptime Row: type) RequestError!Row {
        return space_mod.decodeOne(Row, try self.dataRaw(h));
    }

    /// Decode handle `h`'s DATA under a "0 or 1" contract: 0 -> null, 1 -> `Row`,
    /// >=2 -> `error.MoreThanOne` (the get/delete/update shape). Surfaces the
    /// slot's `error.ServerError` first. Slice fields in `Row` are arena-owned.
    pub fn decodeMaybe(self: *Batch, h: Handle, comptime Row: type) RequestError!?Row {
        return space_mod.decodeCapped(Row, try self.dataRaw(h), error.MoreThanOne);
    }

    /// Decode handle `h`'s DATA as the ENTIRE array-of-tuples into a fresh
    /// `gpa`-owned `[]Row` (CALLER FREES via `gpa`); the ELEMENTS' slice fields
    /// remain arena-owned. Surfaces the slot's `error.ServerError` first.
    pub fn decodeMany(self: *Batch, h: Handle, gpa: Allocator, comptime Row: type) RequestError![]Row {
        return space_mod.decodeRows(gpa, Row, try self.dataRaw(h));
    }

    /// Assert handle `h` succeeded (no server error), ignoring any DATA — for
    /// UPSERT/PING and other no-return verbs. Surfaces `error.ServerError` when
    /// the slot parked one.
    pub fn expectOk(self: *Batch, h: Handle) RequestError!void {
        _ = try self.dataRaw(h);
    }

    /// The parked outcome for a valid, filled handle. Both are contract
    /// violations (crash > corrupt): accessing before `execute` filled the slot,
    /// or an out-of-range handle.
    fn outcomeOf(self: *Batch, h: Handle) *const Outcome {
        std.debug.assert(self.executed);
        std.debug.assert(h < self.slots.items.len);
        return &self.slots.items[h].outcome.?;
    }
};

/// Map a parsed response `Result` into a parked `Outcome`. The error's slices
/// (message/stack) already borrow the arena-copied frame, so no extra dup.
fn outcomeFrom(result: iproto.Result) Outcome {
    return switch (result) {
        .ok => |data| .{ .ok = data },
        .err => |e| .{ .err = .{ .code = e.code, .message = e.message, .raw = e.stack } },
    };
}

// ---------------------------------------------------------------------------
// Tests (pure — no sockets; the live path is smoke-tested by the harness)
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A Connection with only the fields the pure batch core reads initialized; the
/// socket/buffer plumbing stays undefined (never touched off the wire). `sync`
/// seeds the adder path; the schema trio seeds `applySchemaVersion`.
fn stubConn() Connection {
    var c: Connection = undefined;
    c.sync = 0;
    c.schema_version = 0;
    c.cached_schema = null;
    c.schema_stale = false;
    return c;
}

/// Synthesize an OK response frame with DATA into `buf`.
fn buildOkData(buf: *msgpack.Buffer, sync: u64, data_mp: []const u8) !void {
    const pos = try iproto.beginFrame(buf);
    try iproto.encodeHeader(buf, .ok, sync, null);
    try buf.writeByte(0x81); // body map, 1 key
    try msgpack.encode(buf, iproto.Key.data);
    try buf.writeAll(data_mp);
    iproto.endFrame(buf, pos);
}

/// Synthesize an OK response frame with NO DATA (ping/upsert shape).
fn buildOkNil(buf: *msgpack.Buffer, sync: u64) !void {
    const pos = try iproto.beginFrame(buf);
    try iproto.encodeHeader(buf, .ok, sync, null);
    try buf.writeByte(0x80); // empty body map
    iproto.endFrame(buf, pos);
}

/// Synthesize an ERROR response frame (type = TYPE_ERROR|code, ERROR_24 msg).
fn buildErr(buf: *msgpack.Buffer, sync: u64, code: u32, message: []const u8) !void {
    const pos = try iproto.beginFrame(buf);
    const t: iproto.RequestType = @fromBackingInt(@intCast(iproto.TYPE_ERROR | code));
    try iproto.encodeHeader(buf, t, sync, null);
    try buf.writeByte(0x81); // body map, 1 key
    try msgpack.encode(buf, iproto.Key.error_24);
    try msgpack.encode(buf, message);
    iproto.endFrame(buf, pos);
}

test "batch builds a multi-frame buffer whose frames parse back with distinct syncs" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();

    const users = conn.space("users");
    _ = try b.insert(users, .{ @as(u32, 1), @as([]const u8, "a") });
    _ = try b.get(users, .{@as(u32, 1)});
    _ = try b.eval("return 1 + 1", .{});

    // Walk the single build buffer: three complete frames, syncs 0,1,2 in order.
    var bytes: []const u8 = b.frames.items();
    var expect_sync: u64 = 0;
    var count: usize = 0;
    while (bytes.len > 0) {
        const fr = try iproto.readFrame(bytes);
        var dec = msgpack.Decoder.init(fr.payload);
        const hdr = try iproto.decodeHeader(testing.allocator, &dec);
        try testing.expectEqual(expect_sync, hdr.sync);
        expect_sync += 1;
        count += 1;
        bytes = bytes[fr.consumed..];
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(usize, 3), b.slots.items.len);
}

test "read-loop matches SHUFFLED responses to slots by sync, incl an error slot" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();

    // Three pending slots (the pure matching core; syncs chosen by hand).
    try b.slots.append(b.gpa, .{ .sync = 10 });
    try b.slots.append(b.gpa, .{ .sync = 11 });
    try b.slots.append(b.gpa, .{ .sync = 12 });
    b.executed = true; // accessors read post-execute state

    // slot0/sync10: OK DATA [42]; slot1/sync11: server error; slot2/sync12: OK no DATA.
    var f10 = msgpack.Buffer.init(testing.allocator);
    defer f10.deinit();
    try buildOkData(&f10, 10, &[_]u8{ 0x91, 0x2a }); // [42]
    var f11 = msgpack.Buffer.init(testing.allocator);
    defer f11.deinit();
    try buildErr(&f11, 11, 3, "Duplicate key exists"); // code 3 (ER_TUPLE_FOUND)
    var f12 = msgpack.Buffer.init(testing.allocator);
    defer f12.deinit();
    try buildOkNil(&f12, 12);

    // Feed OUT OF ORDER: 11, 12, 10.
    try b.ingestFrame(f11.items());
    try b.ingestFrame(f12.items());
    try b.ingestFrame(f10.items());

    // slot0: OK, DATA [42] verbatim (arena-owned copy).
    const d0 = (try b.dataRaw(0)).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x91, 0x2a }, d0);
    // slot1: parked server error (per-slot, not conn.last_error).
    try testing.expectError(error.ServerError, b.dataRaw(1));
    const se = b.serverError(1).?;
    try testing.expectEqual(@as(u32, 3), se.code);
    try testing.expectEqualStrings("Duplicate key exists", se.message);
    // slot2: OK, no DATA — expectOk passes, dataRaw is null, serverError is null.
    try b.expectOk(2);
    try testing.expectEqual(@as(?[]const u8, null), try b.dataRaw(2));
    try testing.expectEqual(@as(?*const ServerErrorInfo, null), b.serverError(2));
    try testing.expectEqual(@as(?*const ServerErrorInfo, null), b.serverError(0));
}

test "read-loop: an unknown sync is a ProtocolError" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();
    try b.slots.append(b.gpa, .{ .sync = 1 });
    b.executed = true;

    var f = msgpack.Buffer.init(testing.allocator);
    defer f.deinit();
    try buildOkNil(&f, 99); // no slot carries sync 99
    try testing.expectError(error.ProtocolError, b.ingestFrame(f.items()));
}

test "read-loop: a second response for an already-filled slot is a ProtocolError" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();
    try b.slots.append(b.gpa, .{ .sync = 7 });
    b.executed = true;

    var f = msgpack.Buffer.init(testing.allocator);
    defer f.deinit();
    try buildOkNil(&f, 7);
    try b.ingestFrame(f.items()); // fills the slot
    // A duplicate reply for sync 7: the slot is no longer pending -> ProtocolError.
    try testing.expectError(error.ProtocolError, b.ingestFrame(f.items()));
}

test "decodeMaybe/decodeOne over a parked OK slot decode the arena-owned DATA" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();
    try b.slots.append(b.gpa, .{ .sync = 1 }); // will hold [[5,"x"]]
    b.executed = true;

    var f = msgpack.Buffer.init(testing.allocator);
    defer f.deinit();
    // DATA = [[5,"x"]] — one tuple of (u32, str).
    try buildOkData(&f, 1, &[_]u8{ 0x91, 0x92, 0x05, 0xa1, 0x78 });
    try b.ingestFrame(f.items());

    const Row = struct { u32, []const u8 };
    const one = try b.decodeOne(0, Row);
    try testing.expectEqual(@as(u32, 5), one[0]);
    try testing.expectEqualStrings("x", one[1]);

    const maybe = (try b.decodeMaybe(0, Row)).?;
    try testing.expectEqual(@as(u32, 5), maybe[0]);
}

/// Synthesize a full EVENT frame (watcher notification) for the park-during-batch
/// test: header {TYPE:EVENT, SYNC:0}, body {EVENT_KEY:key, EVENT_DATA:data_mp}.
fn buildEvent(buf: *msgpack.Buffer, key: []const u8, data_mp: []const u8) !void {
    const pos = try iproto.beginFrame(buf);
    try iproto.encodeHeader(buf, .event, 0, null);
    try buf.writeByte(0x82); // body map, 2 keys
    try msgpack.encode(buf, iproto.Key.event_key);
    try msgpack.encode(buf, key);
    try msgpack.encode(buf, iproto.Key.event_data);
    try buf.writeAll(data_mp);
    iproto.endFrame(buf, pos);
}

test "read loop parks an interleaved EVENT and still matches the response (park-during-batch)" {
    // The batch read loop reads through `Connection.readOneFrame`, which routes
    // every frame through `classifyFrame`: an EVENT is parked into the connection
    // mailbox and the loop reads again; the real response is matched to its slot.
    // Here we drive that same classification directly over synthesized frames (no
    // socket), then ingest the response — proving an EVENT interleaved mid-batch
    // is parked (not mismatched to a slot) and the reply still lands.
    var conn = stubConn();
    conn.gpa = testing.allocator;
    conn.watched = .empty;
    conn.events = .empty;
    conn.delivered = null;
    defer {
        var it = conn.watched.iterator();
        while (it.next()) |e| conn.gpa.free(e.key_ptr.*);
        conn.watched.deinit(conn.gpa);
        for (conn.events.items) |ev| {
            conn.gpa.free(ev.key);
            if (ev.data) |d| conn.gpa.free(d);
        }
        conn.events.deinit(conn.gpa);
    }
    const owned = try testing.allocator.dupe(u8, "cfg");
    try conn.watched.put(conn.gpa, owned, false);

    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();
    try b.slots.append(b.gpa, .{ .sync = 5 });
    b.executed = true;

    var ev = msgpack.Buffer.init(testing.allocator);
    defer ev.deinit();
    try buildEvent(&ev, "cfg", &[_]u8{0x2a}); // EVENT_DATA = 42
    var resp = msgpack.Buffer.init(testing.allocator);
    defer resp.deinit();
    try buildOkData(&resp, 5, &[_]u8{ 0x91, 0x63 }); // DATA = [99]

    // Interleaved EVENT: parked, no slot touched.
    try testing.expect((try conn.classifyFrame(ev.items())) == .parked);
    try testing.expectEqual(@as(usize, 1), conn.events.items.len);
    try testing.expectEqualStrings("cfg", conn.events.items[0].key);

    // The real response: classified as a response, then ingested into its slot.
    const cls = try conn.classifyFrame(resp.items());
    try testing.expect(cls == .response);
    try b.ingestFrame(resp.items());
    const d0 = (try b.dataRaw(0)).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x91, 0x63 }, d0);
    try testing.expectEqual(@as(usize, 1), conn.events.items.len); // event still parked
}

test "empty batch: execute is a no-op success and consumes the batch" {
    var conn = stubConn();
    var b = Batch.init(&conn, testing.allocator);
    defer b.deinit();

    try b.execute(); // zero slots: returns without any I/O on conn

    // Consumed: any adder and a second execute are rejected.
    try testing.expectError(error.BatchConsumed, b.ping());
    const users = conn.space("users");
    try testing.expectError(error.BatchConsumed, b.insert(users, .{@as(u32, 1)}));
    try testing.expectError(error.BatchConsumed, b.execute());
}
