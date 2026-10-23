//! The admin JSON routes (§7.3). Mounted by `Client.adminRoutes(group)`.
const std = @import("std");
const root = @import("root.zig");

pub fn mount(client: *root.Client, group: anytype) void {
    _ = client;
    _ = group;
}
