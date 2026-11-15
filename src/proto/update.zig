//! Backend-independent update-op constructors and a runtime ops builder.
//!
//! Carries no Tarantool C dependency so the future connector reuses the
//! same update encoding, like `query.zig` and `msgpack.zig`. The operator
//! strings are single-sourced in `Operator` (SSOT) and match Tarantool's
//! update operators exactly. Constructors enforce per-operator arity at
//! comptime via their return type: a malformed op fails to compile.

const std = @import("std");
const msgpack = @import("msgpack");

/// Tarantool update operators. `str()` is the on-wire operator char; these are
/// the single source of truth for the operator strings.
pub const Operator = enum {
    set,
    insert,
    add,
    sub,
    band,
    bor,
    bxor,
    delete,
    splice,

    /// The operator char Tarantool expects as the first element of an op array.
    pub fn str(self: Operator) []const u8 {
        return switch (self) {
            .set => "=",
            .insert => "!",
            .add => "+",
            .sub => "-",
            .band => "&",
            .bor => "|",
            .bxor => "^",
            .delete => "#",
            .splice => ":",
        };
    }
};

// ---- op constructors -------------------------------------------------------
// Each returns an anonymous op tuple `.{ op, field, … }`; the return type fixes
// the arity. `field` is the (0-based) field number.

/// `= field value` — assign.
pub fn set(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.set.str(), field, value };
}

/// `! field value` — insert before `field`.
pub fn insert(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.insert.str(), field, value };
}

/// `+ field value` — add.
pub fn add(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.add.str(), field, value };
}

/// `- field value` — subtract.
pub fn sub(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.sub.str(), field, value };
}

/// `& field value` — bitwise AND.
pub fn band(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.band.str(), field, value };
}

/// `| field value` — bitwise OR.
pub fn bor(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.bor.str(), field, value };
}

/// `^ field value` — bitwise XOR.
pub fn bxor(field: i64, value: anytype) struct { []const u8, i64, @TypeOf(value) } {
    return .{ Operator.bxor.str(), field, value };
}

/// `# field count` — delete `count` fields starting at `field`.
pub fn delete(field: i64, count: u32) struct { []const u8, i64, u32 } {
    return .{ Operator.delete.str(), field, count };
}

/// `: field start len replacement` — splice the string at `field`.
pub fn splice(field: i64, start: i64, len: u32, replacement: []const u8) struct { []const u8, i64, i64, u32, []const u8 } {
    return .{ Operator.splice.str(), field, start, len, replacement };
}

// ---- runtime ops builder ---------------------------------------------------

/// A runtime-built list of update ops. Each `push`ed op is encoded immediately
/// into `bodies`; `toBuffer` frames them with an array header. This is the
/// dynamic counterpart to the comptime tuple-of-constructors form; both encode
/// through `encodeOps`.
pub const Ops = struct {
    bodies: msgpack.Buffer,
    count: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Ops {
        return .{ .bodies = msgpack.Buffer.init(gpa) };
    }

    pub fn deinit(self: *Ops) void {
        self.bodies.deinit();
    }

    /// Append one op (a constructor's result, e.g. `update.set(1, "x")`).
    pub fn push(self: *Ops, op: anytype) !void {
        try msgpack.encode(&self.bodies, op);
        self.count += 1;
    }

    /// Encode the accumulated ops as a MessagePack array-of-arrays. Caller frees.
    pub fn toBuffer(self: *const Ops, gpa: std.mem.Allocator) !msgpack.Buffer {
        var out = msgpack.Buffer.init(gpa);
        errdefer out.deinit();
        try msgpack.encodeArrayHeader(&out, self.count);
        try out.writeAll(self.bodies.items());
        return out;
    }
};

/// The single ops→MessagePack path (IF1). Accepts either an `Ops` builder
/// (any pointer flavor) — encoded via `toBuffer` — or a comptime
/// tuple-of-constructors, encoded as an array. Caller frees the buffer.
pub fn encodeOps(gpa: std.mem.Allocator, ops: anytype) !msgpack.Buffer {
    const T = @TypeOf(ops);
    if (T == Ops or T == *Ops or T == *const Ops) {
        return ops.toBuffer(gpa);
    }
    var out = msgpack.Buffer.init(gpa);
    errdefer out.deinit();
    try msgpack.encode(&out, ops);
    return out;
}
