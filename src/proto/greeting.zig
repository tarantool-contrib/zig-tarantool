//! 128-byte Tarantool greeting parse (version / instance uuid / salt).
//!
//! On connect the server sends exactly 128 bytes: two 64-byte,
//! `\n`-terminated lines (wire facts live-probed on 3.8.0).
//!
//!   line 1: "Tarantool <version> (Binary) <instance-uuid>", right-padded
//!           with spaces, `\n` at byte 63. We require the "Tarantool "
//!           prefix and the "(Binary)" marker (a Console/Lua greeting is
//!           rejected — this layer only speaks the binary protocol).
//!   line 2: base64 salt, right-padded with spaces, `\n` at byte 127. It
//!           decodes to >= 32 bytes; only the first 20 feed the chap-sha1
//!           scramble (see auth.zig), so that is all we retain.
//!
//! Allocation-free: `parse` takes `*const [128]u8` and the returned
//! `version`/`uuid` slices point INTO the caller's buffer — they live exactly
//! as long as that buffer. `salt` is copied out into an owned fixed array.
//!
//! A short read cannot reach `parse`: the `*const [128]u8` signature makes
//! "fewer than 128 bytes" unrepresentable at the type level. The caller is
//! responsible for reading a full 128-byte frame before calling.

const std = @import("std");

/// Greeting parse failures (house module-named error family).
pub const Error = error{
    /// Line 1 lacks the "Tarantool " prefix or the "(Binary)" marker — not a
    /// binary-protocol greeting (e.g. a Console/Lua banner, or garbage).
    NotBinary,
    /// Structural violation: a 64-byte line is not `\n`-terminated where the
    /// wire format requires it.
    BadGreeting,
    /// Line 2 is not valid base64, or decodes to fewer than 32 bytes (too
    /// short to yield the 20-byte scramble salt).
    BadSalt,
};

/// Parsed greeting. `version` and `uuid` are slices into the caller's 128-byte
/// buffer (see module doc for lifetime); `salt` is the first 20 bytes of the
/// decoded line-2 salt, copied out.
pub const Greeting = struct {
    /// Server version token, e.g. "3.8.0" (between "Tarantool " and " (Binary)").
    version: []const u8,
    /// Instance uuid text, e.g. "34bdde95-9d4c-4101-9183-dbe18f2caa54"
    /// (everything after "(Binary)", trimmed).
    uuid: []const u8,
    /// First 20 bytes of the decoded salt — the chap-sha1 scramble input.
    salt: [20]u8,
};

/// Parse a full 128-byte greeting. See module doc for the wire layout.
pub fn parse(bytes: *const [128]u8) Error!Greeting {
    const line1 = bytes[0..64];
    const line2 = bytes[64..128];

    // Line 1 must announce the binary protocol.
    if (!std.mem.startsWith(u8, line1, "Tarantool "))
        return Error.NotBinary;
    // Both 64-byte lines are `\n`-terminated on the wire.
    if (line1[63] != '\n' or line2[63] != '\n')
        return Error.BadGreeting;

    const banner = std.mem.trimEnd(u8, line1, " \n");
    const marker = "(Binary)";
    const bin = std.mem.indexOf(u8, banner, marker) orelse return Error.NotBinary;

    const version = std.mem.trim(u8, banner["Tarantool ".len..bin], " ");
    const uuid = std.mem.trim(u8, banner[bin + marker.len ..], " ");

    // Line 2: base64 salt, space-padded. Decodes to >= 32 bytes; keep the
    // first 20 (the chap-sha1 scramble input). A full 64-byte line yields at
    // most 47 decoded bytes, so a fixed 48-byte scratch buffer always fits.
    const b64 = std.mem.trimEnd(u8, line2, " \n");
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return Error.BadSalt;
    if (n < 32) return Error.BadSalt;
    var scratch: [48]u8 = undefined;
    if (n > scratch.len) return Error.BadSalt;
    dec.decode(scratch[0..n], b64) catch return Error.BadSalt;

    var salt: [20]u8 = undefined;
    @memcpy(&salt, scratch[0..20]);

    return .{ .version = version, .uuid = uuid, .salt = salt };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// A real 128-byte greeting captured live this session from Tarantool 3.8.0
// (`box.cfg{listen=...}` + a raw 128-byte socket read), embedded as hex so the
// fixture is byte-faithful to the wire (trailing space padding and the two
// `\n` terminators included). First line decodes to:
//   "Tarantool 3.8.0 (Binary) 34bdde95-9d4c-4101-9183-dbe18f2caa54  \n"
const live_greeting_hex = "546172616e746f6f6c20332e382e30202842696e617279292033346264646539352d396434632d343130312d393138332d64626531386632636161353420200a5a49776578665735613874656d774459785a7965534d4e4f6a3641302b4734337661715769675a5a4a42413d202020202020202020202020202020202020200a";

// Base64 body of line 2 of the fixture above (no padding spaces), used as an
// INDEPENDENT oracle for the salt: decoded here in the test, first 20 bytes
// compared against what `parse` extracts.
const live_salt_b64 = "ZIwexfW5a8temwDYxZyeSMNOj6A0+G43vaqWigZZJBA=";

fn liveGreeting() [128]u8 {
    var buf: [128]u8 = undefined;
    const out = std.fmt.hexToBytes(&buf, live_greeting_hex) catch unreachable;
    std.debug.assert(out.len == 128);
    return buf;
}

test "parse: live 3.8.0 greeting -> version, uuid, salt" {
    const g = liveGreeting();
    const parsed = try parse(&g);

    try std.testing.expectEqualStrings("3.8.0", parsed.version);
    try std.testing.expectEqualStrings(
        "34bdde95-9d4c-4101-9183-dbe18f2caa54",
        parsed.uuid,
    );

    // Independent salt oracle: decode the known line-2 base64 here, take the
    // first 20 bytes, and compare against parse's extraction.
    var full: [64]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(live_salt_b64);
    try std.testing.expectEqual(@as(usize, 32), n);
    try dec.decode(full[0..n], live_salt_b64);
    try std.testing.expectEqualSlices(u8, full[0..20], &parsed.salt);
}

test "parse: rejects a non-Binary line 1 (NotBinary)" {
    var g = liveGreeting();
    // Doctor the real banner: "(Binary)" -> "(binary)" (same length), so the
    // marker match fails while the "Tarantool " prefix still holds.
    const idx = std.mem.indexOf(u8, &g, "(Binary)").?;
    g[idx + 1] = 'b';
    try std.testing.expectError(Error.NotBinary, parse(&g));
}

test "parse: rejects corrupted base64 in line 2 (BadSalt)" {
    var g = liveGreeting();
    // '@' is outside the standard base64 alphabet -> decode fails.
    g[64] = '@';
    try std.testing.expectError(Error.BadSalt, parse(&g));
}

test "parse: rejects a missing line terminator (BadGreeting)" {
    var g = liveGreeting();
    g[63] = ' '; // clobber line 1's '\n'
    try std.testing.expectError(Error.BadGreeting, parse(&g));
}

test "parse: rejects all-zero garbage (NotBinary)" {
    const g: [128]u8 = @splat(0);
    try std.testing.expectError(Error.NotBinary, parse(&g));
}
