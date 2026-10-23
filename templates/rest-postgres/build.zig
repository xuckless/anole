const std = @import("std");
const anole = @import("anole");

pub fn build(b: *std.Build) void {
    // The schema, for the tests (compose.yaml mounts the same file).
    const schema = b.createModule(.{ .root_source_file = b.path("db/schema.sql") });
    const app = anole.addApp(b, .{
        .name = "{{name}}",
        .root_source_file = b.path("src/main.zig"),
        .profile = .web,
        .imports = &.{.{ .name = "schema_sql", .module = schema }},
    });

    // `zig build test`: src/main_test.zig serves the same routes in memory.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main_test.zig"),
        .target = app.exe.root_module.resolved_target,
        .optimize = app.exe.root_module.optimize,
        .imports = &.{
            .{ .name = "anole", .module = app.anole.module("anole") },
            .{ .name = "app", .module = app.exe.root_module },
            .{ .name = "schema_sql", .module = schema },
        },
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
