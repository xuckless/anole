//! The Anole side of the Fiber benchmark (bench/run.sh): the same three
//! routes as bench/fiber, with no middleware, on HTTP/1.1 and h2c.
//!
//!   zig build bench-server -Doptimize=ReleaseFast
//!   zig-out/bin/bench-server 8080
const std = @import("std");
const anole = @import("anole");
const http = anole.http;

pub const zio_options = anole.zio_options;

pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

fn plaintext(_: *http.Request, res: *http.Response) !void {
    res.content_type = .text;
    res.body = "Hello, World!";
}

fn json(_: *http.Request, res: *http.Response) !void {
    try anole.json.respond(res, .{ .message = "Hello, World!" });
}

fn user(req: *http.Request, res: *http.Response) !void {
    try res.print(.text, "user {s}", .{req.params.get("id") orelse ""});
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);

    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = port, .h2c = true },
    }, {});
    defer app.deinit();
    app.get("/plaintext", plaintext);
    app.get("/json", json);
    app.get("/users/:id", user);
    std.log.info("bench server on http://127.0.0.1:{d} (HTTP/1.1 and h2c)", .{port});
    try app.run();
}
