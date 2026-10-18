//! ngtcp2 1.25.0 (QUIC transport, MIT) built from Anole's fork (xuckless/ngtcp2,
//! branch `anole`: the v1.25.0 tag, the release's generated
//! lib/includes/ngtcp2/version.h, and a patch that keeps a server's fallback
//! connection ID across a migration right after a NAT rebinding), fetched as a
//! GitHub archive of the pinned commit (a lazy dependency), plus ngtcp2's
//! BoringSSL crypto helper (crypto/shared.c + crypto/boringssl/boringssl.c)
//! as its own static library.
//!
//! The source list and macro set are adapted from kingwill101/server_native (MIT),
//! zig/protocol_sources.zig and zig/protocol_dependencies.zig. Differences from
//! server_native: the fork (like the release tarball) has lib/includes/ngtcp2/version.h, so no
//! config header is generated; HAVE_CONFIG_H is never defined, so every config.h macro
//! that the sources test is set here per OS; and the crypto helper is a separate library
//! instead of being compiled into the consumer module.
//!
//! Anole change (integration): the crypto helper links the single BoringSSL library built by
//! build/boringssl.zig instead of allyourcodebase/boringssl's `ssl` + `crypto` artifacts.
const std = @import("std");

/// lib/*.c from ngtcp2 1.25.0 lib/CMakeLists.txt (46 files; no assembly, no generated code).
pub const sources = [_][]const u8{
    "ngtcp2_pkt.c",
    "ngtcp2_conv.c",
    "ngtcp2_str.c",
    "ngtcp2_vec.c",
    "ngtcp2_buf.c",
    "ngtcp2_conn.c",
    "ngtcp2_mem.c",
    "ngtcp2_pq.c",
    "ngtcp2_map.c",
    "ngtcp2_rob.c",
    "ngtcp2_ppe.c",
    "ngtcp2_crypto.c",
    "ngtcp2_err.c",
    "ngtcp2_range.c",
    "ngtcp2_acktr.c",
    "ngtcp2_rtb.c",
    "ngtcp2_frame_chain.c",
    "ngtcp2_strm.c",
    "ngtcp2_idtr.c",
    "ngtcp2_gaptr.c",
    "ngtcp2_ringbuf.c",
    "ngtcp2_log.c",
    "ngtcp2_qlog.c",
    "ngtcp2_cid.c",
    "ngtcp2_ksl.c",
    "ngtcp2_cc.c",
    "ngtcp2_bbr.c",
    "ngtcp2_addr.c",
    "ngtcp2_path.c",
    "ngtcp2_pv.c",
    "ngtcp2_pmtud.c",
    "ngtcp2_version.c",
    "ngtcp2_rst.c",
    "ngtcp2_wf.c",
    "ngtcp2_opl.c",
    "ngtcp2_balloc.c",
    "ngtcp2_objalloc.c",
    "ngtcp2_unreachable.c",
    "ngtcp2_transport_params.c",
    "ngtcp2_settings.c",
    "ngtcp2_callbacks.c",
    "ngtcp2_dcidtr.c",
    "ngtcp2_pcg.c",
    "ngtcp2_ratelim.c",
    "ngtcp2_conn_info.c",
    "ngtcp2_fmt.c",
};

/// crypto/boringssl/CMakeLists.txt: ngtcp2_crypto_boringssl_SOURCES.
pub const crypto_boringssl_sources = [_][]const u8{
    "boringssl/boringssl.c",
    "shared.c",
};

const c_flags = [_][]const u8{"-std=c11"};

/// Builds libngtcp2.a. `upstream` is the lazy `ngtcp2` dependency (the fork's tree).
/// Public headers (ngtcp2/ngtcp2.h, ngtcp2/version.h) are installed so `linkLibrary`
/// exposes them to dependents.
pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "ngtcp2",
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
    mod.addCMacro("BUILDING_NGTCP2", "1");
    mod.addCMacro("NGTCP2_STATICLIB", "1");
    mod.addIncludePath(upstream.path("lib/includes"));
    mod.addIncludePath(upstream.path("lib"));
    mod.addCSourceFiles(.{ .root = upstream.path("lib"), .files = &sources, .flags = &c_flags });
    lib.installHeadersDirectory(upstream.path("lib/includes/ngtcp2"), "ngtcp2", .{
        .include_extensions = &.{".h"},
    });
    return lib;
}

/// Builds libngtcp2_crypto_boringssl.a from crypto/shared.c + crypto/boringssl/boringssl.c.
/// It needs ngtcp2's private lib/ headers (ngtcp2_macro.h, ngtcp2_net.h) and BoringSSL's
/// public headers; it links `ngtcp2` and the combined BoringSSL library from
/// build/boringssl.zig (`boringssl_include` is that tree's `include/`).
pub fn cryptoBoringssl(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    ngtcp2: *std.Build.Step.Compile,
    boringssl: *std.Build.Step.Compile,
    boringssl_include: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "ngtcp2_crypto_boringssl",
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
    // crypto/boringssl/CMakeLists.txt: add_definitions(-DBUILDING_NGTCP2) + PUBLIC NGTCP2_STATICLIB.
    mod.addCMacro("BUILDING_NGTCP2", "1");
    mod.addCMacro("NGTCP2_STATICLIB", "1");
    mod.addIncludePath(upstream.path("lib/includes"));
    mod.addIncludePath(upstream.path("lib"));
    mod.addIncludePath(upstream.path("crypto/includes"));
    mod.addIncludePath(upstream.path("crypto"));
    mod.addIncludePath(boringssl_include);
    mod.addCSourceFiles(.{ .root = upstream.path("crypto"), .files = &crypto_boringssl_sources, .flags = &c_flags });
    mod.linkLibrary(ngtcp2);
    mod.linkLibrary(boringssl);
    lib.installHeadersDirectory(upstream.path("crypto/includes/ngtcp2"), "ngtcp2", .{
        .include_extensions = &.{ "ngtcp2_crypto.h", "ngtcp2_crypto_boringssl.h" },
    });
    return lib;
}

/// Zig bindings for ngtcp2.h + ngtcp2_crypto.h + ngtcp2_crypto_boringssl.h (which pulls in
/// BoringSSL's <openssl/ssl.h>), produced by the official translate-c package
/// (codeberg.org/ziglang/translate-c, branch zig-0.17.x). The module links `ngtcp2` and
/// `crypto_lib`, so importing it links the C code too.
///
/// translate-c turns the function-like macros that splice a *_VERSION constant into a
/// `*_versioned` call into `anytype` inline fns; src/h3/ngtcp2.zig wraps them with typed
/// functions that pin the argument types and the struct versions.
pub fn module(
    b: *std.Build,
    /// `b.lazyImport(@This(), "translate_c").?.Translator`, resolved by build.zig because
    /// lazyImport only works from the build.zig file that declares the dependency.
    comptime Translator: type,
    translate_c: *std.Build.Dependency,
    upstream: *std.Build.Dependency,
    ngtcp2: *std.Build.Step.Compile,
    crypto_lib: *std.Build.Step.Compile,
    boringssl_include: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const wrapper = b.addWriteFiles().add("ngtcp2_c.h",
        \\#include <ngtcp2/ngtcp2.h>
        \\#include <ngtcp2/ngtcp2_crypto.h>
        \\#include <ngtcp2/ngtcp2_crypto_boringssl.h>
        \\#include <openssl/pem.h>
        \\
    );
    const t: Translator = .init(translate_c, .{
        .name = "ngtcp2_c",
        .c_source_file = wrapper,
        .target = target,
        .optimize = optimize,
    });
    t.defineCMacro("NGTCP2_STATICLIB", "1");
    t.addIncludePath(upstream.path("lib/includes"));
    t.addIncludePath(upstream.path("crypto/includes"));
    t.addIncludePath(boringssl_include);
    t.mod.linkLibrary(ngtcp2);
    t.mod.linkLibrary(crypto_lib);
    return t.mod;
}

/// Per-OS replacements for the config.h that ngtcp2's CMake/autotools would generate
/// (cmakeconfig.h.in). Only the macros the lib/ and crypto/ sources actually test are set.
pub fn configureC(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const os = target.result.os.tag;
    switch (os) {
        .linux => {
            // -std=c11 hides explicit_bzero/be64toh/bswap_64 in glibc and musl without this.
            mod.addCMacro("_DEFAULT_SOURCE", "1");
            inline for (.{
                "HAVE_ARPA_INET_H",
                "HAVE_NETINET_IN_H",
                "HAVE_UNISTD_H",
                "HAVE_ENDIAN_H",
                "HAVE_BYTESWAP_H",
                "HAVE_DECL_BE64TOH",
                "HAVE_DECL_BSWAP_64",
                "HAVE_EXPLICIT_BZERO",
            }) |name| mod.addCMacro(name, "1");
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Darwin: no endian.h/byteswap.h; ngtcp2_net.h uses libkern/OSByteOrder.h under
            // __APPLE__. memset_s is C11 Annex K, declared when __STDC_WANT_LIB_EXT1__ is set.
            mod.addCMacro("__STDC_WANT_LIB_EXT1__", "1");
            inline for (.{
                "HAVE_ARPA_INET_H",
                "HAVE_NETINET_IN_H",
                "HAVE_UNISTD_H",
                "HAVE_MEMSET_S",
            }) |name| mod.addCMacro(name, "1");
            mod.addCMacro("HAVE_DECL_BE64TOH", "0");
            mod.addCMacro("HAVE_DECL_BSWAP_64", "0");
        },
        else => @panic("ngtcp2: unsupported target OS (Anole supports Linux and macOS)"),
    }
    if (target.result.cpu.arch.endian() == .big) mod.addCMacro("WORDS_BIGENDIAN", "1");
}
