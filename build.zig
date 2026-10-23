//! Anole build.
//!
//! Features are chosen with `-Dprofile=minimal|web|full` (default `full`) and
//! overridden one by one with `-Dtls=boringssl|none`, `-Dhttp2`, `-Dhttp3`,
//! `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dpostgres`, `-Dsqlite`, `-Dmongodb`, `-Dopenapi`,
//! `-Dnet`, `-Djobs`, `-Dwebhooks`, `-Ds3`, `-Dsmtp`, `-Dlambda` and the rest below. The result is exposed to Zig code as the `build_options`
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
const lz4_build = @import("build/lz4.zig");
const yyjson_build = @import("build/yyjson.zig");
const upb_build = @import("build/upb.zig");
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

/// `-Ddefault-deployment`: src/modes.zig's `Deployment`, by name.
pub const DefaultDeployment = enum { standalone, behind_proxy, anole_lb, platform, lambda };

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
    /// The NATS client (`anole.nats`).
    nats: bool,
    /// The Kafka client (`anole.kafka`); needs `compression`.
    kafka: bool,
    /// OpenAPI 3.1 documents (`anole.openapi`, `app.openapi`). Pure Zig:
    /// no C library. libanole is always built without it.
    openapi: bool,
    /// The live console (`anole console`, `c` + Enter in development): the
    /// control socket, log and error rings and the terminal UI. Pure Zig:
    /// no C library.
    console: bool,
    /// Raw TCP and UDP servers (`anole.net`'s listeners). Pure Zig.
    net: bool,
    /// Durable jobs and cron (`anole.jobs`, `anole.cron`). The stores
    /// follow their own flags; the memory store always works. Pure Zig.
    jobs: bool,
    /// Webhooks out and the Verify middleware (`anole.webhooks`); needs
    /// `jobs`. Pure Zig.
    webhooks: bool,
    /// The S3-compatible object storage client (`anole.s3`). Pure Zig.
    s3: bool,
    /// The SMTP client for sending mail (`anole.smtp`). Pure Zig.
    smtp: bool,
    /// The AWS Lambda adapter (`anole.lambda`, `deployment = lambda`).
    /// Pure Zig.
    lambda: bool,
    /// The deployment a program falls back on when neither the options nor
    /// ANOLE_DEPLOYMENT name one (`-Ddefault-deployment`; `zig build
    /// lambda` builds with `lambda`). Not a feature: it compiles nothing in
    /// or out.
    default_deployment: DefaultDeployment = .standalone,

    pub fn preset(profile: Profile) Features {
        return switch (profile) {
            // HTTP/1.1 only.
            .minimal => .{ .tls = .none, .http2 = false, .http3 = false, .grpc = false, .websocket = false, .auth = false, .compression = false, .brotli = false, .json = false, .redis = false, .postgres = false, .sqlite = false, .mongodb = false, .nats = false, .kafka = false, .openapi = false, .console = false, .net = false, .jobs = false, .webhooks = false, .s3 = false, .smtp = false, .lambda = true },
            .web => .{ .tls = .boringssl, .http2 = true, .http3 = false, .grpc = false, .websocket = true, .auth = true, .compression = true, .brotli = true, .json = true, .redis = false, .postgres = true, .sqlite = true, .mongodb = false, .nats = false, .kafka = false, .openapi = true, .console = true, .net = true, .jobs = true, .webhooks = true, .s3 = true, .smtp = true, .lambda = true },
            .full => .{ .tls = .boringssl, .http2 = true, .http3 = true, .grpc = true, .websocket = true, .auth = true, .compression = true, .brotli = true, .json = true, .redis = true, .postgres = true, .sqlite = true, .mongodb = true, .nats = true, .kafka = true, .openapi = true, .console = true, .net = true, .jobs = true, .webhooks = true, .s3 = true, .smtp = true, .lambda = true },
        };
    }

    /// Null when the combination is valid, otherwise what is wrong with it.
    pub fn invalid(f: Features) ?[]const u8 {
        if (f.grpc and !f.http2) return "-Dgrpc=true requires -Dhttp2=true (gRPC's HTTP/2 path and its client; HTTP/3 is added with -Dhttp3)";
        if (f.http3 and f.tls == .none) return "-Dhttp3=true requires -Dtls=boringssl (QUIC always uses TLS 1.3)";
        if (f.brotli and !f.compression) return "-Dbrotli=true requires -Dcompression=true (Brotli is one of the Compress middleware's codings)";
        if (f.kafka and !f.compression) return "-Dkafka=true requires -Dcompression=true (Kafka batches use gzip and zstd)";
        if (f.webhooks and !f.jobs) return "-Dwebhooks=true requires -Djobs=true (webhook deliveries run as jobs)";
        return null;
    }

    fn needsTls(f: Features) bool {
        return f.tls == .boringssl;
    }
    fn needsTranslateC(f: Features) bool {
        return f.tls != .none or f.http2 or f.http3 or f.compression or f.json or f.redis or f.sqlite or f.grpc;
    }
    /// True when every C library `f` needs is also needed by `have`.
    fn coveredBy(f: Features, have: Features) bool {
        return (!f.needsTls() or have.needsTls()) and (!f.http2 or have.http2) and (!f.http3 or have.http3) and
            (!f.compression or have.compression) and (!f.brotli or have.brotli) and (!f.websocket or have.websocket) and (!f.grpc or have.grpc) and
            (!f.json or have.json) and (!f.redis or have.redis) and (!f.auth or have.auth) and
            (!f.postgres or have.postgres) and (!f.sqlite or have.sqlite) and (!f.mongodb or have.mongodb) and
            (!f.nats or have.nats) and (!f.kafka or have.kafka);
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
        f.kafka = false;
        break :blk f;
    } },
    // Everything but the brokers.
    .{ .name = "brokers-none", .features = blk: {
        var f = Features.preset(.full);
        f.nats = false;
        f.kafka = false;
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
    // No OpenAPI: `anole.openapi` is the declaration stubs only.
    .{ .name = "full-no-openapi", .features = blk: {
        var f = Features.preset(.full);
        f.openapi = false;
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
    // The smallest build without the Lambda adapter: `anole.lambda` is the
    // stub, and `deployment = lambda` fails with LambdaNotBuilt.
    .{ .name = "minimal-no-lambda", .features = blk: {
        var f = Features.preset(.minimal);
        f.lambda = false;
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
/// `build_util.getProtocBin`, which its build.zig does not export). Google's
/// release binaries, pinned by hash in zig-protobuf's build.zig.zon; on
/// Windows the win64 one (also on arm64 Windows, which runs x64 programs).
fn protocBinary(pb_builder: *std.Build) ?std.Build.LazyPath {
    const name = switch (builtin.os.tag) {
        .windows => "protoc-win64",
        .macos, .linux => "protoc-" ++ (if (builtin.os.tag == .macos) "osx" else "linux") ++ "-" ++ switch (builtin.cpu.arch) {
            .aarch64 => "aarch_64",
            .x86_64 => "x86_64",
            .x86 => "x86_32",
            else => @compileError("protoc: no pinned binary for this CPU"),
        },
        else => @compileError("protoc: Anole builds on Linux, macOS and Windows"),
    };
    const dep = pb_builder.lazyDependency(name, .{}) orelse return null;
    return dep.path(if (builtin.os.tag == .windows) "bin/protoc.exe" else "bin/protoc");
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
    /// Single features on or off over the preset, as Anole's own
    /// `-D<feature>` flags do (`.features = .{ .postgres = false }`); null
    /// leaves the preset's choice.
    features: FeatureFlags = .{},
    /// .proto files, each a module the program imports by its `name`,
    /// generated by `zig build` (see `addProtoModule`).
    protos: []const Proto = &.{},
    /// More imports for the program.
    imports: []const std.Build.Module.Import = &.{},
    /// Add `zig build run` (arguments after `--` go to the program).
    run_step: bool = true,
    /// `zig build openapi` (writes the file) and `zig build openapi-check`
    /// (fails when it differs from the app's routes); null: neither step.
    /// Both run the app's executable with `ANOLE_OPENAPI_OUT` /
    /// `ANOLE_OPENAPI_CHECK` set: `run()` writes or compares the document
    /// right after the routes exist and returns before anything binds, so a
    /// project needs no test file or code split. Code before `listen` still
    /// runs: keep secrets in `.env` and connect lazily (the default).
    openapi: ?OpenApiBuild = .{},
    /// `zig build lambda`: the program as AWS Lambda zips
    /// (zig-out/lambda/<name>-<arch>.zip, for `provided.al2023`), built
    /// with `deployment = lambda` as its default (docs/lambda.md). Null: no
    /// such step.
    lambda: ?LambdaBuild = null,
};

/// `AppOptions.features`: Anole's `-D<feature>` flags, each forwarded to
/// the dependency when set.
pub const FeatureFlags = struct {
    tls: ?Tls = null,
    http2: ?bool = null,
    http3: ?bool = null,
    grpc: ?bool = null,
    websocket: ?bool = null,
    auth: ?bool = null,
    compression: ?bool = null,
    brotli: ?bool = null,
    json: ?bool = null,
    redis: ?bool = null,
    postgres: ?bool = null,
    sqlite: ?bool = null,
    mongodb: ?bool = null,
    nats: ?bool = null,
    kafka: ?bool = null,
    openapi: ?bool = null,
    console: ?bool = null,
    net: ?bool = null,
    jobs: ?bool = null,
    webhooks: ?bool = null,
    s3: ?bool = null,
    smtp: ?bool = null,
    lambda: ?bool = null,
};

/// The arguments for Anole's dependency: target, optimize, the preset and
/// every feature flag the app set (null ones are not passed).
fn appDepArgs(options: AppOptions, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, deployment: ?DefaultDeployment) DepArgs {
    const f = options.features;
    return .{
        .target = target,
        .optimize = optimize,
        .profile = options.profile,
        .@"default-deployment" = deployment,
        .tls = f.tls,
        .http2 = f.http2,
        .http3 = f.http3,
        .grpc = f.grpc,
        .websocket = f.websocket,
        .auth = f.auth,
        .compression = f.compression,
        .brotli = f.brotli,
        .json = f.json,
        .redis = f.redis,
        .postgres = f.postgres,
        .sqlite = f.sqlite,
        .mongodb = f.mongodb,
        .nats = f.nats,
        .kafka = f.kafka,
        .openapi = f.openapi,
        .console = f.console,
        .net = f.net,
        .jobs = f.jobs,
        .webhooks = f.webhooks,
        .s3 = f.s3,
        .smtp = f.smtp,
        .lambda = f.lambda,
    };
}

const DepArgs = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    profile: ?Profile,
    @"default-deployment": ?DefaultDeployment,
    tls: ?Tls,
    http2: ?bool,
    http3: ?bool,
    grpc: ?bool,
    websocket: ?bool,
    auth: ?bool,
    compression: ?bool,
    brotli: ?bool,
    json: ?bool,
    redis: ?bool,
    postgres: ?bool,
    sqlite: ?bool,
    mongodb: ?bool,
    nats: ?bool,
    kafka: ?bool,
    openapi: ?bool,
    console: ?bool,
    net: ?bool,
    jobs: ?bool,
    webhooks: ?bool,
    s3: ?bool,
    smtp: ?bool,
    lambda: ?bool,
};

/// `AppOptions.lambda`.
pub const LambdaBuild = struct {
    /// One zip each: zig-out/lambda/<name>-<arch>.zip. `-Dlambda-arch`
    /// picks one.
    arch: []const LambdaArch = &.{ .arm64, .x86_64 },
    /// Files and directories (relative to build.zig) put in the zip beside
    /// bootstrap, under the same relative path: static files, templates.
    /// Lambda runs the program in that directory (LAMBDA_TASK_ROOT,
    /// /var/task).
    include: []const []const u8 = &.{},
    /// `-Dlambda-optimize` overrides.
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
    /// glibc 2.34 (Amazon Linux 2023, `provided.al2023`) or a static musl
    /// binary (any `provided` runtime, container images).
    libc: enum { glibc, musl } = .glibc,
};

/// The architectures Lambda runs: Graviton (arm64) and x86_64.
pub const LambdaArch = enum { arm64, x86_64 };

/// `AppOptions.openapi`.
pub const OpenApiBuild = struct {
    /// Relative to build.zig.
    file: []const u8 = "openapi.json",
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
    const anole_dep = b.dependency(options.dependency, appDepArgs(options, target, optimize, null));
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
    if (options.openapi) |oa| {
        // The run steps' working directory is the project, so the name is relative to it.
        const file = oa.file;
        const write = b.addRunArtifact(exe);
        write.setCwd(b.path("."));
        write.has_side_effects = true;
        write.setEnvironmentVariable("ANOLE_OPENAPI_OUT", file);
        b.step("openapi", b.fmt("Write {s} from the app's routes (runs the app up to listen; nothing binds)", .{oa.file})).dependOn(&write.step);
        const check = b.addRunArtifact(exe);
        check.setCwd(b.path("."));
        check.has_side_effects = true;
        check.setEnvironmentVariable("ANOLE_OPENAPI_CHECK", file);
        b.step("openapi-check", b.fmt("Check that {s} matches the app's routes", .{oa.file})).dependOn(&check.step);
    }
    if (options.lambda) |lb| addLambda(b, options, lb, anole_dep);
    return .{ .exe = exe, .anole = anole_dep };
}

/// `zig build lambda` (and `lambda-arm64`, `lambda-x86_64`): for each
/// architecture, the program built as `bootstrap` for Amazon Linux 2023
/// against its own Anole dependency (the same arguments plus
/// `default-deployment = lambda`), zipped by tools/lambda_zip.zig (built for
/// the host) with the `include` files, and installed as
/// zig-out/lambda/<name>-<arch>.zip.
fn addLambda(b: *std.Build, options: AppOptions, lb: LambdaBuild, anole_dep: *std.Build.Dependency) void {
    const only = b.option(LambdaArch, "lambda-arch", "zig build lambda: only this architecture (arm64 or x86_64)");
    const optimize = b.option(std.builtin.OptimizeMode, "lambda-optimize", "zig build lambda: the optimize mode (default ReleaseSafe)") orelse lb.optimize;
    const all_step = b.step("lambda", b.fmt("Build {s} as AWS Lambda zips (provided.al2023): zig-out/lambda/", .{options.name}));
    const zip_tool = b.addExecutable(.{
        .name = "lambda_zip",
        .root_module = b.createModule(.{
            .root_source_file = anole_dep.path("tools/lambda_zip.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    for (std.enums.values(LambdaArch)) |arch| {
        const arch_step = b.step(b.fmt("lambda-{t}", .{arch}), b.fmt("Build {s} as an AWS Lambda zip for {t}: zig-out/lambda/{s}-{t}.zip", .{ options.name, arch, options.name, arch }));
        const wanted = for (lb.arch) |a| {
            if (a == arch) break true;
        } else false;
        if (!wanted) {
            arch_step.dependOn(&b.addFail(b.fmt("{s}: lambda.arch leaves {t} out", .{ options.name, arch })).step);
            continue;
        }
        const triple = switch (arch) {
            .arm64 => if (lb.libc == .glibc) "aarch64-linux-gnu.2.34" else "aarch64-linux-musl",
            .x86_64 => if (lb.libc == .glibc) "x86_64-linux-gnu.2.34" else "x86_64-linux-musl",
        };
        const cpu = switch (arch) {
            .arm64 => "neoverse_n1",
            .x86_64 => "x86_64_v2+avx2",
        };
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple, .cpu_features = cpu }) catch @panic("lambda target");
        const target = b.resolveTargetQuery(query);
        // A dependency of its own: another target and the lambda default.
        // Reached only through this executable, and its lazy dependencies
        // are fetched in the same configure pass as the main one's.
        const dep = b.dependency(options.dependency, appDepArgs(options, target, optimize, .lambda));
        const exe = b.addExecutable(.{
            .name = "bootstrap",
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = target,
                .optimize = optimize,
                .imports = options.imports,
            }),
        });
        exe.root_module.addImport("anole", dep.module("anole"));
        for (options.protos) |proto| {
            const m = addProtoModule(b, dep, proto);
            m.resolved_target = target;
            m.optimize = optimize;
            exe.root_module.addImport(proto.name, m);
        }
        const zip_name = b.fmt("{s}-{t}.zip", .{ options.name, arch });
        const run = b.addRunArtifact(zip_tool);
        const out = run.addOutputFileArg(zip_name);
        run.addArtifactArg2(exe, .{ .prefix = "bootstrap=", .suffix = ":755" });
        for (lb.include) |rel| {
            const is_dir = blk: {
                const in_root = if (b.root.sub_path.len == 0) rel else b.fmt("{s}/{s}", .{ b.root.sub_path, rel });
                const d = b.root.root_dir.handle.openDir(b.graph.io, in_root, .{}) catch break :blk false;
                d.close(b.graph.io);
                break :blk true;
            };
            if (is_dir) {
                // The tool walks the directory; a change to a file in it
                // must make a new zip, so the step always runs (the zip
                // is the same bytes when nothing changed).
                run.addDirectoryArg2(b.path(rel), .{ .prefix = b.fmt("{s}=", .{rel}) });
                run.has_side_effects = true;
            } else {
                run.addFileArg2(b.path(rel), .{ .prefix = b.fmt("{s}=", .{rel}), .suffix = ":644" });
            }
        }
        const install = b.addInstallFileWithDir(out, .{ .custom = "lambda" }, zip_name);
        arch_step.dependOn(&install.step);
        if (only == null or only.? == arch) all_step.dependOn(&install.step);
    }
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
    const nats_test_url = b.option([]const u8, "nats-test-url", "Run the NATS tests against a live server at this URL (nats://...)");
    const kafka_test_url = b.option([]const u8, "kafka-test-url", "Run the Kafka tests against a live broker at this address (host:port)");
    const s3_test_url = b.option([]const u8, "s3-test-url", "Run the S3 tests against a live S3-compatible server at this URL (http://, https://...)");
    const smtp_test_url = b.option([]const u8, "smtp-test-url", "Run the SMTP tests against a live server at this URL (smtp://, smtps://...)");
    const mailpit_api_url = b.option([]const u8, "mailpit-api-url", "The SMTP tests read what was sent from this Mailpit API (http://...)");
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
    // `zig build test -Dtest-filter="WebSocket over HTTP/2"` runs only the
    // main suite's tests whose names contain the text (repeatable).
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the main suite's tests whose names contain this text (repeatable; zig build test -Dtest-filter=golden)") orelse &.{};
    const tests = b.addTest(.{
        .name = "anole-test",
        .filters = test_filters,
        .root_module = anoleModule(b, .{ .features = features, .core = core, .c = c_mods, .bson = bson_mod, .target = target, .optimize = optimize, .for_test = true, .redis_test_port = redis_test_port, .redis_test_url = redis_test_url, .postgres_test_url = postgres_test_url, .mongodb_test_url = mongodb_test_url, .nats_test_url = nats_test_url, .kafka_test_url = kafka_test_url, .s3_test_url = s3_test_url, .smtp_test_url = smtp_test_url, .mailpit_api_url = mailpit_api_url }),
        .use_llvm = use_llvm,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_tests.step);
    // compile-tests: build the test binaries without running them.
    const compile_tests_step = b.step("compile-tests", "Compile the test binaries without running them");
    compile_tests_step.dependOn(&tests.step);
    // The validator's, the logger's and the banner's own tests: each is its
    // own module (no imports), so the anole test binary does not collect them.
    for ([_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "validate-test", .mod = core.validate },
        .{ .name = "log-test", .mod = core.anole_log },
        .{ .name = "banner-test", .mod = core.banner },
    }) |t| {
        const sub_tests = b.addTest(.{ .name = t.name, .root_module = t.mod, .use_llvm = use_llvm });
        const run_sub = b.addRunArtifact(sub_tests);
        run_sub.skip_foreign_checks = true;
        test_step.dependOn(&run_sub.step);
        compile_tests_step.dependOn(&sub_tests.step);
        b.step(t.name, "Run the tests of the module alone").dependOn(&run_sub.step);
    }

    // ---- p3/lambda ----
    // tools/lambda_zip.zig: the std-only zip writer of `zig build lambda`
    // (the addApp wiring comes with the rest of the adapter). Its tests are
    // part of `test`; `lambda-zip` builds the tool for the host.
    {
        const zip_test = b.addTest(.{
            .name = "lambda-zip-test",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/lambda_zip.zig"), .target = target, .optimize = optimize }),
            .use_llvm = use_llvm,
        });
        const run_zip_test = b.addRunArtifact(zip_test);
        run_zip_test.skip_foreign_checks = true;
        test_step.dependOn(&run_zip_test.step);
        compile_tests_step.dependOn(&zip_test.step);
        b.step("lambda-zip-test", "Run the tests of tools/lambda_zip.zig alone").dependOn(&run_zip_test.step);
        const zip_tool = b.addExecutable(.{
            .name = "lambda_zip",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/lambda_zip.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
        });
        b.step("lambda-zip", "Build the zip writer used by zig build lambda (host tool)").dependOn(&b.addInstallArtifact(zip_tool, .{}).step);
    }
    // ---- end p3/lambda ----

    // test-compile-errors: routes and calls the compiler must refuse, each a
    // tiny file in tests/compile_errors with the message it must give.
    {
        const cases = [_]struct { file: []const u8, contains: []const u8 }{
            .{ .file = "01_wildcard_not_last", .contains = "anole: route GET /a/*x/b: a wildcard (*x) must be the last segment" },
            .{ .file = "02_duplicate_param", .contains = "names the parameter \"id\" twice" },
            .{ .file = "03_query_in_path", .contains = "read the query with req.query, req.bindQuery or anole.In(.{ .query = T }))" },
            .{ .file = "04_in_path_not_a_param", .contains = "is not a parameter of the route (parameters: id)" },
            .{ .file = "05_in_optional_path_field", .contains = "a route parameter is always there" },
            .{ .file = "06_in_body_on_get", .contains = "(use .query, or app.query for the QUERY method)" },
            .{ .file = "07_in_unknown_key", .contains = "anole.In: unknown key .bdy; the keys are .path, .query, .headers and .body (did you mean .body?)" },
            .{ .file = "08_cached_on_post", .contains = "it cannot wrap a POST route" },
            .{ .file = "09_log_tuple_fields", .contains = "for a format string use std.log" },
            .{ .file = "10_log_reserved_field", .contains = "rename it, e.g. 'user_level'" },
            .{ .file = "11_invalid_code_grammar", .contains = "e.g. 'users.name_taken'" },
            .{ .file = "12_rename_on_fallback_type", .contains = "structs, ?T and []const T" },
        };
        const ce_step = b.step("test-compile-errors", "Check that bad routes and calls are compile errors with the right message");
        for (cases) |c| {
            const obj = b.addObject(.{
                .name = c.file,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{c.file})),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "anole", .module = anole_mod }},
                }),
            });
            obj.expect_errors = .{ .contains = c.contains };
            ce_step.dependOn(&obj.step);
        }
        // COFF can't put the anole module's C objects into one object file,
        // so these run on Linux and macOS only (the checks are the same).
        if (target.result.os.tag != .windows) test_step.dependOn(ce_step);
    }

    // The live console's std-only part (src/console/ui): protocol, client, TUI,
    // restart logic. Imported as "anole_console_ui" into the anole module
    // (and so libanole) and the CLI. Its own tests run here.
    {
        const ui_tests = b.addTest(.{
            .name = "console-ui-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/console/ui/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "fuzz", .module = b.createModule(.{ .root_source_file = b.path("src/fuzz.zig"), .target = target, .optimize = optimize }) },
                    .{ .name = "anole_banner", .module = b.createModule(.{ .root_source_file = b.path("src/banner/root.zig"), .target = target, .optimize = optimize }) },
                },
            }),
            .use_llvm = use_llvm,
        });
        const run_ui_tests = b.addRunArtifact(ui_tests);
        run_ui_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_ui_tests.step);
        compile_tests_step.dependOn(&ui_tests.step);
        b.step("console-ui-test", "Run the live console's std-only module tests (protocol, keys, screen, app, restart plan)").dependOn(&run_ui_tests.step);
    }

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

    // ---- p3/s3 ----
    // test-s3: the S3 client's tests alone ("s3: ..."), and the C ABI's
    // storage tests ("capi s3: ..."); with -Ds3-test-url, also against that
    // server (tests/s3/run.sh).
    if (features.s3) {
        const s3_tests = b.addTest(.{ .name = "anole-test-s3", .root_module = tests.root_module, .filters = if (test_filters.len > 0) test_filters else &.{ "s3: ", "capi s3: " }, .use_llvm = use_llvm });
        const run_s3_tests = b.addRunArtifact(s3_tests);
        run_s3_tests.has_side_effects = s3_test_url != null;
        b.step("test-s3", "Run the S3 tests (live with -Ds3-test-url=http://...)").dependOn(&run_s3_tests.step);
    }
    // ---- end p3/s3 ----

    // test-capi-engine: the C ABI engine's Zig tests alone (HTTP/2 and
    // HTTP/3 detached answers, the configuration parser).
    {
        const capi_engine_tests = b.addTest(.{ .name = "anole-test-capi", .root_module = tests.root_module, .filters = &.{ "capi engine", "parse: " }, .use_llvm = use_llvm });
        b.step("test-capi-engine", "Run the C ABI engine's Zig tests").dependOn(&b.addRunArtifact(capi_engine_tests).step);
    }
    // test-net: the raw TCP and UDP tests alone (framing, sessions, the
    // servers over loopback, the C ABI's).
    if (features.net) {
        const net_tests = b.addTest(.{ .name = "anole-test-net", .root_module = tests.root_module, .filters = &.{ "net tcp", "net udp", "framing:", "sessions:", "fuzz: net", "capi net" }, .use_llvm = use_llvm });
        b.step("test-net", "Run the raw TCP and UDP tests (anole.net, the C ABI's anole_net_*)").dependOn(&b.addRunArtifact(net_tests).step);
        b.step("test-net-build", "Build the raw TCP and UDP test binary (zig-out/bin/anole-test-net) without running it").dependOn(&b.addInstallArtifact(net_tests, .{}).step);
    }
    // test-grpc: the gRPC tests alone (the native server and client, JSON
    // transcoding, and the C ABI's gRPC server).
    if (features.grpc) {
        const grpc_tests = b.addTest(.{ .name = "anole-test-grpc", .root_module = tests.root_module, .filters = &.{ "gRPC", "transcoding", "capi grpc" }, .use_llvm = use_llvm });
        b.step("test-grpc", "Run the gRPC tests (native, transcoding, the C ABI's)").dependOn(&b.addRunArtifact(grpc_tests).step);
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
        compile_tests_step.dependOn(&core_tests.step);
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
        .{ .name = "net", .needs = features.net, .about = "a line chat over TCP, a UDP responder with sessions and an HTTP /stats page (ports 7000, 7001, 3000)" },
        .{ .name = "grpc", .needs = features.grpc, .about = "a gRPC Greeter, also over gRPC-Web, Connect and REST (JSON transcoding)" },
        .{ .name = "auth", .needs = features.auth and features.json, .about = "JWT bearer tokens, sessions, CSRF, API keys and rate limits" },
        .{ .name = "clients", .needs = features.tls == .boringssl and features.http2 and features.http3, .about = "outbound HTTP/1.1, HTTP/2, HTTP/3 and gRPC" },
        .{ .name = "observe", .needs = true, .about = "metrics, tracing, access logs and health checks" },
        .{ .name = "postgres", .needs = features.postgres, .about = "a posts API on PostgreSQL (DATABASE_URL), on port 3000" },
        .{ .name = "sqlite", .needs = features.sqlite, .about = "a to-do API on SQLite (todos.db, or a path after --), on port 3000" },
        .{ .name = "mongodb", .needs = features.mongodb, .about = "a users API on MongoDB (MONGODB_URI), on port 3000" },
        .{ .name = "redis", .needs = features.redis, .about = "a counter, a cache, a leaderboard and pub/sub on Redis (REDIS_URL), on port 3000" },
        .{ .name = "lambda", .needs = features.lambda, .about = "the same app as a server on port 3000 or an AWS Lambda function (examples/lambda/README.md)" },
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
            compile_tests_step.dependOn(&rest_test.step);
            // The same scenario through anole.testing, no socket.
            const rest_memory_test = b.addTest(.{
                .name = "rest-memory-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/rest_memory_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{ .{ .name = "anole", .module = anole_mod }, .{ .name = "rest", .module = ex_mod } },
                }),
            });
            const run_rest_memory_test = b.addRunArtifact(rest_memory_test);
            run_rest_memory_test.skip_foreign_checks = true;
            test_step.dependOn(&run_rest_memory_test.step);
            compile_tests_step.dependOn(&rest_memory_test.step);
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
        // libanole never carries OpenAPI: the bindings use their ecosystems' generators.
        var capi_features = features;
        capi_features.openapi = false;
        const capi_anole_mod = anoleModule(b, .{ .features = capi_features, .core = core, .c = c_mods, .bson = bson_mod, .target = target, .optimize = optimize });
        const capi_mod = b.createModule(.{
            .root_source_file = b.path("src/capi/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Linked into shared objects (a Node addon, a Python extension).
            .pic = true,
            .imports = &.{.{ .name = "anole", .module = capi_anole_mod }},
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
            // Mach-O: the merge drops N_ALT_ENTRY/N_NO_DEAD_STRIP, which the
            // tool takes back from the inputs (tools/capi_symbols.zig).
            if (os.isDarwin()) for (linkedInputs(b, capi_mod)) |input| hide.addFileArg(input);
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

        // include/anole.abi.json, generated from src/capi/abi.zig: installed
        // beside the header, regenerated with `zig build capi-abi-json`, and
        // checked fresh by capi-test.
        const abi_mod = b.createModule(.{ .root_source_file = b.path("src/capi/abi.zig"), .target = b.graph.host, .optimize = .Debug });
        const abi_json = b.addExecutable(.{
            .name = "capi_abi_json",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/capi_abi_json.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = &.{.{ .name = "capi_abi", .module = abi_mod }},
            }),
        });
        const abi_json_gen = b.addRunArtifact(abi_json);
        const abi_json_out = abi_json_gen.addOutputFileArg("anole.abi.json");
        capi_step.dependOn(&b.addInstallHeaderFile(abi_json_out, "anole.abi.json").step);
        const abi_json_update = b.addUpdateSourceFiles();
        abi_json_update.addCopyFileToSource(abi_json_out, "include/anole.abi.json");
        b.step("capi-abi-json", "Regenerate include/anole.abi.json from src/capi/abi.zig").dependOn(&abi_json_update.step);
        const abi_json_check = b.addRunArtifact(abi_json);
        abi_json_check.addArg("--check");
        abi_json_check.addFileArg(b.path("include/anole.abi.json"));

        // capi-test (also part of `test`): anole.h's layout against
        // src/capi/abi.zig (the header through translate-c), the symbol
        // check, and the C suite (tests/capi/consumer.c) on libanole.a.
        const capi_test_step = b.step("capi-test", "Test the C ABI: anole.h layout, exported symbols, the C suite");
        capi_test_step.dependOn(&abi_json_check.step);
        if (b.lazyImport(@This(), "translate_c")) |tc| if (b.lazyDependency("translate_c", .{})) |tc_dep| {
            const header: tc.Translator = .init(tc_dep, .{
                .name = "anole_h",
                .c_source_file = b.path("include/anole.h"),
                .target = target,
                .optimize = optimize,
            });
            // What the tests compare the header with: the schema, the guide
            // and the release's version, as text.
            const embed = b.addWriteFiles();
            _ = embed.addCopyFile(b.path("include/anole.schema.json"), "anole.schema.json");
            _ = embed.addCopyFile(b.path("docs/c-abi.md"), "c-abi.md");
            _ = embed.addCopyFile(b.path("include/anole.h"), "anole.h");
            const schema_mod = b.createModule(.{ .root_source_file = embed.add("schema.zig", "pub const text = @embedFile(\"anole.schema.json\");\n") });
            const guide_mod = b.createModule(.{ .root_source_file = embed.add("guide.zig", "pub const text = @embedFile(\"c-abi.md\");\n") });
            const header_text_mod = b.createModule(.{ .root_source_file = embed.add("header.zig", "pub const text = @embedFile(\"anole.h\");\n") });
            const version_mod = b.createModule(.{ .root_source_file = embed.add("version.zig", b.fmt("pub const text = \"{s}\";\n", .{@import("build.zig.zon").version})) });
            const abi_for_test = b.createModule(.{ .root_source_file = b.path("src/capi/abi.zig"), .target = target, .optimize = optimize });
            const abi_test = b.addTest(.{
                .name = "capi-abi-test",
                // The test inspects every declaration of the translated
                // header; the self-hosted x86_64 backend writes debug info
                // for the extern functions among them, which then need the
                // C symbols. LLVM drops the unused ones, as on aarch64.
                .use_llvm = true,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/capi/abi_test.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "capi_abi", .module = abi_for_test },
                        .{ .name = "capi_abi_json", .module = b.createModule(.{
                            .root_source_file = b.path("tools/capi_abi_json.zig"),
                            .target = target,
                            .optimize = optimize,
                            .imports = &.{.{ .name = "capi_abi", .module = abi_for_test }},
                        }) },
                        .{ .name = "anole_h", .module = header.mod },
                        .{ .name = "anole_schema", .module = schema_mod },
                        .{ .name = "anole_guide", .module = guide_mod },
                        .{ .name = "anole_header_text", .module = header_text_mod },
                        .{ .name = "anole_version", .module = version_mod },
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
            // The client of the suite's WebTransport test, in Zig (C has
            // no WebTransport client): its path is the second argument.
            const wt_client: ?*std.Build.Step.Compile = if (features.http3) b.addExecutable(.{
                .name = "capi-wt-client",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/capi/wt_client.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "anole", .module = anole_mod }},
                }),
            }) else null;
            if (wt_client) |wc| run_consumer.addArtifactArg(wc);
            // Its progress lines and Anole's warnings (a drain cut short on
            // purpose) on the terminal; a failure is its exit code.
            run_consumer.stdio = .inherit;
            run_consumer.has_side_effects = true;
            // The PostgreSQL part of the suite, against that server.
            if (postgres_test_url) |url| run_consumer.setEnvironmentVariable("ANOLE_TEST_POSTGRES_URL", url);
            if (redis_test_url) |url| run_consumer.setEnvironmentVariable("ANOLE_TEST_REDIS_URL", url);
            if (mongodb_test_url) |url| run_consumer.setEnvironmentVariable("ANOLE_TEST_MONGODB_URL", url);
            capi_test_step.dependOn(&run_consumer.step);
            b.step("capi-consumer", "Build the C consumer (tests/capi/consumer.c: `test`, or `serve` for benchmarks)").dependOn(&b.addInstallArtifact(consumer, .{}).step);

            // The gRPC suite (tests/capi/grpc.c): its own process, as one
            // anole_server is allowed per process.
            if (features.grpc) {
                const grpc_c = b.addExecutable(.{
                    .name = "capi-grpc",
                    .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
                });
                grpc_c.root_module.addCSourceFile(.{ .file = b.path("tests/capi/grpc.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-missing-field-initializers" } });
                grpc_c.root_module.addIncludePath(b.path("include"));
                grpc_c.root_module.linkLibrary(static_lib);
                const run_grpc_c = b.addRunArtifact(grpc_c);
                run_grpc_c.stdio = .inherit;
                run_grpc_c.has_side_effects = true;
                capi_test_step.dependOn(&run_grpc_c.step);
                const grpc_step = b.step("capi-grpc", "Build the C gRPC consumers (tests/capi/grpc.c; grpc_interop.c, grpc.testing.TestService for tests/grpc/interop/run.sh)");
                grpc_step.dependOn(&b.addInstallArtifact(grpc_c, .{}).step);
                const interop_c = b.addExecutable(.{
                    .name = "capi-grpc-interop",
                    .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
                });
                interop_c.root_module.addCSourceFile(.{ .file = b.path("tests/capi/grpc_interop.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-missing-field-initializers" } });
                interop_c.root_module.addIncludePath(b.path("include"));
                interop_c.root_module.linkLibrary(static_lib);
                grpc_step.dependOn(&b.addInstallArtifact(interop_c, .{}).step);
                // Compiled with capi-test, so it cannot rot; run by hand or in CI.
                capi_test_step.dependOn(&interop_c.step);
            }

            // The server-sent events suite (tests/capi/sse.c): its own
            // process, as one anole_server is allowed per process.
            if (target.result.os.tag != .windows) {
                const sse_c = b.addExecutable(.{
                    .name = "capi-sse",
                    .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
                });
                sse_c.root_module.addCSourceFile(.{ .file = b.path("tests/capi/sse.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-missing-field-initializers" } });
                sse_c.root_module.addIncludePath(b.path("include"));
                sse_c.root_module.linkLibrary(static_lib);
                const run_sse_c = b.addRunArtifact(sse_c);
                run_sse_c.stdio = .inherit;
                run_sse_c.has_side_effects = true;
                capi_test_step.dependOn(&run_sse_c.step);
                b.step("capi-sse", "Run the C server-sent events suite (tests/capi/sse.c)").dependOn(&run_sse_c.step);
            }

            // A TLS listener in a program linked with dead-stripping, as
            // bindings and release links are (tests/capi/tls_start.c): the
            // packed object must survive being cut at its symbols. Zig's
            // linker here; the system's in capi-test-asan.
            const tls_driver = if (features.tls == .boringssl) b.addExecutable(.{
                .name = "capi-tls-start-driver",
                .root_module = b.createModule(.{ .root_source_file = b.path("tests/capi/tls_start.zig"), .target = b.graph.host, .optimize = .Debug }),
            }) else null;
            if (tls_driver) |driver| {
                const tls_start = b.addExecutable(.{
                    .name = "capi-tls-start",
                    .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
                });
                tls_start.root_module.addCSourceFile(.{ .file = b.path("tests/capi/tls_start.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-missing-field-initializers" } });
                tls_start.root_module.addIncludePath(b.path("include"));
                tls_start.root_module.linkLibrary(static_lib);
                tls_start.link_gc_sections = true; // Mach-O -dead_strip, ELF --gc-sections
                const run_tls_start = b.addRunArtifact(driver);
                run_tls_start.addArtifactArg(tls_start);
                run_tls_start.has_side_effects = true;
                run_tls_start.stdio = .inherit;
                capi_test_step.dependOn(&run_tls_start.step);
            }

            // capi-test-asan: the C suite built by the system C compiler
            // with AddressSanitizer and UBSan (Zig ships no ASan runtime);
            // libanole itself keeps Zig's own safety checks.
            const asan_step = b.step("capi-test-asan", "Run the C ABI suite built with -fsanitize=address,undefined, and a TLS listener in a dead-stripped link (needs a system cc)");
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
            if (wt_client) |wc| run_asan.addArtifactArg(wc);
            run_asan.has_side_effects = true;
            run_asan.stdio = .inherit;
            // Zig's threads install a signal stack of their own (for the
            // stack-overflow handler); ASan's would unmap it at thread exit.
            run_asan.setEnvironmentVariable("ASAN_OPTIONS", "use_sigaltstack=0");
            if (postgres_test_url) |url| run_asan.setEnvironmentVariable("ANOLE_TEST_POSTGRES_URL", url);
            if (redis_test_url) |url| run_asan.setEnvironmentVariable("ANOLE_TEST_REDIS_URL", url);
            if (mongodb_test_url) |url| run_asan.setEnvironmentVariable("ANOLE_TEST_MONGODB_URL", url);
            asan_step.dependOn(&run_asan.step);
            if (tls_driver) |driver| {
                const ds = b.addSystemCommand(&.{ "cc", "-O2", "-std=c11" });
                ds.addPrefixedDirectoryArg("-I", b.path("include"));
                ds.addFileArg(b.path("tests/capi/tls_start.c"));
                ds.addFileArg(static_lib.getEmittedBin());
                if (os == .linux) ds.addArgs(&.{ "-Wl,--gc-sections", "-lpthread", "-ldl", "-lm" }) else ds.addArg("-Wl,-dead_strip");
                ds.addArg("-o");
                const ds_exe = ds.addOutputFileArg("capi-tls-start-cc");
                const run_ds = b.addRunArtifact(driver);
                run_ds.addFileArg(ds_exe);
                run_ds.has_side_effects = true;
                run_ds.stdio = .inherit;
                asan_step.dependOn(&run_ds.step);
            }
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

    // `anole`, the command line (tools/anole): `anole new <dir>` makes a
    // project from the templates in templates/. Std-only, so it depends on no
    // C library and no feature flag.
    //   cli        build and install it (zig-out/bin/anole)
    //   cli-test   its unit tests
    //   cli-dist   the release binaries for five targets and SHA256SUMS in zig-out/dist
    {
        const cli_options = b.addOptions();
        cli_options.addOption([]const u8, "version", @import("build.zig.zon").version);
        const templates_mod = b.createModule(.{ .root_source_file = b.path("templates/index.zig") });
        const CliBuild = struct {
            /// `strip`: no debug information (the release binaries; null keeps
            /// the optimize mode's default).
            fn module(bb: *std.Build, opts: *std.Build.Step.Options, tmpl: *std.Build.Module, tgt: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, strip: ?bool) *std.Build.Module {
                const banner = bb.createModule(.{ .root_source_file = bb.path("src/banner/root.zig"), .target = tgt, .optimize = opt, .strip = strip });
                return bb.createModule(.{
                    .root_source_file = bb.path("tools/anole/main.zig"),
                    .target = tgt,
                    .optimize = opt,
                    .strip = strip,
                    .imports = &.{
                        .{ .name = "cli_options", .module = opts.createModule() },
                        .{ .name = "templates", .module = tmpl },
                        // The startup banner (src/banner, std only).
                        .{ .name = "banner", .module = banner },
                        // The live console's client and terminal UI (src/console/ui, std only).
                        .{ .name = "anole_console_ui", .module = bb.createModule(.{ .root_source_file = bb.path("src/console/ui/root.zig"), .target = tgt, .optimize = opt, .strip = strip, .link_libc = true, .imports = &.{.{ .name = "anole_banner", .module = banner }} }) },
                    },
                });
            }
        };
        const cli = b.addExecutable(.{ .name = "anole", .root_module = CliBuild.module(b, cli_options, templates_mod, target, optimize, null) });
        const install_cli = b.addInstallArtifact(cli, .{});
        b.step("cli", "Build and install the anole command line (zig-out/bin/anole)").dependOn(&install_cli.step);

        const cli_tests = b.addTest(.{ .name = "anole-cli-test", .root_module = CliBuild.module(b, cli_options, templates_mod, target, optimize, null) });
        b.step("cli-test", "Run the anole command line's unit tests").dependOn(&b.addRunArtifact(cli_tests).step);

        const dist = b.step("cli-dist", "Cross-build the anole binaries for five targets and SHA256SUMS into zig-out/dist");
        const sums_exe = b.addExecutable(.{ .name = "anole-sums", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/anole/sums.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }) });
        const sums = b.addRunArtifact(sums_exe);
        const sums_out = sums.addOutputFileArg("SHA256SUMS");
        const dist_targets = [_]struct { query: std.Target.Query, name: []const u8 }{
            .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "anole-x86_64-linux" },
            .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "anole-aarch64-linux" },
            .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "anole-x86_64-macos" },
            .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "anole-aarch64-macos" },
            .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "anole-x86_64-windows.exe" },
        };
        for (dist_targets) |dt| {
            // Stripped: the release binaries carry no debug information
            // (ReleaseSafe keeps it otherwise; the Linux ones were ~7x larger).
            const exe = b.addExecutable(.{ .name = "anole", .root_module = CliBuild.module(b, cli_options, templates_mod, b.resolveTargetQuery(dt.query), .ReleaseSafe, true) });
            const installed = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = "dist" }, dt.name);
            dist.dependOn(&installed.step);
            // The sums are over the built files, named as they are installed.
            const named = b.addWriteFiles();
            const copy = named.addCopyFile(exe.getEmittedBin(), dt.name);
            sums.addFileArg(copy);
        }
        const install_sums = b.addInstallFileWithDir(sums_out, .{ .custom = "dist" }, "SHA256SUMS");
        dist.dependOn(&install_sums.step);
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
/// brotli, `-Djobs=false` webhooks); an explicit contradiction
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
    const nats = b.option(bool, "nats", "NATS client (overrides the profile)");
    const kafka = b.option(bool, "kafka", "Kafka client; needs -Dcompression=true (overrides the profile)");
    const openapi = b.option(bool, "openapi", "OpenAPI 3.1 document generation (overrides the profile)");
    const console_opt = b.option(bool, "console", "The live console: control socket, rings and terminal UI (overrides the profile)");
    const net = b.option(bool, "net", "Raw TCP and UDP servers (overrides the profile)");
    const jobs = b.option(bool, "jobs", "Durable jobs, cron and webhooks out (overrides the profile)");
    const webhooks = b.option(bool, "webhooks", "Webhooks out and the Verify middleware; needs -Djobs=true (overrides the profile)");
    const s3 = b.option(bool, "s3", "S3-compatible object storage client (overrides the profile)");
    const smtp = b.option(bool, "smtp", "SMTP client for sending mail (overrides the profile)");
    const lambda = b.option(bool, "lambda", "The AWS Lambda adapter (overrides the profile)");
    const default_deployment = b.option(DefaultDeployment, "default-deployment", "The deployment used when neither the options nor ANOLE_DEPLOYMENT name one (zig build lambda: lambda)") orelse .standalone;

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
    if (nats) |v| f.nats = v;
    if (kafka) |v| f.kafka = v;
    if (openapi) |v| f.openapi = v;
    if (console_opt) |v| f.console = v;
    if (net) |v| f.net = v;
    if (jobs) |v| f.jobs = v;
    if (webhooks) |v| f.webhooks = v;
    if (s3) |v| f.s3 = v;
    if (smtp) |v| f.smtp = v;
    if (lambda) |v| f.lambda = v;
    f.default_deployment = default_deployment;

    if (f.tls == .none and http3 == null) f.http3 = false;
    if (!f.http2 and grpc == null) f.grpc = false;
    if (!f.compression and brotli == null) f.brotli = false;
    if (!f.compression and kafka == null) f.kafka = false;
    if (!f.jobs and webhooks == null) f.webhooks = false;

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
    /// src/resilience/core.zig (retries, breakers): imported as
    /// `resilience_core` by every HTTP core instance and by anole.
    resilience: *std.Build.Module,
    /// src/validate (the validator, no imports): `validate` in the HTTP core
    /// (`req.bind`) and in anole.
    validate: *std.Build.Module,
    /// src/logging (the JSON Lines logger, no imports): `anole_log` in the
    /// HTTP core (`req.log()`) and in anole.
    anole_log: *std.Build.Module,
    /// src/console/ui (the live console's std-only protocol, client, terminal
    /// UI and restart logic): `anole_console_ui` in anole.
    console_ui: *std.Build.Module,
    /// src/banner (the startup banner and the anole art, std only):
    /// `anole_banner` in anole and in the console UI.
    banner: *std.Build.Module,

    fn init(b: *std.Build, c_mods: CModules, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Core {
        // Pinned by default (zio's own default is work stealing), so a
        // program that declares no `zio_options` still gets what Anole needs;
        // anole.Server refuses to compile with work stealing declared. And
        // `fast_accept` (see `anole.zio_options`), so a program whose own
        // `zio_options` leave it out still has it.
        const zio_mod = b.dependency("zio", .{ .target = target, .optimize = optimize, .scheduling = .pinned, .fast_accept = true, .diagnostics = true }).module("zio");
        const seam: ?*std.Build.Module = if (c_mods.boringssl) |bssl| b.createModule(.{
            .root_source_file = b.path("src/tls/dusty_tls.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "anole_boringssl_c", .module = bssl }},
        }) else null;
        const resilience = b.createModule(.{ .root_source_file = b.path("src/resilience/core.zig"), .target = target, .optimize = optimize });
        const validate = b.createModule(.{ .root_source_file = b.path("src/validate/root.zig"), .target = target, .optimize = optimize });
        const anole_log = b.createModule(.{ .root_source_file = b.path("src/logging/root.zig"), .target = target, .optimize = optimize });
        const banner = b.createModule(.{ .root_source_file = b.path("src/banner/root.zig"), .target = target, .optimize = optimize });
        const console_ui = b.createModule(.{ .root_source_file = b.path("src/console/ui/root.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "anole_banner", .module = banner }} });
        var core: Core = .{ .resilience = resilience, .validate = validate, .anole_log = anole_log, .console_ui = console_ui, .banner = banner, .zio = zio_mod, .llhttp = LlHttp.init(b, target, optimize), .dusty_by = @splat(@splat(@splat(@splat(null)))), .h2_client_by = @splat(@splat(@splat(@splat(null)))), .tls_seam = seam };
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
                        dusty_mod.addImport("resilience_core", resilience);
                        dusty_mod.addImport("validate", validate);
                        dusty_mod.addImport("anole_log", anole_log);
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
        opts.addOption([]const u8, "version", @import("build.zig.zon").version);
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
    /// lz4.h, lz4hc.h and lz4frame.h (kafka)
    lz4: ?*std.Build.Module = null,
    /// xuckless/websocket-zig, the sans-IO frame codec for WebSocket over
    /// HTTP/2 (websocket). Pure Zig, but fetched lazily like the C libraries.
    websocket: ?*std.Build.Module = null,
    /// Arwalk/zig-protobuf's runtime (grpc).
    protobuf: ?*std.Build.Module = null,
    /// yyjson.h (json)
    yyjson: ?*std.Build.Module = null,
    /// src/capi/upb_shim.h over upb (grpc): the C ABI's gRPC JSON.
    upb: ?*std.Build.Module = null,
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
        const lz4_dep = if (f.kafka) b.lazyDependency("lz4", .{}) else null;
        // Only its src/root.zig is used (its module would compile a second,
        // vendored zlib).
        const zlib_zig_dep = if (f.compression) b.lazyDependency("zlib_zig", .{}) else null;
        const websocket_dep = if (f.websocket) b.lazyDependency("websocket_zig", .{ .target = target, .optimize = optimize }) else null;
        const protobuf_dep = if (f.grpc) b.lazyDependency("protobuf", .{ .target = target, .optimize = optimize }) else null;
        const yyjson_dep = if (f.json) b.lazyDependency("yyjson", .{}) else null;
        const upb_dep = if (f.grpc) b.lazyDependency("upb", .{}) else null;
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
        if (f.kafka and lz4_dep == null) return null;
        if (f.websocket and websocket_dep == null) return null;
        if (f.grpc and protobuf_dep == null) return null;
        if (f.json and yyjson_dep == null) return null;
        if (f.grpc and upb_dep == null) return null;
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
        if (upb_dep) |up| {
            const lib = upb_build.library(b, up, target, optimize);
            m.upb = upb_build.module(b, Translator, tc_dep.?, lib, target, optimize);
        }
        if (zstd_dep) |up| {
            const lib = zstd_build.library(b, up, target, optimize);
            m.zstd = zstd_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }
        if (brotli_dep) |up| {
            const lib = brotli_build.library(b, up, target, optimize);
            m.brotli = brotli_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
        }
        if (lz4_dep) |up| {
            const lib = lz4_build.library(b, up, target, optimize);
            m.lz4 = lz4_build.module(b, Translator, tc_dep.?, up, lib, target, optimize);
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
    nats_test_url: ?[]const u8 = null,
    kafka_test_url: ?[]const u8 = null,
    s3_test_url: ?[]const u8 = null,
    smtp_test_url: ?[]const u8 = null,
    mailpit_api_url: ?[]const u8 = null,
    /// src/bson as a module, for -Dmongodb.
    bson: ?*std.Build.Module = null,
};

/// src/root.zig with its own build_options and only the binding modules its
/// features need.
fn anoleModule(b: *std.Build, o: AnoleModuleOptions) *std.Build.Module {
    const f = o.features;
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
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
    options.addOption(bool, "nats", f.nats);
    options.addOption(bool, "kafka", f.kafka);
    options.addOption(bool, "openapi", f.openapi);
    options.addOption(bool, "console", f.console);
    options.addOption(bool, "net", f.net);
    options.addOption(bool, "jobs", f.jobs);
    options.addOption(bool, "webhooks", f.webhooks);
    options.addOption(bool, "s3", f.s3);
    options.addOption(bool, "smtp", f.smtp);
    options.addOption(bool, "lambda", f.lambda);
    options.addOption(DefaultDeployment, "default_deployment", f.default_deployment);
    // Live servers for tests (`-Dredis-test-port=6379` or
    // `-Dredis-test-url=redis://...`,
    // `-Dpostgres-test-url=postgres://...`, `-Dmongodb-test-url=mongodb://...`),
    // else those tests skip.
    options.addOption(?u16, "redis_test_port", o.redis_test_port);
    options.addOption(?[]const u8, "redis_test_url", o.redis_test_url);
    options.addOption(?[]const u8, "postgres_test_url", o.postgres_test_url);
    options.addOption(?[]const u8, "mongodb_test_url", o.mongodb_test_url);
    options.addOption(?[]const u8, "nats_test_url", o.nats_test_url);
    options.addOption(?[]const u8, "kafka_test_url", o.kafka_test_url);
    options.addOption(?[]const u8, "s3_test_url", o.s3_test_url);
    options.addOption(?[]const u8, "smtp_test_url", o.smtp_test_url);
    options.addOption(?[]const u8, "mailpit_api_url", o.mailpit_api_url);

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
    mod.addImport("resilience_core", o.core.resilience);
    mod.addImport("validate", o.core.validate);
    mod.addImport("anole_log", o.core.anole_log);
    mod.addImport("anole_console_ui", o.core.console_ui);
    mod.addImport("anole_banner", o.core.banner);
    if (f.http2) {
        mod.addImport("anole_nghttp2_c", o.c.nghttp2.?);
        mod.addImport("anole_h2_client", o.core.h2Client(f));
    }
    if (f.websocket) mod.addImport("anole_websocket_codec", o.c.websocket.?);
    if (f.grpc) {
        mod.addImport("protobuf", o.c.protobuf.?);
        mod.addImport("anole_upb_c", o.c.upb.?);
    }
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
    // ---- p3/lambda ----
    // The sample events the adapter's tests parse (tests/lambda/events).
    if (f.lambda and o.for_test) {
        const wf = b.addWriteFiles();
        _ = wf.addCopyDirectory(b.path("tests/lambda/events"), "events", .{});
        mod.addAnonymousImport("anole_lambda_events", .{ .root_source_file = wf.add("events.zig", "pub fn get(comptime name: []const u8) []const u8 {\n    return @embedFile(\"events/\" ++ name ++ \".json\");\n}\n") });
    }
    // ---- end p3/lambda ----
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
    // The test services' descriptors (a FileDescriptorSet with imports,
    // made by the pinned protoc), for the C ABI's gRPC tests: what a
    // consumer passes as grpc.descriptor_set.
    if (f.grpc and o.for_test) if (b.lazyDependency("protobuf", .{ .target = b.graph.host })) |pb_dep| if (protocBinary(pb_dep.builder)) |protoc| {
        const run = b.addRunFile(protoc);
        run.setName("protoc test descriptors");
        run.addArg("--include_imports");
        const set = run.addPrefixedOutputFileArg("--descriptor_set_out=", "test.binpb");
        run.addArg("-I");
        run.addDirectoryArg(b.path("tests/grpc/proto"));
        run.addArg("-I");
        run.addDirectoryArg(b.path("src/grpc/proto"));
        run.addFileArg(b.path("tests/grpc/proto/echo.proto"));
        run.addFileArg(b.path("tests/grpc/proto/transcode.proto"));
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(set, "test.binpb");
        mod.addAnonymousImport("anole_test_descriptors", .{ .root_source_file = wf.add("descriptors.zig", "pub const set = @embedFile(\"test.binpb\");\n") });
    };
    if (f.compression) {
        mod.addImport("anole_zlib", o.c.zlib.?);
        mod.addImport("anole_zlib_c", o.c.zlib_c.?);
        mod.addImport("anole_zstd_c", o.c.zstd.?);
    }
    if (f.brotli) mod.addImport("anole_brotli_c", o.c.brotli.?);
    if (f.kafka) mod.addImport("anole_lz4_c", o.c.lz4.?);
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

/// Every static library and object a module links, through the modules it
/// imports and the libraries those link (for tools/capi_symbols.zig).
fn linkedInputs(b: *std.Build, root: *std.Build.Module) []const std.Build.LazyPath {
    var out: std.ArrayList(std.Build.LazyPath) = .empty;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, void) = .empty;
    var todo: std.ArrayList(*std.Build.Module) = .empty;
    todo.append(b.allocator, root) catch @panic("OOM");
    while (todo.pop()) |top| for (top.getGraph().modules) |m| for (m.link_objects.items) |lo| switch (lo) {
        .static_path => |p| out.append(b.allocator, p) catch @panic("OOM"),
        .other_step => |c| if (c.kind == .lib and c.linkage != .dynamic) {
            if ((seen.getOrPut(b.allocator, c) catch @panic("OOM")).found_existing) continue;
            out.append(b.allocator, c.getEmittedBin()) catch @panic("OOM");
            todo.append(b.allocator, c.root_module) catch @panic("OOM");
        },
        else => {},
    };
    return out.items;
}
