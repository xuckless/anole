//! Redis (or Valkey): a hit counter, a cache in front of slow work, a
//! leaderboard, and pub/sub streamed to the browser as Server-Sent Events,
//! with the server in /readyz and /metrics.
//!
//!   docker run --rm -d --name cache -p 6379:6379 redis:7
//!   zig build run-redis                          # REDIS_URL, else redis://127.0.0.1:6379
//!
//!   curl localhost:3000/hits
//!   curl -i localhost:3000/quotes/42             # slow the first time, then cached for 30 s
//!   curl -X POST 'localhost:3000/scores/ada?points=10'
//!   curl localhost:3000/leaderboard
//!   curl -N localhost:3000/rooms/lobby/events    # waits for messages...
//!   curl -d 'hello' localhost:3000/rooms/lobby   # ...and this sends one
//!   curl localhost:3000/readyz
//!   curl localhost:3000/metrics
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;

const App = struct { cache: *anole.redis.Client };

fn hits(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .hits = try app.cache.incr(req, "example:hits") });
}

/// Cache-aside: the answer from Redis when it is there, else made (slowly)
/// and kept for 30 seconds.
fn quote(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u32, "id") orelse return error.NotFound;
    const key = try std.fmt.allocPrint(req.arena, "example:quote:{d}", .{id});
    if (try app.cache.get(req, key)) |cached| {
        try res.header("X-Cache", "hit");
        res.content_type = .json;
        res.body = cached;
        return;
    }
    try req.io.sleep(.fromMilliseconds(500), .awake); // the slow part
    const body = try std.fmt.allocPrint(req.arena, "{{\"id\":{d},\"quote\":\"Simplicity is prerequisite for reliability.\"}}", .{id});
    _ = try app.cache.set(req, key, body, .{ .ttl = .fromSeconds(30) });
    try res.header("X-Cache", "miss");
    res.content_type = .json;
    res.body = body;
}

fn score(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const name = req.params.get("name") orelse return error.NotFound;
    const points = req.query.getInt(i32, "points") orelse 1;
    try res.json(.{ .name = name, .score = try app.cache.zincrBy(req, "example:board", @floatFromInt(points), name) });
}

fn leaderboard(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(try app.cache.zrangeWithScores(req, "example:board", 0, 9, .{ .rev = true }));
}

fn publish(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const room = req.params.get("room") orelse return error.NotFound;
    const text = try req.body() orelse return error.BadRequest;
    const channel = try std.fmt.allocPrint(req.arena, "example:room:{s}", .{room});
    try res.json(.{ .receivers = try app.cache.publish(req, channel, text) });
}

/// Every message published to the room, as an event. The subscription has
/// a connection of its own; it ends when the client goes away (the next
/// event cannot be sent) or the server starts to drain.
fn events(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const room = req.params.get("room") orelse return error.NotFound;
    req.setTimeout(.none); // a stream, not a request with a deadline
    const channel = try std.fmt.allocPrint(req.arena, "example:room:{s}", .{room});
    const sub = try app.cache.subscribe(req, channel);
    defer sub.close();
    var buf: [1024]u8 = undefined;
    var stream = try res.startEventStream(&buf);
    try stream.send("subscribed", .{ .event = "ready" });
    while (try sub.next(req)) |msg| try stream.send(msg.payload, .{ .event = "message" });
    try stream.body.end();
}

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    // REDIS_URL (redis://, rediss:// for TLS), else redis://127.0.0.1:6379.
    state.cache = try app.redis(.{});
    _ = app.metrics(.{}); // the pool and command times too
    _ = app.health(.{}); // /readyz sends PING
    app.use(anole.observe.AccessLog.init(.{}));

    app.get("/hits", hits);
    app.get("/quotes/:id", quote);
    app.post("/scores/:name", score);
    app.get("/leaderboard", leaderboard);
    app.post("/rooms/:room", publish);
    app.get("/rooms/:room/events", events);

    var args = init.minimal.args.iterate();
    _ = args.skip();
    try app.listen(args.next() orelse ":3000");
}
