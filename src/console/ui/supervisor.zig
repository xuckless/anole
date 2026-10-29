//! Supervisor detection (design 8.3), pure over environment lookups and a
//! file probe so it tests without touching the machine. The server calls it
//! at start and sends the result in its hello.
const std = @import("std");
const plan = @import("restart_plan.zig");

pub const Supervisor = plan.Supervisor;

pub const Result = struct {
    kind: Supervisor = .none,
    /// The .service name, the pm2 app name, the supervisord program, or
    /// kubernetes / docker / podman / containerd.
    detail: []const u8 = "",
};

pub const Probe = struct {
    ctx: ?*anyopaque = null,
    /// The environment variable, or null when unset.
    env: *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8,
    /// Does the file exist?
    exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
    /// The file's contents (a prefix is enough), or null.
    read: *const fn (ctx: ?*anyopaque, path: []const u8, buf: []u8) ?[]const u8,
};

/// `buf` holds the detail string (the result points into it or into static text).
pub fn detect(p: Probe, buf: []u8) Result {
    if (p.env(p.ctx, "INVOCATION_ID")) |_| {
        var detail: []const u8 = "";
        if (p.read(p.ctx, "/proc/self/cgroup", buf)) |text| detail = serviceName(text);
        return .{ .kind = .systemd, .detail = detail };
    }
    if (p.env(p.ctx, "pm_id")) |_| return .{ .kind = .pm2, .detail = p.env(p.ctx, "name") orelse "" };
    if (p.env(p.ctx, "SUPERVISOR_ENABLED")) |v| {
        if (std.mem.eql(u8, v, "1")) return .{ .kind = .supervisord, .detail = p.env(p.ctx, "SUPERVISOR_PROCESS_NAME") orelse "" };
    }
    if (p.env(p.ctx, "KUBERNETES_SERVICE_HOST")) |_| return .{ .kind = .container, .detail = "kubernetes" };
    if (p.exists(p.ctx, "/.dockerenv")) return .{ .kind = .container, .detail = "docker" };
    if (p.exists(p.ctx, "/run/.containerenv")) return .{ .kind = .container, .detail = "podman" };
    if (p.read(p.ctx, "/proc/1/cgroup", buf)) |text| {
        if (std.mem.indexOf(u8, text, "kubepods") != null) return .{ .kind = .container, .detail = "kubernetes" };
        if (std.mem.indexOf(u8, text, "docker") != null) return .{ .kind = .container, .detail = "docker" };
        if (std.mem.indexOf(u8, text, "libpod") != null) return .{ .kind = .container, .detail = "podman" };
        if (std.mem.indexOf(u8, text, "containerd") != null) return .{ .kind = .container, .detail = "containerd" };
    }
    if (p.env(p.ctx, "XPC_SERVICE_NAME")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return .{ .kind = .launchd, .detail = v };
    }
    return .{};
}

/// The last "*.service" component of a cgroup file's contents.
fn serviceName(text: []const u8) []const u8 {
    var best: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, text, "/\n");
    while (it.next()) |part| {
        if (std.mem.endsWith(u8, part, ".service")) best = part;
    }
    return best;
}

pub fn kindName(k: Supervisor) []const u8 {
    return @tagName(k);
}

const Fake = struct {
    vars: []const [2][]const u8 = &.{},
    files: []const [2][]const u8 = &.{},

    fn env(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Fake = @ptrCast(@alignCast(ctx));
        for (self.vars) |v| if (std.mem.eql(u8, v[0], name)) return v[1];
        return null;
    }
    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *const Fake = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], path)) return true;
        return false;
    }
    fn read(ctx: ?*anyopaque, path: []const u8, buf: []u8) ?[]const u8 {
        const self: *const Fake = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.mem.eql(u8, f[0], path) and f[1].len > 0) {
            const n = @min(buf.len, f[1].len);
            @memcpy(buf[0..n], f[1][0..n]);
            return buf[0..n];
        };
        return null;
    }
    fn probe(self: *const Fake) Probe {
        return .{ .ctx = @constCast(self), .env = env, .exists = exists, .read = read };
    }
};

test "supervisor: systemd, pm2, supervisord, containers and launchd are told apart by their variables and files" {
    var buf: [256]u8 = undefined;
    const T = std.testing;
    {
        const f: Fake = .{ .vars = &.{.{ "INVOCATION_ID", "abc" }}, .files = &.{.{ "/proc/self/cgroup", "0::/system.slice/api.service\n" }} };
        const r = detect(f.probe(), &buf);
        try T.expectEqual(Supervisor.systemd, r.kind);
        try T.expectEqualStrings("api.service", r.detail);
    }
    {
        const f: Fake = .{ .vars = &.{ .{ "pm_id", "0" }, .{ "name", "web" } } };
        const r = detect(f.probe(), &buf);
        try T.expectEqual(Supervisor.pm2, r.kind);
        try T.expectEqualStrings("web", r.detail);
    }
    {
        const f: Fake = .{ .vars = &.{ .{ "SUPERVISOR_ENABLED", "1" }, .{ "SUPERVISOR_PROCESS_NAME", "api" } } };
        try T.expectEqual(Supervisor.supervisord, detect(f.probe(), &buf).kind);
        const g: Fake = .{ .vars = &.{.{ "SUPERVISOR_ENABLED", "0" }} };
        try T.expectEqual(Supervisor.none, detect(g.probe(), &buf).kind);
    }
    {
        const f: Fake = .{ .vars = &.{.{ "KUBERNETES_SERVICE_HOST", "10.0.0.1" }} };
        try T.expectEqualStrings("kubernetes", detect(f.probe(), &buf).detail);
        const d: Fake = .{ .files = &.{.{ "/.dockerenv", "" }} };
        try T.expectEqualStrings("docker", detect(d.probe(), &buf).detail);
        const p: Fake = .{ .files = &.{.{ "/run/.containerenv", "" }} };
        try T.expectEqualStrings("podman", detect(p.probe(), &buf).detail);
        const c: Fake = .{ .files = &.{.{ "/proc/1/cgroup", "0::/kubepods/burstable/pod1\n" }} };
        try T.expectEqual(Supervisor.container, detect(c.probe(), &buf).kind);
        const ct: Fake = .{ .files = &.{.{ "/proc/1/cgroup", "0::/containerd/x\n" }} };
        try T.expectEqualStrings("containerd", detect(ct.probe(), &buf).detail);
    }
    {
        const f: Fake = .{ .vars = &.{.{ "XPC_SERVICE_NAME", "com.example.api" }} };
        try T.expectEqual(Supervisor.launchd, detect(f.probe(), &buf).kind);
        const z: Fake = .{ .vars = &.{.{ "XPC_SERVICE_NAME", "0" }} };
        try T.expectEqual(Supervisor.none, detect(z.probe(), &buf).kind);
        const n: Fake = .{};
        try T.expectEqual(Supervisor.none, detect(n.probe(), &buf).kind);
    }
}
