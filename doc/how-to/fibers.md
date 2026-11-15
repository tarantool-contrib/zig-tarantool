# Fibers

This page runs code in fibers of its own from a module: fibers you join,
a background fiber you cancel, channels between fibers, a condition variable,
and work offloaded to a thread. [Fibers and yields](../concepts/fibers.md)
explains the model. The module is `workers`.

## The module

`src/workers.zig`:

```zig
//! workers: fibers, a channel, a condition variable, and a worker thread.

const std = @import("std");
const t = @import("tarantool");
const fiber = t.fiber;

fn square(x: i64, delay: f64) i64 {
    fiber.sleep(delay);
    return x * x;
}

/// workers.squares(n) -> 1² + ... + n², each square computed in a fiber.
fn squares(n: u32) !i64 {
    var fibers: [16]fiber.Fiber(i64) = undefined;
    if (n > fibers.len) return error.TooMany;
    var spawned: usize = 0;
    errdefer for (fibers[0..spawned]) |f| {
        _ = f.join();
    };
    while (spawned < n) : (spawned += 1) {
        fibers[spawned] = try fiber.spawn("square", square, .{ @as(i64, @intCast(spawned + 1)), 0.01 });
    }
    var sum: i64 = 0;
    for (fibers[0..n]) |f| sum += f.join();
    return sum;
}

fn consume(ch: *fiber.Channel(i64)) i64 {
    var total: i64 = 0;
    while (ch.recv() catch return total) |v| total += v;
    return total;
}

/// workers.pipeline(n) -> 1 + ... + n, sent through a channel of 4 slots to a
/// consumer fiber.
fn pipeline(n: i64) !i64 {
    var ch = try fiber.Channel(i64).init(4, std.heap.c_allocator);
    defer ch.deinit(); // after the join: no fiber waits on it any more
    var consumer = try fiber.spawn("consumer", consume, .{&ch});
    var i: i64 = 1;
    while (i <= n) : (i += 1) try ch.send(i); // waits while the channel is full
    ch.close(); // the consumer takes what is left, then sees the end
    return consumer.join();
}

var ticks: u64 = 0;
var ticker: ?fiber.Fiber(void) = null;

fn tick(counter: *u64) void {
    while (!fiber.isCancelled()) {
        counter.* += 1;
        fiber.sleep(0.01);
    }
}

/// workers.start(): start a fiber that counts ticks until workers.stop().
fn start() !void {
    if (ticker != null) return error.Running;
    ticker = try fiber.spawn("ticker", tick, .{&ticks});
}

/// workers.stop() -> the number of ticks counted.
fn stop() !u64 {
    const f = ticker orelse return error.NotRunning;
    ticker = null;
    f.cancel();
    f.join();
    return ticks;
}

var flag = false;
var flag_cond: ?t.cond.Cond = null;

fn flagCond() !t.cond.Cond {
    if (flag_cond == null) flag_cond = try t.cond.Cond.init();
    return flag_cond.?;
}

fn isSet(f: *bool) bool {
    return f.*;
}

/// workers.wait_flag(timeout) -> true once set_flag ran, false on timeout.
fn waitFlag(timeout: f64) !bool {
    const cond = try flagCond();
    cond.waitUntil(&flag, isSet, timeout) catch |e| switch (e) {
        error.Timeout => return false,
        else => return e,
    };
    return true;
}

/// workers.set_flag(): wake every fiber in wait_flag.
fn setFlag() !void {
    flag = true;
    (try flagCond()).broadcast();
}

const Digest = struct { input: []const u8, out: [32]u8 = undefined };

/// Runs on a worker thread: touches nothing but `d`.
fn digest(d: *Digest) isize {
    std.crypto.hash.sha2.Sha256.hash(d.input, &d.out, .{});
    return 0;
}

/// workers.sha256(s) -> the hex SHA-256 of s, computed on a worker thread.
fn sha256(s: []const u8) ![]const u8 {
    var d: Digest = .{ .input = s };
    _ = try t.coio.call(Digest, digest, &d);
    const hex = std.fmt.bytesToHex(d.out, .lower);
    return t.region.allocator().dupe(u8, &hex);
}

comptime {
    t.proc.exportProc("squares", squares);
    t.proc.exportProc("pipeline", pipeline);
    t.proc.exportProc("start", start);
    t.proc.exportProc("stop", stop);
    t.proc.exportProc("wait_flag", waitFlag);
    t.proc.exportProc("set_flag", setFlag);
    t.proc.exportProc("sha256", sha256);
}
```

```lua
for _, name in ipairs({ 'squares', 'pipeline', 'start', 'stop', 'wait_flag',
                        'set_flag', 'sha256' }) do
    box.schema.func.create('workers.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['workers.' .. name]:call({ ... })
end

call('squares', 10)               -- 385
call('pipeline', 100)             -- 5050
call('start')
require('fiber').sleep(0.1)
call('stop') > 5                  -- true
call('wait_flag', 0.05)           -- false
require('fiber').create(function() require('fiber').sleep(0.05) call('set_flag') end)
call('wait_flag', 0.5)            -- true
call('sha256', 'abc')             -- ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
```

The timeouts are `f64`, so they take a float: `call('wait_flag', 1)` fails
with `NotFloat`, because Lua sends 1 as an integer. See
[Encoding](../concepts/encoding.md#messagepack-to-zig).

## Spawn and join

`fiber.spawn(name, f, args)` creates a fiber that runs `f` with the tuple
`args`, and returns a `fiber.Fiber(R)`, where `R` is what `f` returns.
`join()` waits for the fiber to end and returns that value; it may be an error
union. Join each fiber exactly once.

`spawn` yields: the new fiber runs until its first yield before `spawn`
returns. In `squares`, each fiber starts, sleeps, and the loop spawns the next
one; the ten sleeps overlap.

- `fiber.spawnWithAttr(name, attr, f, args)` takes a `fiber.FiberAttr`, which
  sets the stack size of the fiber: `attr.setStackSize(bytes)`. Deep recursion,
  or large arrays on the stack, need more than the default.
- `fiber.spawnDetached(name, f, args)` starts a fiber nobody joins; `f` must
  return `void`.
- A `Fiber` handle has `cancel`, `wakeup`, `id`, `name`, `setName` and `csw`,
  the number of context switches. `fiber.find(id)` looks up any fiber, read
  only.

The arguments of a fiber must outlive it. In `pipeline`, the consumer gets a
pointer to the channel on the stack of the procedure, which is valid because
the procedure joins the consumer before it returns. The ticker gets a pointer
to a global, since it outlives the call that starts it.

## Cancel

`ticker.cancel()` asks the ticker fiber to stop. The fiber sees it at its next
yield: `fiber.sleep` returns early, and `fiber.isCancelled()` is true. A fiber
that waits in `Cond.wait`, `Channel.send` or `recv` gets `error.Cancelled`
instead.

## Channels

`fiber.Channel(T).init(capacity, alloc)` is a bounded queue between fibers;
any number of fibers may send and receive.

| Method | Does |
|--------|------|
| `send(value)` | queues `value`; waits while the channel is full; `error.Closed` once it is closed |
| `recv()` | takes the oldest value; waits while the channel is empty; `null` once it is closed and empty |
| `close()` | wakes every waiting fiber; the values queued still arrive |
| `deinit()` | frees the channel; no fiber may wait on it |

## Condition variables and latches

`cond.Cond` wakes fibers that wait for a condition:

| Method | Does |
|--------|------|
| `wait()`, `waitTimeout(seconds)` | waits for a signal; `error.Timeout`, `error.Cancelled` |
| `waitUntil(context, pred, timeout)` | waits until `pred(context)` is true, checking it at each wake, within `timeout` seconds of the call |
| `signal()`, `broadcast()` | wakes one waiting fiber, or all of them |

`latch.Latch` is a mutex for fibers, for a section of code that yields and
must not run in two fibers at once:

```zig
const lock = try t.latch.Latch.init();
defer lock.deinit();
lock.lock();
defer lock.unlock();
```

`tryLock()` takes it only if it is free, and `withLock(context, f)` runs
`f(context)` under it. Code that does not yield needs no latch: no other fiber
runs in between.

## Worker threads

`coio.call(Ctx, f, &ctx)` runs `f(&ctx)` on a worker thread of Tarantool and
yields the fiber until `f` returns; it returns what `f` returned. Meanwhile the
TX thread serves other requests. `f` runs outside the TX thread, so it must not
call the box, Lua, the fiber region or any fiber function: give it the data it
needs in `ctx`, as `sha256` does.

`coio.getAddrInfo(host, port, hints, timeout)` resolves a name the same way,
without blocking the TX thread:

```zig
var addrs = try t.coio.getAddrInfo("localhost", "3301", null, 1.0);
defer addrs.deinit();
var it = addrs.iterator();
while (it.next()) |ai| _ = ai; // *std.c.addrinfo
```

`coio.wait(fd, .{ .read = true }, timeout)` waits until a non-blocking file
descriptor is readable or writable, and `coio.close(fd)` closes one and wakes
the fibers waiting on it.

## Time

`fiber.sleep(seconds)` sleeps the fiber. `fiber.time()` and `fiber.clock()`
are the wall-clock and monotonic time of the current event loop iteration, in
seconds; `time64()` and `clock64()` in microseconds. `tarantool.clock` reads the
system clocks themselves: `realtime`, `monotonic`, `process` and `thread`, in
seconds, and with `64` in nanoseconds.
