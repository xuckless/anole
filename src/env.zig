//! The process environment as Anole reads it: the real environment first,
//! then the entries of the `.env` files read at startup.

const std = @import("std");
const builtin = @import("builtin");
const modes = @import("modes.zig");
const url = @import("db/url.zig");
const Diagnostics = @import("config/Diagnostics.zig");
const dotenv = @import("config/parsers/dotenv.zig");

const log = std.log.scoped(.anole);
const errors = @import("errors.zig");

pub const Environment = modes.Environment;

/// Largest `.env` file read.
pub const max_file_bytes = 1024 * 1024;

/// `name` from the process environment, else from the `.env` files read
/// (`loadOnce`). The value lives for the process.
pub fn get(name: []const u8) ?[]const u8 {
    return url.env(null, name);
}

/// `ANOLE_ENV` from the process environment (never from `.env`), else
/// development in a Debug build and production in a release build;
/// production in tests. Not cached. An `ANOLE_ENV` that names neither is
/// production here; the server refuses it (`InvalidEnvironmentVariable`).
pub fn environment() Environment {
    if (url.realEnv(null, "ANOLE_ENV")) |v| {
        if (std.meta.stringToEnum(Environment, v)) |e| return e;
        return .production;
    }
    if (builtin.is_test) return .production;
    return if (builtin.mode == .debug) .development else .production;
}

const development_files = [_][]const u8{ ".env.development.local", ".env.local", ".env.development", ".env" };

/// The `.env` files read for `e`: development, the four of the working
/// directory (the first wins per key); production, none. None in tests.
pub fn defaultFiles(e: Environment) []const []const u8 {
    if (builtin.is_test) return &.{};
    return defaultFilesFor(e);
}

/// `defaultFiles` without the empty list tests get: what the C ABI's
/// `anole_dotenv_read` reads for `e`.
pub fn defaultFilesFor(e: Environment) []const []const u8 {
    return switch (e) {
        .development => &development_files,
        .production => &.{},
    };
}

pub const Files = struct {
    pub const Entry = struct { value: []const u8, file: []const u8, line: u32 };
    pub const Read = struct { path: []const u8, count: u32 };
    /// Every key once: the entry of the first file (in the list's order)
    /// that has it. ANOLE_ENV is never an entry.
    entries: std.array_hash_map.String(Entry) = .empty,
    /// The files found, in list order, with how many entries each gave.
    read: []const Read = &.{},
    /// The file that set ANOLE_ENV (dropped), if one did.
    saw_anole_env: ?[]const u8 = null,

    /// Reads `paths` (relative to `dir`, default the working directory).
    /// Missing files are skipped. Any problem in any file is added to `diag`
    /// and fails the whole read. Everything is allocated in `arena`.
    pub fn load(arena: std.mem.Allocator, io: std.Io, dir: ?std.Io.Dir, paths: []const []const u8, diag: *Diagnostics) error{ OutOfMemory, InvalidEnvFile }!Files {
        var files: Files = .{};
        var read: std.ArrayList(Read) = .empty;
        const before = diag.problems.items.len;
        const d = dir orelse std.Io.Dir.cwd();
        for (paths) |path| {
            const text = d.readFileAlloc(io, path, arena, .limited(max_file_bytes + 1)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => continue,
                error.StreamTooLong => {
                    try diag.addFmt(.unreadable, "", .{ .file = path }, "larger than {d} bytes", .{max_file_bytes});
                    continue;
                },
                else => |e| {
                    try diag.addFmt(.unreadable, "", .{ .file = path }, "{s}", .{@errorName(e)});
                    continue;
                },
            };
            const vars = try dotenv.parse(arena, text, path, diag);
            try read.append(arena, .{ .path = path, .count = @intCast(vars.count()) });
            for (vars.keys(), vars.values()) |key, v| {
                if (std.mem.eql(u8, key, "ANOLE_ENV")) {
                    if (files.saw_anole_env == null) files.saw_anole_env = path;
                    continue;
                }
                const gop = try files.entries.getOrPut(arena, key);
                if (!gop.found_existing) gop.value_ptr.* = .{ .value = v.value, .file = path, .line = v.line };
            }
        }
        if (diag.problems.items.len != before) return error.InvalidEnvFile;
        files.read = read.items;
        return files;
    }

    pub fn get(self: *const Files, name: []const u8) ?[]const u8 {
        const e = self.entries.get(name) orelse return null;
        return e.value;
    }
};

// Process-wide overlay: 0 empty, 1 loading, 2 loaded.
var state: std.atomic.Value(u8) = .init(0);
var overlay: Files = .{};
var overlay_paths: []const []const u8 = &.{};
var overlay_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var warned_other_list: std.atomic.Value(bool) = .init(false);
var test_override: ?*const Files = null;

/// Reads `paths` into the process-wide overlay, once per process: the first
/// call's list is the one read, later calls get the same `Files` (a later
/// call naming another list logs one warning and gets the first). Problems
/// go to the log (all of them, err) and give `error.InvalidEnvFile`; a
/// later call tries again.
pub fn loadOnce(io: std.Io, paths: []const []const u8, dir: ?std.Io.Dir) error{ OutOfMemory, InvalidEnvFile }!*const Files {
    while (true) {
        switch (state.load(.acquire)) {
            2 => {
                if (!samePaths(overlay_paths, paths) and !warned_other_list.swap(true, .monotonic)) {
                    log.warn("the .env files were read already from another list; the first list is used", .{});
                }
                return &overlay;
            },
            1 => std.atomic.spinLoopHint(),
            else => {
                if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) continue;
                const result = loadInto(io, paths, dir);
                if (result) |_| state.store(2, .release) else |_| state.store(0, .release);
                try result;
                return &overlay;
            },
        }
    }
}

fn loadInto(io: std.Io, paths: []const []const u8, dir: ?std.Io.Dir) error{ OutOfMemory, InvalidEnvFile }!void {
    _ = overlay_arena.reset(.free_all);
    const a = overlay_arena.allocator();
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var diag: Diagnostics = .init(scratch.allocator());
    defer diag.deinit();
    const files = Files.load(a, io, dir, paths, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidEnvFile => {
            // The caller gets the error too: a test can expect this one.
            errors.log.err("{f}", .{&diag});
            return error.InvalidEnvFile;
        },
    };
    const copy = try a.alloc([]const u8, paths.len);
    for (paths, copy) |p, *c| c.* = try a.dupe(u8, p);
    overlay_paths = copy;
    overlay = files;
}

fn samePaths(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// The overlay, once read; null before.
pub fn loaded() ?*const Files {
    if (builtin.is_test) if (test_override) |f| return f;
    if (state.load(.acquire) == 2) return &overlay;
    return null;
}

/// Tests only: these entries are the overlay until `_resetForTest`.
pub fn _setLoadedForTest(files: *const Files) void {
    test_override = files;
}

/// Tests only: forgets the overlay, so `loadOnce` reads again.
pub fn _resetForTest() void {
    test_override = null;
    warned_other_list.store(false, .monotonic);
    state.store(0, .release);
    overlay = .{};
    overlay_paths = &.{};
}

const testing = std.testing;

fn writeTmp(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
}

test "env: first file in the list wins per key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "a", "K1=a1\nK2=a2\n");
    try writeTmp(tmp.dir, "b", "K2=b2\nK3=b3\n");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const files = try Files.load(arena.allocator(), testing.io, tmp.dir, &.{ "a", "missing", "b" }, &diag);
    try testing.expectEqual(3, files.entries.count());
    try testing.expectEqualStrings("a2", files.get("K2").?);
    try testing.expectEqualStrings("b3", files.get("K3").?);
    try testing.expectEqualStrings("b", files.entries.get("K3").?.file);
    try testing.expectEqual(2, files.read.len);
    try testing.expectEqual(2, files.read[0].count);
}

test "env: missing files are skipped; a problem in any file fails the whole read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "good", "A=1\n");
    try writeTmp(tmp.dir, "bad", "BAD LINE\n");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidEnvFile, Files.load(arena.allocator(), testing.io, tmp.dir, &.{ "good", "bad" }, &diag));
    try testing.expectEqual(1, diag.problems.items.len);
}

test "env: ANOLE_ENV in a file is dropped and noted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, ".env.local", "ANOLE_ENV=production\nA=1\n");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const files = try Files.load(arena.allocator(), testing.io, tmp.dir, &.{".env.local"}, &diag);
    try testing.expectEqualStrings(".env.local", files.saw_anole_env.?);
    try testing.expect(files.get("ANOLE_ENV") == null);
    try testing.expectEqual(1, files.entries.count());
}

test "env: defaultFiles" {
    // Empty in tests, whatever the environment.
    try testing.expectEqual(0, defaultFiles(.development).len);
    try testing.expectEqual(0, defaultFiles(.production).len);
    try testing.expectEqual(4, development_files.len);
}

test "env: get prefers the process environment" {
    var files: Files = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try files.entries.put(arena.allocator(), "ANOLE_SURELY_UNSET_VARIABLE", .{ .value = "from-file", .file = ".env", .line = 1 });
    try files.entries.put(arena.allocator(), "PATH", .{ .value = "from-file", .file = ".env", .line = 2 });
    _setLoadedForTest(&files);
    defer _resetForTest();
    try testing.expectEqualStrings("from-file", get("ANOLE_SURELY_UNSET_VARIABLE").?);
    try testing.expect(!std.mem.eql(u8, get("PATH").?, "from-file"));
}

test "fuzz: the .env parser" {
    const fuzz = @import("fuzz.zig");
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var diag: Diagnostics = .init(testing.allocator);
            defer diag.deinit();
            const vars = try dotenv.parse(arena.allocator(), input, ".env", &diag);
            // Bounded: no more entries than lines, and every line number inside the input.
            const lines = std.mem.countScalar(u8, input, '\n') + 1;
            try testing.expect(vars.count() <= lines);
            for (vars.values()) |v| try testing.expect(v.line >= 1 and v.line <= lines);
        }
    }.check, &.{ "A=1\nB=\"x\ny\"\n", "export K = v # c\n", "K='open", "=\n\"\n", "A=\"\\n\\\"" });
}
