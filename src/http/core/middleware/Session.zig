// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Sessions in a cookie: `req.session` is loaded from it before the
//! handler and saved to it after, when changed. The cookie is signed with
//! HMAC-SHA256, so a client cannot forge or alter it, but not encrypted, so
//! it can read it: keep secrets out, or use `anole.session` (encrypted
//! cookies, or server-side stores).
//!
//!     app.use(try anole.http.middleware.Session.init(.{ .secret_key = key }));
//!     ...
//!     try req.session.set("user", user_id);

const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const SessionCookieOpts = @import("../cookie.zig").SessionCookieOpts;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64url = std.base64.url_safe_no_pad;
const log = std.log.scoped(.anole);

/// The most keys a session holds.
pub const max_entries = 16;

/// A request's session values (`req.session`): a few string pairs, kept in
/// a signed cookie between requests.
pub const SessionData = struct {
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    /// Set by `set`, `remove` and `clear`: the cookie is sent again.
    modified: bool = false,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// The value under `key`, or null.
    pub fn get(self: *const SessionData, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    /// Sets `key` to `value`, both kept by reference (use the request's
    /// arena or literals). Fails with `error.SessionFull` past
    /// `max_entries` keys, and `error.InvalidSessionData` for a zero byte.
    pub fn set(self: *SessionData, key: []const u8, value: []const u8) error{ SessionFull, InvalidSessionData }!void {
        if (std.mem.indexOfScalar(u8, key, 0) != null or
            std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSessionData;
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                self.modified = true;
                return;
            }
        }
        if (self.len >= max_entries) return error.SessionFull;
        self.entries[self.len] = .{ .key = key, .value = value };
        self.len += 1;
        self.modified = true;
    }

    /// Removes `key`, if present.
    pub fn remove(self: *SessionData, key: []const u8) void {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (std.mem.eql(u8, entry.key, key)) {
                self.entries[i] = self.entries[self.len - 1];
                self.len -= 1;
                self.modified = true;
                return;
            }
        }
    }

    /// Removes every key (log out).
    pub fn clear(self: *SessionData) void {
        self.len = 0;
        self.modified = true;
    }

    /// Every key and value.
    pub fn items(self: *const SessionData) []const Entry {
        return self.entries[0..self.len];
    }
};

/// `Session.init`'s settings.
pub const Config = struct {
    /// The HMAC-SHA256 key the cookie is signed with: at least 32 random
    /// bytes from your secret store. `init` refuses a shorter one, or one
    /// of zeros, with `error.WeakSessionKey`.
    secret_key: []const u8,
    /// Also signed into the cookie: a cookie signed under one name is no
    /// session under another.
    cookie_name: []const u8 = "session",
    /// How long the cookie lasts, renewed on every response while the
    /// session has data; null for a browser-session cookie. It is also the
    /// expiry signed into the cookie.
    max_age: ?std.Io.Duration = null,
    /// With `max_age` null: how long a signed cookie is honoured after it
    /// was last signed, whatever the browser keeps. Renewed while the
    /// session is in use (once half of it has passed), so an idle or
    /// copied cookie stops working. 24 hours by default.
    lifetime: std.Io.Duration = .fromSeconds(24 * 3600),
    /// Path "/", HttpOnly, Secure and SameSite=Lax by default, each kept
    /// unless set here (`.{ .same_site = .none }` changes only that one).
    cookie_opts: SessionCookieOpts = .{},
};

config: Config,

const Session = @This();

/// The middleware: `app.use(try anole.http.middleware.Session.init(.{ .secret_key = key }))`.
/// Fails with `error.WeakSessionKey` (and logs it) when the key is shorter
/// than 32 bytes or all zeros: such cookies could be forged.
pub fn init(config: Config) error{WeakSessionKey}!Session {
    if (!strongKey(config.secret_key)) {
        log.err("session: secret_key must be at least 32 random bytes from your secret store, not shorter and not all zeros", .{});
        return error.WeakSessionKey;
    }
    return .{ .config = config };
}

fn strongKey(key: []const u8) bool {
    return key.len >= 32 and !std.mem.allEqual(u8, key, 0);
}

test "init: a key shorter than 32 bytes, or of zeros, is refused" {
    try std.testing.expect(!strongKey(""));
    try std.testing.expect(!strongKey("short-key"));
    try std.testing.expect(!strongKey(&@as([32]u8, @splat(0))));
    try std.testing.expect(strongKey("test-secret-key-that-is-long-enough"));
    _ = try init(.{ .secret_key = "test-secret-key-that-is-long-enough" });
}

pub fn execute(self: *const Session, req: *Request, res: *Response, executor: anytype) !void {
    const cookie_value = req.cookies().get(self.config.cookie_name);
    // When the loaded cookie stops being honoured; 0 for none loaded.
    var expires_at: u32 = 0;
    if (cookie_value) |raw| {
        expires_at = self.loadExpiry(req.arena, &req.session, raw, req.io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| blk: {
                log.debug("session load failed: {}", .{e});
                break :blk 0;
            },
        };
    }

    try executor.next();

    // Re-sign if modified, or the session has data and its expiry should
    // slide: on every response with max_age (the cookie's Max-Age is
    // renewed too), else once half the lifetime has passed.
    const should_set = req.session.modified or (req.session.len > 0 and
        (self.config.max_age != null or self.needsRenewal(expires_at, unixSeconds(req.io))));

    if (should_set) {
        const result = if (req.session.len == 0) blk: {
            // Session was cleared — delete the cookie
            break :blk res.setCookie(self.config.cookie_name, "", self.config.cookie_opts.withMaxAge(.zero));
        } else blk: {
            const signed = try self.signSession(req.arena, &req.session, .now(req.io, .real));
            break :blk res.setCookie(self.config.cookie_name, signed, self.config.cookie_opts.withMaxAge(self.config.max_age));
        };
        result catch |err| switch (err) {
            // The handler streamed its response, so the headers left before
            // we got here and the cookie cannot be refreshed. That is the
            // handler's choice to make, not a failure of the request.
            error.HeadersAlreadySent => log.debug("session cookie not set: response already started", .{}),
            else => |e| return e,
        };
    }
}

/// Version 2 signs the cookie's name and always carries an expiry;
/// version 1 cookies (unbound to a name, possibly without an expiry) are
/// refused.
const Header = packed struct(u64) {
    version: u8 = 2,
    _reserved: u24 = 0,
    expires_at: u32 = 0,
};

fn unixSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// Whether a cookie expiring at `expires_at` has less than half of
/// `lifetime` left at `now`.
fn needsRenewal(self: *const Session, expires_at: u32, now: i64) bool {
    const half = @divTrunc(self.config.lifetime.toSeconds(), 2);
    return @as(i64, expires_at) - now < half;
}

/// The MAC over a cookie: the name (so it does not verify under another),
/// the header and the payload.
fn mac(self: *const Session, header: []const u8, payload: []const u8, out: *[sig_size]u8) void {
    var h = HmacSha256.init(self.config.secret_key);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(self.config.cookie_name.len), .little);
    h.update(&len);
    h.update(self.config.cookie_name);
    h.update(header);
    h.update(payload);
    h.final(out);
}

const header_size = @sizeOf(Header);
const sig_size = HmacSha256.mac_length;
const overhead = header_size + sig_size;

/// Load a signed cookie value into a SessionData.
fn load(self: *const Session, arena: std.mem.Allocator, session: *SessionData, raw: []const u8, io: std.Io) !void {
    _ = try self.loadExpiry(arena, session, raw, io);
}

/// Load a signed cookie value into a SessionData, and return its expiry.
/// Decodes the base64, verifies HMAC, then parses entries.
/// Format: base64url([Header: 8 bytes][signature: 32 bytes][key\0value\0...])
fn loadExpiry(self: *const Session, arena: std.mem.Allocator, session: *SessionData, raw: []const u8, io: std.Io) !u32 {
    const decoded_len = base64url.Decoder.calcSizeForSlice(raw) catch return error.InvalidEncoding;
    if (decoded_len < overhead) return error.InvalidEncoding;
    const decoded = try arena.alloc(u8, decoded_len);
    base64url.Decoder.decode(decoded, raw) catch return error.InvalidEncoding;

    // Read and check header
    const header: Header = @bitCast(std.mem.readInt(u64, decoded[0..header_size], .little));
    if (header.version != 2) return error.UnsupportedVersion;

    // Verify signature (covers the name, header and payload)
    const sig = decoded[header_size..][0..sig_size];
    const payload = decoded[overhead..];

    var expected: [sig_size]u8 = undefined;
    self.mac(decoded[0..header_size], payload, &expected);
    if (!std.crypto.timing_safe.eql([sig_size]u8, sig.*, expected)) return error.InvalidSignature;

    // Check expiry: every cookie has one.
    if (@as(i64, header.expires_at) < unixSeconds(io)) return error.Expired;

    // Parse null-separated key\0value pairs
    var it = std.mem.splitScalar(u8, payload, 0);
    while (session.len < max_entries) {
        const key = it.next() orelse break;
        const val = it.next() orelse break;
        session.entries[session.len] = .{ .key = key, .value = val };
        session.len += 1;
    }
    return header.expires_at;
}

/// Serialize session entries, sign, and base64-encode.
/// Format: base64url([Header: 8 bytes][signature: 32 bytes][key\0value\0...])
fn signSession(self: *const Session, arena: std.mem.Allocator, session: *const SessionData, now: std.Io.Timestamp) ![]const u8 {
    // Calculate payload size
    var payload_size: usize = 0;
    for (session.items()) |entry| {
        payload_size += entry.key.len + 1 + entry.value.len + 1;
    }

    // Build raw buffer: [header][signature][payload]
    const raw = try arena.alloc(u8, overhead + payload_size);

    // Write header: the expiry is max_age's, else the lifetime's.
    const expires_ns = now.addDuration(self.config.max_age orelse self.config.lifetime).nanoseconds;
    const expires_s: i64 = @intCast(@divTrunc(expires_ns, std.time.ns_per_s));
    const expires_at: u32 = @intCast(std.math.clamp(expires_s, 0, std.math.maxInt(u32)));

    const header = Header{ .expires_at = expires_at };
    std.mem.writeInt(u64, raw[0..header_size], @bitCast(header), .little);

    // Write payload
    var pos: usize = overhead;
    for (session.items()) |entry| {
        @memcpy(raw[pos..][0..entry.key.len], entry.key);
        pos += entry.key.len;
        raw[pos] = 0;
        pos += 1;
        @memcpy(raw[pos..][0..entry.value.len], entry.value);
        pos += entry.value.len;
        raw[pos] = 0;
        pos += 1;
    }

    // Sign the name, header and payload
    self.mac(raw[0..header_size], raw[overhead..], raw[header_size..][0..sig_size]);

    // Base64-encode
    const enc_len = base64url.Encoder.calcSize(raw.len);
    const buf = try arena.alloc(u8, enc_len);
    return base64url.Encoder.encode(buf, raw);
}

// Tests

const testing = std.testing;

test "SessionData: get and set" {
    var s = SessionData{};
    try s.set("user_id", "42");
    try s.set("name", "alice");

    try testing.expectEqualStrings("42", s.get("user_id").?);
    try testing.expectEqualStrings("alice", s.get("name").?);
    try testing.expect(s.get("missing") == null);
    try testing.expect(s.modified);
}

test "SessionData: set overwrites existing key" {
    var s = SessionData{};
    try s.set("key", "old");
    try s.set("key", "new");

    try testing.expectEqualStrings("new", s.get("key").?);
    try testing.expectEqual(1, s.len);
}

test "SessionData: remove" {
    var s = SessionData{};
    try s.set("a", "1");
    try s.set("b", "2");
    try s.set("c", "3");

    s.modified = false;
    s.remove("b");

    try testing.expect(s.modified);
    try testing.expectEqual(2, s.len);
    try testing.expectEqualStrings("1", s.get("a").?);
    try testing.expectEqualStrings("3", s.get("c").?);
    try testing.expect(s.get("b") == null);
}

test "SessionData: remove nonexistent is no-op" {
    var s = SessionData{};
    try s.set("a", "1");
    s.modified = false;

    s.remove("missing");
    try testing.expect(!s.modified);
    try testing.expectEqual(1, s.len);
}

test "SessionData: full capacity" {
    const keys = [max_entries][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p" };
    var s = SessionData{};
    for (keys) |key| {
        try s.set(key, "v");
    }
    try testing.expectEqual(max_entries, s.len);
    try testing.expectError(error.SessionFull, s.set("overflow", "x"));
}

test "Session: sign and load round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
    } };

    var s = SessionData{};
    try s.set("user_id", "42");
    try s.set("role", "admin");

    const signed = try session.signSession(arena.allocator(), &s, .now(std.testing.io, .real));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed, std.testing.io);

    try testing.expectEqualStrings("42", s2.get("user_id").?);
    try testing.expectEqualStrings("admin", s2.get("role").?);
    try testing.expect(!s2.modified);
}

test "Session: sign and load round-trip with max_age" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
        .max_age = .fromSeconds(3600),
    } };

    var s = SessionData{};
    try s.set("user_id", "42");

    const signed = try session.signSession(arena.allocator(), &s, .now(std.testing.io, .real));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed, std.testing.io);

    try testing.expectEqualStrings("42", s2.get("user_id").?);
}

test "Session: load rejects expired session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
        .max_age = .fromSeconds(3600),
    } };

    var s = SessionData{};
    try s.set("user_id", "42");

    // Sign with a timestamp far in the past so expires_at is already passed
    const signed = try session.signSession(arena.allocator(), &s, .fromNanoseconds(1000 * 1_000_000_000));

    var s2 = SessionData{};
    try testing.expectError(error.Expired, session.load(arena.allocator(), &s2, signed, std.testing.io));
}

test "Session: load rejects tampered payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{
        .secret_key = "test-secret-key-that-is-long-enough",
        .cookie_name = "session",
    } };

    var s = SessionData{};
    try s.set("user_id", "42");
    const signed = try session.signSession(arena.allocator(), &s, .now(std.testing.io, .real));

    var tampered = try arena.allocator().dupe(u8, signed);
    // Tamper near the end (payload region) to avoid corrupting the header/version
    const idx = tampered.len - 1;
    tampered[idx] = if (tampered[idx] == 'A') 'B' else 'A';

    var s2 = SessionData{};
    try testing.expectError(error.InvalidSignature, session.load(arena.allocator(), &s2, tampered, std.testing.io));
}

test "Session: load rejects wrong key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session1 = Session{ .config = .{ .secret_key = "key-one", .cookie_name = "s" } };
    const session2 = Session{ .config = .{ .secret_key = "key-two", .cookie_name = "s" } };

    var s = SessionData{};
    try s.set("data", "test");
    const signed = try session1.signSession(arena.allocator(), &s, .now(std.testing.io, .real));

    var s2 = SessionData{};
    try testing.expectError(error.InvalidSignature, session2.load(arena.allocator(), &s2, signed, std.testing.io));
}

test "Session: load rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{ .secret_key = "key", .cookie_name = "s" } };

    var s = SessionData{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, "", std.testing.io));

    s = .{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, "!!!invalid-base64!!!", std.testing.io));

    s = .{};
    try testing.expectError(error.InvalidEncoding, session.load(arena.allocator(), &s, "AAAA", std.testing.io));
}

test "Session: empty session round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const session = Session{ .config = .{ .secret_key = "key", .cookie_name = "s" } };

    var s = SessionData{};
    const signed = try session.signSession(arena.allocator(), &s, .now(std.testing.io, .real));

    var s2 = SessionData{};
    try session.load(arena.allocator(), &s2, signed, std.testing.io);
    try testing.expectEqual(0, s2.len);
}

test "SessionData: set rejects null bytes in key" {
    var s = SessionData{};
    try testing.expectError(error.InvalidSessionData, s.set("bad\x00key", "value"));
    try testing.expectEqual(0, s.len);
}

test "SessionData: set rejects null bytes in value" {
    var s = SessionData{};
    try testing.expectError(error.InvalidSessionData, s.set("key", "bad\x00value"));
    try testing.expectEqual(0, s.len);
}

test "SessionData: clear" {
    var s = SessionData{};
    try s.set("a", "1");
    try s.set("b", "2");
    s.modified = false;

    s.clear();
    try testing.expect(s.modified);
    try testing.expectEqual(0, s.len);
    try testing.expect(s.get("a") == null);
}

test "Config: setting one cookie_opts field keeps the secure defaults of the others" {
    const session = try init(.{ .secret_key = "test-secret-key-that-is-long-enough", .cookie_opts = .{ .same_site = .none } });
    try testing.expect(session.config.cookie_opts.http_only);
    try testing.expect(session.config.cookie_opts.secure);
    try testing.expectEqualStrings("/", session.config.cookie_opts.path);
}

test "Session: a cookie signed for one name does not load under another" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const key = "test-secret-key-that-is-long-enough";
    const a = Session{ .config = .{ .secret_key = key, .cookie_name = "a_session" } };
    const b = Session{ .config = .{ .secret_key = key, .cookie_name = "b_session" } };
    var s = SessionData{};
    try s.set("user_id", "42");
    const signed = try a.signSession(arena.allocator(), &s, .now(std.testing.io, .real));
    var s2 = SessionData{};
    try testing.expectError(error.InvalidSignature, b.load(arena.allocator(), &s2, signed, std.testing.io));
}

test "Session: without max_age a signed cookie still expires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const session = Session{ .config = .{ .secret_key = "test-secret-key-that-is-long-enough" } };
    var s = SessionData{};
    try s.set("user_id", "42");
    // Signed in 1970: long expired, whatever the cookie's own lifetime.
    const signed = try session.signSession(arena.allocator(), &s, .fromNanoseconds(1000 * std.time.ns_per_s));
    var s2 = SessionData{};
    try testing.expectError(error.Expired, session.load(arena.allocator(), &s2, signed, std.testing.io));
}

test "Session: an unchanged session is signed again once half its lifetime has passed" {
    const session = Session{ .config = .{ .secret_key = "test-secret-key-that-is-long-enough", .lifetime = .fromSeconds(100) } };
    try testing.expect(!session.needsRenewal(1_000_100, 1_000_000));
    try testing.expect(!session.needsRenewal(1_000_100, 1_000_049));
    try testing.expect(session.needsRenewal(1_000_100, 1_000_051));
    // Nothing loaded: a session made now is signed when it gets data.
    try testing.expect(session.needsRenewal(0, 1_000_000));
}
