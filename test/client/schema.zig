//! Live harness exe: exercise the `tarantool-client` Schema surface against the server the luatest `schema` group starts.
//! Standalone binary — importing `tarantool-client` and LINKING with no `box_*`
//! symbols is the module-purity proof.
//!
//! Reads `TT_URI` / `TT_USER` / `TT_PASS` from the environment, connects as the
//! granted test user, and drives the fixture space `schema_widgets` (created by
//! the luatest group's before_all: format {id unsigned, name string, qty
//! unsigned nullable}, primary tree on id, non-unique secondary tree `by_name`
//! on name). It also drives DDL of its OWN via `conn.eval` so the full drift
//! cycle (fetch → non-DDL traffic keeps the cache → eval DDL marks stale →
//! schema() refetches → eval drop → refetch) is testable from one process.
//!
//! Prints TAP-ish lines (`ok - <name>` / `not ok - <name> (<detail>)`), exits 1
//! on the FIRST failing check and 0 once every check passed — the luatest driver
//! asserts the exit code and surfaces the captured TAP text on failure.
//!
//! The DDL space it creates (`schema_drift_probe`) is dropped both up front
//! (backstop against a crashed prior run) and at the end, so the case is
//! rerunnable.
//!
//! Section 7 joins the LIVE half of `Schema.decodeRow`: typed-by-name
//! decode of real tuples fetched off `schema_widgets` — full row, reordered
//! subset struct, the nullable tail (a short 2-element insert stored WITHOUT
//! padding, decoded as `qty == null`), and the two negatives (a struct field the
//! format never names -> `FieldNotInFormat`; a non-optional field past a short
//! tuple's length -> `MissingField`). It also pins the borrowed-lifetime rule:
//! a decoded slice leaf borrows `resp_buf`, so the copy-before-next-request
//! discipline is asserted here as in the DML matrix.

const std = @import("std");
const client = @import("tarantool-client");
const msgpack = @import("msgpack");

const Connection = client.Connection;

/// Positional tuple mirroring the `schema_widgets` format: {id, name, qty}.
const Row = struct { u32, []const u8, u32 };

/// The DDL space name the drift cycle creates/drops. Deterministic so cleanup is
/// unambiguous; dropped up front and at the end for rerunnability.
const drift_space = "schema_drift_probe";

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    const uri = env.get("TT_URI") orelse return missing("TT_URI");
    const user = env.get("TT_USER") orelse return missing("TT_USER");
    const pass = env.get("TT_PASS") orelse return missing("TT_PASS");

    var conn = Connection.connect(gpa, io, .{
        .address = uri,
        .user = user,
        .password = pass,
    }) catch |e| return fail("connect as test user", @errorName(e));
    defer conn.close();

    return run(&conn, gpa, io, uri);
}

/// The check sequence over an established connection. Returns 0 iff every check
/// passed, else 1 (after the first failing check printed its `not ok` line).
fn run(conn: *Connection, gpa: std.mem.Allocator, io: std.Io, uri: []const u8) u8 {
    // Backstop cleanup: drop the drift space if a prior crashed run left it. A
    // drop of an absent space via this guard is DDL-free (no schema bump).
    _ = conn.eval("if box.space[...] ~= nil then box.space[...]:drop() end", .{drift_space}, void) catch |e|
        return fail("pre-clean drift space", @errorName(e));

    // --- 1. Initial fetch: fixture space present with exact format + indexes ---
    var v0: u64 = undefined;
    {
        const sch = conn.schema() catch |e| return fail("initial schema() fetch", @errorName(e));
        v0 = sch.version;
        if (v0 == 0) return fail("schema version is non-zero after fetch", "version is 0");

        const w = sch.space("schema_widgets") orelse
            return fail("schema_widgets present in initial fetch", "space not found");
        if (w.id == 0) return failFmt("schema_widgets id > 0", "id is {d}", .{w.id});
        if (!std.mem.eql(u8, w.name, "schema_widgets"))
            return failFmt("schema_widgets name", "name is '{s}'", .{w.name});

        // Exact format: names id/name/qty, types unsigned/string/unsigned, only
        // qty is_nullable.
        if (w.format.len != 3) return failFmt("schema_widgets format arity", "len is {d}", .{w.format.len});
        if (fieldMismatch(w.format[0], "id", "unsigned", false)) |d| return fail("format[0] = id unsigned not-null", d);
        if (fieldMismatch(w.format[1], "name", "string", false)) |d| return fail("format[1] = name string not-null", d);
        if (fieldMismatch(w.format[2], "qty", "unsigned", true)) |d| return fail("format[2] = qty unsigned nullable", d);
        ok("initial: schema_widgets present, id>0, exact format");

        // Indexes: primary unique on field 0, by_name non-unique.
        const pk = w.index("primary") orelse return fail("schema_widgets primary index present", "not found");
        if (!pk.unique) return fail("primary index unique", "primary is not unique");
        if (pk.parts.len != 1) return failFmt("primary has one part", "parts len {d}", .{pk.parts.len});
        if (pk.parts[0].field != 0) return failFmt("primary part on field 0", "field is {d}", .{pk.parts[0].field});
        const bn = w.index("by_name") orelse return fail("schema_widgets by_name index present", "not found");
        if (bn.unique) return fail("by_name index non-unique", "by_name is unique");
        ok("initial: primary unique on field 0, by_name non-unique");
    }

    // --- 2. System views _vspace and _vindex findable via schema.space ---
    {
        const sch = conn.schema() catch |e| return fail("schema() for system views", @errorName(e));
        if (sch.space("_vspace") == null) return fail("_vspace system view present", "not found");
        if (sch.space("_vindex") == null) return fail("_vindex system view present", "not found");
        ok("system views: _vspace and _vindex findable");
    }

    // --- 3. Stability: non-DDL DML must NOT mark the cache stale ---
    {
        const widgets = conn.space("schema_widgets");
        _ = widgets.insert(.{ @as(u32, 100), @as([]const u8, "probe"), @as(u32, 5) }, void) catch |e|
            return fail("stability insert {100,probe,5}", @errorName(e));
        const got = (widgets.get(.{@as(u32, 100)}, Row) catch |e|
            return fail("stability get {100}", @errorName(e))) orelse
            return fail("stability get {100}", "expected a row, got null");
        if (got[0] != 100 or !std.mem.eql(u8, got[1], "probe") or got[2] != 5)
            return failFmt("stability get echoes row", "got {{{d},{s},{d}}}", .{ got[0], got[1], got[2] });
        _ = widgets.delete(.{@as(u32, 100)}, void) catch |e|
            return fail("stability delete {100}", @errorName(e));

        if (conn.schema_stale) return fail("schema_stale stays false after non-DDL traffic", "schema_stale is true");
        const sch = conn.schema() catch |e| return fail("schema() after DML", @errorName(e));
        if (sch.version != v0) return failFmt("schema version unchanged after DML", "version {d} != v0 {d}", .{ sch.version, v0 });
        ok("stability: DML keeps schema_stale=false, version constant");
    }

    // --- 4. Drift cycle: eval DDL marks stale, schema() refetches the new space ---
    {
        // Create the drift space (with a format + primary index) via eval. This
        // is DDL: it bumps SCHEMA_VERSION, and the eval reply itself carries the
        // new version, so `roundtrip` marks the cache stale.
        conn.eval(
            \\local s = box.schema.space.create(...)
            \\s:format({ { name = 'k', type = 'unsigned' } })
            \\s:create_index('pk', { type = 'tree', parts = { 'k' } })
        , .{drift_space}, void) catch |e| return fail("eval DDL create drift space", @errorName(e));

        if (!conn.schema_stale) return fail("schema_stale set true by DDL eval", "schema_stale still false");
        ok("drift: DDL eval marked schema_stale=true");

        const sch = conn.schema() catch |e| return fail("schema() refetch after drift", @errorName(e));
        if (conn.schema_stale) return fail("schema_stale cleared after refetch", "schema_stale still true");
        if (sch.version <= v0) return failFmt("schema version increased after DDL", "version {d} <= v0 {d}", .{ sch.version, v0 });
        const drift = sch.space(drift_space) orelse
            return fail("drift space present after refetch", "space not found");
        if (!std.mem.eql(u8, drift.name, drift_space))
            return failFmt("drift space name", "name is '{s}'", .{drift.name});
        if (drift.index("pk") == null) return fail("drift space pk index present", "not found");
        ok("drift: schema() refetched, new space+index present, version increased");

        // Drop it and refetch again: the space must now be ABSENT (present →
        // absent), leaving the instance clean for a rerun.
        conn.eval("box.space[...]:drop()", .{drift_space}, void) catch |e|
            return fail("eval drop drift space", @errorName(e));
        conn.refreshSchema() catch |e| return fail("refreshSchema after drop", @errorName(e));
        const after = conn.schema() catch |e| return fail("schema() after drop", @errorName(e));
        if (after.space(drift_space) != null) return fail("drift space absent after drop+refetch", "space still present");
        ok("drift: drop+refetch -> space absent (rerunnable)");
    }

    // --- 5. refreshSchema explicit path: version stays consistent ---
    {
        const before = (conn.schema() catch |e| return fail("schema() before explicit refresh", @errorName(e))).version;
        conn.refreshSchema() catch |e| return fail("explicit refreshSchema()", @errorName(e));
        const sch = conn.schema() catch |e| return fail("schema() after explicit refresh", @errorName(e));
        if (sch.version != before)
            return failFmt("refreshSchema version consistent (no DDL between)", "version {d} != {d}", .{ sch.version, before });
        ok("refreshSchema: explicit refetch, version consistent");
    }

    // --- 6. Guest path: no-auth connection fetches an access-filtered schema ---
    {
        var guest = Connection.connect(gpa, io, .{ .address = uri, .user = "guest", .password = "" }) catch |e|
            return fail("connect as guest (no auth)", @errorName(e));
        defer guest.close();

        const gsch = guest.schema() catch |e| return fail("guest schema() fetch", @errorName(e));
        // The `_v*` system views are universally readable, so a guest always
        // sees the views themselves in its (access-filtered) snapshot.
        if (gsch.space("_vspace") == null) return fail("guest sees _vspace", "not found");
        if (gsch.space("_vindex") == null) return fail("guest sees _vindex", "not found");
        // LIVE TRUTH: `_vspace` filters rows to spaces the user has a privilege
        // on. In THIS harness the fixture space IS visible to guest — luatest's
        // server_instance.lua (line ~42) grants `guest` the `super` role by
        // default (`if_not_exists=true`) so no-auth test clients can reach
        // everything. A truly unprivileged guest would NOT see schema_widgets
        // (verified against a fresh instance without that grant: the fixture is
        // filtered out); the visibility we assert here is a property of the
        // luatest-granted guest, not of the access model in general.
        if (gsch.space("schema_widgets") == null)
            return fail("guest (luatest-super) sees schema_widgets", "space not found for guest");
        ok("guest: no-auth schema() works, sees _vspace/_vindex + schema_widgets (luatest grants guest super)");
    }

    // --- 7. decodeRow LIVE: typed-by-name decode against the fixture format ---
    // decodeRow wants ONE tuple's bytes; a raw read returns the OUTER DATA array
    // ([tuple]), so `firstTuple` strips that header. The fixture format is
    // {id unsigned, name string, qty unsigned nullable} — id 1001 seeds a FULL
    // 3-field row, id 1002 a SHORT 2-field row (qty omitted, exercising the
    // nullable tail + the MissingField negative).
    {
        const widgets = conn.space("schema_widgets");
        const sch = conn.schema() catch |e| return fail("schema() for decodeRow", @errorName(e));
        // The Schema snapshot is OWNED (arena-backed), so `w` stays valid across
        // the DML requests below — only the fetched TUPLE bytes borrow resp_buf.
        const w = sch.space("schema_widgets") orelse
            return fail("schema_widgets present for decodeRow", "space not found");

        // Seed a full row {1001,"alpha",42} and a SHORT row {1002,"beta"} (qty
        // omitted — a trailing nullable field may be left off the tuple).
        widgets.insert(.{ @as(u32, 1001), @as([]const u8, "alpha"), @as(u32, 42) }, void) catch |e|
            return fail("decodeRow seed full row {1001,alpha,42}", @errorName(e));
        widgets.insert(.{ @as(u32, 1002), @as([]const u8, "beta") }, void) catch |e|
            return fail("decodeRow seed short row {1002,beta}", @errorName(e));

        // The struct maps to format positions BY NAME; qty optional so it absorbs
        // a missing nullable tail as null.
        const FullRow = struct { id: u64, name: []const u8, qty: ?u64 };

        // -- full row: getRaw {1001} -> firstTuple -> decodeRow all three fields --
        {
            const tuple = (getRawKey(widgets, 1001) catch |e|
                return fail("decodeRow getRaw {1001}", @errorName(e))) orelse
                return fail("decodeRow getRaw {1001}", "reply carried no DATA");
            const mp = firstTuple(tuple) orelse
                return fail("decodeRow {1001} DATA has a tuple", "empty result set");

            const r = client.decodeRow(FullRow, w, mp) catch |e|
                return fail("decodeRow {1001} full row", @errorName(e));
            if (r.id != 1001 or !std.mem.eql(u8, r.name, "alpha") or r.qty != 42)
                return failFmt("decodeRow {1001} -> {1001,alpha,42}", "got {{{d},{s},{?d}}}", .{ r.id, r.name, r.qty });

            // Reordered SUBSET struct (qty before id, name skipped) over the SAME
            // bytes -> identical values (mapping is order-independent).
            const Sub = struct { qty: ?u64, id: u64 };
            const s2 = client.decodeRow(Sub, w, mp) catch |e|
                return fail("decodeRow {1001} reordered subset", @errorName(e));
            if (s2.id != 1001 or s2.qty != 42)
                return failFmt("decodeRow {1001} subset {qty,id} -> {42,1001}", "got {{{?d},{d}}}", .{ s2.qty, s2.id });
            ok("decodeRow: full row {1001} + reordered subset both by-name -> {1001,alpha,42}");

            // Negative: a struct field the format never names -> FieldNotInFormat
            // (a comptime-unknowable name, so a runtime error). Any valid tuple.
            const Bogus = struct { id: u64, nonesuch: u64 };
            if (client.decodeRow(Bogus, w, mp)) |_| {
                return fail("decodeRow bogus field -> FieldNotInFormat", "unexpectedly decoded");
            } else |e| switch (e) {
                error.FieldNotInFormat => {},
                else => return fail("decodeRow bogus field -> FieldNotInFormat", @errorName(e)),
            }
            ok("decodeRow: struct field absent from format -> error.FieldNotInFormat");
        }

        // -- short row {1002}: stored WITHOUT padding, qty tail decodes null -----
        {
            const tuple = (getRawKey(widgets, 1002) catch |e|
                return fail("decodeRow getRaw {1002}", @errorName(e))) orelse
                return fail("decodeRow getRaw {1002}", "reply carried no DATA");
            const mp = firstTuple(tuple) orelse
                return fail("decodeRow {1002} DATA has a tuple", "empty result set");

            // LIVE TRUTH: a 2-element insert into a 3-field format (nullable tail)
            // is stored AS-IS — the server does NOT pad qty to an explicit nil, so
            // the stored tuple has arity 2. (An explicit-nil insert would store 3.)
            const arity = arrayCount(mp) orelse
                return fail("decodeRow {1002} tuple is an array", "not an array header");
            if (arity != 2)
                return failFmt("short insert stored WITHOUT padding (arity 2)", "stored arity is {d}", .{arity});

            // qty (format position 2) is beyond the tuple -> null for the optional.
            const r = client.decodeRow(FullRow, w, mp) catch |e|
                return fail("decodeRow {1002} short row", @errorName(e));
            if (r.id != 1002 or !std.mem.eql(u8, r.name, "beta") or r.qty != null)
                return failFmt("decodeRow {1002} -> {1002,beta,null}", "got {{{d},{s},{?d}}}", .{ r.id, r.name, r.qty });
            ok("decodeRow: short 2-field row {1002} stored unpadded, nullable qty -> null");

            // Negative: a NON-optional field past the tuple's length -> MissingField
            // (the same short tuple, qty required).
            const Strict = struct { id: u64, name: []const u8, qty: u64 };
            if (client.decodeRow(Strict, w, mp)) |_| {
                return fail("decodeRow {1002} strict qty -> MissingField", "unexpectedly decoded");
            } else |e| switch (e) {
                error.MissingField => {},
                else => return fail("decodeRow {1002} strict qty -> MissingField", @errorName(e)),
            }
            ok("decodeRow: non-optional field past a short tuple -> error.MissingField");
        }

        // -- a decoded slice leaf borrows resp_buf; copy before next request -
        {
            const tuple = (getRawKey(widgets, 1001) catch |e|
                return fail("decodeRow rk2 getRaw {1001}", @errorName(e))) orelse
                return fail("decodeRow rk2 getRaw {1001}", "reply carried no DATA");
            const mp = firstTuple(tuple) orelse
                return fail("decodeRow rk2 {1001} DATA has a tuple", "empty result set");
            const r = client.decodeRow(FullRow, w, mp) catch |e|
                return fail("decodeRow rk2 decode {1001}", @errorName(e));
            // Copy the borrowed name OUT before the next request stomps resp_buf.
            var namebuf: [64]u8 = undefined;
            @memcpy(namebuf[0..r.name.len], r.name);
            const copy = namebuf[0..r.name.len];
            // Any request reuses resp_buf and invalidates `r.name` (and `mp`).
            _ = getRawKey(widgets, 1002) catch |e|
                return fail("decodeRow rk2 intervening getRaw {1002}", @errorName(e));
            if (!std.mem.eql(u8, copy, "alpha"))
                return failFmt("decodeRow rk2 copied name survives", "copy is '{s}', expected 'alpha'", .{copy});
            ok("decodeRow: rk2 copied name survives an intervening request");
        }

        // Cleanup: delete the seeded rows so the case is rerunnable (before_each
        // truncates too, but keep the exe self-cleaning like the drift cycle).
        _ = widgets.delete(.{@as(u32, 1001)}, void) catch |e|
            return fail("decodeRow cleanup delete {1001}", @errorName(e));
        _ = widgets.delete(.{@as(u32, 1002)}, void) catch |e|
            return fail("decodeRow cleanup delete {1002}", @errorName(e));
    }

    return 0;
}

/// getRaw a single-field primary key `id` off `s`, encoding the key MP_ARRAY
/// inline. Returns the reply's raw DATA (`[]`/`[tuple]`) or null. The DATA slice
/// BORROWS `resp_buf` (valid until the next request).
fn getRawKey(s: client.Space, id: u32) client.RequestError!?[]const u8 {
    var kbuf = msgpack.Buffer.init(s.conn.gpa);
    defer kbuf.deinit();
    try msgpack.encodeArray(&kbuf, .{id});
    return s.getRaw(kbuf.items());
}

/// Strip the OUTER DATA array header, returning the tail that begins at the first
/// tuple (`decodeRow` reads exactly one tuple and ignores any trailing ones); null
/// when the result set is empty. The returned slice BORROWS `data`.
fn firstTuple(data: []const u8) ?[]const u8 {
    const count = arrayCount(data) orelse return null;
    if (count == 0) return null;
    const hdr = arrayHeaderLen(data).?;
    return data[hdr..];
}

/// Element count of the msgpack array at the front of `mp` (fixarray / array16 /
/// array32); null when `mp` does not begin with an array header. std-only — used
/// to measure a stored tuple's arity and to size the outer DATA array.
fn arrayCount(mp: []const u8) ?usize {
    if (mp.len == 0) return null;
    const t = mp[0];
    if (t & 0xf0 == 0x90) return t & 0x0f;
    return switch (t) {
        0xdc => if (mp.len >= 3) std.mem.readInt(u16, mp[1..][0..2], .big) else null,
        0xdd => if (mp.len >= 5) std.mem.readInt(u32, mp[1..][0..4], .big) else null,
        else => null,
    };
}

/// Byte length of the msgpack array header at the front of `mp` (1 for fixarray,
/// 3 for array16, 5 for array32); null when `mp` does not begin with an array.
fn arrayHeaderLen(mp: []const u8) ?usize {
    if (mp.len == 0) return null;
    const t = mp[0];
    if (t & 0xf0 == 0x90) return 1;
    return switch (t) {
        0xdc => 3,
        0xdd => 5,
        else => null,
    };
}

/// Compare a format field against expected name/type/nullable; null on a match,
/// else a static detail string naming the first mismatch.
fn fieldMismatch(f: client.Schema.Field, name: []const u8, typ: []const u8, is_nullable: bool) ?[]const u8 {
    if (!std.mem.eql(u8, f.name, name)) return "name mismatch";
    if (!std.mem.eql(u8, f.type, typ)) return "type mismatch";
    if (f.is_nullable != is_nullable) return "is_nullable mismatch";
    return null;
}

/// Print a passing TAP line.
fn ok(name: []const u8) void {
    std.debug.print("ok - {s}\n", .{name});
}

/// Print a failing TAP line and yield the process exit code (1).
fn fail(name: []const u8, detail: []const u8) u8 {
    std.debug.print("not ok - {s} ({s})\n", .{ name, detail });
    return 1;
}

/// `fail` with a formatted detail (e.g. an unexpected value). A too-long detail
/// is reported as such rather than swallowed.
fn failFmt(name: []const u8, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch "detail too long to format";
    return fail(name, detail);
}

/// A required environment variable was unset — a harness wiring bug, reported
/// loudly (no silent fallback) and exits nonzero.
fn missing(key: []const u8) u8 {
    std.debug.print("not ok - environment variable {s} is not set\n", .{key});
    return 1;
}
