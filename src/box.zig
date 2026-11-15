//! Box data API: spaces, indexes, CRUD, and iteration.
//!
//! A `Space` is a thin handle over a resolved space id; an `Index` adds the
//! index id. Each one-shot call taking a tuple/key encodes it as a MessagePack
//! array on the fiber region under a per-call `region.Savepoint` and passes it
//! to the host C ABI; because the host copies its input synchronously, the
//! region is truncated back to the mark as the call returns. `Index.iterator`
//! is the exception: its key must outlive the call (the host retains the
//! pointer across yields), so it stays `c_allocator`-owned by the `Iterator`.
//! Failures are never swallowed: a missing space/index, a -1 C return, or a
//! decode mismatch is surfaced as a Zig error.
//!
//! Tuples returned by reads are ref'd before being wrapped in a `Tuple`, so the
//! caller owns a host reference released via `Tuple.deinit`. A tuple from
//! `box_iterator_next` is valid only until the next step, so it too is
//! ref'd on wrap.

const std = @import("std");
const c = @import("c.zig");
const msgpack = @import("msgpack");
const tuple_mod = @import("tuple.zig");
const query = @import("tarantool-proto").query;
const update_mod = @import("tarantool-proto").update;
const region = @import("region.zig");

pub const Tuple = tuple_mod.Tuple;

pub const Error = error{
    /// The named space does not exist.
    NoSuchSpace,
    /// The named index does not exist on the space.
    NoSuchIndex,
    /// A host box operation returned -1; the host error stack holds details
    /// (read via `error.zig`/`box_error_last`).
    BoxOp,
};

/// Handle over a resolved space id. Cheap to copy.
pub const Space = struct {
    id: u32,

    /// Resolve a space by name. `error.NoSuchSpace` if the host has no such space.
    pub fn byName(name: []const u8) Error!Space {
        const id = c.box_space_id_by_name(name.ptr, @intCast(name.len));
        if (id == c.BOX_ID_NIL) return Error.NoSuchSpace;
        return .{ .id = id };
    }

    /// The primary index (id 0).
    pub fn primary(self: Space) Index {
        return .{ .space_id = self.id, .id = 0 };
    }

    /// An index by id (not validated against the schema).
    pub fn indexById(self: Space, index_id: u32) Index {
        return .{ .space_id = self.id, .id = index_id };
    }

    /// Resolve an index by name. `error.NoSuchIndex` if absent.
    pub fn index(self: Space, name: []const u8) Error!Index {
        const iid = c.box_index_id_by_name(self.id, name.ptr, @intCast(name.len));
        if (iid == c.BOX_ID_NIL) return Error.NoSuchIndex;
        return .{ .space_id = self.id, .id = iid };
    }

    /// Insert `tuple`. Returns the stored tuple (ref'd; caller `deinit`s), or null.
    pub fn insert(self: Space, tuple: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), tuple);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_insert(self.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Insert `tuple`, discarding the returned tuple (one host call).
    pub fn insertDiscard(self: Space, tuple: anytype) !void {
        if (try self.insert(tuple)) |row| row.deinit();
    }

    /// Replace (upsert by primary key) with `tuple`. Returns the stored tuple, or null.
    pub fn replace(self: Space, tuple: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), tuple);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_replace(self.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Replace with `tuple`, discarding the returned tuple (one host call).
    pub fn replaceDiscard(self: Space, tuple: anytype) !void {
        if (try self.replace(tuple)) |row| row.deinit();
    }

    /// Delete by primary key. Returns the deleted tuple, or null.
    pub fn delete(self: Space, key: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), key);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_delete(self.id, 0, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Delete by primary key, discarding the deleted tuple (one host call).
    pub fn deleteDiscard(self: Space, key: anytype) !void {
        if (try self.delete(key)) |row| row.deinit();
    }

    /// Point-get by primary key. Delegates to the primary index.
    pub fn get(self: Space, key: anytype) !?Tuple {
        return self.primary().get(key);
    }

    /// Update the tuple matching `key` by primary key with `ops`. Delegates to
    /// the primary index. Returns the updated tuple (ref'd), or null.
    pub fn update(self: Space, key: anytype, ops: anytype) !?Tuple {
        return self.primary().update(key, ops);
    }

    /// Update `key` with `ops`, discarding the updated tuple (one host call).
    pub fn updateDiscard(self: Space, key: anytype, ops: anytype) !void {
        if (try self.update(key, ops)) |row| row.deinit();
    }

    /// Upsert by primary key: insert `tuple` if no row matches its key,
    /// otherwise apply `ops` to the existing row (on the primary index 0).
    /// Returns null (upsert never returns a tuple to a C module).
    pub fn upsert(self: Space, tuple: anytype, ops: anytype) !?Tuple {
        // One savepoint covers both the tuple buffer and the ops buffer.
        var svp = region.Savepoint.save();
        defer svp.restore();
        var tbuf = try encodeArgs(region.allocator(), tuple);
        defer tbuf.deinit();
        var obuf = try update_mod.encodeOps(region.allocator(), ops);
        defer obuf.deinit();
        const t = tbuf.items();
        const o = obuf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_upsert(self.id, 0, t.ptr, t.ptr + t.len, o.ptr, o.ptr + o.len, 0, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Upsert `tuple`/`ops`, discarding any returned tuple (one host call).
    pub fn upsertDiscard(self: Space, tuple: anytype, ops: anytype) !void {
        if (try self.upsert(tuple, ops)) |row| row.deinit();
    }

    /// Remove every tuple from the space. Requires a writable instance (fails
    /// with `Error.BoxOp` / ER_READONLY on a read-only one). Maps a -1 host
    /// return to `Error.BoxOp`, leaving the diag on the host stack.
    /// Note: on this host truncate does NOT bump `info.schemaVersion` — it
    /// updates the internal `_truncate` space, not the schema.
    pub fn truncate(self: Space) Error!void {
        if (c.box_truncate(self.id) != 0) return Error.BoxOp;
    }
};

/// True for `[]const u8` (the only string row-field type — `[]u8` is rejected
/// because the codec decodes a msgpack str as `[]const u8` and cannot
/// round-trip a mutable slice). Shared by `validateRow`/`dupeStrings`/`free`
/// so the "is a string field" rule has exactly one definition.
fn isStr(comptime T: type) bool {
    const ti = @typeInfo(T);
    return ti == .pointer and
        ti.pointer.size == .slice and
        ti.pointer.child == u8 and
        ti.pointer.attrs.@"const";
}

/// True for a type a `Typed(Row)` field may have: an int/float/bool/enum
/// scalar, or `[]const u8`. Every other type — including `[]u8`, other
/// slices, optionals, nested structs — is rejected.
fn supported(comptime T: type) bool {
    if (isStr(T)) return true;
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// Dupe every `[]const u8` field of `*row` into `alloc`, replacing the borrowed
/// (tuple-aliasing) slice with an owned copy. On a later OOM, each unrolled
/// iteration's own `errdefer` fires LIFO and frees the dupes made by prior
/// iterations, so a partial failure leaks nothing. Scalar fields are
/// skipped at comptime. Shared by `Typed.get` and `Range.next` so the copy-out
/// rule has exactly one definition.
fn dupeStrings(comptime Row: type, row: *Row, alloc: std.mem.Allocator) !void {
    const row_info = @typeInfo(Row).@"struct";
    inline for (row_info.field_names, row_info.field_types) |name, ty| {
        if (comptime isStr(ty)) {
            const d = try alloc.dupe(u8, @field(row.*, name));
            errdefer alloc.free(d);
            @field(row.*, name) = d;
        }
    }
}

/// Free exactly the fields `dupeStrings` duped: every `[]const u8` field of
/// `row` is freed via `alloc`; all other fields are left untouched. A
/// scalar-only `Row` makes this a no-op. Pass the same allocator that produced
/// the row; freeing a row that `dupeStrings` produced is leak- and
/// double-free-free. Shared by `Typed.free`, `Range.free`, and `Range.freeSlice`
/// so the free rule has exactly one definition.
fn freeRow(comptime Row: type, row: Row, alloc: std.mem.Allocator) void {
    const row_info = @typeInfo(Row).@"struct";
    inline for (row_info.field_names, row_info.field_types) |name, ty| {
        if (comptime isStr(ty)) alloc.free(@field(row, name));
    }
}

/// A typed view over a space whose rows are the named struct `Row`, encoded
/// and decoded POSITIONALLY (declaration order ⇄ tuple fields). Each
/// `Row` field must be an int/float/bool/enum scalar or `[]const u8`; any other
/// field type is a `@compileError` at instantiation.
///
/// Ownership: `put` encodes the row in one `box_replace` and discards the
/// returned tuple; `insert` is its fail-on-duplicate sibling (one
/// `box_insert`, same discard semantics). `get` decodes positionally and DUPES every `[]const u8`
/// field into the caller's `alloc` so the returned `Row` outlives the host
/// tuple, which is released before return; free that row with `free`.
/// A scalar-only `Row` allocates nothing, so `get`/`free` are a no-op on
/// the allocator.
pub fn Typed(comptime Row: type) type {
    const ti = @typeInfo(Row);
    if (ti != .@"struct") @compileError("Typed(Row): Row must be a struct, got " ++ @typeName(Row));
    inline for (ti.@"struct".field_names, ti.@"struct".field_types) |name, ty| {
        if (!supported(ty)) @compileError(
            "Typed(Row): field '" ++ name ++ "' has unsupported type " ++ @typeName(ty) ++
                " (allowed: int/float/bool/enum or []const u8)",
        );
    }

    return struct {
        space: Space,

        const Self = @This();

        /// Resolve the backing space by name. `error.NoSuchSpace` if absent.
        pub fn byName(name: []const u8) Error!Self {
            return .{ .space = try Space.byName(name) };
        }

        /// Replace (upsert by primary key) with `row`, encoded positionally as a
        /// MessagePack array via `encodeArray` in a single `box_replace`; the
        /// returned tuple is discarded. The row is NEVER encoded as a
        /// map. The encode scratch lives on the fiber region under a per-call
        /// `Savepoint`, truncated as the call returns (the host copies its input
        /// synchronously, as in `Space.replace`).
        pub fn put(self: Self, row: Row) !void {
            var svp = region.Savepoint.save();
            defer svp.restore();
            var buf = msgpack.Buffer.init(region.allocator());
            defer buf.deinit();
            try msgpack.encodeArray(&buf, row);
            const b = buf.items();
            var result: ?*c.box_tuple_t = null;
            if (c.box_replace(self.space.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
            if (wrap(result)) |t| t.deinit();
        }

        /// Insert `row` (fail on duplicate primary key) — the fail-on-duplicate
        /// sibling of `put`. Encoding identical to `put` (positional array on the
        /// region under a Savepoint); a duplicate key surfaces as `Error.BoxOp`
        /// with the host's "Duplicate key exists…" diag readable via `err`.
        pub fn insert(self: Self, row: Row) !void {
            var svp = region.Savepoint.save();
            defer svp.restore();
            var buf = msgpack.Buffer.init(region.allocator());
            defer buf.deinit();
            try msgpack.encodeArray(&buf, row);
            const b = buf.items();
            var result: ?*c.box_tuple_t = null;
            if (c.box_insert(self.space.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
            if (wrap(result)) |t| t.deinit();
        }

        /// Point-get by primary `key` (a key tuple, e.g. `.{1}`), decoded
        /// positionally into `Row`. Returns null when no row matches. Every
        /// `[]const u8` field is duped into `alloc` so the returned `Row`
        /// outlives the host tuple; the host tuple is released before
        /// return and no pointer into it escapes. Free the result with
        /// `free`. A scalar-only `Row` performs no allocation.
        pub fn get(self: Self, key: anytype, alloc: std.mem.Allocator) !?Row {
            const t = (try self.space.get(key)) orelse return null;
            defer t.deinit();
            var row = try t.decodeRow(Row);
            try dupeStrings(Row, &row, alloc);
            return row;
        }

        /// Delete by primary `key`, discarding the deleted tuple (one host call). Delegates to the existing `Space` delete path.
        pub fn del(self: Self, key: anytype) !void {
            return self.space.deleteDiscard(key);
        }

        /// Free exactly the fields `get` duped: every `[]const u8` field of
        /// `row` is freed via `alloc`; all other fields are left untouched.
        /// A scalar-only `Row` makes this a no-op. Pass the same
        /// allocator `get` was given; calling `free` on a row that `get`
        /// produced is leak- and double-free-free.
        pub fn free(row: Row, alloc: std.mem.Allocator) void {
            freeRow(Row, row, alloc);
        }
    };
}

/// Handle over a (space, index) pair. Cheap to copy.
pub const Index = struct {
    space_id: u32,
    id: u32,

    /// Point-get by `key`. Returns the matching tuple (ref'd), or null.
    pub fn get(self: Index, key: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), key);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_index_get(self.space_id, self.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Update the tuple matching `key` by applying `ops`. `index_base = 0`, so op
    /// field numbers are 0-based. Returns the updated tuple (ref'd), or null.
    pub fn update(self: Index, key: anytype, ops: anytype) !?Tuple {
        // One savepoint covers both the key buffer and the ops buffer.
        var svp = region.Savepoint.save();
        defer svp.restore();
        var kbuf = try encodeArgs(region.allocator(), key);
        defer kbuf.deinit();
        var obuf = try update_mod.encodeOps(region.allocator(), ops);
        defer obuf.deinit();
        const k = kbuf.items();
        const o = obuf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_update(self.space_id, self.id, k.ptr, k.ptr + k.len, o.ptr, o.ptr + o.len, 0, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Minimum tuple matching `key` (`.{}` for the global minimum), or null.
    pub fn min(self: Index, key: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), key);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_index_min(self.space_id, self.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Maximum tuple matching `key` (`.{}` for the global maximum), or null.
    pub fn max(self: Index, key: anytype) !?Tuple {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), key);
        defer buf.deinit();
        const b = buf.items();
        var result: ?*c.box_tuple_t = null;
        if (c.box_index_max(self.space_id, self.id, b.ptr, b.ptr + b.len, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Count tuples matching `key` under iterator `iter`.
    pub fn count(self: Index, iter: query.IteratorType, key: anytype) !usize {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var buf = try encodeArgs(region.allocator(), key);
        defer buf.deinit();
        const b = buf.items();
        const n = c.box_index_count(self.space_id, self.id, @backingInt(iter), b.ptr, b.ptr + b.len);
        if (n < 0) return Error.BoxOp;
        return @intCast(n);
    }

    /// Number of tuples in the index.
    pub fn len(self: Index) !usize {
        const n = c.box_index_len(self.space_id, self.id);
        if (n < 0) return Error.BoxOp;
        return @intCast(n);
    }

    /// Memory footprint of the index, in bytes.
    pub fn bsize(self: Index) !usize {
        const n = c.box_index_bsize(self.space_id, self.id);
        if (n < 0) return Error.BoxOp;
        return @intCast(n);
    }

    /// A pseudo-random tuple seeded by `seed`, or null if the index is empty.
    pub fn random(self: Index, seed: u32) !?Tuple {
        var result: ?*c.box_tuple_t = null;
        if (c.box_index_random(self.space_id, self.id, seed, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    /// Extract the key of tuple `t` by this index's key definition, returned as
    /// owned MessagePack key bytes (the caller frees with `alloc.free`). The host
    /// returns the key buffer ON the fiber region, so it is copied into `alloc`
    /// under a `region.Savepoint` that truncates the region buffer before return
    /// — no region pointer escapes. Null return → `Error.BoxOp`.
    pub fn extractKey(self: Index, t: Tuple, alloc: std.mem.Allocator) ![]u8 {
        var svp = region.Savepoint.save();
        defer svp.restore();
        var size: u32 = undefined;
        const ptr = c.box_tuple_extract_key(t.raw, self.space_id, self.id, &size) orelse
            return Error.BoxOp;
        // dupe BEFORE the deferred restore() truncates the region buffer.
        return try alloc.dupe(u8, ptr[0..size]);
    }

    /// Open an iterator over tuples matching `key` under `iter` (`.{}` scans all).
    /// The host iterator keeps a pointer to the key, so the returned `Iterator`
    /// owns the key buffer until `deinit`.
    pub fn iterator(self: Index, iter: query.IteratorType, key: anytype) !Iterator {
        // The host iterator retains a pointer to this key across next()/yields,
        // so it must NOT live on the region — keep it c_allocator-owned by the
        // Iterator and free it on deinit.
        var buf = try encodeArgs(std.heap.c_allocator, key);
        errdefer buf.deinit();
        const b = buf.items();
        const it = c.box_index_iterator(self.space_id, self.id, @backingInt(iter), b.ptr, b.ptr + b.len) orelse
            return Error.BoxOp;
        return .{ .raw = it, .key_buf = buf };
    }

    /// Collect tuples matching `key`, honoring `opts.offset`/`opts.limit`. Each
    /// returned `Tuple` is ref'd and the slice is `alloc`-owned: the caller
    /// `deinit`s every tuple and frees the slice.
    pub fn select(self: Index, opts: query.SelectOptions, key: anytype, alloc: std.mem.Allocator) ![]Tuple {
        var it = try self.iterator(opts.iterator, key);
        defer it.deinit();

        var skipped: u32 = 0;
        while (skipped < opts.offset) : (skipped += 1) {
            const t = (try it.next()) orelse break;
            t.deinit();
        }

        var out: std.ArrayList(Tuple) = .empty;
        errdefer {
            for (out.items) |t| t.deinit();
            out.deinit(alloc);
        }
        while (true) {
            if (opts.limit) |lim| {
                if (out.items.len >= lim) break;
            }
            const t = (try it.next()) orelse break;
            errdefer t.deinit(); // release this ref if the append below OOMs
            try out.append(alloc, t);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Open a typed, auto-freeing cursor over tuples matching `key` under
    /// `opts.iterator`, decoding each into `Row`. Mirrors `select`'s
    /// `(opts, key, alloc)` shape: it opens the host iterator, eagerly skips
    /// `opts.offset` tuples (unref'ing each), and returns a `Range(Row)` that
    /// owns the iterator + the `c_allocator` key buffer the host retains.
    /// `opts.limit` caps how many rows `next` yields. Free each row with
    /// `Range(Row).free`; `deinit` the range when done.
    pub fn range(self: Index, comptime Row: type, opts: query.SelectOptions, key: anytype, alloc: std.mem.Allocator) !Range(Row) {
        var it = try self.iterator(opts.iterator, key);
        errdefer it.deinit();

        var skipped: u32 = 0;
        while (skipped < opts.offset) : (skipped += 1) {
            const t = (try it.next()) orelse break;
            t.deinit();
        }

        return .{ .it = it, .alloc = alloc, .remaining = opts.limit };
    }

    /// Open an auto-freeing raw-tuple cursor over tuples matching `key` under
    /// `opts.iterator` — the raw analog of `range` (it yields borrowed `Tuple`s
    /// rather than decoded rows, so it needs no allocator). Eagerly skips
    /// `opts.offset` tuples (unref'ing each) and caps `next` at `opts.limit`.
    /// The yielded tuple is valid only until the next `next`/`deinit`;
    /// `deinit` the cursor when done.
    pub fn cursor(self: Index, opts: query.SelectOptions, key: anytype) !Cursor {
        var it = try self.iterator(opts.iterator, key);
        errdefer it.deinit();

        var skipped: u32 = 0;
        while (skipped < opts.offset) : (skipped += 1) {
            const t = (try it.next()) orelse break;
            t.deinit();
        }

        return .{ .it = it, .current = null, .remaining = opts.limit };
    }

    /// The `n` largest tuples in descending index order, decoded into an
    /// `alloc`-owned `[]Row` (the leaderboard "empty key + `.le` = full
    /// descending scan" idiom). Each Row's `[]const u8` fields are duped
    /// into `alloc`; free the result with `Range(Row).freeSlice`.
    pub fn top(self: Index, n: u32, comptime Row: type, alloc: std.mem.Allocator) ![]Row {
        var r = try self.range(Row, .{ .iterator = .le, .limit = n }, .{}, alloc);
        defer r.deinit();

        var out: std.ArrayList(Row) = .empty;
        errdefer {
            for (out.items) |row| freeRow(Row, row, alloc);
            out.deinit(alloc);
        }
        while (try r.next()) |row| {
            errdefer freeRow(Row, row, alloc); // free this row if append OOMs
            try out.append(alloc, row);
        }
        return out.toOwnedSlice(alloc);
    }
};

/// A live index cursor. Owns the host iterator and the key buffer it points at,
/// freeing both on `deinit`. A tuple from `next` is valid only until the
/// following `next`/`deinit` unless ref'd; `next` ref's each before returning it.
///
pub const Iterator = struct {
    raw: *c.box_iterator_t,
    key_buf: msgpack.Buffer,

    /// Advance and return the next tuple (ref'd; caller `deinit`s), or null at end.
    pub fn next(self: *Iterator) !?Tuple {
        var result: ?*c.box_tuple_t = null;
        if (c.box_iterator_next(self.raw, &result) != 0) return Error.BoxOp;
        return wrap(result);
    }

    pub fn deinit(self: *Iterator) void {
        c.box_iterator_free(self.raw);
        self.key_buf.deinit();
    }
};

/// An auto-freeing raw-tuple index cursor — the raw analog of `Range(Row)`.
/// Wraps an `Iterator` plus a `?u32 remaining` cap (from `opts.limit`) and holds
/// the last-yielded tuple. `next` releases the previously-yielded tuple before
/// handing out the next, so the caller frees nothing per tuple; the yielded
/// tuple is BORROWED — valid only until the following `next`/`deinit` — so copy
/// out (`get`/`decode`) anything that must outlive the advance (`Tuple` has
/// no public `ref`). `deinit` releases the outstanding tuple and the host
/// iterator exactly once.
pub const Cursor = struct {
    it: Iterator,
    current: ?Tuple,
    remaining: ?u32,

    /// Release the previously-yielded tuple, advance, and return the next tuple
    /// (ref'd by `Iterator.next`, owned by the cursor until the following
    /// `next`/`deinit`). `null` at end-of-iteration or once `opts.limit` is
    /// reached. Errors mirror `Iterator.next` (`error.BoxOp`).
    pub fn next(self: *Cursor) !?Tuple {
        if (self.current) |t| {
            t.deinit();
            self.current = null;
        }
        if (self.remaining) |r| if (r == 0) return null;
        const t = (try self.it.next()) orelse return null;
        self.current = t;
        if (self.remaining) |*r| r.* -= 1;
        return t;
    }

    /// Release the outstanding borrowed tuple (if any) and the host iterator
    /// exactly once.
    pub fn deinit(self: *Cursor) void {
        if (self.current) |t| t.deinit();
        self.it.deinit();
    }
};

/// A typed, auto-freeing index cursor over rows of the named struct `Row`,
/// decoded POSITIONALLY (declaration order ⇄ tuple fields). Wraps an `Iterator`
/// plus a `?u32 remaining` cap from `opts.limit`. Each `Row` field must be an
/// int/float/bool/enum scalar or `[]const u8`; any other field type is a
/// `@compileError` at instantiation (the same `supported()` guard as `Typed`).
///
/// Ownership: `next` decodes the next tuple, DUPES every `[]const u8` field into
/// the range's `alloc`, and releases the host tuple BEFORE returning — so no
/// pointer into the tuple buffer escapes and the row outlives the tuple.
/// Each tuple is fully consumed inside `next`, so nothing is retained
/// between calls; `deinit` frees the host iterator + key buffer exactly once.
/// Free a single row with `free`, a `top`-style slice with `freeSlice`.
pub fn Range(comptime Row: type) type {
    const ti = @typeInfo(Row);
    if (ti != .@"struct") @compileError("Range(Row): Row must be a struct, got " ++ @typeName(Row));
    inline for (ti.@"struct".field_names, ti.@"struct".field_types) |name, ty| {
        if (!supported(ty)) @compileError(
            "Range(Row): field '" ++ name ++ "' has unsupported type " ++ @typeName(ty) ++
                " (allowed: int/float/bool/enum or []const u8)",
        );
    }

    return struct {
        it: Iterator,
        alloc: std.mem.Allocator,
        remaining: ?u32,

        const Self = @This();

        /// Decode the next tuple positionally into `Row`, dupe its `[]const u8`
        /// fields into `alloc`, unref the host tuple, and return the `Row`.
        /// `null` at end-of-iteration or once `opts.limit` is reached. The tuple
        /// is released before `next` returns and no pointer into it escapes.
        /// Errors mirror `Iterator.next` (`error.BoxOp`) plus the
        /// decode/OOM errors — never a partial Row.
        pub fn next(self: *Self) !?Row {
            if (self.remaining) |r| if (r == 0) return null;
            const t = (try self.it.next()) orelse return null;
            defer t.deinit();
            var row = try t.decodeRow(Row);
            try dupeStrings(Row, &row, self.alloc);
            if (self.remaining) |*r| r.* -= 1;
            return row;
        }

        /// Free the host iterator and key buffer exactly once. Since `next`
        /// fully consumes each tuple, no host tuple is retained between calls —
        /// nothing leaks.
        pub fn deinit(self: *Self) void {
            self.it.deinit();
        }

        /// Free exactly the `[]const u8` fields `next` duped for one `row`.
        /// A scalar-only `Row` is a no-op. Pass the same allocator the
        /// range was given.
        pub fn free(row: Row, alloc: std.mem.Allocator) void {
            freeRow(Row, row, alloc);
        }

        /// Free every row's duped fields and then the slice itself (for `top`'s
        /// `[]Row`). Pass the same allocator `top` was given.
        pub fn freeSlice(rows: []Row, alloc: std.mem.Allocator) void {
            for (rows) |r| freeRow(Row, r, alloc);
            alloc.free(rows);
        }
    };
}

/// Encode `value` as a MessagePack array into a fresh buffer on `alloc`.
/// Caller `deinit`s the returned buffer (a no-op when `alloc` is the region;
/// reclamation there happens via a `Savepoint`).
fn encodeArgs(alloc: std.mem.Allocator, value: anytype) !msgpack.Buffer {
    var buf = msgpack.Buffer.init(alloc);
    errdefer buf.deinit();
    try msgpack.encode(&buf, value);
    return buf;
}

/// Ref a raw host tuple and wrap it; null stays null. The returned `Tuple` owns
/// one reference released via `Tuple.deinit`.
fn wrap(result: ?*c.box_tuple_t) ?Tuple {
    const raw = result orelse return null;
    _ = c.box_tuple_ref(raw);
    return Tuple.init(raw);
}

/// Instance introspection: read-only/writable state, role-change waits, schema
/// version, self LSN, and memtx slab statistics. Reachable as `t.box.info`.
/// Wraps `box_status`/`box_is_ro`/`box_wait_ro`/`box_ro_reason`/
/// `box_schema_version`/`box_info_lsn`/`box_slab_info`.
pub const info = struct {
    /// Documented host-contract instance states (module.h box_status doc).
    pub const Status = enum { running, loading, orphan, hot_standby };

    /// `waitRo`'s error set. A -1 host return is disambiguated via
    /// `fiber_is_cancelled()` — the cond.zig:74-77 pattern.
    pub const WaitError = error{ Timeout, Cancelled };

    /// Re-export of `c.box_slab_info_type` (memtx-scoped; matches Lua's
    /// `box.slab.info` naming). The enum lives in c.zig next to its extern so
    /// the c_verify value pin sits beside the definition.
    pub const Slab = c.box_slab_info_type; // items_size=0 .. quota_used=5

    /// Map a host status string to `Status`; unknown → null. Pure and
    /// comptime-callable (pinned by the comptime block below and 's panic).
    fn parseStatus(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "loading")) return .loading;
        if (std.mem.eql(u8, s, "orphan")) return .orphan;
        if (std.mem.eql(u8, s, "hot_standby")) return .hot_standby;
        return null;
    }

    /// The current instance status. An unknown host string is a loud panic
    /// (ABI drift), never a silent default.
    pub fn status() Status {
        const s = std.mem.span(c.box_status());
        return parseStatus(s) orelse std.debug.panic("unknown box_status: {s}", .{s});
    }

    /// Whether the instance is currently read-only.
    pub fn isRo() bool {
        return c.box_is_ro();
    }

    /// Park the fiber until the instance is read-only (`ro=true`) or read-write
    /// (`ro=false`), or `timeout` seconds elapse. A -1 host return is
    /// disambiguated into `Timeout`/`Cancelled` via `fiber_is_cancelled()`
    /// (cond.zig:74-77 pattern).
    pub fn waitRo(ro: bool, timeout: f64) WaitError!void {
        if (c.box_wait_ro(ro, timeout) != 0)
            return if (c.fiber_is_cancelled()) WaitError.Cancelled else WaitError.Timeout;
    }

    /// Reason the instance is read-only; null when writable. The `isRo()` guard
    /// wraps the header precondition ("can't be called on a writable instance"). Borrowed host string — copy to retain past the next box call.
    pub fn roReason() ?[]const u8 {
        if (!isRo()) return null;
        return std.mem.span(c.box_ro_reason());
    }

    /// The database schema version; bumps on any DDL.
    pub fn schemaVersion() u64 {
        return c.box_schema_version();
    }

    /// Self LSN component of the box vclock. The documented -1 sentinel
    /// (pre-bootstrap) maps to null.
    pub fn lsn() ?i64 {
        const v = c.box_info_lsn();
        return if (v == -1) null else v;
    }

    /// A memtx slab statistic (bytes).
    pub fn slab(what: Slab) u64 {
        return c.box_slab_info(what);
    }
};

// parseStatus's string table is pinned here, not in a `test {}` block: src-module
// tests are NOT collected by `zig build test`, but a comptime block is analyzed
// with the file on every build that touches box.zig.
comptime {
    if (info.parseStatus("running") != .running) @compileError("parseStatus running");
    if (info.parseStatus("loading") != .loading) @compileError("parseStatus loading");
    if (info.parseStatus("orphan") != .orphan) @compileError("parseStatus orphan");
    if (info.parseStatus("hot_standby") != .hot_standby) @compileError("parseStatus hot_standby");
    if (info.parseStatus("bogus") != null) @compileError("parseStatus bogus must be null");
}
