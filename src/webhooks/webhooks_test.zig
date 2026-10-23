//! End to end on the memory store: endpoints, publish fan-out, idempotency.
//! (Delivery itself runs inside the jobs worker; it is exercised by the
//! test round once the jobs engine is merged.)
const std = @import("std");
const anole = @import("../root.zig");
const wh = @import("root.zig");

test "Client: publish keeps one message per idempotency key" {
    const gpa = std.testing.allocator;
    const jc = try anole.jobs.Client.init(gpa, std.testing.io, .{ .store = .memory });
    defer jc.deinit();
    const c = try wh.Client.init(gpa, std.testing.io, .{ .jobs = jc, .allow_private_addresses = true, .require_https = false });
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cx: anole.db.Ctx = .{ .io = std.testing.io, .arena = arena.allocator() };
    const made = try c.createEndpoint(&cx, .{ .owner = "acme", .url = "http://localhost:9/hook", .types = &.{"invoice.*"} });
    try std.testing.expect(std.mem.startsWith(u8, made.secret, "whsec_"));
    try std.testing.expect(std.mem.startsWith(u8, made.endpoint.id, "ep_"));
    const list = try c.listEndpoints(&cx, "acme");
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectError(error.InvalidJob, c.createEndpoint(&cx, .{ .url = "ftp://x" }));
    const rotated = try c.rotateSecret(&cx, made.endpoint.id, .fromSeconds(60));
    try std.testing.expect(!std.mem.eql(u8, rotated, made.secret));
}
