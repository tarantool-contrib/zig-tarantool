//! Example Tarantool C module: a tiny bank over an `accounts` space
//! (`{id: string, balance: integer}`), demonstrating the **transaction** helper
//! `txn.transaction` — atomic commit on success, automatic rollback on any
//! returned error.
//!
//! `bank_transfer` debits one account and credits another inside a single
//! transaction. If the destination does not exist, the credit fails AFTER the
//! debit, the helper's `errdefer` rolls the whole transaction back, and the
//! source balance is left untouched — the integration driver asserts exactly
//! this (rollback leaves no partial write).
//!
//! Build into `bank.so`; see test/integration/bank.lua.

const std = @import("std");
const t = @import("tarantool");
const box = t.box;
const txn = t.txn;
const update = t.update;
const proc = t.proc;

const Error = error{
    /// An account named in the transfer does not exist.
    NoAccount,
    /// A row's balance field was missing or not an integer.
    BadRow,
    /// The source account cannot cover the transfer amount.
    InsufficientFunds,
};

/// Read an account's integer balance (field 1). The row is borrowed host memory;
/// the caller keeps it alive across this read.
fn balanceOf(row: box.Tuple) !i64 {
    const v = (try row.field(1, std.heap.c_allocator)) orelse return Error.BadRow;
    return switch (v) {
        .uint => |u| @intCast(u),
        .int => |i| i,
        else => Error.BadRow,
    };
}

/// The transactional body: debit `from`, credit `to`, both or neither. The
/// `from`/`to` slices are forwarded by `txn.transaction` via `@call`, which runs
/// this synchronously inside the same proc call, so they stay valid throughout.
fn doTransfer(from: []const u8, to: []const u8, amount: i64) !void {
    const accounts = try box.Space.byName("accounts");

    const from_row = (try accounts.get(.{from})) orelse return Error.NoAccount;
    const balance = blk: {
        defer from_row.deinit();
        break :blk try balanceOf(from_row);
    };
    if (balance < amount) return Error.InsufficientFunds; // pre-check: no write yet

    // Debit the source.
    if (try accounts.update(.{from}, .{update.sub(1, amount)})) |r| {
        r.deinit();
    } else return Error.NoAccount;

    // Credit the destination. If it does not exist, `update` returns null; we
    // turn that into an error AFTER the debit, so the helper rolls the debit back.
    if (try accounts.update(.{to}, .{update.add(1, amount)})) |r| {
        r.deinit();
    } else return Error.NoAccount;
}

/// bank_open(id, balance): create or overwrite an account.
fn bankOpen(id: []const u8, balance: i64) !void {
    const accounts = try box.Space.byName("accounts");
    if (try accounts.replace(.{ id, balance })) |row| row.deinit();
}

/// bank_balance(id) -> i64: the account's current balance (errors if absent).
fn bankBalance(id: []const u8) !i64 {
    const accounts = try box.Space.byName("accounts");
    const row = (try accounts.get(.{id})) orelse return Error.NoAccount;
    defer row.deinit();
    return balanceOf(row);
}

/// bank_transfer(from, to, amount): move `amount` from `from` to `to` atomically.
/// Rolls back (leaving balances untouched) on insufficient funds or a missing
/// account.
fn bankTransfer(from: []const u8, to: []const u8, amount: i64) !void {
    try txn.transaction(doTransfer, .{ from, to, amount });
}

comptime {
    proc.exportProc("bank_open", bankOpen);
    proc.exportProc("bank_balance", bankBalance);
    proc.exportProc("bank_transfer", bankTransfer);
}
