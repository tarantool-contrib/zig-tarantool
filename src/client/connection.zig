//! Live iproto `Connection`: TCP connect, greeting parse, ID feature
//! negotiation, chap-sha1 AUTH, and a single-in-flight request roundtrip
//! (IO model errors).
//!
//! Everything on the wire goes through the landed `tarantool-proto` layer
//! (greeting parse, request builders, response envelope) — this module adds no
//! wire-format code, only the socket plumbing and the negotiation/auth state
//! machine. The connection is `io: std.Io`-parameterized end to end; it never
//! names an Io implementation (tests/exes pick `std.Io.Threaded`).
//!
//! Lifetime: a `Connection` owns its read/write buffers, a reusable response
//! frame buffer, the server version string, the negotiated auth-type, and the
//! `last_error` side channel — all freed by `close()`. The value is move-only:
//! it holds no self-pointers (the buffered reader/writer recover themselves via
//! `@fieldParentPtr` and point at the heap buffers), so it may be relocated
//! between uses, but it must not be *copied* while live — two copies share the
//! same heap buffers and would double-free on `close()`.

const std = @import("std");
const msgpack = @import("msgpack");
const proto = @import("tarantool-proto");
const space_mod = @import("space.zig");
const schema_mod = @import("schema.zig");
const batch_mod = @import("batch.zig");

const iproto = proto.iproto;
const query = proto.query;
const greeting = proto.greeting;
const auth = proto.auth;
const request = iproto.request;
const Key = iproto.Key;
const Response = iproto.Response;
const ResponseError = iproto.ResponseError;
const parseResponse = iproto.parseResponse;
const readFrame = iproto.readFrame;
const decodeHeader = iproto.decodeHeader;
const Schema = schema_mod.Schema;

const net = std.Io.net;

/// Read buffer for the buffered stream reader. Generous so a whole response
/// frame (and then some) lands in one place; heap-owned by the connection.
const read_buf_size: usize = 64 * 1024;
/// Write buffer for the buffered stream writer. Requests are tiny (ID/AUTH/PING
/// are well under a KiB); 4 KiB leaves ample headroom.
const write_buf_size: usize = 4 * 1024;

// ---------------------------------------------------------------------------
// Errors (house module-named families)
// ---------------------------------------------------------------------------

/// Client-level failures raised directly by this module. Transport/protocol
/// family plus the server-error and auth signals; address parsing collapses to
/// `InvalidAddress`.
pub const Error = error{
    /// `address` is not "host:port" with a numeric IP host and a u16 port.
    InvalidAddress,
    /// The peer closed the stream mid-exchange (EndOfStream on a read).
    ConnectionClosed,
    /// A framed reply violated the v1 wire contract (bad size prefix, sync
    /// mismatch, CHUNK/out-of-scope type, malformed header/body).
    ProtocolError,
    /// The server lacks a feature the v1 client requires (SPACE_AND_INDEX_NAMES),
    /// or rejected the ID request outright (floor: Tarantool >= 3.0).
    UnsupportedServer,
    /// AUTH was rejected by the server (details land in `last_error`).
    AuthFailed,
    /// The server answered a request with an error response (details in
    /// `last_error`).
    ServerError,
    /// A `get` (unique-lookup) matched more than one tuple — the request used
    /// `iterator=.eq, limit=2` and the server returned two rows (`get`
    /// never silently drops a match).
    MoreThanOne,
};

/// Errors surfaced by a request roundtrip: the client family, the proto parse
/// errors, and the buffered-stream transport failures.
pub const RequestError = Error || iproto.ParseError || error{ ReadFailed, WriteFailed };

/// Errors surfaced by `connect`: everything a roundtrip can raise plus the
/// socket connect failures and greeting parse failures.
pub const ConnectError = RequestError || net.IpAddress.ConnectError || greeting.Error;

/// Owned copy of a server error response, kept as the connection's `last_error`
/// side channel. Replaced on each new server error, freed on `close()`.
pub const ServerError = struct {
    /// iproto error code (low 15 bits of the error response type).
    code: u32,
    /// Plain ERROR_24 message text (always present on an error response).
    message: []u8,
    /// Structured MP_ERROR (0x52) stack, kept as raw msgpack bytes; null when
    /// the peer omitted it.
    raw: ?[]u8,
};

/// A delivered watcher notification handed to the caller by `waitEvent`/
/// `pollEvent`. `key` is the notified key name; `data` is the current payload as
/// raw msgpack (null when the key holds no value). Both slices are OWNED by the
/// connection but BORROWED by the caller: they stay valid only until the NEXT
/// pump call (`waitEvent`/`pollEvent`) or `close()` — the connection frees the
/// previously delivered event when it hands out the next one. Copy them
/// before the next pump if they must outlive it.
pub const Event = struct {
    key: []const u8,
    data: ?[]const u8,
};

/// An event parked in the mailbox: an OWNED copy of `parseEvent`'s frame-borrowed
/// slices (the connection's `resp_buf` is transient, so a parked event must not
/// borrow it). Freed either when delivered-then-superseded, or on `close`.
const OwnedEvent = struct {
    key: []u8,
    data: ?[]u8,
};

/// The routing outcome of `classifyFrame`: a real `Response` (borrowing the frame
/// bytes) or `.parked` when the frame was an EVENT already copied into the
/// mailbox. The read loops keep reading on `.parked` and return on `.response`.
pub const FrameClass = union(enum) {
    response: Response,
    parked: void,
};

/// Connection options. `address` is "host:port" text with a numeric IP host;
/// guest with an empty password skips AUTH entirely.
pub const ConnectOptions = struct {
    address: []const u8,
    user: []const u8 = "guest",
    password: []const u8 = "",
    timeout: std.Io.Timeout = .none,
};

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: []u8,
    write_buf: []u8,
    /// Reusable buffer holding the most recent response frame (size prefix +
    /// payload). A `Response` returned by `roundtrip` borrows from here and stays
    /// valid until the next roundtrip (single in-flight).
    resp_buf: std.ArrayList(u8),
    /// Monotonic per-request sync counter. ID uses 0, AUTH 1, then requests.
    sync: u64,
    /// Server version text from the greeting (owned copy), e.g. "3.8.0".
    server_version: []const u8,
    /// Negotiated feature intersection as a bitmask keyed by `Feature` bit
    /// position (bit i set == both peers speak feature i).
    features: u64,
    /// AUTH_TYPE advertised in the ID reply (owned copy), or null if absent.
    auth_type: ?[]u8,
    /// Most recent server error (owned), or null. See `ServerError`.
    last_error: ?ServerError,
    /// Latest SCHEMA_VERSION (0x05) seen on a response header, or 0 before any
    /// response has carried one. Updated on every `roundtrip`; the Schema cache
    /// reads this counter to decide when to refetch. No policy here — just the
    /// monotonic value the server stamps on each reply.
    schema_version: u64 = 0,
    /// Lazily-populated owned schema snapshot, or null before the first
    /// `schema()`/`refreshSchema()` call. Freed on `close()`. Connections that
    /// never ask for schema pay zero fetch round-trips.
    cached_schema: ?schema_mod.Schema = null,
    /// Set true by `roundtrip` when a reply's SCHEMA_VERSION diverges from the
    /// CACHE's version (DDL drift). MARK ONLY — `roundtrip` never refetches
    /// inline (single in-flight + resp_buf borrowing forbid nested
    /// requests mid-response); the next `schema()` repopulates and clears it.
    schema_stale: bool = false,

    // ---- watcher mailbox (caller-pumped event queue) ----------------------
    //
    // The watch protocol is ack-based and unsolicited: after WATCH{key} the
    // server sends ONE EVENT (current state), then stays silent for that key
    // until re-armed by another WATCH. The read path PARKS owned EVENT copies
    // here instead of erroring on an unexpected frame; the caller pumps them out
    // via `waitEvent`/`pollEvent`. No background reader — the only I/O
    // initiators are the caller's own calls.

    /// Registered watch keys (owned copies). The value is the "re-arm owed" flag:
    /// `pollEvent` (no-I/O) sets it true on delivery instead of sending the WATCH
    /// ack; `waitEvent` flushes owed re-arms (I/O) at its start. Freed on `close`.
    watched: std.StringHashMapUnmanaged(bool) = .empty,
    /// FIFO mailbox of parked events (owned copies), delivery order across keys.
    /// Drained by `waitEvent`/`pollEvent`; freed on `close`.
    events: std.ArrayListUnmanaged(OwnedEvent) = .empty,
    /// The event most recently handed to the caller, still borrowed by them.
    /// Freed when the next pump hands out its successor, or on `close`.
    delivered: ?OwnedEvent = null,

    /// Connect to `opts.address`, complete the greeting/ID/AUTH handshake, and
    /// return a ready connection. Every error path closes the stream and frees
    /// any state allocated so far. REQUIRES the server to negotiate
    /// SPACE_AND_INDEX_NAMES (else `error.UnsupportedServer`). AUTH is performed
    /// unless the user is `guest` with an empty password.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, opts: ConnectOptions) ConnectError!Connection {
        const addr = try parseAddress(opts.address);

        var stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream, .timeout = opts.timeout });
        errdefer stream.close(io);

        const read_buf = try gpa.alloc(u8, read_buf_size);
        errdefer gpa.free(read_buf);
        const write_buf = try gpa.alloc(u8, write_buf_size);
        errdefer gpa.free(write_buf);

        var self: Connection = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .read_buf = read_buf,
            .write_buf = write_buf,
            .resp_buf = .empty,
            .sync = 0,
            .server_version = "",
            .features = 0,
            .auth_type = null,
            .last_error = null,
        };
        // resp_buf/server_version/auth_type/last_error each get freed here on any
        // error after this point; the stream + raw buffers keep their own
        // errdefers above (disjoint resources, no double free).
        errdefer self.resp_buf.deinit(gpa);
        errdefer self.freeOwnedState();

        // Greeting: exactly 128 bytes, then parse version/uuid/salt.
        var greeting_bytes: [128]u8 = undefined;
        self.reader.interface.readSliceAll(&greeting_bytes) catch |e| return mapReadError(e);
        const g = try greeting.parse(&greeting_bytes);
        self.server_version = try gpa.dupe(u8, g.version);

        // ID: negotiate features (requires SPACE_AND_INDEX_NAMES), record auth_type.
        try self.negotiateId();

        // AUTH: chap-sha1 scramble unless guest+empty.
        if (shouldAuth(opts.user, opts.password)) {
            const scr = auth.scramble(opts.password, &g.salt);
            try self.authenticate(opts.user, &scr);
        }

        return self;
    }

    /// Close the stream and free all owned state. NOT idempotent — calling it
    /// twice double-frees; call exactly once per successful `connect`.
    pub fn close(self: *Connection) void {
        self.stream.close(self.io);
        if (self.cached_schema) |*cs| cs.deinit();
        self.freeMailbox();
        self.freeOwnedState();
        self.resp_buf.deinit(self.gpa);
        self.gpa.free(self.read_buf);
        self.gpa.free(self.write_buf);
    }

    /// True when `feature` was negotiated (both peers speak it).
    pub fn hasFeature(self: *const Connection, feature: iproto.Feature) bool {
        return (self.features & featureBit(feature)) != 0;
    }

    /// Build a `Space` value handle bound to this connection and `name`.
    /// Infallible and does no I/O (names resolve server-side per request; a
    /// bad name surfaces as `error.ServerError` on first use). `name` is
    /// borrowed — the caller keeps it alive (typically a string literal).
    pub fn space(self: *Connection, name: []const u8) space_mod.Space {
        return .{ .conn = self, .name = name };
    }

    /// Open a `Batch` bound to this connection: build N request frames (verb
    /// adders), `execute()` to flush them in one write and read all N replies
    /// matched by sync, then read per-handle results. `gpa` backs the batch's
    /// arena (which owns the copied result frames) plus its frame/slot buffers;
    /// the batch is freed by `batch.deinit()`, independent of this connection's
    /// lifetime for the buffers (though its handles reference this connection
    /// during `execute`). One batch is one flight — see `batch.zig`.
    pub fn batch(self: *Connection, gpa: std.mem.Allocator) batch_mod.Batch {
        return batch_mod.Batch.init(self, gpa);
    }

    /// Return the current schema snapshot, fetching it on first use or after a
    /// drift mark. When `cached_schema` is present and not stale, this is a
    /// pointer into the cache and does NO I/O; otherwise it fetches `_vspace`/
    /// `_vindex` (two SELECTs by name), rebuilds, and swaps the cache. The
    /// returned pointer is valid until the next fetch (a later `schema()` after
    /// drift, or `refreshSchema`) — do not retain it across a request that could
    /// mark the schema stale. Connections that never call this pay no fetch.
    pub fn schema(self: *Connection) RequestError!*const Schema {
        if (self.cached_schema == null or self.schema_stale) try self.fetchSchema();
        return &self.cached_schema.?;
    }

    /// Force a fresh schema fetch regardless of staleness (deterministic timing
    /// for callers who want it), replacing any cached snapshot.
    pub fn refreshSchema(self: *Connection) RequestError!void {
        try self.fetchSchema();
    }

    /// PING (0x40): a bare liveness roundtrip. Any OK reply (with or without
    /// DATA) is success; a server error surfaces as `error.ServerError`.
    pub fn ping(self: *Connection) RequestError!void {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.ping(&buf, sync);
        _ = try self.roundtrip(buf.items(), sync);
    }

    /// CALL (0x0a) with a pre-encoded MP_ARRAY of arguments. Returns the raw DATA
    /// payload — the function's returns array as msgpack bytes — or null when the
    /// reply carries no DATA. The returned slice BORROWS `resp_buf` and stays valid
    /// only until the next request on this connection (single in-flight);
    /// copy it before issuing another call if it must outlive that. A server error
    /// records `last_error` and surfaces as `error.ServerError` (identical to
    /// `ping`).
    pub fn callRaw(self: *Connection, name: []const u8, args_mp: []const u8) RequestError!?[]const u8 {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.call(&buf, sync, name, args_mp);
        return okData(try self.roundtrip(buf.items(), sync));
    }

    /// EVAL (0x08) of a Lua expression with a pre-encoded MP_ARRAY of arguments.
    /// Return/ownership/error semantics are identical to `callRaw`.
    pub fn evalRaw(self: *Connection, expr: []const u8, args_mp: []const u8) RequestError!?[]const u8 {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.eval(&buf, sync, expr, args_mp);
        return okData(try self.roundtrip(buf.items(), sync));
    }

    /// Comptime-typed CALL convenience. `args`
    /// is a tuple/struct or array/slice, encoded positionally to the MP_ARRAY the
    /// wire wants (the house idiom: `.{a, b}`). `Result` is the type of the single
    /// value the function returns: the reply's returns array must hold EXACTLY one
    /// element, decoded into `Result` (a composite single return decodes into a
    /// tuple struct). `Result == void` ignores the DATA entirely. A wrong return
    /// arity is `error.ArityMismatch`; a call/eval reply with no DATA at all is
    /// `error.ProtocolError`.
    ///
    /// OWNERSHIP: decoding is allocation-free; any slice fields in `Result` (e.g.
    /// `[]const u8`) borrow `resp_buf` and are valid only until the next request
    /// (same lifetime as `callRaw`'s DATA). Copy before the next call if needed.
    pub fn call(self: *Connection, name: []const u8, args: anytype, comptime Result: type) RequestError!Result {
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try encodeArgs(&buf, args);
        return decodeReturns(Result, try self.callRaw(name, buf.items()));
    }

    /// Comptime-typed EVAL convenience. Args/Result/ownership semantics are
    /// identical to `call`.
    pub fn eval(self: *Connection, expr: []const u8, args: anytype, comptime Result: type) RequestError!Result {
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try encodeArgs(&buf, args);
        return decodeReturns(Result, try self.evalRaw(expr, buf.items()));
    }

    // ---- watchers (caller-pumped event queue) -----------------------------

    /// Register interest in `key` and send WATCH (fire-and-forget — NO response
    /// is read; the server answers only with an asynchronous EVENT). Requires the
    /// `watchers` feature (else `error.UnsupportedServer`). Idempotent: re-watching
    /// an already-registered key just re-sends WATCH (a harmless re-arm) and keeps
    /// the single owned key copy. The key is duped (owned until `unwatch`/`close`).
    pub fn watch(self: *Connection, key: []const u8) RequestError!void {
        if (!self.hasFeature(.watchers)) return error.UnsupportedServer;
        const gop = try self.watched.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            const owned = self.gpa.dupe(u8, key) catch |e| {
                std.debug.assert(self.watched.remove(key));
                return e;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = false; // no re-arm owed yet
        }
        try self.sendWatch(key);
    }

    /// Unregister `key` and send UNWATCH (fire-and-forget). After this the read
    /// path DROPS any further EVENTs for `key` (they are no longer registered).
    /// An unknown key is a no-op (no UNWATCH is sent) — unwatching what was never
    /// watched has no wire meaning. Already-queued events for `key` (parked while
    /// it was registered) still deliver; only events arriving AFTER unwatch drop.
    pub fn unwatch(self: *Connection, key: []const u8) RequestError!void {
        const kv = self.watched.fetchRemove(key) orelse return; // unknown: no-op
        self.gpa.free(kv.key);
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.unwatch(&buf, sync, key);
        try self.sendFrame(buf.items()); // fire-and-forget: no response to read
    }

    /// Pump the mailbox, BLOCKING until an event is available (no timeout — the
    /// net vtable read carries none; `pollEvent` is the non-blocking half). When
    /// the queue is non-empty this pops the head; otherwise it reads frames until
    /// an EVENT arrives, parking each (owned copy) and popping the head. Because
    /// NO request is outstanding, any NON-EVENT frame read here violates the wire
    /// contract → `error.ProtocolError`. On delivery: the previously delivered
    /// event is freed (borrow-until-next-pump) and — if the key is still
    /// registered — WATCH is re-sent to re-arm delivery (the protocol ack).
    pub fn waitEvent(self: *Connection) RequestError!Event {
        try self.flushRearm(); // ack re-arms owed by earlier pollEvent deliveries
        while (self.events.items.len == 0) {
            try self.readResponseFrame();
            if (!try self.isEventFrame(self.resp_buf.items)) return error.ProtocolError;
            try self.parkEvent(self.resp_buf.items);
        }
        const out = self.takeDelivered(self.events.orderedRemove(0));
        if (self.watched.getPtr(out.key)) |owed| {
            owed.* = false;
            try self.sendWatch(out.key); // immediate ack (re-arm)
        }
        return out;
    }

    /// Non-blocking half of `waitEvent`: return the head of the mailbox if one is
    /// already queued, else null. Does NO read I/O (never blocks). On delivery it
    /// frees the previously delivered event (borrow-until-next-pump); the
    /// re-arm ack is DEFERRED (marked "owed") rather than sent, so this stays
    /// I/O-free — the next `waitEvent` flushes owed re-arms. A key delivered ONLY
    /// via `pollEvent` therefore does not receive further events until a
    /// `waitEvent` re-arms it (documented; `pollEvent` is the escape hatch, not
    /// the steady-state pump).
    pub fn pollEvent(self: *Connection) ?Event {
        if (self.events.items.len == 0) return null;
        const out = self.takeDelivered(self.events.orderedRemove(0));
        if (self.watched.getPtr(out.key)) |owed| owed.* = true; // defer re-arm (no I/O)
        return out;
    }

    /// WATCH_ONCE (0x4d): fetch the current value of `key` as an ORDINARY
    /// request/response (no registration, no re-arm, does not touch the mailbox).
    /// Requires the `watch_once` feature (else `error.UnsupportedServer`). The
    /// reply's IPROTO_DATA (0x30) is a returns ARRAY of arity 1 holding the key's
    /// current value — the SAME shape as call/eval (live-probed on 3.8.0: DATA =
    /// `dd 00 00 00 01 <value>`), so it decodes through the identical
    /// `decodeReturns` path. `Result == void` ignores DATA; a key with no value
    /// comes back as `[nil]` (decode into an optional `Result` to see it as null).
    /// Slice fields in `Result` borrow `resp_buf` (valid until the next request,
    /// same ownership as `call`).
    pub fn watchOnce(self: *Connection, key: []const u8, comptime Result: type) RequestError!Result {
        if (!self.hasFeature(.watch_once)) return error.UnsupportedServer;
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.watchOnce(&buf, sync, key);
        return decodeReturns(Result, okData(try self.roundtrip(buf.items(), sync)));
    }

    /// Build + send a WATCH{key} frame, fire-and-forget (no response is read).
    /// Used both by `watch` (initial arm) and by the delivery re-arm (ack).
    fn sendWatch(self: *Connection, key: []const u8) RequestError!void {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.watch(&buf, sync, key);
        try self.sendFrame(buf.items());
    }

    /// Send the WATCH ack for every registered key with a re-arm owed (set by a
    /// prior `pollEvent`), clearing each flag. No-op when nothing is owed. This is
    /// the I/O the no-I/O `pollEvent` defers to the next `waitEvent`.
    fn flushRearm(self: *Connection) RequestError!void {
        var it = self.watched.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) {
                entry.value_ptr.* = false;
                try self.sendWatch(entry.key_ptr.*);
            }
        }
    }

    /// Move `ev` into the `delivered` slot (freeing the previously delivered
    /// event) and return a borrowing `Event` view. The caller borrows the
    /// slices until the next pump call frees this slot in turn.
    fn takeDelivered(self: *Connection, ev: OwnedEvent) Event {
        if (self.delivered) |prev| self.freeEvent(prev);
        self.delivered = ev;
        return .{ .key = ev.key, .data = ev.data };
    }

    /// True when the framed packet in `raw` is an EVENT (watcher notification),
    /// so the read path parks it instead of treating it as a response. Peeks the
    /// header REQUEST_TYPE via the proto header decoder (transient walk only).
    fn isEventFrame(self: *Connection, raw: []const u8) RequestError!bool {
        const fr = try iproto.readFrame(raw);
        var dec = msgpack.Decoder.init(fr.payload);
        const hdr = try decodeHeader(self.gpa, &dec);
        return hdr.type == @backingInt(iproto.RequestType.event);
    }

    /// Park an EVENT frame into the mailbox as an OWNED copy (its `parseEvent`
    /// slices borrow the transient `resp_buf`, so they must be duped). An
    /// event for a key that is NOT currently registered is DROPPED (documented):
    /// it belongs to a watch already dropped by `unwatch`. `pub` so the batch
    /// read loop routes parked EVENTs through the identical path.
    pub fn parkEvent(self: *Connection, raw: []const u8) RequestError!void {
        const ev = try iproto.parseEvent(raw); // borrows raw
        if (!self.watched.contains(ev.key)) return; // drop unregistered (documented)
        const key_copy = try self.gpa.dupe(u8, ev.key);
        errdefer self.gpa.free(key_copy);
        const data_copy = if (ev.data) |d| try self.gpa.dupe(u8, d) else null;
        try self.events.append(self.gpa, .{ .key = key_copy, .data = data_copy });
    }

    /// Classify a framed packet already staged in (or synthesized like) `resp_buf`:
    /// an EVENT is parked into the mailbox and reported as `.parked` (caller reads
    /// again); every other frame parses into a `Response`. This is the pure routing
    /// core the roundtrip/batch read loops share — unit-tested directly over
    /// synthesized frames (no socket), the way `Batch.ingestFrame` is.
    pub fn classifyFrame(self: *Connection, raw: []const u8) RequestError!FrameClass {
        if (try self.isEventFrame(raw)) {
            try self.parkEvent(raw);
            return .parked;
        }
        return .{ .response = try parseResponse(self.gpa, raw) };
    }

    /// Free one owned event's slices.
    fn freeEvent(self: *Connection, ev: OwnedEvent) void {
        self.gpa.free(ev.key);
        if (ev.data) |d| self.gpa.free(d);
    }

    /// Free the watcher mailbox: registered keys + map, queued events, and the
    /// borrowed delivered slot. Part of `close`'s teardown.
    fn freeMailbox(self: *Connection) void {
        var it = self.watched.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.watched.deinit(self.gpa);
        for (self.events.items) |ev| self.freeEvent(ev);
        self.events.deinit(self.gpa);
        if (self.delivered) |ev| {
            self.freeEvent(ev);
            self.delivered = null;
        }
    }

    // ---- internals --------------------------------------------------------

    /// The single-in-flight primitive: write one already-built frame (the SEND
    /// half of the build/send seam — `Space`/`Batch` build frames separately and
    /// hand the bytes here), read one response frame, parse it, and verify the
    /// sync echoes the request. Any SCHEMA_VERSION on the reply header updates
    /// `schema_version`. A server error response is recorded into `last_error`
    /// and surfaced as `error.ServerError`; the returned `Response` is therefore
    /// always an OK result whose slices borrow `resp_buf` (valid until the next
    /// roundtrip). `pub` so sibling handles (`space.zig`) can reuse it.
    ///
    /// Composed from the reusable halves `Batch` also drives: `sendFrame` (write
    /// + flush), `readOneFrame` (read one frame into `resp_buf` + parse), and
    /// `applySchemaVersion` (the shared drift mark). Batch differs only in that it
    /// flushes MANY frames in one `sendFrame` and loops `readOneFrame` N times.
    pub fn roundtrip(self: *Connection, frame: []const u8, expected_sync: u64) RequestError!Response {
        try self.sendFrame(frame);
        const resp = try self.readOneFrame();
        if (resp.sync != expected_sync) return error.ProtocolError;
        self.applySchemaVersion(resp.schema_version);
        switch (resp.result) {
            .ok => return resp,
            .err => |se| {
                try self.storeError(se);
                return error.ServerError;
            },
        }
    }

    /// SEND half of the seam: write one already-built frame buffer and flush it.
    /// The buffer may hold ONE frame (`roundtrip`) or MANY concatenated frames
    /// (`Batch.execute` flushes its whole build buffer in a single call). `pub`
    /// for the sibling `batch.zig`. A transport failure is `error.WriteFailed`.
    pub fn sendFrame(self: *Connection, frame: []const u8) RequestError!void {
        self.writer.interface.writeAll(frame) catch return error.WriteFailed;
        self.writer.interface.flush() catch return error.WriteFailed;
    }

    /// READ half of the seam: read exactly one framed response into `resp_buf`
    /// and parse it. The returned `Response` and the raw frame in `resp_buf`
    /// both borrow `resp_buf` (valid until the next read). Applies NO policy
    /// (no sync check, no schema mark, no error raise) — `roundtrip` layers those
    /// on; `Batch.execute` copies the raw `resp_buf` frame into its arena and
    /// re-parses there so results outlive the next read. `pub` for `batch.zig`.
    /// Reads frames until a NON-EVENT (response) frame arrives, PARKING any EVENT
    /// frames read along the way (watcher notifications the server interleaves
    /// with responses — the ack protocol lets them arrive mid-roundtrip/batch).
    /// Parked events are owned copies routed through `classifyFrame`; the returned
    /// `Response` and `resp_buf` hold the real (non-event) reply. Both `roundtrip`
    /// and `Batch.execute` read through here, so BOTH inherit EVENT parking (parking happens entirely inside this read-loop call).
    pub fn readOneFrame(self: *Connection) RequestError!Response {
        while (true) {
            try self.readResponseFrame();
            switch (try self.classifyFrame(self.resp_buf.items)) {
                .response => |resp| return resp,
                .parked => {}, // EVENT parked into the mailbox; read the next frame
            }
        }
    }

    /// Apply a reply's SCHEMA_VERSION: record the latest value and MARK the cache
    /// stale on divergence (mark-only, never refetch inline). Shared by
    /// `roundtrip` and `Batch.execute`'s read loop so drift detection is
    /// identical on both paths (not duplicated). `pub` for `batch.zig`.
    pub fn applySchemaVersion(self: *Connection, schema_version: ?u64) void {
        const sv = schema_version orelse return;
        self.schema_version = sv;
        // Drift detection is MARK-ONLY: compare against the CACHE's
        // version, never refetch here. The next schema() repopulates.
        if (self.cached_schema) |cs| {
            if (sv != cs.version) self.schema_stale = true;
        }
    }

    /// Fetch `_vspace`/`_vindex` (two SELECTs by name, iterator=all, unbounded
    /// limit), rebuild the owned `Schema`, and swap it into the cache. Goes
    /// entirely through the existing `Space.selectRaw` machinery — no new wire
    /// code. CAREFUL: both DATA payloads live in the single reused
    /// `resp_buf`; the second SELECT clobbers the first, so the `_vspace` bytes
    /// are copied to a heap buffer before the `_vindex` SELECT is issued.
    fn fetchSchema(self: *Connection) RequestError!void {
        const opts: query.SelectOptions = .{ .iterator = .all, .offset = 0, .limit = null };
        const empty_key = [_]u8{0x90}; // empty MP_ARRAY key -> full-scan every tuple

        // _vspace first; its DATA borrows resp_buf, so copy it out before the
        // _vindex SELECT overwrites resp_buf.
        const vspace_src = (try self.space("_vspace").selectRaw(&empty_key, opts)) orelse return error.ProtocolError;
        const vspace_copy = try self.gpa.dupe(u8, vspace_src);
        defer self.gpa.free(vspace_copy);

        // _vindex second; its DATA is still live in resp_buf while we build.
        const vindex_data = (try self.space("_vindex").selectRaw(&empty_key, opts)) orelse return error.ProtocolError;

        var built = try schema_mod.buildSchema(self.gpa, self.schema_version, vspace_copy, vindex_data);
        errdefer built.deinit();

        if (self.cached_schema) |*old| old.deinit();
        self.cached_schema = built;
        self.schema_stale = false;
    }

    /// Read one framed response into `resp_buf`: decode the MP_UINT size prefix,
    /// then read exactly that many payload bytes. `resp_buf` ends holding the
    /// full frame (prefix + payload) so `parseResponse` can re-read the size.
    fn readResponseFrame(self: *Connection) RequestError!void {
        const r = &self.reader.interface;
        const first = r.peekByte() catch |e| return mapReadError(e);
        const prefix_len = mpUintPrefixLen(first) orelse return error.ProtocolError;
        const prefix = r.take(prefix_len) catch |e| return mapReadError(e);

        var dec = msgpack.Decoder.init(prefix);
        const size = msgpack.decode(u64, &dec) catch return error.ProtocolError;

        self.resp_buf.clearRetainingCapacity();
        try self.resp_buf.appendSlice(self.gpa, prefix);
        const dst = try self.resp_buf.addManyAsSlice(self.gpa, size);
        r.readSliceAll(dst) catch |e| return mapReadError(e);
    }

    /// Send the ID request and record the negotiated feature intersection +
    /// auth_type. Requires SPACE_AND_INDEX_NAMES; a rejected ID (error response)
    /// or a missing required feature is `error.UnsupportedServer`.
    fn negotiateId(self: *Connection) RequestError!void {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.id(&buf, sync, &iproto.v1_features);

        _ = self.roundtrip(buf.items(), sync) catch |e| switch (e) {
            // A peer that predates the ID request answers it with an error.
            error.ServerError => return error.UnsupportedServer,
            else => return e,
        };

        // The ID reply carries VERSION/FEATURES/AUTH_TYPE directly in the body
        // (not under DATA), so parse it off the retained frame ourselves.
        const info = try parseIdReply(self.gpa, self.resp_buf.items);
        if ((info.features & featureBit(.space_and_index_names)) == 0)
            return error.UnsupportedServer;
        self.features = info.features;
        if (info.auth_type) |at| self.auth_type = try self.gpa.dupe(u8, at);
    }

    /// Send the AUTH request with a ready chap-sha1 scramble; a rejection
    /// (server error) maps to `error.AuthFailed` (message still in `last_error`).
    fn authenticate(self: *Connection, user: []const u8, scramble: *const [20]u8) RequestError!void {
        const sync = self.nextSync();
        var buf = msgpack.Buffer.init(self.gpa);
        defer buf.deinit();
        try request.auth(&buf, sync, user, scramble);

        _ = self.roundtrip(buf.items(), sync) catch |e| switch (e) {
            error.ServerError => return error.AuthFailed,
            else => return e,
        };
    }

    /// Allocate the next per-request SYNC. `pub` so the `space.zig` frame
    /// builders — the BUILD half of the build/send seam — can stamp the same
    /// value they later hand to `roundtrip`.
    pub fn nextSync(self: *Connection) u64 {
        const s = self.sync;
        self.sync += 1;
        return s;
    }

    /// Replace `last_error` with an owned copy of `se`, freeing the previous one.
    fn storeError(self: *Connection, se: ResponseError) error{OutOfMemory}!void {
        const message = try self.gpa.dupe(u8, se.message);
        errdefer self.gpa.free(message);
        const raw = if (se.stack) |s| try self.gpa.dupe(u8, s) else null;
        self.freeLastError();
        self.last_error = .{ .code = se.code, .message = message, .raw = raw };
    }

    fn freeLastError(self: *Connection) void {
        if (self.last_error) |le| {
            self.gpa.free(le.message);
            if (le.raw) |r| self.gpa.free(r);
            self.last_error = null;
        }
    }

    /// Free the version/auth_type/last_error trio (used both by the `connect`
    /// error-unwind and by `close`). Does not touch the raw buffers or stream.
    fn freeOwnedState(self: *Connection) void {
        self.freeLastError();
        if (self.auth_type) |at| {
            self.gpa.free(at);
            self.auth_type = null;
        }
        if (self.server_version.len != 0) {
            self.gpa.free(self.server_version);
            self.server_version = "";
        }
    }
};

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested without sockets)
// ---------------------------------------------------------------------------

/// Split "host:port" (numeric IP host) into a parsed `IpAddress`. Any malformed
/// input — no port separator, non-numeric port, unparseable host — collapses to
/// `error.InvalidAddress`.
fn parseAddress(address: []const u8) error{InvalidAddress}!net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress;
    const host = address[0..colon];
    const port_text = address[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidAddress;
    return net.IpAddress.parse(host, port) catch error.InvalidAddress;
}

/// AUTH is skipped only for the guest user with an empty password; every
/// other combination authenticates.
fn shouldAuth(user: []const u8, password: []const u8) bool {
    return !(std.mem.eql(u8, user, "guest") and password.len == 0);
}

/// Extract the raw DATA slice from a roundtrip result. `roundtrip` guarantees an
/// OK response (server errors are raised before it returns), so the `.err` arm
/// is unreachable.
fn okData(resp: Response) ?[]const u8 {
    return switch (resp.result) {
        .ok => |data| data,
        .err => unreachable,
    };
}

/// Encode call/eval `args` into `buf` as a single positional MP_ARRAY. A
/// tuple/struct is emitted field-order via the codec's `encodeArray` (so a named
/// struct becomes a positional array, not a map); an array/slice goes through
/// `encode` (already an MP_ARRAY). Any other shape is a compile error — args must
/// be an argument list, never a bare scalar.
fn encodeArgs(buf: *msgpack.Buffer, args: anytype) !void {
    const T = @TypeOf(args);
    switch (@typeInfo(T)) {
        .@"struct" => try msgpack.encodeArray(buf, args),
        .array, .pointer => try msgpack.encode(buf, args),
        else => @compileError("call/eval args must be a tuple/struct or array/slice (MP_ARRAY), got " ++ @typeName(T)),
    }
}

/// Decode the single return value of a call/eval out of the raw DATA returns
/// array into `Result`. `void` ignores DATA and returns immediately. Otherwise
/// DATA must be present (its absence is `error.ProtocolError` — call/eval always
/// carry a returns array) and hold exactly one element: it is decoded as a
/// one-field tuple via the codec, so a returns array of any other arity surfaces
/// as `error.ArityMismatch`. Slice fields in `Result` borrow the DATA bytes
/// (which borrow `resp_buf`); see `call`'s ownership note.
fn decodeReturns(comptime Result: type, data: ?[]const u8) RequestError!Result {
    if (comptime Result == void) return;
    const bytes = data orelse return error.ProtocolError;
    var dec = msgpack.Decoder.init(bytes);
    const Returns = @Tuple(&.{Result});
    const returns = try msgpack.decode(Returns, &dec);
    return returns[0];
}

/// The `Feature` bit as a one-hot u64 mask.
fn featureBit(feature: iproto.Feature) u64 {
    return @as(u64, 1) << @backingInt(feature);
}

/// Total byte length (prefix byte included) of an MP_UINT written as `first`,
/// or null when `first` is not an MP_UINT lead byte. Covers the fixint form and
/// the uint8/16/32/64 forms; Tarantool writes the size as `0xce` + u32BE.
fn mpUintPrefixLen(first: u8) ?usize {
    if (first <= 0x7f) return 1; // positive fixint: the value is the whole prefix
    return switch (first) {
        0xcc => 2,
        0xcd => 3,
        0xce => 5,
        0xcf => 9,
        else => null,
    };
}

/// Decoded ID reply: the server's advertised feature bitmask and (borrowed from
/// `frame`) the optional AUTH_TYPE string.
const IdReply = struct {
    features: u64,
    auth_type: ?[]const u8,
};

/// Parse an ID response frame for FEATURES (0x55) and AUTH_TYPE (0x5b). The
/// server sends its FULL feature list; we intersect locally against
/// `v1_features` so the recorded mask is the mutual set. VERSION (0x54) is
/// ignored (the human-readable version comes from the greeting). Slices in the
/// result borrow from `frame`.
fn parseIdReply(gpa: std.mem.Allocator, frame: []const u8) iproto.ParseError!IdReply {
    const fr = try readFrame(frame);
    var dec = msgpack.Decoder.init(fr.payload);
    _ = try decodeHeader(gpa, &dec); // advance past the header map

    // msgpack.zig exposes no public map-header *reader*, so walk the body as a
    // schemaless Value (its str/bin leaves borrow `frame`, not the freed nodes).
    const body = try dec.decodeValue(gpa);
    defer msgpack.freeValue(gpa, body);

    const kvs = switch (body) {
        .map => |m| m,
        else => return error.NotMap,
    };

    var server_features: u64 = 0;
    var auth_type: ?[]const u8 = null;
    for (kvs) |kv| {
        const key = switch (kv.key) {
            .uint => |u| u,
            else => continue,
        };
        switch (key) {
            @backingInt(Key.features) => {
                const arr = switch (kv.value) {
                    .array => |a| a,
                    else => return error.NotArray,
                };
                for (arr) |elem| {
                    const bit = switch (elem) {
                        .uint => |u| u,
                        else => continue,
                    };
                    if (bit < 64) server_features |= @as(u64, 1) << @intCast(bit);
                }
            },
            @backingInt(Key.auth_type) => {
                auth_type = switch (kv.value) {
                    .str => |s| s,
                    else => null,
                };
            },
            else => {},
        }
    }

    return .{ .features = server_features & localFeatureMask(), .auth_type = auth_type };
}

/// The mask of features this client advertises in ID (`v1_features`).
fn localFeatureMask() u64 {
    var mask: u64 = 0;
    inline for (iproto.v1_features) |f| mask |= featureBit(f);
    return mask;
}

/// Map a buffered-reader error onto the client family: a closed peer becomes
/// `ConnectionClosed`, a transport failure stays `ReadFailed`.
fn mapReadError(e: std.Io.Reader.Error) RequestError {
    return switch (e) {
        error.EndOfStream => error.ConnectionClosed,
        error.ReadFailed => error.ReadFailed,
    };
}

// ---------------------------------------------------------------------------
// Tests (pure; no sockets — the live path is smoke-tested by the harness)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "shouldAuth: only guest with empty password skips AUTH" {
    try testing.expect(!shouldAuth("guest", ""));
    try testing.expect(shouldAuth("guest", "x")); // guest with a password authenticates
    try testing.expect(shouldAuth("tester", "")); // non-guest always authenticates
    try testing.expect(shouldAuth("tester", "secret"));
    try testing.expect(shouldAuth("guestx", "")); // not exactly "guest"
}

test "mpUintPrefixLen: fixint / uintN forms and rejects non-uint lead bytes" {
    try testing.expectEqual(@as(?usize, 1), mpUintPrefixLen(0x00));
    try testing.expectEqual(@as(?usize, 1), mpUintPrefixLen(0x7f));
    try testing.expectEqual(@as(?usize, 2), mpUintPrefixLen(0xcc));
    try testing.expectEqual(@as(?usize, 3), mpUintPrefixLen(0xcd));
    try testing.expectEqual(@as(?usize, 5), mpUintPrefixLen(0xce));
    try testing.expectEqual(@as(?usize, 9), mpUintPrefixLen(0xcf));
    try testing.expectEqual(@as(?usize, null), mpUintPrefixLen(0x80)); // fixmap, not a uint
    try testing.expectEqual(@as(?usize, null), mpUintPrefixLen(0xc0)); // nil
}

test "frame size prefix: prefix length + decoded size match a real ping frame" {
    // Build a ping frame with the proto layer, then read its size prefix the way
    // readResponseFrame does — the pure half of the frame-read loop.
    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    try request.ping(&buf, 42);
    const bytes = buf.items();

    const prefix_len = mpUintPrefixLen(bytes[0]).?;
    try testing.expectEqual(@as(usize, 5), prefix_len); // Tarantool writes 0xce+u32BE

    var dec = msgpack.Decoder.init(bytes[0..prefix_len]);
    const size = try msgpack.decode(u64, &dec);
    try testing.expectEqual(bytes.len - prefix_len, size); // declared size == payload length
}

test "roundtrip sync check: a mismatched echo is a ProtocolError" {
    // Exercise the sync-match rule in isolation over a synthesized response.
    // parseResponse yields sync 5; the request expected 6 -> ProtocolError.
    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    const pos = try iproto.beginFrame(&buf);
    try iproto.encodeHeader(&buf, .ok, 5, null); // response echoes sync 5
    try buf.writeByte(0x80); // empty body map
    iproto.endFrame(&buf, pos);

    const resp = try parseResponse(testing.allocator, buf.items());
    try testing.expectEqual(@as(u64, 5), resp.sync);
    // The rule roundtrip applies: resp.sync (5) != expected (6).
    try testing.expect(resp.sync != @as(u64, 6));
    try testing.expect(resp.sync == @as(u64, 5)); // matches when equal
}

test "parseIdReply: extracts intersected features + auth_type from an ID reply" {
    // Synthesize an ID reply: header {TYPE:ok, SYNC:1}, body
    // {VERSION:10, FEATURES:[2,5], AUTH_TYPE:"chap-sha1"}. The server offers
    // bits 2 and 5 (both in v1_features), so both survive the intersection.
    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    const pos = try iproto.beginFrame(&buf);
    try iproto.encodeHeader(&buf, .ok, 1, null);
    try buf.writeByte(0x83); // body map of 3 keys
    try msgpack.encode(&buf, Key.version);
    try msgpack.encode(&buf, @as(u64, 10));
    try msgpack.encode(&buf, Key.features);
    try msgpack.encodeArrayHeader(&buf, 2);
    try msgpack.encode(&buf, @as(u8, 2)); // error_extension
    try msgpack.encode(&buf, @as(u8, 5)); // space_and_index_names
    try msgpack.encode(&buf, Key.auth_type);
    try msgpack.encode(&buf, @as([]const u8, "chap-sha1"));
    iproto.endFrame(&buf, pos);

    const info = try parseIdReply(testing.allocator, buf.items());
    try testing.expect((info.features & featureBit(.space_and_index_names)) != 0);
    try testing.expect((info.features & featureBit(.error_extension)) != 0);
    try testing.expectEqualStrings("chap-sha1", info.auth_type.?);
}

test "parseIdReply: intersection drops features the client does not advertise" {
    // Server offers PAGINATION (bit 4), which v1_features does not request; it
    // must not appear in the negotiated mask, and the required feature is absent
    // so the caller would reject with UnsupportedServer.
    var buf = msgpack.Buffer.init(testing.allocator);
    defer buf.deinit();
    const pos = try iproto.beginFrame(&buf);
    try iproto.encodeHeader(&buf, .ok, 1, null);
    try buf.writeByte(0x81); // body map of 1 key
    try msgpack.encode(&buf, Key.features);
    try msgpack.encodeArrayHeader(&buf, 1);
    try msgpack.encode(&buf, @as(u8, 4)); // pagination — not advertised locally
    iproto.endFrame(&buf, pos);

    const info = try parseIdReply(testing.allocator, buf.items());
    try testing.expectEqual(@as(u64, 0), info.features); // intersection is empty
    try testing.expect((info.features & featureBit(.space_and_index_names)) == 0);
    try testing.expectEqual(@as(?[]const u8, null), info.auth_type);
}

test "parseAddress: rejects missing port and non-numeric port" {
    try testing.expectError(error.InvalidAddress, parseAddress("127.0.0.1"));
    try testing.expectError(error.InvalidAddress, parseAddress("127.0.0.1:notaport"));
    try testing.expectError(error.InvalidAddress, parseAddress("not-an-ip:3301"));
    const ok = try parseAddress("127.0.0.1:3301");
    try testing.expect(ok == .ip4);
}

test "encodeArgs: a tuple encodes to the same MP_ARRAY the msgpack module emits" {
    // The typed call/eval args helper must produce a positional MP_ARRAY that is
    // byte-identical to the codec's own `encodeArray` over the same tuple.
    const args = .{ @as(i64, 3), @as(i64, 7) };

    var got = msgpack.Buffer.init(testing.allocator);
    defer got.deinit();
    try encodeArgs(&got, args);

    var want = msgpack.Buffer.init(testing.allocator);
    defer want.deinit();
    try msgpack.encodeArray(&want, args);

    try testing.expectEqualSlices(u8, want.items(), got.items());
    // hand oracle: fixarray(2) 03 07
    try testing.expectEqualSlices(u8, &[_]u8{ 0x92, 0x03, 0x07 }, got.items());
}

test "encodeArgs: empty tuple encodes to an empty MP_ARRAY" {
    var got = msgpack.Buffer.init(testing.allocator);
    defer got.deinit();
    try encodeArgs(&got, .{});
    try testing.expectEqualSlices(u8, &[_]u8{0x90}, got.items());
}

test "decodeReturns: unwraps the single return value from a DATA array" {
    // EVAL "return 1 + 1" yields DATA = [2] (returns array of one element).
    const data = [_]u8{ 0x91, 0x02 };
    try testing.expectEqual(@as(i64, 2), try decodeReturns(i64, &data));
}

test "decodeReturns: a single composite return decodes into a tuple struct" {
    // One return value that is itself a pair: DATA = [[1,2]].
    const data = [_]u8{ 0x91, 0x92, 0x01, 0x02 };
    const pair = try decodeReturns(struct { i64, i64 }, &data);
    try testing.expectEqual(@as(i64, 1), pair[0]);
    try testing.expectEqual(@as(i64, 2), pair[1]);
}

test "decodeReturns: a returns array of the wrong arity is ArityMismatch" {
    // Two return values but a scalar Result asks for exactly one -> ArityMismatch.
    const data = [_]u8{ 0x92, 0x01, 0x02 }; // [1,2]
    try testing.expectError(error.ArityMismatch, decodeReturns(i64, &data));
}

test "decodeReturns: void ignores DATA (present or absent)" {
    const data = [_]u8{ 0x91, 0x02 };
    try decodeReturns(void, &data); // present DATA ignored
    try decodeReturns(void, null); // absent DATA ignored
}

test "decodeReturns: absent DATA with a non-void Result is a ProtocolError" {
    // call/eval always carry a returns array; its absence violates the contract.
    try testing.expectError(error.ProtocolError, decodeReturns(i64, null));
}

// ---------------------------------------------------------------------------
// Watcher mailbox tests (pure — no sockets; the classification/park/queue core
// the roundtrip + batch read loops share, driven over synthesized frames the
// way parseEvent's own fixtures and Batch.ingestFrame are).
// ---------------------------------------------------------------------------

/// A Connection with only the mailbox + gpa + features/sync fields initialized;
/// the socket/buffer plumbing stays undefined (never touched off the wire). Pair
/// with `defer c.freeMailbox()`.
fn mailboxConn(gpa: std.mem.Allocator, features: u64) Connection {
    var c: Connection = undefined;
    c.gpa = gpa;
    c.sync = 0;
    c.features = features;
    c.watched = .empty;
    c.events = .empty;
    c.delivered = null;
    return c;
}

/// Register `key` directly (owned copy), bypassing the WATCH send — the pure
/// tests never touch the socket.
fn registerKey(c: *Connection, key: []const u8) !void {
    const owned = try c.gpa.dupe(u8, key);
    try c.watched.put(c.gpa, owned, false);
}

/// Synthesize a full EVENT frame (size ++ header{TYPE:EVENT,SYNC:0} ++ body).
/// `data_mp`, when present, is written verbatim as the EVENT_DATA value.
fn buildEventFrame(buf: *msgpack.Buffer, key: []const u8, data_mp: ?[]const u8) !void {
    const pos = try iproto.beginFrame(buf);
    try iproto.encodeHeader(buf, .event, 0, null);
    if (data_mp) |d| {
        try buf.writeByte(0x82); // body map, 2 keys
        try msgpack.encode(buf, iproto.Key.event_key);
        try msgpack.encode(buf, key);
        try msgpack.encode(buf, iproto.Key.event_data);
        try buf.writeAll(d);
    } else {
        try buf.writeByte(0x81); // body map, 1 key
        try msgpack.encode(buf, iproto.Key.event_key);
        try msgpack.encode(buf, key);
    }
    iproto.endFrame(buf, pos);
}

/// Synthesize an OK response frame with a DATA payload (the non-event frame the
/// read loop returns).
fn buildOkResponse(buf: *msgpack.Buffer, sync: u64, data_mp: []const u8) !void {
    const pos = try iproto.beginFrame(buf);
    try iproto.encodeHeader(buf, .ok, sync, null);
    try buf.writeByte(0x81); // body map, 1 key
    try msgpack.encode(buf, iproto.Key.data);
    try buf.writeAll(data_mp);
    iproto.endFrame(buf, pos);
}

test "classifyFrame: EVENT for a registered key parks; a response returns (park-during-roundtrip)" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    try registerKey(&c, "k");

    // The read loop's exact sequence when an EVENT interleaves ahead of the reply.
    var ev = msgpack.Buffer.init(testing.allocator);
    defer ev.deinit();
    try buildEventFrame(&ev, "k", &[_]u8{0x2a}); // EVENT_DATA = 42
    var resp = msgpack.Buffer.init(testing.allocator);
    defer resp.deinit();
    try buildOkResponse(&resp, 3, &[_]u8{ 0x91, 0x2a }); // DATA = [42]

    // EVENT -> parked (mailbox grows, no response yielded).
    try testing.expect((try c.classifyFrame(ev.items())) == .parked);
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
    try testing.expectEqualStrings("k", c.events.items[0].key);
    try testing.expectEqualSlices(u8, &[_]u8{0x2a}, c.events.items[0].data.?);

    // Response -> yielded with its sync; the parked event is untouched.
    const cls = try c.classifyFrame(resp.items());
    try testing.expectEqual(@as(u64, 3), cls.response.sync);
    try testing.expectEqual(@as(usize, 1), c.events.items.len);
}

test "isEventFrame: true for EVENT, false for an ordinary response (waitEvent's guard)" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();

    var ev = msgpack.Buffer.init(testing.allocator);
    defer ev.deinit();
    try buildEventFrame(&ev, "k", null);
    var resp = msgpack.Buffer.init(testing.allocator);
    defer resp.deinit();
    try buildOkResponse(&resp, 1, &[_]u8{0x90});

    try testing.expect(try c.isEventFrame(ev.items()));
    try testing.expect(!try c.isEventFrame(resp.items()));
}

test "parkEvent: events for unregistered keys are DROPPED (drop-after-unwatch)" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    try registerKey(&c, "k");

    var ev = msgpack.Buffer.init(testing.allocator);
    defer ev.deinit();
    try buildEventFrame(&ev, "k", &[_]u8{0x01});
    try c.parkEvent(ev.items());
    try testing.expectEqual(@as(usize, 1), c.events.items.len); // registered -> queued

    // Simulate unwatch: drop the registration, then a later EVENT is discarded.
    const kv = c.watched.fetchRemove("k").?;
    c.gpa.free(kv.key);
    try c.parkEvent(ev.items());
    try testing.expectEqual(@as(usize, 1), c.events.items.len); // unregistered -> dropped
}

test "pollEvent: FIFO across two keys, then null when drained" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    try registerKey(&c, "k1");
    try registerKey(&c, "k2");

    var e1 = msgpack.Buffer.init(testing.allocator);
    defer e1.deinit();
    try buildEventFrame(&e1, "k1", &[_]u8{0x01});
    var e2 = msgpack.Buffer.init(testing.allocator);
    defer e2.deinit();
    try buildEventFrame(&e2, "k2", &[_]u8{0x02});
    try c.parkEvent(e1.items());
    try c.parkEvent(e2.items());

    const first = c.pollEvent().?;
    try testing.expectEqualStrings("k1", first.key);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, first.data.?);
    const second = c.pollEvent().?;
    try testing.expectEqualStrings("k2", second.key);
    try testing.expectEqual(@as(?Event, null), c.pollEvent());
}

test "pollEvent: delivery frees the previously delivered event (borrow-until-next-pump)" {
    // The testing allocator flags a leak if the prior delivered event is not
    // freed, and a double-free if it is freed twice — so this pins the single
    // borrow slot with the two events differing.
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    try registerKey(&c, "k");

    var e1 = msgpack.Buffer.init(testing.allocator);
    defer e1.deinit();
    try buildEventFrame(&e1, "k", &[_]u8{0x01});
    var e2 = msgpack.Buffer.init(testing.allocator);
    defer e2.deinit();
    try buildEventFrame(&e2, "k", &[_]u8{0x02});
    try c.parkEvent(e1.items());
    try c.parkEvent(e2.items());

    const d1 = c.pollEvent().?;
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, d1.data.?);
    const d2 = c.pollEvent().?; // frees d1's storage, moves d2 into the slot
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, d2.data.?);
    // pollEvent deferred the re-arm ack (no I/O): the registered key is owed one.
    try testing.expect(c.watched.get("k").?);
}

test "parkEvent: the parked copy survives reuse of the source frame buffer (ownership)" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    try registerKey(&c, "k");

    var src = msgpack.Buffer.init(testing.allocator);
    defer src.deinit();
    try buildEventFrame(&src, "k", &[_]u8{0x2a});
    try c.parkEvent(src.items());

    // Clobber the source bytes the way the next readResponseFrame reuses resp_buf.
    @memset(src.list.items, 0xff);
    try testing.expectEqualStrings("k", c.events.items[0].key);
    try testing.expectEqualSlices(u8, &[_]u8{0x2a}, c.events.items[0].data.?);
}

test "watch/watchOnce require their feature bit (fails before any I/O)" {
    var c = mailboxConn(testing.allocator, 0); // no features negotiated
    defer c.freeMailbox();
    try testing.expectError(error.UnsupportedServer, c.watch("k"));
    try testing.expectError(error.UnsupportedServer, c.watchOnce("k", i64));
}

test "unwatch of an unknown key is a no-op (no registration, no send)" {
    var c = mailboxConn(testing.allocator, 0);
    defer c.freeMailbox();
    // Not registered: unwatch returns without touching the (undefined) socket.
    try c.unwatch("never-watched");
    try testing.expectEqual(@as(u32, 0), c.watched.count());
}

test "watchOnce DATA is a returns array (arity 1), decoded like call/eval" {
    // Live-probed on 3.8.0: box.watch_once('k')=7 -> DATA = dd 00 00 00 01 07
    // (array32 of one element, [7]), the SAME returns-array shape as call/eval,
    // so `decodeReturns` unwraps it. Assert over the exact wire bytes observed.
    const data_array32 = [_]u8{ 0xdd, 0x00, 0x00, 0x00, 0x01, 0x07 }; // [7]
    try testing.expectEqual(@as(i64, 7), try decodeReturns(i64, &data_array32));
    // A key with no value comes back as [nil]; an optional Result sees it as null.
    try testing.expectEqual(@as(?i64, null), try decodeReturns(?i64, &[_]u8{ 0x91, 0xc0 }));
    // void ignores DATA; a non-void Result with absent DATA is a ProtocolError.
    try decodeReturns(void, null);
    try testing.expectError(error.ProtocolError, decodeReturns(i64, null));
}
