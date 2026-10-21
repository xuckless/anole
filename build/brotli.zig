//! google/brotli 1.2.0 (release tarball, MIT): the C library's common,
//! encoder and decoder sources (c/common, c/enc, c/dec), static tables
//! built at compile time (BROTLI_STATIC_INIT_NONE, the default), no CLI and
//! no C++ lazy initializer (c/enc/static_init_lazy.cc).
//!
//! Anole sends `Content-Encoding: br` with the encoder. The decoder is only
//! called by tests (round trips), so the linker leaves it out of programs;
//! it is compiled with the rest so the bindings declare both.
//!
//! Source lists: what upstream's CMakeLists.txt globs (c/{common,dec,enc}/*.c).
const std = @import("std");

const common: []const []const u8 = &.{
    "common/constants.c",         "common/context.c",   "common/dictionary.c", "common/platform.c",
    "common/shared_dictionary.c", "common/transform.c",
};

const enc: []const []const u8 = &.{
    "enc/backward_references.c",        "enc/backward_references_hq.c", "enc/bit_cost.c",
    "enc/block_splitter.c",             "enc/brotli_bit_stream.c",      "enc/cluster.c",
    "enc/command.c",                    "enc/compound_dictionary.c",    "enc/compress_fragment.c",
    "enc/compress_fragment_two_pass.c", "enc/dictionary_hash.c",        "enc/encode.c",
    "enc/encoder_dict.c",               "enc/entropy_encode.c",         "enc/fast_log.c",
    "enc/histogram.c",                  "enc/literal_cost.c",           "enc/memory.c",
    "enc/metablock.c",                  "enc/static_dict.c",            "enc/static_dict_lut.c",
    "enc/static_init.c",                "enc/utf8_util.c",
};

const dec: []const []const u8 = &.{
    "dec/bit_reader.c", "dec/decode.c", "dec/huffman.c", "dec/prefix.c", "dec/state.c", "dec/static_init.c",
};

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "brotli",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    const m = lib.root_module;
    switch (target.result.os.tag) {
        .linux, .macos => {},
        else => @panic("brotli: unsupported target OS (Anole supports Linux and macOS)"),
    }
    m.addIncludePath(upstream.path("c/include"));
    inline for (.{ common, enc, dec }) |files| {
        m.addCSourceFiles(.{ .root = upstream.path("c"), .files = files, .flags = &.{"-std=c99"} });
    }
    lib.installHeadersDirectory(upstream.path("c/include/brotli"), "brotli", .{});
    return lib;
}

/// Bindings of brotli/encode.h and brotli/decode.h, linking `lib`.
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
        .name = "brotli",
        .c_source_file = b.addWriteFiles().add("brotli_wrapper.h",
            \\#include <brotli/encode.h>
            \\#include <brotli/decode.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("c/include"));
    t.mod.linkLibrary(lib);
    return t.mod;
}
