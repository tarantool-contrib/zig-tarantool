# Spaces and indexes

This page reads and writes a space from stored procedures: by the tuple, through
a typed row, by index ranges and cursors. The module is `inventory`, over a
space of items.

## The space

```lua
local items = box.schema.space.create('items', {
    if_not_exists = true,
    format = {
        { name = 'sku', type = 'string' },
        { name = 'name', type = 'string' },
        { name = 'qty', type = 'unsigned' },
    },
})
items:create_index('pk', { parts = { 'sku' }, if_not_exists = true })
items:create_index('by_qty', { parts = { 'qty' }, unique = false, if_not_exists = true })
```

## The module

`src/inventory.zig`:

```zig
//! inventory: items {sku, name, qty}, a primary index on sku and a non-unique
//! index by_qty.

const std = @import("std");
const t = @import("tarantool");
const box = t.box;
const update = t.update;
const msgpack = t.msgpack;

/// A row of `items`, field by field in the order of the space format.
const Item = struct { sku: []const u8, name: []const u8, qty: u64 };
const Items = box.Typed(Item);

/// inventory.add(sku, name, qty): insert an item; a duplicate sku fails.
fn add(sku: []const u8, name: []const u8, qty: u64) !void {
    const items = try Items.byName("items");
    try items.insert(.{ .sku = sku, .name = name, .qty = qty });
}

/// inventory.restock(sku, n) -> the new qty.
fn restock(sku: []const u8, n: u64) !u64 {
    const items = try box.Space.byName("items");
    // Field numbers of Space.update count from 0: 2 is qty.
    const row = (try items.update(.{sku}, .{update.add(2, n)})) orelse return error.NoSuchItem;
    defer row.deinit();
    return (try row.get(2, u64, std.heap.c_allocator)).?;
}

/// inventory.take(sku, n) -> the qty left, or the error NotEnough.
fn take(sku: []const u8, n: u64) !u64 {
    const gpa = std.heap.c_allocator;
    const items = try Items.byName("items");
    var it = (try items.get(.{sku}, gpa)) orelse return error.NoSuchItem;
    defer Items.free(it, gpa);
    if (it.qty < n) return error.NotEnough;
    it.qty -= n;
    try items.put(it);
    return it.qty;
}

/// inventory.edit(sku, name, delta): rename, and add delta to qty if it is
/// not 0. The update operations are built at run time.
fn edit(sku: []const u8, name: []const u8, delta: i64) !void {
    var ops = update.Ops.init(std.heap.c_allocator);
    defer ops.deinit();
    try ops.push(update.set(1, name));
    if (delta > 0) try ops.push(update.add(2, delta));
    if (delta < 0) try ops.push(update.sub(2, -delta));
    const items = try box.Space.byName("items");
    try items.updateDiscard(.{sku}, &ops);
}

/// inventory.count_in(sku, name): one more of sku, created with qty 1 if absent.
fn countIn(sku: []const u8, name: []const u8) !void {
    const items = try box.Space.byName("items");
    try items.upsertDiscard(.{ sku, name, 1 }, .{update.add(2, 1)});
}

/// inventory.remove(sku) -> whether there was such an item.
fn remove(sku: []const u8) !bool {
    const items = try box.Space.byName("items");
    const old = (try items.delete(.{sku})) orelse return false;
    old.deinit();
    return true;
}

/// inventory.item(sku) -> the tuple, or nothing. A raw procedure, to return
/// the tuple itself.
fn item(ctx: ?*t.c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) !c_int {
    var dec = msgpack.Decoder.init(args[0 .. @intFromPtr(args_end) - @intFromPtr(args)]);
    const sku = (try msgpack.decode(struct { []const u8 }, &dec))[0];
    const items = try box.Space.byName("items");
    const row = (try items.get(.{sku})) orelse return 0;
    defer row.deinit();
    return t.proc.returnTuple(ctx, row);
}

/// inventory.below(limit) -> the skus with qty < limit, highest qty first.
fn below(limit: u64) ![]const []const u8 {
    const region = t.region.allocator();
    const by_qty = try (try box.Space.byName("items")).index("by_qty");
    var range = try by_qty.range(Item, .{ .iterator = .lt }, .{limit}, region);
    defer range.deinit();
    var skus: std.ArrayList([]const u8) = .empty;
    while (try range.next()) |row| try skus.append(region, row.sku);
    return skus.items;
}

const Stock = struct { []const u8, u64 };

/// inventory.top(n) -> {{sku, qty}, ...}: the n items with the most stock.
fn top(n: u32) ![]const Stock {
    const region = t.region.allocator();
    const by_qty = try (try box.Space.byName("items")).index("by_qty");
    const rows = try by_qty.top(n, Item, region);
    const out = try region.alloc(Stock, rows.len);
    for (rows, out) |row, *o| o.* = .{ row.sku, row.qty };
    return out;
}

/// inventory.total() -> the sum of qty over all items.
fn total() !u64 {
    const items = try box.Space.byName("items");
    var cursor = try items.primary().cursor(.{ .iterator = .all }, .{});
    defer cursor.deinit();
    var sum: u64 = 0;
    while (try cursor.next()) |row| sum += (try row.get(2, u64, std.heap.c_allocator)).?;
    return sum;
}

/// inventory.stats(limit) -> {items = , below = }: two counts.
fn stats(limit: u64) !struct { items: usize, below: usize } {
    const items = try box.Space.byName("items");
    const by_qty = try items.index("by_qty");
    return .{ .items = try items.primary().len(), .below = try by_qty.count(.lt, .{limit}) };
}

comptime {
    t.proc.exportProc("add", add);
    t.proc.exportProc("restock", restock);
    t.proc.exportProc("take", take);
    t.proc.exportProc("edit", edit);
    t.proc.exportProc("count_in", countIn);
    t.proc.exportProc("remove", remove);
    t.proc.exportRaw("item", item);
    t.proc.exportProc("below", below);
    t.proc.exportProc("top", top);
    t.proc.exportProc("total", total);
    t.proc.exportProc("stats", stats);
}
```

```lua
for _, name in ipairs({ 'add', 'restock', 'take', 'edit', 'count_in', 'remove',
                        'item', 'below', 'top', 'total', 'stats' }) do
    box.schema.func.create('inventory.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['inventory.' .. name]:call({ ... })
end

call('add', 'A-1', 'bolt', 10)
call('add', 'B-2', 'nut', 3)
call('restock', 'B-2', 5)       -- 8
call('take', 'A-1', 4)          -- 6
call('take', 'A-1', 100)        -- error: NotEnough
call('edit', 'A-1', 'hex bolt', -1)
call('count_in', 'C-3', 'washer')
call('item', 'A-1')             -- ['A-1', 'hex bolt', 5]
call('below', 6)                -- ['A-1', 'C-3']
call('top', 2)                  -- [['B-2', 8], ['A-1', 5]]
call('total')                   -- 14
call('stats', 6)                -- {items = 3, below = 2}
call('remove', 'C-3')           -- true
```

## Spaces

`box.Space.byName(name)` looks up the id of a space; `error.NoSuchSpace` if
there is none. A `Space` is the id and nothing else, cheap to copy and keep.

| Operation | Returns |
|-----------|---------|
| `insert(row)`, `replace(row)` | the stored tuple |
| `get(key)`, `delete(key)` | the tuple, or `null` |
| `update(key, ops)` | the updated tuple, or `null` if no tuple has the key |
| `upsert(row, ops)` | `null`: an upsert returns no tuple to a module |
| `insertDiscard`, `replaceDiscard`, `deleteDiscard`, `updateDiscard`, `upsertDiscard` | nothing: they release the tuple for you |
| `truncate()` | nothing |

A row and a key are tuple structs, `.{ sku, name, qty }` and `.{sku}`, or any
value that encodes as an array. Every returned tuple holds a reference that
`deinit` releases, see [Lifetimes](../concepts/lifetimes.md#tuples).

A failed operation, such as a duplicate key, returns `error.BoxOp`, and the
message is in `t.err.lastError()`.

## Update operations

`tarantool.update` builds the operations of `update` and `upsert`:

| Constructor | Operation |
|-------------|-----------|
| `set(field, value)` | `=`: assign |
| `add(field, n)`, `sub(field, n)` | `+`, `-` |
| `band`, `bor`, `bxor` | `&`, `\|`, `^` |
| `insert(field, value)` | `!`: insert a field before `field` |
| `delete(field, count)` | `#`: delete `count` fields |
| `splice(field, start, len, str)` | `:`: replace part of a string |

Pass them as a tuple, `.{ update.set(1, name), update.add(2, 1) }`, or build an
`update.Ops` at run time, as `edit` does, and pass a pointer to it.

**Field numbers count from 0** in `Space.update`, `Index.update` and
`upsert`: `update.add(2, n)` changes the third field, `qty`. They count from 1
in `Tuple.update`, which updates a tuple outside a space, as Lua's
`tuple:update` does.

## Reading a tuple

| Method | Gives |
|--------|-------|
| `row.get(i, T, alloc)` | field `i`, counting from 0, decoded as `T`; `null` past the end |
| `row.field(i, alloc)` | field `i` as a `msgpack.Value` |
| `row.decode(T, alloc)` | the whole tuple decoded as `T`, a tuple struct |
| `row.decodeRow(Row)` | the whole tuple decoded into the named struct `Row`, field by field |
| `row.fieldCount()`, `row.bsize()` | the number of fields, the size in bytes |
| `row.fieldIterator()` | a cursor over the fields |

A string field is a slice of the tuple; see
[Lifetimes](../concepts/lifetimes.md#tuples).

## Typed rows

`box.Typed(Row)` maps the named struct `Row` to the tuples of a space, field by
field in the order of declaration. The fields of `Row` may be integers, floats,
booleans, enums and `[]const u8`; anything else is a compile error.

| Method | Does |
|--------|------|
| `Typed(Row).byName(name)` | looks up the space |
| `put(row)` | replaces |
| `insert(row)` | inserts; a duplicate key fails with `error.BoxOp` |
| `get(key, alloc)` | the row, or `null`; its strings are copied into `alloc` |
| `del(key)` | deletes |
| `Typed(Row).free(row, alloc)` | frees the strings `get` copied |

`take` above reads, changes and writes a row. Between the `get` and the `put`
it does not yield, so no other fiber can change the item in between.

## Indexes

`space.primary()` is the primary index; `space.index(name)` looks one up by
name, and `space.indexById(id)` takes its id.

| Method | Returns |
|--------|---------|
| `get(key)` | the tuple, or `null` |
| `min(key)`, `max(key)` | the first or last tuple with the key; `.{}` for the whole index |
| `count(iterator, key)` | the number of tuples the iterator visits |
| `len()`, `bsize()` | the number of tuples, the size of the index in bytes |
| `random(seed)` | a random tuple |
| `select(options, key, alloc)` | a slice of tuples; release each and free the slice |
| `iterator(iterator, key)` | an `Iterator`, whose `next` returns tuples you release |
| `cursor(options, key)` | a `Cursor`, whose `next` returns tuples it releases |
| `range(Row, options, key, alloc)` | a `Range(Row)`, whose `next` returns decoded rows with their strings copied |
| `top(n, Row, alloc)` | the `n` last rows in the order of the index, as a slice |
| `update(key, ops)` | updates through this index |
| `extractKey(tuple, alloc)` | the key of a tuple in this index, as MessagePack |

The options are a `query.SelectOptions`:

```zig
.{ .iterator = .ge, .offset = 0, .limit = 10 }
```

and the iterators are those of Tarantool: `.eq`, `.req`, `.all`, `.lt`, `.le`,
`.ge`, `.gt`, and the bitset and spatial ones. As in Lua, `.lt` and `.le` walk
the index in descending order: `below` gets the highest quantities first.

`top(n, Row, alloc)` is the descending walk of the whole index, `.le` with an
empty key, cut at `n` rows; free it with `Range(Row).freeSlice`. `below` and
`top` allocate on the fiber region, which needs no free.

## Sequences

`tarantool.seq.Sequence` advances a sequence of Tarantool:

```zig
const ids = try t.seq.Sequence.byName("event_ids");
const id = try ids.next();
try events.insertDiscard(.{ id, name });
```

`next`, `current`, `set(value)` and `reset()` are those of
`box.sequence.<name>`. `current` fails with `error.SeqOp` on a sequence that
never advanced.

## Key definitions

`tarantool.keydef.KeyDef` compares tuples by a key that no index has:

```zig
const parts = [_]t.keydef.KeyPartDef{
    .{ .fieldno = 2, .type = .unsigned },
    .{ .fieldno = 0, .type = .string },
};
const by_qty_sku = try t.keydef.KeyDef.init(&parts, std.heap.c_allocator);
defer by_qty_sku.deinit();
const order = by_qty_sku.compare(a, b); // std.math.Order
```

`compareWithKey(tuple, key, alloc)` compares a tuple with a key, and
`extractKey(tuple, alloc)` cuts the key out of a tuple.
