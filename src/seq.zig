//! Box sequences: a host-bound `Sequence` handle over Tarantool's
//! `box_sequence_*` C functions (this module is legitimately
//! Tarantool-bound and imports `c.zig`, plus `box.zig` for name resolution).
//!
//! A `Sequence` is an id-keyed value handle (a bare `u32`) that owns no host
//! resource: it has no `deinit`, and `byId` allocates nothing. Construct
//! one with `byId` when the sequence id is known, or `byName` to resolve a name
//! through the public box layer. Every host call maps a -1 return to
//! `Error.SeqOp` — including `current()` on a never-advanced sequence, which is
//! intentional fail-fast, not a sentinel.

const std = @import("std");
const c = @import("c.zig");
const box = @import("box.zig");

/// A host `box_sequence_*` call returned -1.
pub const Error = error{SeqOp};

/// An id-keyed handle to a host sequence. Owns no host resource.
pub const Sequence = struct {
    id: u32,

    /// Wrap a known sequence id. Allocation-free.
    pub fn byId(seq_id: u32) Sequence {
        return .{ .id = seq_id };
    }

    /// Resolve a sequence by name through the public box layer:
    /// the `_sequence` system space, `name` index, id in field 0 (unsigned).
    ///
    /// Returns `error.NoSuchSequence` if no sequence has that name, `error.SeqOp`
    /// if the id field is not an unsigned, and otherwise propagates the box read
    /// and msgpack decode errors unchanged (inferred error set — never swallowed). No silent fallback.
    pub fn byName(name: []const u8) !Sequence {
        const space = try box.Space.byName("_sequence");
        const idx = try space.index("name");
        var t = (try idx.get(.{name})) orelse return error.NoSuchSequence;
        defer t.deinit();
        const v = (try t.field(0, std.heap.c_allocator)) orelse return error.NoSuchSequence;
        const id: u32 = switch (v) {
            .uint => |u| @intCast(u),
            else => return error.SeqOp,
        };
        return .{ .id = id };
    }

    /// Advance the sequence and return its new value.
    pub fn next(self: Sequence) Error!i64 {
        var out: i64 = undefined;
        if (c.box_sequence_next(self.id, &out) != 0) return Error.SeqOp;
        return out;
    }

    /// Current value. A -1 host return (including a never-advanced sequence)
    /// surfaces as `Error.SeqOp` — fail-fast, no sentinel.
    pub fn current(self: Sequence) Error!i64 {
        var out: i64 = undefined;
        if (c.box_sequence_current(self.id, &out) != 0) return Error.SeqOp;
        return out;
    }

    /// Set the sequence to `value`.
    pub fn set(self: Sequence, value: i64) Error!void {
        if (c.box_sequence_set(self.id, value) != 0) return Error.SeqOp;
    }

    /// Reset the sequence to its start state.
    pub fn reset(self: Sequence) Error!void {
        if (c.box_sequence_reset(self.id) != 0) return Error.SeqOp;
    }
};
