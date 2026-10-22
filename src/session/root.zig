//! Sessions: `req.session` (a `SessionData`, up to 16 entries) loaded before the handler
//! and saved after it, either
//!
//! - server-side, in a `Store` (`MemoryStore`, `RedisStore`), the cookie
//!   carrying only a random session id; or
//! - in the cookie itself, encrypted and authenticated with
//!   XChaCha20-Poly1305 (no store).
//!
//!     app.use(try anole.session.Middleware.init(.{ .key = key }));         // cookie
//!     app.use(try anole.session.Middleware.init(.{ .store = mem.store() })); // store
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

/// The session cookie's attributes (`Config.cookie_opts`), with secure
/// defaults for every field.
pub const CookieOpts = dusty.SessionCookieOpts;

/// The cookie encryption key's length in bytes (32), for `Config.key`.
pub const key_length = Cipher.key_length;

/// Where server-side sessions live.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// What a store implements. `update` and `touch` must not bring back a
    /// session that is gone: a request still running when the session was
    /// destroyed (a logout, `regenerate`) ends with one of them. A store
    /// without them gets `load` followed by `save`, which leaves a short
    /// window for that.
    pub const VTable = struct {
        /// The session's serialized data, copied into `arena`; null when
        /// there is none (or it expired).
        load: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!?[]const u8,
        /// Stores `data` under `id` for `ttl_seconds`, replacing what was there.
        save: *const fn (ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!void,
        /// Removes the session `id`; one that is not there is no error.
        destroy: *const fn (ptr: *anyopaque, id: []const u8) anyerror!void,
        /// Replaces the data under `id`, for `ttl_seconds`, only if it is
        /// still there (Redis `SET ... XX`); false when it is not.
        update: ?*const fn (ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!bool = null,
        /// Renews `id` for `ttl_seconds` without rewriting it, only if it
        /// is still there (Redis `EXPIRE`); false when it is not.
        touch: ?*const fn (ptr: *anyopaque, id: []const u8, ttl_seconds: u32) anyerror!bool = null,
    };

    /// The data stored under `id`, copied into `arena`, or null.
    pub fn load(s: Store, arena: std.mem.Allocator, id: []const u8) !?[]const u8 {
        return s.vtable.load(s.ptr, arena, id);
    }
    /// Stores `data` under `id` for `ttl_seconds`.
    pub fn save(s: Store, id: []const u8, data: []const u8, ttl_seconds: u32) !void {
        return s.vtable.save(s.ptr, id, data, ttl_seconds);
    }
    /// Removes the session `id`.
    pub fn destroy(s: Store, id: []const u8) !void {
        return s.vtable.destroy(s.ptr, id);
    }
    /// Replaces the data under `id` if it is still there; false when it is
    /// not. `arena` is for a store without `update`.
    pub fn update(s: Store, arena: std.mem.Allocator, id: []const u8, data: []const u8, ttl_seconds: u32) !bool {
        if (s.vtable.update) |f| return f(s.ptr, id, data, ttl_seconds);
        if ((try s.load(arena, id)) == null) return false;
        try s.save(id, data, ttl_seconds);
        return true;
    }
    /// Renews `id` if it is still there; false when it is not. `arena` is
    /// for a store without `touch`.
    pub fn touch(s: Store, arena: std.mem.Allocator, id: []const u8, ttl_seconds: u32) !bool {
        if (s.vtable.touch) |f| return f(s.ptr, id, ttl_seconds);
        const data = (try s.load(arena, id)) orelse return false;
        try s.save(id, data, ttl_seconds);
        return true;
    }
};

/// Sessions in this process's memory: for a single node, and tests.
/// Bounded: expired sessions are swept as new ones are written, and past
/// `max_entries` the one written longest ago goes.
pub const MemoryStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// Most recently written first. The middleware gives every session the
    /// same TTL, so the far end is where they expire first.
    order: std.DoublyLinkedList = .{},
    max_entries: usize,
    /// Whether the "store full" warning was logged already.
    warned_full: bool = false,

    const Entry = struct {
        key: []u8,
        data: []u8,
        expires: i64,
        node: std.DoublyLinkedList.Node = .{},
    };

    /// `initOptions`' settings.
    pub const Options = struct {
        /// Sessions kept at most; past it, the one written longest ago is
        /// dropped (its user is signed out), with a warning in the log.
        max_entries: usize = 100_000,
    };

    /// An empty store with the default `Options`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) MemoryStore {
        return initOptions(gpa, io, .{});
    }

    /// An empty store.
    pub fn initOptions(gpa: std.mem.Allocator, io: std.Io, options: Options) MemoryStore {
        return .{ .gpa = gpa, .io = io, .max_entries = @max(1, options.max_entries) };
    }

    /// Frees every session.
    pub fn deinit(self: *MemoryStore) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| self.freeEntry(e.*);
        self.entries.deinit(self.gpa);
    }

    /// The store interface for `Config.store`; `self` must outlive the
    /// middleware.
    pub fn store(self: *MemoryStore) Store {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .destroy = destroy, .update = update, .touch = touch } };
    }

    /// How many sessions are kept now, expired ones not yet swept included.
    pub fn count(self: *MemoryStore) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.entries.count();
    }

    fn now(self: *MemoryStore) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    fn freeEntry(self: *MemoryStore, e: *Entry) void {
        self.gpa.free(e.key);
        self.gpa.free(e.data);
        self.gpa.destroy(e);
    }

    fn removeLocked(self: *MemoryStore, e: *Entry) void {
        self.order.remove(&e.node);
        _ = self.entries.remove(e.key);
        self.freeEntry(e);
    }

    /// The live entry for `id`; an expired one is removed.
    fn liveLocked(self: *MemoryStore, id: []const u8, t: i64) ?*Entry {
        const e = self.entries.get(id) orelse return null;
        if (e.expires <= t) {
            self.removeLocked(e);
            return null;
        }
        return e;
    }

    /// Drops expired entries from the far end of `order`.
    fn sweepLocked(self: *MemoryStore, t: i64) void {
        while (self.order.last) |n| {
            const e: *Entry = @fieldParentPtr("node", n);
            if (e.expires > t) break;
            self.removeLocked(e);
        }
    }

    /// `e` was just written: to the front, with its new expiry.
    fn renewLocked(self: *MemoryStore, e: *Entry, t: i64, ttl_seconds: u32) void {
        e.expires = t + ttl_seconds;
        self.order.remove(&e.node);
        self.order.prepend(&e.node);
    }

    fn load(ptr: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!?[]const u8 {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = self.liveLocked(id, self.now()) orelse return null;
        return try arena.dupe(u8, e.data);
    }

    fn save(ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.now();
        self.sweepLocked(t);
        const copy = try self.gpa.dupe(u8, data);
        errdefer self.gpa.free(copy);
        if (self.entries.get(id)) |e| {
            self.gpa.free(e.data);
            e.data = copy;
            self.renewLocked(e, t, ttl_seconds);
            return;
        }
        if (self.entries.count() >= self.max_entries) {
            if (!self.warned_full) {
                self.warned_full = true;
                log.warn("anole.session: MemoryStore holds max_entries ({d}) sessions; the oldest are being dropped", .{self.max_entries});
            }
            self.removeLocked(@fieldParentPtr("node", self.order.last.?));
        }
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        const key = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(key);
        e.* = .{ .key = key, .data = copy, .expires = t + ttl_seconds };
        try self.entries.put(self.gpa, key, e);
        self.order.prepend(&e.node);
    }

    fn update(ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!bool {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.now();
        const e = self.liveLocked(id, t) orelse return false;
        const copy = try self.gpa.dupe(u8, data);
        self.gpa.free(e.data);
        e.data = copy;
        self.renewLocked(e, t, ttl_seconds);
        return true;
    }

    fn touch(ptr: *anyopaque, id: []const u8, ttl_seconds: u32) anyerror!bool {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.now();
        const e = self.liveLocked(id, t) orelse return false;
        self.renewLocked(e, t, ttl_seconds);
        return true;
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = self.entries.get(id) orelse return;
        self.removeLocked(e);
    }
};

/// Sessions in Redis/Valkey (-Dredis), keys `prefix ++ id` with the
/// session's TTL, on the client's pools (`app.redis`).
pub const RedisStore = if (features.redis) struct {
    /// The client sessions go through (`app.redis(.{})`).
    client: *redis.Client,
    /// Prepended to each session id to make its key.
    prefix: []const u8 = "anole:session:",
    /// For the scratch memory of a save or destroy.
    gpa: std.mem.Allocator,

    /// The store interface for `Config.store`; `self` must outlive the
    /// middleware.
    pub fn store(self: *@This()) Store {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .destroy = destroy, .update = update, .touch = touch } };
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

    /// SET ... XX: only while the key exists.
    fn update(ptr: *anyopaque, id: []const u8, data: []const u8, ttl_seconds: u32) anyerror!bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var buf: [256]u8 = undefined;
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena.allocator() };
        return self.client.set(&c, try self.key(&buf, id), data, .{ .ttl = .fromSeconds(ttl_seconds), .xx = true });
    }

    /// EXPIRE: false when the key is gone.
    fn touch(ptr: *anyopaque, id: []const u8, ttl_seconds: u32) anyerror!bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var buf: [256]u8 = undefined;
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena.allocator() };
        return self.client.expire(&c, try self.key(&buf, id), .fromSeconds(ttl_seconds));
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

/// `Middleware` settings. Cookie mode (no `store`) needs `key`, and
/// `Middleware.init` refuses to start without one; with `store`, `key` is
/// unused.
pub const Config = struct {
    /// Server-side store; null keeps the session in an encrypted cookie.
    store: ?Store = null,
    /// The cookie encryption key, required in cookie mode: 32 random bytes
    /// from your secret store, the same on every node (`keyFromBase64`
    /// reads one from configuration). There is no default: `init` fails
    /// with `error.SessionKeyMissing` for null or all zeros. For local
    /// development only, `devKey(io)` makes a random one.
    key: ?[key_length]u8 = null,
    /// The cookie's name; also bound into the sealed cookie, so renaming
    /// it ends every cookie-mode session. Over HTTPS, a `__Host-` name
    /// (`__Host-anole_session`) keeps the cookie to this host and path `/`,
    /// so a sibling subdomain cannot set or shadow it; `init` checks that
    /// `cookie_opts` allows it.
    cookie_name: []const u8 = "anole_session",
    /// How long a session lives without being touched; each response that
    /// carries it renews it.
    ttl_seconds: u32 = 24 * 3600,
    /// The cookie's attributes: path `/`, `HttpOnly`, `Secure` and
    /// `SameSite=Lax` by default, each kept unless set here (`.{ .same_site =
    /// .none }` changes only that one). `Max-Age` comes from `ttl_seconds`.
    cookie_opts: CookieOpts = .{},
};

/// The session entry `regenerate` leaves for the middleware. Never stored:
/// the save path takes it out first.
pub const regenerate_key = "_anole_regenerate";

/// Where `anole.auth.csrf` keeps the session's token; `regenerate` drops
/// it, so a token handed out before a sign-in is not valid after.
pub const csrf_key = "_csrf";

/// Asks the session middleware to issue a new session id when it saves
/// this response: call it when someone signs in (or their privileges
/// change), against session fixation. With a store, the old id is
/// destroyed there and the data saved under a fresh one, with a new
/// cookie. A sealed cookie has no id, and is re-sealed (a new nonce) as on
/// every save; an earlier copy of it stays valid until it expires, but
/// holds only what the session held before.
///
/// It also drops the session's CSRF token (`anole.auth.csrf`): the next
/// `csrf.token(req)`, in this request or a later one, makes a new one.
///
/// It takes one of the session's 16 entries until the response is saved.
pub fn regenerate(req: *dusty.Request) error{ SessionFull, InvalidSessionData }!void {
    req.session.remove(csrf_key);
    try req.session.set(regenerate_key, "1");
}

/// What `Middleware.init` refuses: cookie mode without a usable key, and
/// a cookie name whose prefix `cookie_opts` does not satisfy.
pub const ConfigError = error{
    /// Cookie mode (no `Config.store`) with `Config.key` null or all
    /// zeros: such cookies could be forged and read by anyone.
    SessionKeyMissing,
    /// A `__Host-` name without `Secure`, `Path=/` and no `Domain`, or a
    /// `__Secure-` one without `Secure`: browsers would drop the cookie.
    CookiePrefixMismatch,
};

/// The session middleware: `app.use(try anole.session.Middleware.init(config))`.
pub const Middleware = struct {
    config: Config,
    /// The cookie key, checked by `init` (cookie mode only).
    key: [key_length]u8,

    /// The middleware for `config`. Before the handler it loads
    /// `req.session` from the cookie (a missing, expired or forged one
    /// leaves it empty); after, it saves the session when it changed,
    /// renews it when it holds anything, and clears the cookie when it was
    /// emptied. With a store, a session destroyed while the request ran
    /// (a logout elsewhere) stays destroyed.
    ///
    /// In cookie mode it fails with `error.SessionKeyMissing` (and logs
    /// how to fix it) when `config.key` is null or all zeros. It fails with
    /// `error.CookiePrefixMismatch` for a `__Host-`/`__Secure-` name that
    /// `cookie_opts` does not allow.
    pub fn init(config: Config) ConfigError!Middleware {
        config.cookie_opts.checkPrefix(config.cookie_name) catch |err| {
            log.err("anole.session: a __Host- cookie needs Secure, Path=/ and no Domain; a __Secure- one needs Secure", .{});
            return err;
        };
        if (config.store != null) return .{ .config = config, .key = @splat(0) };
        const key = cookieKey(config.key) orelse {
            log.err("anole.session: cookie sessions need Config.key, 32 random bytes (not all zeros) from your secret store and the same on every node " ++
                "(anole.session.keyFromBase64 reads one), or a Config.store; anole.session.devKey(io) makes one for local development", .{});
            return error.SessionKeyMissing;
        };
        return .{ .config = config, .key = key };
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
            const plain = try open(req.arena, self.key, self.config.cookie_name, sealed);
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
            return res.setCookie(self.config.cookie_name, "", self.config.cookie_opts.withMaxAge(.zero));
        }
        const opts = self.config.cookie_opts.withMaxAge(.fromSeconds(self.config.ttl_seconds));
        const ttl = self.config.ttl_seconds;
        if (self.config.store) |store| {
            if (fresh) if (id) |old| try store.destroy(old);
            if (id != null and !fresh) {
                // The session this request loaded, written or renewed only
                // if it still exists: one destroyed meanwhile (a logout, a
                // `regenerate` by another request) stays destroyed, and
                // the browser gets no cookie for it.
                const alive = if (req.session.modified)
                    try store.update(req.arena, id.?, try serialize(req.arena, &req.session), ttl)
                else
                    try store.touch(req.arena, id.?, ttl);
                if (!alive) return;
                return res.setCookie(self.config.cookie_name, id.?, opts);
            }
            // A new id, which only a cookie can hand out: none is stored
            // once the response has started.
            if (res.headers_written) return error.HeadersAlreadySent;
            const session_id = try newId(req.arena, req.io);
            try store.save(session_id, try serialize(req.arena, &req.session), ttl);
            return res.setCookie(self.config.cookie_name, session_id, opts);
        }
        const data = try serialize(req.arena, &req.session);
        const plain = try req.arena.alloc(u8, 8 + data.len);
        std.mem.writeInt(i64, plain[0..8], std.Io.Clock.real.now(req.io).toSeconds() + self.config.ttl_seconds, .little);
        @memcpy(plain[8..], data);
        const sealed = try seal(req.arena, req.io, self.key, self.config.cookie_name, plain);
        const encoded = try req.arena.alloc(u8, base64url.Encoder.calcSize(sealed.len));
        return res.setCookie(self.config.cookie_name, base64url.Encoder.encode(encoded, sealed), opts);
    }
};

/// `key` when it can seal cookies: set, and not all zeros.
fn cookieKey(key: ?[key_length]u8) ?[key_length]u8 {
    const k = key orelse return null;
    return if (std.mem.allEqual(u8, &k, 0)) null else k;
}

/// A random cookie key for local development, with a warning in the log:
/// sessions end when the process does, and every node has its own key, so
/// a cookie sealed on one is no session on another. Never in production:
///
///     app.use(try anole.session.Middleware.init(.{ .key = anole.session.devKey(app.io()) }));
pub fn devKey(io: std.Io) [key_length]u8 {
    log.warn("anole.session: using a random development key; sessions end on restart and differ between nodes. Set Config.key from your secret store in production", .{});
    var key: [key_length]u8 = undefined;
    io.random(&key);
    return key;
}

/// A cookie key from configuration: 32 bytes as standard or URL-safe
/// base64, padded or not (`openssl rand -base64 32` makes one). Anything
/// else is `error.InvalidSessionKey`, and so is all zeros:
///
///     const key = try anole.session.keyFromBase64(env.get("SESSION_KEY") orelse return error.NoSessionKey);
pub fn keyFromBase64(text: []const u8) error{InvalidSessionKey}![key_length]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var key: [key_length]u8 = undefined;
    const decoders = [_]std.base64.Base64Decoder{
        std.base64.standard.Decoder,
        std.base64.standard_no_pad.Decoder,
        std.base64.url_safe.Decoder,
        std.base64.url_safe_no_pad.Decoder,
    };
    for (decoders) |d| {
        const len = d.calcSizeForSlice(trimmed) catch continue;
        if (len != key_length) continue;
        d.decode(&key, trimmed) catch continue;
        if (std.mem.allEqual(u8, &key, 0)) return error.InvalidSessionKey;
        return key;
    }
    return error.InvalidSessionKey;
}

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

test "Middleware.init: cookie mode needs a key that is not all zeros" {
    try std.testing.expect(cookieKey(null) == null);
    try std.testing.expect(cookieKey(@splat(0)) == null);
    var almost: [key_length]u8 = @splat(0);
    almost[31] = 1;
    try std.testing.expect(cookieKey(almost) != null);
    // A key is enough for cookie mode, and a store needs none.
    _ = try Middleware.init(.{ .key = almost });
    var mem = MemoryStore.init(std.testing.allocator, std.testing.io);
    defer mem.deinit();
    _ = try Middleware.init(.{ .store = mem.store() });
}

test "keyFromBase64: 32 bytes in any base64 alphabet, nothing else" {
    var raw: [key_length]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @truncate(i * 9 + 250);
    var buf: [64]u8 = undefined;
    for ([_]std.base64.Base64Encoder{ std.base64.standard.Encoder, std.base64.standard_no_pad.Encoder, std.base64.url_safe.Encoder, std.base64.url_safe_no_pad.Encoder }) |e| {
        const text = e.encode(&buf, &raw);
        try std.testing.expectEqualSlices(u8, &raw, &(try keyFromBase64(text)));
    }
    var padded: [70]u8 = undefined;
    const spaced = try std.fmt.bufPrint(&padded, " {s}\n", .{std.base64.standard.Encoder.encode(&buf, &raw)});
    try std.testing.expectEqualSlices(u8, &raw, &(try keyFromBase64(spaced)));
    try std.testing.expectError(error.InvalidSessionKey, keyFromBase64(""));
    try std.testing.expectError(error.InvalidSessionKey, keyFromBase64("c2hvcnQ="));
    try std.testing.expectError(error.InvalidSessionKey, keyFromBase64("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expectError(error.InvalidSessionKey, keyFromBase64("not base64 at all, not base64 at all!!!!!!!"));
}

test "devKey: random, never all zeros in practice, and different each time" {
    // Its warning is expected here.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    const a = devKey(std.testing.io);
    const b = devKey(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(cookieKey(a) != null);
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

test "MemoryStore: capped at max_entries, and update/touch never bring a session back" {
    const level = std.testing.log_level;
    std.testing.log_level = .err; // the "store full" warning is expected
    defer std.testing.log_level = level;
    var mem = MemoryStore.initOptions(std.testing.allocator, std.testing.io, .{ .max_entries = 3 });
    defer mem.deinit();
    const s = mem.store();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try s.save("a", "1", 3600);
    try s.save("b", "1", 3600);
    try s.save("c", "1", 3600);
    try std.testing.expect(try s.touch(arena, "a", 3600)); // a is the most recent now
    try s.save("d", "1", 3600); // b goes
    try std.testing.expectEqual(@as(usize, 3), mem.count());
    try std.testing.expect((try s.load(arena, "b")) == null);
    try std.testing.expect((try s.load(arena, "a")) != null);
    try std.testing.expect(try s.update(arena, "a", "2", 3600));
    try std.testing.expectEqualStrings("2", (try s.load(arena, "a")).?);
    try s.destroy("a");
    try std.testing.expect(!try s.update(arena, "a", "3", 3600));
    try std.testing.expect(!try s.touch(arena, "a", 3600));
    try std.testing.expect((try s.load(arena, "a")) == null);
}

test "regenerate drops the CSRF token, and __Host- names are checked" {
    var req: dusty.Request = .{ .arena = std.testing.allocator, .parser = undefined, .transport = undefined };
    try req.session.set(csrf_key, "old-token");
    try req.session.set("user", "alice");
    try regenerate(&req);
    try std.testing.expect(req.session.get(csrf_key) == null);
    try std.testing.expectEqualStrings("alice", req.session.get("user").?);
    // The defaults allow a __Host- name (the refusals are in cookie.zig's
    // tests, without the error this would log).
    _ = try Middleware.init(.{ .key = @splat(1), .cookie_name = "__Host-anole_session" });
    const opts: CookieOpts = .{ .path = "/app" };
    try std.testing.expectError(error.CookiePrefixMismatch, opts.checkPrefix("__Host-s"));
}

test "Config: setting one cookie_opts field keeps the secure defaults of the others" {
    const mw = try Middleware.init(.{ .key = @splat(1), .cookie_opts = .{ .same_site = .strict } });
    try std.testing.expect(mw.config.cookie_opts.http_only);
    try std.testing.expect(mw.config.cookie_opts.secure);
    try std.testing.expectEqualStrings("/", mw.config.cookie_opts.path);
}

test "MemoryStore: expired sessions are swept as new ones come in" {
    var mem = MemoryStore.init(std.testing.allocator, std.testing.io);
    defer mem.deinit();
    const s = mem.store();
    var buf: [16]u8 = undefined;
    // Each expires at once (a TTL of 0), and none is ever looked up again.
    for (0..500) |i| try s.save(try std.fmt.bufPrint(&buf, "dead{d}", .{i}), "x", 0);
    try s.save("live", "x", 3600);
    try std.testing.expect(mem.entries.count() < 100);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("x", (try s.load(arena_state.allocator(), "live")).?);
}
