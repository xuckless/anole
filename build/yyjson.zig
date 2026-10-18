//! ibireme/yyjson 0.13.0 (release tarball, MIT): one C file, built as is.
const std = @import("std");

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "yyjson",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addCSourceFiles(.{ .root = upstream.path("src"), .files = &.{"yyjson.c"}, .flags = &.{"-std=c99"} });
    lib.installHeader(upstream.path("src/yyjson.h"), "yyjson.h");
    return lib;
}

/// Bindings of yyjson.h, linking `lib`.
pub fn module(
    b: *std.Build,
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
    lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const t: Translator = .init(translate_c, .{
        .name = "yyjson",
        .c_source_file = b.addWriteFiles().add("yyjson_wrapper.h", "#include <yyjson.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("src"));
    t.mod.linkLibrary(lib);
    return t.mod;
}
