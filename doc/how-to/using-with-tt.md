# Using with tt

[tt](https://github.com/tarantool/tt) builds a Zig component of a package with
its `zig` backend: it runs `zig build` of the component, takes the module and
the program the build installs, and puts them into `.rocks/` of the project,
where Tarantool, `tt run`, `tt test` and the instances of the project find
them, and into the archive of `tt package pack`. This page covers what that
build does and how to set it up. [Your first modules with tt](../get-started/first-modules-with-tt.md)
walks through a first one.

## What it needs

| What | Where it comes from |
|------|---------------------|
| tt 3 with the `zig` backend | the standard module `build` of tt: `tt version --modules` lists `build` in a tt that has it |
| Zig | yours to install, see [Install](../get-started/install.md#install-zig); tt looks for `zig` in `.tarantool/bin` of the project first, then on `PATH` |
| Tarantool 3.5 or later | `tt binary install tarantool` installs it into the project |

tt does not install Zig. To pin the Zig of a project, link it into
`.tarantool/bin`:

```sh
mkdir -p .tarantool/bin
ln -s /path/to/zig-0.17.1/zig .tarantool/bin/zig
```

## The build block

```toml
[components.hello]
path = "libs/hello"
exclude = ["zig-pkg/**"]

[components.hello.build]
backend = "zig"
module = "hello"
bin = "hello-client"
```

`path` is the directory of the component, where its `build.zig` and
`build.zig.zon` are. tt runs there:

```console
zig build -p _build/component/hello/zig-out --cache-dir _build/component/hello/zig-cache --release=safe
```

The build installs into a prefix of its own and keeps the cache of Zig there,
under `_build/` of the project, out of the sources. `tt -V package build`
shows the line it runs.

| Field | Is |
|-------|----|
| `module` | the module the build makes: tt takes `lib/<module>.so` (`.dylib` on macOS) from the prefix, as `installModule` installs it, or `lib/lib<module>.so` as `b.installArtifact` does |
| `bin` | the program the build makes: tt takes `bin/<bin>` from the prefix, as `b.installArtifact` installs it |
| `steps` | the steps of `zig build` to run, its default step by default: `steps = ["modules"]` for a `build.zig` that installs the module from a step of its own |
| `optimize` | `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`; `ReleaseSafe` by default. tt passes `--release=safe`, `fast` or `small`, and no flag for `Debug`, which the `standardOptimizeOption` of the `build.zig` takes |
| `options` | the options the `build.zig` declares with `b.option`, as strings: `options = { tls = "true" }` passes `-Dtls=true` |
| `incremental` | `true` skips `zig build` when the block, the files of the component, the version of Zig, `build.zig` and `build.zig.zon` are those of the last build |
| `static` | `true` checks that the program needs no shared library and the module none but the C library |

A block names `module`, `bin` or both; one with neither is an error.

`exclude = ["zig-pkg/**"]` belongs to the component, not to the build. Zig
fetches the dependencies of `build.zig.zon` into `zig-pkg/` next to it, and tt
lays out the `*.lua` files of a component into the package: without the
`exclude`, the `.lua` files of zig-tarantool, those of its examples, end up in
`.rocks/share/tarantool/<namespace>/zig-pkg/` and in the archive.

## Where the files go

| What | Into |
|------|------|
| the module | `.rocks/lib/tarantool/<namespace>/<module>.so` |
| the program | `.rocks/bin/<bin>` |
| a `*.lua` file of the component | `.rocks/share/tarantool/<namespace>/<path in the component>` |

The namespace is the name of the package unless the component sets
`namespace`. A module named `hello` of the package `myapp` is
`myapp/hello.so`, so its names carry `myapp`:

| From | The name | In Zig |
|------|----------|--------|
| Lua | `require('myapp.hello')` | `lua.exportModule("myapp_hello", ...)`: dots become `_` in `luaopen_<name>` |
| a stored procedure | `box.schema.func.create('myapp.hello.add', {language = 'C'})` | `proc.exportProc("add", ...)`: Tarantool loads the module named up to the last dot, `myapp.hello`, and calls its symbol `add` |

With `namespace = ""` the module is `.rocks/lib/tarantool/hello.so`, and the
names are `require('hello')`, `luaopen_hello` and `hello.add`.

A dotted module, `module = "codec.fast"` for a `build.zig` that names it
`codec.fast`, is `lib/codec/fast.so` of the prefix, as `installModule`
installs it, and `.rocks/lib/tarantool/myapp/codec/fast.so`:
`require('myapp.codec.fast')`, exported as `myapp_codec_fast`.

## A program next to the module

The same `build.zig` builds a program over
[the network client](network-client.md) with `addExecutable`:

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

    const cli = tarantool.addExecutable(b, .{
        .name = "hello-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(cli);
}
```

`libs/hello/src/client.zig`:

```zig
//! hello-client: call myapp.hello.add over the network.

const std = @import("std");
const client = @import("tarantool-client");

pub fn main(init: std.process.Init) !void {
    var conn = try client.Connection.connect(init.gpa, init.io, .{
        .address = "127.0.0.1:3301",
    });
    defer conn.close();

    const sum = try conn.call("myapp.hello.add", .{ 20, 22 }, i64);
    std.debug.print("myapp.hello.add(20, 22) = {d}\n", .{sum});
}
```

`bin = "hello-client"` in the block takes the program into `.rocks/bin/`.

## Run it in an instance

An instance of the project loads the module as the code of the project does.
The code of the application is a component of Lua files, `app/`, which tt
lays out into `.rocks/share/tarantool/myapp/`:

```toml
[components.app]
path = "app"
```

`app/init.lua`, the module `myapp`, declares the function and lets the guest
call it:

```lua
box.schema.func.create('myapp.hello.add', {language = 'C', if_not_exists = true})
box.schema.user.grant('guest', 'execute', 'function', 'myapp.hello.add',
    {if_not_exists = true})
```

`.templates/default/config.yaml` runs one instance with it:

```yaml
app:
  module: myapp

groups:
  group-001:
    replicasets:
      replicaset-001:
        instances:
          instance-001:
            iproto:
              listen:
              - uri: 127.0.0.1:3301
```

```console
$ tt package build
$ tt instance start
   • Starting an instance [myapp:instance-001]...
$ .rocks/bin/hello-client
myapp.hello.add(20, 22) = 42
$ tt instance stop --yes
```

## zig-tarantool from a checkout

While you change zig-tarantool and the project together, depend on a checkout
of it instead of a commit. The path is relative to the component: for a
checkout next to the project, `zig-tarantool/` beside `myapp/`,
`libs/hello/build.zig.zon` has

```zig
.dependencies = .{
    .tarantool = .{ .path = "../../../zig-tarantool" },
},
```

An `incremental` build does not see a change of the checkout, which is outside
the component: `tt package build --rebuild` builds anyway.

## Pack and install

```console
$ tt package pack
/home/me/myapp/_build/pack/myapp-1.0.0-linux-amd64.tt
```

The archive carries the module and the program, built for the machine it is
packed on, and an installed version of the package loads and runs them as the
project does. The module links against the C library of that machine: pack on
the oldest system the package runs on. `static = true` checks that the module
needs no other shared library; a program of `addExecutable` links no C library
and needs none.

Zig fetches the dependencies of `build.zig.zon` itself, as it builds:
`tt package fetch` does not run the build, and the lock of tt does not pin
them. The `.hash` of each dependency in `build.zig.zon` does.

## When it fails

- **The build installed no module.** tt names what the build did install:

  ```console
  $ tt package build
     ⨯ building component "hello": zig build installed no module "hullo": .../_build/component/hello/zig-out/lib has none of hullo.so, hullo.dylib, libhullo.so, libhullo.dylib (it installed hello.so); install it with installModule of zig-tarantool, or name the step that installs it in steps
  ```

  `module` and the `.name` of `addModule` must be the same name.
- **A module renamed is still in `.rocks/`.** A build keeps what an earlier
  build of the component made while the file is there: after a change of
  `module`, `tt package build --rebuild` drops the old one.
- **`undefined symbol: box_...` on `require` or on the first call.** The
  Tarantool is older than 3.5, see
  [Install](../get-started/install.md#requirements).
- **`undefined symbol: luaopen_myapp_hello` on `require('myapp.hello')`.**
  The name given to `exportModule` does not match the path of the module: it
  is `myapp_hello` for `myapp/hello.so`.
