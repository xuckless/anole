//! Builds BoringSSL (libcrypto + libssl, one static library) from a google/boringssl
//! source tree, driven by the tree's own gen/sources.json.
//!
//! Adapted from allyourcodebase/boringssl's build.zig
//! (https://github.com/allyourcodebase/boringssl, Copyright (c) Lukas Kastern, Zlib licence).
//! Altered: one combined library instead of bcm/crypto/ssl, no tests/tools/decrepit,
//! no nasm (Anole has no Windows), no patch step, and BoringSSL's own CMake/Bazel
//! flags (BORINGSSL_IMPLEMENTATION, -fno-strict-aliasing, -fno-common,
//! -fno-exceptions, -fno-rtti, -D_XOPEN_SOURCE=700 on Linux).
const std = @import("std");

const SourceList = struct {
    srcs: []const []const u8 = &.{},
    @"asm": []const []const u8 = &.{},
};

/// The parts of gen/sources.json this build reads.
const Sources = struct {
    bcm: SourceList,
    crypto: SourceList,
    ssl: SourceList,
};

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const t = target.result;
    if (t.os.tag == .windows) @panic("boringssl: Windows is not supported by Anole (no nasm)");

    const json = upstream.builder.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        "gen/sources.json",
        b.allocator,
        .unlimited,
    ) catch |err| std.debug.panic("boringssl: cannot read gen/sources.json: {t}", .{err});
    const sources = std.json.parseFromSliceLeaky(Sources, b.allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("boringssl: bad gen/sources.json: {t}", .{err});

    const lib = b.addLibrary(.{
        .name = "boringssl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // BoringSSL is C++ but built without the C++ runtime (no exceptions, no RTTI,
            // operator delete routed to OPENSSL_free); libc++ is needed for its headers.
            .link_libcpp = true,
        }),
    });

    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-DBORINGSSL_IMPLEMENTATION",
        "-fno-strict-aliasing",
        "-fno-common",
        "-fno-exceptions",
        "-fno-rtti",
    }) catch @panic("OOM");
    // glibc needs this for pthread_rwlock_t; it disables APIs on Apple and the BSDs.
    if (t.os.tag == .linux) cxx_flags.append(b.allocator, "-D_XOPEN_SOURCE=700") catch @panic("OOM");

    const root = upstream.path("");
    inline for (.{ "bcm", "crypto", "ssl" }) |part| {
        const list = @field(sources, part);
        var files: std.ArrayList([]const u8) = .empty;
        for (list.srcs) |src| {
            if (std.mem.endsWith(u8, src, ".inc")) continue; // textually included, not compiled
            files.append(b.allocator, src) catch @panic("OOM");
        }
        lib.root_module.addCSourceFiles(.{ .root = root, .files = files.items, .flags = cxx_flags.items });
        // Every .S file is guarded by #if on arch and object format, so all are passed.
        if (list.@"asm".len != 0)
            lib.root_module.addCSourceFiles(.{ .root = root, .files = list.@"asm", .flags = &.{"-DBORINGSSL_IMPLEMENTATION"} });
    }

    lib.root_module.addIncludePath(upstream.path("include"));
    lib.installHeadersDirectory(upstream.path("include"), "", .{});
    return lib;
}

/// Zig bindings for `header` (a stub that #includes the BoringSSL headers it needs),
/// produced by codeberg.org/ziglang/translate-c (branch zig-0.17.x). The returned module
/// also links `lib`, so importing it is enough.
pub fn module(
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig because
    /// lazyImport only works from the build.zig file that declares the dependency.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
    lib: *std.Build.Step.Compile,
    header: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const t: Translator = .init(translate_c, .{
        .name = "boringssl",
        .c_source_file = header,
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(upstream.path("include"));
    t.mod.linkLibrary(lib);
    return t.mod;
}
