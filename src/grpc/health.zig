//! The standard health service, grpc.health.v1.Health: Check, List and
//! Watch over a registry of service statuses. The empty service name is the
//! server as a whole.
//!
//!     var health: anole.grpc.Health = .init(gpa, app.io());
//!     defer health.deinit();
//!     health.registerOn(void, app.router);
//!     try health.set("my.package.MyService", .SERVING);
//!
//! One `Health` per process serves the routes (they are static).
const std = @import("std");
const dusty = @import("dusty");
const server = @import("server.zig");
pub const pb = @import("gen/grpc/health/v1.pb.zig");

pub const ServingStatus = pb.HealthCheckResponse.ServingStatus;
const Call = server.Call;

pub const Health = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    statuses: std.StringArrayHashMapUnmanaged(ServingStatus) = .empty,
    /// Bumped on every change; Watch waits on it.
    generation: std.atomic.Value(u32) = .init(0),

    var instance: ?*Health = null;

    /// The overall status starts as SERVING.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Health {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Health) void {
        if (instance == self) instance = null;
        for (self.statuses.keys()) |k| self.allocator.free(k);
        self.statuses.deinit(self.allocator);
    }

    /// Serves the health service on `router`, from this registry.
    pub fn registerOn(self: *Health, comptime Ctx: type, router: *dusty.Router(Ctx)) void {
        instance = self;
        self.set("", .SERVING) catch @panic("OOM");
        server.register(Ctx, router, pb.Health(Call, anyerror), .{
            .Check = check,
            .List = list,
            .Watch = watch,
        });
    }

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
        const self = instance orelse return call.fail(.unavailable, "health service not set up");
        const status = self.get(req.service) orelse return call.fail(.not_found, "unknown service");
        return .{ .status = status };
    }

    fn list(call: *Call, _: pb.HealthListRequest) anyerror!pb.HealthListResponse {
        const self = instance orelse return call.fail(.unavailable, "health service not set up");
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
        const self = instance orelse return call.fail(.unavailable, "health service not set up");
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
