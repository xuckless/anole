//! A JSON API over MongoDB: users in a collection with a unique email.
//!
//!   docker run --rm -p 27017:27017 mongo:8.0 --replSet rs0 --bind_ip_all &
//!   docker exec <container> mongosh --eval 'rs.initiate()'
//!   MONGODB_URI='mongodb://localhost:27017/app?directConnection=true' zig build run-mongodb
//!
//!   curl -d '{"name":"Ada","email":"ada@example.com","tags":["math"]}' localhost:3000/users
//!   curl 'localhost:3000/users?tag=math'
//!   curl localhost:3000/users/<id>
//!   curl -X PATCH -d '{"name":"Ada L."}' localhost:3000/users/<id>
//!   curl -X DELETE localhost:3000/users/<id>
//!   curl localhost:3000/readyz
//!
//! The same email twice is a 409, an unknown id a 404, no primary a 503.
//! A standalone mongod works too, without retryable writes and sessions.
const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options;

const App = struct { mongo: *anole.mongodb.Client };

const User = struct {
    _id: anole.bson.ObjectId,
    name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},
};
const NewUser = struct { name: []const u8, email: []const u8, tags: []const []const u8 = &.{} };
const Patch = struct { name: ?[]const u8 = null, tags: ?[]const []const u8 = null };

fn userId(req: *anole.Request) !anole.bson.ObjectId {
    return anole.bson.ObjectId.parse(req.params.get("id") orelse "") catch error.NotFound;
}

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const users = app.mongo.collection("users");
    const limit = req.query.getInt(i64, "limit") orelse 20;
    const found = if (req.query.get("tag")) |tag|
        try users.find(User, req, .{ .tags = tag }, .{ .sort = .{ .name = 1 }, .limit = limit })
    else
        try users.find(User, req, .{}, .{ .sort = .{ .name = 1 }, .limit = limit });
    try res.json(found);
}

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(try app.mongo.collection("users").findOne(User, req, .{ ._id = try userId(req) }, .{}));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewUser);
    const r = try app.mongo.collection("users").insertOne(req, in); // the same email: 409
    res.status = .created;
    try res.json(.{ .id = r.objectId().? });
}

fn update(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const patch = try req.bind(Patch);
    if (patch.name == null and patch.tags == null) return error.BadRequest;
    const users = app.mongo.collection("users");
    // Fields left null are left out of $set.
    const updated = try users.findOneAndUpdate(User, req, .{ ._id = try userId(req) }, .{ .@"$set" = patch }, .{
        .return_document = anole.mongodb.ReturnDocument.after,
    });
    try res.json(updated orelse return error.NotFound);
}

fn remove(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const r = try app.mongo.collection("users").deleteOne(req, .{ ._id = try userId(req) }, .{});
    if (r.deleted_count == 0) return error.NotFound;
    res.status = .no_content;
}

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    // MONGODB_URI, else mongodb://localhost:27017 (database "test").
    state.mongo = try app.mongodb(.{ .environ = init.minimal.environ });
    _ = app.health(.{}); // /readyz pings MongoDB
    app.use(anole.observe.AccessLog.init(.{}));

    // Startup work outside a request: an anole.db.Ctx in place of `req`.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
    _ = state.mongo.collection("users").createIndex(&c, .{ .email = 1 }, .{ .unique = true }) catch |err| {
        std.log.warn("users.email index not created ({t}): {f}", .{ err, anole.db.lastError(&c).? });
    };

    app.get("/users", list);
    app.get("/users/:id", get);
    app.post("/users", create);
    app.patch("/users/:id", update);
    app.delete("/users/:id", remove);
    var args = init.minimal.args.iterate();
    _ = args.skip();
    try app.listen(args.next() orelse ":3000");
}
