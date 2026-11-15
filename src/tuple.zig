//! Tuple access — a thin, borrowing wrapper over a host `box_tuple_t`.
//!
//! A `Tuple` returned by a box CRUD call borrows host memory that is only
//! guaranteed valid until the *next* box call, unless the tuple has been
//! ref'd. The box layer ref's every tuple it hands out, so a `Tuple` you
//! receive owns a reference you must release with `deinit`. Within that ref'd
//! lifetime, `field`/`decode` read directly from the tuple's MessagePack array
//! (`box_tuple_data`); copy or `decode` out anything you need before dropping
//! the reference.

const std = @import("std");
const c = @import("c.zig");
const msgpack = @import("msgpack");
// Imported as `update_ops` (not `update`) so it does not collide with the
// `Tuple.update` method name (Zig flags that reference as ambiguous).
const update_ops = @import("tarantool-proto").update;

pub const Error = error{
    /// `box_tuple_data` returned a null pointer for a non-null tuple.
    NullTupleData,
    /// `box_tuple_new` returned null (the host could not build the tuple).
    NewFailed,
    /// `box_tuple_update` returned null (no update produced, or a client
    /// error left on the host error stack).
    UpdateFailed,
};

/// Borrowing handle over a host tuple. Construct via the box layer; release the
/// underlying host reference with `deinit`.
pub const Tuple = struct {
    raw: *c.box_tuple_t,

    /// Wrap a raw host tuple. Does NOT add a reference; the box layer ref's
    /// before wrapping so the returned handle owns exactly one reference.
    pub fn init(raw: *c.box_tuple_t) Tuple {
        return .{ .raw = raw };
    }

    /// Construct a new tuple from `values` (encoded as a MessagePack array via
    /// the shared codec) using the default tuple format. The new tuple is
    /// ref'd and owned by the caller (release with `deinit`). The
    /// encode scratch buffer is freed right after `box_tuple_new` because the
    /// host copies the bytes. `alloc` backs the scratch buffer only.
    ///
    /// `alloc` may be `region.allocator()`: this method is allocator-agnostic
    /// and adds no `Savepoint` of its own. When the region is used, the CALLER
    /// owns the bounding `region.Savepoint` and must keep it open until after
    /// the host has copied the scratch — i.e. until at least `box_tuple_new`
    /// returns here. The built tuple is host-ref'd, so the caller
    /// may safely restore the savepoint once this call returns.
    pub fn new(values: anytype, alloc: std.mem.Allocator) !Tuple {
        var buf = msgpack.Buffer.init(alloc);
        defer buf.deinit();

        try msgpack.encode(&buf, values);

        const b = buf.items();
        const begin: [*c]const u8 = b.ptr;
        const raw = c.box_tuple_new(c.box_tuple_format_default(), begin, begin + b.len) orelse
            return Error.NewFailed;

        _ = c.box_tuple_ref(raw);
        return Tuple.init(raw);
    }

    /// Apply update `ops` to this tuple and return a NEW owned tuple; the
    /// original is left unchanged. `ops` is the shared update-op format
    /// (`update.zig`): a comptime tuple of constructors (e.g.
    /// `.{ update.set(1, "x") }`) or a runtime `update.Ops` builder, encoded
    /// through the single `update.encodeOps` path (no second encoder).
    ///
    /// FIELD NUMBERS ARE **1-BASED** here: `update.set(1, ...)` targets the
    /// FIRST field. This matches Lua `tuple:update` and is host-defined —
    /// `box_tuple_update` takes no index-base parameter. Note this DIFFERS from
    /// the 0-based `Space.update`/`Index.update`; ops are passed straight
    /// through with no rebasing.
    ///
    /// The returned tuple is ref'd and caller-owned (release with `deinit`). The encode scratch buffer is freed right after the call because
    /// the host copies the expression bytes. `alloc` backs the scratch only.
    ///
    /// `alloc` may be `region.allocator()`: this method is allocator-agnostic
    /// and adds no `Savepoint` of its own. When the region is used, the CALLER
    /// owns the bounding `region.Savepoint` and must keep it open until after
    /// the host has copied the scratch — i.e. until at least `box_tuple_update`
    /// returns here. The returned tuple is host-ref'd, so the
    /// caller may safely restore the savepoint once this call returns.
    pub fn update(self: Tuple, ops: anytype, alloc: std.mem.Allocator) !Tuple {
        var obuf = try update_ops.encodeOps(alloc, ops);
        defer obuf.deinit();

        const o = obuf.items();
        const begin: [*c]const u8 = o.ptr;
        const raw = c.box_tuple_update(self.raw, begin, begin + o.len) orelse
            return Error.UpdateFailed;

        _ = c.box_tuple_ref(raw);
        return Tuple.init(raw);
    }

    /// Total size in bytes of the tuple's MessagePack data.
    pub fn bsize(self: Tuple) usize {
        return c.box_tuple_bsize(self.raw);
    }

    /// Open a forward field cursor over this tuple. The iterator borrows the
    /// tuple, which must stay ref'd for the cursor's lifetime; free the
    /// cursor with `FieldIterator.deinit`.
    pub fn fieldIterator(self: Tuple) !FieldIterator {
        const raw = c.box_tuple_iterator(self.raw) orelse return Error.NewFailed;

        var sz: usize = undefined;
        const data = c.box_tuple_data(self.raw, &sz);
        if (data == null) {
            c.box_tuple_iterator_free(raw);
            return Error.NullTupleData;
        }

        return .{ .raw = raw, .data = data[0..sz] };
    }

    /// Release the host reference acquired when this handle was created. After
    /// `deinit` the tuple memory may be reclaimed by the host; do not use the
    /// handle further.
    pub fn deinit(self: Tuple) void {
        c.box_tuple_unref(self.raw);
    }

    /// Number of top-level fields in the tuple.
    pub fn fieldCount(self: Tuple) u32 {
        return c.box_tuple_field_count(self.raw);
    }

    /// Decode field `i` (0-based) as a schema-less `Value`, or null if the
    /// field does not exist. The returned `Value` borrows the tuple buffer for
    /// scalar str/bin; any array/map containers are allocated via `alloc` and
    /// owned by the caller. The field slice is bounded by the tuple's total
    /// data end so the decoder cannot run past the tuple.
    pub fn field(self: Tuple, i: u32, alloc: std.mem.Allocator) !?msgpack.Value {
        const ptr = c.box_tuple_field(self.raw, i);
        if (ptr == null) return null;

        var sz: usize = undefined;
        const data = c.box_tuple_data(self.raw, &sz);
        if (data == null) return Error.NullTupleData;

        // Bound the field slice by the tuple's total data end: the field
        // pointer lies within [data, data+sz).
        const base = @intFromPtr(data);
        const off = @intFromPtr(ptr) - base;
        const slice = data[off..sz];

        var dec = msgpack.Decoder.init(slice);
        return try dec.decodeValue(alloc);
    }

    /// Decode field `i` (0-based) as a concrete type `T`, or null if the field
    /// does not exist (`i >= fieldCount()`). A type mismatch surfaces as the
    /// codec's decode error — never a silent coercion. Locates field `i`'s
    /// raw MessagePack (same path as `field`) and decodes those bytes as `T`.
    ///
    /// A `[]const u8` result BORROWS the tuple's raw data (the codec returns a
    /// slice into it, it does not copy), so it is valid only while this tuple is
    /// alive — do not retain it past `deinit`. `alloc` is accepted for signature
    /// consistency with `field`/`decode` and is currently unused: the codec's
    /// `decode` borrows rather than allocates for every `T` it supports.
    pub fn get(self: Tuple, i: u32, comptime T: type, alloc: std.mem.Allocator) !?T {
        _ = alloc;
        const ptr = c.box_tuple_field(self.raw, i);
        if (ptr == null) return null;

        var sz: usize = undefined;
        const data = c.box_tuple_data(self.raw, &sz);
        if (data == null) return Error.NullTupleData;

        // Bound the field slice by the tuple's total data end (as in `field`).
        const base = @intFromPtr(data);
        const off = @intFromPtr(ptr) - base;
        const slice = data[off..sz];

        var dec = msgpack.Decoder.init(slice);
        return try msgpack.decode(T, &dec);
    }

    /// Decode the whole tuple (its MessagePack array) into a concrete type `T`.
    /// For fixed-shape `T` (tuple struct, array, scalar) this is allocation
    /// free; `alloc` is accepted for signature stability and is unused in that
    /// path. The tuple must remain ref'd for the duration of this call.
    pub fn decode(self: Tuple, comptime T: type, alloc: std.mem.Allocator) !T {
        _ = alloc;
        var sz: usize = undefined;
        const data = c.box_tuple_data(self.raw, &sz);
        if (data == null) return Error.NullTupleData;

        var dec = msgpack.Decoder.init(data[0..sz]);
        return try msgpack.decode(T, &dec);
    }

    /// Decode the whole tuple's MessagePack array positionally into the named
    /// struct `Row` (`decodeArray`: array header of N, then each field in
    /// declaration order). The arity must match `Row`'s field count
    /// or the codec returns `error.ArityMismatch`; a type mismatch surfaces as
    /// the codec's decode error, never a silent coercion.
    ///
    /// This is a BORROW decode and takes no `alloc`: any `[]const u8` field in
    /// the result aliases the tuple's raw data (the codec returns a slice into
    /// it), so it is valid only while this tuple is ref'd — do NOT retain
    /// such a field past `deinit`. Copy out anything that must outlive the
    /// tuple (`box.Typed(Row).get` does exactly this). The tuple must remain
    /// ref'd for the duration of this call.
    pub fn decodeRow(self: Tuple, comptime Row: type) !Row {
        var sz: usize = undefined;
        const data = c.box_tuple_data(self.raw, &sz);
        if (data == null) return Error.NullTupleData;

        var dec = msgpack.Decoder.init(data[0..sz]);
        return try msgpack.decodeArray(Row, &dec);
    }
};

/// A forward field cursor over a tuple's MessagePack array. Owns the host
/// `box_tuple_iterator_t` and frees it on `deinit`. It borrows the tuple,
/// captured here as the full data slice `data`; the tuple must stay ref'd for
/// the cursor's lifetime. Field pointers from the host are decoded immediately
/// against `data`, never retained.
pub const FieldIterator = struct {
    raw: *c.box_tuple_iterator_t,
    data: []const u8,

    /// Decode the field at the host-returned `ptr`, bounded by the tuple's data
    /// end (same bounding as `Tuple.field`).
    fn decodeAt(self: *const FieldIterator, ptr: [*c]const u8, alloc: std.mem.Allocator) !msgpack.Value {
        const base = @intFromPtr(self.data.ptr);
        const off = @intFromPtr(ptr) - base;
        var dec = msgpack.Decoder.init(self.data[off..]);
        return try dec.decodeValue(alloc);
    }

    /// Advance and decode the next field, or null at the end. Containers are
    /// allocated via `alloc` and owned by the caller (see `Tuple.field`).
    pub fn next(self: *FieldIterator, alloc: std.mem.Allocator) !?msgpack.Value {
        const ptr = c.box_tuple_next(self.raw);
        if (ptr == null) return null;
        return try self.decodeAt(ptr, alloc);
    }

    /// Position the cursor at field `fieldno` (0-based) and decode it, or null if
    /// it does not exist.
    pub fn seek(self: *FieldIterator, fieldno: u32, alloc: std.mem.Allocator) !?msgpack.Value {
        const ptr = c.box_tuple_seek(self.raw, fieldno);
        if (ptr == null) return null;
        return try self.decodeAt(ptr, alloc);
    }

    /// The 0-based position of the field the next `next` will return.
    pub fn position(self: *const FieldIterator) u32 {
        return c.box_tuple_position(self.raw);
    }

    /// Reset the cursor to the first field.
    pub fn rewind(self: *FieldIterator) void {
        c.box_tuple_rewind(self.raw);
    }

    /// Free the host iterator. Does not affect the borrowed tuple.
    pub fn deinit(self: *FieldIterator) void {
        c.box_tuple_iterator_free(self.raw);
    }
};
