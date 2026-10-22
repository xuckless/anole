//! facebook/zstd 1.5.7 (release tarball), compression + decompression only:
//! no legacy formats, no dictionary builder, no deprecated zbuff, single-threaded.
//! On x86_64 the BMI2 Huffman decoder huf_decompress_amd64.S is assembled and
//! zstd's own DYNAMIC_BMI2 picks BMI2 paths at run time.
//!
//! Provenance: source lists and the asm rule from allyourcodebase/zstd
//! build.zig @ 4ccb01e (release 1.5.7-2, MIT).
const std = @import("std");

const sources: []const []const u8 = &.{
    "common/zstd_common.c",                "common/entropy_common.c",           "common/fse_decompress.c",
    "common/xxhash.c",                     "common/error_private.c",            "common/pool.c",
    "common/threading.c",                  "compress/fse_compress.c",           "compress/huf_compress.c",
    "compress/zstd_double_fast.c",         "compress/zstd_compress_literals.c", "compress/zstdmt_compress.c",
    "compress/zstd_compress_superblock.c", "compress/zstd_opt.c",               "compress/zstd_compress.c",
    "compress/zstd_compress_sequences.c",  "compress/hist.c",                   "compress/zstd_ldm.c",
    "compress/zstd_lazy.c",                "compress/zstd_preSplit.c",          "compress/zstd_fast.c",
    "decompress/zstd_decompress.c",        "decompress/huf_decompress.c",       "decompress/zstd_decompress_block.c",
    "decompress/zstd_ddict.c",
};

pub fn includePath(upstream: *std.Build.Dependency) std.Build.LazyPath {
    return upstream.path("lib");
}

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    const m = lib.root_module;
    switch (target.result.os.tag) {
        .linux, .macos, .windows => {},
        else => @panic("zstd: unsupported target OS (Anole supports Linux, macOS and Windows)"),
    }
    m.addCMacro("ZSTD_LEGACY_SUPPORT", "0");
    m.addCSourceFiles(.{ .root = upstream.path("lib"), .files = sources, .flags = &.{"-std=c99"} });
    // The assembly decoder is ELF/Mach-O only (zstd leaves it out on Windows).
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows) {
        m.addAssemblyFile(upstream.path("lib/decompress/huf_decompress_amd64.S"));
    } else {
        m.addCMacro("ZSTD_DISABLE_ASM", "1");
    }
    inline for (.{ "zstd.h", "zstd_errors.h" }) |h| lib.installHeader(upstream.path("lib/" ++ h), h);
    return lib;
}

/// Bindings of zstd.h, linking `lib`.
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
        .name = "zstd",
        .c_source_file = b.addWriteFiles().add("zstd_wrapper.h",
            \\// The advanced API (custom allocators, streaming parameters) that
            \\// dusty's zstd_io uses.
            \\#define ZSTD_STATIC_LINKING_ONLY 1
            \\#include <zstd.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(includePath(upstream));
    t.mod.linkLibrary(lib);
    return t.mod;
}
