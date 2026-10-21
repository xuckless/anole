//! Role-based access control: roles grant permissions ("posts:write"),
//! a role can include others, and `*` or `area:*` grant broadly.
//!
//!     const policy: anole.auth.rbac.Policy = .{ .roles = &.{
//!         .{ .name = "reader", .grants = &.{"posts:read"} },
//!         .{ .name = "editor", .grants = &.{"posts:*"}, .includes = &.{"reader"} },
//!         .{ .name = "admin", .grants = &.{"*"} },
//!     } };
//!     policy.allows("editor", "posts:write") // true
const std = @import("std");
const dusty = @import("dusty");

/// A named role: the permissions it grants (`*` and `area:*` allowed) and
/// the roles whose grants it also has.
pub const Role = struct {
    name: []const u8,
    grants: []const []const u8 = &.{},
    includes: []const []const u8 = &.{},
};

/// Every role the application knows. A role name it does not list grants
/// nothing.
pub const Policy = struct {
    roles: []const Role,

    fn find(self: Policy, name: []const u8) ?Role {
        for (self.roles) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    /// Whether `role` (or a role it includes) grants `permission`.
    pub fn allows(self: Policy, role: []const u8, permission: []const u8) bool {
        return self.allowsDepth(role, permission, 0);
    }

    fn allowsDepth(self: Policy, role: []const u8, permission: []const u8, depth: usize) bool {
        if (depth > 8) return false; // an inclusion cycle
        const r = self.find(role) orelse return false;
        for (r.grants) |g| if (matches(g, permission)) return true;
        for (r.includes) |inc| if (self.allowsDepth(inc, permission, depth + 1)) return true;
        return false;
    }

    /// Whether any of `roles` grants `permission`.
    pub fn anyAllows(self: Policy, roles: []const []const u8, permission: []const u8) bool {
        for (roles) |r| if (self.allows(r, permission)) return true;
        return false;
    }
};

/// `*` matches everything; `area:*` everything in `area`.
fn matches(grant: []const u8, permission: []const u8) bool {
    if (std.mem.eql(u8, grant, "*")) return true;
    if (std.mem.endsWith(u8, grant, ":*")) return std.mem.startsWith(u8, permission, grant[0 .. grant.len - 1]);
    return std.mem.eql(u8, grant, permission);
}

/// Who the request is, as far as roles go: the roles for this request
/// (from its session, its token, its API key, the application's state:
/// the application decides), in `req.arena` or longer-lived memory.
/// `ctx` is `Roles.ptr`. An error answers 500.
pub const RolesFn = *const fn (ctx: ?*anyopaque, req: *dusty.Request) anyerror![]const []const u8;

/// A roles function and the context it gets.
pub const Roles = struct {
    ptr: ?*anyopaque = null,
    roles: RolesFn,
};

/// Requires `permission`: 403 otherwise.
///
///     var can_write = anole.auth.rbac.Require.init(&policy, "notes:write", .{ .ptr = &app, .roles = rolesOf });
pub const Require = struct {
    policy: *const Policy,
    permission: []const u8,
    roles: Roles,

    /// A middleware that lets a request through when one of its roles (from
    /// `roles`) has `permission` under `policy`, which must outlive it.
    pub fn init(policy: *const Policy, permission: []const u8, roles: Roles) Require {
        return .{ .policy = policy, .permission = permission, .roles = roles };
    }

    pub fn execute(self: *const Require, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        if (!self.policy.anyAllows(try self.roles.roles(self.roles.ptr, req), self.permission)) {
            res.status = .forbidden;
            res.content_type = .text;
            res.body = "403 Forbidden\n";
            return;
        }
        return executor.next();
    }
};

test "roles, inclusion and wildcards" {
    const policy: Policy = .{ .roles = &.{
        .{ .name = "reader", .grants = &.{"posts:read"} },
        .{ .name = "editor", .grants = &.{"posts:*"}, .includes = &.{"reader"} },
        .{ .name = "admin", .grants = &.{"*"} },
        .{ .name = "loop", .includes = &.{"loop"} },
    } };
    try std.testing.expect(policy.allows("reader", "posts:read"));
    try std.testing.expect(!policy.allows("reader", "posts:write"));
    try std.testing.expect(policy.allows("editor", "posts:delete"));
    try std.testing.expect(!policy.allows("editor", "users:delete"));
    try std.testing.expect(policy.allows("admin", "users:delete"));
    try std.testing.expect(!policy.allows("nobody", "posts:read"));
    try std.testing.expect(!policy.allows("loop", "x"));
    try std.testing.expect(policy.anyAllows(&.{ "reader", "admin" }, "billing:read"));
}

test "Require: roles from the application's state, 403 without the permission" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const policy: Policy = .{ .roles = &.{
        .{ .name = "reader", .grants = &.{"notes:read"} },
        .{ .name = "editor", .grants = &.{"notes:*"} },
    } };
    // The application's state: one user's role, looked up by a header.
    const App = struct {
        role_of_bob: []const u8 = "reader",

        fn rolesOf(ctx: ?*anyopaque, req: *dusty.Request) anyerror![]const []const u8 {
            const app: *@This() = @ptrCast(@alignCast(ctx.?));
            const who = req.headers.get("X-User") orelse return &.{};
            if (!std.mem.eql(u8, who, "bob")) return &.{};
            const roles = try req.arena.alloc([]const u8, 1);
            roles[0] = app.role_of_bob;
            return roles;
        }
    };
    var app: App = .{};
    var can_write = Require.init(&policy, "notes:write", .{ .ptr = &app, .roles = App.rolesOf });

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    const mw = [_]dusty.Middleware(void){.init(&can_write)};
    server.router.group("", &mw).post("/notes", struct {
        fn h(_: *dusty.Request, res: *dusty.Response) !void {
            res.status = .created;
        }
    }.h);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(server.address.ip.getPort()) };

    const Post = struct {
        fn status(io_: std.Io, a: std.Io.net.IpAddress, user: []const u8) !u16 {
            const stream = try a.connect(io_, .{ .mode = .stream });
            defer stream.close(io_);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            try w.interface.print("POST /notes HTTP/1.1\r\nHost: x\r\nX-User: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{user});
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            return std.fmt.parseInt(u16, (try r.interface.takeDelimiterInclusive('\n'))[9..12], 10);
        }
    };
    try std.testing.expectEqual(@as(u16, 403), try Post.status(io, addr, "bob"));
    try std.testing.expectEqual(@as(u16, 403), try Post.status(io, addr, "eve"));
    app.role_of_bob = "editor";
    try std.testing.expectEqual(@as(u16, 201), try Post.status(io, addr, "bob"));
}
