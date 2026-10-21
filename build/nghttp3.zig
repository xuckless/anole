//! nghttp3 (HTTP/3 + QPACK, MIT) built from Anole's fork (xuckless/nghttp3, branch
//! `anole`): the v1.18.0 tag plus, as in the release tarball,
//! lib/includes/nghttp3/version.h and the vendored lib/sfparse, and
//! nghttp3_conn_add_extra_setting (SETTINGS for WebTransport). The GitHub archive of
//! the pinned commit is a lazy dependency.
//!
//! The source list and macro set are adapted from kingwill101/server_native (MIT),
//! zig/protocol_sources.zig and zig/protocol_dependencies.zig. Differences from
//! server_native: no generated version header (the tarball has one), no HAVE_CONFIG_H,
//! and per-OS HAVE_* macros instead of one POSIX set.
const std = @import("std");

/// lib/*.c from nghttp3 1.18.0 lib/CMakeLists.txt (31 files) + vendored sfparse.
pub const sources = [_][]const u8{
    "nghttp3_rcbuf.c",
    "nghttp3_mem.c",
    "nghttp3_str.c",
    "nghttp3_conv.c",
    "nghttp3_buf.c",
    "nghttp3_ringbuf.c",
    "nghttp3_pq.c",
    "nghttp3_map.c",
    "nghttp3_ksl.c",
    "nghttp3_qpack.c",
    "nghttp3_qpack_huffman.c",
    "nghttp3_qpack_huffman_data.c",
    "nghttp3_err.c",
    "nghttp3_debug.c",
    "nghttp3_conn.c",
    "nghttp3_stream.c",
    "nghttp3_frame.c",
    "nghttp3_tnode.c",
    "nghttp3_vec.c",
    "nghttp3_gaptr.c",
    "nghttp3_idtr.c",
    "nghttp3_range.c",
    "nghttp3_http.c",
    "nghttp3_version.c",
    "nghttp3_balloc.c",
    "nghttp3_opl.c",
    "nghttp3_objalloc.c",
    "nghttp3_unreachable.c",
    "nghttp3_settings.c",
    "nghttp3_callbacks.c",
    "nghttp3_ratelim.c",
    "sfparse/sfparse.c",
};

const c_flags = [_][]const u8{"-std=c11"};

/// Builds libnghttp3.a. `upstream` is the lazy `nghttp3` dependency (the fork's tree).
pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "nghttp3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    const mod = lib.root_module;
    configureC(mod, target);
    mod.addCMacro("BUILDING_NGHTTP3", "1");
    mod.addCMacro("NGHTTP3_STATICLIB", "1");
    mod.addIncludePath(upstream.path("lib/includes"));
    mod.addIncludePath(upstream.path("lib"));
    mod.addCSourceFiles(.{ .root = upstream.path("lib"), .files = &sources, .flags = &c_flags });
    lib.installHeadersDirectory(upstream.path("lib/includes/nghttp3"), "nghttp3", .{
        .include_extensions = &.{".h"},
    });
    return lib;
}

/// Zig bindings for nghttp3.h via the official translate-c package (branch zig-0.17.x).
/// `Translator` is `b.lazyImport(@This(), "translate_c").?.Translator` from build.zig.
/// translate-c turns the `*_versioned` function-like macros into `anytype` inline fns;
/// src/h3/nghttp3.zig wraps them with typed functions that pin the struct versions.
pub fn module(
    b: *std.Build,
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
    nghttp3: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const wrapper = b.addWriteFiles().add("nghttp3_c.h",
        \\#include <nghttp3/nghttp3.h>
        \\
    );
    const t: Translator = .init(translate_c, .{
        .name = "nghttp3_c",
        .c_source_file = wrapper,
        .target = target,
        .optimize = optimize,
    });
    t.defineCMacro("NGHTTP3_STATICLIB", "1");
    t.addIncludePath(upstream.path("lib/includes"));
    t.mod.linkLibrary(nghttp3);
    return t.mod;
}

/// Per-OS replacements for config.h (nghttp3 cmakeconfig.h.in); only macros the sources test.
pub fn configureC(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const os = target.result.os.tag;
    switch (os) {
        .linux => {
            mod.addCMacro("_DEFAULT_SOURCE", "1");
            inline for (.{
                "HAVE_ARPA_INET_H",
                "HAVE_NETINET_IN_H",
                "HAVE_UNISTD_H",
                "HAVE_ENDIAN_H",
                "HAVE_BYTESWAP_H",
                "HAVE_DECL_BE64TOH",
                "HAVE_DECL_BSWAP_64",
            }) |name| mod.addCMacro(name, "1");
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            inline for (.{
                "HAVE_ARPA_INET_H",
                "HAVE_NETINET_IN_H",
                "HAVE_UNISTD_H",
            }) |name| mod.addCMacro(name, "1");
            mod.addCMacro("HAVE_DECL_BE64TOH", "0");
            mod.addCMacro("HAVE_DECL_BSWAP_64", "0");
        },
        .windows => {
            // nghttp3's Windows paths test WIN32 (see ngtcp2.zig).
            mod.addCMacro("WIN32", "1");
            mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
            mod.addCMacro("HAVE_DECL_BE64TOH", "0");
            mod.addCMacro("HAVE_DECL_BSWAP_64", "0");
        },
        else => @panic("nghttp3: unsupported target OS (Anole supports Linux, macOS and Windows)"),
    }
    if (target.result.cpu.arch.endian() == .big) mod.addCMacro("WORDS_BIGENDIAN", "1");
}

/// nghttp2 (lib/sfparse.c) and nghttp3 (lib/sfparse/sfparse.c) each vendor sfparse and
/// export the same global `sfparse_*` symbols. When both libraries are linked, the
/// linker keeps one archive member and both libraries run that copy. That is safe only
/// while the two copies are identical, so the build stops when a pin bump makes them
/// differ. The fix then is to rename one copy's symbols or to build one shared sfparse.
pub fn checkSharedSfparse(b: *std.Build, nghttp2_up: *std.Build.Dependency, nghttp3_up: *std.Build.Dependency) void {
    const pairs = [_][2][]const u8{
        .{ "lib/sfparse.c", "lib/sfparse/sfparse.c" },
        .{ "lib/sfparse.h", "lib/sfparse/sfparse.h" },
    };
    for (pairs) |pair| {
        const a = readPkgFile(b, nghttp2_up, pair[0]);
        const c = readPkgFile(b, nghttp3_up, pair[1]);
        if (!std.mem.eql(u8, a, c)) {
            std.debug.print(
                "error: nghttp2's {s} and nghttp3's {s} differ; both export the same sfparse_* symbols, " ++
                    "so linking both would run one library against the other's sfparse. Bump the pins together " ++
                    "or give one copy its own symbol prefix.\n",
                .{ pair[0], pair[1] },
            );
            std.process.exit(1);
        }
    }
}

fn readPkgFile(b: *std.Build, up: *std.Build.Dependency, path: []const u8) []const u8 {
    return up.builder.root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |err|
        std.debug.panic("cannot read {s} from a C dependency: {t}", .{ path, err });
}
