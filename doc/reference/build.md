# Build reference

The `build.zig` of zig-tarantool exports helpers for the `build.zig` of a project
that depends on it, and defines the steps that build and test the package
itself. This page lists both.

## Helpers

A project calls them with the package imported under the name it has in
`build.zig.zon`, which must be `tarantool`:

```zig
const tarantool = @import("tarantool");
```

The helpers find the package among the dependencies of the project themselves,
and build it for the `target` and `optimize` they are given: the project does
not call `b.dependency`.

### addModule

```zig
pub fn addModule(b: *std.Build, options: ModuleOptions) *std.Build.Step.Compile
```

Creates a Tarantool module: a shared library that Tarantool loads, for
`box.schema.func.create('<name>.<symbol>', {language = 'C'})` or for
`require('<name>')`. Its root source file can import `tarantool`,
`tarantool-client`, `tarantool-proto` and `msgpack`. The symbols of Tarantool
stay undefined, for Tarantool to resolve when it loads the library.

| Option | Is |
|--------|----|
| `.name` | the name of the module; a dotted name `a.b` installs as `a/b.so` |
| `.root_source_file` | its root source file |
| `.target`, `.optimize` | as for any compile step |
| `.imports` | more imports, on top of the four above |

It returns the compile step, which you can change further: link a C library,
add an include path.

### installModule, addInstallModule

```zig
pub fn installModule(b: *std.Build, lib: *std.Build.Step.Compile) void
pub fn addInstallModule(b: *std.Build, lib: *std.Build.Step.Compile) *std.Build.Step.InstallArtifact
```

`installModule` installs a module as `lib/<name>.so`, or `lib/<name>.dylib` when
the target is macOS, under the install prefix, as part of `zig build`.
`addInstallModule` makes the same install step without adding it to `zig build`,
for a step of your own.

Do not install a module with `b.installArtifact`: it names the file
`lib<name>.so`, and Tarantool looks for `<name>.so`.

### addExecutable

```zig
pub fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile
```

Creates a program that can import `tarantool-client`, `tarantool-proto` and
`msgpack`, with the same options as `addModule`. It cannot import `tarantool`,
which only runs inside Tarantool. Install it with `b.installArtifact`, into
`bin/`.

### moduleExtension

```zig
pub fn moduleExtension(target: std.Target) []const u8
```

`"dylib"` for macOS, `"so"` for the other systems: the extension Tarantool looks
for. In Lua, `require('tarantool').build.mod_format` says the same.

## Loading a module

Tarantool looks for a module on `package.cpath`, as Lua does:

```lua
local ext = require('tarantool').build.mod_format
package.cpath = '/path/to/zig-out/lib/?.' .. ext .. ';' .. package.cpath
```

Without that, it also looks in the current directory, and in
`.rocks/lib/tarantool/` of the current directory and of its parents, so copying
the module there works as well. A tt package puts it there: see
[Using with tt](../how-to/using-with-tt.md).

`zig build -p <prefix>` installs into `<prefix>/lib` and `<prefix>/bin` instead
of `zig-out`. `zig build -Dtarget=aarch64-macos` cross-compiles the modules and
programs, if the project passes `b.standardTargetOptions` to the helpers.

## Steps of this repository

| Step | Does |
|------|------|
| `zig build test` | the unit tests: the codec, the protocol, the client, the update operations; no Tarantool needed |
| `zig build modules` | builds the examples, the test modules and the test programs |
| `zig build integration` | builds them, then runs the luatest suite against `tarantool` on `PATH` |
| `zig build consumer` | builds `examples/consumer`, a project that uses the helpers, and checks what it installed |
| `zig build purity` | checks that `tarantool-client` and `tarantool-proto` cannot import `tarantool`: their compilation must fail |
| `zig build verify-cabi -Dverify-cabi=true` | checks the declarations of `tarantool.c` against the `module.h` of an installed Tarantool |
| `zig build docs` | generates the API reference from the doc comments into `zig-out/docs/api/`; see [Testing](../project/testing.md#the-documentation) |

| Option | Does |
|--------|------|
| `-Dtarantool-include=<dir>` | where `verify-cabi` reads `module.h`; `/usr/include/tarantool` by default, `/opt/homebrew/include/tarantool` on macOS |
| `-Dllvm` | builds with the LLVM backend, which kcov needs |
| `-Dcoverage=<dir>` | runs the unit tests under kcov, writing the reports to `<dir>` |

[Testing](../project/testing.md) describes the suite.
