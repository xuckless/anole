//! Anole build.
//!
//! Features are chosen with `-Dprofile=minimal|web|full` (default `full`) and
//! overridden one by one with `-Dtls=boringssl|none`, `-Dhttp2`, `-Dhttp3`,
//! `-Dgrpc`, `-Dwebsocket` and `-Dauth`. The result is exposed to Zig code as
//! the `build_options` module (re-exported as `anole.features`).
//!
//! Every C library is a lazy dependency in build.zig.zon and is requested only
//! when a feature that needs it is on, so `-Dprofile=minimal` fetches and
//! compiles no C library besides dusty's llhttp.
//!
//! Steps:
//!   test        unit tests + smoke tests of the enabled features
//!   test-flags  the test binary for every preset and edge combination, sharing
//!               one build of each C library (run when the target is native)
//!   hello       install examples/hello (also part of the default install step)
//!   run-hello   run examples/hello (`zig build run-hello -- 8080`)
const std = @import("std");
const builtin = @import("builtin");

const nghttp2_build = @import("build/nghttp2.zig");
const boringssl_build = @import("build/boringssl.zig");
const ngtcp2_build = @import("build/ngtcp2.zig");
const nghttp3_build = @import("build/nghttp3.zig");

/// This file's struct, for `b.lazyImport` (which must name the build.zig that declares the dependency).
const build_zig = @This();

comptime {
    // minimum_zig_version in build.zig.zon is advisory only, so enforce it here.
    // Any 0.17.x release passes; 0.17.0-dev builds may lack APIs used below, so
    // prereleases are rejected.
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 17 or v.pre != null) {
        @compileError("Anole requires a Zig 0.17.x release (not a dev build), but this is Zig " ++
            builtin.zig_version_string ++ ". Install Zig 0.17.0 from https://ziglang.org/download/");
    }
}

pub const Tls = enum { boringssl, none };
pub const Profile = enum { minimal, web, full };

pub const Features = struct {
    tls: Tls,
    http2: bool,
    http3: bool,
    grpc: bool,
    websocket: bool,
    auth: bool,

    pub fn preset(profile: Profile) Features {
        return switch (profile) {
            // HTTP/1.1 only.
            .minimal => .{ .tls = .none, .http2 = false, .http3 = false, .grpc = false, .websocket = false, .auth = false },
            .web => .{ .tls = .boringssl, .http2 = true, .http3 = false, .grpc = false, .websocket = true, .auth = true },
            .full => .{ .tls = .boringssl, .http2 = true, .http3 = true, .grpc = true, .websocket = true, .auth = true },
        };
    }

    /// Null when the combination is valid, otherwise what is wrong with it.
    pub fn invalid(f: Features) ?[]const u8 {
        if (f.grpc and !f.http2) return "-Dgrpc=true requires -Dhttp2=true (gRPC runs over HTTP/2 with trailers)";
        if (f.http3 and f.tls == .none) return "-Dhttp3=true requires -Dtls=boringssl (QUIC always uses TLS 1.3)";
        return null;
    }

    fn needsTls(f: Features) bool {
        return f.tls == .boringssl;
    }
    fn needsTranslateC(f: Features) bool {
        return f.tls != .none or f.http2 or f.http3;
    }
    /// True when every C library `f` needs is also needed by `have`.
    fn coveredBy(f: Features, have: Features) bool {
        return (!f.needsTls() or have.needsTls()) and (!f.http2 or have.http2) and (!f.http3 or have.http3);
    }
};

/// Presets plus the edge combinations that `test-flags` builds.
const flag_combos = [_]struct { name: []const u8, features: Features }{
    .{ .name = "minimal", .features = Features.preset(.minimal) },
    .{ .name = "web", .features = Features.preset(.web) },
    .{ .name = "full", .features = Features.preset(.full) },
    .{ .name = "full-tls-none", .features = blk: {
        var f = Features.preset(.full);
        f.tls = .none;
        f.http3 = false;
        break :blk f;
    } },
    .{ .name = "http2-no-grpc", .features = blk: {
        var f = Features.preset(.full);
        f.grpc = false;
        break :blk f;
    } },
};

comptime {
    for (flag_combos) |combo| {
        if (combo.features.invalid()) |msg| @compileError("test-flags combo " ++ combo.name ++ ": " ++ msg);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features = resolveFeatures(b);

    // C libraries, requested only for the features that are on. On the first
    // configure pass a missing lazy dependency yields null; the build runner
    // then fetches everything requested and runs build() again.
    const c_mods = CModules.init(b, features, target, optimize) orelse return;

    // Core: zio (runtime) and dusty (HTTP/1.1), always on.
    const core = Core.init(b, c_mods, target, optimize);

    // The public `anole` module, for `b.dependency("anole", ...).module("anole")`.
    const anole_mod = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .target = target, .optimize = optimize, .public = true });

    // test: unit + smoke tests for the enabled features.
    const test_step = b.step("test", "Run unit tests and the smoke tests of the enabled features");
    const tests = b.addTest(.{
        .name = "anole-test",
        .root_module = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .target = target, .optimize = optimize, .for_test = true }),
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_tests.step);

    // test-flags: one test binary per preset and edge combination. Each gets its
    // own build_options module; the C libraries in `c_mods` are shared, so each
    // compiles once per target.
    const flags_step = b.step("test-flags", "Build (and on a native target run) the tests for every preset and edge flag combination");
    for (flag_combos) |combo| {
        if (!combo.features.coveredBy(features)) {
            flags_step.dependOn(&b.addFail(b.fmt(
                "test-flags needs every C dependency, but combo '{s}' needs one the current flags turned off; run it with the default -Dprofile=full and no feature overrides",
                .{combo.name},
            )).step);
            continue;
        }
        const t = b.addTest(.{
            .name = b.fmt("anole-test-{s}", .{combo.name}),
            .root_module = anoleModule(b, .{ .features = combo.features, .core = core, .c = c_mods, .target = target, .optimize = optimize, .for_test = true }),
        });
        const run = b.addRunArtifact(t);
        run.skip_foreign_checks = true;
        flags_step.dependOn(&run.step);
    }

    // examples/hello: dusty on zio, HTTP/1.1.
    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "anole", .module = anole_mod }},
        }),
    });
    const install_hello = b.addInstallArtifact(hello, .{});
    b.getInstallStep().dependOn(&install_hello.step);
    b.step("hello", "Build and install examples/hello").dependOn(&install_hello.step);
    // `zig build test` also proves the example still compiles.
    test_step.dependOn(&hello.step);

    const run_hello = b.addRunArtifact(hello);
    run_hello.addPassthruArgs();
    b.step("run-hello", "Run examples/hello (pass a port after --, default 8080)").dependOn(&run_hello.step);
}

/// Reads -Dprofile and the per-feature overrides. A feature that depends on a
/// turned-off one follows it when it was not set explicitly (`-Dtls=none`
/// turns http3 off, `-Dhttp2=false` turns grpc off); an explicit contradiction
/// is an error.
fn resolveFeatures(b: *std.Build) Features {
    const profile = b.option(Profile, "profile", "Feature preset: minimal (HTTP/1.1 only), web, full (default)") orelse .full;
    const tls = b.option(Tls, "tls", "TLS backend: boringssl or none (overrides the profile)");
    const http2 = b.option(bool, "http2", "HTTP/2 via nghttp2 (overrides the profile)");
    const http3 = b.option(bool, "http3", "HTTP/3 via ngtcp2 + nghttp3; needs -Dtls=boringssl (overrides the profile)");
    const grpc = b.option(bool, "grpc", "gRPC; needs -Dhttp2=true (overrides the profile)");
    const websocket = b.option(bool, "websocket", "WebSocket (overrides the profile)");
    const auth = b.option(bool, "auth", "Auth: JWT, OIDC, sessions, API keys (overrides the profile)");

    var f = Features.preset(profile);
    if (tls) |v| f.tls = v;
    if (http2) |v| f.http2 = v;
    if (http3) |v| f.http3 = v;
    if (grpc) |v| f.grpc = v;
    if (websocket) |v| f.websocket = v;
    if (auth) |v| f.auth = v;

    if (f.tls == .none and http3 == null) f.http3 = false;
    if (!f.http2 and grpc == null) f.grpc = false;

    if (f.invalid()) |msg| {
        std.debug.print("error: invalid Anole feature flags: {s}\n", .{msg});
        std.process.exit(1);
    }
    return f;
}

const Core = struct {
    zio: *std.Build.Module,
    /// dusty with TLS compiled out (-Dtls=none).
    dusty_plain: *std.Build.Module,
    /// dusty whose `tls` import is Anole's BoringSSL module (-Dtls=boringssl);
    /// null when BoringSSL is not part of this build.
    dusty_tls: ?*std.Build.Module,
    /// src/tls/dusty_tls.zig, the module dusty_tls imports as `tls`.
    tls_seam: ?*std.Build.Module,

    fn init(b: *std.Build, c_mods: CModules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Core {
        const zio_mod = b.dependency("zio", .{ .target = target, .optimize = optimize }).module("zio");
        var core: Core = .{
            .zio = zio_mod,
            .dusty_plain = dustyModule(b, zio_mod, false, target, optimize),
            .dusty_tls = null,
            .tls_seam = null,
        };
        if (c_mods.boringssl) |bssl| {
            const seam = b.createModule(.{
                .root_source_file = b.path("src/tls/dusty_tls.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "anole_boringssl_c", .module = bssl }},
            });
            const dusty_tls = dustyModule(b, zio_mod, true, target, optimize);
            dusty_tls.addImport("tls", seam);
            core.dusty_tls = dusty_tls;
            core.tls_seam = seam;
        }
        return core;
    }

    fn dusty(core: Core, f: Features) *std.Build.Module {
        return if (f.needsTls()) core.dusty_tls.? else core.dusty_plain;
    }

    /// Different arguments give separate dusty instances, so the TLS and
    /// non-TLS builds coexist (test-flags builds both).
    fn dustyModule(b: *std.Build, zio_mod: *std.Build.Module, tls: bool, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const mod = b.dependency("dusty", .{
            .target = target,
            .optimize = optimize,
            // With TLS, the `tls` import is injected (Anole's BoringSSL
            // module) instead of dusty's bundled tls.zig, which is then
            // never fetched.
            .use_tls = tls,
            .use_bundled_tls = false,
            // Never set: Anole builds nghttp2 1.70.0 itself, and dusty's vendored
            // 1.69.0 would collide with it at link time.
            .use_http2 = false,
            // Anole standardises on zlib-ng for deflate, so don't fetch dusty's zlib.zig.
            .use_zlib = false,
        }).module("dusty");
        // Replace dusty's zio stub so its timeouts use zio.AutoCancel.
        mod.addImport("zio", zio_mod);
        return mod;
    }
};

/// Zig binding modules of the C libraries. Each one links its static library,
/// so importing the module is enough.
const CModules = struct {
    /// nghttp2.h (http2)
    nghttp2: ?*std.Build.Module = null,
    /// BoringSSL headers listed in src/tls/bssl.h (tls=boringssl)
    boringssl: ?*std.Build.Module = null,
    /// ngtcp2.h + ngtcp2_crypto_boringssl.h (http3)
    ngtcp2: ?*std.Build.Module = null,
    /// nghttp3.h (http3)
    nghttp3: ?*std.Build.Module = null,
    /// C-side struct layouts for the h3 binding tests (http3, tests only)
    h3_layout: ?*std.Build.Module = null,

    /// Null while lazy dependencies are still being fetched.
    fn init(b: *std.Build, f: Features, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?CModules {
        // Request every needed lazy dependency before giving up, so one fetch
        // round gets them all.
        const tc_dep = if (f.needsTranslateC()) b.lazyDependency("translate_c", .{}) else null;
        const nghttp2_dep = if (f.http2) b.lazyDependency("nghttp2", .{}) else null;
        const boringssl_dep = if (f.needsTls()) b.lazyDependency("boringssl", .{}) else null;
        const ngtcp2_dep = if (f.http3) b.lazyDependency("ngtcp2", .{}) else null;
        const nghttp3_dep = if (f.http3) b.lazyDependency("nghttp3", .{}) else null;

        if (f.needsTranslateC() and tc_dep == null) return null;
        if (f.http2 and nghttp2_dep == null) return null;
        if (f.needsTls() and boringssl_dep == null) return null;
        if (f.http3 and (ngtcp2_dep == null or nghttp3_dep == null)) return null;

        // Both vendor sfparse and export the same symbols; stop if they differ.
        if (nghttp2_dep != null and nghttp3_dep != null) nghttp3_build.checkSharedSfparse(b, nghttp2_dep.?, nghttp3_dep.?);

        var m: CModules = .{};
        if (!f.needsTranslateC()) return m;
        // Available whenever tc_dep is; resolved here because the result is a comptime type.
        const tc_build = b.lazyImport(build_zig, "translate_c") orelse return null;
        const Translator = tc_build.Translator;

        if (nghttp2_dep) |up| {
            const lib = nghttp2_build.library(b, up, target, optimize);
            m.nghttp2 = nghttp2_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }

        var bssl_lib: ?*std.Build.Step.Compile = null;
        if (boringssl_dep) |up| {
            const lib = boringssl_build.library(b, up, target, optimize);
            bssl_lib = lib;
            m.boringssl = boringssl_build.module(Translator, tc_dep.?, up, lib, b.path("src/tls/bssl.h"), target, optimize);
        }

        if (ngtcp2_dep != null and nghttp3_dep != null) {
            const ngtcp2_up = ngtcp2_dep.?;
            const nghttp3_up = nghttp3_dep.?;
            const bssl_include = boringssl_dep.?.path("include");
            const ngtcp2_lib = ngtcp2_build.library(b, ngtcp2_up, target, optimize);
            const crypto_lib = ngtcp2_build.cryptoBoringssl(b, ngtcp2_up, ngtcp2_lib, bssl_lib.?, bssl_include, target, optimize);
            const nghttp3_lib = nghttp3_build.library(b, nghttp3_up, target, optimize);
            m.ngtcp2 = ngtcp2_build.module(b, Translator, tc_dep.?, ngtcp2_up, ngtcp2_lib, crypto_lib, bssl_include, target, optimize);
            m.nghttp3 = nghttp3_build.module(b, Translator, tc_dep.?, nghttp3_up, nghttp3_lib, target, optimize);

            const layout = b.createModule(.{
                .root_source_file = b.path("src/h3/layout.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            layout.addCMacro("NGTCP2_STATICLIB", "1");
            layout.addCMacro("NGHTTP3_STATICLIB", "1");
            layout.addIncludePath(ngtcp2_up.path("lib/includes"));
            layout.addIncludePath(nghttp3_up.path("lib/includes"));
            layout.addCSourceFile(.{ .file = b.path("src/h3/layout.c"), .flags = &.{"-std=c11"} });
            m.h3_layout = layout;
        }
        return m;
    }
};

const AnoleModuleOptions = struct {
    features: Features,
    core: Core,
    c: CModules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Register as the package's public `anole` module.
    public: bool = false,
    /// Add test-only imports (the h3 layout probe).
    for_test: bool = false,
};

/// src/root.zig with its own build_options and only the binding modules its
/// features need.
fn anoleModule(b: *std.Build, o: AnoleModuleOptions) *std.Build.Module {
    const f = o.features;
    const options = b.addOptions();
    options.addOption(Tls, "tls", f.tls);
    options.addOption(bool, "http2", f.http2);
    options.addOption(bool, "http3", f.http3);
    options.addOption(bool, "grpc", f.grpc);
    options.addOption(bool, "websocket", f.websocket);
    options.addOption(bool, "auth", f.auth);

    const create: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
    };
    const mod = if (o.public) b.addModule("anole", create) else b.createModule(create);
    mod.addOptions("build_options", options);
    mod.addImport("zio", o.core.zio);
    mod.addImport("dusty", o.core.dusty(f));
    if (f.http2) mod.addImport("anole_nghttp2_c", o.c.nghttp2.?);
    if (f.needsTls()) {
        mod.addImport("anole_boringssl_c", o.c.boringssl.?);
        mod.addImport("anole_dusty_tls", o.core.tls_seam.?);
    }
    if (f.http3) {
        mod.addImport("anole_ngtcp2_c", o.c.ngtcp2.?);
        mod.addImport("anole_nghttp3_c", o.c.nghttp3.?);
        if (o.for_test) mod.addImport("anole_h3_layout", o.c.h3_layout.?);
    }
    return mod;
}
