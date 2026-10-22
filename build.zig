//! Anole build.
//!
//! Features are chosen with `-Dprofile=minimal|web|full` (default `full`) and
//! overridden one by one with `-Dtls=boringssl|none`, `-Dhttp2`, `-Dhttp3`,
//! `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dpostgres`, `-Dsqlite`, `-Dmongodb` and
//! the rest below. The result is exposed to Zig code as the `build_options`
//! module (re-exported as `anole.features`).
//!
//! Every C library is a lazy dependency in build.zig.zon and is requested only
//! when a feature that needs it is on, so `-Dprofile=minimal` fetches and
//! compiles no C library besides llhttp (the HTTP core's parser).
//!
//! Steps:
//!   test        unit tests + smoke tests of the enabled features
//!   test-flags  the test binary for every preset and edge combination, sharing
//!               one build of each C library (run when the target is native)
//!   <example>   install examples/<example> (hello, rest, websocket, grpc, auth,
//!               clients, observe, sqlite, full)
//!   run-<example>  run it (`zig build run-rest -- 127.0.0.1:4000`)
//!   full        examples/full, every listener spelled out (also part of the
//!               default install step; the h2spec and restart scripts drive it)
//!   bench-server  the Anole side of bench/run.sh (with -Doptimize=ReleaseFast)
//!   io          install examples/io (handlers waiting on I/O through std.Io)
//!   run-io      run examples/io (`zig build run-io -- 8081`)
//!   docs        the API reference (Zig autodoc of the `anole` module) in
//!               zig-out/docs; the docs site (site/) serves it at /anole/api/
const std = @import("std");
const builtin = @import("builtin");

const nghttp2_build = @import("build/nghttp2.zig");
const boringssl_build = @import("build/boringssl.zig");
const ngtcp2_build = @import("build/ngtcp2.zig");
const nghttp3_build = @import("build/nghttp3.zig");
const zlib_ng_build = @import("build/zlib_ng.zig");
const zstd_build = @import("build/zstd.zig");
const brotli_build = @import("build/brotli.zig");
const yyjson_build = @import("build/yyjson.zig");
const hiredis_build = @import("build/hiredis.zig");
const sqlite_build = @import("build/sqlite.zig");

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
    /// Brotli (google/brotli) as a third response coding next to zstd and
    /// gzip. Needs `compression`.
    brotli: bool,
    /// JSON on yyjson (`anole.json`).
    json: bool,
    /// Redis/Valkey on hiredis (`anole.redis`): session and rate-limit
    /// stores.
    redis: bool,
    /// The PostgreSQL client (`anole.pg`).
    postgres: bool,
    /// SQLite, the library built in (`anole.sqlite`).
    sqlite: bool,
    /// The MongoDB client (`anole.mongodb`) and its BSON codec
    /// (`anole.bson`).
    mongodb: bool,

    pub fn preset(profile: Profile) Features {
        return switch (profile) {
            // HTTP/1.1 only.
            .minimal => .{ .tls = .none, .http2 = false, .http3 = false, .grpc = false, .websocket = false, .auth = false, .compression = false, .brotli = false, .json = false, .redis = false, .postgres = false, .sqlite = false, .mongodb = false },
            .web => .{ .tls = .boringssl, .http2 = true, .http3 = false, .grpc = false, .websocket = true, .auth = true, .compression = true, .brotli = true, .json = true, .redis = false, .postgres = true, .sqlite = true, .mongodb = false },
            .full => .{ .tls = .boringssl, .http2 = true, .http3 = true, .grpc = true, .websocket = true, .auth = true, .compression = true, .brotli = true, .json = true, .redis = true, .postgres = true, .sqlite = true, .mongodb = true },
        };
    }

    /// Null when the combination is valid, otherwise what is wrong with it.
    pub fn invalid(f: Features) ?[]const u8 {
        if (f.grpc and !f.http2) return "-Dgrpc=true requires -Dhttp2=true (gRPC runs over HTTP/2 with trailers)";
        if (f.http3 and f.tls == .none) return "-Dhttp3=true requires -Dtls=boringssl (QUIC always uses TLS 1.3)";
        if (f.brotli and !f.compression) return "-Dbrotli=true requires -Dcompression=true (Brotli is one of the Compress middleware's codings)";
        return null;
    }

    fn needsTls(f: Features) bool {
        return f.tls == .boringssl;
    }
    fn needsTranslateC(f: Features) bool {
        return f.tls != .none or f.http2 or f.http3 or f.compression or f.json or f.redis or f.sqlite;
    }
    /// True when every C library `f` needs is also needed by `have`.
    fn coveredBy(f: Features, have: Features) bool {
        return (!f.needsTls() or have.needsTls()) and (!f.http2 or have.http2) and (!f.http3 or have.http3) and
            (!f.compression or have.compression) and (!f.brotli or have.brotli) and (!f.websocket or have.websocket) and (!f.grpc or have.grpc) and
            (!f.json or have.json) and (!f.redis or have.redis) and (!f.auth or have.auth) and
            (!f.postgres or have.postgres) and (!f.sqlite or have.sqlite) and (!f.mongodb or have.mongodb);
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
        f.brotli = false;
        break :blk f;
    } },
    // zstd and gzip without Brotli.
    .{ .name = "full-no-brotli", .features = blk: {
        var f = Features.preset(.full);
        f.brotli = false;
        break :blk f;
    } },
    .{ .name = "http2-no-grpc", .features = blk: {
        var f = Features.preset(.full);
        f.grpc = false;
        break :blk f;
    } },
    // Everything but the database connectors.
    .{ .name = "db-none", .features = blk: {
        var f = Features.preset(.full);
        f.postgres = false;
        f.sqlite = false;
        f.mongodb = false;
        break :blk f;
    } },
    // The connectors on HTTP/1.1 alone: no TLS (plain connections only),
    // no JSON, no compression.
    .{ .name = "db-only", .features = blk: {
        var f = Features.preset(.minimal);
        f.postgres = true;
        f.sqlite = true;
        f.mongodb = true;
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
    /// Where protoc resolves imports from (its `-I`). Anole adds its own
    /// .proto directory after these, for `google/api/annotations.proto` and
    /// `google/api/http.proto` (JSON transcoding).
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
    const includes = b.allocator.alloc(std.Build.LazyPath, options.include_directories.len + 1) catch @panic("OOM");
    @memcpy(includes[0..options.include_directories.len], options.include_directories);
    includes[options.include_directories.len] = anole_dep.path("src/grpc/proto");
    const run = pb.RunProtocStep.createWithGenerator(b, pb_dep.artifact("protoc-gen-zig"), .{
        .source_files = options.source_files,
        .include_directories = includes,
        .destination_directory = options.destination_directory,
    });
    step.dependOn(run.step);
}

/// One .proto file as a module of generated Zig, for `addApp` and
/// `addProtoModule`.
pub const Proto = struct {
    /// What the program imports it as: `@import("greeter_pb")`.
    name: []const u8,
    /// The .proto file. protoc resolves its imports from its directory,
    /// `include_directories`, and Anole's google/api protos.
    file: std.Build.LazyPath,
    /// Its `package` statement, which names the generated file. Read from
    /// `file` when null, which then must be in the project.
    package: ?[]const u8 = null,
    include_directories: []const std.Build.LazyPath = &.{},
};

/// For a project that depends on Anole: Zig generated from `proto.file`
/// as a module importing "protobuf", made in the cache by `zig build`
/// itself whenever the .proto changes (nothing to commit, no separate
/// step), with the protoc and protoc-gen-zig Anole pins. Anole must be
/// fetched with gRPC on (the default profile). `addApp` calls it for its
/// `protos`; `addProtoGen` writes the code into the source tree instead.
pub fn addProtoModule(b: *std.Build, anole_dep: *std.Build.Dependency, proto: Proto) *std.Build.Module {
    // Lazy, as in `addProtoGen`: the first configure pass has none of
    // these, and nothing is compiled then.
    const pb_dep = anole_dep.builder.lazyDependency("protobuf", .{ .target = b.graph.host }) orelse return b.createModule(.{});
    const protoc = protocBinary(pb_dep.builder) orelse return b.createModule(.{});
    const package = proto.package orelse protoPackage(b, proto.file) orelse
        std.debug.panic("addProtoModule: no `package` statement found in the .proto for \"{s}\"; set `.package`", .{proto.name});

    const run = b.addRunFile(protoc);
    run.setName(b.fmt("protoc {s}", .{proto.name}));
    run.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", pb_dep.artifact("protoc-gen-zig"));
    const out = run.addPrefixedOutputDirectoryArg("--zig_out=", proto.name);
    for (proto.include_directories) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    run.addArg("-I");
    run.addDirectoryArg(proto.file.dirname());
    run.addArg("-I");
    run.addDirectoryArg(anole_dep.path("src/grpc/proto"));
    run.addFileArg(proto.file);

    // protoc-gen-zig names the file after the package: a.b -> a/b.pb.zig.
    const dir_path = b.fmt("{s}", .{package});
    std.mem.replaceScalar(u8, dir_path, '.', '/');
    const file_name = b.fmt("{s}.pb.zig", .{dir_path});
    return b.createModule(.{
        .root_source_file = out.path(b, file_name),
        .imports = &.{.{ .name = "protobuf", .module = anole_dep.module("protobuf") }},
    });
}

/// zig-protobuf's pinned protoc for the machine running the build (its
/// `build_util.getProtocBin`, which its build.zig does not export).
fn protocBinary(pb_builder: *std.Build) ?std.Build.LazyPath {
    const os = switch (builtin.os.tag) {
        .macos => "osx",
        .linux => "linux",
        else => @compileError("protoc: Anole builds on Linux and macOS"),
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch_64",
        .x86_64 => "x86_64",
        .x86 => "x86_32",
        else => @compileError("protoc: no pinned binary for this CPU"),
    };
    const dep = pb_builder.lazyDependency("protoc-" ++ os ++ "-" ++ arch, .{}) orelse return null;
    return dep.path("bin/protoc");
}

/// The `package` a .proto file in the project declares, or null. The
/// configure step reruns when the file changes.
fn protoPackage(b: *std.Build, file: std.Build.LazyPath) ?[]const u8 {
    const src = switch (file) {
        .src_path => |sp| sp,
        else => return null,
    };
    src.owner.dependOnFileContents(file);
    const root = src.owner.root;
    const path = if (root.sub_path.len == 0) src.sub_path else b.pathJoin(&.{ root.sub_path, src.sub_path });
    const text = root.root_dir.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(4 << 20)) catch return null;
    return parseProtoPackage(text);
}

fn parseProtoPackage(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "package")) continue;
        const rest = std.mem.trim(u8, line["package".len..], " \t");
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
        const name = std.mem.trim(u8, rest[0..end], " \t");
        if (name.len > 0 and rest.len > 0 and line.len > "package".len and (line["package".len] == ' ' or line["package".len] == '\t')) return name;
    }
    return null;
}

/// What `addApp` builds.
pub const AppOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    /// Null: `b.standardTargetOptions(.{})` and
    /// `b.standardOptimizeOption(.{})`, so `-Dtarget` and `-Doptimize` work.
    /// Pass them when build.zig already declares those options.
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.Optimize = null,
    /// Anole's name in build.zig.zon.
    dependency: []const u8 = "anole",
    /// Anole's feature preset (`-Dprofile`); null takes Anole's default,
    /// `full`.
    profile: ?Profile = null,
    /// .proto files, each a module the program imports by its `name`,
    /// generated by `zig build` (see `addProtoModule`).
    protos: []const Proto = &.{},
    /// More imports for the program.
    imports: []const std.Build.Module.Import = &.{},
    /// Add `zig build run` (arguments after `--` go to the program).
    run_step: bool = true,
};

/// What `addApp` made.
pub const App = struct {
    exe: *std.Build.Step.Compile,
    /// The Anole dependency it uses. Reuse it (`addProtoGen`, more
    /// executables) rather than asking `b.dependency` again with other
    /// arguments: two instances of Anole in one build collide.
    anole: *std.Build.Dependency,
};

/// For a project that depends on Anole: the executable, importing "anole"
/// and the modules generated from `protos`, installed, with a `run` step.
/// The whole build.zig of a gRPC server:
///
///     const std = @import("std");
///     pub fn build(b: *std.Build) void {
///         _ = @import("anole").addApp(b, .{
///             .name = "api",
///             .root_source_file = b.path("src/main.zig"),
///             .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }},
///         });
///     }
pub fn addApp(b: *std.Build, options: AppOptions) App {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    // Not refused (it is the fastest build), but said: a server takes
    // untrusted input, and ReleaseFast turns a bug Zig would stop at into
    // undefined behaviour.
    if (optimize == .fast or optimize == .small) std.log.warn("{s}: -Doptimize={s} turns Zig's safety checks off (a bug that would stop the server can corrupt memory instead); Anole recommends -Doptimize=ReleaseSafe for production", .{ options.name, if (optimize == .fast) "ReleaseFast" else "ReleaseSmall" });
    const anole_dep = if (options.profile) |profile|
        b.dependency(options.dependency, .{ .target = target, .optimize = optimize, .profile = profile })
    else
        b.dependency(options.dependency, .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = options.imports,
        }),
    });
    exe.root_module.addImport("anole", anole_dep.module("anole"));
    for (options.protos) |proto| {
        const m = addProtoModule(b, anole_dep, proto);
        m.resolved_target = target;
        m.optimize = optimize;
        exe.root_module.addImport(proto.name, m);
    }
    b.installArtifact(exe);
    if (options.run_step) {
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        run.addPassthruArgs();
        b.step("run", b.fmt("Run {s}", .{options.name})).dependOn(&run.step);
    }
    return .{ .exe = exe, .anole = anole_dep };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features = resolveFeatures(b);

    // Options are declared before the lazy-dependency return below: one
    // first declared after it is "invalid" on a fresh cache's first pass.
    const redis_test_port = b.option(u16, "redis-test-port", "Run the Redis tests against a live Redis/Valkey on this port of 127.0.0.1");
    const redis_test_url = b.option([]const u8, "redis-test-url", "Run the Redis tests against a live Redis/Valkey at this URL (redis://, rediss://...)");
    const postgres_test_url = b.option([]const u8, "postgres-test-url", "Run the PostgreSQL tests against a live server at this URL (postgres://...)");
    const mongodb_test_url = b.option([]const u8, "mongodb-test-url", "Run the MongoDB tests against a live server at this URL (mongodb://...)");
    // `zig build test --fuzz` needs LLVM: Zig 0.17's self-hosted backend (the
    // Debug default on x86_64-linux) emits no coverage tables, so the fuzzer
    // would see none ("pcs_len was zero").
    const use_llvm = b.option(bool, "llvm", "Build the unit tests with LLVM (needed for --fuzz on x86_64-linux)");
    // The BSON corpus, a test-only download: requested here so a fresh cache
    // fetches it with the C libraries, and never for a project depending on
    // Anole.
    const mongodb_specs = if (b.isRoot() and features.mongodb) b.lazyDependency("mongodb_specs", .{}) else null;

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

    // Core: zio (runtime) and the HTTP core (src/http/core), always on.
    const core = Core.init(b, c_mods, target, optimize);
    // pg.zig's TLS: Anole's BoringSSL client (src/pg/tls.zig).
    if (c_mods.pg_tls) |pg| pg.addImport("tls", b.createModule(.{
        .root_source_file = b.path("src/pg/tls.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "anole_dusty_tls", .module = core.tls_seam.? }},
    }));

    // BSON (src/bson), the codec under the MongoDB client: pure Zig, its own
    // module, imported by the anole module as "bson" when -Dmongodb is on
    // (here or in a test-flags combination); nothing compiles it otherwise.
    const bson_mod = b.createModule(.{ .root_source_file = b.path("src/bson/root.zig"), .target = target, .optimize = optimize });

    // The public `anole` module, for `b.dependency("anole", ...).module("anole")`.
    const anole_mod = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .bson = bson_mod, .target = target, .optimize = optimize, .public = true });
    // zig-protobuf's runtime, which the code `addProtoGen` generates imports
    // as "protobuf": `anole_dep.module("protobuf")`.
    if (c_mods.protobuf) |m| _ = b.modules.getOrPutValue(b.graph.arena, "protobuf", m) catch @panic("OOM");

    // docs: Zig's autodoc for the `anole` module, in zig-out/docs (the docs
    // site serves it at /anole/api/). It documents the features that are on,
    // so run it with the default full profile. Only the docs are emitted
    // (-fno-emit-bin), though the C libraries the module links are built.
    if (b.isRoot()) {
        const docs_obj = b.addObject(.{ .name = "anole", .root_module = anole_mod });
        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs_obj.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });
        b.step("docs", "Generate the API reference (Zig autodoc for the anole module) into zig-out/docs").dependOn(&install_docs.step);
    }

    // test: unit + smoke tests for the enabled features.
    const test_step = b.step("test", "Run unit tests and the smoke tests of the enabled features");
    const tests = b.addTest(.{
        .name = "anole-test",
        .root_module = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .bson = bson_mod, .target = target, .optimize = optimize, .for_test = true, .redis_test_port = redis_test_port, .redis_test_url = redis_test_url, .postgres_test_url = postgres_test_url, .mongodb_test_url = mongodb_test_url }),
        .use_llvm = use_llvm,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_tests.step);

    // test-postgres: the PostgreSQL tests alone ("pg: ..."); with
    // -Dpostgres-test-url, against that server (tests/postgres/run.sh).
    if (features.postgres) {
        const pg_tests = b.addTest(.{ .name = "anole-test-pg", .root_module = tests.root_module, .filters = &.{"pg:"}, .use_llvm = use_llvm });
        const run_pg_tests = b.addRunArtifact(pg_tests);
        run_pg_tests.has_side_effects = postgres_test_url != null;
        b.step("test-postgres", "Run the PostgreSQL tests (live with -Dpostgres-test-url=postgres://...)").dependOn(&run_pg_tests.step);
    }
    // That the options header reached the compiled SQLite (build/sqlite.zig).
    if (c_mods.sqlite_build_test) |run| test_step.dependOn(&run.step);
    // test-sqlite: the SQLite tests alone ("sqlite: ...").
    if (features.sqlite) {
        const sqlite_tests = b.addTest(.{ .name = "anole-test-sqlite", .root_module = tests.root_module, .filters = &.{"sqlite:"}, .use_llvm = use_llvm });
        b.step("test-sqlite", "Run the SQLite tests").dependOn(&b.addRunArtifact(sqlite_tests).step);
    }
    // test-mongodb: the MongoDB client's tests alone (src/mongodb); with
    // -Dmongodb-test-url, against that server (tests/mongodb/run.sh).
    if (features.mongodb) {
        const mongo_tests = b.addTest(.{ .name = "anole-test-mongodb", .root_module = tests.root_module, .filters = &.{"mongodb."}, .use_llvm = use_llvm });
        const run_mongo_tests = b.addRunArtifact(mongo_tests);
        run_mongo_tests.has_side_effects = mongodb_test_url != null;
        b.step("test-mongodb", "Run the MongoDB client's tests (live with -Dmongodb-test-url=mongodb://...)").dependOn(&run_mongo_tests.step);
    }

    // test-redis: the Redis tests alone ("redis: ..."), the session store's
    // and the rate limiter's among them; with -Dredis-test-url (or
    // -Dredis-test-port), against that server (tests/redis/run.sh).
    if (features.redis) {
        const redis_tests = b.addTest(.{ .name = "anole-test-redis", .root_module = tests.root_module, .filters = &.{"redis:"}, .use_llvm = use_llvm });
        const run_redis_tests = b.addRunArtifact(redis_tests);
        run_redis_tests.has_side_effects = redis_test_url != null or redis_test_port != null;
        b.step("test-redis", "Run the Redis tests (live with -Dredis-test-url=redis://...)").dependOn(&run_redis_tests.step);
    }

    // test-capi-engine: the C ABI engine's Zig tests alone (HTTP/2 and
    // HTTP/3 detached answers, the configuration parser).
    {
        const capi_engine_tests = b.addTest(.{ .name = "anole-test-capi", .root_module = tests.root_module, .filters = &.{ "capi engine", "parse: " }, .use_llvm = use_llvm });
        b.step("test-capi-engine", "Run the C ABI engine's Zig tests").dependOn(&b.addRunArtifact(capi_engine_tests).step);
    }

    // The HTTP core's own tests (src/http/core, adapted from lalinsky/dusty)
    // on what Anole builds into it: BoringSSL through src/tls/dusty_tls.zig,
    // nghttp2, zlib-ng, zstd and Brotli. Part of `test`, and `core-test` alone.
    if (core.dusty_by[1][1][1][@intFromBool(features.brotli)] != null and target.query.isNative()) {
        const core_full = core.dusty_by[1][1][1][@intFromBool(features.brotli)].?;
        // A second instance of the same sources and imports, but with the
        // core's zio stub: its tests run on std.testing.io, and the real
        // zio's timers need a zio task.
        const core_root = core_full.root_source_file.?;
        const test_mod = b.createModule(.{
            .root_source_file = core_root,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        var imports = core_full.import_table.iterator();
        while (imports.next()) |e| test_mod.addImport(e.key_ptr.*, e.value_ptr.*);
        test_mod.addAnonymousImport("zio", .{ .root_source_file = b.path("src/http/core/zio_stub.zig") });
        // And the stub HTTP/2 client: Anole's would import these sources a
        // second time.
        test_mod.addAnonymousImport("h2_client", .{ .root_source_file = b.path("src/http/core/h2_client_stub.zig") });
        test_mod.include_dirs.appendSlice(b.allocator, core_full.include_dirs.items) catch @panic("OOM");
        test_mod.link_objects.appendSlice(b.allocator, core_full.link_objects.items) catch @panic("OOM");
        // The core's test runner (some tests log at err on purpose).
        const core_tests = b.addTest(.{
            .name = "core-test",
            .root_module = test_mod,
            .test_runner = .{ .path = b.path("src/http/core/test_runner.zig"), .mode = .simple },
            .use_llvm = use_llvm,
        });
        const run_core_tests = b.addRunArtifact(core_tests);
        // The TLS tests open certs/cert.pem and certs/key.pem from where
        // they run: a certificate made now by tests/test_cert.zig, so no
        // key is committed.
        const make_cert = b.addRunArtifact(b.addExecutable(.{
            .name = "test-cert",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/test_cert.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        }));
        run_core_tests.setCwd(make_cert.addOutputDirectoryArg("certs").dirname());
        test_step.dependOn(&run_core_tests.step);
        // Its "fuzz:" targets again, under Zig's own test runner, which is
        // what drives the fuzzer (the core's runner has none): `zig build
        // test --fuzz` fuzzes them with Anole's.
        const core_fuzz = b.addTest(.{
            .name = "core-fuzz",
            .root_module = test_mod,
            .filters = &.{"fuzz:"},
            .use_llvm = use_llvm,
        });
        test_step.dependOn(&b.addRunArtifact(core_fuzz).step);
        b.step("core-test", "Run the HTTP core's own tests (src/http/core) on Anole's TLS, nghttp2, zlib-ng, zstd and Brotli").dependOn(&run_core_tests.step);
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
            .root_module = anoleModule(b, .{ .features = combo.features, .core = core, .c = c_mods, .bson = bson_mod, .target = target, .optimize = optimize, .for_test = true }),
        });
        const run = b.addRunArtifact(t);
        run.skip_foreign_checks = true;
        flags_step.dependOn(&run.step);
    }

    // BSON (src/bson) and the MongoDB client's pure parts (src/mongodb:
    // the connection string, SCRAM, the topology state machine), with
    // -Dmongodb. The BSON tests' "fuzz:" targets get src/fuzz.zig as the
    // module "fuzz".
    if (features.mongodb) {
        const bson = bson_mod;
        const bson_tests = b.addTest(.{
            .name = "bson-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bson/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fuzz", .module = b.createModule(.{ .root_source_file = b.path("src/fuzz.zig"), .target = target, .optimize = optimize }) }},
            }),
            .use_llvm = use_llvm,
        });
        const run_bson_tests = b.addRunArtifact(bson_tests);
        run_bson_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_bson_tests.step);
        const bson_step = b.step("bson-test", "Run the BSON codec's tests and the bson-corpus (src/bson, tests/bson)");
        bson_step.dependOn(&run_bson_tests.step);
        const mongodb_spec_step = b.step("mongodb-spec-test", "Run the MongoDB client's spec tests (connection string, URI options, auth, SDAM) from mongodb/specifications");
        // tests/bson/corpus_test.zig over the corpus files, which it embeds:
        // both are copied into one generated directory.
        if (mongodb_specs) |specs| {
            const files = b.addWriteFiles();
            _ = files.addCopyDirectory(specs.path("source/bson-corpus/tests"), "corpus", .{ .include_extensions = &.{".json"} });
            const corpus_tests = b.addTest(.{
                .name = "bson-corpus",
                .root_module = b.createModule(.{
                    .root_source_file = files.addCopyFile(b.path("tests/bson/corpus_test.zig"), "corpus_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "bson", .module = bson }},
                }),
                .use_llvm = use_llvm,
            });
            const run_corpus = b.addRunArtifact(corpus_tests);
            run_corpus.skip_foreign_checks = true;
            test_step.dependOn(&run_corpus.step);
            bson_step.dependOn(&run_corpus.step);

            // src/mongodb/spec_test.zig reads the spec's JSON test files at
            // run time, from the specification's `source` directory.
            const spec_tests = b.addTest(.{
                .name = "mongodb-spec-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/mongodb/spec_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "bson", .module = bson }},
                }),
                .use_llvm = use_llvm,
            });
            const run_spec = b.addRunArtifact(spec_tests);
            run_spec.skip_foreign_checks = true;
            run_spec.setCwd(specs.path("source"));
            test_step.dependOn(&run_spec.step);
            mongodb_spec_step.dependOn(&run_spec.step);
        }
    }

    // examples/<name>: one per protocol or area, each built by `zig build
    // test` when the flags include what it needs, and run with
    // `zig build run-<name>`.
    const Example = struct { name: []const u8, needs: bool, about: []const u8 };
    const examples = [_]Example{
        .{ .name = "hello", .needs = true, .about = "the smallest server, on port 3000" },
        .{ .name = "rest", .needs = true, .about = "a JSON REST API: CRUD in memory, behind an API key, on port 3000" },
        .{ .name = "websocket", .needs = features.websocket, .about = "WebSocket echo and a broadcast room" },
        .{ .name = "grpc", .needs = features.grpc, .about = "a gRPC Greeter, also over gRPC-Web, Connect and REST (JSON transcoding)" },
        .{ .name = "auth", .needs = features.auth and features.json, .about = "JWT bearer tokens, sessions, CSRF, API keys and rate limits" },
        .{ .name = "clients", .needs = features.tls == .boringssl and features.http2 and features.http3, .about = "outbound HTTP/1.1, HTTP/2, HTTP/3 and gRPC" },
        .{ .name = "observe", .needs = true, .about = "metrics, tracing, access logs and health checks" },
        .{ .name = "postgres", .needs = features.postgres, .about = "a posts API on PostgreSQL (DATABASE_URL), on port 3000" },
        .{ .name = "sqlite", .needs = features.sqlite, .about = "a to-do API on SQLite (todos.db, or a path after --), on port 3000" },
        .{ .name = "mongodb", .needs = features.mongodb, .about = "a users API on MongoDB (MONGODB_URI), on port 3000" },
        .{ .name = "redis", .needs = features.redis, .about = "a counter, a cache, a leaderboard and pub/sub on Redis (REDIS_URL), on port 3000" },
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
        b.step(ex.name, b.fmt("Build and install examples/{s}", .{ex.name})).dependOn(&b.addInstallArtifact(ex_exe, .{}).step);
        if (std.mem.eql(u8, ex.name, "rest")) {
            // tests/rest_test.zig serves the example's routes and calls
            // each one.
            const rest_test = b.addTest(.{
                .name = "rest-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/rest_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{ .{ .name = "anole", .module = anole_mod }, .{ .name = "rest", .module = ex_mod } },
                }),
            });
            const run_rest_test = b.addRunArtifact(rest_test);
            run_rest_test.skip_foreign_checks = true;
            test_step.dependOn(&run_rest_test.step);
        }
        if (std.mem.eql(u8, ex.name, "sqlite")) {
            const sqlite_test = b.addTest(.{
                .name = "sqlite-example-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/sqlite_example_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{ .{ .name = "anole", .module = anole_mod }, .{ .name = "sqlite_example", .module = ex_mod } },
                }),
            });
            const run_sqlite_test = b.addRunArtifact(sqlite_test);
            run_sqlite_test.skip_foreign_checks = true;
            test_step.dependOn(&run_sqlite_test.step);
        }
        const run_ex = b.addRunArtifact(ex_exe);
        run_ex.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{ex.name}), b.fmt("Run examples/{s}: {s}", .{ ex.name, ex.about })).dependOn(&run_ex.step);
    }

    // examples/full: every listener and option spelled out; the server
    // tests/h2spec and tests/restart drive.
    const full = b.addExecutable(.{
        .name = "full",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/full/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "anole", .module = anole_mod }},
        }),
    });
    const install_full = b.addInstallArtifact(full, .{});
    b.getInstallStep().dependOn(&install_full.step);
    b.step("full", "Build and install examples/full").dependOn(&install_full.step);
    // `zig build test` also proves the example still compiles.
    test_step.dependOn(&full.step);

    const run_full = b.addRunArtifact(full);
    run_full.addPassthruArgs();
    b.step("run-full", "Run examples/full (pass the ports after --, default 8080 and 8443)").dependOn(&run_full.step);

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

    // capi: libanole, the C ABI (include/anole.h) as a static and a shared
    // library, every exported symbol `anole_*` (src/capi/lib.zig). M17 spike.
    {
        const capi_mod = b.createModule(.{
            .root_source_file = b.path("src/capi/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Linked into shared objects (a Node addon, a Python extension).
            .pic = true,
            .imports = &.{.{ .name = "anole", .module = anole_mod }},
        });
        const capi_opts = b.addOptions();
        capi_opts.addOption([]const u8, "version", @import("build.zig.zon").version);
        capi_mod.addOptions("capi_options", capi_opts);
        // The C++ runtime symbols BoringSSL's objects need, so that libanole
        // needs no libstdc++ or libc++ in the final link (Linux has no
        // std::__1 in libstdc++ at all).
        if ((target.result.os.tag == .linux or target.result.os.tag.isDarwin()) and features.tls == .boringssl) {
            capi_mod.link_libcpp = true;
            capi_mod.addCSourceFile(.{ .file = b.path("src/capi/cxx_shim.cpp"), .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti" } });
        }
        const capi_step = b.step("capi", "Build libanole (static and shared, only anole_* exported) and install include/anole.h");
        // capi-zig: the Zig part alone, as a static library (not
        // self-contained), e.g. to check that it cross-compiles.
        const zig_lib = b.addLibrary(.{ .name = "anole_zig", .linkage = .static, .root_module = capi_mod });
        b.step("capi-zig", "Build only the Zig part of libanole (libanole_zig.a, not self-contained)").dependOn(&b.addInstallArtifact(zig_lib, .{}).step);
        // Packing, with Zig alone: one relocatable object holds the Zig
        // code, every C library it links (the linker pulls in what is
        // used), compiler-rt and, in Debug, the UBSan runtime; it needs only
        // libc. tools/capi_symbols.zig then hides every symbol but anole_*,
        // and the two libraries are made from that object.
        const symbols_tool = b.addExecutable(.{
            .name = "capi_symbols",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/capi_symbols.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const os = target.result.os.tag;
        const packable = os == .linux or os.isDarwin();
        var lib_obj: std.Build.LazyPath = undefined;
        var shared_lib: *std.Build.Step.Compile = undefined;
        var static_lib_opt: ?*std.Build.Step.Compile = null;
        if (packable) {
            const merged = b.addObject(.{ .name = "anole", .root_module = capi_mod });
            merged.bundle_compiler_rt = true;
            merged.bundle_ubsan_rt = true;
            const hide = b.addRunArtifact(symbols_tool);
            hide.addArg("hide");
            hide.addFileArg(merged.getEmittedBin());
            lib_obj = hide.addOutputFileArg("anole.o");
            const static_lib = b.addLibrary(.{
                .name = "anole",
                .linkage = .static,
                .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
            });
            static_lib.root_module.addObjectFile(lib_obj);
            capi_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
            static_lib_opt = static_lib;
            shared_lib = b.addLibrary(.{
                .name = "anole",
                .linkage = .dynamic,
                .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true }),
            });
            shared_lib.root_module.addObjectFile(lib_obj);
        } else {
            // COFF cannot merge objects into one, and a DLL exports only
            // what is dllexport (the anole_* functions): Windows gets
            // anole.dll and its import library, linked from the module.
            shared_lib = b.addLibrary(.{ .name = "anole", .linkage = .dynamic, .root_module = capi_mod });
            shared_lib.bundle_compiler_rt = true;
            shared_lib.bundle_ubsan_rt = true;
        }
        capi_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
        // The symbol check runs with every build of libanole on Linux and
        // macOS: the object and the shared library export anole_* alone.
        if (packable) for ([_]std.Build.LazyPath{ lib_obj, shared_lib.getEmittedBin() }) |file| {
            const check = b.addRunArtifact(symbols_tool);
            check.addArg("check");
            check.addFileArg(file);
            check.expectExitCode(0);
            capi_step.dependOn(&check.step);
        };

        // capi-test (also part of `test`): anole.h's layout against
        // src/capi/abi.zig (the header through translate-c), the symbol
        // check, and the C suite (tests/capi/consumer.c) on libanole.a.
        const capi_test_step = b.step("capi-test", "Test the C ABI: anole.h layout, exported symbols, the C suite");
        if (b.lazyImport(@This(), "translate_c")) |tc| if (b.lazyDependency("translate_c", .{})) |tc_dep| {
            const header: tc.Translator = .init(tc_dep, .{
                .name = "anole_h",
                .c_source_file = b.path("include/anole.h"),
                .target = target,
                .optimize = optimize,
            });
            const abi_test = b.addTest(.{
                .name = "capi-abi-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi/abi_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "capi_abi", .module = b.createModule(.{ .root_source_file = b.path("src/capi/abi.zig"), .target = target, .optimize = optimize }) },
                        .{ .name = "anole_h", .module = header.mod },
                    },
                }),
            });
            capi_test_step.dependOn(&b.addRunArtifact(abi_test).step);
        };
        if (static_lib_opt) |static_lib| {
            capi_test_step.dependOn(capi_step);
            const consumer = b.addExecutable(.{
                .name = "capi-consumer",
                .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
            });
            consumer.root_module.addCSourceFile(.{ .file = b.path("tests/capi/consumer.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-missing-field-initializers" } });
            consumer.root_module.addIncludePath(b.path("include"));
            consumer.root_module.linkLibrary(static_lib);
            const run_consumer = b.addRunArtifact(consumer);
            run_consumer.addArg("test");
            // Its progress lines and Anole's warnings (a drain cut short on
            // purpose) on the terminal; a failure is its exit code.
            run_consumer.stdio = .inherit;
            run_consumer.has_side_effects = true;
            // The PostgreSQL part of the suite, against that server.
            if (postgres_test_url) |url| run_consumer.setEnvironmentVariable("ANOLE_TEST_POSTGRES_URL", url);
            capi_test_step.dependOn(&run_consumer.step);
            b.step("capi-consumer", "Build the C consumer (tests/capi/consumer.c: `test`, or `serve` for benchmarks)").dependOn(&b.addInstallArtifact(consumer, .{}).step);

            // capi-test-asan: the C suite built by the system C compiler
            // with AddressSanitizer and UBSan (Zig ships no ASan runtime);
            // libanole itself keeps Zig's own safety checks.
            const asan_step = b.step("capi-test-asan", "Run the C ABI suite built with -fsanitize=address,undefined (needs a system cc)");
            const cc = b.addSystemCommand(&.{ "cc", "-O1", "-g", "-std=c11", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-fno-sanitize-recover=undefined" });
            cc.addPrefixedDirectoryArg("-I", b.path("include"));
            cc.addFileArg(b.path("tests/capi/consumer.c"));
            cc.addFileArg(static_lib.getEmittedBin());
            if (os == .linux) cc.addArgs(&.{ "-lpthread", "-ldl", "-lm" });
            cc.addArg("-o");
            const asan_exe = cc.addOutputFileArg("capi-consumer-asan");
            const run_asan = std.Build.Step.Run.create(b, "run capi-consumer-asan");
            run_asan.addFileArg(asan_exe);
            run_asan.addArg("test");
            run_asan.has_side_effects = true;
            run_asan.stdio = .inherit;
            // Zig's threads install a signal stack of their own (for the
            // stack-overflow handler); ASan's would unmap it at thread exit.
            run_asan.setEnvironmentVariable("ASAN_OPTIONS", "use_sigaltstack=0");
            if (postgres_test_url) |url| run_asan.setEnvironmentVariable("ANOLE_TEST_POSTGRES_URL", url);
            asan_step.dependOn(&run_asan.step);
        }
        test_step.dependOn(capi_test_step);
        capi_step.dependOn(&b.addInstallHeaderFile(b.path("include/anole.h"), "anole.h").step);
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
        // The interop runner's WebTransport server endpoint
        // (tests/interop/webtransport).
        const wt_interop = b.addExecutable(.{
            .name = "wt-interop-server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/h3/wt_interop.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "anole", .module = anole_mod }},
            }),
        });
        b.step("wt-interop-server", "Build the interop runner's WebTransport server (tests/interop/webtransport/run.sh)").dependOn(&b.addInstallArtifact(wt_interop, .{}).step);
        test_step.dependOn(&wt_interop.step);
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
            // google/api/annotations.proto and http.proto come from
            // src/grpc/proto (vendored, Apache-2.0).
            const gen_transcode = pb.RunProtocStep.create(b, target, .{
                .source_files = &.{b.path("tests/grpc/proto/transcode.proto")},
                .include_directories = &.{ b.path("tests/grpc/proto"), b.path("src/grpc/proto") },
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
                .include_directories = &.{ b.path("examples/grpc/proto"), b.path("src/grpc/proto") },
                .destination_directory = b.path("examples/grpc/gen"),
                .generator = dep.artifact("protoc-gen-zig"),
            });
            const gen = b.step("gen-proto", "Regenerate the Zig for Anole's .proto files (committed)");
            gen.dependOn(gen_example.step);
            gen.dependOn(gen_health.step);
            gen.dependOn(gen_test.step);
            gen.dependOn(gen_transcode.step);
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
/// turns http3 off, `-Dhttp2=false` turns grpc off, `-Dcompression=false`
/// brotli); an explicit contradiction
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
    const brotli = b.option(bool, "brotli", "Brotli response compression (google/brotli); needs -Dcompression=true (overrides the profile)");
    const json = b.option(bool, "json", "JSON on yyjson (overrides the profile)");
    const redis = b.option(bool, "redis", "Redis/Valkey client on hiredis (overrides the profile)");
    const postgres = b.option(bool, "postgres", "PostgreSQL client (overrides the profile)");
    const sqlite = b.option(bool, "sqlite", "SQLite, built in (overrides the profile)");
    const mongodb = b.option(bool, "mongodb", "MongoDB client (overrides the profile)");

    var f = Features.preset(profile);
    if (tls) |v| f.tls = v;
    if (http2) |v| f.http2 = v;
    if (http3) |v| f.http3 = v;
    if (grpc) |v| f.grpc = v;
    if (websocket) |v| f.websocket = v;
    if (auth) |v| f.auth = v;
    if (compression) |v| f.compression = v;
    if (brotli) |v| f.brotli = v;
    if (json) |v| f.json = v;
    if (redis) |v| f.redis = v;
    if (postgres) |v| f.postgres = v;
    if (sqlite) |v| f.sqlite = v;
    if (mongodb) |v| f.mongodb = v;

    if (f.tls == .none and http3 == null) f.http3 = false;
    if (!f.http2 and grpc == null) f.grpc = false;
    if (!f.compression and brotli == null) f.brotli = false;

    if (f.invalid()) |msg| {
        std.debug.print("error: invalid Anole feature flags: {s}\n", .{msg});
        std.process.exit(1);
    }
    return f;
}

/// llhttp (src/http/core/llhttp, MIT): its bindings and its static library,
/// made once and shared by every HTTP core instance.
const LlHttp = struct {
    mod: *std.Build.Module,
    lib: *std.Build.Step.Compile,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) LlHttp {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/http/core/llhttp/llhttp.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addIncludePath(b.path("src/http/core/llhttp"));
        const lib = b.addLibrary(.{
            .name = "llhttp",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        lib.root_module.addCSourceFiles(.{
            .root = b.path("src/http/core/llhttp"),
            .files = &.{ "llhttp.c", "api.c", "http.c" },
            .flags = &.{"-std=c99"},
        });
        lib.root_module.addIncludePath(b.path("src/http/core/llhttp"));
        return .{ .mod = tc.createModule(), .lib = lib };
    }
};

const Core = struct {
    zio: *std.Build.Module,
    llhttp: LlHttp,
    /// dusty instances by [tls][http2][compression][brotli]. One exists for
    /// each combination this build can satisfy: TLS needs BoringSSL in the
    /// build, HTTP/2 nghttp2, compression zlib-ng, Brotli google/brotli and
    /// compression. Different arguments give separate dusty instances, so
    /// test-flags can build every combination side by side.
    dusty_by: [2][2][2][2]?*std.Build.Module,
    /// src/h2/client.zig for each HTTP/2 dusty instance, which imports it as
    /// `h2_client` (and it imports that dusty back), by the same index.
    h2_client_by: [2][2][2][2]?*std.Build.Module,
    /// src/tls/dusty_tls.zig, the module the TLS instances import as `tls`.
    tls_seam: ?*std.Build.Module,

    fn init(b: *std.Build, c_mods: CModules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Core {
        // Pinned by default (zio's own default is work stealing), so a
        // program that declares no `zio_options` still gets what Anole needs;
        // anole.Server refuses to compile with work stealing declared.
        const zio_mod = b.dependency("zio", .{ .target = target, .optimize = optimize, .scheduling = .pinned }).module("zio");
        const seam: ?*std.Build.Module = if (c_mods.boringssl) |bssl| b.createModule(.{
            .root_source_file = b.path("src/tls/dusty_tls.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "anole_boringssl_c", .module = bssl }},
        }) else null;
        var core: Core = .{ .zio = zio_mod, .llhttp = LlHttp.init(b, target, optimize), .dusty_by = @splat(@splat(@splat(@splat(null)))), .h2_client_by = @splat(@splat(@splat(@splat(null)))), .tls_seam = seam };
        for ([_]bool{ false, true }) |tls| {
            if (tls and seam == null) continue;
            for ([_]bool{ false, true }) |http2| {
                if (http2 and c_mods.nghttp2 == null) continue;
                for ([_]bool{ false, true }) |compression| {
                    if (compression and c_mods.zlib == null) continue;
                    for ([_]bool{ false, true }) |brotli| {
                        if (brotli and (!compression or c_mods.brotli == null)) continue;
                        const dusty_mod = coreModule(
                            b,
                            zio_mod,
                            core.llhttp,
                            if (tls) seam else null,
                            if (http2) c_mods.nghttp2 else null,
                            if (compression) c_mods.zlib else null,
                            if (compression) c_mods.zstd else null,
                            if (brotli) c_mods.brotli else null,
                            target,
                            optimize,
                        );
                        core.dusty_by[@intFromBool(tls)][@intFromBool(http2)][@intFromBool(compression)][@intFromBool(brotli)] = dusty_mod;
                        if (http2) core.h2_client_by[@intFromBool(tls)][1][@intFromBool(compression)][@intFromBool(brotli)] = h2ClientModule(
                            b,
                            dusty_mod,
                            c_mods.nghttp2.?,
                            if (tls) seam else null,
                            target,
                            optimize,
                        );
                    }
                }
            }
        }
        return core;
    }

    fn dusty(core: Core, f: Features) *std.Build.Module {
        return core.dusty_by[@intFromBool(f.needsTls())][@intFromBool(f.http2)][@intFromBool(f.compression)][@intFromBool(f.brotli)].?;
    }

    fn h2Client(core: Core, f: Features) *std.Build.Module {
        return core.h2_client_by[@intFromBool(f.needsTls())][@intFromBool(f.http2)][@intFromBool(f.compression)][@intFromBool(f.brotli)].?;
    }

    /// The HTTP/2 client, as its own module so dusty's client can take it
    /// (`h2_client`): a TLS connection on which ALPN picks "h2" is handed
    /// to it. The two modules import each other.
    fn h2ClientModule(
        b: *std.Build,
        dusty_mod: *std.Build.Module,
        nghttp2: *std.Build.Module,
        tls: ?*std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/h2/client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const opts = b.addOptions();
        opts.addOption(bool, "tls", tls != null);
        mod.addOptions("anole_h2_options", opts);
        mod.addImport("anole_nghttp2_c", nghttp2);
        mod.addImport("dusty", dusty_mod);
        if (tls) |m| mod.addImport("anole_dusty_tls", m);
        dusty_mod.addImport("h2_client", mod);
        return mod;
    }

    /// The HTTP core (src/http/core, adapted from lalinsky/dusty) for one
    /// combination of TLS, HTTP/2, compression and Brotli. What a combination leaves
    /// out gets the core's stub instead (`tls`, `zlib`), or no import at all.
    fn coreModule(
        b: *std.Build,
        zio_mod: *std.Build.Module,
        llhttp: LlHttp,
        tls: ?*std.Build.Module,
        nghttp2: ?*std.Build.Module,
        zlib: ?*std.Build.Module,
        zstd: ?*std.Build.Module,
        brotli: ?*std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) *std.Build.Module {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/http/core/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const opts = b.addOptions();
        opts.addOption(bool, "use_tls", tls != null);
        opts.addOption(bool, "use_http2", nghttp2 != null);
        opts.addOption(bool, "use_zlib", zlib != null);
        opts.addOption(bool, "use_zstd", zstd != null);
        opts.addOption(bool, "use_brotli", brotli != null);
        mod.addOptions("build_options", opts);
        // The real runtime, so timeouts use zio.AutoCancel; the core's own
        // tests use src/http/core/zio_stub.zig instead.
        mod.addImport("zio", zio_mod);
        // Replaced by src/h2/client.zig in the HTTP/2 instances (h2ClientModule).
        mod.addAnonymousImport("h2_client", .{ .root_source_file = b.path("src/http/core/h2_client_stub.zig") });
        if (tls) |m| mod.addImport("tls", m) else mod.addAnonymousImport("tls", .{ .root_source_file = b.path("src/http/core/tls_stub.zig") });
        if (nghttp2) |m| mod.addImport("nghttp2", m);
        if (zlib) |m| mod.addImport("zlib", m) else mod.addAnonymousImport("zlib", .{ .root_source_file = b.path("src/http/core/zlib_stub.zig") });
        if (zstd) |m| mod.addImport("zstd", m);
        if (brotli) |m| mod.addImport("brotli", m);
        mod.addImport("llhttp", llhttp.mod);
        // llhttp is a library of its own, not C sources of this module, so
        // the module holds only Zig: Zig 0.17's fuzzer cannot take clang's
        // coverage tables from C compiled into a fuzzed module.
        mod.linkLibrary(llhttp.lib);
        mod.addIncludePath(b.path("src/http/core/llhttp"));
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
    /// brotli/encode.h and brotli/decode.h (brotli)
    brotli: ?*std.Build.Module = null,
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
    /// xuckless/pg.zig (postgres), pure Zig, fetched lazily. Two instances:
    /// one whose `tls` import is Anole's BoringSSL client (src/pg/tls.zig,
    /// added in `build` once the core's TLS module exists), and one built
    /// without TLS, for builds that leave it out.
    pg_tls: ?*std.Build.Module = null,
    pg_plain: ?*std.Build.Module = null,
    /// xuckless/zig-sqlite's `sqlite` module over the SQLite amalgamation
    /// (sqlite), and the build test of the two (tests only).
    sqlite: ?*std.Build.Module = null,
    sqlite_build_test: ?*std.Build.Step.Run = null,

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
        const brotli_dep = if (f.brotli) b.lazyDependency("brotli", .{}) else null;
        // Only its src/root.zig is used (its module would compile a second,
        // vendored zlib).
        const zlib_zig_dep = if (f.compression) b.lazyDependency("zlib_zig", .{}) else null;
        const websocket_dep = if (f.websocket) b.lazyDependency("websocket_zig", .{ .target = target, .optimize = optimize }) else null;
        const protobuf_dep = if (f.grpc) b.lazyDependency("protobuf", .{ .target = target, .optimize = optimize }) else null;
        const yyjson_dep = if (f.json) b.lazyDependency("yyjson", .{}) else null;
        const hiredis_dep = if (f.redis) b.lazyDependency("hiredis", .{}) else null;
        const jwt_dep = if (f.auth) b.lazyDependency("zig_jwt", .{ .target = target, .optimize = optimize }) else null;
        const pg_tls_dep = if (f.postgres and f.needsTls()) b.lazyDependency("pg", .{ .target = target, .optimize = optimize, .tls = .injected }) else null;
        const pg_plain_dep = if (f.postgres) b.lazyDependency("pg", .{ .target = target, .optimize = optimize, .tls = .none }) else null;
        // zig-sqlite translates the amalgamation's sqlite3.h, so its
        // arguments need the amalgamation first: one more configure pass on
        // a fresh cache.
        const sqlite_dep = if (f.sqlite) b.lazyDependency("sqlite_amalgamation", .{}) else null;
        const sqlite_config = if (sqlite_dep != null) sqlite_build.configHeader(b) else null;
        const zig_sqlite_dep = if (sqlite_dep) |up| b.lazyDependency("zig_sqlite", sqlite_build.zigSqliteArgs(up, sqlite_config.?, target, optimize)) else null;

        if (f.needsTranslateC() and tc_dep == null) return null;
        if (f.http2 and nghttp2_dep == null) return null;
        if (f.needsTls() and boringssl_dep == null) return null;
        if (f.http3 and (ngtcp2_dep == null or nghttp3_dep == null)) return null;
        if (f.compression and (zlib_ng_dep == null or zstd_dep == null or zlib_zig_dep == null)) return null;
        if (f.brotli and brotli_dep == null) return null;
        if (f.websocket and websocket_dep == null) return null;
        if (f.grpc and protobuf_dep == null) return null;
        if (f.json and yyjson_dep == null) return null;
        if (f.redis and hiredis_dep == null) return null;
        if (f.auth and jwt_dep == null) return null;
        if (f.postgres and (pg_plain_dep == null or (f.needsTls() and pg_tls_dep == null))) return null;
        if (f.sqlite and (sqlite_dep == null or zig_sqlite_dep == null)) return null;

        // Both vendor sfparse and export the same symbols; stop if they differ.
        if (nghttp2_dep != null and nghttp3_dep != null) nghttp3_build.checkSharedSfparse(b, nghttp2_dep.?, nghttp3_dep.?);

        var m: CModules = .{};
        if (websocket_dep) |dep| m.websocket = dep.module("websocket");
        if (protobuf_dep) |dep| m.protobuf = dep.module("protobuf");
        if (jwt_dep) |dep| m.jwt = dep.module("zig-jwt");
        if (pg_tls_dep) |dep| m.pg_tls = dep.module("pg");
        if (pg_plain_dep) |dep| m.pg_plain = dep.module("pg");
        if (zig_sqlite_dep) |dep| {
            const lib = sqlite_build.library(b, sqlite_dep.?, sqlite_config.?, target, optimize);
            m.sqlite = sqlite_build.module(dep, lib);
            m.sqlite_build_test = sqlite_build.buildTest(b, m.sqlite.?, target, optimize);
        }
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
        if (brotli_dep) |up| {
            const lib = brotli_build.library(b, up, target, optimize);
            m.brotli = brotli_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
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
    redis_test_url: ?[]const u8 = null,
    postgres_test_url: ?[]const u8 = null,
    mongodb_test_url: ?[]const u8 = null,
    /// src/bson as a module, for -Dmongodb.
    bson: ?*std.Build.Module = null,
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
    options.addOption(bool, "brotli", f.brotli);
    options.addOption(bool, "json", f.json);
    options.addOption(bool, "redis", f.redis);
    options.addOption(bool, "postgres", f.postgres);
    options.addOption(bool, "sqlite", f.sqlite);
    options.addOption(bool, "mongodb", f.mongodb);
    // Live servers for tests (`-Dredis-test-port=6379` or
    // `-Dredis-test-url=redis://...`,
    // `-Dpostgres-test-url=postgres://...`, `-Dmongodb-test-url=mongodb://...`),
    // else those tests skip.
    options.addOption(?u16, "redis_test_port", o.redis_test_port);
    options.addOption(?[]const u8, "redis_test_url", o.redis_test_url);
    options.addOption(?[]const u8, "postgres_test_url", o.postgres_test_url);
    options.addOption(?[]const u8, "mongodb_test_url", o.mongodb_test_url);

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
    if (f.http2) {
        mod.addImport("anole_nghttp2_c", o.c.nghttp2.?);
        mod.addImport("anole_h2_client", o.core.h2Client(f));
    }
    if (f.websocket) mod.addImport("anole_websocket_codec", o.c.websocket.?);
    if (f.grpc) mod.addImport("protobuf", o.c.protobuf.?);
    if (f.json) mod.addImport("anole_yyjson_c", o.c.yyjson.?);
    if (f.redis) mod.addImport("anole_hiredis_c", o.c.hiredis.?);
    if (f.mongodb) mod.addImport("bson", o.bson.?);
    if (f.auth) mod.addImport("anole_jwt", o.c.jwt.?);
    if (f.postgres) mod.addImport("anole_pg", if (f.needsTls()) o.c.pg_tls.? else o.c.pg_plain.?);
    if (f.sqlite) mod.addImport("anole_sqlite", o.c.sqlite.?);
    // The generated test service (tests/grpc/gen), outside src/.
    // The C ABI's configuration schema, for the test that keeps it in step
    // with src/capi/config.zig.
    if (o.for_test) {
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(b.path("include/anole.schema.json"), "anole.schema.json");
        mod.addAnonymousImport("anole_capi_schema", .{ .root_source_file = wf.add("schema.zig", "pub const text = @embedFile(\"anole.schema.json\");\n") });
    }
    if (f.grpc and o.for_test) mod.addImport("anole_test_pb", b.createModule(.{
        .root_source_file = b.path("tests/grpc/gen/anole/test.pb.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "protobuf", .module = o.c.protobuf.? }},
    }));
    // The JSON transcoding test service (google.api.http annotations).
    if (f.grpc and o.for_test) mod.addImport("anole_transcode_pb", b.createModule(.{
        .root_source_file = b.path("tests/grpc/gen/transcode.pb.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "protobuf", .module = o.c.protobuf.? }},
    }));
    if (f.compression) {
        mod.addImport("anole_zlib", o.c.zlib.?);
        mod.addImport("anole_zlib_c", o.c.zlib_c.?);
        mod.addImport("anole_zstd_c", o.c.zstd.?);
    }
    if (f.brotli) mod.addImport("anole_brotli_c", o.c.brotli.?);
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
