//! Where the console's control sockets live and how `anole console` finds
//! them (design 5.1). Shared by the server (which creates the socket) and the
//! CLI (which lists them).
const std = @import("std");

pub const max_name = 48;
/// macOS's sun_path is 104 bytes; one is the terminator.
pub const max_path = 103;

pub const Vars = struct {
    xdg_runtime_dir: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
    uid: u32 = 0,
    linux: bool = true,
    macos: bool = false,
};

pub const PathError = error{ NoSpace, DirTooLong };

/// The directory: $XDG_RUNTIME_DIR/anole (Linux, when set), /run/anole for
/// uid 0 on Linux, $TMPDIR/anole (macOS, per user), else /tmp/anole-<uid>.
pub fn defaultDir(buf: []u8, vars: Vars) PathError![]const u8 {
    if (vars.linux) {
        if (vars.xdg_runtime_dir) |x| if (x.len > 0 and x[0] == '/') return std.fmt.bufPrint(buf, "{s}/anole", .{std.mem.trimEnd(u8, x, "/")}) catch error.NoSpace;
        if (vars.uid == 0) return std.fmt.bufPrint(buf, "/run/anole", .{}) catch error.NoSpace;
    }
    if (vars.macos) {
        if (vars.tmpdir) |t| if (t.len > 0 and t[0] == '/') return std.fmt.bufPrint(buf, "{s}/anole", .{std.mem.trimEnd(u8, t, "/")}) catch error.NoSpace;
    }
    return fallbackDir(buf, vars.uid);
}

pub fn fallbackDir(buf: []u8, uid: u32) PathError![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/anole-{d}", .{uid}) catch error.NoSpace;
}

/// [A-Za-z0-9._-] kept, others become '-', cut to max_name. Writes into `out`
/// (at least max_name bytes) and returns the used part; never empty.
pub fn sanitizeName(out: []u8, name: []const u8) []const u8 {
    const n = @min(@min(name.len, max_name), out.len);
    for (name[0..n], out[0..n]) |c, *o| {
        o.* = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '-';
    }
    if (n == 0) {
        out[0] = 'a';
        return out[0..1];
    }
    return out[0..n];
}

/// "<dir>/<name>.<pid>.sock", the name sanitized and cut so that the whole
/// path fits 103 bytes. A directory too long for even a one-letter name:
/// error.DirTooLong (the caller falls back to `fallbackDir`).
pub fn socketPath(buf: []u8, dir: []const u8, name: []const u8, pid: i32) PathError![]const u8 {
    var pid_buf: [16]u8 = undefined;
    const pid_s = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;
    // dir + '/' + name + '.' + pid + ".sock"
    const fixed = dir.len + 1 + 1 + pid_s.len + ".sock".len;
    if (fixed + 1 > max_path) return error.DirTooLong;
    var name_buf: [max_name]u8 = undefined;
    const clean = sanitizeName(&name_buf, name);
    const room = max_path - fixed;
    const used = clean[0..@min(clean.len, room)];
    return std.fmt.bufPrint(buf, "{s}/{s}.{s}.sock", .{ dir, used, pid_s }) catch error.NoSpace;
}

pub const Entry = struct {
    /// Points into `path`.
    name: []const u8,
    pid: i32,
    path: []const u8,
    mtime_ns: i96,
};

pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.path);
    gpa.free(entries);
}

pub const PidProbe = struct {
    ctx: ?*anyopaque = null,
    alive: *const fn (ctx: ?*anyopaque, pid: i32) bool,
};

/// Splits "<name>.<pid>.sock".
pub fn parseFileName(file: []const u8) ?struct { name: []const u8, pid: i32 } {
    if (!std.mem.endsWith(u8, file, ".sock")) return null;
    const stem = file[0 .. file.len - ".sock".len];
    const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return null;
    if (dot == 0) return null;
    const pid = std.fmt.parseInt(i32, stem[dot + 1 ..], 10) catch return null;
    if (pid <= 0) return null;
    return .{ .name = stem[0..dot], .pid = pid };
}

/// Lists "<name>.<pid>.sock" files in `dir`; entries whose pid is not alive
/// are removed (when this user can) and left out. Sorted by name, then pid.
pub fn listIn(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, dir_path: []const u8, probe: PidProbe) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| gpa.free(e.path);
        out.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .unix_domain_socket and entry.kind != .file) continue;
        const parsed = parseFileName(entry.name) orelse continue;
        if (!probe.alive(probe.ctx, parsed.pid)) {
            dir.deleteFile(io, entry.name) catch {};
            continue;
        }
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        errdefer gpa.free(path);
        try out.append(gpa, .{
            .name = path[dir_path.len + 1 ..][0..parsed.name.len],
            .pid = parsed.pid,
            .path = path,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }
    std.mem.sortUnstable(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            const o = std.mem.order(u8, a.name, b.name);
            return if (o == .eq) a.pid < b.pid else o == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// `listIn` on a directory by path; a missing directory is an empty list.
pub fn list(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, probe: PidProbe) ![]Entry {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return gpa.alloc(Entry, 0),
        else => |e| return e,
    };
    defer dir.close(io);
    return listIn(gpa, io, dir, dir_path, probe);
}

pub const Target = union(enum) {
    any,
    name: []const u8,
    pid: i32,
    path: []const u8,
};

/// "" -> any; all digits -> pid; contains '/' or ends in ".sock" -> path; else name.
pub fn parseTarget(arg: ?[]const u8) Target {
    const a = arg orelse return .any;
    if (a.len == 0) return .any;
    if (std.mem.indexOfScalar(u8, a, '/') != null or std.mem.endsWith(u8, a, ".sock")) return .{ .path = a };
    if (std.fmt.parseInt(i32, a, 10)) |pid| {
        if (pid > 0) return .{ .pid = pid };
    } else |_| {}
    return .{ .name = a };
}

/// The entries a target names.
pub fn select(gpa: std.mem.Allocator, entries: []const Entry, target: Target) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    for (entries) |e| {
        const ok = switch (target) {
            .any => true,
            .name => |n| std.mem.eql(u8, e.name, n),
            .pid => |p| e.pid == p,
            .path => |p| std.mem.eql(u8, e.path, p),
        };
        if (ok) try out.append(gpa, e);
    }
    return out.toOwnedSlice(gpa);
}

test "discover: names sanitized" {
    var buf: [max_name]u8 = undefined;
    try std.testing.expectEqualStrings("My-App-", sanitizeName(&buf, "My App!"));
    try std.testing.expectEqualStrings("a", sanitizeName(&buf, ""));
    const long: [80]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, max_name), sanitizeName(&buf, &long).len);
}

test "discover: default directories" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/1000/anole", try defaultDir(&buf, .{ .xdg_runtime_dir = "/run/user/1000/", .uid = 1000 }));
    try std.testing.expectEqualStrings("/run/anole", try defaultDir(&buf, .{ .uid = 0 }));
    try std.testing.expectEqualStrings("/tmp/anole-1000", try defaultDir(&buf, .{ .uid = 1000 }));
    try std.testing.expectEqualStrings("/var/folders/ab/T/anole", try defaultDir(&buf, .{ .tmpdir = "/var/folders/ab/T/", .linux = false, .macos = true, .uid = 501 }));
}

test "discover: path fits 103 bytes" {
    var buf: [256]u8 = undefined;
    const p = try socketPath(&buf, "/run/user/1000/anole", "api", 48213);
    try std.testing.expectEqualStrings("/run/user/1000/anole/api.48213.sock", p);
    const dir = "/var/folders/zz/abcdefghijklmnopqrstuvwxyz0123456789/T/anole";
    const nm: [48]u8 = @splat('x');
    const p2 = try socketPath(&buf, dir, &nm, 1234567);
    try std.testing.expect(p2.len <= max_path);
    try std.testing.expect(std.mem.endsWith(u8, p2, ".1234567.sock"));
    var longdir: [101]u8 = @splat('d');
    longdir[0] = '/';
    try std.testing.expectError(error.DirTooLong, socketPath(&buf, &longdir, "api", 1));
}

test "discover: parseTarget" {
    try std.testing.expect(parseTarget(null) == .any);
    try std.testing.expect(parseTarget("") == .any);
    try std.testing.expectEqual(@as(i32, 4821), parseTarget("4821").pid);
    try std.testing.expectEqualStrings("api", parseTarget("api").name);
    try std.testing.expectEqualStrings("/tmp/a.sock", parseTarget("/tmp/a.sock").path);
    try std.testing.expectEqualStrings("a.sock", parseTarget("a.sock").path);
    try std.testing.expectEqualStrings("2fa", parseTarget("2fa").name);
}

fn fakeAlive(ctx: ?*anyopaque, pid: i32) bool {
    _ = ctx;
    return pid != 999;
}

test "discover: stale socket removed, ambiguous name lists both" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "api.100.sock", "api.200.sock", "worker.300.sock", "api.999.sock", "notes.txt", "bad.sock" }) |n| {
        var f = try tmp.dir.createFile(io, n, .{});
        f.close(io);
    }
    const entries = try listIn(std.testing.allocator, io, tmp.dir, "/x", .{ .alive = fakeAlive });
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("api", entries[0].name);
    try std.testing.expectEqual(@as(i32, 100), entries[0].pid);
    try std.testing.expectEqual(@as(i32, 200), entries[1].pid);
    try std.testing.expectEqualStrings("worker", entries[2].name);
    try std.testing.expectEqualStrings("/x/api.100.sock", entries[0].path);
    // The dead one was deleted.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "api.999.sock", .{}));
    const apis = try select(std.testing.allocator, entries, .{ .name = "api" });
    defer std.testing.allocator.free(apis);
    try std.testing.expectEqual(@as(usize, 2), apis.len);
    const one = try select(std.testing.allocator, entries, .{ .pid = 300 });
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("worker", one[0].name);
}
