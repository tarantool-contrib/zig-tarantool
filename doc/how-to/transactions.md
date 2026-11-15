# Transactions

This page makes several writes of a stored procedure atomic: a transaction that
commits when the code succeeds and rolls back when it fails, savepoints inside
it, its options, and code that runs at the commit. The module is `ledger`, over
a space of accounts.

## The module

```lua
local accounts = box.schema.space.create('accounts', {
    if_not_exists = true,
    format = { { name = 'id', type = 'string' }, { name = 'balance', type = 'integer' } },
})
accounts:create_index('pk', { parts = { 'id' }, if_not_exists = true })
```

`src/ledger.zig`:

```zig
//! ledger: transfers between accounts {id, balance}, all or nothing.

const std = @import("std");
const t = @import("tarantool");
const box = t.box;
const txn = t.txn;
const update = t.update;

/// Add `amount` to the balance of `id`; fail if it goes below zero.
fn credit(id: []const u8, amount: i64) !void {
    const accounts = try box.Space.byName("accounts");
    const row = (try accounts.update(.{id}, .{update.add(1, amount)})) orelse return error.NoAccount;
    defer row.deinit();
    if ((try row.get(1, i64, std.heap.c_allocator)).? < 0) return error.Overdraft;
}

fn move(from: []const u8, to: []const u8, amount: i64) !void {
    try credit(from, -amount);
    try credit(to, amount);
}

/// Commits so far. Static: the trigger runs after the procedure returned.
var commits: u64 = 0;

fn countCommit(counter: *u64) void {
    counter.* += 1;
}

fn transferTx(from: []const u8, to: []const u8, amount: i64) !void {
    try t.trigger.onCommit(&commits, countCommit);
    try move(from, to, amount);
}

/// ledger.transfer(from, to, amount): both writes, or none.
fn transfer(from: []const u8, to: []const u8, amount: i64) !void {
    try txn.transaction(transferTx, .{ from, to, amount });
}

fn splitTx(from: []const u8, a: []const u8, b: []const u8, amount: i64) !u32 {
    try t.trigger.onCommit(&commits, countCommit);
    var paid: u32 = 0;
    for ([_][]const u8{ a, b }) |to| {
        const svp = try txn.Savepoint.save();
        move(from, to, amount) catch |e| switch (e) {
            error.NoAccount, error.Overdraft => {
                try svp.rollback(); // undo this payment only
                continue;
            },
            else => return e,
        };
        paid += 1;
    }
    return paid;
}

/// ledger.split(from, a, b, amount) -> how many of the two payments were made.
fn split(from: []const u8, a: []const u8, b: []const u8, amount: i64) !u32 {
    return txn.transaction(splitTx, .{ from, a, b, amount });
}

/// ledger.transfer_within(from, to, amount, seconds): a transfer that rolls
/// back if it takes longer than `seconds`.
fn transferWithin(from: []const u8, to: []const u8, amount: i64, seconds: f64) !void {
    try txn.transactionWith(.{ .timeout = seconds }, move, .{ from, to, amount });
}

/// ledger.commits() -> the number of transactions of this module committed.
fn getCommits() u64 {
    return commits;
}

comptime {
    t.proc.exportProc("transfer", transfer);
    t.proc.exportProc("split", split);
    t.proc.exportProc("transfer_within", transferWithin);
    t.proc.exportProc("commits", getCommits);
}
```

```lua
for _, name in ipairs({ 'transfer', 'split', 'transfer_within', 'commits' }) do
    box.schema.func.create('ledger.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['ledger.' .. name]:call({ ... })
end
accounts:replace({ 'alice', 100 })
accounts:replace({ 'bob', 0 })

call('transfer', 'alice', 'bob', 30)
accounts:get('alice')[2]                 -- 70
call('transfer', 'alice', 'nobody', 10)  -- error: NoAccount
accounts:get('alice')[2]                 -- 70: the debit was rolled back
call('split', 'alice', 'bob', 'nobody', 20) -- 1
accounts:get('alice')[2]                 -- 50
call('transfer_within', 'alice', 'bob', 5, 1.5)
call('commits')                          -- 2
```

## Run code in a transaction

`txn.transaction(f, args)` begins a transaction, calls `f` with the tuple
`args`, and:

- commits, and returns what `f` returned, when `f` succeeds;
- rolls back, and returns the error, when `f` returns one.

`f` may return a value, `void`, or an error union of either. The second
`transfer` above fails at the credit of `nobody`, after the debit of `alice`;
the rollback undoes the debit.

A transaction is bound to the fiber. Calling `transaction` while one is active
fails, as `box.begin()` does: `txn.active()` tells whether there is one, and
`txn.id()` gives its id.

## Savepoints

`txn.Savepoint.save()` marks a point in the active transaction;
`svp.rollback()` undoes what the transaction did after it, and the transaction
goes on. `split` uses one per payment, so a failed payment does not undo the
one before it.

`rollback` fails with `error.StaleSavepoint` when the transaction it was saved
in has ended. The savepoints of a transaction need no free: Tarantool frees them
with the transaction.

## Options

`txn.transactionWith(options, f, args)` applies options before `f` runs:

| Option | Does |
|--------|------|
| `.isolation` | the isolation level: `.read_committed`, `.read_confirmed`, `.best_effort`, `.linearizable`; `.default` keeps the one of `box.cfg` |
| `.timeout` | seconds after which Tarantool rolls the transaction back |
| `.sync` | makes the commit wait for the quorum of synchronous replication |

They are the options of `box.begin()`. The isolation levels take effect with
the MVCC engine, see below. Outside `transactionWith`, `txn.setIsolation`,
`txn.setTimeout` and `txn.makeSync` set them on the active transaction; the
isolation only before its first write.

## Yields in a transaction

memtx without MVCC aborts a transaction that yields: the next write, or the
commit, fails with `Transaction has been aborted by a fiber yield`. A
transaction of a module must not sleep, wait on a channel or do network I/O,
unless the instance runs with

```lua
box.cfg{ memtx_use_mvcc_engine = true }
```

which allows yields and makes the isolation levels work.
[Fibers and yields](../concepts/fibers.md#what-yields) lists what yields.

## Code at commit and rollback

`trigger.onCommit(context, f)` runs `f(context)` once, after the active
transaction commits; `trigger.onRollback(context, f)` once, if it rolls back.
Outside a transaction they fail with `error.NoTxn`.

- `f` returns nothing and cannot fail: the commit has happened.
- `f` must not yield.
- `context` is a pointer, and it must stay valid until the transaction ends,
  which may be after the procedure returned. A variable on the stack of the
  procedure is not: use a global, as `commits` above, or memory you free in `f`.

The failed `transfer` above registered its trigger, then rolled back, so the
trigger did not run: `commits` counts the first `transfer` and the `split`. The
`transfer_within` call does not register one.

## Memory of a transaction

`txn.alloc(T)` and `txn.allocSlice(T, n)` allocate on the memory of the active
transaction, which Tarantool frees when the transaction ends. There is no free.
