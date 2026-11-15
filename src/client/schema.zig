//! `Schema` — a drift-aware, lazily-fetched snapshot of the server's space and
//! index metadata, built from the `_vspace` (281) and `_vindex` (289) system
//! views. The views are selectable BY NAME and are
//! access-filtered (readable even by guest), so the fetch is two ordinary
//! SELECTs through the existing wire machinery — this module adds zero
//! wire-format code. The Connection owns the cache + the fetch/staleness
//! policy; this module owns the pure row parsers and the value model.
//!
//! OWNERSHIP: a `Schema` owns every byte it exposes. All strings/slices
//! are copied out of the transient `resp_buf` into a child `ArenaAllocator`, so
//! `deinit` is a single arena teardown and a rebuild is cheap. No `Schema`
//! field ever borrows `resp_buf` — a cache that outlives one request must not.
//!
//! ROW SHAPES (live-probed Tarantool 3.8 — parsers take prefixes
//! positionally and skip unknown trailing fields/keys):
//!   `_vspace` row = [id, owner, name, engine, field_count, flags, format]
//!     format = [ {name, type, is_nullable?}, ... ]  (maps; key order varies,
//!     unknown keys skipped, missing is_nullable => false)
//!   `_vindex` row = [space_id, iid, name, type, opts, parts]
//!     opts = { unique: bool, ... }  (missing unique => false)
//!     parts = [ [field, type, ...], ... ]  (array form)  OR
//!             [ {field, type, path?, ...}, ... ]  (map form, functional /
//!             JSON-path indexes) — both parsed, only field+type kept.

const std = @import("std");
const msgpack = @import("msgpack");

const Allocator = std.mem.Allocator;
const Value = msgpack.Value;

/// Parser/build failures: the codec's decode errors plus `ProtocolError` for a
/// row that decodes cleanly but violates the `_vspace`/`_vindex` prefix
/// contract (too short, wrong leaf type, a format field lacking name/type). A
/// subset of `connection.RequestError`, so `Connection.schema()` propagates it
/// verbatim.
pub const Error = msgpack.DecodeError || error{ProtocolError};

/// `decodeRow` failures: the codec's decode errors (a leaf whose wire type does
/// not match the struct field, a truncated tuple) plus `FieldNotInFormat` for a
/// struct field the space's format never names. A trailing format position that
/// the tuple omits surfaces as the codec's own `error.MissingField` when the
/// struct field is non-optional (missing nullable tails decode as null instead).
pub const DecodeRowError = msgpack.DecodeError || error{FieldNotInFormat};

/// An owned snapshot of the server schema at `version`. Build via `buildSchema`;
/// free via `deinit`. Move-only: it holds a child arena whose allocations back
/// every string and map inside it (moving the struct moves the arena's bookkeeping
/// value, not the heap buffers), so it may be relocated but never copied while
/// live (two copies would double-free on `deinit`).
pub const Schema = struct {
    /// Backing store for every owned byte in this snapshot (spaces map, names,
    /// engines, formats, index parts). One `deinit` frees all of it.
    arena: std.heap.ArenaAllocator,
    /// The server's SCHEMA_VERSION counter at fetch time. The Connection compares
    /// a later reply's version against this to decide staleness (`!=`, never `<`).
    version: u64,
    /// Spaces keyed by name (owned copies). Backed by `arena`.
    spaces: std.StringArrayHashMapUnmanaged(SpaceInfo),

    /// One field of a space's format (from a `_vspace` row's format array).
    pub const Field = struct { name: []u8, type: []u8, is_nullable: bool };

    /// One part of an index key (field position + declared type). Both the array
    /// form `[field, type, ...]` and the map form `{field, type, path?}` collapse
    /// to this; any trailing path/collation is dropped.
    pub const Part = struct { field: u32, type: []u8 };

    /// One index of a space (from `_vindex`). `unique` comes from the opts map;
    /// the wire index type (TREE/HASH) is not modelled here.
    pub const IndexInfo = struct {
        id: u32,
        name: []u8,
        unique: bool,
        parts: []Part,
    };

    /// One space (from `_vspace`), with its format and its indexes keyed by name.
    pub const SpaceInfo = struct {
        id: u32,
        name: []u8,
        engine: []u8,
        format: []Field,
        indexes: std.StringArrayHashMapUnmanaged(IndexInfo),

        /// Look up an index of this space by name; null when absent.
        pub fn index(s: *const SpaceInfo, name: []const u8) ?*const IndexInfo {
            return s.indexes.getPtr(name);
        }

        /// Position of the format field named `name` (== its tuple position),
        /// or null when the format has no such field. Naive linear scan (no premature index-map at v1 sizes). Used by `decodeRow`.
        pub fn fieldIndex(s: *const SpaceInfo, name: []const u8) ?u32 {
            for (s.format, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) return @intCast(i);
            }
            return null;
        }
    };

    /// Look up a space by name; null when absent.
    pub fn space(s: *const Schema, name: []const u8) ?*const SpaceInfo {
        return s.spaces.getPtr(name);
    }

    /// Free the whole snapshot (one arena teardown).
    pub fn deinit(s: *Schema) void {
        s.arena.deinit();
    }
};

/// Build a `Schema` from two raw DATA payloads: the `_vspace` and `_vindex`
/// SELECT results, each an MP_ARRAY of rows (the array32-framed DATA the server
/// sends). `version` is the SCHEMA_VERSION the fetch observed. All contents are
/// copied into the returned Schema's arena — the input slices may be freed /
/// clobbered immediately after (they borrow `resp_buf`). On any error the arena
/// is torn down and nothing leaks.
pub fn buildSchema(gpa: Allocator, version: u64, vspace_data: []const u8, vindex_data: []const u8) Error!Schema {
    var self: Schema = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .version = version,
        .spaces = .empty,
    };
    errdefer self.arena.deinit();
    const a = self.arena.allocator();

    // Transient store for the schemaless Value trees. Its str/bin leaves borrow
    // the input payloads; the map/array node slices live here and die at return.
    // Everything we keep is duped into `a` before this frees.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // --- _vspace rows -> SpaceInfo, keyed by name ---
    const vspace_rows = try decodeRows(sa, vspace_data);
    for (vspace_rows) |row_val| {
        const info = try parseSpaceRow(a, row_val);
        try self.spaces.put(a, info.name, info);
    }

    // space_id -> name, so index rows attach to their space (rows carry the id,
    // the spaces map is keyed by name).
    var id_to_name: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer id_to_name.deinit(gpa);
    for (self.spaces.values()) |sp| try id_to_name.put(gpa, sp.id, sp.name);

    // --- _vindex rows -> IndexInfo, appended to the owning space ---
    const vindex_rows = try decodeRows(sa, vindex_data);
    for (vindex_rows) |row_val| {
        const parsed = try parseIndexRow(a, row_val);
        // An index whose space is not in our snapshot (e.g. access-filtered
        // asymmetrically) is unreferenced, not corrupt — skip it, do not raise.
        const name = id_to_name.get(parsed.space_id) orelse continue;
        const sp = self.spaces.getPtr(name).?;
        try sp.indexes.put(a, parsed.info.name, parsed.info);
    }

    return self;
}

// ---------------------------------------------------------------------------
// Typed-by-name row decode
// ---------------------------------------------------------------------------

/// Decode a msgpack tuple into `Row`, mapping struct field NAMES onto format
/// positions (order-independent): every field of `Row` is resolved to the
/// format entry of the same name — which is its position in the tuple — via
/// `info.fieldIndex`. A field the format never names is `error.FieldNotInFormat`
/// (unknowable at comptime, so a runtime error). The tuple is walked
/// positionally; named positions decode into their field, unnamed ones are
/// skipped. Positions beyond what `Row` names are ignored; a format position the
/// tuple omits (a shorter tuple) decodes as `null` into an optional field, else
/// `error.MissingField`.
///
/// LIFETIME: like `msgpack.decode`, this allocates nothing — slice leaves (a
/// `[]const u8` field) BORROW `tuple_mp`, so the decoded `Row` lives only as
/// long as those bytes (same house rule as the rest of the client: a value that
/// must outlive one response copies out).
pub fn decodeRow(comptime Row: type, info: *const Schema.SpaceInfo, tuple_mp: []const u8) DecodeRowError!Row {
    const ti = @typeInfo(Row);
    if (ti != .@"struct" or ti.@"struct".is_tuple)
        @compileError("decodeRow: Row must be a named struct, got " ++ @typeName(Row));
    const fields = ti.@"struct".field_names;

    // Resolve each struct field to its format/tuple position up front
    // (O(fields * format) naive scan). A name absent from the format is fatal.
    var target: [fields.len]u32 = undefined;
    inline for (fields, 0..) |name, fi| {
        target[fi] = info.fieldIndex(name) orelse return error.FieldNotInFormat;
    }

    var out: Row = undefined;
    var filled: [fields.len]bool = @splat(false);

    // Walk the tuple positionally, decoding named positions and skipping the
    // rest. Positions past the tuple's length are handled after the loop.
    var dec = msgpack.Decoder.init(tuple_mp);
    const tuple_len = try readArrayHeaderRaw(&dec);
    var p: usize = 0;
    while (p < tuple_len) : (p += 1) {
        var matched = false;
        inline for (fields, ti.@"struct".field_types, 0..) |name, ty, fi| {
            // Field names are unique, so at most one field maps to position p.
            if (!matched and target[fi] == p) {
                @field(out, name) = try msgpack.decode(ty, &dec);
                filled[fi] = true;
                matched = true;
            }
        }
        if (!matched) try skipValue(&dec);
    }

    // Fields whose position lies beyond the tuple's length were never filled:
    // null for optionals (missing nullable tail), else a hard MissingField.
    inline for (fields, ti.@"struct".field_types, 0..) |name, ty, fi| {
        if (!filled[fi]) {
            if (@typeInfo(ty) == .optional) {
                @field(out, name) = null;
            } else return error.MissingField;
        }
    }
    return out;
}

/// Read a big-endian unsigned int of type `T` at `buf[pos..]`, widened to usize;
/// `error.Truncated` if it runs off the end. Length/count prefix reader for the
/// allocation-free tuple walk below.
fn beRead(buf: []const u8, pos: usize, comptime T: type) DecodeRowError!usize {
    const n = @sizeOf(T);
    if (pos + n > buf.len) return error.Truncated;
    return std.mem.readInt(T, buf[pos..][0..n], .big);
}

/// Read (and consume) an msgpack array header from `dec`, returning its element
/// count. `Decoder.readArrayHeader` is private and `decodeValue` allocates;
/// `decodeRow` needs the tuple's arity allocation-free, so it frames the header
/// directly off the decoder's buffer.
fn readArrayHeaderRaw(dec: *msgpack.Decoder) DecodeRowError!usize {
    const buf = dec.buf;
    if (dec.pos >= buf.len) return error.Truncated;
    const t = buf[dec.pos];
    dec.pos += 1;
    if (t & 0xf0 == 0x90) return t & 0x0f; // fixarray
    switch (t) {
        0xdc => {
            const n = try beRead(buf, dec.pos, u16);
            dec.pos += 2;
            return n;
        },
        0xdd => {
            const n = try beRead(buf, dec.pos, u32);
            dec.pos += 4;
            return n;
        },
        else => return error.NotArray,
    }
}

/// Advance `dec` past exactly one complete msgpack value without allocating.
/// `msgpack.decode` consumes the leaves `Row` names; the unnamed tuple positions
/// interleaved between them must still be walked over to reach the next named
/// one. The codec's only value-walk (`decodeValue`) allocates container nodes we
/// would immediately discard, and `decodeRow` is allocation-free (it borrows
/// `tuple_mp`), so we frame-skip here: fixed-size tokens advance `pos` by their
/// payload; containers push their child count onto `remaining`.
fn skipValue(dec: *msgpack.Decoder) DecodeRowError!void {
    const buf = dec.buf;
    var pos = dec.pos;
    var remaining: usize = 1; // values still to consume (the one asked for)
    while (remaining > 0) : (remaining -= 1) {
        if (pos >= buf.len) return error.Truncated;
        const t = buf[pos];
        pos += 1;
        switch (t) {
            0x00...0x7f => {}, // positive fixint
            0xe0...0xff => {}, // negative fixint
            0x80...0x8f => remaining += 2 * @as(usize, t & 0x0f), // fixmap: 2N children
            0x90...0x9f => remaining += @as(usize, t & 0x0f), // fixarray: N children
            0xa0...0xbf => pos += t & 0x1f, // fixstr
            0xc0, 0xc2, 0xc3 => {}, // nil, false, true
            0xc1 => return error.NotInt, // never-used byte (mirrors decodeValue)
            0xcc, 0xd0 => pos += 1, // uint8 / int8
            0xcd, 0xd1 => pos += 2, // uint16 / int16
            0xca, 0xce, 0xd2 => pos += 4, // float32 / uint32 / int32
            0xcb, 0xcf, 0xd3 => pos += 8, // float64 / uint64 / int64
            0xc4, 0xd9 => { // bin8 / str8: 1-byte length + payload
                const n = try beRead(buf, pos, u8);
                pos += 1 + n;
            },
            0xc5, 0xda => { // bin16 / str16
                const n = try beRead(buf, pos, u16);
                pos += 2 + n;
            },
            0xc6, 0xdb => { // bin32 / str32
                const n = try beRead(buf, pos, u32);
                pos += 4 + n;
            },
            0xc7 => { // ext8: 1-byte length + 1 type byte + payload
                const n = try beRead(buf, pos, u8);
                pos += 1 + 1 + n;
            },
            0xc8 => { // ext16
                const n = try beRead(buf, pos, u16);
                pos += 2 + 1 + n;
            },
            0xc9 => { // ext32
                const n = try beRead(buf, pos, u32);
                pos += 4 + 1 + n;
            },
            0xd4 => pos += 1 + 1, // fixext1: type byte + 1
            0xd5 => pos += 1 + 2, // fixext2
            0xd6 => pos += 1 + 4, // fixext4
            0xd7 => pos += 1 + 8, // fixext8
            0xd8 => pos += 1 + 16, // fixext16
            0xdc => { // array16: 2-byte count, N children
                const n = try beRead(buf, pos, u16);
                pos += 2;
                remaining += n;
            },
            0xdd => { // array32
                const n = try beRead(buf, pos, u32);
                pos += 4;
                remaining += n;
            },
            0xde => { // map16: 2-byte count, 2N children
                const n = try beRead(buf, pos, u16);
                pos += 2;
                remaining += 2 * n;
            },
            0xdf => { // map32
                const n = try beRead(buf, pos, u32);
                pos += 4;
                remaining += 2 * n;
            },
        }
    }
    if (pos > buf.len) return error.Truncated; // a trailing str/bin/ext ran off the end
    dec.pos = pos;
}

// ---------------------------------------------------------------------------
// Pure row parsers (fixture-tested)
// ---------------------------------------------------------------------------

/// Decode a DATA payload (MP_ARRAY of rows) into its row `Value`s. The str/bin
/// leaves borrow `data`; array/map nodes are allocated from `alloc`.
fn decodeRows(alloc: Allocator, data: []const u8) Error![]const Value {
    var dec = msgpack.Decoder.init(data);
    const v = try dec.decodeValue(alloc);
    return switch (v) {
        .array => |rows| rows,
        else => error.NotArray,
    };
}

/// Parse one `_vspace` row into an owned `SpaceInfo` (strings/format duped into
/// `a`). Positions used: 0=id, 2=name, 3=engine, 6=format; a row shorter than
/// that violates the contract.
fn parseSpaceRow(a: Allocator, row_val: Value) Error!Schema.SpaceInfo {
    const row = switch (row_val) {
        .array => |r| r,
        else => return error.NotArray,
    };
    if (row.len < 7) return error.ProtocolError;

    const id = try uintField(row[0]);
    const name = try dupeStr(a, row[2]);
    const engine = try dupeStr(a, row[3]);

    const format_val = switch (row[6]) {
        .array => |f| f,
        else => return error.NotArray,
    };
    const format = try a.alloc(Schema.Field, format_val.len);
    for (format, format_val) |*dst, fv| dst.* = try parseField(a, fv);

    return .{
        .id = id,
        .name = name,
        .engine = engine,
        .format = format,
        .indexes = .empty,
    };
}

/// Parse one format entry `{name, type, is_nullable?}` (a map; key order varies,
/// unknown keys skipped). name and type are mandatory; is_nullable defaults false.
fn parseField(a: Allocator, field_val: Value) Error!Schema.Field {
    const kvs = switch (field_val) {
        .map => |m| m,
        else => return error.NotMap,
    };
    var name: ?[]u8 = null;
    var typ: ?[]u8 = null;
    var is_nullable = false;
    for (kvs) |kv| {
        const key = switch (kv.key) {
            .str => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, key, "name")) {
            name = try dupeStr(a, kv.value);
        } else if (std.mem.eql(u8, key, "type")) {
            typ = try dupeStr(a, kv.value);
        } else if (std.mem.eql(u8, key, "is_nullable")) {
            is_nullable = switch (kv.value) {
                .bool => |b| b,
                else => return error.NotBool,
            };
        }
    }
    return .{
        .name = name orelse return error.ProtocolError,
        .type = typ orelse return error.ProtocolError,
        .is_nullable = is_nullable,
    };
}

/// A parsed `_vindex` row: the owning space id plus the owned index info.
const ParsedIndex = struct { space_id: u32, info: Schema.IndexInfo };

/// Parse one `_vindex` row. Positions used: 0=space_id, 1=iid, 2=name, 4=opts,
/// 5=parts (position 3, the wire index type, is not modelled).
fn parseIndexRow(a: Allocator, row_val: Value) Error!ParsedIndex {
    const row = switch (row_val) {
        .array => |r| r,
        else => return error.NotArray,
    };
    if (row.len < 6) return error.ProtocolError;

    const space_id = try uintField(row[0]);
    const iid = try uintField(row[1]);
    const name = try dupeStr(a, row[2]);
    const unique = try optsUnique(row[4]);

    const parts_val = switch (row[5]) {
        .array => |p| p,
        else => return error.NotArray,
    };
    const parts = try a.alloc(Schema.Part, parts_val.len);
    for (parts, parts_val) |*dst, pv| dst.* = try parsePart(a, pv);

    return .{
        .space_id = space_id,
        .info = .{ .id = iid, .name = name, .unique = unique, .parts = parts },
    };
}

/// Read the `unique` flag from an index opts map; missing key => false.
fn optsUnique(opts_val: Value) Error!bool {
    const kvs = switch (opts_val) {
        .map => |m| m,
        else => return error.NotMap,
    };
    for (kvs) |kv| {
        const key = switch (kv.key) {
            .str => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, key, "unique")) {
            return switch (kv.value) {
                .bool => |b| b,
                else => error.NotBool,
            };
        }
    }
    return false;
}

/// Parse one index part, array form `[field, type, ...]` or map form
/// `{field, type, path?, ...}`; keep only field + type.
fn parsePart(a: Allocator, part_val: Value) Error!Schema.Part {
    switch (part_val) {
        .array => |p| {
            if (p.len < 2) return error.ProtocolError;
            return .{ .field = try uintField(p[0]), .type = try dupeStr(a, p[1]) };
        },
        .map => |kvs| {
            var field: ?u32 = null;
            var typ: ?[]u8 = null;
            for (kvs) |kv| {
                const key = switch (kv.key) {
                    .str => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, key, "field")) {
                    field = try uintField(kv.value);
                } else if (std.mem.eql(u8, key, "type")) {
                    typ = try dupeStr(a, kv.value);
                }
            }
            return .{
                .field = field orelse return error.ProtocolError,
                .type = typ orelse return error.ProtocolError,
            };
        },
        else => return error.NotArray,
    }
}

/// Extract a u32 from a msgpack uint leaf; a non-uint or an out-of-range value
/// is a contract violation, never a silent default.
fn uintField(v: Value) Error!u32 {
    const u = switch (v) {
        .uint => |x| x,
        else => return error.NotInt,
    };
    return std.math.cast(u32, u) orelse error.Overflow;
}

/// Dupe a msgpack str leaf into `a` (owned copy; the source borrows resp_buf).
fn dupeStr(a: Allocator, v: Value) Error![]u8 {
    const s = switch (v) {
        .str => |x| x,
        else => return error.NotStr,
    };
    return a.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// Tests — fixtures captured live from Tarantool 3.8 this session (see the
// module header for the row shapes). Space `widgets`: format
// {id:unsigned, name:string, qty:unsigned?}, indexes primary(unique) +
// by_name(non-unique). Space `jsp`: a JSON-path index (map-form parts).
// ---------------------------------------------------------------------------

const testing = std.testing;

// _vspace row for `widgets` (id 512): [512,1,"widgets","memtx",0,{},
//   [{name:"id",type:"unsigned"},{name:"name",type:"string"},
//    {type:"unsigned",name:"qty",is_nullable:true}]]
const vspace_widgets = [_]u8{
    0x97, 0xcd, 0x02, 0x00, 0x01, 0xa7, 0x77, 0x69, 0x64, 0x67, 0x65, 0x74,
    0x73, 0xa5, 0x6d, 0x65, 0x6d, 0x74, 0x78, 0x00, 0x80, 0x93, 0x82, 0xa4,
    0x6e, 0x61, 0x6d, 0x65, 0xa2, 0x69, 0x64, 0xa4, 0x74, 0x79, 0x70, 0x65,
    0xa8, 0x75, 0x6e, 0x73, 0x69, 0x67, 0x6e, 0x65, 0x64, 0x82, 0xa4, 0x6e,
    0x61, 0x6d, 0x65, 0xa4, 0x6e, 0x61, 0x6d, 0x65, 0xa4, 0x74, 0x79, 0x70,
    0x65, 0xa6, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x83, 0xa4, 0x74, 0x79,
    0x70, 0x65, 0xa8, 0x75, 0x6e, 0x73, 0x69, 0x67, 0x6e, 0x65, 0x64, 0xa4,
    0x6e, 0x61, 0x6d, 0x65, 0xa3, 0x71, 0x74, 0x79, 0xab, 0x69, 0x73, 0x5f,
    0x6e, 0x75, 0x6c, 0x6c, 0x61, 0x62, 0x6c, 0x65, 0xc3,
};

// _vspace row for `jsp` (id 513): format [{name:"id",type:"unsigned"},
//   {name:"data",type:"map"}]
const vspace_jsp = [_]u8{
    0x97, 0xcd, 0x02, 0x01, 0x00, 0xa3, 0x6a, 0x73, 0x70, 0xa5, 0x6d, 0x65,
    0x6d, 0x74, 0x78, 0x00, 0x80, 0x92, 0x82, 0xa4, 0x6e, 0x61, 0x6d, 0x65,
    0xa2, 0x69, 0x64, 0xa4, 0x74, 0x79, 0x70, 0x65, 0xa8, 0x75, 0x6e, 0x73,
    0x69, 0x67, 0x6e, 0x65, 0x64, 0x82, 0xa4, 0x6e, 0x61, 0x6d, 0x65, 0xa4,
    0x64, 0x61, 0x74, 0x61, 0xa4, 0x74, 0x79, 0x70, 0x65, 0xa3, 0x6d, 0x61,
    0x70,
};

// _vindex primary of widgets: [512,0,"primary","tree",{unique:true},[[0,"unsigned"]]]
const vindex_w_primary = [_]u8{
    0x96, 0xcd, 0x02, 0x00, 0x00, 0xa7, 0x70, 0x72, 0x69, 0x6d, 0x61, 0x72,
    0x79, 0xa4, 0x74, 0x72, 0x65, 0x65, 0x81, 0xa6, 0x75, 0x6e, 0x69, 0x71,
    0x75, 0x65, 0xc3, 0x91, 0x92, 0x00, 0xa8, 0x75, 0x6e, 0x73, 0x69, 0x67,
    0x6e, 0x65, 0x64,
};

// _vindex by_name of widgets: [512,1,"by_name","tree",{unique:false},[[1,"string"]]]
const vindex_w_byname = [_]u8{
    0x96, 0xcd, 0x02, 0x00, 0x01, 0xa7, 0x62, 0x79, 0x5f, 0x6e, 0x61, 0x6d,
    0x65, 0xa4, 0x74, 0x72, 0x65, 0x65, 0x81, 0xa6, 0x75, 0x6e, 0x69, 0x71,
    0x75, 0x65, 0xc2, 0x91, 0x92, 0x01, 0xa6, 0x73, 0x74, 0x72, 0x69, 0x6e,
    0x67,
};

// _vindex by_path of jsp (MAP-FORM parts): [513,1,"by_path","tree",
//   {unique:false},[{field:1,type:"string",path:"city"}]]
const vindex_jsp_bypath = [_]u8{
    0x96, 0xcd, 0x02, 0x01, 0x01, 0xa7, 0x62, 0x79, 0x5f, 0x70, 0x61, 0x74,
    0x68, 0xa4, 0x74, 0x72, 0x65, 0x65, 0x81, 0xa6, 0x75, 0x6e, 0x69, 0x71,
    0x75, 0x65, 0xc2, 0x91, 0x83, 0xa5, 0x66, 0x69, 0x65, 0x6c, 0x64, 0x01,
    0xa4, 0x74, 0x79, 0x70, 0x65, 0xa6, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67,
    0xa4, 0x70, 0x61, 0x74, 0x68, 0xa4, 0x63, 0x69, 0x74, 0x79,
};

/// Wrap N raw row byte-slices into one DATA payload (MP_ARRAY of rows). Fixarray
/// header (N < 16) + the rows concatenated. Caller frees.
fn dataOf(gpa: Allocator, rows: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, 0x90 | @as(u8, @intCast(rows.len)));
    for (rows) |r| try buf.appendSlice(gpa, r);
    return buf.toOwnedSlice(gpa);
}

test "parseSpaceRow: widgets format incl. reordered keys + is_nullable tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dec = msgpack.Decoder.init(&vspace_widgets);
    const row = try dec.decodeValue(arena.allocator());

    const info = try parseSpaceRow(arena.allocator(), row);
    try testing.expectEqual(@as(u32, 512), info.id);
    try testing.expectEqualStrings("widgets", info.name);
    try testing.expectEqualStrings("memtx", info.engine);
    try testing.expectEqual(@as(usize, 3), info.format.len);

    try testing.expectEqualStrings("id", info.format[0].name);
    try testing.expectEqualStrings("unsigned", info.format[0].type);
    try testing.expect(!info.format[0].is_nullable);
    try testing.expectEqualStrings("name", info.format[1].name);
    try testing.expectEqualStrings("string", info.format[1].type);
    try testing.expect(!info.format[1].is_nullable);
    // Third field: keys arrive in order type,name,is_nullable (order-independent)
    // and is_nullable=true.
    try testing.expectEqualStrings("qty", info.format[2].name);
    try testing.expectEqualStrings("unsigned", info.format[2].type);
    try testing.expect(info.format[2].is_nullable);
}

test "parseIndexRow: array-form parts + unique flag from opts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var d0 = msgpack.Decoder.init(&vindex_w_primary);
    const primary = try parseIndexRow(a, try d0.decodeValue(a));
    try testing.expectEqual(@as(u32, 512), primary.space_id);
    try testing.expectEqual(@as(u32, 0), primary.info.id);
    try testing.expectEqualStrings("primary", primary.info.name);
    try testing.expect(primary.info.unique);
    try testing.expectEqual(@as(usize, 1), primary.info.parts.len);
    try testing.expectEqual(@as(u32, 0), primary.info.parts[0].field);
    try testing.expectEqualStrings("unsigned", primary.info.parts[0].type);

    var d1 = msgpack.Decoder.init(&vindex_w_byname);
    const byname = try parseIndexRow(a, try d1.decodeValue(a));
    try testing.expectEqualStrings("by_name", byname.info.name);
    try testing.expect(!byname.info.unique); // non-unique
    try testing.expectEqual(@as(u32, 1), byname.info.parts[0].field);
    try testing.expectEqualStrings("string", byname.info.parts[0].type);
}

test "parseIndexRow: map-form parts (JSON-path index) keep field+type, drop path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dec = msgpack.Decoder.init(&vindex_jsp_bypath);
    const bypath = try parseIndexRow(a, try dec.decodeValue(a));
    try testing.expectEqual(@as(u32, 513), bypath.space_id);
    try testing.expectEqualStrings("by_path", bypath.info.name);
    try testing.expect(!bypath.info.unique);
    try testing.expectEqual(@as(usize, 1), bypath.info.parts.len);
    try testing.expectEqual(@as(u32, 1), bypath.info.parts[0].field);
    try testing.expectEqualStrings("string", bypath.info.parts[0].type);
}

test "buildSchema: two DATA payloads -> named spaces with owned formats + indexes" {
    const gpa = testing.allocator;
    const vspace = try dataOf(gpa, &.{ &vspace_widgets, &vspace_jsp });
    defer gpa.free(vspace);
    const vindex = try dataOf(gpa, &.{ &vindex_w_primary, &vindex_w_byname, &vindex_jsp_bypath });
    defer gpa.free(vindex);

    var schema = try buildSchema(gpa, 42, vspace, vindex);
    defer schema.deinit();

    try testing.expectEqual(@as(u64, 42), schema.version);
    try testing.expectEqual(@as(usize, 2), schema.spaces.count());

    const w = schema.space("widgets").?;
    try testing.expectEqual(@as(u32, 512), w.id);
    try testing.expectEqual(@as(usize, 3), w.format.len);
    try testing.expectEqualStrings("qty", w.format[2].name);
    try testing.expect(w.format[2].is_nullable);
    // indexes attached by space_id
    try testing.expectEqual(@as(usize, 2), w.indexes.count());
    try testing.expect(w.index("primary").?.unique);
    try testing.expect(!w.index("by_name").?.unique);
    try testing.expectEqual(@as(?*const Schema.IndexInfo, null), w.index("nope"));

    const j = schema.space("jsp").?;
    try testing.expectEqual(@as(u32, 513), j.id);
    try testing.expectEqual(@as(usize, 1), j.indexes.count());
    try testing.expectEqualStrings("string", j.index("by_path").?.parts[0].type);

    try testing.expectEqual(@as(?*const Schema.SpaceInfo, null), schema.space("absent"));
}

test "buildSchema: owned contents survive freeing the source payloads" {
    const gpa = testing.allocator;
    const vspace = try dataOf(gpa, &.{&vspace_widgets});
    const vindex = try dataOf(gpa, &.{&vindex_w_primary});
    var schema = try buildSchema(gpa, 7, vspace, vindex);
    defer schema.deinit();
    // Free the source bytes: an owned Schema must not borrow them.
    gpa.free(vspace);
    gpa.free(vindex);
    const w = schema.space("widgets").?;
    try testing.expectEqualStrings("widgets", w.name);
    try testing.expectEqualStrings("primary", w.index("primary").?.name);
}

test "parseSpaceRow: a row shorter than the 7-field prefix is a ProtocolError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // [1,2,"x"] — only 3 fields.
    const short = [_]u8{ 0x93, 0x01, 0x02, 0xa1, 0x78 };
    var dec = msgpack.Decoder.init(&short);
    const row = try dec.decodeValue(arena.allocator());
    try testing.expectError(error.ProtocolError, parseSpaceRow(arena.allocator(), row));
}

test "parseField: a format entry missing type is a ProtocolError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // {name:"x"} — no type key.
    const only_name = [_]u8{ 0x81, 0xa4, 0x6e, 0x61, 0x6d, 0x65, 0xa1, 0x78 };
    var dec = msgpack.Decoder.init(&only_name);
    const v = try dec.decodeValue(arena.allocator());
    try testing.expectError(error.ProtocolError, parseField(arena.allocator(), v));
}

test "optsUnique: missing unique key defaults to false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty_map = [_]u8{0x80}; // {}
    var dec = msgpack.Decoder.init(&empty_map);
    try testing.expect(!try optsUnique(try dec.decodeValue(arena.allocator())));
}

// --- decodeRow (typed-by-name row decode) ---------------------------------
//
// The FORMAT comes from the live `widgets` fixture (id:unsigned, name:string,
// qty:unsigned nullable); the tuple BYTES are hand-built here with the codec so
// each case controls the tuple's arity and leaf types independently.

/// Build a `widgets` SpaceInfo (via buildSchema over the checked-in fixture) so
/// decodeRow tests exercise the real, live-captured format. Caller `deinit`s.
fn widgetsSchema(gpa: Allocator) !Schema {
    const vspace = try dataOf(gpa, &.{&vspace_widgets});
    defer gpa.free(vspace);
    const vindex = [_]u8{0x90}; // empty _vindex payload
    return buildSchema(gpa, 1, vspace, &vindex);
}

/// Encode any struct/tuple to an owned msgpack array (`encode` emits a tuple
/// struct as a positional array — a row). Caller frees.
fn tupleOf(gpa: Allocator, value: anytype) ![]u8 {
    var buf = msgpack.Buffer.init(gpa);
    defer buf.deinit();
    try msgpack.encode(&buf, value);
    return gpa.dupe(u8, buf.items());
}

test "decodeRow: exact-match struct decodes every named position" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    const tuple = try tupleOf(gpa, .{ @as(u64, 1), "hello", @as(u64, 7) });
    defer gpa.free(tuple);

    const Row = struct { id: u64, name: []const u8, qty: u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(u64, 1), r.id);
    try testing.expectEqualStrings("hello", r.name);
    try testing.expectEqual(@as(u64, 7), r.qty);
}

test "decodeRow: struct field order is independent of tuple/format order" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    const tuple = try tupleOf(gpa, .{ @as(u64, 2), "world", @as(u64, 9) });
    defer gpa.free(tuple);

    // Fields declared qty, name, id — reverse of the format order.
    const Row = struct { qty: u64, name: []const u8, id: u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(u64, 2), r.id);
    try testing.expectEqualStrings("world", r.name);
    try testing.expectEqual(@as(u64, 9), r.qty);
}

test "decodeRow: a subset struct skips the unnamed interleaved positions" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    const tuple = try tupleOf(gpa, .{ @as(u64, 3), "middle", @as(u64, 11) });
    defer gpa.free(tuple);

    // Names only id (pos 0) and qty (pos 2) — position 1 (name) is skipped.
    const Row = struct { id: u64, qty: u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(u64, 3), r.id);
    try testing.expectEqual(@as(u64, 11), r.qty);
}

test "decodeRow: optional field absent from a short tuple decodes as null" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    // Tuple of length 2 — qty (format position 2) is not present.
    const tuple = try tupleOf(gpa, .{ @as(u64, 4), "short" });
    defer gpa.free(tuple);

    const Row = struct { id: u64, name: []const u8, qty: ?u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(u64, 4), r.id);
    try testing.expectEqualStrings("short", r.name);
    try testing.expectEqual(@as(?u64, null), r.qty);
}

test "decodeRow: an optional field present in the tuple decodes its value" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    const tuple = try tupleOf(gpa, .{ @as(u64, 5), "full", @as(u64, 13) });
    defer gpa.free(tuple);

    const Row = struct { id: u64, name: []const u8, qty: ?u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(?u64, 13), r.qty);
}

test "decodeRow: a struct field not in the format is FieldNotInFormat" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    const tuple = try tupleOf(gpa, .{ @as(u64, 6), "x", @as(u64, 1) });
    defer gpa.free(tuple);

    const Row = struct { id: u64, bogus: u64 };
    try testing.expectError(error.FieldNotInFormat, decodeRow(Row, w, tuple));
}

test "decodeRow: a non-optional field beyond the tuple length is MissingField" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    // Tuple of length 2 — qty (format position 2) is absent and non-optional.
    const tuple = try tupleOf(gpa, .{ @as(u64, 7), "nope" });
    defer gpa.free(tuple);

    const Row = struct { id: u64, name: []const u8, qty: u64 };
    try testing.expectError(error.MissingField, decodeRow(Row, w, tuple));
}

test "decodeRow: unnamed positions of any msgpack shape are walked over" {
    const gpa = testing.allocator;
    var schema = try widgetsSchema(gpa);
    defer schema.deinit();
    const w = schema.space("widgets").?;

    // Position 1 (name) is a NESTED array here — skipping must value-walk it,
    // not assume a scalar, to reach qty at position 2.
    const tuple = try tupleOf(gpa, .{ @as(u64, 8), .{ "a", "bb", "ccc" }, @as(u64, 15) });
    defer gpa.free(tuple);

    const Row = struct { id: u64, qty: u64 };
    const r = try decodeRow(Row, w, tuple);
    try testing.expectEqual(@as(u64, 8), r.id);
    try testing.expectEqual(@as(u64, 15), r.qty);
}
