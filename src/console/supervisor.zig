//! Supervisor detection with the real environment and files (design 8.3).
//! The decision itself is `ui.supervisor.detect`.
const std = @import("std");
const ui = @import("anole_console_ui");
const os = @import("os.zig");

fn envFn(_: ?*anyopaque, name: []const u8) ?[]const u8 {
    var buf: [64:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return ui.sys.getenv(buf[0..name.len :0]);
}

fn existsFn(_: ?*anyopaque, path: []const u8) bool {
    return os.exists(path);
}

fn readFn(_: ?*anyopaque, path: []const u8, buf: []u8) ?[]const u8 {
    return os.readSmall(path, buf);
}

pub const real_probe: ui.supervisor.Probe = .{ .env = envFn, .exists = existsFn, .read = readFn };

/// `buf` holds the detail string.
pub fn detect(buf: []u8) ui.supervisor.Result {
    return ui.supervisor.detect(real_probe, buf);
}

/// Inside a container (for the in-process hotkey's gating).
pub fn inContainer() bool {
    if (envFn(null, "KUBERNETES_SERVICE_HOST") != null) return true;
    return os.exists("/.dockerenv") or os.exists("/run/.containerenv");
}
