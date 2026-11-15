# Your first modules with tt

This page builds a Zig module as part of a [tt](https://github.com/tarantool/tt)
package: tt runs `zig build`, puts the module into `.rocks/` of the project,
runs Tarantool with it and runs its tests. The module holds two stored
procedures and a Lua module. [Your first module](first-module.md) builds the
same kind of module with Zig and Tarantool alone.

It needs Zig, see [Install](install.md), and tt 3 with the `zig` build backend:
`tt version --modules` lists the module `build` in a tt that has it. tt installs
Tarantool into the project itself.

## Create the project

```console
$ mkdir myapp && cd myapp
$ git init
$ tt new
created /home/me/myapp/app.manifest.toml for package myapp
$ tt binary install tarantool
```

`tt new` writes `app.manifest.toml`, the manifest of the package `myapp`.
`tt binary install tarantool` installs the latest Tarantool into
`.tarantool/` of the project; the commands of tt below run that one.

## Set up the component

The Zig code of the package is a component: a directory with its own Zig
project. Create it in `libs/hello/` and add zig-tarantool to it:

```sh
mkdir -p libs/hello/src && cd libs/hello
zig init --minimal
zig fetch --save git+https://github.com/tarantool-contrib/zig-tarantool#<commit>
cd ../..
```

`zig fetch` adds the package to `libs/hello/build.zig.zon` as `tarantool`; a
checkout works as well, see [Using with tt](../how-to/using-with-tt.md#zig-tarantool-from-a-checkout).

## Write the module

`libs/hello/src/hello.zig`:

```zig
//! The module hello of the package myapp: two stored procedures and a Lua
//! module.

const std = @import("std");
const t = @import("tarantool");

/// The stored procedure myapp.hello.add(a, b) -> a + b.
fn add(a: i64, b: i64) i64 {
    return a + b;
}

/// The stored procedure myapp.hello.greet(name) -> 'Hello, <name>!', or the
/// error EmptyName.
fn greet(name: []const u8) ![]const u8 {
    if (name.len == 0) return error.EmptyName;
    return std.fmt.allocPrint(t.region.allocator(), "Hello, {s}!", .{name});
}

/// mul(a, b) of the Lua module require('myapp.hello').
fn mul(a: i64, b: i64) i64 {
    return a * b;
}

comptime {
    t.proc.exportProc("add", add);
    t.proc.exportProc("greet", greet);
    t.lua.exportModule("myapp_hello", .{ .mul = mul });
}
```

One library is two modules for Tarantool:

- a C module: `add` and `greet` are the C symbols of the stored procedures
  `myapp.hello.add` and `myapp.hello.greet`, see
  [Stored procedures](../how-to/stored-procedures.md);
- a Lua module: `exportModule("myapp_hello", ...)` exports
  `luaopen_myapp_hello`, which `require('myapp.hello')` calls, see
  [Lua modules](../how-to/lua-modules.md).

The names have the namespace of the package, `myapp`, in front, because tt
installs the module as `myapp/hello.so`.

`libs/hello/build.zig`:

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

This is the `build.zig` of [Your first module](first-module.md#build-it):
`installModule` installs `lib/hello.so`, or `lib/hello.dylib` on macOS, where
tt takes it from.

## Declare the component

Add the component to `app.manifest.toml`:

```toml
[components.hello]
path = "libs/hello"
exclude = ["zig-pkg/**"]

[components.hello.build]
backend = "zig"
module = "hello"
```

- `backend = "zig"` builds the component with `zig build`, and
  `module = "hello"` is the module the build installs.
- `exclude` keeps `zig-pkg/` out of the package. Zig fetches the dependencies
  of `build.zig.zon` there, next to it, and tt lays out the `*.lua` files of a
  component into the package, those of the dependencies among them.

Zig and tt leave files that git does not need to keep:

```console
$ printf '.rocks/\n.tarantool/\n.env/\n_build/\nzig-out/\nzig-pkg/\n.zig-cache/\n' > .gitignore
```

## Build

```console
$ tt package build
$ find .rocks/lib -name 'hello*'
.rocks/lib/tarantool/myapp/hello.so
```

`tt package build` runs `zig build` in `libs/hello/`, in the `ReleaseSafe` mode,
and copies the module into `.rocks/lib/tarantool/myapp/`. Tarantool looks for
modules in `.rocks/` of its current directory, so the code of the project
loads it with no `package.cpath`.

The first build compiles zig-tarantool and takes a while; the next ones reuse
the cache of zig in `_build/`.

## Call the Lua module

```console
$ tt run -e "print(require('myapp.hello').mul(6, 7))" - </dev/null
42
```

`tt run` runs the Tarantool of the project with the arguments as given.
`require('myapp.hello')` finds `myapp/hello.so` in `.rocks/` and calls its
`luaopen_myapp_hello`.

## Call the stored procedures

`app.lua`:

```lua
require('fio').mktree('data')
box.cfg({memtx_dir = 'data', wal_dir = 'data'})

box.schema.func.create('myapp.hello.add', {language = 'C', if_not_exists = true})
box.schema.func.create('myapp.hello.greet', {language = 'C', if_not_exists = true})

print(box.func['myapp.hello.add']:call({1, 2}))
print(box.func['myapp.hello.greet']:call({'tt'}))
print(pcall(box.func['myapp.hello.greet'].call, box.func['myapp.hello.greet'], {''}))

os.exit(0)
```

```console
$ tt run app.lua
3
Hello, tt!
false	EmptyName
```

The log of `box.cfg` goes to the standard error, around these lines.
`box.schema.func.create('myapp.hello.add', {language = 'C'})` declares a
function whose code is the symbol `add` of the module `myapp.hello`: Tarantool
takes the module from the name up to its last dot and the symbol from the rest.

## Test

```console
$ tt package add luatest --dev
added luatest * to [dev_dependencies]
  checks 3.4.1-1
  luatest 1.4.5-1
```

`test/hello_test.lua`:

```lua
local t = require('luatest')
local fio = require('fio')
local hello = require('myapp.hello')

local g = t.group()

g.before_all(function()
    local dir = fio.tempdir()
    box.cfg({memtx_dir = dir, wal_dir = dir})
    box.schema.func.create('myapp.hello.add', {language = 'C', if_not_exists = true})
    box.schema.func.create('myapp.hello.greet', {language = 'C', if_not_exists = true})
end)

g.test_mul = function()
    t.assert_equals(hello.mul(6, 7), 42)
end

g.test_add = function()
    t.assert_equals(box.func['myapp.hello.add']:call({1, 2}), 3)
end

g.test_greet = function()
    t.assert_equals(box.func['myapp.hello.greet']:call({'tt'}), 'Hello, tt!')
    t.assert_error_msg_equals('EmptyName', box.func['myapp.hello.greet'].call,
        box.func['myapp.hello.greet'], {''})
end
```

```console
$ tt test
...
Ran 3 tests in 0.047 seconds, 3 succeeded, 0 failed
```

`tt test` builds the package first, so a change of the Zig code is in the
module the tests load. luatest runs the tests in a Tarantool of its own, which
the group configures in `before_all`. Leave `log` out of that `box.cfg`:
luatest has set it already, and `box.cfg` cannot change it.

## Next

- [Using with tt](../how-to/using-with-tt.md): a program next to the module,
  instances, the build options, packing.
- [Stored procedures](../how-to/stored-procedures.md): arguments, results,
  errors, raw procedures.
- [Lua modules](../how-to/lua-modules.md): tables, tuples, several results.
