const std = @import("std");

/// `-Dllvm`: force the LLVM backend for this repo's own test/module/client
/// artifacts. Coverage runs need it — kcov cannot read the self-hosted x86_64
/// backend's debug info.
var force_llvm: ?bool = null;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    force_llvm = b.option(bool, "llvm", "Force the LLVM backend for tests, modules and client programs (for kcov)");

    // ---- module graph: msgpack -> tarantool-proto -> tarantool + client ----
    // Allowed-imports ladder: msgpack is std-only;
    // tarantool-proto sees only msgpack; the SDK (`tarantool`) and the client
    // stub sit on top of both. Consumers `@import("tarantool")`.
    const msgpack_mod = b.addModule("msgpack", .{
        .root_source_file = b.path("src/msgpack/msgpack.zig"),
        .target = target,
        .optimize = optimize,
        // NO .imports — std-only is structural.
    });
    const proto_mod = b.addModule("tarantool-proto", .{
        .root_source_file = b.path("src/proto/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "msgpack", .module = msgpack_mod }},
    });
    const mod = b.addModule("tarantool", .{
        .root_source_file = b.path("src/tarantool.zig"),
        .target = target,
        .optimize = optimize,
        // The SDK allocates through std.heap.c_allocator. Tarantool has libc
        // loaded already; the module only has to say it uses it. On macOS
        // libc is always linked, on Linux the build fails without this.
        .link_libc = true,
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_mod },
            .{ .name = "tarantool-proto", .module = proto_mod },
        },
    });
    const client_mod = b.addModule("tarantool-client", .{
        .root_source_file = b.path("src/client/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "msgpack", .module = msgpack_mod },
            .{ .name = "tarantool-proto", .module = proto_mod },
        },
    });

    // ---- unit tests: pure-Zig msgpack codec (no Tarantool dependency) ----
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("test/msgpack_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tarantool", .module = mod }},
    });
    // `-Dcoverage=<dir>`: run every unit-test binary under kcov, one report per
    // binary in <dir>/unit-<name> (merge with `kcov --merge`). Line coverage is
    // restricted to src/.
    const coverage_dir = b.option([]const u8, "coverage", "Run unit tests under kcov, writing reports to this directory");
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .name = "msgpack_test", .root_module = unit_mod, .use_llvm = force_llvm });
    addTestRun(b, test_step, unit_tests, coverage_dir);

    // ---- unit tests: pure-Zig update-op module (no Tarantool dependency) ----
    const update_mod = b.createModule(.{
        .root_source_file = b.path("test/update_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tarantool", .module = mod }},
    });
    const update_tests = b.addTest(.{ .name = "update_test", .root_module = update_mod, .use_llvm = force_llvm });
    addTestRun(b, test_step, update_tests, coverage_dir);

    // ---- per-module compile-smoke tests: each root compiles standalone ----
    const msgpack_tests = b.addTest(.{ .name = "msgpack", .root_module = msgpack_mod, .use_llvm = force_llvm });
    addTestRun(b, test_step, msgpack_tests, coverage_dir);
    const proto_tests = b.addTest(.{ .name = "proto", .root_module = proto_mod, .use_llvm = force_llvm });
    addTestRun(b, test_step, proto_tests, coverage_dir);
    const client_tests = b.addTest(.{ .name = "client", .root_module = client_mod, .use_llvm = force_llvm });
    addTestRun(b, test_step, client_tests, coverage_dir);

    const mods: Modules = .{
        .tarantool = mod,
        .proto = proto_mod,
        .client = client_mod,
        .msgpack = msgpack_mod,
    };

    // ---- integration: build each test/integration/*.zig into a loadable
    //      module and run the luatest suite (test/luatest/) against them ----
    const integration_step = b.step("integration", "Build the modules and run the luatest suite");
    const modules_step = b.step("modules", "Build the example/test modules and client programs only");
    addIntegration(b, mods, target, optimize, integration_step, modules_step);

    // ---- consumer: build examples/consumer, a downstream project that pulls
    //      this package in through build.zig.zon and uses addModule /
    //      addExecutable from its own build.zig ----
    const consumer_step = b.step("consumer", "Build examples/consumer through the public build helpers");
    addConsumerCheck(b, target, optimize, consumer_step);

    // ---- ABI parity check (CI only): translate-c module.h and compare ----
    const verify = b.option(bool, "verify-cabi", "Compile the module.h ABI parity check") orelse false;
    const tnt_inc = b.option([]const u8, "tarantool-include", "Path to Tarantool module headers") orelse
        if (target.result.os.tag == .macos) "/opt/homebrew/include/tarantool" else "/usr/include/tarantool";
    if (verify) {
        const module_h = b.addTranslateC(.{
            .root_source_file = b.path("src/c_verify.h"),
            .target = target,
            .optimize = optimize,
        });
        module_h.addIncludePath(.{ .cwd_relative = tnt_inc });
        // Vendored lua headers satisfy module.h's `#include "lua.h"` so the
        // parity check does not depend on the host install shipping them.
        module_h.addIncludePath(b.path("vendor/tarantool"));
        const vmod = b.createModule(.{
            .root_source_file = b.path("src/c_verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "msgpack", .module = msgpack_mod },
                .{ .name = "tarantool-proto", .module = proto_mod },
                .{ .name = "module_h", .module = module_h.createModule() },
            },
        });
        vmod.link_libc = true;
        const vexe = b.addExecutable(.{ .name = "c_verify", .root_module = vmod });
        const vstep = b.step("verify-cabi", "Check c.zig against the real module.h");
        vstep.dependOn(&vexe.step);
    }

    // ---- purity: prove cross-module imports fail to compile (negative gate) ----
    // The module graph alone cannot be trusted: Zig diagnoses an
    // unreferenced *named* `@import("<module>")` only lazily, so a
    // stray host import could lurk in a pure module. This gate copies the tree
    // into a sandbox and poisons a pure-module file with a *relative* import of
    // a `tarantool` file — which IS diagnosed eagerly ("file exists in modules")
    // — then asserts the build fails. Kept out of `test` (it recompiles the
    // world in a sandbox); it joins the land checklist beside verify-cabi.
    const purity = b.addSystemCommand(&.{ "sh", "test/purity_negative.sh" });
    purity.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    purity.setCwd(b.path("."));
    purity.has_side_effects = true;
    const purity_step = b.step("purity", "Prove cross-module imports fail to compile (negative gate)");
    purity_step.dependOn(&purity.step);

    // ---- docs: the API reference, generated by Zig's autodoc from the doc
    //      comments. One root (src/docs/root.zig, alone in its directory: autodoc takes a module's
    //      files from its root directory) re-exports the four public
    //      modules, so they share one reference (and one copy of std's
    //      sources). Installs to <prefix>/docs/api; ci/docs.sh puts it on the
    //      documentation site under api/. ----
    const docs_lib = b.addLibrary(.{
        .name = "zig-tarantool",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs/root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "tarantool", .module = mod },
                .{ .name = "tarantool-client", .module = client_mod },
                .{ .name = "tarantool-proto", .module = proto_mod },
                .{ .name = "msgpack", .module = msgpack_mod },
            },
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    b.step("docs", "Generate the API reference into <prefix>/docs/api").dependOn(&install_docs.step);
}

// ---- public build helpers for downstream projects ----
//
// A project that depends on this package through build.zig.zon calls these
// from its own build.zig:
//
//     const tarantool = @import("tarantool");
//
//     pub fn build(b: *std.Build) void {
//         const target = b.standardTargetOptions(.{});
//         const optimize = b.standardOptimizeOption(.{});
//         const kv = tarantool.addModule(b, .{
//             .name = "kv",
//             .root_source_file = b.path("src/kv.zig"),
//             .target = target,
//             .optimize = optimize,
//         });
//         tarantool.installModule(b, kv); // zig-out/lib/kv.so (kv.dylib on macOS)
//     }
//
// The helpers find this package among the caller's dependencies by its
// build.zig (`dependencyFromBuildZig`), instantiated for the caller's target
// and optimize mode, so the caller does not call `b.dependency` itself. The
// dependency must be named `tarantool` in build.zig.zon for `@import` to work.

/// Options for `addModule`.
pub const ModuleOptions = struct {
    /// Module name. Lua resolves `require('<name>')` and
    /// `box.schema.func.create('<name>.<proc>', {language = 'C'})` to
    /// `<name>.so` (`<name>.dylib` on macOS); a dotted name `a.b` maps to
    /// `a/b.so`, as Lua's `package.searchpath` does.
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Imports on top of the default set: `tarantool`, `tarantool-proto`,
    /// `tarantool-client` and `msgpack`.
    imports: []const std.Build.Module.Import = &.{},
};

/// Options for `addExecutable`.
pub const ExecutableOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Imports on top of the default set: `tarantool-client`,
    /// `tarantool-proto` and `msgpack`. The in-process SDK (`tarantool`) is
    /// left out on purpose: it needs the `box_*` symbols of a running server.
    imports: []const std.Build.Module.Import = &.{},
};

/// Create a Tarantool C module: a dynamic library that Tarantool loads with
/// `require` or as the module of a `language = 'C'` function. The `box_*` and
/// `lua_*` symbols stay undefined and are resolved from the host at dlopen.
/// Install it with `installModule` or `addInstallModule`; `b.installArtifact`
/// would use the platform library name (`lib<name>.so`), which Tarantool
/// does not look for.
pub fn addModule(b: *std.Build, options: ModuleOptions) *std.Build.Step.Compile {
    return addModuleWith(b, dependencyModules(b, options.target, options.optimize), options);
}

/// Create a standalone executable that talks to Tarantool over the network
/// through `tarantool-client`. Install it as usual, with `b.installArtifact`
/// (to `zig-out/bin/<name>`).
pub fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    return addExecutableWith(b, dependencyModules(b, options.target, options.optimize), options);
}

/// Create a step that installs a module from `addModule` as
/// `lib/<name>.<ext>` under the install prefix, where `<ext>` is what
/// Tarantool looks for on the module's target (see `moduleExtension`).
/// Does not add it to the install step; `installModule` does.
pub fn addInstallModule(b: *std.Build, lib: *std.Build.Step.Compile) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = moduleFileName(b, lib.name, lib.rootModuleTarget()),
        .dylib_symlinks = false,
    });
}

/// Install a module from `addModule` as part of the default install step.
pub fn installModule(b: *std.Build, lib: *std.Build.Step.Compile) void {
    b.getInstallStep().dependOn(&addInstallModule(b, lib).step);
}

/// The file extension Tarantool's C-module loader searches for on `target`:
/// `dylib` on macOS (`TARANTOOL_LIBEXT` and `src/lua/loaders.lua` in
/// Tarantool), `so` elsewhere.
pub fn moduleExtension(target: std.Target) []const u8 {
    return if (target.os.tag.isDarwin()) "dylib" else "so";
}

/// The install path of module `name` relative to the lib directory:
/// dots become directory separators, plus the target's module extension.
fn moduleFileName(b: *std.Build, name: []const u8, target: std.Target) []const u8 {
    const path = std.mem.replaceOwned(u8, b.allocator, name, ".", "/") catch @panic("OOM");
    return b.fmt("{s}.{s}", .{ path, moduleExtension(target) });
}

/// The four public modules of this package, as wired in `build`.
const Modules = struct {
    tarantool: *std.Build.Module,
    proto: *std.Build.Module,
    client: *std.Build.Module,
    msgpack: *std.Build.Module,
};

/// The modules of this package as a dependency of the project that owns `b`.
fn dependencyModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Modules {
    const dep = b.dependencyFromBuildZig(@This(), .{ .target = target, .optimize = optimize });
    return .{
        .tarantool = dep.module("tarantool"),
        .proto = dep.module("tarantool-proto"),
        .client = dep.module("tarantool-client"),
        .msgpack = dep.module("msgpack"),
    };
}

/// `addModule` over an explicit module set. This package's own examples and
/// integration modules come through here with the modules from `build`.
fn addModuleWith(b: *std.Build, mods: Modules, options: ModuleOptions) *std.Build.Step.Compile {
    // The SDK deliberately does not re-export iproto; the connector parity
    // module (`test/integration/iproto.zig`) needs the pure protocol layer
    // directly, so `tarantool-proto` is available alongside the SDK. The
    // in-process client proof (`test/integration/fiberio.zig`) drives
    // `tarantool-client` over `tarantool.fiberio` from a stored proc, so the
    // client module (+ msgpack for arg encoding) is available too. Modules
    // that do not use the extra imports are not affected by them.
    const defaults: []const std.Build.Module.Import = &.{
        .{ .name = "tarantool", .module = mods.tarantool },
        .{ .name = "tarantool-proto", .module = mods.proto },
        .{ .name = "tarantool-client", .module = mods.client },
        .{ .name = "msgpack", .module = mods.msgpack },
    };
    const root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = concatImports(b, defaults, options.imports),
    });
    const lib = b.addLibrary(.{ .name = options.name, .linkage = .dynamic, .root_module = root });
    lib.linker_allow_shlib_undefined = true; // box_* resolved at dlopen
    return lib;
}

/// `addExecutable` over an explicit module set (see `addModuleWith`).
fn addExecutableWith(b: *std.Build, mods: Modules, options: ExecutableOptions) *std.Build.Step.Compile {
    const defaults: []const std.Build.Module.Import = &.{
        .{ .name = "tarantool-client", .module = mods.client },
        .{ .name = "msgpack", .module = mods.msgpack },
        .{ .name = "tarantool-proto", .module = mods.proto },
    };
    const root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = concatImports(b, defaults, options.imports),
    });
    return b.addExecutable(.{ .name = options.name, .root_module = root });
}

fn concatImports(
    b: *std.Build,
    defaults: []const std.Build.Module.Import,
    extra: []const std.Build.Module.Import,
) []const std.Build.Module.Import {
    if (extra.len == 0) return defaults;
    return std.mem.concat(b.allocator, std.Build.Module.Import, &.{ defaults, extra }) catch @panic("OOM");
}

/// Build examples/consumer with the zig running this build, for this build's
/// target and optimize mode, into a fresh prefix, and check that the module
/// and the program land where tt expects them: `lib/hello.<ext>` and
/// `bin/hello-client`.
fn addConsumerCheck(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    consumer_step: *std.Build.Step,
) void {
    const run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\prefix=$1 ext=$2
        \\shift 2
        \\"$ZIG" build --build-file examples/consumer/build.zig -p "$prefix" "$@"
        \\for f in "lib/hello.$ext" bin/hello-client; do
        \\  if [ ! -f "$prefix/$f" ]; then
        \\    echo "consumer: $f is missing from the install prefix" >&2
        \\    exit 1
        \\  fi
        \\done
        \\echo "consumer OK: lib/hello.$ext bin/hello-client"
        ,
        "sh",
    });
    run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    run.setCwd(b.path("."));
    _ = run.addOutputDirectoryArg("consumer-prefix");
    run.addArg(moduleExtension(target.result));
    if (!target.query.isNative()) {
        const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
        run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    }
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The consumer's sources are not inputs of this step; always rebuild.
    run.has_side_effects = true;
    consumer_step.dependOn(&run.step);
}

/// Discover every `test/integration/*.zig`, compile it to a Tarantool-loadable
/// module (`<stem>.so`, `<stem>.dylib` on macOS; no `lib` prefix; undefined
/// `box_*` symbols resolved by the host at dlopen), then run
/// `.rocks/bin/luatest test/luatest/` after install. `modules_step` gets the
/// installs alone, for builds that do not run the suite (e.g. cross targets).
fn addIntegration(
    b: *std.Build,
    mods: Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    integration_step: *std.Build.Step,
    modules_step: *std.Build.Step,
) void {
    const io = b.graph.io;

    // Collect module install steps (barrier: every test may load any module).
    var installs: std.ArrayList(*std.Build.Step) = .empty;
    // The root package has no hash; a dependency has one.
    const root_pkg = b.pkg_hash.len == 0;

    // Integration modules: each test/integration/*.zig builds to <stem>.so
    // (<stem>.dylib on macOS). The Lua *drivers* now live under test/luatest/
    // and are run by the luatest runner (see below), not per-file by this build.
    // These scans run at configure time; declare the directories so a new or
    // removed file invalidates Zig's cached build configuration. Only a
    // directory that exists (declaring a missing one fails the configuration,
    // and the purity sandbox, test/purity_negative.sh, copies none of them),
    // and only when this package is the one being built: Zig 0.17.1 fails the
    // configuration of a project that depends on this package when a
    // dependency declares a directory (examples/consumer shows it).
    var dir = b.root.openDir(io, "test/integration", .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (root_pkg) b.dependOnDirectoryContents(b.path("test/integration"));
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".zig")) {
            const stem = entry.name[0 .. entry.name.len - 4];
            installs.append(b.allocator, soFromZig(b, mods, target, optimize, b.fmt("test/integration/{s}", .{entry.name}), stem)) catch @panic("OOM");
        }
    }

    // Example modules: examples/<name>/<name>.zig -> <name>.so (loadable
    // artifacts). examples/consumer has no consumer.zig and is skipped here;
    // it is a separate project, built by the `consumer` step.
    var ex = b.root.openDir(io, "examples", .{ .iterate = true }) catch null;
    if (ex) |*exdir| {
        defer exdir.close(io);
        if (root_pkg) b.dependOnDirectoryContents(b.path("examples"));
        var exit = exdir.iterate();
        while (exit.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = b.dupe(entry.name);
            const src = b.fmt("examples/{s}/{s}.zig", .{ name, name });
            if (root_pkg) b.dependOnDirectoryContents(b.path(b.fmt("examples/{s}", .{name})));
            if (b.root.access(io, src, .{})) |_| {
                installs.append(b.allocator, soFromZig(b, mods, target, optimize, src, name)) catch @panic("OOM");
            } else |_| {}
        }
    }

    // Client harness exes: each test/client/*.zig builds to a STANDALONE
    // executable importing `tarantool-client` (+ msgpack/tarantool-proto for arg
    // encoding), installed to zig-out/bin. These are pure clients — no Tarantool
    // symbols — so linking succeeding is the module-purity proof. The
    // luatest `client` group drives them via io.popen against a live server, so
    // the suite run below must wait on their installs like the module .so's.
    var cdir = b.root.openDir(io, "test/client", .{ .iterate = true }) catch null;
    if (cdir) |*d| {
        defer d.close(io);
        if (root_pkg) b.dependOnDirectoryContents(b.path("test/client"));
        var cit = d.iterate();
        while (cit.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".zig")) {
                const stem = entry.name[0 .. entry.name.len - 4];
                installs.append(b.allocator, exeFromZig(b, mods, target, optimize, b.fmt("test/client/{s}", .{entry.name}), stem)) catch @panic("OOM");
            }
        }
    }

    // Run the whole luatest suite once, after every module .so is installed.
    // The runner process never calls box.cfg (each group starts its own
    // luatest.Server), so a single `luatest test/luatest/` invocation works.
    // LUA_PATH carries test/luatest/?.lua so `require('helper')` resolves; the
    // step fails loudly (pointing at ./deps.sh) when .rocks/bin/luatest is
    // absent, since installing it needs network + tt — neither in build.zig's
    // world.
    const run = b.addSystemCommand(&.{
        "sh", "-c",
        \\if [ ! -x ./.rocks/bin/luatest ]; then
        \\  echo "luatest not found at ./.rocks/bin/luatest — run ./deps.sh first" >&2
        \\  exit 1
        \\fi
        \\export LUA_PATH="./test/luatest/?.lua;;$LUA_PATH"
        \\exec ./.rocks/bin/luatest test/luatest/
        ,
    });
    run.setCwd(b.path("."));
    run.has_side_effects = true; // always run the suite; not a cacheable artifact
    for (installs.items) |s| {
        run.step.dependOn(s);
        modules_step.dependOn(s);
    }
    integration_step.dependOn(&run.step);
}

/// Compile a single Zig source (importing `tarantool`) into a Tarantool-loadable
/// module through the public `addModule` path and return its install step.
fn soFromZig(
    b: *std.Build,
    mods: Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_path: []const u8,
    stem: []const u8,
) *std.Build.Step {
    const lib = addModuleWith(b, mods, .{
        .name = b.dupe(stem),
        .root_source_file = b.path(src_path),
        .target = target,
        .optimize = optimize,
    });
    lib.use_llvm = force_llvm;
    return &addInstallModule(b, lib).step;
}

/// Compile a single `test/client/*.zig` source (importing `tarantool-client`,
/// plus msgpack/tarantool-proto for arg encoding) into a standalone executable
/// installed to `zig-out/bin/<stem>`, and return its install step. No host
/// (`box_*`) symbols exist for these clients, so a clean link is the proof the
/// client module graph stayed pure.
fn exeFromZig(
    b: *std.Build,
    mods: Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_path: []const u8,
    stem: []const u8,
) *std.Build.Step {
    const exe = addExecutableWith(b, mods, .{
        .name = b.dupe(stem),
        .root_source_file = b.path(src_path),
        .target = target,
        .optimize = optimize,
    });
    exe.use_llvm = force_llvm;
    return &b.addInstallArtifact(exe, .{}).step;
}

/// Run a unit-test binary as part of `step` — directly, or under kcov when
/// `-Dcoverage=<dir>` is set (report in <dir>/unit-<name>, src/ lines only).
fn addTestRun(b: *std.Build, step: *std.Build.Step, t: *std.Build.Step.Compile, coverage_dir: ?[]const u8) void {
    const dir = coverage_dir orelse {
        step.dependOn(&b.addRunArtifact(t).step);
        return;
    };
    const run = b.addSystemCommand(&.{
        "kcov",
        "--include-pattern=/src/",
        b.fmt("{s}/unit-{s}", .{ dir, t.name }),
    });
    run.addArtifactArg(t);
    run.has_side_effects = true;
    step.dependOn(&run.step);
}
