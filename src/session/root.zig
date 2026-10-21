//! Sessions: `req.session` (dusty's SessionData) loaded before the handler
//! and saved after it, either
//!
//! - server-side, in a `Store` (`MemoryStore`, `RedisStore`), the cookie
//!   carrying only a random session id; or
//! - in the cookie itself, encrypted and authenticated with
//!   XChaCha20-Poly1305 (no store).
//!
//!     var sessions = anole.session.Middleware.init(.{ .key = key });            // cookie
//!     var sessions = anole.session.Middleware.init(.{ .key = key, .store = mem.store() });
//!     app.use(sessions);
//!     // in a handler: try req.session.set("user", "42"); req.session.get("user")
//!     // at sign-in:   try anole.session.regenerate(req);  (a new session id)
//!
//! The cookie encryption follows jetzig's src/jetzig/http/Session.zig (MIT,
//! Copyright 2023-2024 Robert Farrell; nonce, ciphertext and tag in that
//! order), with the cookie name as associated data and the expiry inside
//! the sealed payload.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");
const redis = if (features.redis) @import("../redis/root.zig") else struct {};
const db = @import("../db/root.zig");

const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const base64url = std.base64.url_safe_no_pad;
const log = std.log.scoped(.anole_session);

pub const key_length = Cipher.key_length;

/// Where server-side sessions live.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The session's serialized data, copied into `arena`; null when
        /// there is none (or it expired).
        load: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!?[]const u8,
        save: *const fn (ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!void,
        destroy: *const fn (ptr: *anyopaque, id: []const u8) anyerror!void,
    };

    pub fn load(s: Store, arena: std.mem.Allocator, id: []const u8) !?[]const u8 {
        return s.vtable.load(s.ptr, arena, id);
    }
    pub fn save(s: Store, id: []const u8, data: []const u8, ttl_seconds: u32) !void {
        return s.vtable.save(s.ptr, id, data, ttl_seconds);
    }
    pub fn destroy(s: Store, id: []const u8) !void {
        return s.vtable.destroy(s.ptr, id);
    }
};

/// Sessions in this process's memory: for a single node, and tests.
pub const MemoryStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { data: []u8, expires: i64 };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) MemoryStore {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.data);
        }
        self.entries.deinit(self.gpa);
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .destroy = destroy } };
    }

    fn now(self: *MemoryStore) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    fn load(ptr: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!?[]const u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = self.entries.get(id) orelse return null;
        if (e.expires <= self.now()) {
            removeLocked(self, id);
            return null;
        }
        return try arena.dupe(u8, e.data);
    }

    fn save(ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const copy = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(copy);
        const gop = try self.entries.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.data);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, id) catch |err| {
                self.entries.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = .{ .data = copy, .expires = self.now() + ttl_seconds };
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        removeLocked(self, id);
    }

    fn removeLocked(self: *MemoryStore, id: []const u8) void {
        const kv = self.entries.fetchRemove(id) orelse return;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value.data);
    }
};

/// Sessions in Redis/Valkey (-Dredis), keys `prefix ++ id` with the
/// session's TTL, on the client's pools (`app.redis`).
pub const RedisStore = if (features.redis) struct {
    client: *redis.Client,
    prefix: []const u8 = "anole:session:",
    gpa: std.mem.Allocator,

    pub fn store(self: *@This()) Store {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .destroy = destroy } };
    }

    fn key(self: *@This(), buf: []u8, id: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ self.prefix, id });
    }

    fn load(ptr: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var buf: [256]u8 = undefined;
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena };
        return self.client.get(&c, try self.key(&buf, id));
    }

    fn save(ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var buf: [256]u8 = undefined;
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena.allocator() };
        _ = try self.client.set(&c, try self.key(&buf, id), data, .{ .ttl = .fromSeconds(ttl_seconds) });
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var buf: [256]u8 = undefined;
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena.allocator() };
        _ = try self.client.del(&c, try self.key(&buf, id));
    }
} else struct {};

pub const Config = struct {
    /// Server-side store; null keeps the session in an encrypted cookie.
    store: ?Store = null,
    /// The cookie encryption key (cookie mode). Random, secret, and the
    /// same on every node.
    key: [key_length]u8 = @splat(0),
    cookie_name: []const u8 = "anole_session",
    /// How long a session lives without being touched; each response that
    /// carries it renews it.
    ttl_seconds: u32 = 24 * 3600,
    cookie_opts: dusty.CookieOpts = .{ .path = "/", .http_only = true, .secure = true, .same_site = .lax },
};

/// The session entry `regenerate` leaves for the middleware. Never stored:
/// the save path takes it out first.
pub const regenerate_key = "_anole_regenerate";

/// Asks the session middleware to issue a new session id when it saves
/// this response: call it when someone signs in (or their privileges
/// change), against session fixation. With a store, the old id is
/// destroyed there and the data saved under a fresh one, with a new
/// cookie. A sealed cookie has no id, and is re-sealed (a new nonce) as on
/// every save; an earlier copy of it stays valid until it expires, but
/// holds only what the session held before.
///
/// It takes one of the session's 16 entries until the response is saved.
pub fn regenerate(req: *dusty.Request) error{ SessionFull, InvalidSessionData }!void {
    try req.session.set(regenerate_key, "1");
}

/// The session middleware: `app.use(anole.session.Middleware.init(config))`.
pub const Middleware = struct {
    config: Config,

    pub fn init(config: Config) Middleware {
        return .{ .config = config };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        var id: ?[]const u8 = null;
        if (req.cookies().get(self.config.cookie_name)) |raw| {
            self.load(req, raw, &id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A bad or stale cookie is no session.
                else => |e| log.debug("session not loaded: {t}", .{e}),
            };
        }

        try executor.next();

        if (!req.session.modified and req.session.len == 0) return;
        const fresh = req.session.get(regenerate_key) != null;
        if (fresh) req.session.remove(regenerate_key);
        self.save(req, res, id, fresh) catch |err| switch (err) {
            // The handler streamed its response: the cookie cannot go out.
            error.HeadersAlreadySent => log.debug("session cookie not set: response already started", .{}),
            else => |e| return e,
        };
    }

    fn load(self: *const Middleware, req: *dusty.Request, raw: []const u8, id: *?[]const u8) !void {
        if (self.config.store) |store| {
            if (raw.len != 22) return error.InvalidSessionId;
            const data = (try store.load(req.arena, raw)) orelse return;
            id.* = raw;
            try deserialize(&req.session, data);
        } else {
            const sealed = try decodeBase64(req.arena, raw);
            const plain = try open(req.arena, self.config.key, self.config.cookie_name, sealed);
            if (plain.len < 8) return error.InvalidSession;
            const expires = std.mem.readInt(i64, plain[0..8], .little);
            if (expires <= std.Io.Clock.real.now(req.io).toSeconds()) return error.SessionExpired;
            try deserialize(&req.session, plain[8..]);
        }
        req.session.modified = false;
    }

    /// `fresh`: `regenerate` was called, so a stored session moves to a
    /// new id (the old one destroyed first, so it is never left valid).
    fn save(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, id: ?[]const u8, fresh: bool) !void {
        if (req.session.len == 0) {
            // Cleared: forget it, here and in the browser.
            if (self.config.store) |store| if (id) |i| try store.destroy(i);
            var opts = self.config.cookie_opts;
            opts.max_age = .zero;
            return res.setCookie(self.config.cookie_name, "", opts);
        }
        const data = try serialize(req.arena, &req.session);
        var opts = self.config.cookie_opts;
        opts.max_age = .fromSeconds(self.config.ttl_seconds);
        if (self.config.store) |store| {
            if (fresh) if (id) |old| try store.destroy(old);
            const session_id = if (fresh) try newId(req.arena, req.io) else id orelse try newId(req.arena, req.io);
            try store.save(session_id, data, self.config.ttl_seconds);
            return res.setCookie(self.config.cookie_name, session_id, opts);
        }
        const plain = try req.arena.alloc(u8, 8 + data.len);
        std.mem.writeInt(i64, plain[0..8], std.Io.Clock.real.now(req.io).toSeconds() + self.config.ttl_seconds, .little);
        @memcpy(plain[8..], data);
        const sealed = try seal(req.arena, req.io, self.config.key, self.config.cookie_name, plain);
        const encoded = try req.arena.alloc(u8, base64url.Encoder.calcSize(sealed.len));
        return res.setCookie(self.config.cookie_name, base64url.Encoder.encode(encoded, sealed), opts);
    }
};

/// 128 random bits, base64url (22 characters).
fn newId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const out = try arena.alloc(u8, base64url.Encoder.calcSize(bytes.len));
    return base64url.Encoder.encode(out, &bytes);
}

fn decodeBase64(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = base64url.Decoder.calcSizeForSlice(text) catch return error.InvalidEncoding;
    const out = try arena.alloc(u8, len);
    base64url.Decoder.decode(out, text) catch return error.InvalidEncoding;
    return out;
}

/// nonce ++ ciphertext ++ tag (jetzig's layout), the cookie name as
/// associated data.
fn seal(arena: std.mem.Allocator, io: std.Io, key: [key_length]u8, name: []const u8, plain: []const u8) ![]u8 {
    const out = try arena.alloc(u8, Cipher.nonce_length + plain.len + Cipher.tag_length);
    const nonce = out[0..Cipher.nonce_length];
    io.random(nonce);
    var tag: [Cipher.tag_length]u8 = undefined;
    Cipher.encrypt(out[Cipher.nonce_length..][0..plain.len], &tag, plain, name, nonce.*, key);
    @memcpy(out[out.len - Cipher.tag_length ..], &tag);
    return out;
}

fn open(arena: std.mem.Allocator, key: [key_length]u8, name: []const u8, sealed: []const u8) ![]u8 {
    if (sealed.len < Cipher.nonce_length + Cipher.tag_length) return error.InvalidSession;
    const plain = try arena.alloc(u8, sealed.len - Cipher.nonce_length - Cipher.tag_length);
    const tag = sealed[sealed.len - Cipher.tag_length ..][0..Cipher.tag_length].*;
    Cipher.decrypt(plain, sealed[Cipher.nonce_length .. sealed.len - Cipher.tag_length], tag, name, sealed[0..Cipher.nonce_length].*, key) catch return error.InvalidSession;
    return plain;
}

/// key\0value\0... (keys and values carry no NUL; SessionData checks).
fn serialize(arena: std.mem.Allocator, session: *const dusty.SessionData) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (session.items()) |e| {
        try out.appendSlice(arena, e.key);
        try out.append(arena, 0);
        try out.appendSlice(arena, e.value);
        try out.append(arena, 0);
    }
    return out.items;
}

fn deserialize(session: *dusty.SessionData, data: []const u8) !void {
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |k| {
        if (k.len == 0 and it.peek() == null) break;
        const v = it.next() orelse return error.InvalidSession;
        try session.set(k, v);
    }
}

test "seal/open: round trip, wrong key, and a cookie name it was not sealed for" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const key: [key_length]u8 = @splat(7);
    const sealed = try seal(arena, io, key, "s", "secret data");
    try std.testing.expectEqualStrings("secret data", try open(arena, key, "s", sealed));
    try std.testing.expectError(error.InvalidSession, open(arena, @splat(8), "s", sealed));
    try std.testing.expectError(error.InvalidSession, open(arena, key, "other", sealed));
}

test {
    _ = @import("session_test.zig");
}

test "fuzz: forged session cookies never open" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const key: [key_length]u8 = @splat(7);
            const raw = decodeBase64(arena, input) catch input;
            if (open(arena, key, "sid", raw)) |_| return error.ForgedCookieOpened else |_| {}
        }
    }.check, &.{ "", "AAAA", &@as([80]u8, @splat('A')), &@as([40]u8, @splat(0)) });
}
