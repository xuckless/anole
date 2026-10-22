//! zlib-ng 2.3.3 in zlib-compat mode (ZLIB_COMPAT: the classic zlib API and
//! symbol names), with every SIMD kernel for the target arch compiled and
//! picked at run time by zlib-ng's own functable/cpu_features dispatch,
//! exactly like its CMake build with WITH_RUNTIME_CPU_DETECTION=ON.
//!
//! Provenance: source lists, per-file -m flags and defines transcribed from
//! zlib-ng 2.3.3 CMakeLists.txt and cmake/detect-intrinsics.cmake (Zlib licence).
//!
//! `module()` gives Zig bindings of zlib.h (translate-c, with ZLIB_CONST) for
//! lalinsky/zlib.zig's `std.Io` wrapper, which dusty uses for gzip/deflate.
const std = @import("std");

const core: []const []const u8 = &.{
    "adler32.c",       "compress.c",           "crc32.c",                       "crc32_braid_comb.c",
    "deflate.c",       "deflate_fast.c",       "deflate_huff.c",                "deflate_medium.c",
    "deflate_quick.c", "deflate_rle.c",        "deflate_slow.c",                "deflate_stored.c",
    "functable.c",     "infback.c",            "inflate.c",                     "inftrees.c",
    "insert_string.c", "insert_string_roll.c", "trees.c",                       "uncompr.c",
    "zutil.c",         "cpu_features.c",       "arch/generic/crc32_chorba_c.c",
    // ZLIB_COMPAT forces WITH_GZFILEOP in CMake.
    "gzlib.c",
    "gzread.c",        "gzwrite.c",
};

/// CMake's ZLIB_ALL_FALLBACK_SRCS (used with WITH_ALL_FALLBACKS, i.e. every arch but x86_64).
const all_fallbacks: []const []const u8 = &.{
    "arch/generic/adler32_c.c",    "arch/generic/adler32_fold_c.c", "arch/generic/chunkset_c.c",
    "arch/generic/compare256_c.c", "arch/generic/crc32_braid_c.c",  "arch/generic/crc32_fold_c.c",
    "arch/generic/slide_hash_c.c",
};

/// x86_64 always has SSE2, so the SSE2 kernels stand in for the rest
/// (compare256_c is skipped because HAVE_BUILTIN_CTZ is set).
const x86_64_fallbacks: []const []const u8 = &.{
    "arch/generic/adler32_c.c",     "arch/generic/adler32_fold_c.c",
    "arch/generic/crc32_braid_c.c", "arch/generic/crc32_fold_c.c",
};

/// `features` are clang target features. They go in as `-Xclang -target-feature
/// -Xclang +x` because Zig passes the target's full feature list to clang
/// explicitly, which silently overrides per-file `-mavx2`-style flags.
const Group = struct { files: []const []const u8, features: []const []const u8 };

const x86_groups = [_]Group{
    .{ .files = &.{"arch/x86/x86_features.c"}, .features = &.{"xsave"} },
    .{ .files = &.{ "arch/x86/chunkset_sse2.c", "arch/x86/chorba_sse2.c", "arch/x86/compare256_sse2.c", "arch/x86/slide_hash_sse2.c" }, .features = &.{} },
    .{ .files = &.{ "arch/x86/adler32_ssse3.c", "arch/x86/chunkset_ssse3.c" }, .features = &.{"ssse3"} },
    .{ .files = &.{"arch/x86/chorba_sse41.c"}, .features = &.{"sse4.1"} },
    .{ .files = &.{"arch/x86/adler32_sse42.c"}, .features = &.{"sse4.2"} },
    .{ .files = &.{"arch/x86/crc32_pclmulqdq.c"}, .features = &.{ "sse4.2", "pclmul" } },
    .{ .files = &.{ "arch/x86/slide_hash_avx2.c", "arch/x86/chunkset_avx2.c", "arch/x86/compare256_avx2.c", "arch/x86/adler32_avx2.c" }, .features = &.{ "avx2", "bmi2" } },
    .{ .files = &.{ "arch/x86/adler32_avx512.c", "arch/x86/chunkset_avx512.c", "arch/x86/compare256_avx512.c" }, .features = &.{ "avx512f", "avx512dq", "avx512bw", "avx512vl", "bmi2" } },
    .{ .files = &.{"arch/x86/adler32_avx512_vnni.c"}, .features = &.{ "avx512f", "avx512dq", "avx512bw", "avx512vl", "avx512vnni", "bmi2" } },
    .{ .files = &.{"arch/x86/crc32_vpclmulqdq.c"}, .features = &.{ "pclmul", "vpclmulqdq", "avx512f", "avx512dq", "avx512bw", "avx512vl", "bmi2" } },
};
const x86_defines = [_][]const u8{
    "X86_FEATURES",   "HAVE_CPUID_GNU",     "X86_HAVE_XSAVE_INTRIN", "X86_SSE2", "X86_SSSE3",
    "X86_SSE41",      "X86_SSE42",          "X86_PCLMULQDQ_CRC",     "X86_AVX2", "X86_AVX512",
    "X86_AVX512VNNI", "X86_VPCLMULQDQ_CRC",
};

const aarch64_groups = [_]Group{
    .{ .files = &.{"arch/arm/arm_features.c"}, .features = &.{} },
    .{ .files = &.{"arch/arm/crc32_armv8.c"}, .features = &.{"crc"} },
    .{ .files = &.{ "arch/arm/adler32_neon.c", "arch/arm/chunkset_neon.c", "arch/arm/compare256_neon.c", "arch/arm/slide_hash_neon.c" }, .features = &.{"neon"} },
};
const aarch64_defines = [_][]const u8{
    "ARM_FEATURES", "HAVE_ARM_ACLE_H", "ARM_CRC32", "ARM_CRC32_INTRIN", "ARM_NEON", "ARM_NEON_HASLD4",
};

fn featureFlags(b: *std.Build, base: []const []const u8, features: []const []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, base) catch @panic("OOM");
    for (features) |f| list.appendSlice(b.allocator, &.{ "-Xclang", "-target-feature", "-Xclang", b.fmt("+{s}", .{f}) }) catch @panic("OOM");
    return list.items;
}

fn generatedHeaders(b: *std.Build, upstream: *std.Build.Dependency) *std.Build.Step.WriteFile {
    const wf = b.addWriteFiles();
    // zlib.h / gzread_mangle.h: @ZLIB_SYMBOL_PREFIX@ -> "" (no prefix).
    inline for (.{ "zlib.h", "gzread_mangle.h" }) |name| {
        const h = b.addConfigHeader(.{
            .style = .{ .autoconf_at = upstream.path(name ++ ".in") },
            .include_path = name,
        }, .{ .ZLIB_SYMBOL_PREFIX = "" });
        _ = wf.addCopyFile(h.getOutputFile(), name);
    }
    // No prefix: CMake copies zlib_name_mangling.h.empty.
    _ = wf.addCopyFile(upstream.path("zlib_name_mangling.h.empty"), "zlib_name_mangling.h");
    // zconf.h: CMake/configure rewrite "#ifdef HAVE_UNISTD_H" to "#if 1".
    // build.zig can't read package files in 0.17, so predefine the macro that
    // line would set and include the template verbatim.
    _ = wf.addCopyFile(upstream.path("zconf.h.in"), "zconf.h.in");
    _ = wf.add("zconf.h",
        \\/* Generated by Anole: zconf.h.in with HAVE_UNISTD_H on, as CMake does. */
        \\#ifndef Z_HAVE_UNISTD_H
        \\#  define Z_HAVE_UNISTD_H
        \\#endif
        \\#include "zconf.h.in"
        \\
    );
    return wf;
}

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "z",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    const m = lib.root_module;
    const t = target.result;

    for ([_][]const u8{
        "ZLIB_COMPAT",                 "WITH_GZFILEOP",          "WITH_OPTIM",
        "HAVE_BUILTIN_CTZ",            "HAVE_BUILTIN_CTZLL",     "HAVE_ATTRIBUTE_ALIGNED",
        "HAVE_BUILTIN_ASSUME_ALIGNED", "HAVE_VISIBILITY_HIDDEN", "HAVE_VISIBILITY_INTERNAL",
    }) |d| m.addCMacro(d, "1");
    switch (t.os.tag) {
        .linux => {
            m.addCMacro("_LARGEFILE64_SOURCE", "1");
            m.addCMacro("__USE_LARGEFILE64", "1");
            m.addCMacro("HAVE_SYS_AUXV_H", "1");
            m.addCMacro("HAVE_LINUX_AUXVEC_H", "1");
        },
        .macos, .windows => {},
        else => @panic("zlib-ng: unsupported target OS (Anole supports Linux, macOS and Windows)"),
    }

    const hdrs = generatedHeaders(b, upstream);
    m.addIncludePath(hdrs.getDirectory());
    m.addIncludePath(upstream.path(""));
    const base_flags: []const []const u8 = &.{"-std=c11"};
    m.addCSourceFiles(.{ .root = upstream.path(""), .files = core, .flags = base_flags });

    const groups: []const Group, const defines: []const []const u8, const fallbacks = switch (t.cpu.arch) {
        .x86_64 => .{ &x86_groups, &x86_defines, x86_64_fallbacks },
        .aarch64 => blk: {
            m.addCMacro("WITH_ALL_FALLBACKS", "1");
            if (t.os.tag == .linux) m.addCMacro("ARM_AUXV_HAS_CRC32", "1");
            break :blk .{ &aarch64_groups, &aarch64_defines, all_fallbacks };
        },
        else => @panic("zlib-ng: unsupported CPU (Anole supports x86_64 and aarch64)"),
    };
    for (defines) |d| m.addCMacro(d, "1");
    m.addCSourceFiles(.{ .root = upstream.path(""), .files = fallbacks, .flags = base_flags });
    for (groups) |g| m.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = g.files,
        .flags = featureFlags(b, base_flags, g.features),
    });

    lib.installHeader(hdrs.getDirectory().path(b, "zlib.h"), "zlib.h");
    lib.installHeader(hdrs.getDirectory().path(b, "zconf.h"), "zconf.h");
    lib.installHeader(hdrs.getDirectory().path(b, "zlib_name_mangling.h"), "zlib_name_mangling.h");
    lib.installHeader(hdrs.getDirectory().path(b, "zconf.h.in"), "zconf.h.in");
    return lib;
}

/// Bindings of zlib.h for lalinsky/zlib.zig (`@import("c")`), linking `lib`.
/// The headers come from `lib`'s installed ones.
pub fn module(
    b: *std.Build,
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const t: Translator = .init(translate_c, .{
        .name = "zlib",
        .c_source_file = b.addWriteFiles().add("zlib_wrapper.h",
            \\// ZLIB_CONST: next_in is a pointer to const, as zlib.zig expects.
            \\#define ZLIB_CONST 1
            \\#include <zlib.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(lib.getEmittedIncludeTree());
    t.mod.linkLibrary(lib);
    return t.mod;
}
