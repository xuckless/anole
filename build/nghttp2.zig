//! nghttp2 1.70.0 built from Anole's fork (xuckless/nghttp2, branch `anole`:
//! the v1.70.0 tag plus an RFC 9113 strictness patch), fetched as a GitHub
//! archive of the pinned commit (a lazy dependency).
//!
//! Provenance (all MIT):
//! - Per-OS defines: lalinsky/dusty build.zig @ d3cb485a644a18bee7e03b4a51577990455b23b3
//!   (the `use_http2` block). Windows branch dropped: Anole has no Windows support.
//! - Source list: mattrobenolt/etcd-zig build.zig @ 4becbeeaa7a17f727d4f26b2a34ac906a299c660,
//!   cross-checked against the 26 `lib/*.c` files in nghttp2-1.70.0.tar.xz.
//! - The fork commits the release's generated lib/includes/nghttp2/nghttp2ver.h,
//!   so, as with the release tarball, there is no configure step.
const std = @import("std");

pub const sources: []const []const u8 = &.{
    "nghttp2_alpn.c",
    "nghttp2_buf.c",
    "nghttp2_callbacks.c",
    "nghttp2_debug.c",
    "nghttp2_extpri.c",
    "nghttp2_frame.c",
    "nghttp2_hd.c",
    "nghttp2_hd_huffman.c",
    "nghttp2_hd_huffman_data.c",
    "nghttp2_helper.c",
    "nghttp2_http.c",
    "nghttp2_map.c",
    "nghttp2_mem.c",
    "nghttp2_option.c",
    "nghttp2_outbound_item.c",
    "nghttp2_pq.c",
    "nghttp2_priority_spec.c",
    "nghttp2_queue.c",
    "nghttp2_ratelim.c",
    "nghttp2_rcbuf.c",
    "nghttp2_session.c",
    "nghttp2_stream.c",
    "nghttp2_submit.c",
    "nghttp2_time.c",
    "nghttp2_version.c",
    "sfparse.c",
};

/// Public include directory (contains nghttp2/nghttp2.h and nghttp2/nghttp2ver.h).
pub fn includePath(upstream: *std.Build.Dependency) std.Build.LazyPath {
    return upstream.path("lib/includes");
}

pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "nghttp2",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // From dusty: a feature-test macro to un-hide POSIX/C99 declarations
    // (clock_gettime, vsnprintf) plus HAVE_* to select nghttp2's code paths.
    // A too-strict _POSIX_C_SOURCE hides vsnprintf on Darwin, hence
    // _DARWIN_C_SOURCE there and _GNU_SOURCE elsewhere.
    const c99 = "-std=c99";
    const staticlib = "-DNGHTTP2_STATICLIB";
    const have_posix = [_][]const u8{
        "-DHAVE_ARPA_INET_H=1",
        "-DHAVE_NETINET_IN_H=1",
        "-DHAVE_CLOCK_GETTIME=1",
        "-DHAVE_DECL_CLOCK_MONOTONIC=1",
    };
    const flags: []const []const u8 = switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => &([_][]const u8{ c99, staticlib, "-D_DARWIN_C_SOURCE" } ++ have_posix),
        .linux => &([_][]const u8{ c99, staticlib, "-D_GNU_SOURCE" } ++ have_posix),
        else => @panic("nghttp2: unsupported target OS (Anole supports Linux and macOS)"),
    };

    lib.root_module.addIncludePath(upstream.path("lib"));
    lib.root_module.addIncludePath(includePath(upstream));
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = sources,
        .flags = flags,
    });
    lib.installHeadersDirectory(includePath(upstream), "", .{});
    return lib;
}

/// Zig bindings for nghttp2.h via the official translate-c package
/// (codeberg.org/ziglang/translate-c, branch zig-0.17.x). The returned module
/// also links `lib`, so importing it is enough.
pub fn module(
    b: *std.Build,
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig because
    /// lazyImport only works from the build.zig file that declares the dependency.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
    lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const t: Translator = .init(translate_c, .{
        .name = "nghttp2",
        .c_source_file = b.addWriteFiles().add("nghttp2_wrapper.h",
            \\#define NGHTTP2_STATICLIB 1
            \\#include <nghttp2/nghttp2.h>
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(includePath(upstream));
    t.mod.linkLibrary(lib);
    return t.mod;
}
