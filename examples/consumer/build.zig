const std = @import("std");
const tarantool = @import("tarantool");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-out/lib/hello.so (hello.dylib on macOS): require('hello') or
    // box.schema.func.create('hello.add', {language = 'C'}).
    const hello = tarantool.addModule(b, .{
        .name = "hello",
        .root_source_file = b.path("src/hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    tarantool.installModule(b, hello);

    // zig-out/bin/hello-client: a standalone program over tarantool-client.
    const cli = tarantool.addExecutable(b, .{
        .name = "hello-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(cli);
}
