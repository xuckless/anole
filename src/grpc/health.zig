//! The standard health service, grpc.health.v1.Health: Check, List and
//! Watch over a registry of service statuses. The empty service name is the
//! server as a whole.
//!
//!     var health: anole.grpc.Health = .init(gpa, app.io());
//!     defer health.deinit();
//!     health.registerOn(void, app.router);
//!     try health.set("my.package.MyService", .SERVING);
//!
//! Each `Health` is its own registry: two servers in one process can each
//! register their own (or share one, registered on both routers).
const std = @import("std");
const dusty = @import("dusty");
const server = @import("server.zig");
const safety = @import("anole_safety");
/// The generated grpc.health.v1 messages and service.
pub const pb = @import("gen/grpc/health/v1.pb.zig");

/// SERVING, NOT_SERVING, UNKNOWN or SERVICE_UNKNOWN.
pub const ServingStatus = pb.HealthCheckResponse.ServingStatus;
const Call = server.Call;

/// A registry of service statuses, served as grpc.health.v1.Health.
/// `app.grpcHealth()` makes one owned by the server and registers it.
pub const Health = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Guards `statuses` (a leaf: no lock or wait under it; `set`'s wake is
    /// no wait).
    mutex: safety.Mutex(.leaf) = .init,
    statuses: std.StringArrayHashMapUnmanaged(ServingStatus) = .empty,
    /// Bumped on every change; Watch waits on it.
    generation: std.atomic.Value(u32) = .init(0),

    /// The overall status starts as SERVING.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Health {
        return .{ .allocator = allocator, .io = io };
    }

    /// Frees the registry. Unregister it first: the routes point at it.
    pub fn deinit(self: *Health) void {
        for (self.statuses.keys()) |k| self.allocator.free(k);
        self.statuses.deinit(self.allocator);
    }

    /// Serves the health service on `router`, from this registry, which
    /// must outlive the router.
    pub fn registerOn(self: *Health, comptime Ctx: type, router: *dusty.Router(Ctx)) void {
        self.set("", .SERVING) catch @panic("OOM");
        server.registerWith(Ctx, router, pb.Health(Call, anyerror), .{
            .Check = check,
            .List = list,
            .Watch = watch,
        }, .{ .data = self });
    }

    /// The registry the call's route was registered from.
    fn of(call: *Call) *Health {
        return @ptrCast(@alignCast(call.data.?));
    }

    /// Sets `service`'s status (the full name, "package.Service"; "" for
    /// the server as a whole), waking every Watch on it. Fails only with
    /// `error.OutOfMemory`.
    pub fn set(self: *Health, service: []const u8, status: ServingStatus) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = try self.statuses.getOrPut(self.allocator, service);
        if (!entry.found_existing) entry.key_ptr.* = self.allocator.dupe(u8, service) catch |err| {
            self.statuses.swapRemoveAt(entry.index);
            return err;
        };
        entry.value_ptr.* = status;
        _ = self.generation.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.generation.raw, std.math.maxInt(u32));
    }

    /// Marks every service NOT_SERVING, as a server about to drain does.
    pub fn shutdown(self: *Health) void {
        self.mutex.lockUncancelable(self.io);
        for (self.statuses.values()) |*v| v.* = .NOT_SERVING;
        self.mutex.unlock(self.io);
        _ = self.generation.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.generation.raw, std.math.maxInt(u32));
    }

    fn get(self: *Health, service: []const u8) ?ServingStatus {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.statuses.get(service);
    }

    fn check(call: *Call, req: pb.HealthCheckRequest) anyerror!pb.HealthCheckResponse {
        const self = of(call);
        const status = self.get(req.service) orelse return call.fail(.not_found, "unknown service");
        return .{ .status = status };
    }

    fn list(call: *Call, _: pb.HealthListRequest) anyerror!pb.HealthListResponse {
        const self = of(call);
        var out: pb.HealthListResponse = .{};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.statuses.keys(), self.statuses.values()) |k, v| {
            try out.statuses.append(call.arena, .{ .key = try call.arena.dupe(u8, k), .value = .{ .status = v } });
        }
        return out;
    }

    /// The status now, then each change, until the client goes away.
    fn watch(call: *Call, req: pb.HealthCheckRequest, out: *std.Io.Queue(pb.HealthCheckResponse)) anyerror!void {
        const self = of(call);
        var last: ?ServingStatus = null;
        while (true) {
            const gen = self.generation.load(.acquire);
            const now = self.get(req.service) orelse .SERVICE_UNKNOWN;
            if (last != now) {
                try out.putOne(call.io, .{ .status = now });
                last = now;
            }
            // Wake on a change, or each second to notice a client gone.
            call.io.futexWaitTimeout(u32, &self.generation.raw, gen, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            if (call.cancelled()) return error.Canceled;
        }
    }
};
