//! Opening a file so that it cannot be somewhere else than under a
//! directory, for `StaticOptions.resolve_beneath` and `Response.sendFile`.
//!
//! Two tiers, picked once per server by `probe`:
//!
//! - `.kernel`: the OS refuses a path that leaves the directory (Linux
//!   openat2 `RESOLVE_BENEATH`, macOS 26+ `O_RESOLVE_BENEATH`). No extra
//!   work per open. Absolute symlinks are refused even when they point
//!   back inside the directory.
//! - `.verify`: open, then compare the open file's real path with the real
//!   path of the directory (Windows, macOS 15.x, Linux without openat2, any
//!   `Io` that ignores the flag). One more blocking-pool hop per open under
//!   zio. Absolute symlinks that point inside are served.
//!
//! On `.kernel`, an open that fails with `error.Unexpected` or
//! `error.WouldBlock` is redone on the verify path: zio's io_uring backend
//! reports an openat2 `EAGAIN` (any rename or mount on the host during a
//! walk that has a `..` in it) as `Unexpected`, and `std.Io.Threaded` reports
//! macOS 26's `ENOTCAPABLE` the same way. The verify path refuses whatever
//! leaves the directory, so nothing unsafe is served by the retry.
//!
//! The macOS probe is Bun's `kernel_resolves_beneath` (src/sys/beneath.rs at
//! 4f7acde, MIT, Copyright (c) Oven): open `..` with `O_RESOLVE_BENEATH` and
//! trust the flag only when the answer is `ENOTCAPABLE`, which macOS 26
//! gives; 15.4 to 26.0 accept other semantics (and lack some checks 26.1
//! added), and older ones ignore the bit. See THIRD_PARTY_NOTICES.

const std = @import("std");
const builtin = @import("builtin");

pub const Tier = enum { kernel, verify };

/// Why `probe` chose its tier, for the startup line.
pub const Why = enum {
    /// `.kernel`: the OS refused to leave the directory.
    kernel_refuses,
    /// `.verify`: Windows has no scoped open.
    windows,
    /// `.verify`: the open of `..` with the flag worked, so the `Io` or the
    /// OS ignores it (std.Io.Threaded on Linux, macOS before 26).
    flag_ignored,
    /// `.verify`: the kernel has no openat2 (Linux before 5.6).
    no_openat2,
    /// `.verify`: a seccomp filter blocks openat2 (Docker before 20.10).
    openat2_blocked,
    /// `.verify`: the probe could not run (no `..` to open, or another error).
    probe_failed,

    /// Whether this verdict is the expected one on this platform, so the
    /// startup line is for debug only.
    pub fn expected(self: Why) bool {
        return switch (self) {
            .kernel_refuses, .windows => true,
            .flag_ignored => builtin.os.tag == .macos,
            else => false,
        };
    }

    pub fn text(self: Why) []const u8 {
        return switch (self) {
            .kernel_refuses => "the kernel refuses paths that leave the directory",
            .windows => "Windows has no scoped open",
            .flag_ignored => "this OS or Io ignores the scoped-open flag",
            .no_openat2 => "this kernel has no openat2 (before Linux 5.6), or the Io cannot use it",
            .openat2_blocked => "openat2 is blocked here (a seccomp filter, as in Docker before 20.10)",
            .probe_failed => "the scoped-open probe could not run",
        };
    }
};

pub const Probe = struct {
    tier: Tier,
    why: Why,
};

/// Test only: when set, `probe` answers this tier, so a test can run the
/// verify code where the natural tier is `.kernel`.
pub var test_force: if (builtin.is_test) ?Tier else void = if (builtin.is_test) null else {};

/// Which tier opens through `dir` use on this machine. Never fails: any
/// doubt is `.verify`. Run it before connections are served; it opens `..`
/// of `dir` once or twice and closes it.
pub fn probe(io: std.Io, dir: std.Io.Dir) Probe {
    if (builtin.is_test) if (test_force) |forced| return .{ .tier = forced, .why = .flag_ignored };
    return switch (builtin.os.tag) {
        .windows => .{ .tier = .verify, .why = .windows },
        .linux => probeLinux(io, dir),
        .macos => probeDarwin(dir),
        else => .{ .tier = .verify, .why = .flag_ignored },
    };
}

/// Two O_PATH opens of `..` (it needs no read permission on the parent, and
/// under `RESOLVE_BENEATH` the kernel answers `EXDEV` for `..` at the root
/// before any permission check): without the flag it must work, with it the
/// answer must be a refusal. Through the `Io`, so one that ignores the flag
/// (Threaded) is detected too.
fn probeLinux(io: std.Io, dir: std.Io.Dir) Probe {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const plain = dir.openFile(io, "..", .{ .path_only = true }) catch return .{ .tier = .verify, .why = .probe_failed };
    plain.close(io);
    if (dir.openFile(io, "..", .{ .path_only = true, .resolve_beneath = true })) |scoped| {
        scoped.close(io);
        return .{ .tier = .verify, .why = .flag_ignored };
    } else |err| return switch (err) {
        error.AccessDenied => .{ .tier = .kernel, .why = .kernel_refuses },
        // zio's strict mode (no openat2) reaches std as `Unexpected`.
        error.Unexpected => .{ .tier = .verify, .why = .no_openat2 },
        error.PermissionDenied => .{ .tier = .verify, .why = .openat2_blocked },
        else => .{ .tier = .verify, .why = .probe_failed },
    };
}

/// Bun's probe: a raw `openat`, since zio maps both macOS 15's `EACCES` and
/// 26's `ENOTCAPABLE` to `AccessDenied` and std's Threaded turns the latter
/// into `Unexpected`.
fn probeDarwin(dir: std.Io.Dir) Probe {
    if (builtin.os.tag != .macos) unreachable;
    const rc = std.c.openat(dir.handle, "..", .{ .DIRECTORY = true, .CLOEXEC = true, .RESOLVE_BENEATH = true });
    if (rc >= 0) {
        _ = std.c.close(rc);
        return .{ .tier = .verify, .why = .flag_ignored };
    }
    if (std.c.errno(rc) == .NOTCAPABLE) return .{ .tier = .kernel, .why = .kernel_refuses };
    return .{ .tier = .verify, .why = .probe_failed };
}

pub const OpenError = std.Io.File.OpenError;

/// Opens `sub_path` under `dir` (relative, no `..`: the caller checked)
/// such that the file is never outside `dir`. A path that escapes is
/// `error.AccessDenied`, which the static handlers answer with a 404.
///
/// `root_real` is the real path of `dir` when the caller has it (the verify
/// tier reads it from `dir` otherwise, which costs one more hop); `scratch`
/// holds the path buffers of the verify tier.
pub fn openFile(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    tier: Tier,
    root_real: ?[]const u8,
    scratch: std.mem.Allocator,
) OpenError!std.Io.File {
    const effective: Tier = if (builtin.is_test) (test_force orelse tier) else tier;
    switch (effective) {
        .kernel => return dir.openFile(io, sub_path, .{ .resolve_beneath = true }) catch |err| switch (err) {
            error.Unexpected, error.WouldBlock => return openVerified(io, dir, sub_path, root_real, scratch),
            else => return err,
        },
        .verify => return openVerified(io, dir, sub_path, root_real, scratch),
    }
}

/// Opens (following links), then refuses a file whose real path is not under
/// the directory's. The check is on the open handle, so there is no window
/// between check and use.
fn openVerified(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    root_real: ?[]const u8,
    scratch: std.mem.Allocator,
) OpenError!std.Io.File {
    const file = try dir.openFile(io, sub_path, .{});
    errdefer file.close(io);

    const root: []const u8 = root_real orelse blk: {
        const buf = scratch.alloc(u8, std.Io.Dir.max_path_bytes) catch return error.SystemResources;
        defer scratch.free(buf);
        const n = dir.realPath(io, buf) catch |err| return realPathFailure(err);
        // Copy out: `buf` goes back to the arena for the next one.
        break :blk scratch.dupe(u8, buf[0..n]) catch return error.SystemResources;
    };
    const buf = scratch.alloc(u8, std.Io.Dir.max_path_bytes) catch return error.SystemResources;
    defer scratch.free(buf);
    const n = file.realPath(io, buf) catch |err| return realPathFailure(err);
    if (!isUnder(root, buf[0..n])) return error.AccessDenied;
    return file;
}

/// A real path that cannot be had refuses the open (a 404 for the static
/// handlers): fail closed, apart from the errors that are not about the path.
fn realPathFailure(err: std.Io.File.RealPathError) OpenError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        else => error.AccessDenied,
    };
}

/// Whether `path` is `root` or something below it. Both are real paths from
/// the same source. A prefix is not enough: `/srv/pub` is not above
/// `/srv/public2/x`. On Windows the compare ignores case and takes `\` or `/`.
pub fn isUnder(root: []const u8, path: []const u8) bool {
    const windows = builtin.os.tag == .windows;
    const trimmed = std.mem.trimEnd(u8, root, if (windows) "/\\" else "/");
    if (path.len < trimmed.len) return false;
    const same = if (windows)
        std.ascii.eqlIgnoreCase(path[0..trimmed.len], trimmed)
    else
        std.mem.eql(u8, path[0..trimmed.len], trimmed);
    if (!same) return false;
    if (path.len == trimmed.len) return true;
    const next = path[trimmed.len];
    return next == '/' or (windows and next == '\\');
}

test "isUnder: the directory itself and what is below it" {
    try std.testing.expect(isUnder("/srv/pub", "/srv/pub"));
    try std.testing.expect(isUnder("/srv/pub", "/srv/pub/a/b.css"));
    try std.testing.expect(isUnder("/srv/pub/", "/srv/pub/a"));
}

test "isUnder: a longer sibling name or a parent is not under" {
    try std.testing.expect(!isUnder("/srv/pub", "/srv/public2/x"));
    try std.testing.expect(!isUnder("/srv/pub", "/srv"));
    try std.testing.expect(!isUnder("/srv/pub", "/etc/passwd"));
}

test "isUnder: a root of / holds every absolute path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(isUnder("/", "/etc/passwd"));
    try std.testing.expect(isUnder("/", "/"));
}

test "isUnder: Windows ignores case and takes either separator" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isUnder("C:\\Srv\\Pub", "c:\\srv\\pub\\a.css"));
    try std.testing.expect(isUnder("C:\\Srv\\Pub", "C:\\Srv\\Pub/a.css"));
    try std.testing.expect(!isUnder("C:\\Srv\\Pub", "C:\\Srv\\Public2\\x"));
}
