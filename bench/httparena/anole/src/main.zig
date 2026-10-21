//! HttpArena entry for Anole (https://github.com/xuckless/anole), standard
//! mode: documented APIs and default settings.
//!
//! HttpArena wants four ports with different protocols, and an Anole server
//! has one cleartext and one TLS listener, so the container runs this
//! program twice (entrypoint.sh):
//!
//!   ROLE=h1  8080 HTTP/1.1 + h2c (gRPC), 8081 TLS HTTP/1.1 only
//!   ROLE=h2  8082 h2c,                   8443 TLS h2 + HTTP/3
const std = @import("std");
const anole = @import("anole");
const pb = @import("benchmark_pb");

pub const std_options = anole.std_options;

const Rating = struct { score: i64, count: i64 };

const Item = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const Priced = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

const App = struct {
    dataset: []const Item = &.{},
};

fn baseline(req: *anole.Request, res: *anole.Response) !void {
    var sum: i64 = (req.query.getInt(i64, "a") orelse 0) + (req.query.getInt(i64, "b") orelse 0);
    if (req.method == .post) {
        if (try req.body()) |body| sum += std.fmt.parseInt(i64, std.mem.trim(u8, body, " \t\r\n"), 10) catch 0;
    }
    try res.print(.text, "{d}", .{sum});
}

fn pipeline(_: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "ok", .{});
}

fn delay(req: *anole.Request, res: *anole.Response) !void {
    const ms = req.params.getInt(u32, "ms") orelse return res.fail(.bad_request, "bad delay");
    if (ms > 0) try req.io.sleep(.fromMilliseconds(ms), .awake);
    try res.print(.text, "{d}", .{ms});
}

fn json(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const count = req.params.getInt(usize, "count") orelse return res.fail(.bad_request, "bad count");
    if (count < 1 or count > app.dataset.len) return res.fail(.bad_request, "bad count");
    const m = req.query.getInt(i64, "m") orelse 1;
    const items = try res.arena.alloc(Priced, count);
    for (app.dataset[0..count], items) |it, *out| out.* = .{
        .id = it.id,
        .name = it.name,
        .category = it.category,
        .price = it.price,
        .quantity = it.quantity,
        .active = it.active,
        .tags = it.tags,
        .rating = it.rating,
        .total = it.price * it.quantity * m,
    };
    // Compressed when the client accepts it (gzip or zstd), as configured
    // per response in docs/routing.md#compression.
    res.compress = true;
    try res.json(.{ .items = items, .count = count });
}

fn echo(req: *anole.Request, res: *anole.Response) !void {
    res.body = (try req.body()) orelse "";
    try res.header("Content-Type", "application/octet-stream");
}

/// /ws: every text or binary message straight back.
const WsEcho = struct {
    pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
};

fn wsLoop(ws: *anole.websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

// gRPC: benchmark.BenchmarkService (requests/benchmark.proto).
const Call = anole.grpc.Call;

const Benchmark = struct {
    pub fn GetSum(_: *Call, req: pb.SumRequest) anyerror!pb.SumReply {
        return .{ .result = req.a +% req.b };
    }
    pub fn StreamSum(call: *Call, req: pb.StreamRequest, out: *std.Io.Queue(pb.SumReply)) anyerror!void {
        var i: i32 = 0;
        while (i < req.count) : (i += 1) try out.putOne(call.io, .{ .result = req.a +% req.b +% i });
    }
    pub fn CollectSum(call: *Call, in: *std.Io.Queue(pb.SumRequest)) anyerror!pb.SumReply {
        var total: i32 = 0;
        while (true) {
            const r = in.getOne(call.io) catch |err| switch (err) {
                error.Closed => return .{ .result = total },
                else => |e| return e,
            };
            total +%= r.a +% r.b;
        }
    }
    pub fn EchoSum(call: *Call, in: *std.Io.Queue(pb.SumRequest), out: *std.Io.Queue(pb.SumReply)) anyerror!void {
        while (true) {
            const r = in.getOne(call.io) catch |err| switch (err) {
                error.Closed => return,
                else => |e| return e,
            };
            try out.putOne(call.io, .{ .result = r.a +% r.b });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const role = init.environ_map.get("ROLE") orelse "h1";
    const h2 = std.mem.eql(u8, role, "h2");
    const cert: anole.Cert = .fromFiles("/certs/server.crt", "/certs/server.key");

    var state: App = .{};
    const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, "/data/dataset.json", init.arena.allocator(), .limited(16 << 20));
    state.dataset = try std.json.parseFromSliceLeaky([]const Item, init.arena.allocator(), raw, .{ .ignore_unknown_fields = true });

    var app = try anole.Server(App).init(init.gpa, .{
        .http = .{ .address = "0.0.0.0", .port = if (h2) 8082 else 8080 },
        .https = .{
            .address = "0.0.0.0",
            .port = if (h2) 8443 else 8081,
            .cert = cert,
            .alpn_protocols = if (h2) null else &.{"http/1.1"},
        },
        .http3 = if (h2) .{} else null,
        .server = .{
            // The async and WebSocket profiles hold 32,000 and 16,384
            // connections; the default cap is 10,000.
            .max_connections = null,
        },
    }, &state);
    defer app.deinit();

    app.get("/baseline11", anole.noWait(baseline));
    app.post("/baseline11", anole.noWait(baseline));
    app.get("/baseline2", anole.noWait(baseline));
    app.post("/baseline2", anole.noWait(baseline));
    app.get("/pipeline", anole.noWait(pipeline));
    app.get("/delay/:ms", delay);
    app.get("/json/:count", anole.noWait(json));
    app.post("/echo", echo);
    if (comptime @hasDecl(anole.Server(App), "wsCallbacks")) {
        app.wsCallbacks("/ws", WsEcho);
    } else {
        app.ws("/ws", wsLoop);
    }
    try app.staticDir("/static", "/data/static", .{ .precompressed = &.{ .br, .gzip } });
    app.grpcWith(pb.BenchmarkService, Benchmark, .{ .no_wait = true });

    try app.run();
}
