//! A JSON REST API: users kept in memory, behind an API key.
//!
//! The key comes from the environment, never from source; the server keeps
//! only its SHA-256 and compares in constant time:
//!
//!   export API_KEY=$(openssl rand -base64 32)
//!   zig build run-rest                 # every interface, port 3000
//!   zig build run-rest -- 127.0.0.1:4000
//!
//!   curl -H "X-Api-Key: $API_KEY" -d '{"name":"Ada","email":"ada@example.com"}' localhost:3000/api/users
//!   curl -H "X-Api-Key: $API_KEY" 'localhost:3000/api/users?limit=10'
//!   curl -H "X-Api-Key: $API_KEY" localhost:3000/api/users/1
//!   curl -H "X-Api-Key: $API_KEY" -X PUT -d '{"name":"Ada L.","email":"ada@example.com"}' localhost:3000/api/users/1
//!   curl -H "X-Api-Key: $API_KEY" -X DELETE localhost:3000/api/users/1
//!
//! tests/rest_test.zig serves the same routes and checks each one.
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const User = struct { id: u64, name: []const u8, email: []const u8 };
const NewUser = struct { name: []const u8, email: []const u8 };

/// Shared by every handler, on every executor: hence the lock.
pub const Store = struct {
    gpa: std.mem.Allocator,
    /// The API key's SHA-256 (`keyDigest`): the key itself is not kept.
    api_key_digest: [32]u8,
    mutex: std.Io.Mutex = .init,
    users: std.AutoArrayHashMapUnmanaged(u64, User) = .empty,
    next_id: u64 = 1,

    /// Stores a copy of `in` under `id`: `in`'s strings die with the request.
    fn put(self: *Store, id: u64, in: NewUser) !User {
        if (in.name.len == 0) return error.UnprocessableEntity;
        const name = try self.gpa.dupe(u8, in.name);
        errdefer self.gpa.free(name);
        const email = try self.gpa.dupe(u8, in.email);
        errdefer self.gpa.free(email);
        const slot = try self.users.getOrPut(self.gpa, id);
        if (slot.found_existing) self.free(slot.value_ptr.*);
        slot.value_ptr.* = .{ .id = id, .name = name, .email = email };
        return slot.value_ptr.*;
    }

    fn free(self: *Store, user: User) void {
        self.gpa.free(user.name);
        self.gpa.free(user.email);
    }

    pub fn deinit(self: *Store) void {
        for (self.users.values()) |user| self.free(user);
        self.users.deinit(self.gpa);
    }
};

fn userId(req: *anole.Request) !u64 {
    return req.params.getInt(u64, "id") orelse error.NotFound;
}

fn list(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    const limit = req.query.getInt(usize, "limit") orelse 20;
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    const users = store.users.values();
    try res.json(users[0..@min(limit, users.len)]);
}

fn get(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    try res.json(store.users.get(try userId(req)) orelse return error.NotFound);
}

fn create(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewUser); // no body, or not a NewUser: 400
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    const user = try store.put(store.next_id, in);
    store.next_id += 1;
    res.status = .created;
    try res.json(user);
}

fn update(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewUser);
    const id = try userId(req);
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    if (!store.users.contains(id)) return error.NotFound;
    try res.json(try store.put(id, in));
}

fn remove(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    const gone = store.users.fetchOrderedRemove(try userId(req)) orelse return error.NotFound;
    store.free(gone.value);
    res.status = .no_content;
}

/// The SHA-256 of an API key, which is what `Store` keeps.
pub fn keyDigest(key: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &d, .{});
    return d;
}

/// Middleware as a function: answer (or return an error), or go on with
/// `next.call()`. Digests of the same length compared in constant time:
/// how long the check takes says nothing about the key.
fn requireKey(store: *Store, req: *anole.Request, res: *anole.Response, next: anole.Next) !void {
    const key = req.headers.get("X-Api-Key") orelse return error.Unauthorized;
    if (!std.crypto.timing_safe.eql([32]u8, keyDigest(key), store.api_key_digest)) return res.fail(.forbidden, "wrong API key");
    return next.call();
}

/// Apart from `main` so that tests/rest_test.zig can serve the same routes.
pub fn routes(app: *anole.Server(Store)) void {
    const api = app.group("/api", .{requireKey});
    api.get("/users", list);
    api.get("/users/:id", get);
    api.post("/users", create);
    api.put("/users/:id", update);
    api.delete("/users/:id", remove);
}

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("API_KEY") orelse {
        std.log.err("set API_KEY (for example: export API_KEY=$(openssl rand -base64 32))", .{});
        return error.NoApiKey;
    };
    if (api_key.len < 16) {
        std.log.err("API_KEY is too short to be a secret: use 16 random characters or more", .{});
        return error.WeakApiKey;
    }
    var store: Store = .{ .gpa = init.gpa, .api_key_digest = keyDigest(api_key) };
    defer store.deinit();
    // Error answers as {"error":"..."}; error.NotFound is a 404, and so on.
    var app = try anole.Server(Store).init(init.gpa, .{ .errors = .json }, &store);
    defer app.deinit();
    app.use(anole.middleware.RequestId.init(.{})); // X-Request-Id
    app.use(anole.observe.AccessLog.init(.{})); // a line per request on stderr
    app.use(anole.middleware.Cors.init(.{})); // any origin, preflights answered
    routes(&app);
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    try app.listen(args.next() orelse ":3000");
}
