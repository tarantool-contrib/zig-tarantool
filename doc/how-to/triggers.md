# Triggers

A module can run code when something happens in Tarantool: a write to a space,
the commit or the rollback of a transaction, the shutdown of the server.
`tarantool.trigger` registers Zig functions for these. This page writes a module
that audits a space and rejects some writes.

## The module

`src/audit.zig`:

```zig
//! audit: count the writes to a space, and reject a negative quantity.

const std = @import("std");
const t = @import("tarantool");
const trigger = t.trigger;

const Audit = struct {
    inserts: u64 = 0,
    replaces: u64 = 0,
    updates: u64 = 0,
    deletes: u64 = 0,
    handle: ?trigger.SpaceTrigger = null,
};

/// Global: a trigger outlives the call that registers it.
var audit: Audit = .{};

fn onReplace(a: *Audit, event: trigger.ReplaceEvent) !void {
    if (event.new) |row| {
        const qty = (try row.get(1, i64, std.heap.c_allocator)) orelse 0;
        if (qty < 0) return error.NegativeQty; // rejects the write
    }
    switch (event.op) {
        .insert => a.inserts += 1,
        .replace => a.replaces += 1,
        .update => a.updates += 1,
        .delete => a.deletes += 1,
        .upsert => {},
    }
}

fn onShutdown(a: *Audit) void {
    t.say.info("audit: {d} inserts, {d} deletes", .{ a.inserts, a.deletes });
}

/// audit.enable(space): start auditing a space.
fn enable(space: []const u8) !void {
    if (audit.handle != null) return error.AlreadyEnabled;
    const s = try t.box.Space.byName(space);
    audit.handle = try trigger.onReplace(s.id, &audit, onReplace);
    try trigger.onShutdown(&audit, onShutdown);
}

/// audit.disable(): stop.
fn disable() !void {
    const handle = audit.handle orelse return error.NotEnabled;
    audit.handle = null;
    try handle.remove();
    try trigger.removeShutdown(&audit, onShutdown);
}

/// audit.counts() -> {inserts = , replaces = , updates = , deletes = }
fn counts() struct { inserts: u64, replaces: u64, updates: u64, deletes: u64 } {
    return .{ .inserts = audit.inserts, .replaces = audit.replaces, .updates = audit.updates, .deletes = audit.deletes };
}

comptime {
    t.proc.exportProc("enable", enable);
    t.proc.exportProc("disable", disable);
    t.proc.exportProc("counts", counts);
}
```

```lua
local stock = box.schema.space.create('stock', { if_not_exists = true })
stock:create_index('pk', { if_not_exists = true })
for _, name in ipairs({ 'enable', 'disable', 'counts' }) do
    box.schema.func.create('audit.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['audit.' .. name]:call({ ... })
end

call('enable', 'stock')
stock:insert({ 1, 5 })
stock:replace({ 1, 7 })
stock:update(1, { { '-', 2, 10 } })    -- error: NegativeQty
stock:get(1)[2]                        -- 7
stock:delete(1)
call('counts')                         -- {inserts = 1, replaces = 1, updates = 0, deletes = 1}
call('disable')
stock:insert({ 2, -1 })                -- [2, -1]
```

## Writes to a space

`trigger.onReplace(space_id, context, f)` registers `f` as an `on_replace`
trigger of the space, as `space:on_replace(f)` does in Lua. It runs for every
insert, replace, update, delete and upsert, before the write is final, until
`remove()` on the `SpaceTrigger` it returns.

`f(context, event)` gets a `trigger.ReplaceEvent`:

| Field | Is |
|-------|----|
| `old` | the tuple before the write, or `null` for an insert |
| `new` | the tuple after it, or `null` for a delete |
| `space` | the name of the space, valid during `f` |
| `op` | `.insert`, `.replace`, `.update`, `.delete` or `.upsert` |

The tuples are valid during `f`; copy what you keep.

An error returned by `f` rejects the statement: the write that fired the
trigger fails with the error, as `NegativeQty` above. Within an explicit
transaction only that statement is undone; the transaction goes on.
`error.BoxOp` fails it with the message of Tarantool.

`context` is a pointer that must stay valid until `remove()`: a global, or memory
you free after `remove()`, never a variable on the stack of the procedure that
registers the trigger.

The trigger lives in the memory of the instance, not in the schema: it is gone
after a restart. A module that needs it registers it again at startup, from a
procedure called in the init script.

## Commit and rollback

`trigger.onCommit(context, f)` and `trigger.onRollback(context, f)` run
`f(context)` once, when the active transaction commits or rolls back.
[Transactions](transactions.md#code-at-commit-and-rollback) shows them.

## Shutdown

`trigger.onShutdown(context, f)` runs `f(context)` when the server shuts down
gracefully, as `box.ctl.on_shutdown` does. `trigger.removeShutdown(context, f)`
with the same pair removes it. `audit` logs its counts at shutdown:

```text
I> audit: 1 inserts, 1 deletes
```

## The Lua state

The triggers of a space and of a transaction have no C API in Tarantool: the
SDK registers them through Lua, on the Lua state of the instance. A module
cannot register them from a worker thread of `coio.call`, which has no Lua.
