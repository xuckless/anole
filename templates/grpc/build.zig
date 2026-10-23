const std = @import("std");
const anole = @import("anole");

pub fn build(b: *std.Build) void {
    const app = anole.addApp(b, .{
        .name = "{{name}}",
        .root_source_file = b.path("src/main.zig"),
        .profile = .full,
        .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }},
    });

    // `zig build test`: src/main_test.zig serves the same routes in memory.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main_test.zig"),
        .target = app.exe.root_module.resolved_target,
        .optimize = app.exe.root_module.optimize,
        .imports = &.{
            .{ .name = "anole", .module = app.anole.module("anole") },
            .{ .name = "app", .module = app.exe.root_module },
        },
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
