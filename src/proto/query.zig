//! Backend-independent query types: iterator kinds and select options.
//!
//! Carries no Tarantool C dependency so the future connector reuses the
//! same iterator semantics. `IteratorType` integer values mirror Tarantool's
//! `enum iterator_type` exactly; the match is asserted at compile time in
//! `c_verify.zig`, the only site that includes `module.h`.

/// Index search/iteration mode. Values match `enum iterator_type`.
pub const IteratorType = enum(c_int) {
    /// key == x, ascending
    eq = 0,
    /// key == x, descending
    req = 1,
    /// all tuples
    all = 2,
    /// key < x
    lt = 3,
    /// key <= x
    le = 4,
    /// key >= x
    ge = 5,
    /// key > x
    gt = 6,
    /// all bits from x are set in key (BITSET indexes)
    bits_all_set = 7,
    /// at least one of x's bits is set
    bits_any_set = 8,
    /// all of x's bits are not set
    bits_all_not_set = 9,
    /// key overlaps x (RTREE)
    overlaps = 10,
    /// tuples in order of distance from x (RTREE)
    neighbor = 11,
    /// next prefix, ascending
    np = 12,
    /// previous prefix, descending
    pp = 13,
};

/// Options for a range `select`: which iterator, how many to skip, and a cap.
pub const SelectOptions = struct {
    iterator: IteratorType = .eq,
    offset: u32 = 0,
    /// Maximum tuples to return; `null` means unbounded.
    limit: ?u32 = null,
};
