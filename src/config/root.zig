// Adapted from vkiryakov/zefir src/confy/root.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! anole.config: typed settings for an app, from JSON, INI, `.env` files and
//! the environment, decoded into a struct you declare. Every problem is
//! reported at once, and values (secrets) never appear in messages.
//!
//! ```zig
//! const Config = struct {
//!     database_url: anole.Secret, // required: DATABASE_URL
//!     port: u16 = 3000,
//!     request_timeout: anole.Duration = .fromSeconds(30),
//! };
//! const cfg = try anole.config.load(Config, init, .{});
//! ```
//!
//! A field `db.port` is the key `"db": { "port": ... }` in JSON, `port` in the
//! `[db]` section of an INI file, and `DB_PORT` in `.env` files and the
//! environment. docs/config.md has the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;

const copy = @import("copy.zig");
const decode = @import("decode.zig");
const naming = @import("naming.zig");
const Tree = @import("tree.zig").Tree;
const dotenv = @import("parsers/dotenv.zig");
const env_mod = @import("../env.zig");
const modes = @import("../modes.zig");
const env = @import("parsers/env.zig");
const ini = @import("parsers/ini.zig");
const json = @import("parsers/json.zig");

pub const ConfigSource = @import("source.zig").ConfigSource;
pub const Diagnostics = @import("Diagnostics.zig");
pub const Secret = @import("Secret.zig");

pub const Error = error{
    OutOfMemory,
    /// At least one problem was found; they are all in `Options.diagnostics`.
    InvalidConfig,
};

pub const SourceOptions = struct {
    /// Used to read files.
    io: std.Io,
    /// The process environment (`init.environ_map` in `main`). Required by `.osEnv()`.
    environ: ?*const std.process.Environ.Map = null,
    /// Prepended to environment variable names: with `APP_`, field `db.port` is `APP_DB_PORT`.
    env_prefix: []const u8 = "",
    /// Applied in order; each source overrides the ones before it.
    sources: []const ConfigSource,
    /// Directory that relative file paths are resolved against; the working directory when null.
    dir: ?std.Io.Dir = null,
    /// Receives every problem when `load` fails.
    diagnostics: ?*Diagnostics = null,
    /// The entries of the `.env` files read (the `.dotenvFiles()` source).
    overlay: ?*const env_mod.Files = null,
    /// Whose per-environment defaults apply.
    environment: modes.Environment = .production,
};

/// Largest file `load` reads.
pub const max_file_bytes = 1024 * 1024;

/// Fills `config` (a mutable pointer to a struct) from `options.sources`.
///
/// Strings and lists in the result are allocated with `gpa`; release them with
/// `free`, or pass an arena such as `init.arena.allocator()`. On error,
/// `config` is left untouched and nothing is leaked.
pub fn loadSources(gpa: Allocator, config: anytype, options: SourceOptions) Error!void {
    const T = ConfigType(@TypeOf(config));
    const leaves = comptime naming.leaves(T);

    var own_diagnostics: Diagnostics = .init(gpa);
    defer own_diagnostics.deinit();
    const diag = options.diagnostics orelse &own_diagnostics;
    const problems_before = diag.problems.items.len;

    var tree = try Tree.init(gpa);
    defer tree.deinit();
    const arena = tree.allocator();

    var env_names: [leaves.len][]const u8 = undefined;
    for (leaves, &env_names) |leaf, *name| {
        name.* = try std.mem.concat(arena, u8, &.{ options.env_prefix, leaf.env_name });
    }

    var has_env_source = false;
    var has_file_source = false;
    for (options.sources) |source| switch (source) {
        .json_file => |path| {
            has_file_source = true;
            const text = try readFile(arena, options, path, .required, diag) orelse continue;
            if (try json.parse(arena, text, path, diag)) |object| try tree.merge(object);
        },
        .ini_file => |path| {
            has_file_source = true;
            const text = try readFile(arena, options, path, .required, diag) orelse continue;
            try tree.merge(try ini.parse(arena, text, path, diag));
        },
        .dotenv => |path| {
            has_env_source = true;
            const text = try readFile(arena, options, path, .optional, diag) orelse continue;
            const vars = try dotenv.parse(arena, text, path, diag);
            try env.placeDotEnv(&tree, leaves, &env_names, &vars, path);
        },
        .dotenv_files => {
            has_env_source = true;
            if (options.overlay) |files| try env.placeOverlay(&tree, leaves, &env_names, files);
        },
        .os_env => {
            has_env_source = true;
            const environ = options.environ orelse @panic("anole.config: the .osEnv() source needs SourceOptions.environ");
            try env.placeEnviron(&tree, leaves, &env_names, environ);
        },
    };

    const value = try decode.decode(T, .{
        .arena = arena,
        .diag = diag,
        .env_prefix = options.env_prefix,
        .has_env_source = has_env_source,
        .has_file_source = has_file_source,
        .environment = options.environment,
    }, tree.root());
    if (diag.problems.items.len != problems_before) return error.InvalidConfig;

    config.* = try copy.dupe(T, gpa, value);
}

/// Like `load`, but on failure logs every problem and exits with status 1.
pub fn loadSourcesOrExit(gpa: Allocator, config: anytype, options: SourceOptions) void {
    var own_diagnostics: Diagnostics = .init(gpa);
    defer own_diagnostics.deinit();
    var with_diagnostics = options;
    const diag = options.diagnostics orelse &own_diagnostics;
    with_diagnostics.diagnostics = diag;

    loadSources(gpa, config, with_diagnostics) catch |err| {
        switch (err) {
            error.InvalidConfig => log.err("{f}", .{diag}),
            error.OutOfMemory => log.err("out of memory while loading configuration", .{}),
        }
        std.process.exit(1);
    };
}

/// Frees the strings and lists that `load` allocated in `config` (the struct, not a pointer).
/// Secrets are overwritten with zeros first.
pub fn free(gpa: Allocator, config: anytype) void {
    copy.free(@TypeOf(config), gpa, config);
}

pub const Environment = modes.Environment;
pub const Duration = decode.Duration;

pub const Options = struct {
    /// Prepended to every variable name: with "APP_", field `db.port` is
    /// APP_DB_PORT. Default none: field `database_url` is DATABASE_URL.
    prefix: []const u8 = "",
    /// A JSON (".json") or INI (".ini") file read first, below `.env` and the
    /// environment. It must exist. Null: none.
    file: ?[]const u8 = null,
    /// Whose per-environment defaults (`pub const development`/`production`
    /// on the config struct) apply, and which `.env` files are read. Null:
    /// `anole.env.environment()`.
    environment: ?Environment = null,
    /// The `.env` files, as `ServerOptions.env_files`: null for the
    /// environment's (development: ".env.development.local", ".env.local",
    /// ".env.development", ".env"; production and tests: none).
    env_files: ?[]const []const u8 = null,
    /// What relative paths (`file`, `env_files`) resolve against. Null: the
    /// working directory.
    dir: ?std.Io.Dir = null,
    /// Receives every problem instead of the log (tests).
    diagnostics: ?*Diagnostics = null,
    /// Tests only: these `.env` entries instead of the process-wide ones.
    dotenv: ?*const env_mod.Files = null,
};

pub const LoadError = error{ InvalidConfig, OutOfMemory };

/// Reads `T` from (lowest first) its field defaults, its per-environment
/// defaults, `options.file`, the `.env` files and the process environment.
/// Strings live in `init.arena` (the process's lifetime: nothing to free).
/// On a problem, logs every problem at once (scope `anole`, level err) and
/// returns `error.InvalidConfig`, so `try` in `main` exits with status 1.
///
///     const cfg = try anole.config.load(Config, init, .{});
pub fn load(comptime T: type, init: std.process.Init, options: Options) LoadError!T {
    return loadFrom(T, init.arena.allocator(), init.io, init.environ_map, options);
}

/// `load` with its parts given: `arena` owns the result, `environ` is the
/// process environment (tests pass their own map).
pub fn loadFrom(comptime T: type, arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: Options) LoadError!T {
    const environment = options.environment orelse env_mod.environment();
    var own_diagnostics: Diagnostics = .init(arena);
    defer own_diagnostics.deinit();
    const diag = options.diagnostics orelse &own_diagnostics;
    const before = diag.problems.items.len;

    const overlay: ?*const env_mod.Files = options.dotenv orelse blk: {
        const paths = options.env_files orelse env_mod.defaultFiles(environment);
        if (paths.len == 0) break :blk null;
        break :blk env_mod.loadOnce(io, paths, options.dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEnvFile => return error.InvalidConfig, // loadOnce logged every problem
        };
    };

    var sources: [3]ConfigSource = undefined;
    var n: usize = 0;
    if (options.file) |path| {
        if (std.mem.endsWith(u8, path, ".json")) {
            sources[n] = .json(path);
            n += 1;
        } else if (std.mem.endsWith(u8, path, ".ini")) {
            sources[n] = .ini(path);
            n += 1;
        } else {
            try diag.addFmt(.unreadable, "", null, "config file {s}: only .json and .ini are read", .{path});
        }
    }
    sources[n] = .dotenvFiles();
    n += 1;
    sources[n] = .osEnv();
    n += 1;

    var value: T = undefined;
    loadSources(arena, &value, .{
        .io = io,
        .environ = environ,
        .env_prefix = options.prefix,
        .sources = sources[0..n],
        .dir = options.dir,
        .diagnostics = diag,
        .overlay = overlay,
        .environment = environment,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => {
            if (options.diagnostics == null) log.err("{f}", .{diag});
            return error.InvalidConfig;
        },
    };
    if (diag.problems.items.len != before) {
        if (options.diagnostics == null) log.err("{f}", .{diag});
        return error.InvalidConfig;
    }
    return value;
}

const log = std.log.scoped(.anole);

/// The struct type `config` points to; a compile error unless it is a mutable pointer to a struct.
fn ConfigType(comptime CfgPtr: type) type {
    const info = @typeInfo(CfgPtr);
    if (info != .pointer or
        info.pointer.size != .one or
        info.pointer.attrs.@"const" or
        @typeInfo(info.pointer.child) != .@"struct")
    {
        @compileError("anole.config.load: expected a mutable pointer to a struct, like &config, got " ++ @typeName(CfgPtr));
    }

    return info.pointer.child;
}

const Presence = enum { required, optional };

/// The file's contents, or null when it can't be read (reported unless an optional file is missing).
fn readFile(arena: Allocator, options: SourceOptions, path: []const u8, presence: Presence, diag: *Diagnostics) Allocator.Error!?[]const u8 {
    const dir = options.dir orelse std.Io.Dir.cwd();
    // readFileAlloc fails as soon as it has read `limit` bytes, so allow one more.
    return dir.readFileAlloc(options.io, path, arena, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            if (presence == .required) try diag.add(.{ .kind = .unreadable, .origin = .{ .file = path }, .detail = "file not found" });
            return null;
        },
        error.StreamTooLong => {
            try diag.addFmt(.unreadable, "", .{ .file = path }, "larger than {d} bytes", .{max_file_bytes});
            return null;
        },
        else => |e| {
            try diag.addFmt(.unreadable, "", .{ .file = path }, "{s}", .{@errorName(e)});
            return null;
        },
    };
}

test {
    _ = @import("tree.zig");
    _ = @import("Diagnostics.zig");
    _ = @import("Secret.zig");
    _ = @import("naming.zig");
    _ = @import("decode.zig");
    _ = @import("copy.zig");
    _ = @import("parsers/dotenv.zig");
    _ = @import("parsers/ini.zig");
    _ = @import("parsers/json.zig");
    _ = @import("parsers/env.zig");
}

const testing = std.testing;

const TestConfig = struct {
    name: []const u8,
    db: struct {
        host: []const u8,
        port: u16 = 5432,
        password: ?Secret,
        pool: struct { size: u8 = 4 },
    },
    hosts: []const []const u8 = &.{"localhost"},
    log_level: enum { debug, info, warn, err } = .info,
    debug: bool = false,
};

test "sources apply in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{
        \\  "name": "anole",
        \\  "db": { "host": "db.internal", "port": 5432, "pool": { "size": 8 } },
        \\  "hosts": ["a", "b"]
        \\}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data =
        \\[db]
        \\port = 6000
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data =
        \\APP_DB_PORT=6543
        \\APP_DB_PASSWORD="s3cret"
        \\UNRELATED=ignored
    });

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_LOG_LEVEL", "debug");
    try environ.put("APP_HOSTS", "x, y, z");

    var config: TestConfig = undefined;
    try loadSources(testing.allocator, &config, .{
        .io = testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{
            .json("config.json"),
            .ini("config.ini"),
            .env(".env"),
            .env(".env.local"), // missing: skipped
            .osEnv(),
        },
    });
    defer free(testing.allocator, config);

    try testing.expectEqualStrings("anole", config.name);
    try testing.expectEqualStrings("db.internal", config.db.host);
    try testing.expectEqual(6543, config.db.port);
    try testing.expectEqualStrings("s3cret", config.db.password.?.expose());
    try testing.expectEqual(8, config.db.pool.size);
    try testing.expectEqual(3, config.hosts.len);
    try testing.expectEqualStrings("z", config.hosts[2]);
    try testing.expectEqual(.debug, config.log_level);
    try testing.expectEqual(false, config.debug);
}

test "defaults and nulls when nothing sets a field" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("NAME", "anole");
    try environ.put("DB_HOST", "localhost");

    var config: TestConfig = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} });
    defer free(testing.allocator, config);

    try testing.expectEqual(5432, config.db.port);
    try testing.expectEqual(null, config.db.password);
    try testing.expectEqual(4, config.db.pool.size);
    try testing.expectEqualStrings("localhost", config.hosts[0]);
}

test "every problem is reported and config is left untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{
        \\  "nmae": "anole",
        \\  "db": { "port": 70000 },
        \\  "log_level": "verbose"
        \\}
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data =
        \\APP_DEBUG=maybe
        \\APP_DEBUG=yes
    });

    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var config: TestConfig = undefined;
    config.name = "untouched";
    try testing.expectError(error.InvalidConfig, loadSources(testing.allocator, &config, .{
        .io = testing.io,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .diagnostics = &diag,
        .sources = &.{ .json("config.json"), .json("missing.json"), .env(".env") },
    }));
    try testing.expectEqualStrings("untouched", config.name);

    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\8 configuration problems:
        \\  missing.json: cannot read file (file not found)
        \\  .env:2: APP_DEBUG: duplicate key (first set on line 1)
        \\  name: missing (set APP_NAME, or "name" in a config file)
        \\  db.host: missing (set APP_DB_HOST, or "db.host" in a config file)
        \\  config.json:3: db.port: invalid (expected an integer 0..65535)
        \\  config.json:4: log_level: invalid (expected one of: debug, info, warn, err)
        \\  .env:1: APP_DEBUG: invalid (expected true or false)
        \\  config.json:2: nmae: unknown key (did you mean "name"?)
    , text);
}

test "validate() is called once the fields are valid" {
    const Config = struct {
        port: u16,

        pub fn validate(config: @This()) !void {
            if (config.port < 1024) return error.PortBelow1024;
        }
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PORT", "80");

    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var config: Config = undefined;
    try testing.expectError(error.InvalidConfig, loadSources(testing.allocator, &config, .{
        .io = testing.io,
        .environ = &environ,
        .diagnostics = &diag,
        .sources = &.{.osEnv()},
    }));

    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\1 configuration problem:
        \\  invalid (validate() returned error.PortBelow1024)
    , text);
}

test "values from JSON keep their types" {
    const Config = struct {
        ratio: f32,
        retries: i8,
        enabled: bool,
        ports: []const u16,
        servers: []const struct { host: []const u8, weight: u8 = 1 },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{
        \\  "ratio": 0.25,
        \\  "retries": -3,
        \\  "enabled": true,
        \\  "ports": [80, 443],
        \\  "servers": [{ "host": "a", "weight": 5 }, { "host": "b" }]
        \\}
    });

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    defer free(testing.allocator, config);

    try testing.expectEqual(0.25, config.ratio);
    try testing.expectEqual(-3, config.retries);
    try testing.expect(config.enabled);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, config.ports);
    try testing.expectEqualStrings("b", config.servers[1].host);
    try testing.expectEqual(5, config.servers[0].weight);
    try testing.expectEqual(1, config.servers[1].weight);
}

test "secrets load from any source and never print" {
    const Config = struct { api_token: Secret, db_password: ?Secret };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "API_TOKEN=tok-123\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{ \"db_password\": \"pa55\" }" });

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{ .json("config.json"), .env(".env") } });
    defer free(testing.allocator, config);

    try testing.expectEqualStrings("tok-123", config.api_token.expose());
    try testing.expectEqualStrings("pa55", config.db_password.?.expose());

    const printed = try std.fmt.allocPrint(testing.allocator, "{any} {f}", .{ config, config.api_token });
    defer testing.allocator.free(printed);
    try testing.expect(std.mem.find(u8, printed, "tok-123") == null);
    try testing.expect(std.mem.find(u8, printed, "pa55") == null);
    try testing.expect(std.mem.endsWith(u8, printed, "[REDACTED]"));
}

test "a secret must be a string" {
    const Config = struct { api_token: Secret };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{ \"api_token\": 12345 }" });

    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var config: Config = undefined;
    try testing.expectError(error.InvalidConfig, loadSources(testing.allocator, &config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .diagnostics = &diag,
        .sources = &.{.json("config.json")},
    }));

    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\1 configuration problem:
        \\  config.json:1: api_token: invalid (expected a string)
    , text);
}

fn loadEverything(gpa: Allocator, dir: std.Io.Dir, environ: *const std.process.Environ.Map) !void {
    var config: TestConfig = undefined;
    try loadSources(gpa, &config, .{
        .io = testing.io,
        .environ = environ,
        .env_prefix = "APP_",
        .dir = dir,
        .sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
    });
    free(gpa, config);
}

test "load frees everything when memory runs out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{ "name": "anole", "db": { "host": "db.internal" }, "hosts": ["a", "b"] }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "APP_DB_PASSWORD=\"s3\\ncret\"\n" });

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_LOG_LEVEL", "warn");

    try testing.checkAllAllocationFailures(@import("../testing/no_resize.zig").allocator, loadEverything, .{ tmp.dir, &environ });
}

/// Loads a `T` and expects exactly the `expected` problems.
fn expectProblems(comptime T: type, options: SourceOptions, expected: []const u8) !void {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &diag;

    var config: T = undefined;
    try testing.expectError(error.InvalidConfig, loadSources(testing.allocator, &config, with_diagnostics));

    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "loadSourcesOrExit fills config when it is valid" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("NAME", "anole");
    try environ.put("DB_HOST", "localhost");

    var config: TestConfig = undefined;
    loadSourcesOrExit(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} });
    defer free(testing.allocator, config);

    try testing.expectEqualStrings("anole", config.name);
}

test "a later source overrides an earlier one of any kind" {
    const Config = struct { a: u8, b: u8, c: u8 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "A=2\nB=2\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{ \"b\": 3 }" });

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("A", "1");
    try environ.put("C", "1");

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{
        .io = testing.io,
        .environ = &environ,
        .dir = tmp.dir,
        .sources = &.{ .osEnv(), .env(".env"), .json("config.json") },
    });

    try testing.expectEqual(2, config.a);
    try testing.expectEqual(3, config.b);
    try testing.expectEqual(1, config.c);
}

test "one Diagnostics can serve several loads" {
    const Config = struct { port: u16 };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const options: SourceOptions = .{ .io = testing.io, .environ = &environ, .diagnostics = &diag, .sources = &.{.osEnv()} };

    var config: Config = undefined;
    try testing.expectError(error.InvalidConfig, loadSources(testing.allocator, &config, options));
    try environ.put("PORT", "8080");
    try loadSources(testing.allocator, &config, options);

    try testing.expectEqual(8080, config.port);
    try testing.expectEqual(1, diag.problems.items.len);
}

test "a file larger than max_file_bytes is a problem" {
    const Config = struct { port: u16 = 5432 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(data);
    @memset(data, '\n');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data = data });

    try expectProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} },
        \\1 configuration problem:
        \\  config.ini: cannot read file (larger than 1048576 bytes)
    );
}

test "a file of exactly max_file_bytes is read" {
    const Config = struct { port: u16 = 5432 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try testing.allocator.alloc(u8, max_file_bytes);
    defer testing.allocator.free(data);
    @memset(data, '\n');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data = data });

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
}

test "lists in strings are comma-separated" {
    const Config = struct {
        ports: []const u16,
        hosts: []const []const u8 = &.{"localhost"},
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("PORTS", " 80, 443 ");
    try environ.put("HOSTS", "");

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} });
    defer free(testing.allocator, config);

    try testing.expectEqualSlices(u16, &.{ 80, 443 }, config.ports);
    try testing.expectEqual(0, config.hosts.len);
}

test "JSON null leaves a field unset" {
    const Config = struct {
        port: u16 = 5432,
        password: ?Secret,
        pool: struct { size: u8 = 4 },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{ "port": null, "password": null, "pool": null }
    });

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    defer free(testing.allocator, config);

    try testing.expectEqual(5432, config.port);
    try testing.expectEqual(null, config.password);
    try testing.expectEqual(4, config.pool.size);
}

test "an optional section is null until a source sets a key in it" {
    const Config = struct { tls: ?struct { cert: []const u8, key: []const u8 } };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const options: SourceOptions = .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} };

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, options);
    try testing.expectEqual(null, config.tls);

    try environ.put("TLS_CERT", "cert.pem");
    try expectProblems(Config, options,
        \\1 configuration problem:
        \\  tls.key: missing (set TLS_KEY)
    );
}

test "validate() of a nested struct runs only when its fields are valid" {
    const Config = struct {
        db: struct {
            port: u16,

            pub fn validate(db: @This()) !void {
                if (db.port < 1024) return error.PortBelow1024;
            }
        },
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const options: SourceOptions = .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} };

    try environ.put("DB_PORT", "80");
    try expectProblems(Config, options,
        \\1 configuration problem:
        \\  db: invalid (validate() returned error.PortBelow1024)
    );

    try environ.put("DB_PORT", "eighty");
    try expectProblems(Config, options,
        \\1 configuration problem:
        \\  environment: DB_PORT: invalid (expected an integer 0..65535)
    );
}

test "a missing field's hint names the sources that could set it" {
    const Config = struct {
        name: []const u8,
        servers: []const struct { host: []const u8 } = &.{},
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{ \"servers\": [{}] }" });

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try expectProblems(Config, .{ .io = testing.io, .sources = &.{} },
        \\1 configuration problem:
        \\  name: missing (no source sets it)
    );
    try expectProblems(Config, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} },
        \\1 configuration problem:
        \\  name: missing (set APP_NAME)
    );
    try expectProblems(Config, .{
        .io = testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .osEnv() },
    },
        \\2 configuration problems:
        \\  name: missing (set APP_NAME, or "name" in a config file)
        \\  servers[0].host: missing (set "servers[0].host" in a config file)
    );
}

test "values of the wrong JSON type are invalid" {
    const Config = struct {
        port: u16,
        debug: bool,
        db: struct { host: []const u8 = "localhost" },
        hosts: []const []const u8,
        name: []const u8,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data =
        \\{
        \\  "port": 80.5,
        \\  "debug": 1,
        \\  "db": "localhost",
        \\  "hosts": 5,
        \\  "name": ["anole"]
        \\}
    });

    try expectProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} },
        \\5 configuration problems:
        \\  config.json:2: port: invalid (expected an integer 0..65535)
        \\  config.json:3: debug: invalid (expected true or false)
        \\  config.json:4: db: invalid (expected a section with fields)
        \\  config.json:5: hosts: invalid (expected a list)
        \\  config.json:6: name: invalid (expected a string)
    );
}

const IniTypes = struct {
    ratio: f64,
    retries: i8,
    enabled: bool,
    level: enum { low, high },
    ports: []const u16,
};

test "strings from INI are parsed into the field type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data =
        \\ratio = 0.25
        \\retries = -3
        \\enabled = yes
        \\level = high
        \\ports = 80, 443
    });

    var config: IniTypes = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
    defer free(testing.allocator, config);

    try testing.expectEqual(0.25, config.ratio);
    try testing.expectEqual(-3, config.retries);
    try testing.expect(config.enabled);
    try testing.expectEqual(.high, config.level);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, config.ports);
}

test "strings that don't parse as the field type are invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data =
        \\ratio = fast
        \\retries = 128
        \\enabled = maybe
        \\level = medium
        \\ports = 80, http
    });

    try expectProblems(IniTypes, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} },
        \\5 configuration problems:
        \\  config.ini:1: ratio: invalid (expected a number)
        \\  config.ini:2: retries: invalid (expected an integer -128..127)
        \\  config.ini:3: enabled: invalid (expected true or false)
        \\  config.ini:4: level: invalid (expected one of: low, high)
        \\  config.ini:5: ports[1]: invalid (expected an integer 0..65535)
    );
}

test "unknown keys in a section are reported with their path" {
    const Config = struct { db: struct { port: u16 = 5432 } };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.ini", .data =
        \\[db]
        \\prot = 1
        \\zzz = 2
    });

    try expectProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} },
        \\2 configuration problems:
        \\  config.ini:2: db.prot: unknown key (did you mean "port"?)
        \\  config.ini:3: db.zzz: unknown key
    );
}

test "an unknown key's hint ignores case, and none is given past 64 characters or when the key is mostly wrong" {
    const long: []const u8 = comptime &@as([64]u8, @splat('a'));
    const Config = struct { port: u16 = 1, xy: u8 = 0, aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: u8 = 0 };
    comptime std.debug.assert(@hasField(Config, long));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\n" ++
        "  \"PORT\": 1,\n" ++
        "  \"" ++ long ++ "a\": 2,\n" ++
        "  \"ab\": 3\n" ++
        "}" });

    try expectProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} }, "3 configuration problems:\n" ++
        "  config.json:2: PORT: unknown key (did you mean \"port\"?)\n" ++
        "  config.json:3: " ++ long ++ "a: unknown key\n" ++
        "  config.json:4: ab: unknown key");
}

test "a struct field's default fills the keys no source sets" {
    const Db = struct { host: []const u8 = "localhost", port: u16 = 5432, user: []const u8 };
    const Config = struct { db: Db = .{ .host = "db.internal", .user = "app" } };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("DB_PORT", "6000");

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .sources = &.{.osEnv()} });
    defer free(testing.allocator, config);

    try testing.expectEqualStrings("db.internal", config.db.host);
    try testing.expectEqual(6000, config.db.port);
    try testing.expectEqualStrings("app", config.db.user);
}

test "integers outside i64 load from JSON" {
    const Config = struct { max: u64 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{ \"max\": 18446744073709551615 }" });

    var config: Config = undefined;
    try loadSources(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });

    try testing.expectEqual(std.math.maxInt(u64), config.max);
}
