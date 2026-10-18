//! Liveness and readiness: `/healthz` answers 200 while the process can
//! answer at all; `/readyz` answers 200 only when every readiness check
//! passes and the server is not draining, 503 otherwise (with the failing
//! check named), so a load balancer stops sending traffic before shutdown.
//!
//!     var health = anole.observe.Health.init(.{});
//!     try health.addCheck("db", dbReady, &pool);
//!     health.registerOn(void, app.router, app.server);
const std = @import("std");
const dusty = @import("dusty");

pub const Check = struct {
    name: []const u8,
    ctx: ?*anyopaque,
    ready: *const fn (ctx: ?*anyopaque) bool,
};

pub const Health = struct {
    checks: [16]Check = undefined,
    len: usize = 0,
    /// Set by `registerOn`: reports the server's drain.
    draining: ?*const fn (server: *anyopaque) bool = null,
    server: ?*anyopaque = null,

    var instance: ?*Health = null;

    pub const Options = struct {};

    pub fn init(_: Options) Health {
        return .{};
    }

    pub fn addCheck(self: *Health, name: []const u8, ready: *const fn (ctx: ?*anyopaque) bool, ctx: ?*anyopaque) !void {
        if (self.len == self.checks.len) return error.TooManyChecks;
        self.checks[self.len] = .{ .name = name, .ctx = ctx, .ready = ready };
        self.len += 1;
    }

    /// Serves `/healthz` and `/readyz` (one `Health` per process).
    pub fn registerOn(self: *Health, comptime Ctx: type, router: *dusty.Router(Ctx), server: *dusty.Server(Ctx)) void {
        instance = self;
        self.server = server;
        self.draining = struct {
            fn f(p: *anyopaque) bool {
                const s: *dusty.Server(Ctx) = @ptrCast(@alignCast(p));
                return s.busy.load(.acquire).draining;
            }
        }.f;
        if (Ctx == void) {
            router.get("/healthz", healthz);
            router.get("/readyz", readyz);
        } else {
            router.get("/healthz", struct {
                fn h(_: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                    return healthz(req, res);
                }
            }.h);
            router.get("/readyz", struct {
                fn h(_: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                    return readyz(req, res);
                }
            }.h);
        }
    }

    fn healthz(_: *dusty.Request, res: *dusty.Response) anyerror!void {
        res.content_type = .text;
        res.body = "ok\n";
    }

    fn readyz(_: *dusty.Request, res: *dusty.Response) anyerror!void {
        res.content_type = .text;
        const self = instance orelse {
            res.body = "ok\n";
            return;
        };
        if (self.draining) |d| if (d(self.server.?)) {
            res.status = .service_unavailable;
            res.body = "draining\n";
            return;
        };
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
