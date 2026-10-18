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

pub const Role = struct {
    name: []const u8,
    grants: []const []const u8 = &.{},
    includes: []const []const u8 = &.{},
};

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
/// (from its session, its token, its API key: the application decides).
pub const RolesFn = *const fn (req: *dusty.Request) []const []const u8;

/// Requires `permission`: 403 otherwise.
pub const Require = struct {
    policy: *const Policy,
    permission: []const u8,
    roles: RolesFn,

    pub fn execute(self: *const Require, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        if (!self.policy.anyAllows(self.roles(req), self.permission)) {
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
