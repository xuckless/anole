//! {{name}}: most of Anole in one app that runs with no outside service.
//! Read it top to bottom, keep what you need and delete the rest.
//!
//!   zig build run          # http://localhost:3000 (HTTP/1.1 and h2c), docs at /docs
//!   zig build test         # one test per area, in memory
//!   zig build openapi      # writes openapi.json
//!
//! Areas, in order: typed routes with validation (todos on SQLite), a
//! WebSocket chat, server-sent event topics, background jobs and a cron
//! schedule (stored in SQLite), sessions with CSRF, bearer tokens (JWT), API
//! keys and roles, a gRPC service that also answers REST and Connect, an
//! outbound client with retry and a breaker, and metrics, health and
//! tracing. `main` ends with the connectors that need a service
//! (PostgreSQL, Redis, NATS, Kafka, S3, SMTP): each starts when its URL is
//! set.
const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");
const config = @import("config.zig");

const auth = anole.auth;
const websocket = anole.websocket;
const v = anole.validate;

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

/// The state every handler gets first.
pub const App = struct {
    db: *anole.sqlite.Client,
    rooms: websocket.Rooms,
    /// Server-sent event topics: GET /events streams the todos as they change.
    live: *anole.sse.Topics,
    /// Background jobs, stored in the SQLite database (they survive a restart).
    jobs: *anole.jobs.Client,
    /// The bearer tokens' key, by `kid`.
    jwt_keys: [1]auth.Key,
    /// The SHA-256 of the one API key; a real app looks digests up in its database.
    api_key_digest: auth.apikey.Digest,
    session_key: [anole.session.key_length]u8,
    upstream_url: []const u8,
};

pub const schema =
    \\CREATE TABLE IF NOT EXISTS todos (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL UNIQUE CHECK (length(title) > 0),
    \\    done INTEGER NOT NULL DEFAULT 0
    \\);
;

const issuer = "{{name}}";
const audience = "api";

// ------------------------------------------------------------------ todos: typed routes, validation, SQLite

const Todo = struct { id: i64, title: []const u8, done: bool };

const NewTodo = struct {
    title: []const u8,

    // Checked before the handler runs: a request that breaks a rule gets a
    // 422 that names the field, and the OpenAPI document shows the limits.
    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
    };
};

fn listTodos(app: *App, req: *anole.Request, in: anole.In(.{ .query = struct { limit: u32 = 50 } })) ![]const Todo {
    return app.db.all(Todo, req, "SELECT id, title, done FROM todos ORDER BY id LIMIT ?", .{in.query.limit});
}

fn getTodo(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: i64 } })) !Todo {
    // No such row: error.NotFound, a 404.
    return app.db.one(Todo, req, "SELECT id, title, done FROM todos WHERE id = ?", .{in.path.id});
}

fn createTodo(app: *App, req: *anole.Request, in: anole.In(.{ .body = NewTodo })) !anole.Created(Todo) {
    // The same title twice breaks UNIQUE: error.Conflict, a 409.
    const todo = try app.db.one(Todo, req, "INSERT INTO todos (title) VALUES (?) RETURNING id, title, done", .{in.body.title});
    // Every open /events stream gets it; nothing waits for the subscribers.
    _ = try app.live.publishJson("todos", "created", todo);
    // The slow part (an email, a webhook) runs later, retried if it fails.
    _ = try app.jobs.enqueue(req, Announce{ .id = todo.id }, .{});
    return .{ .value = todo, .location = try std.fmt.allocPrint(req.arena, "/todos/{d}", .{todo.id}) };
}

fn deleteTodo(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: i64 } })) !void {
    if (try app.db.exec(req, "DELETE FROM todos WHERE id = ?", .{in.path.id}) == 0) return error.NotFound;
}

// ------------------------------------------------------------------ WebSocket chat

/// Joins the room named by `?room=` and sends every message to the room.
fn chat(app: *App, ws: *websocket.Socket, req: *anole.Request) !void {
    const room = req.query.get("room") orelse "lobby";
    try app.rooms.join(room, ws);
    defer app.rooms.leave(room, ws);
    while (try ws.next()) |msg| {
        if (msg.type == .text) _ = app.rooms.broadcast(room, .text, msg.data, null);
    }
}

// ------------------------------------------------------------------ server-sent events, jobs and cron

// GET /events (`app.sse` in `routes`): `new EventSource("/events")` gets a
// `created` event for every new todo. An idle subscriber holds no task; a
// browser that reconnects gets what it missed (`Last-Event-ID`).

/// Runs after a todo is created, outside the request. Here it only logs;
/// sending an email or calling a webhook goes here. An error retries it with
/// backoff.
const Announce = struct {
    id: i64,
    pub const job: anole.jobs.Kind = .{ .name = "todos.announce" };
};

fn announce(_: *App, job: *anole.jobs.Job, args: Announce) !void {
    std.log.info("{s}: todo {d} created", .{ job.id_text, args.id });
}

/// Every night at 03:00 UTC the done todos go: one run per tick, however
/// many instances run.
const Sweep = struct {
    pub const job: anole.jobs.Kind = .{ .name = "todos.sweep" };
};

fn sweep(app: *App, job: *anole.jobs.Job, _: Sweep) !void {
    const removed = try app.db.exec(job, "DELETE FROM todos WHERE done = 1", .{});
    _ = try app.live.publishJson("todos", "swept", .{ .removed = removed });
}

/// The event topics and the job queue, with its handlers and schedule. After
/// the database, before `routes`; apart from `main` so that src/main_test.zig
/// has them too.
pub fn services(app: *anole.Server(App), state: *App) !void {
    state.live = try app.sseTopics(.{});
    state.jobs = try app.jobs(.{ .store = .{ .sqlite = state.db } });
    try state.jobs.handle(app, Announce, .{}, announce);
    try state.jobs.handle(app, Sweep, .{}, sweep);
    try state.jobs.cron("todos.sweep", "0 3 * * *", Sweep{}, .{});
}

// ------------------------------------------------------------------ sessions and CSRF

/// A page's first request starts the session and gets the CSRF token every
/// later POST must send back in `X-CSRF-Token`.
fn sessionInfo(_: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .user = req.session.get("user"), .csrf = try auth.csrf.token(req) });
}

fn signIn(_: *App, req: *anole.Request, in: anole.In(.{ .body = struct { name: []const u8 } })) !struct { user: []const u8 } {
    try req.session.set("user", in.body.name);
    // A new session id at sign-in (against session fixation).
    try anole.session.regenerate(req);
    return .{ .user = in.body.name };
}

// ------------------------------------------------------------------ bearer tokens, API keys and roles

/// Roles grant permissions; an editor also has everything a reader has.
const policy: auth.rbac.Policy = .{ .roles = &.{
    .{ .name = "reader", .grants = &.{"notes:read"} },
    .{ .name = "editor", .grants = &.{"notes:*"}, .includes = &.{"reader"} },
} };

/// The request's roles: the verified token's `role` claim.
fn rolesOf(_: ?*anyopaque, req: *anole.Request) anyerror![]const []const u8 {
    const claims = auth.claims(req) orelse return &.{};
    const role = claims.string("role") orelse return &.{};
    const roles = try req.arena.alloc([]const u8, 1);
    roles[0] = role;
    return roles;
}

fn me(_: *App, req: *anole.Request, res: *anole.Response) !void {
    // The token RequireJwt verified.
    try res.json(.{ .subject = auth.subject(req) orelse return error.Unauthorized });
}

fn addNote(_: *App, req: *anole.Request, res: *anole.Response) !void {
    // Only an editor gets here: RBAC ran first.
    res.status = .created;
    try res.json(.{ .saved_by = auth.subject(req) orelse "-" });
}

fn lookupKey(ptr: ?*anyopaque, _: std.mem.Allocator, digest: auth.apikey.Digest) anyerror!?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ptr.?));
    return if (std.mem.eql(u8, &digest, &app.api_key_digest)) "reporting-service" else null;
}

fn stats(_: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .owner = auth.apikey.owner(req) orelse return error.Unauthorized, .requests = 42 });
}

/// A signed token for development (printed at startup in development).
pub fn demoToken(arena: std.mem.Allocator, io: std.Io, secret: []const u8, subject: []const u8, role: []const u8) ![]const u8 {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var signer = auth.jwt.SigningMethodHS256.init(arena);
    return signer.signWithHeader(.{ .typ = "JWT", .alg = "HS256", .kid = "demo" }, .{
        .iss = issuer,
        .aud = audience,
        .sub = subject,
        .role = role,
        .iat = now,
        .exp = now + 3600,
    }, secret);
}

// ------------------------------------------------------------------ gRPC

fn sayHello(call: *anole.grpc.Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name must not be empty");
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

fn lookup(call: *anole.grpc.Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    return .{ .message = try std.fmt.allocPrint(call.arena, "hi again, {s}", .{req.name}) };
}

// ------------------------------------------------------------------ an outbound call

/// GET /upstream: calls `upstream_url` through the server's client, which
/// retries idempotent requests and stops calling a host that keeps failing
/// (`ServerOptions.client`, in `main`).
fn upstream(app: *App, req: *anole.Request, res: *anole.Response) !void {
    var r = try anole.client(req).fetch(app.upstream_url, .{});
    defer r.deinit();
    try res.json(.{ .url = app.upstream_url, .status = @backingInt(r.status()) });
}

// ------------------------------------------------------------------ routes

/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.Server(App), state: *App) !void {
    _ = app.health(.{}); // /healthz and /readyz (which pings the database)
    app.openapi(.{ .info = .{ .title = "{{name}}", .version = "0.1.0" } });

    app.get("/todos", listTodos);
    app.get("/todos/:id", getTodo);
    app.post("/todos", createTodo);
    app.delete("/todos/:id", deleteTodo);

    app.wsWith("/ws", chat, .{ .max_message_size = 4096 });
    app.sse("/events", state.live, .{ .topics = &.{"todos"} });
    app.get("/upstream", upstream);

    // Sessions are sealed cookies; CSRF protects every unsafe method behind it
    // (JSON bodies too: `check_json`).
    const web = app.group("", .{ try anole.session.Middleware.init(.{ .key = state.session_key }), auth.csrf.Middleware.init(.{ .check_json = true }) });
    web.get("/session", sessionInfo);
    web.post("/session", signIn);

    // Bearer tokens (HS256, one key): RequireJwt, then roles.
    const bearer = auth.RequireJwt.init(.{ .static = &state.jwt_keys }, .{ .issuer = issuer, .audience = audience }, .{});
    const api = app.group("/api", .{bearer});
    api.get("/me", me);
    api.with(.{auth.rbac.Require.init(&policy, "notes:write", .{ .roles = rolesOf })}).post("/notes", addNote);

    // API keys, for machine clients.
    app.group("/service", .{auth.apikey.Middleware.init(.{ .ptr = state, .lookup = lookupKey })}).get("/stats", stats);

    app.grpc(pb.Greeter, .{ .SayHello = sayHello, .Lookup = lookup });
    try app.grpcHealth().set("greeter.Greeter", .SERVING);
}

pub fn main(init: std.process.Init) !void {
    const cfg = try anole.config.load(config.Config, init, .{});
    const arena = init.arena.allocator();

    var state: App = .{
        .db = undefined,
        .rooms = .init(init.gpa, .{}),
        .live = undefined,
        .jobs = undefined,
        .jwt_keys = .{.{ .kid = "demo", .alg = .HS256, .material = .{ .hmac = cfg.jwt_secret.expose() } }},
        .api_key_digest = undefined,
        .session_key = undefined,
        .upstream_url = cfg.upstream_url,
    };
    defer state.rooms.deinit();

    var app = try anole.Server(App).init(init.gpa, .{
        .http = .{ .port = cfg.port, .h2c = true },
        // The outbound client: retries on idempotent requests, a breaker per host.
        .client = .{ .retry = .{}, .breaker = .{} },
    }, &state);
    defer app.deinit();
    const io = app.io();

    state.session_key = if (cfg.session_key) |k| try anole.session.keyFromBase64(k.expose()) else anole.session.devKey(io);
    const key = try auth.apikey.generate(arena, io);
    state.api_key_digest = key.digest;
    if (app.environment() == .development) {
        std.log.info("demo bearer token for an editor, valid 1 h:\n{s}", .{try demoToken(arena, io, cfg.jwt_secret.expose(), "alice", "editor")});
        std.log.info("demo API key:\n{s}", .{key.key});
    }

    // Global middleware, before the routes.
    app.use(anole.middleware.RequestId.init(.{})); // X-Request-Id
    app.use(anole.observe.AccessLog.init(.{})); // a line per request
    app.use(anole.middleware.Cors.init(.{})); // any origin; narrow it for production
    app.use(anole.middleware.Compress.init(.{})); // gzip / zstd for clients that accept them
    app.rateLimit(.{ .limit = 300 }); // 300 requests a minute per client address
    _ = app.metrics(.{}); // /metrics, with the HTTP and database series
    if (cfg.otel_exporter_otlp_endpoint) |endpoint| _ = try app.tracing(.{ .endpoint = endpoint });

    // The database: a file in data/ (the directory is made here).
    try std.Io.Dir.cwd().createDirPath(io, "data");
    state.db = try app.sqlite("data/app.db");
    var setup_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer setup_arena.deinit();
    var setup: anole.db.Ctx = .{ .io = io, .arena = setup_arena.allocator() };
    try state.db.execScript(&setup, schema);
    try services(&app, &state);

    // Connectors that need a service start when their URL is set.
    if (cfg.database_url) |url| _ = try app.postgres(.{ .url = url.expose() });
    if (cfg.redis_url) |url| _ = try app.redis(.{ .url = url.expose() });
    if (cfg.nats_url) |url| _ = try app.nats(.{ .url = url.expose() });
    if (cfg.kafka_bootstrap_servers != null) _ = try app.kafka(.{}); // reads KAFKA_BOOTSTRAP_SERVERS
    if (cfg.s3_bucket != null) _ = try app.s3(.{}); // reads S3_BUCKET and the AWS_* variables
    if (cfg.smtp_url != null) _ = try app.smtp(.{}); // reads SMTP_URL

    try routes(&app, &state);
    try app.staticDir("/static", "public", .{});
    try app.run();
}
