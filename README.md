# zig-tarantool

[![CI](https://github.com/tarantool-contrib/zig-tarantool/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/tarantool-contrib/zig-tarantool/actions/workflows/ci.yml)
[![Documentation](https://github.com/tarantool-contrib/zig-tarantool/actions/workflows/docs.yml/badge.svg?branch=master)](https://github.com/tarantool-contrib/zig-tarantool/actions/workflows/docs.yml)
[![Docs](https://img.shields.io/badge/docs-guides-2a7ae2)](https://tarantool-contrib.github.io/zig-tarantool/)
[![Docs (ru)](https://img.shields.io/badge/docs-%D0%BF%D0%BE--%D1%80%D1%83%D1%81%D1%81%D0%BA%D0%B8-2a7ae2)](https://tarantool-contrib.github.io/zig-tarantool/ru/)
[![API reference](https://img.shields.io/badge/API-reference-2a7ae2)](https://tarantool-contrib.github.io/zig-tarantool/api/)
[![Zig](https://img.shields.io/badge/Zig-0.17.1-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![Tarantool](https://img.shields.io/badge/Tarantool-3.5%2B-e2132c)](https://www.tarantool.io/en/download/)
[![Platforms](https://img.shields.io/badge/platforms-linux%20x86__64%20%7C%20linux%20arm64%20%7C%20macOS-lightgrey)](doc/get-started/install.md#requirements)

Write Tarantool stored procedures and modules in **Zig** — the in-process ("box
side") equivalent of the Rust [`tarantool`](https://docs.rs/crate/tarantool)
crate — and talk to Tarantool over the network from Zig programs.

- **SDK (`tarantool`).** Your Zig code compiles to a shared library (`.so`,
  `.dylib` on macOS) that Tarantool loads like any C module. You get a typed,
  comptime-driven API and a MessagePack codec instead of hand-rolled `box_*`
  calls, and you can author `require()`-able Lua modules from plain Zig
  functions.
- **Client (`tarantool-client`).** An iproto connector: auth, typed call/eval,
  full DML, pipelined batches, a drift-aware schema cache, watchers and
  interactive transactions. It is IO-agnostic: run it standalone over
  `std.Io.Threaded`, or inside a stored procedure over the SDK's
  fiber-yielding `std.Io` (net.box in Zig).

**Documentation:** [the guides](https://tarantool-contrib.github.io/zig-tarantool/) ([по-русски](https://tarantool-contrib.github.io/zig-tarantool/ru/)) — getting
started, concepts, how-to guides for every part of the SDK and the client — and
the [API reference](https://tarantool-contrib.github.io/zig-tarantool/api/), generated from the doc comments. The sources
are in [`doc/`](doc/index.md); `python3 ci/docs.py serve` builds and serves the site
locally (see [Testing](doc/project/testing.md#the-documentation)).

## Requirements

- **Zig 0.17.1** (pinned; see `.zig-version` / `build.zig.zon`).
- **Tarantool ≥ 3.5** to load SDK modules. Modules build against a hand-written
  ABI and resolve `box_*` symbols from the host when it loads them. Older 3.x
  hosts lack some of those symbols (`box_tuple_data`, `box_status`, …), so
  modules fail to load there.
- The network client only speaks the protocol and works with **Tarantool ≥ 3.0**
  servers.
- **Platforms:** Linux x86_64 and arm64, macOS (Apple silicon, Intel). CI runs
  the whole suite on Linux x86_64 against Tarantool 3.5–3.9, on Linux arm64
  against 3.5 and 3.9, and on macOS against the Homebrew Tarantool; macOS Intel
  is cross-built.

## Quick start

A module with one typed stored procedure:

```zig
// src/hello.zig
const t = @import("tarantool");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

comptime {
    t.proc.exportProc("add", add);
}
```

Build it with the helpers this package exports (see
[Use in your project](#use-in-your-project)), then call it from Tarantool:

```lua
package.cpath = '/path/to/zig-out/lib/?.' .. require('tarantool').build.mod_format
    .. ';' .. package.cpath

box.schema.func.create('hello.add', { language = 'C' })
box.func['hello.add']:call({ 1, 2 }) --> 3
```

A standalone program that talks to Tarantool over the network:

```zig
// src/client.zig
const std = @import("std");
const client = @import("tarantool-client");

pub fn main(init: std.process.Init) !void {
    var conn = try client.Connection.connect(init.gpa, init.io, .{
        .address = "127.0.0.1:3301",
    });
    defer conn.close();

    try conn.ping();
    const two = try conn.eval("return 1 + 1", .{}, i64);
    std.debug.print("1 + 1 = {d}\n", .{two});
}
```

[`examples/consumer/`](examples/consumer/) is exactly this, as a standalone
project with a path dependency on this repository.

## What's in the box

| Layer | What it gives you |
|-------|-------------------|
| `msgpack` | comptime `encode`/`decode` over Zig types, a dynamic `Value`, a `Bin` newtype, and Tarantool `MP_EXT` (uuid/datetime parsed). No Tarantool dependency. |
| `proc` | **raw** procs (`fn(ctx, args, args_end) callconv(.c) c_int`) and **typed** procs (`exportProc(name, fn)` reflects the signature, (de)serializes args/return, maps Zig errors to box errors). |
| `lua` | author **Lua C modules**: `exportModule(name, defs)` emits `luaopen_<name>` for a `require()`-able module. Entries are **raw** `lua_CFunction`s or **typed** plain Zig fns — args decoded off the Lua stack, result encoded back, mismatches fail-fast. Carries int64/uint64 cdata, struct↔table / tuple↔array / slice↔array, multiple return values, and a `box.tuple` bridge. |
| `box` | `Space` (`insert`/`replace`/`delete`/`get`/`update`/`upsert`), `Index` (`get`/`min`/`max`/`count`/`iterator`/`select`/`range`/`top`), `Tuple` field access, and `Typed(Row)` — a typed view mapping a struct to a positional row (`byName`/`get`/`put`/`del`). `Index.range(Row, …)`/`top(n, Row, …)` add a typed, auto-freeing cursor: each row decodes to a struct and the host tuple is released as you advance. |
| `txn` | `transaction(fn)` — atomic commit on success, rollback on a returned error — plus `Savepoint`, isolation level and timeout. |
| `seq` | Tarantool **sequences**: `next`/`current`/`set`/`reset` over a named or id'd sequence. |
| `keydef` | `key_def`: compare tuples and extract keys by a typed key definition. |
| `fiber` | `spawn`/`join`/`cancel`, `spawnWithAttr` (custom stack via `FiberAttr`), introspection (`name`/`csw`/`find`), the fiber clocks, and `Channel(T)` — a bounded MPMC channel (`send`/`recv`/`close`) for cross-fiber producer/consumer handoff. |
| `cond`, `latch` | fiber **condition variable** (`wait`/`waitTimeout`/`signal`/`broadcast`, predicate-aware `waitUntil`) and fiber **mutex** (`lock`/`tryLock`/`withLock`). |
| `coio` | cooperative **fd readiness**: `wait(fd, events, timeout)` yields the fiber until a socket/pipe is readable/writable; `close` wakes blocked waiters. Plus `call` — offload a blocking function to the coio worker-thread pool — and `getAddrInfo`. |
| `fiberio` | a **`std.Io` backend over fibers/coio** — hand it to `tarantool-client` and a stored proc talks iproto to other instances while its fiber yields during network waits. |
| `decimal` | Tarantool **decimal** arithmetic/rounding/compare over `box_decimal_*`, with the msgpack ext bridge and a `luaT` push/pull bridge. |
| `trigger` | **trigger registration** via the Lua bridge: `box.session.on_shutdown`, txn triggers (on_commit/on_rollback), and space `on_replace` lifecycle. |
| `say` | logging through Tarantool's logger (`say.info(fmt, args)`, …), gated by `box.cfg.log_level`. |
| `region` | the fiber-region scratch allocator (per-call savepoints) the box layer encodes through. |
| `c` | the hand-written Tarantool C ABI (single source of truth), with an optional `module.h` parity check (`-Dverify-cabi`). |
| `symresolve` | runtime resolver for **hidden** host symbols: reads the main binary's full symbol table (`.symtab`/`LC_SYMTAB`), so internals invisible to `dlsym` can be cast to typed function pointers. The escape hatch for unstable internal APIs. |

Every ergonomic layer sits on a raw one you can always drop to.

## Package modules

The build ships four public modules on a one-way import ladder, so protocol and
connector code compiles against layers that *structurally cannot* reach the host
ABI — a cross-module import fails to compile (proven by `zig build purity`):

| Module | May import | Contents |
|--------|-----------|----------|
| `msgpack` | std only | the MessagePack codec — no Tarantool dependency |
| `tarantool-proto` | `msgpack` + std | backend-independent protocol types (iterators, update ops) |
| `tarantool` | `msgpack`, `tarantool-proto`, host ABI | the in-process SDK — everything in the table above |
| `tarantool-client` | `msgpack`, `tarantool-proto` | the iproto network client (see below) |

The SDK re-exports the shared names (`tarantool.msgpack`, `tarantool.query`, …),
so module code only needs `@import("tarantool")`.

## Examples

Everything below is taken from code that `zig build integration` compiles and
runs against a live Tarantool. Each `examples/<name>/` builds to `<name>.so`
(`<name>.dylib` on macOS) and has a matching `test/luatest/<name>_test.lua`.

| Example | Shows | What it does |
|---------|-------|--------------|
| [`kv`](examples/kv/kv.zig) | `box`, `proc` | string key/value store; typed and raw procs side by side |
| [`counter`](examples/counter/counter.zig) | `seq` | a sequence-backed atomic counter and auto-incrementing ids |
| [`bank`](examples/bank/bank.zig) | `txn` | atomic transfers via `transaction(fn)`; a failed credit rolls the debit back |
| [`pipeline`](examples/pipeline/pipeline.zig) | `fiber` + `Channel` | a producer/consumer handoff between fibers over a bounded channel (with backpressure) |
| [`leaderboard`](examples/leaderboard/leaderboard.zig) | `box` index | a secondary index read with `max` / `count` and a descending top-N via `Index.top` |
| [`textutil`](examples/textutil/textutil.zig) | `lua` | a `require()`-able Lua module from plain Zig functions |
| [`proxy`](examples/proxy/proxy.zig) | `tarantool-client` + `fiberio` | stored procedures that read and write another instance over iproto |
| [`consumer`](examples/consumer/) | build helpers | a standalone project depending on this one: a module plus a client program |

### Stored procedures: typed and raw

`examples/kv/kv.zig` — a string KV store over a space named `kv`. `kv_set` is a
typed proc; `kv_get` is a raw proc, so it controls the result tuple's lifetime
while reading a field.

```zig
const std = @import("std");
const t = @import("tarantool");
const box = t.box;
const proc = t.proc;

fn kvSet(key: []const u8, value: []const u8) !void {
    const space = try box.Space.byName("kv");
    if (try space.replace(.{ key, value })) |row| row.deinit();
}

fn kvGet(ctx: ?*t.c.box_function_ctx_t, args: [*c]const u8, args_end: [*c]const u8) !c_int {
    var dec = t.msgpack.Decoder.init(args[0 .. @intFromPtr(args_end) - @intFromPtr(args)]);
    const key = (try t.msgpack.decode(struct { []const u8 }, &dec))[0];

    const space = try box.Space.byName("kv");
    if (try space.get(.{key})) |row| {
        defer row.deinit(); // the tuple is host memory: read, then release
        if (try row.field(1, std.heap.c_allocator)) |v| return proc.returnValue(ctx, v);
    }
    return proc.returnValue(ctx, @as(?u8, null)); // nil
}

comptime {
    proc.exportProc("kv_set", kvSet);
    proc.exportRaw("kv_get", kvGet);
}
```

```lua
box.schema.func.create('kv.kv_set', { language = 'C' })
box.func['kv.kv_set']:call{ 'hello', 'world' }
box.func['kv.kv_get']:call{ 'hello' }   --> 'world'
```

A typed proc returning a Zig error fails the call with the error's name; a raw
proc wrapped by `exportRaw` surfaces the host's real message on `error.BoxOp`.

### Typed rows

`box.Typed(Row)` maps a struct to a positional tuple; `Index.range`/`top`
decode rows as you iterate and free the host tuples for you:

```zig
const Account = struct { id: []const u8, balance: i64 };
const Accounts = t.box.Typed(Account);

fn deposit(id: []const u8, amount: i64) !i64 {
    const alloc = std.heap.c_allocator;
    const accounts = try Accounts.byName("accounts");
    var acct = (try accounts.get(.{id}, alloc)) orelse return error.NoAccount;
    defer Accounts.free(acct, alloc); // strings were copied out of the tuple
    acct.balance += amount;
    try accounts.put(acct);
    return acct.balance;
}
```

See [`leaderboard`](examples/leaderboard/leaderboard.zig) for
`Index.top(n, Row, alloc)` over a secondary index.

### Transactions

`txn.transaction(fn, args)` commits when `fn` returns, rolls back when it
returns an error ([`bank`](examples/bank/bank.zig)):

```zig
fn transfer(from: []const u8, to: []const u8, amount: i64) !void {
    try t.txn.transaction(doTransfer, .{ from, to, amount });
}

fn doTransfer(from: []const u8, to: []const u8, amount: i64) !void {
    const accounts = try t.box.Space.byName("accounts");
    if (try accounts.update(.{from}, .{t.update.sub(1, amount)})) |r| r.deinit() else return error.NoAccount;
    // A missing destination fails AFTER the debit: the transaction undoes it.
    if (try accounts.update(.{to}, .{t.update.add(1, amount)})) |r| r.deinit() else return error.NoAccount;
}
```

### Fibers and channels

[`pipeline`](examples/pipeline/pipeline.zig) — a consumer fiber drains a
bounded channel; the producer parks while the channel is full:

```zig
const fiber = t.fiber;

fn consume(ch: *fiber.Channel(i64)) i64 {
    var total: i64 = 0;
    while (ch.recv() catch return total) |v| total += v;
    return total;
}

fn pipelineSum(n: i64) !i64 {
    var ch = try fiber.Channel(i64).init(4, std.heap.c_allocator);
    defer ch.deinit(); // after join: no fiber is left parked on it

    var consumer = try fiber.spawn("consumer", consume, .{&ch});
    var i: i64 = 1;
    while (i <= n) : (i += 1) try ch.send(i);
    ch.close(); // the consumer drains the rest, then sees closed-and-empty
    return consumer.join();
}
```

### Lua modules

[`textutil`](examples/textutil/textutil.zig) — plain Zig functions become a
`require()`-able Lua module:

```zig
const lua = t.lua;

fn upper(s: []const u8) ![]const u8 {
    const out = try t.region.allocator().alloc(u8, s.len); // freed after the call
    for (s, out) |ch, *o| o.* = std.ascii.toUpper(ch);
    return out;
}

fn divmod(a: i64, b: i64) !lua.Multi(struct { i64, i64 }) {
    if (b == 0) return error.DivByZero; // raised as a Lua error
    return lua.multi(.{ @divTrunc(a, b), @mod(a, b) });
}

comptime {
    lua.exportModule("textutil", .{ .upper = upper, .divmod = divmod });
}
```

```lua
local textutil = require('textutil')
textutil.upper('hello')  --> 'HELLO'
textutil.divmod(17, 5)   --> 3LL, 2LL (integers cross as int64/uint64 cdata)
```

### The client inside a stored procedure

[`proxy`](examples/proxy/proxy.zig) — `tarantool.fiberio.io()` gives the client
a `std.Io` whose network waits park the current fiber, so a proc can query
another instance without blocking the TX thread:

```zig
const client = @import("tarantool-client");

fn get(uri: []const u8, key: []const u8) !?[]const u8 {
    var conn = try client.Connection.connect(std.heap.c_allocator, t.fiberio.io(), .{
        .address = uri,
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_s }, .clock = .awake } },
    });
    defer conn.close();
    const row = try conn.space("kv").get(.{key}, struct { []const u8, []const u8 }) orelse return null;
    // Decoded strings borrow the connection's buffer: copy out before close.
    return try t.region.allocator().dupe(u8, row[1]);
}

comptime {
    t.proc.exportProc("get", get);
}
```

```lua
box.func['proxy.get']:call{ '127.0.0.1:3302', 'hello' } --> 'world'
```

## Network client

```zig
const client = @import("tarantool-client");

var conn = try client.Connection.connect(gpa, io, .{
    .address = "127.0.0.1:3301", .user = "app", .password = "secret",
});
defer conn.close();

// DML by space name: no schema fetch needed. `Row = void` discards the result.
const users = conn.space("users");
_ = try users.insert(.{ 1, "alice" }, void);
const row = try users.get(.{1}, struct { u64, []const u8 }); // ?Row

// Calls and evals decode their result into a Zig type.
const n = try conn.call("box.space.users:count", .{}, u64);

// Pipelining: N requests, one flush, responses matched by sync.
var b = conn.batch(gpa);
defer b.deinit();
const h1 = try b.eval("return 1 + 1", .{});
const h2 = try b.get(users, .{1});
try b.execute();
const two = try b.decodeOne(h1, i64);
const again = try b.decodeMaybe(h2, struct { u64, []const u8 });

// A lazy, drift-aware schema cache.
const sch = try conn.schema();
const info = sch.space("users") orelse return error.NoSuchSpace;

// Watchers (box.watch / box.broadcast): a caller-pumped event queue.
try conn.watch("config");
const ev = try conn.waitEvent(); // ev.key, ev.data (raw MessagePack, null if unset)
const current = try conn.watchOnce("config", ?i64);

// Interactive transactions over a stream (pair with memtx_use_mvcc_engine).
var tx = try client.Stream.open(&conn);
try tx.begin();
errdefer tx.rollback() catch {};
_ = try tx.space("users").replace(.{ 2, "bob" }, void);
try tx.commit();
```

- **IO-agnostic** (`io: std.Io` parameter): `std.Io.Threaded` standalone, or
  `tarantool.fiberio.io()` inside a stored procedure — the client is the same.
- `chap-sha1` auth; a guest with an empty password skips AUTH. Typed
  `call`/`eval` plus raw-MessagePack escape hatches on every verb; `Space`/`Index`
  DML mirroring the SDK's shapes; per-request server errors on a `last_error`
  side channel.
- Decoded `[]const u8` fields **borrow** the connection's receive buffer: copy
  them before the next request on the same connection.
- No background reader and no threads: watcher events arrive while you pump
  (`waitEvent`/`pollEvent`) and are re-armed automatically.
- Every protocol constant is parity-asserted against a live server's
  `box.iproto` in the test suite; wire fixtures are live-captured, never
  hand-computed.

## Use in your project

Add the package to your `build.zig.zon` under the name `tarantool` (a `.url` +
`.hash` pair, or a local `.path`):

```zig
.dependencies = .{
    .tarantool = .{ .path = "../zig-tarantool" },
},
```

Then your `build.zig` calls the helpers this package's `build.zig` exports:

```zig
const std = @import("std");
const tarantool = @import("tarantool");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hello = tarantool.addModule(b, .{
        .name = "hello",
        .root_source_file = b.path("src/hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    tarantool.installModule(b, hello); // zig-out/lib/hello.so (hello.dylib on macOS)

    const cli = tarantool.addExecutable(b, .{
        .name = "hello-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(cli); // zig-out/bin/hello-client
}
```

`zig build` puts modules in `zig-out/lib/` and programs in `zig-out/bin/`;
`zig build -p <dir>` installs to `<dir>/lib` and `<dir>/bin` instead.

- `addModule(b, options) *std.Build.Step.Compile` creates a Tarantool C
  module: a dynamic library whose root source can import `tarantool`,
  `tarantool-proto`, `tarantool-client` and `msgpack` (plus any
  `options.imports`). Undefined symbols are allowed: `box_*` and `lua_*` are
  resolved from the Tarantool process when it loads the module.
- `installModule(b, lib)` installs it as `lib/<name>.so`, or `lib/<name>.dylib`
  on macOS: no `lib` prefix, the extension Tarantool searches for on that OS.
  A dotted name `a.b` goes to `lib/a/b.so`. `addInstallModule(b, lib)` returns
  the install step without adding it to `zig build`'s default step. Don't use
  `b.installArtifact` for a module: it installs `lib<name>.so`, which Tarantool
  does not find.
- `addExecutable(b, options) *std.Build.Step.Compile` creates a standalone
  program that can import `tarantool-client`, `tarantool-proto` and `msgpack`;
  install it with `b.installArtifact`.
- `moduleExtension(target) []const u8` returns `"so"` or `"dylib"`.

The helpers find this package among your dependencies on their own
(`b.dependencyFromBuildZig`) and build it for the `target` and `optimize` you
pass; you don't call `b.dependency`. Both return the plain compile step, so you
can adjust it further.

To load a module, put the install directory on `package.cpath`. Tarantool
reports the extension it expects as `require('tarantool').build.mod_format`:

```lua
local ext = require('tarantool').build.mod_format -- 'so', or 'dylib' on macOS
package.cpath = '/path/to/zig-out/lib/?.' .. ext .. ';' .. package.cpath

box.schema.func.create('hello.add', { language = 'C' })
box.func['hello.add']:call({ 1, 2 }) --> 3
```

Without `package.cpath`, Tarantool also looks for `?.<ext>` and
`.rocks/lib/tarantool/?.<ext>` in the current directory (`.rocks` in its
parents too), so copying the module there works as well.

Creating a `language = 'C'` function as a non-admin user needs `execute` on
`universe` since Tarantool 3.7.2 / 3.8.2 / 3.9.0; the examples create them as
admin.

`zig build consumer` builds [`examples/consumer/`](examples/consumer/) for the
current `-Dtarget`/`-Doptimize` and checks that `lib/hello.<ext>` and
`bin/hello-client` were installed.

## Encoding conventions

Explicit, never guessed:

- `[]const u8` and string/array-of-`u8` → MessagePack **str**
- `msgpack.Bin{ .bytes = ... }` → **bin**
- a **tuple** struct (`.{ a, b }`) → **array** (a Tarantool tuple/key)
- a **named** struct → **map**
- an optional `null` → **nil**

Decoding is fail-fast: a type or arity mismatch is an error, never a silent
coercion.

## Lifetimes & error contracts

The box layer hands back host-owned tuples and host-set errors; both have
explicit lifetimes you manage. The rules, in one place:

- **Tuples.** A read (`get`/`min`/`max`/`insert`/…) returns a `Tuple` holding one
  host reference — call `deinit` when done. When you don't need the result, the
  `*Discard` write variants (`insertDiscard`, `replaceDiscard`, `deleteDiscard`,
  `updateDiscard`, `upsertDiscard`) run the op and free it for you. A tuple
  yielded by `Index.cursor`'s `Cursor` (or a raw `Iterator`) is **borrowed**: the
  `Cursor` frees it on the next `next`/`deinit`, so copy out anything that must
  outlive the advance — `get` on a `[]const u8` field returns a slice *into* the
  tuple, not a copy, so `dupe` it first. `Index.range(Row, …)`/`top` avoid this
  by duping every `[]const u8` field into your allocator as they decode.
- **Region allocator.** Box ops encode their arguments on the fiber region under
  a per-call `region.Savepoint` that truncates as the call returns. The one-shot
  ops manage that savepoint internally; if *you* hand a helper
  `region.allocator()` directly, you own the bounding `region.Savepoint` — its
  scratch is reclaimed only when your savepoint restores.
- **Errors.** A failing host op returns `error.BoxOp` and leaves the real message
  on the host error stack ("Duplicate key exists in unique index 'pk'"); a
  missing space/index is a pure-Zig `error.NoSuchSpace`/`NoSuchIndex` with no host
  message. In a raw proc, `proc.exportRaw` maps both — host message on a `BoxOp`,
  the error name otherwise. Compose from the host text with `err.lastMessage(buf)`.
- **Fiber teardown.** `Channel.deinit` debug-asserts no sender/receiver fiber is
  still parked — join them first. `cond.Cond.deinit` carries the same precondition
  as a caller obligation (a by-value `Cond` can't track waiters across a captured
  copy).

## Build & test

```sh
./deps.sh                      # one-time: install luatest into ./.rocks (needs tt + network)
zig build test                 # pure-Zig unit tests (msgpack, proto, client, update ops)
zig build modules              # build the example/test modules and client programs
zig build integration          # build them, then run the luatest suite against them
zig build consumer             # build examples/consumer through the public helpers
zig build verify-cabi -Dverify-cabi=true   # check c.zig against module.h
zig build purity                           # prove cross-module imports fail to compile
```

`zig build integration` needs `tarantool` on your `PATH` and luatest installed
once via `./deps.sh`. The suite lives under `test/luatest/`: each group starts
its own `luatest.Server` with `zig-out/lib` on its `package.cpath`. `deps.sh`
shells out to `tt rocks install`; `tt` ships with the Tarantool SDK and may not
be on your `PATH`, so point at it if needed: `TT=/path/to/tt ./deps.sh`. To run
one group by hand, set `LUA_PATH` so `require('helper')` resolves:

```sh
LUA_PATH="./test/luatest/?.lua;;$LUA_PATH" ./.rocks/bin/luatest test/luatest/kv_test.lua
```

`verify-cabi` reads headers from `/usr/include/tarantool`
(`/opt/homebrew/include/tarantool` on macOS); override with
`-Dtarantool-include=<dir>`. `zig build modules -Dtarget=aarch64-macos`
cross-compiles the modules.

In the official `tarantool/tarantool` Docker images, unset `TT_APP_NAME` and
`TT_INSTANCE_NAME` before running the suite: they switch every tarantool the
tests start into cluster-config mode.

**CI** (`.github/workflows/ci.yml`) runs formatting, unit tests, the purity
gate, the consumer build and the macOS cross-build, then `verify-cabi` and the
luatest suite inside `tarantool/tarantool:3.5` … `3.9`.

**Coverage.** `ci/coverage.sh <out-dir>` measures `src/` line coverage with kcov
across the unit tests, every luatest-spawned server and the client programs,
and writes `<out-dir>/merged/index.html` plus a per-file `summary.md`. It
replaces `/usr/bin/tarantool` with a kcov wrapper, so run it in a throwaway
`tarantool/tarantool` container with `--cap-add=SYS_PTRACE`; CI does this on
3.9. `zig build test -Dllvm -Dcoverage=<dir>` covers just the unit tests.

## Roadmap

Open work — TLS and `pap-sha256` (Tarantool 3.9), SQL, pagination,
`Index.deleteRange`, an evented-loop example — is tracked in
[GitHub issues](https://github.com/tarantool-contrib/zig-tarantool/issues).
