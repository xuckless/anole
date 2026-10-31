//! ebiggers/libdeflate 1.26 (release tag tarball, MIT): the compressor only,
//! for buffered gzip responses (`-Dlibdeflate`). zlib-ng stays for streamed
//! bodies, decompression and WebSocket permessage-deflate.
//!
//! Provenance: the source list is nilo's (nevindra/nilo build.zig
//! `libdeflateFor` @ d3ab2f3, MIT, Copyright (c) 2026 Nevindra): the
//! compressor, gzip's wrapper, CRC-32 and the CPU feature detection; no
//! decompressor, no zlib or raw-deflate wrappers. One difference: nilo links
//! no libc, so it builds with `FREESTANDING` and leaves `lib/utils.c` out,
//! whose freestanding `memcpy`/`memset` are weak byte loops that won the link
//! for the whole program. Anole links libc, so `utils.c` is built as is
//! (its allocator defaults are libc's `malloc`/`free`, and it defines no
//! `memcpy`), and `FREESTANDING` stays off.
const std = @import("std");

const sources: []const []const u8 = &.{
    "deflate_compress.c",
    "gzip_compress.c",
    "crc32.c",
    "utils.c",
    "x86/cpu_features.c",
    "arm/cpu_features.c",
};

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "deflate",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addIncludePath(upstream.path("."));
    lib.root_module.addCSourceFiles(.{ .root = upstream.path("lib"), .files = sources, .flags = &.{"-std=c99"} });
    lib.installHeader(upstream.path("libdeflate.h"), "libdeflate.h");
    return lib;
}

/// Bindings of libdeflate.h, linking `lib`.
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
        .name = "libdeflate",
        .c_source_file = b.addWriteFiles().add("libdeflate_wrapper.h", "#include <libdeflate.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("."));
    t.mod.linkLibrary(lib);
    return t.mod;
}
