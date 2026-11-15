# Your first module

This page builds a Tarantool module with two stored procedures, loads it into
Tarantool and calls them. It needs Zig and Tarantool, see
[Install](install.md).

A module is a shared library that Tarantool loads: `hello.so` on Linux,
`hello.dylib` on macOS. Each stored procedure of the module is a C symbol in it,
and Tarantool calls it as the function `hello.<symbol>`.

## Set up the project

```sh
mkdir hello && cd hello
zig init --minimal
zig fetch --save git+https://github.com/tarantool-contrib/zig-tarantool#<commit>
mkdir src
```

`zig fetch` adds the package to `build.zig.zon` as `tarantool`; a checkout
works as well, see [Install](install.md#add-the-package-to-a-project).

## Write the procedures

`src/hello.zig`:

```zig
//! hello.add(a, b) and hello.greet(name): two typed stored procedures.

const std = @import("std");
const t = @import("tarantool");

/// hello.add(a, b) -> a + b
fn add(a: i64, b: i64) i64 {
    return a + b;
}

/// hello.greet(name) -> 'Hello, <name>!', or the error EmptyName.
fn greet(name: []const u8) ![]const u8 {
    if (name.len == 0) return error.EmptyName;
    return std.fmt.allocPrint(t.region.allocator(), "Hello, {s}!", .{name});
}

comptime {
    t.proc.exportProc("add", add);
    t.proc.exportProc("greet", greet);
}
```

`exportProc(name, f)` exports the C symbol `name`, a function that Tarantool can
call. It decodes the arguments of the call into the parameters of `f` by their
types, calls `f`, and encodes its result back. Here:

- `add` takes two integers. A call with one argument, or with a string, fails
  with an error and never reaches `add`.
- `greet` takes a string and returns a string or an error. A Zig error fails
  the call, with the name of the error as its message.
- The greeting is allocated on the fiber region,
  `t.region.allocator()`: scratch memory that Tarantool reclaims when the
  call ends. There is nothing to free.

[Stored procedures](../how-to/stored-procedures.md) covers the types a
procedure takes and returns.

## Build it

`build.zig`:

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
    tarantool.installModule(b, hello);
}
```

```console
$ zig build
$ ls zig-out/lib
hello.so
```

`addModule` makes a shared library that can import `tarantool`, with the
`box_*` symbols left for Tarantool to resolve. `installModule` installs it under
the name Tarantool looks for: `hello.so`, or `hello.dylib` on macOS, without
the `lib` prefix that `b.installArtifact` would add. See
[Build reference](../reference/build.md).

## Call it from Tarantool

`init.lua`:

```lua
-- Find zig-out/lib/hello.so (hello.dylib on macOS).
local ext = require('tarantool').build.mod_format
package.cpath = 'zig-out/lib/?.' .. ext .. ';' .. package.cpath

require('fio').mktree('data')
box.cfg{ memtx_dir = 'data', wal_dir = 'data' }

box.schema.func.create('hello.add', { language = 'C', if_not_exists = true })
box.schema.func.create('hello.greet', { language = 'C', if_not_exists = true })

print(box.func['hello.add']:call({ 1, 2 }))
print(box.func['hello.greet']:call({ 'Zig' }))
print(pcall(box.func['hello.greet'].call, box.func['hello.greet'], { '' }))

os.exit(0)
```

```console
$ tarantool init.lua
3
Hello, Zig!
false	EmptyName
```

`box.schema.func.create('hello.add', {language = 'C'})` declares a function
whose code is the symbol `add` of the module `hello`. On the first call
Tarantool finds `hello.so` on `package.cpath`, loads it and resolves the symbol.
`require('tarantool').build.mod_format` is the extension Tarantool looks for,
`so` or `dylib`.

The function is in the schema now, so it is also callable over the network.
[Your first client](first-client.md) calls it from a Zig program.

## Next

- [Your first client](first-client.md): call `hello.add` from a program.
- [Your first modules with tt](first-modules-with-tt.md): the same module in a
  tt package, which tt builds, runs and tests.
- [Stored procedures](../how-to/stored-procedures.md): arguments, results,
  errors, raw procedures.
- [Spaces and indexes](../how-to/spaces-and-indexes.md): read and write data
  from a procedure.
