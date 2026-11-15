# Logging

A module writes to the log of Tarantool: the destination of `box.cfg.log`, with
its format and its level. `tarantool.say` does it, and adapts `std.log` to it,
so that the `std.log` calls of the module and of its dependencies go there too.

## The module

`src/chatty.zig`:

```zig
//! chatty: log through say, and through std.log.

const std = @import("std");
const t = @import("tarantool");
const say = t.say;

/// Route std.log of this module, and of everything it imports, to the log of
/// Tarantool.
pub const std_options: std.Options = .{ .logFn = say.stdLogFn };

const log = std.log.scoped(.chatty);

/// chatty.hello(name): log at each level.
fn hello(name: []const u8) void {
    say.info("hello, {s}", .{name});
    say.warn("{d} bytes of name", .{name.len});
    if (say.enabled(.debug)) say.debug("debug is on", .{});
    log.info("through std.log", .{});
}

/// chatty.open(path): log the error of a failed open, with its errno.
fn open(path: []const u8) !void {
    const z = try t.region.allocator().dupeSentinel(u8, path, 0);
    const fd = std.c.open(z, .{});
    if (fd < 0) {
        say.sysError(@backingInt(std.c.errno(fd)), "cannot open {s}", .{path});
        return error.OpenFailed;
    }
    _ = std.c.close(fd);
}

comptime {
    t.proc.exportProc("hello", hello);
    t.proc.exportProc("open", open);
}
```

```lua
box.schema.func.create('chatty.hello', { language = 'C', if_not_exists = true })
box.schema.func.create('chatty.open', { language = 'C', if_not_exists = true })
box.func['chatty.hello']:call({ 'zig' })
pcall(box.func['chatty.open'].call, box.func['chatty.open'], { '/nonexistent' })
```

```text
I> hello, zig
W> 3 bytes of name
I> (chatty): through std.log
!> cannot open /nonexistent: No such file or directory
```

Each line starts with the time, the process id, the fiber and the position, as
other lines of the log do. The position is `zig:0`: Zig gives a function no way
to know the line that called it, so put what identifies the line in the message.

## Levels

| Function | Level |
|----------|-------|
| `say.err` | `E>`, error |
| `say.crit` | `C>`, critical |
| `say.warn` | `W>`, warning |
| `say.info` | `I>`, information |
| `say.verbose` | `V>`, verbose |
| `say.debug` | `D>`, debug |
| `say.sysError(errno, fmt, args)` | `!>`, system error: the message of `errno` appended |

A message above the `box.cfg.log_level` of the instance is not written, and not
formatted: the level is checked first. `say.enabled(level)` tells whether a level
is written, to skip work that only a message needs. The level is read at each
call, so a change of `box.cfg{log_level = ...}` takes effect at once.

The format is that of `std.fmt`, not of `printf`. A line is formatted in a
buffer of 1024 bytes on the stack; a longer one is cut and ends with `...`.

## std.log

`say.stdLogFn` as the `logFn` of the `std_options` of the root source file
sends `std.log` to the log of Tarantool: `err`, `warn`, `info` and `debug` map
to the levels of the same names, and a scope other than the default one
prefixes the message, as `(chatty):` above.

`std.log` filters by its own level as well, at compile time:
`std_options.log_level` defaults to `.debug` in a debug build and to `.info` in
the release ones, so a release build has no `std.log.debug` calls at all, whatever
`box.cfg.log_level` says.
