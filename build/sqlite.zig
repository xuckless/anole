//! SQLite 3.54.1 (the amalgamation, public domain), compiled by Anole with
//! the options below in one SQLITE_CUSTOM_INCLUDE header, and the `sqlite`
//! module of xuckless/zig-sqlite (branch `anole`, MIT) on top of it: the
//! fork translates the same sqlite3.h with the same header (its
//! `sqlite_include` and `sqlite_config` options), fetches no SQLite of its
//! own, and Anole links this library to its module.
const std = @import("std");

/// The header's name; sqlite3.c includes it as SQLITE_CUSTOM_INCLUDE, before
/// any of its own definitions.
pub const config_name = "anole_sqlite_config.h";

/// Compile-time options. From https://sqlite.org/compile.html section 2
/// ("about 3% less size and 5% fewer cycles"), plus SQLITE_THREADSAFE=2 (a
/// connection may move between threads but is never used by two at once)
/// and FTS5. Not OMIT_DECLTYPE or OMIT_PROGRESS_CALLBACK: zig-sqlite may read
/// declared types, and the progress callback is a cancellation fallback.
/// With OMIT_AUTOINIT, sqlite3_initialize() must run before anything else
/// (zig-sqlite's `Db.init` calls it). Per-connection settings (WAL,
/// synchronous=NORMAL, busy_timeout, foreign_keys) are pragmas, not here.
/// SQLITE_MAX_EXPR_DEPTH stays at SQLite's default of 1000 (compile.html
/// suggests 0, no limit): the parser recurses per level, on a thread or a
/// coroutine stack of limited size.
pub const config =
    \\#define SQLITE_DQS 0
    \\#define SQLITE_DEFAULT_MEMSTATUS 0
    \\#define SQLITE_DEFAULT_WAL_SYNCHRONOUS 1
    \\#define SQLITE_LIKE_DOESNT_MATCH_BLOBS 1
    \\#define SQLITE_MAX_EXPR_DEPTH 1000
    \\#define SQLITE_OMIT_DEPRECATED 1
    \\#define SQLITE_OMIT_SHARED_CACHE 1
    \\#define SQLITE_OMIT_AUTOINIT 1
    \\#define SQLITE_STRICT_SUBTYPE 1
    \\#define SQLITE_USE_ALLOCA 1
    \\#define SQLITE_THREADSAFE 2
    \\#define SQLITE_ENABLE_FTS5 1
    \\
;

/// The options header, as a file for `library` and zig-sqlite's `sqlite_config`.
pub fn configHeader(b: *std.Build) std.Build.LazyPath {
    return b.addWriteFiles().add(config_name, config);
}

/// sqlite3.c with `config_header` as its SQLITE_CUSTOM_INCLUDE.
pub fn library(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    config_header: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "sqlite",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.root_module.addIncludePath(config_header.dirname());
    lib.root_module.addIncludePath(upstream.path("."));
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &.{"sqlite3.c"},
        .flags = &.{ "-std=c99", "-DSQLITE_CUSTOM_INCLUDE=" ++ config_name },
    });
    return lib;
}

/// The zig-sqlite dependency's arguments: Anole's SQLite instead of its
/// bundled one.
pub fn zigSqliteArgs(
    upstream: *std.Build.Dependency,
    config_header: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ZigSqliteArgs {
    return .{ .target = target, .optimize = optimize, .sqlite_include = upstream.path("."), .sqlite_config = config_header };
}

pub const ZigSqliteArgs = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite_include: std.Build.LazyPath,
    sqlite_config: std.Build.LazyPath,
};

/// zig-sqlite's `sqlite` module (`@import("sqlite")`, with the C API as
/// `sqlite.c`), linking `lib`.
pub fn module(zig_sqlite: *std.Build.Dependency, lib: *std.Build.Step.Compile) *std.Build.Module {
    const mod = zig_sqlite.module("sqlite");
    mod.linkLibrary(lib);
    return mod;
}

/// A test that opens `:memory:` through `mod` and checks that the options
/// header reached the compiled library.
pub fn buildTest(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const tests = b.addTest(.{
        .name = "sqlite-build-test",
        .root_module = b.createModule(.{
            .root_source_file = b.addWriteFiles().add("sqlite_build_test.zig", test_source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqlite", .module = mod }},
        }),
    });
    const run = b.addRunArtifact(tests);
    run.skip_foreign_checks = true;
    return run;
}

const test_source =
    \\const std = @import("std");
    \\const sqlite = @import("sqlite");
    \\const c = sqlite.c;
    \\
    \\test "sqlite: :memory: through zig-sqlite on Anole's SQLite" {
    \\    var db = try sqlite.Db.init(.{
    \\        .mode = .Memory,
    \\        .open_flags = .{ .write = true, .create = true },
    \\        .threading_mode = .MultiThread,
    \\    });
    \\    defer db.deinit();
    \\
    \\    try std.testing.expectEqual(@as(c_int, 3054001), c.sqlite3_libversion_number());
    \\    try std.testing.expectEqual(c.SQLITE_VERSION_NUMBER, c.sqlite3_libversion_number());
    \\
    \\    try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL)", .{}, .{});
    \\    try db.exec("INSERT INTO t(name) VALUES(?)", .{}, .{"anole"});
    \\    const name = (try db.oneAlloc([]const u8, std.testing.allocator, "SELECT name FROM t WHERE id = ?", .{}, .{@as(i64, 1)})).?;
    \\    defer std.testing.allocator.free(name);
    \\    try std.testing.expectEqualStrings("anole", name);
    \\
    \\    // The options header reached sqlite3.c, not only the bindings.
    \\    for ([_][*:0]const u8{ "THREADSAFE=2", "OMIT_AUTOINIT", "OMIT_DEPRECATED", "OMIT_SHARED_CACHE", "DQS=0", "DEFAULT_MEMSTATUS=0", "ENABLE_FTS5" }) |opt| {
    \\        if (c.sqlite3_compileoption_used(opt) != 1) {
    \\            std.debug.print("compile option missing: {s}\n", .{opt});
    \\            return error.TestUnexpectedResult;
    \\        }
    \\    }
    \\    // DQS=0: a double-quoted string is an identifier only.
    \\    try std.testing.expectError(error.SQLiteError, db.oneDynamic(i64, "SELECT \"no such column\"", .{}, .{}));
    \\    // FTS5 is in.
    \\    try db.exec("CREATE VIRTUAL TABLE docs USING fts5(body)", .{}, .{});
    \\    try db.exec("INSERT INTO docs(body) VALUES(?)", .{}, .{"small lizards change colour"});
    \\    const hits = (try db.one(i64, "SELECT count(*) FROM docs WHERE docs MATCH ?", .{}, .{"lizards"})).?;
    \\    try std.testing.expectEqual(@as(i64, 1), hits);
    \\}
    \\
;
