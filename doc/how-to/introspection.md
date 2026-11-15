# Introspection

This page reads the state of the instance from a module: its status, whether it
is read-only, its schema version and LSN, the memory of memtx. It also covers
the clocks, and reaching functions that Tarantool does not export.

## The module

`src/probe.zig`:

```zig
//! probe: the state of the instance, as a stored procedure sees it.

const t = @import("tarantool");
const info = t.box.info;

/// probe.state() -> {status = , ro = , schema = , lsn = , arena_used = }
fn state() struct { status: []const u8, ro: bool, schema: u64, lsn: ?i64, arena_used: u64 } {
    return .{
        .status = @tagName(info.status()),
        .ro = info.isRo(),
        .schema = info.schemaVersion(),
        .lsn = info.lsn(),
        .arena_used = info.slab(.arena_used),
    };
}

/// probe.wait_rw(timeout) -> true once the instance is writable, false on timeout.
fn waitRw(timeout: f64) !bool {
    info.waitRo(false, timeout) catch |e| switch (e) {
        error.Timeout => return false,
        error.Cancelled => return e,
    };
    return true;
}

/// probe.has_symbol(name) -> whether the executable has a symbol, exported or not.
fn hasSymbol(name: []const u8) bool {
    return t.symresolve.resolve(name) != null;
}

comptime {
    t.proc.exportProc("state", state);
    t.proc.exportProc("wait_rw", waitRw);
    t.proc.exportProc("has_symbol", hasSymbol);
}
```

```lua
for _, name in ipairs({ 'state', 'wait_rw', 'has_symbol' }) do
    box.schema.func.create('probe.' .. name, { language = 'C', if_not_exists = true })
end
local function call(name, ...)
    return box.func['probe.' .. name]:call({ ... })
end

call('state').status          -- running
call('state').ro              -- false
call('wait_rw', 0.1)          -- true
call('has_symbol', 'txn_begin') -- true
```

## The state of the instance

`box.info` reads what `box.info` and `box.slab.info()` show in Lua:

| Function | Returns |
|----------|---------|
| `status()` | `.running`, `.loading`, `.orphan` or `.hot_standby` |
| `isRo()` | whether the instance is read-only |
| `roReason()` | why it is read-only, or `null`; the string is valid until the next box call |
| `waitRo(ro, timeout)` | waits until the instance is read-only, or writable; `error.Timeout`, `error.Cancelled` |
| `schemaVersion()` | the schema version, which every DDL increases |
| `lsn()` | the LSN of this instance in its vclock, or `null` before the bootstrap |
| `slab(what)` | a figure of `box.slab.info()`, in bytes: `.items_size`, `.items_used`, `.arena_size`, `.arena_used`, `.quota_size`, `.quota_used` |

A replica waits with `waitRo(false, timeout)` until it becomes the leader
before it writes.

## Clocks

| Function | Clock |
|----------|-------|
| `fiber.time()`, `fiber.time64()` | wall clock, as of the current iteration of the event loop: cheap, and the same for every fiber of the iteration |
| `fiber.clock()`, `fiber.clock64()` | monotonic, as of the current iteration |
| `clock.realtime()`, `clock.monotonic()` | the system clocks, read at the call |
| `clock.process()`, `clock.thread()` | the CPU time of the process, and of the thread |

`fiber.time64` and `fiber.clock64` count microseconds, `clock.*64`
nanoseconds; the others return seconds as `f64`.

## Hidden symbols

The C API of Tarantool, `module.h`, is a part of what its executable contains.
The rest is compiled in too, but not exported: `dlsym` does not find it, and
neither does a module that declares it as `extern`.
`symresolve.resolve(name)` reads the full symbol table of the executable, and
returns the address of the symbol, or `null`:

```zig
const raw = t.symresolve.resolve("txn_begin") orelse return error.NoSymbol;
const txn_begin: *const fn () callconv(.c) ?*anyopaque = @ptrCast(raw);
_ = txn_begin;
```

Pass the name of the C symbol, without the leading underscore of macOS. The
cast is yours: nothing checks that the type matches the function.

This is an escape hatch, not an API. The internal functions of Tarantool have
no stable signature, and change between versions; a stripped executable has no
symbol table, and nothing resolves. The `tarantool/tarantool` Docker images
keep it; check the build you deploy with `has_symbol` above.
