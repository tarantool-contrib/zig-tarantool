//! Tarantool `key_def` module: compare tuples and extract keys by a key
//! definition. `KeyDef` is the host-bound handle wrapping `box_key_def_t`;
//! the pure value types `FieldType`/`KeyPartDef` describe a key
//! definition and carry no Tarantool C dependency.
//!
//! `FieldType` integer values mirror Tarantool's `enum field_type` exactly;
//! the match is asserted at compile time in `c_verify.zig`, the only
//! site that includes `module.h`.

const std = @import("std");
const c = @import("c.zig");
const tuple = @import("tuple.zig");
const region = @import("region.zig");
const msgpack = @import("msgpack");

const Tuple = tuple.Tuple;

/// Type of a key part's field. Values match the leading members of Tarantool's
/// `enum field_type` (the subset valid for key parts).
pub const FieldType = enum(c_int) {
    /// any MessagePack type
    any = 0,
    /// non-negative integer
    unsigned = 1,
    /// UTF-8 string
    string = 2,
    /// integer or floating point
    number = 3,
    /// double-precision float
    double = 4,
    /// signed integer
    integer = 5,
    /// boolean
    boolean = 6,
    /// binary data
    varbinary = 7,
    /// any comparable scalar (bool/number/string/varbinary)
    scalar = 8,
    /// arbitrary-precision decimal
    decimal = 9,
    /// UUID
    uuid = 10,
    /// datetime
    datetime = 11,
};

/// One part of a key definition: which tuple field it refers to and its type.
pub const KeyPartDef = struct {
    /// 0-based field number within the tuple.
    fieldno: u32,
    /// Expected type of the field.
    type: FieldType,
};

pub const Error = error{
    /// `box_key_def_new` returned null (the host could not build the key_def).
    KeyDefFailed,
    /// `box_key_def_extract_key`/`box_tuple_extract_key` returned a null key
    /// buffer for the given tuple.
    ExtractFailed,
};

/// A host-bound key definition. Owns a `*box_key_def_t` and frees it on
/// `deinit`; compare tuples and extract keys against it. Construct with
/// `init` from a slice of `KeyPartDef`.
pub const KeyDef = struct {
    raw: *c.box_key_def_t,

    /// Build a key_def from `parts`. Packs the field numbers and field types
    /// into two parallel `[]u32` scratch arrays on `alloc` and hands them to
    /// `box_key_def_new`, which copies them into the new key_def — so the
    /// scratch is freed right after the call. `alloc` backs the scratch only and
    /// may be `region.allocator()` (no `Savepoint` is taken here; the host copies
    /// synchronously). Null return → `Error.KeyDefFailed`.
    pub fn init(parts: []const KeyPartDef, alloc: std.mem.Allocator) !KeyDef {
        const fields = try alloc.alloc(u32, parts.len);
        defer alloc.free(fields);
        const types = try alloc.alloc(u32, parts.len);
        defer alloc.free(types);

        for (parts, 0..) |p, i| {
            fields[i] = p.fieldno;
            types[i] = @intCast(@backingInt(p.type));
        }

        const raw = c.box_key_def_new(fields.ptr, types.ptr, @intCast(parts.len)) orelse
            return Error.KeyDefFailed;
        return .{ .raw = raw };
    }

    /// Free the underlying host key_def. Do not use the handle after.
    pub fn deinit(self: KeyDef) void {
        c.box_key_def_delete(self.raw);
    }

    /// Compare tuples `a` and `b` by this key definition, mapping the host's
    /// signed result onto `std.math.Order`.
    pub fn compare(self: KeyDef, a: Tuple, b: Tuple) std.math.Order {
        return std.math.order(c.box_tuple_compare(a.raw, b.raw, self.raw), 0);
    }

    /// Compare tuple `t` against `key` (an arbitrary value encoded as a
    /// MessagePack array) by this key definition, mapping the host's signed
    /// result onto `std.math.Order`. `alloc` backs the encode scratch
    /// only; the caller owns it (and any bounding `region.Savepoint`) and the
    /// host copies the bytes synchronously within this call.
    pub fn compareWithKey(self: KeyDef, t: Tuple, key: anytype, alloc: std.mem.Allocator) !std.math.Order {
        var buf = msgpack.Buffer.init(alloc);
        defer buf.deinit();
        try msgpack.encode(&buf, key);

        const key_b: [*c]const u8 = buf.items().ptr;
        return std.math.order(c.box_tuple_compare_with_key(t.raw, key_b, self.raw), 0);
    }

    /// Extract the key of tuple `t` by this key definition, returned as owned
    /// MessagePack key bytes (the caller frees with `alloc.free`). The host
    /// returns the key buffer ON the fiber region, so it is copied into `alloc`
    /// under a `region.Savepoint` that truncates the region buffer before return
    /// — no region pointer escapes. `multikey_idx` is fixed to -1
    /// (non-multikey). Null return → `Error.ExtractFailed`.
    pub fn extractKey(self: KeyDef, t: Tuple, alloc: std.mem.Allocator) ![]u8 {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var size: u32 = undefined;
        const ptr = c.box_key_def_extract_key(self.raw, t.raw, -1, &size) orelse
            return Error.ExtractFailed;
        // dupe BEFORE the deferred restore() truncates the region buffer.
        return try alloc.dupe(u8, ptr[0..size]);
    }
};
