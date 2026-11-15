//! Box region — the host's per-fiber scratch arena, exposed as a Zig
//! `std.mem.Allocator` plus a `Savepoint` (this module is legitimately
//! Tarantool-bound and imports `c.zig`).
//!
//! The region is a bump arena owned by the current fiber: a yield does not
//! invalidate data on it, but neither is it reclaimed automatically. Use it for
//! short-lived scratch you hand straight to a synchronous `box_*` call. The
//! intended shape is:
//!
//!     var sp = region.Savepoint.save();
//!     defer sp.restore();
//!     const buf = try region.allocator().alloc(u8, n);
//!     // ... fill buf, pass it to a box_* call that copies it ...
//!
//! Nothing on the region may outlive the savepoint that bounds it, and a
//! savepoint is only restored once the host has copied the bytes — i.e. after
//! the synchronous box call returned, with no yield in between.
//!
//! The allocator's `free` is a no-op: reclamation happens solely through
//! `box_region_truncate` via `Savepoint.restore`. A null return from the
//! host surfaces as `error.OutOfMemory`, never a silent fallback.

const std = @import("std");
const c = @import("c.zig");

/// A `std.mem.Allocator` backed by the current fiber's box region.
///
/// The region is a per-fiber global, so the allocator carries no state: the
/// vtable's context pointer is unused. Allocations are never individually
/// freed — reclaim them in bulk with a `Savepoint`.
pub fn allocator() std.mem.Allocator {
    return .{
        // The region is per-fiber global state; the context is never read.
        .ptr = undefined,
        .vtable = &vtable,
    };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // box_region_aligned_alloc honors arbitrary power-of-two alignments;
    // Alignment.toByteUnits is always a power of two. A null return propagates
    // as error.OutOfMemory through the Allocator contract.
    const p = c.box_region_aligned_alloc(len, alignment.toByteUnits()) orelse return null;
    return @ptrCast(p);
}

fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // Bump arena: an in-place shrink is fine, growth is not.
    return new_len <= memory.len;
}

fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    // Force the caller's alloc+copy path; the arena cannot relocate in place.
    return null;
}

fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
    // No-op: the region only reclaims in bulk via box_region_truncate.
}

/// A marker of the region's used size, taken before some scratch allocations
/// and used to roll the region back to exactly that point.
///
/// Save before allocating, restore after the host has consumed the bytes.
/// Restore is idempotent in the sense that truncating to a mark
/// at or above the current used size is a no-op on the host side.
pub const Savepoint = struct {
    mark: usize,

    /// Record the region's current used size.
    pub fn save() Savepoint {
        return .{ .mark = c.box_region_used() };
    }

    /// Reclaim everything allocated on the region since `save`.
    pub fn restore(self: Savepoint) void {
        c.box_region_truncate(self.mark);
    }
};

/// How many bytes the current fiber's region has in use. Thin wrapper over
/// `box_region_used`.
pub fn used() usize {
    return c.box_region_used();
}

/// Truncate the current fiber's region back to `mark` bytes used. Thin wrapper
/// over `box_region_truncate`; prefer `Savepoint` for scoped reclamation.
pub fn truncate(mark: usize) void {
    c.box_region_truncate(mark);
}
