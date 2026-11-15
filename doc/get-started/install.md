# Install

This page lists what zig-tarantool needs and adds it to a Zig project.

## Requirements

| What | Version | Needed for |
|------|---------|------------|
| Zig | 0.17.1 | everything; the package pins it in `build.zig.zon` and `.zig-version` |
| Tarantool | 3.5 or later | loading the modules you build |
| Tarantool | 3.0 or later | the server a client program talks to |
| luatest | any | only the test suite of this repository |

A module needs Tarantool 3.5 because it calls `box_*` functions that older
Tarantool does not export, such as `box_tuple_data` and `box_status` (3.3 and
3.4 lack them, 3.0 lacks more). Tarantool resolves these symbols when it loads
the module, so on an older version the load fails with an undefined symbol. A
client program only speaks the protocol, and 3.0 is the first version with the
features it requires.

Platforms:

| Platform | CI |
|----------|----|
| Linux x86_64 | runs the suite against Tarantool 3.5, 3.6, 3.7, 3.8 and 3.9 |
| Linux arm64 | runs the suite against Tarantool 3.5 and 3.9 |
| macOS, Apple silicon | runs the suite against the Tarantool of Homebrew |
| macOS, Intel | builds the modules and programs, does not run them |

## Install Zig

Take Zig 0.17.1 from [ziglang.org/download](https://ziglang.org/download/)
and put it on `PATH`:

```console
$ zig version
0.17.1
```

## Install Tarantool

Install Tarantool 3.5 or later from
[tarantool.io/download](https://www.tarantool.io/en/download/); on macOS,
`brew install tarantool`. Or run it in Docker:

```console
$ docker run --rm -it tarantool/tarantool:3.9
```

The modules do not need the Tarantool headers to build: the package carries its
own declarations of the C API. The headers are only needed to check those
declarations, see [Testing](../project/testing.md#check-the-c-api).

## Add the package to a project

Create a project, if you have none yet:

```sh
mkdir hello && cd hello
zig init --minimal
```

and add zig-tarantool to its `build.zig.zon` under the name `tarantool`. Its
`build.zig` exports the helpers that build modules and programs, and they find
the package by that name.

At a commit of the repository:

```sh
zig fetch --save git+https://github.com/tarantool-contrib/zig-tarantool#<commit>
```

`zig fetch` downloads the package, computes its hash and writes both to
`build.zig.zon`:

```zig
.dependencies = .{
    .tarantool = .{
        .url = "git+https://github.com/tarantool-contrib/zig-tarantool#<commit>",
        .hash = "tarantool-0.0.0-...",
    },
},
```

Or from a checkout next to the project, which is handy while you change both:

```zig
.dependencies = .{
    .tarantool = .{ .path = "../zig-tarantool" },
},
```

A `.path` dependency has no hash: Zig builds the checkout as it is.

## Next

- [Your first module](first-module.md): a stored procedure, built and called.
- [Your first client](first-client.md): a program that talks to Tarantool.
- [Your first modules with tt](first-modules-with-tt.md): a module built,
  run and tested as part of a tt package.
