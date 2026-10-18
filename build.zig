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
//!   bench-server  the Anole side of bench/run.sh (with -Doptimize=ReleaseFast)
//!   io          install examples/io (handlers waiting on I/O through std.Io)
//!   run-io      run examples/io (`zig build run-io -- 8081`)
const std = @import("std");
const builtin = @import("builtin");

const nghttp2_build = @import("build/nghttp2.zig");
const boringssl_build = @import("build/boringssl.zig");
const ngtcp2_build = @import("build/ngtcp2.zig");
const nghttp3_build = @import("build/nghttp3.zig");
const zlib_ng_build = @import("build/zlib_ng.zig");
const zstd_build = @import("build/zstd.zig");
const yyjson_build = @import("build/yyjson.zig");
const hiredis_build = @import("build/hiredis.zig");

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
    /// gzip/deflate (zlib-ng) and zstd: response compression and request
    /// decompression.
    compression: bool,
    /// JSON on yyjson (`anole.json`).
    json: bool,
    /// Redis/Valkey on hiredis (`anole.redis`): session and rate-limit
    /// stores.
    redis: bool,

    pub fn preset(profile: Profile) Features {
        return switch (profile) {
            // HTTP/1.1 only.
            .minimal => .{ .tls = .none, .http2 = false, .http3 = false, .grpc = false, .websocket = false, .auth = false, .compression = false, .json = false, .redis = false },
            .web => .{ .tls = .boringssl, .http2 = true, .http3 = false, .grpc = false, .websocket = true, .auth = true, .compression = true, .json = true, .redis = false },
            .full => .{ .tls = .boringssl, .http2 = true, .http3 = true, .grpc = true, .websocket = true, .auth = true, .compression = true, .json = true, .redis = true },
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
        return f.tls != .none or f.http2 or f.http3 or f.compression or f.json or f.redis;
    }
    /// True when every C library `f` needs is also needed by `have`.
    fn coveredBy(f: Features, have: Features) bool {
        return (!f.needsTls() or have.needsTls()) and (!f.http2 or have.http2) and (!f.http3 or have.http3) and
            (!f.compression or have.compression) and (!f.websocket or have.websocket) and (!f.grpc or have.grpc) and
            (!f.json or have.json) and (!f.redis or have.redis) and (!f.auth or have.auth);
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
    .{ .name = "full-no-compression", .features = blk: {
        var f = Features.preset(.full);
        f.compression = false;
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

/// What `addProtoGen` generates code for.
pub const ProtoGenOptions = struct {
    /// The .proto files.
    source_files: []const std.Build.LazyPath,
    /// Where protoc resolves imports from (its `-I`).
    include_directories: []const std.Build.LazyPath = &.{},
    /// Where the .pb.zig files go: a directory in the project's source tree,
    /// committed like any other source.
    destination_directory: std.Build.LazyPath,
};

/// For a project that depends on Anole: makes `step` generate Zig from
/// .proto files, with the protoc binary and protoc-gen-zig that Anole pins
/// (downloaded and built by `zig build`, nothing to install). Anole must be
/// fetched with gRPC on (the default profile). The generated files import
/// "protobuf": give their module `anole_dep.module("protobuf")`.
///
///     const anole_build = @import("anole");
///     const gen = b.step("gen-proto", "Generate Zig from the .proto files");
///     anole_build.addProtoGen(gen, anole_dep, .{
///         .source_files = &.{b.path("proto/greeter.proto")},
///         .include_directories = &.{b.path("proto")},
///         .destination_directory = b.path("src/gen"),
///     });
pub fn addProtoGen(step: *std.Build.Step, anole_dep: *std.Build.Dependency, options: ProtoGenOptions) void {
    const b = step.owner;
    // Lazy, like inside Anole: on the first configure pass these are null,
    // and the build runner fetches them and configures again.
    const pb = anole_dep.builder.lazyImport(@This(), "protobuf") orelse return;
    const pb_dep = anole_dep.builder.lazyDependency("protobuf", .{ .target = b.graph.host }) orelse return;
    const run = pb.RunProtocStep.createWithGenerator(b, pb_dep.artifact("protoc-gen-zig"), .{
        .source_files = options.source_files,
        .include_directories = options.include_directories,
        .destination_directory = options.destination_directory,
    });
    step.dependOn(run.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features = resolveFeatures(b);

    // Options are declared before the lazy-dependency return below: one
    // first declared after it is "invalid" on a fresh cache's first pass.
    const redis_test_port = b.option(u16, "redis-test-port", "Run the Redis tests against a live Redis/Valkey on this port");
    // `zig build test --fuzz` needs LLVM: Zig 0.17's self-hosted backend (the
    // Debug default on x86_64-linux) emits no coverage tables, so the fuzzer
    // would see none ("pcs_len was zero").
    const use_llvm = b.option(bool, "llvm", "Build the unit tests with LLVM (needed for --fuzz on x86_64-linux)");

    // C libraries, requested only for the features that are on. On the first
    // configure pass a missing lazy dependency yields null; the build runner
    // then fetches everything requested and runs build() again.
    const c_mods = CModules.init(b, features, target, optimize) orelse {
        // A project depending on Anole asks for its modules in this same
        // pass, and `Dependency.module` panics on a missing one, so they
        // exist here as stand-ins. The pass is thrown away once the lazy
        // dependencies are fetched; nothing compiles these.
        _ = b.addModule("anole", .{ .root_source_file = b.path("src/root.zig") });
        if (features.grpc) _ = b.addModule("protobuf", .{});
        return;
    };

    // Core: zio (runtime) and dusty (HTTP/1.1), always on.
    const core = Core.init(b, c_mods, target, optimize);

    // The public `anole` module, for `b.dependency("anole", ...).module("anole")`.
    const anole_mod = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .target = target, .optimize = optimize, .public = true });
    // zig-protobuf's runtime, which the code `addProtoGen` generates imports
    // as "protobuf": `anole_dep.module("protobuf")`.
    if (c_mods.protobuf) |m| _ = b.modules.getOrPutValue(b.graph.arena, "protobuf", m) catch @panic("OOM");

    // test: unit + smoke tests for the enabled features.
    const test_step = b.step("test", "Run unit tests and the smoke tests of the enabled features");
    const tests = b.addTest(.{
        .name = "anole-test",
        .root_module = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .target = target, .optimize = optimize, .for_test = true, .redis_test_port = redis_test_port }),
        .use_llvm = use_llvm,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_tests.step);

    // dusty-test: dusty's own test suite on what Anole injects into it
    // (BoringSSL through src/tls/dusty_tls.zig, nghttp2 1.70.0, zlib-ng,
    // zstd): a conformance check of those seams.
    if (core.dusty_by[1][1][1]) |dusty_full| {
        // A second instance of the same sources and imports, but with
        // dusty's own zio stub: its tests run on std.testing.io, and the
        // real zio's timers need a zio task.
        const dusty_root = dusty_full.root_source_file.?;
        const test_mod = b.createModule(.{
            .root_source_file = dusty_root,
            .target = target,
            .optimize = optimize,
            .link_libc = dusty_full.link_libc,
        });
        var imports = dusty_full.import_table.iterator();
        while (imports.next()) |e| test_mod.addImport(e.key_ptr.*, e.value_ptr.*);
        test_mod.addAnonymousImport("zio", .{ .root_source_file = dusty_root.dirname().path(b, "zio_stub.zig") });
        test_mod.include_dirs.appendSlice(b.allocator, dusty_full.include_dirs.items) catch @panic("OOM");
        test_mod.c_macros.appendSlice(b.allocator, dusty_full.c_macros.items) catch @panic("OOM");
        test_mod.link_objects.appendSlice(b.allocator, dusty_full.link_objects.items) catch @panic("OOM");
        // dusty's own test runner, as its build uses (some tests log at
        // err on purpose).
        const dusty_tests = b.addTest(.{
            .name = "dusty-test",
            .root_module = test_mod,
            .test_runner = .{ .path = dusty_root.dirname().dirname().path(b, "test_runner.zig"), .mode = .simple },
        });
        const run_dusty_tests = b.addRunArtifact(dusty_tests);
        run_dusty_tests.skip_foreign_checks = true;
        // Its tests open fixtures (examples/certs/...) relative to dusty's
        // package root.
        run_dusty_tests.setCwd(dusty_root.dirname().dirname());
        b.step("dusty-test", "Run dusty's own tests on Anole's TLS, nghttp2, zlib-ng and zstd").dependOn(&run_dusty_tests.step);
    }

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

    // tests/tls_duplex.zig: the multi-threaded full-duplex TLS check.
    if (features.needsTls()) {
        const duplex = b.addExecutable(.{
            .name = "tls-duplex",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tls_duplex.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        const run_duplex = b.addRunArtifact(duplex);
        run_duplex.skip_foreign_checks = true;
        test_step.dependOn(&run_duplex.step);
    }

    // examples/<name>: one per protocol or area, each built by `zig build
    // test` when the flags include what it needs, and run with
    // `zig build run-<name>`.
    const Example = struct { name: []const u8, needs: bool, about: []const u8 };
    const examples = [_]Example{
        .{ .name = "websocket", .needs = features.websocket, .about = "WebSocket echo and a broadcast room" },
        .{ .name = "grpc", .needs = features.grpc, .about = "a gRPC Greeter, also over gRPC-Web and Connect" },
        .{ .name = "auth", .needs = features.auth and features.json, .about = "JWT bearer tokens, sessions, CSRF, API keys and rate limits" },
        .{ .name = "clients", .needs = features.tls == .boringssl and features.http2 and features.http3, .about = "outbound HTTP/1.1, HTTP/2, HTTP/3 and gRPC" },
        .{ .name = "observe", .needs = true, .about = "metrics, tracing, access logs and health checks" },
    };
    for (examples) |ex| {
        if (!ex.needs) continue;
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{ex.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "anole", .module = anole_mod }},
        });
        if (std.mem.eql(u8, ex.name, "grpc")) ex_mod.addImport("greeter_pb", b.createModule(.{
            .root_source_file = b.path("examples/grpc/gen/greeter.pb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "protobuf", .module = c_mods.protobuf.? }},
        }));
        const ex_exe = b.addExecutable(.{ .name = ex.name, .root_module = ex_mod });
        test_step.dependOn(&ex_exe.step);
        const run_ex = b.addRunArtifact(ex_exe);
        run_ex.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{ex.name}), b.fmt("Run examples/{s}: {s}", .{ ex.name, ex.about })).dependOn(&run_ex.step);
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

    // bench/anole: the Anole side of the Fiber benchmark (bench/run.sh).
    if (features.json) {
        const bench = b.addExecutable(.{
            .name = "bench-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/anole/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("bench-server", "Build the benchmark server (bench/run.sh; use -Doptimize=ReleaseFast)").dependOn(&b.addInstallArtifact(bench, .{}).step);
        test_step.dependOn(&bench.step);
    }

    // tls-public-check: outbound HTTPS against public hosts (needs the network).
    if (features.tls == .boringssl) {
        const public_check = b.addExecutable(.{
            .name = "tls-public-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/tls_public.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        const run_public_check = b.addRunArtifact(public_check);
        run_public_check.has_side_effects = true;
        b.step("tls-public-check", "Fetch public HTTPS hosts with the system trust store (needs the network)").dependOn(&run_public_check.step);
        test_step.dependOn(&public_check.step);
    }

    // tests/h3: a server for the independent HTTP/3 client (tests/h3/client.py).
    if (features.http3) {
        const h3_server = b.addExecutable(.{
            .name = "h3-test-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/h3/server.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("h3-test-server", "Build the HTTP/3 test server (tests/h3/run.sh drives it with aioquic)").dependOn(&b.addInstallArtifact(h3_server, .{}).step);
        test_step.dependOn(&h3_server.step);
        // And anole.h3's client against aioquic's server (tests/h3/peer_server.py).
        const h3_client = b.addExecutable(.{
            .name = "h3-test-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/h3/client.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("h3-test-client", "Build the HTTP/3 test client (tests/h3/run.sh drives it against aioquic)").dependOn(&b.addInstallArtifact(h3_client, .{}).step);
        test_step.dependOn(&h3_client.step);
        // The QUIC interop runner's server endpoint (tests/interop).
        const h3_interop = b.addExecutable(.{
            .name = "h3-interop-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/h3/interop.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("h3-interop-server", "Build the QUIC interop runner's server (tests/interop/build.sh)").dependOn(&b.addInstallArtifact(h3_interop, .{}).step);
        test_step.dependOn(&h3_interop.step);
    }

    // examples/io: handlers that wait on timers, files and outbound requests
    // through std.Io.
    const io_example = b.addExecutable(.{
        .name = "io-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/io/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "anole", .module = anole_mod }},
        }),
    });
    const install_io = b.addInstallArtifact(io_example, .{});
    b.step("io", "Build and install examples/io").dependOn(&install_io.step);
    test_step.dependOn(&io_example.step);
    const run_io = b.addRunArtifact(io_example);
    run_io.addPassthruArgs();
    b.step("run-io", "Run examples/io (pass a port after --, default 8081)").dependOn(&run_io.step);

    // `zig build gen-proto`: Zig for Anole's own .proto files (the health
    // service, the test service), through zig-protobuf's protoc-gen-zig and
    // its pinned protoc. The output is committed; rerun after a proto or
    // zig-protobuf change.
    if (features.grpc) {
        if (b.lazyImport(@This(), "protobuf")) |pb| if (b.lazyDependency("protobuf", .{ .target = target })) |dep| {
            const gen_health = pb.RunProtocStep.create(b, target, .{
                .source_files = &.{b.path("src/grpc/proto/grpc/health/v1/health.proto")},
                .include_directories = &.{b.path("src/grpc/proto")},
                .destination_directory = b.path("src/grpc/gen"),
                .generator = dep.artifact("protoc-gen-zig"),
            });
            const gen_test = pb.RunProtocStep.create(b, target, .{
                .source_files = &.{b.path("tests/grpc/proto/echo.proto")},
                .include_directories = &.{b.path("tests/grpc/proto")},
                .destination_directory = b.path("tests/grpc/gen"),
                .generator = dep.artifact("protoc-gen-zig"),
            });
            const gen_interop = pb.RunProtocStep.create(b, target, .{
                .source_files = &.{b.path("tests/grpc/proto/grpc/testing/test.proto")},
                .include_directories = &.{b.path("tests/grpc/proto")},
                .destination_directory = b.path("tests/grpc/gen"),
                .generator = dep.artifact("protoc-gen-zig"),
            });
            const gen_example = pb.RunProtocStep.create(b, target, .{
                .source_files = &.{b.path("examples/grpc/proto/greeter.proto")},
                .include_directories = &.{b.path("examples/grpc/proto")},
                .destination_directory = b.path("examples/grpc/gen"),
                .generator = dep.artifact("protoc-gen-zig"),
            });
            const gen = b.step("gen-proto", "Regenerate the Zig for Anole's .proto files (committed)");
            gen.dependOn(gen_example.step);
            gen.dependOn(gen_health.step);
            gen.dependOn(gen_test.step);
            gen.dependOn(gen_interop.step);
        };
    }

    // tests/grpc/interop: grpc.testing.TestService for grpc-go's interop
    // client (tests/grpc/interop/run.sh).
    if (features.grpc) {
        const interop = b.addExecutable(.{
            .name = "grpc-interop-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/grpc/interop/server.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "anole", .module = anole_mod },
                    .{ .name = "anole_interop_pb", .module = b.createModule(.{
                        .root_source_file = b.path("tests/grpc/gen/grpc/testing.pb.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{.{ .name = "protobuf", .module = c_mods.protobuf.? }},
                    }) },
                },
            }),
        });
        b.step("grpc-interop-server", "Build the gRPC interop server (tests/grpc/interop/run.sh runs grpc-go's client)").dependOn(&b.addInstallArtifact(interop, .{}).step);
        test_step.dependOn(&interop.step);
        const interop_client = b.addExecutable(.{
            .name = "grpc-interop-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/grpc/interop/client.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "anole", .module = anole_mod },
                    .{ .name = "anole_interop_pb", .module = interop.root_module.import_table.get("anole_interop_pb").? },
                },
            }),
        });
        b.step("grpc-interop-client", "Build the gRPC interop client (tests/grpc/interop/run-client.sh runs it against grpc-go's server)").dependOn(&b.addInstallArtifact(interop_client, .{}).step);
        test_step.dependOn(&interop_client.step);
    }

    // tests/autobahn: the WebSocket echo peer for the Autobahn suite.
    if (features.websocket) {
        const echo = b.addExecutable(.{
            .name = "autobahn-echo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/autobahn/echo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("autobahn-echo", "Build the Autobahn echo peer (tests/autobahn/run.sh runs the suite)").dependOn(&b.addInstallArtifact(echo, .{}).step);
        test_step.dependOn(&echo.step);
    }
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
    const compression = b.option(bool, "compression", "gzip/deflate (zlib-ng) and zstd (overrides the profile)");
    const json = b.option(bool, "json", "JSON on yyjson (overrides the profile)");
    const redis = b.option(bool, "redis", "Redis/Valkey client on hiredis (overrides the profile)");

    var f = Features.preset(profile);
    if (tls) |v| f.tls = v;
    if (http2) |v| f.http2 = v;
    if (http3) |v| f.http3 = v;
    if (grpc) |v| f.grpc = v;
    if (websocket) |v| f.websocket = v;
    if (auth) |v| f.auth = v;
    if (compression) |v| f.compression = v;
    if (json) |v| f.json = v;
    if (redis) |v| f.redis = v;

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
    /// dusty instances by [tls][http2][compression]. One exists for each
    /// combination this build can satisfy: TLS needs BoringSSL in the build,
    /// HTTP/2 nghttp2, compression zlib-ng. Different arguments give separate
    /// dusty instances, so test-flags can build every combination side by
    /// side.
    dusty_by: [2][2][2]?*std.Build.Module,
    /// src/tls/dusty_tls.zig, the module the TLS instances import as `tls`.
    tls_seam: ?*std.Build.Module,

    fn init(b: *std.Build, c_mods: CModules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Core {
        const zio_mod = b.dependency("zio", .{ .target = target, .optimize = optimize }).module("zio");
        const seam: ?*std.Build.Module = if (c_mods.boringssl) |bssl| b.createModule(.{
            .root_source_file = b.path("src/tls/dusty_tls.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "anole_boringssl_c", .module = bssl }},
        }) else null;
        var core: Core = .{ .zio = zio_mod, .dusty_by = @splat(@splat(@splat(null))), .tls_seam = seam };
        for ([_]bool{ false, true }) |tls| {
            if (tls and seam == null) continue;
            for ([_]bool{ false, true }) |http2| {
                if (http2 and c_mods.nghttp2 == null) continue;
                for ([_]bool{ false, true }) |compression| {
                    if (compression and c_mods.zlib == null) continue;
                    core.dusty_by[@intFromBool(tls)][@intFromBool(http2)][@intFromBool(compression)] = dustyModule(
                        b,
                        zio_mod,
                        if (tls) seam else null,
                        if (http2) c_mods.nghttp2 else null,
                        if (compression) c_mods.zlib else null,
                        if (compression) c_mods.zstd else null,
                        target,
                        optimize,
                    );
                }
            }
        }
        return core;
    }

    fn dusty(core: Core, f: Features) *std.Build.Module {
        return core.dusty_by[@intFromBool(f.needsTls())][@intFromBool(f.http2)][@intFromBool(f.compression)].?;
    }

    fn dustyModule(
        b: *std.Build,
        zio_mod: *std.Build.Module,
        tls: ?*std.Build.Module,
        nghttp2: ?*std.Build.Module,
        zlib: ?*std.Build.Module,
        zstd: ?*std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        const mod = b.dependency("dusty", .{
            .target = target,
            .optimize = optimize,
            // With TLS, the `tls` import is injected (Anole's BoringSSL
            // module) instead of dusty's bundled tls.zig, which is then
            // never fetched.
            .use_tls = tls != null,
            .use_bundled_tls = false,
            // With HTTP/2, the `nghttp2` import is Anole's nghttp2 1.70.0
            // module (which links the library) instead of dusty's vendored
            // 1.69.0, so only one copy is linked.
            .use_http2 = nghttp2 != null,
            .use_bundled_nghttp2 = false,
            // gzip/deflate on zlib-ng: the `zlib` import is zlib.zig's wrapper
            // over Anole's zlib-ng, so dusty's pinned zlib.zig (and its
            // vendored C zlib) is never fetched.
            .use_zlib = zlib != null,
            .use_bundled_zlib = false,
            // zstd for responses and request bodies, on Anole's zstd.
            .use_zstd = zstd != null,
        }).module("dusty");
        // Never instrumented for `zig build test --fuzz`: Zig 0.17's fuzzer
        // cannot take clang's coverage tables from the C (llhttp) compiled
        // into this module beside Zig's ("pc counters length and pcs length
        // do not match"). Anole's fuzz targets do not go through dusty.
        mod.fuzz = false;
        // Replace dusty's zio stub so its timeouts use zio.AutoCancel.
        mod.addImport("zio", zio_mod);
        if (tls) |m| mod.addImport("tls", m);
        if (nghttp2) |m| mod.addImport("nghttp2", m);
        if (zlib) |m| mod.addImport("zlib", m);
        if (zstd) |m| mod.addImport("zstd", m);
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
    /// lalinsky/zlib.zig's std.Io wrapper over zlib-ng (compression); the
    /// `zlib` module dusty imports.
    zlib: ?*std.Build.Module = null,
    /// zlib.h of zlib-ng (compression)
    zlib_c: ?*std.Build.Module = null,
    /// zstd.h (compression)
    zstd: ?*std.Build.Module = null,
    /// xuckless/websocket-zig, the sans-IO frame codec for WebSocket over
    /// HTTP/2 (websocket). Pure Zig, but fetched lazily like the C libraries.
    websocket: ?*std.Build.Module = null,
    /// Arwalk/zig-protobuf's runtime (grpc).
    protobuf: ?*std.Build.Module = null,
    /// yyjson.h (json)
    yyjson: ?*std.Build.Module = null,
    /// hiredis.h (redis)
    hiredis: ?*std.Build.Module = null,
    /// xuckless/zig-jwt (auth).
    jwt: ?*std.Build.Module = null,

    /// Null while lazy dependencies are still being fetched.
    fn init(b: *std.Build, f: Features, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?CModules {
        // Request every needed lazy dependency before giving up, so one fetch
        // round gets them all.
        const tc_dep = if (f.needsTranslateC()) b.lazyDependency("translate_c", .{}) else null;
        const nghttp2_dep = if (f.http2) b.lazyDependency("nghttp2", .{}) else null;
        const boringssl_dep = if (f.needsTls()) b.lazyDependency("boringssl", .{}) else null;
        const ngtcp2_dep = if (f.http3) b.lazyDependency("ngtcp2", .{}) else null;
        const nghttp3_dep = if (f.http3) b.lazyDependency("nghttp3", .{}) else null;
        const zlib_ng_dep = if (f.compression) b.lazyDependency("zlib_ng", .{}) else null;
        const zstd_dep = if (f.compression) b.lazyDependency("zstd", .{}) else null;
        // Only its src/root.zig is used (its module would compile a second,
        // vendored zlib).
        const zlib_zig_dep = if (f.compression) b.lazyDependency("zlib_zig", .{}) else null;
        const websocket_dep = if (f.websocket) b.lazyDependency("websocket_zig", .{ .target = target, .optimize = optimize }) else null;
        const protobuf_dep = if (f.grpc) b.lazyDependency("protobuf", .{ .target = target, .optimize = optimize }) else null;
        const yyjson_dep = if (f.json) b.lazyDependency("yyjson", .{}) else null;
        const hiredis_dep = if (f.redis) b.lazyDependency("hiredis", .{}) else null;
        const jwt_dep = if (f.auth) b.lazyDependency("zig_jwt", .{ .target = target, .optimize = optimize }) else null;

        if (f.needsTranslateC() and tc_dep == null) return null;
        if (f.http2 and nghttp2_dep == null) return null;
        if (f.needsTls() and boringssl_dep == null) return null;
        if (f.http3 and (ngtcp2_dep == null or nghttp3_dep == null)) return null;
        if (f.compression and (zlib_ng_dep == null or zstd_dep == null or zlib_zig_dep == null)) return null;
        if (f.websocket and websocket_dep == null) return null;
        if (f.grpc and protobuf_dep == null) return null;
        if (f.json and yyjson_dep == null) return null;
        if (f.redis and hiredis_dep == null) return null;
        if (f.auth and jwt_dep == null) return null;

        // Both vendor sfparse and export the same symbols; stop if they differ.
        if (nghttp2_dep != null and nghttp3_dep != null) nghttp3_build.checkSharedSfparse(b, nghttp2_dep.?, nghttp3_dep.?);

        var m: CModules = .{};
        if (websocket_dep) |dep| m.websocket = dep.module("websocket");
        if (protobuf_dep) |dep| m.protobuf = dep.module("protobuf");
        if (jwt_dep) |dep| m.jwt = dep.module("zig-jwt");
        if (!f.needsTranslateC()) return m;
        // Available whenever tc_dep is; resolved here because the result is a comptime type.
        const tc_build = b.lazyImport(build_zig, "translate_c") orelse return null;
        const Translator = tc_build.Translator;

        if (zlib_ng_dep) |up| {
            const lib = zlib_ng_build.library(b, up, target, optimize);
            const c_mod = zlib_ng_build.module(b, Translator, tc_dep.?, lib, target, optimize);
            const zlib_mod = b.createModule(.{
                .root_source_file = zlib_zig_dep.?.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "c", .module = c_mod }},
            });
            m.zlib = zlib_mod;
            m.zlib_c = c_mod;
        }
        if (hiredis_dep) |up| {
            const lib = hiredis_build.library(b, up, target, optimize);
            m.hiredis = hiredis_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }
        if (yyjson_dep) |up| {
            const lib = yyjson_build.library(b, up, target, optimize);
            m.yyjson = yyjson_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }
        if (zstd_dep) |up| {
            const lib = zstd_build.library(b, up, target, optimize);
            m.zstd = zstd_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }

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
    redis_test_port: ?u16 = null,
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
    options.addOption(bool, "compression", f.compression);
    options.addOption(bool, "json", f.json);
    options.addOption(bool, "redis", f.redis);
    // A live Redis/Valkey for tests (`-Dredis-test-port=6379`), else those
    // tests skip.
    options.addOption(?u16, "redis_test_port", o.redis_test_port);

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
    if (f.websocket) mod.addImport("anole_websocket_codec", o.c.websocket.?);
    if (f.grpc) mod.addImport("protobuf", o.c.protobuf.?);
    if (f.json) mod.addImport("anole_yyjson_c", o.c.yyjson.?);
    if (f.redis) mod.addImport("anole_hiredis_c", o.c.hiredis.?);
    if (f.auth) mod.addImport("anole_jwt", o.c.jwt.?);
    // The generated test service (tests/grpc/gen), outside src/.
    if (f.grpc and o.for_test) mod.addImport("anole_test_pb", b.createModule(.{
        .root_source_file = b.path("tests/grpc/gen/anole/test.pb.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "protobuf", .module = o.c.protobuf.? }},
    }));
    if (f.compression) {
        mod.addImport("anole_zlib", o.c.zlib.?);
        mod.addImport("anole_zlib_c", o.c.zlib_c.?);
        mod.addImport("anole_zstd_c", o.c.zstd.?);
    }
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
