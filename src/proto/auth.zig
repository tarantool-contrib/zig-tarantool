//! chap-sha1 scramble over pure std.crypto.
//!
//! The client authenticates with CHAP-SHA1 (the only mechanism compiled into
//! Tarantool CE). Given the 20-byte salt from the greeting and the plaintext
//! password, the wire scramble is:
//!
//!   scramble = sha1(pass) XOR sha1(salt[0..20] ++ sha1(sha1(pass)))
//!
//! Pure and total: no allocation, no host ABI, and an empty password is a
//! valid input (sha1 of the empty string). Skipping AUTH entirely for the
//! `guest` user is the client's decision, not this layer's.

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

/// The mechanism string carried in the AUTH body's TUPLE (`["chap-sha1", …]`).
pub const auth_type = "chap-sha1";

/// Compute the 20-byte CHAP-SHA1 scramble for `password` against the 20-byte
/// greeting `salt`. Pure and total (empty password is valid).
///
///   scramble = sha1(pass) XOR sha1(salt ++ sha1(sha1(pass)))
pub fn scramble(password: []const u8, salt: *const [20]u8) [20]u8 {
    var s1: [20]u8 = undefined; // sha1(pass)
    Sha1.hash(password, &s1, .{});

    var s1s1: [20]u8 = undefined; // sha1(sha1(pass))
    Sha1.hash(&s1, &s1s1, .{});

    var hashed: [20]u8 = undefined; // sha1(salt ++ sha1(sha1(pass)))
    var h = Sha1.init(.{});
    h.update(salt);
    h.update(&s1s1);
    h.final(&hashed);

    var out: [20]u8 = undefined;
    for (&out, s1, hashed) |*o, a, b| o.* = a ^ b;
    return out;
}

const testing = std.testing;

// Fixtures cross-generated with the live Tarantool 3.8 digest machinery
// (require('digest').sha1 + bit.bxor) as the oracle.
// Live AUTH is covered by the client integration tests; here we pin the
// scramble chain only.
const salt_a: [20]u8 = .{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
    0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13,
};
const salt_b: [20]u8 = .{
    0x9f, 0x1c, 0x03, 0xd4, 0x77, 0xa8, 0x2b, 0xee, 0x50, 0x91,
    0x63, 0xba, 0x0d, 0xfc, 0x18, 0x42, 0xd9, 0x7e, 0x35, 0xc6,
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "scramble: password=secret, salt=0x00..0x13 (live-digest oracle)" {
    const got = scramble("secret", &salt_a);
    try testing.expectEqualSlices(u8, &hex("21b3ff405f32cbe4aafff291396046ea29fa3a4d"), &got);
}

test "scramble: password=secret, salt=random-looking (live-digest oracle)" {
    const got = scramble("secret", &salt_b);
    try testing.expectEqualSlices(u8, &hex("e1cd95758c273b160c8fdccfd31e63b7f5a02b78"), &got);
}

test "scramble: empty password is total (live-digest oracle)" {
    const got = scramble("", &salt_a);
    try testing.expectEqualSlices(u8, &hex("767be93ed197083818f15db91fd7d52407ad353e"), &got);
}

test "scramble: result differs from sha1(password) (XOR is non-degenerate)" {
    var s1: [20]u8 = undefined;
    Sha1.hash("secret", &s1, .{});
    const got = scramble("secret", &salt_a);
    try testing.expect(!std.mem.eql(u8, &s1, &got));
}

test "auth_type is the chap-sha1 mechanism string" {
    try testing.expectEqualStrings("chap-sha1", auth_type);
}
