//! lz4 1.10.0 (release tarball, BSD-2 library part): lib/lz4.c, lz4frame.c,
//! lz4hc.c and xxhash.c. Kafka's record batches use the LZ4 *frame* format,
//! so Anole binds lz4frame.h (and lz4.h/lz4hc.h underneath it). Behind
//! -Dkafka only.
const std = @import("std");

const sources: []const []const u8 = &.{ "lz4.c", "lz4frame.c", "lz4hc.c", "xxhash.c" };

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "lz4",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    const m = lib.root_module;
    switch (target.result.os.tag) {
        .linux, .macos, .windows => {},
        else => @panic("lz4: unsupported target OS (Anole supports Linux, macOS and Windows)"),
    }
    m.addCSourceFiles(.{ .root = upstream.path("lib"), .files = sources, .flags = &.{"-std=c99"} });
    inline for (.{ "lz4.h", "lz4hc.h", "lz4frame.h" }) |h| lib.installHeader(upstream.path("lib/" ++ h), h);
    return lib;
}

/// Bindings of lz4.h, lz4hc.h and lz4frame.h, linking `lib`.
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
        .name = "lz4",
        .c_source_file = b.addWriteFiles().add("lz4_wrapper.h",
            \\#include <lz4.h>
            \\#include <lz4hc.h>
            \\#include <lz4frame.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("lib"));
    t.mod.linkLibrary(lib);
    return t.mod;
}
