//! redis/hiredis 1.5.0 (release tarball, BSD-3-Clause). Anole uses its RESP
//! reader only (src/redis writes the commands); the socket I/O is Anole's,
//! on std.Io. net.c and async.c are compiled because hiredis.c refers to them
//! (async.c includes dict.c).
const std = @import("std");

const sources: []const []const u8 = &.{ "alloc.c", "async.c", "hiredis.c", "net.c", "read.c", "sds.c" };

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "hiredis",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addCSourceFiles(.{ .root = upstream.path("."), .files = sources, .flags = &.{ "-std=c99", "-D_GNU_SOURCE" } });
    if (target.result.os.tag == .windows) {
        // net.c's socket calls go through hiredis's Winsock shims.
        lib.root_module.addCSourceFiles(.{ .root = upstream.path("."), .files = &.{"sockcompat.c"}, .flags = &.{"-std=c99"} });
        lib.root_module.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
    }
    inline for (.{ "hiredis.h", "read.h", "sds.h", "alloc.h" }) |h| lib.installHeader(upstream.path(h), "hiredis/" ++ h);
    return lib;
}

/// Bindings of hiredis.h, linking `lib`.
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
        .name = "hiredis",
        .c_source_file = b.addWriteFiles().add("hiredis_wrapper.h", "#include <hiredis.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("."));
    t.mod.linkLibrary(lib);
    return t.mod;
}
