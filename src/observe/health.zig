//! Liveness and readiness: `/healthz` answers 200 while the process can
//! answer at all; `/readyz` answers 200 only when every readiness check
//! passes and the server is not draining, 503 otherwise (with the failing
//! check named), so a load balancer stops sending traffic before shutdown.
//!
//! In an app, `app.health(.{})` returns one the server owns and serves:
//!
//!     try app.health(.{}).addCheck("db", dbReady, &pool);
//!
//! By hand:
//!
//!     var health = anole.observe.Health.init(.{});
//!     try health.addCheck("db", dbReady, &pool);
//!     health.registerOn(void, app.router, app.server);
//!
//! Each `Health` serves its own server, so two servers in one process can
//! each have one.
const std = @import("std");
const dusty = @import("dusty");
const common = @import("common.zig");

/// A readiness check: `ready(ctx)` says whether the dependency it watches
/// (a database, a queue) can be used now.
pub const Check = struct {
    name: []const u8,
    ctx: ?*anyopaque,
    ready: *const fn (ctx: ?*anyopaque) bool,
};

/// The liveness and readiness routes and their checks.
pub const Health = struct {
    options: Options,
    checks: [16]Check = undefined,
    len: usize = 0,
    /// Set by `registerOn`: reports the server's drain.
    draining: ?*const fn (server: *anyopaque) bool = null,
    server: ?*anyopaque = null,

    pub const Options = struct {
        /// Where `registerOn` serves the two routes.
        healthz_path: []const u8 = "/healthz",
        /// The readiness route.
        readyz_path: []const u8 = "/readyz",
    };

    /// No checks yet: `/readyz` passes until one is added or the server drains.
    pub fn init(options: Options) Health {
        return .{ .options = options };
    }

    /// Adds a readiness check called `name` (shown when it fails): `/readyz`
    /// calls `ready(ctx)` on every request and answers 503 when it returns
    /// false. At most 16 checks (`error.TooManyChecks`). Keep `ready` quick;
    /// it runs on the request's task.
    pub fn addCheck(self: *Health, name: []const u8, ready: *const fn (ctx: ?*anyopaque) bool, ctx: ?*anyopaque) !void {
        if (self.len == self.checks.len) return error.TooManyChecks;
        self.checks[self.len] = .{ .name = name, .ctx = ctx, .ready = ready };
        self.len += 1;
    }

    /// Serves `/healthz` and `/readyz` (or `Options`' paths) on `router`,
    /// with `server`'s drain failing readiness. The `Health` must outlive
    /// the router.
    pub fn registerOn(self: *Health, comptime Ctx: type, router: *dusty.Router(Ctx), server: *dusty.Server(Ctx)) void {
        self.server = server;
        self.draining = struct {
            fn f(p: *anyopaque) bool {
                const s: *dusty.Server(Ctx) = @ptrCast(@alignCast(p));
                return s.busy.load(.acquire).draining;
            }
        }.f;
        common.serve(Ctx, router, self.options.healthz_path, Health, self, healthz);
        common.serve(Ctx, router, self.options.readyz_path, Health, self, readyz);
    }

    /// Whether the server `registerOn` was given has started to drain.
    pub fn isDraining(self: *const Health) bool {
        const d = self.draining orelse return false;
        return d(self.server.?);
    }

    fn healthz(_: *Health, _: *dusty.Request, res: *dusty.Response) anyerror!void {
        res.content_type = .text;
        res.body = "ok\n";
    }

    fn readyz(self: *Health, _: *dusty.Request, res: *dusty.Response) anyerror!void {
        res.content_type = .text;
        // Requests still reach the router during a drain: one pipelined
        // behind another on a keep-alive connection, or an HTTP/2 stream
        // opened before the final GOAWAY.
        if (self.isDraining()) {
            res.status = .service_unavailable;
            res.body = "draining\n";
            return;
        }
        for (self.checks[0..self.len]) |c| {
            if (!c.ready(c.ctx)) {
                res.status = .service_unavailable;
                res.body = try std.fmt.allocPrint(res.arena, "not ready: {s}\n", .{c.name});
                return;
            }
        }
        res.body = "ok\n";
    }
};
