//! The smallest Anole server: `zig build run-hello`, then
//! `curl localhost:3000`. examples/full spells out every listener and
//! option; examples/rest is a JSON API.
const std = @import("std");
const anole = @import("anole");

/// Optional: keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "Hello, World!";
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    try app.listen(":3000");
}
