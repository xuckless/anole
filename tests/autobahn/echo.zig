//! The Autobahn fuzzing client's peer: every text or binary message is
//! echoed back on the socket it arrived on, from a `receive` loop, or with
//! `callbacks` as the second argument through WebSocket callbacks, parking
//! the socket whenever it has nothing to read for a millisecond.
//!
//!   zig build autobahn-echo -Doptimize=ReleaseSafe && tests/autobahn/run.sh
//!   tests/autobahn/run.sh zig-out/bin/autobahn-echo callbacks
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{ .{ .scope = .zio, .level = .info }, .{ .scope = .dusty_access, .level = .warn } },
};

fn echo(req: *anole.Request, res: *anole.Response) !void {
    var ws = (try anole.websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => ws.send(msg.type, msg.data) catch return,
            .close => return,
            else => {},
        }
    }
}

const Echo = struct {
    pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
};

pub fn main(init: std.process.Init) !void {
    var port: u16 = 9001;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    const callbacks = if (args.next()) |mode| std.mem.eql(u8, mode, "callbacks") else false;
    var app = try anole.Server(void).init(init.gpa, .{
        // Docker reaches the host through its gateway, not loopback.
        .http = .{ .address = "0.0.0.0", .port = port },
        .server = .{ .timeout = .{ .idle_park = if (callbacks) .fromMilliseconds(1) else .fromSeconds(1) } },
    }, {});
    defer app.deinit();
    if (callbacks) app.wsCallbacks("/", Echo) else app.get("/", echo);
    try app.run();
}
