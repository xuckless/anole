//! `anole_console_ui`: the live console's std-only module. The wire protocol,
//! the client, the terminal UI and the restart logic. Linked by the server
//! (in-process mode) and by `anole console`. See research/dx-pass/design-console.md.
const std = @import("std");

pub const sys = @import("sys.zig");
pub const protocol = @import("protocol.zig");
pub const ctlseqs = @import("ctlseqs.zig");
pub const width = @import("width.zig");
pub const keys = @import("keys.zig");
pub const screen = @import("screen.zig");
pub const stats_window = @import("stats_window.zig");
pub const restart_plan = @import("restart_plan.zig");
pub const supervisor = @import("supervisor.zig");
pub const discover = @import("discover.zig");
pub const client = @import("client.zig");
pub const term = @import("term.zig");
pub const app = @import("app.zig");
pub const views = @import("views.zig");
pub const run = @import("run.zig");
pub const relaunch = @import("relaunch.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("app_test.zig");
}
