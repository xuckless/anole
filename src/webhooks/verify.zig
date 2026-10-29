//! `Verify`: a middleware that checks the signature of an incoming
//! webhook before the handler runs, and drops duplicate deliveries.
//!
//!     const hook = app.webhookVerify(.{ .preset = .stripe, .secrets = &.{secret} });
//!     app.with(.{hook}).post("/hooks/stripe", stripeHook);
//!
//! The signature is over the body as received: the handler reads the same
//! bytes with `req.body()` and parses that, never a re-serialized copy.
//! A missing, malformed or wrong signature, or a timestamp outside
//! `tolerance`, answers 400 with no detail (the reason goes to the log at
//! info: any peer can trigger it). A delivery id seen before answers 200
//! without running the handler (it was processed); one still running
//! answers 409 so the sender retries later. The id is marked after a 2xx
//! and released after anything else, so a failed handler stays retryable.
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const sign = @import("sign.zig");
const dedup = @import("dedup.zig");
const declarations = @import("../openapi/declarations.zig");

const log = std.log.scoped(.anole_webhooks);

const Encoding = enum { hex, base64 };

pub const Verify = struct {
    pub const Preset = enum { standard, stripe, github, slack, hmac };

    pub const Hmac = struct {
        header: []const u8,
        algorithm: enum { sha1, sha256, sha512 } = .sha256,
        encoding: Encoding = .hex,
        /// Stripped from the header value first ("sha256=").
        prefix: []const u8 = "",
        /// A header with the delivery's id, for duplicates; null: none.
        id_header: ?[]const u8 = null,
    };

    pub const Dedup = dedup.Config;

    pub const Options = struct {
        preset: Preset,
        /// One or more (rotation). standard: "whsec_<base64>" (v1) or
        /// "whpk_<base64>" (v1a public key); stripe: the "whsec_..." text as
        /// it is; github, slack, hmac: the shared secret's bytes.
        secrets: []const []const u8,
        /// The timestamp window, both directions (standard, stripe, slack).
        tolerance: anole.Duration = .fromSeconds(300),
        dedup: Dedup = .{ .memory = .{} },
        on_store_error: enum { reject, process } = .reject,
        /// For `.hmac`.
        hmac: ?Hmac = null,
        /// Null: the real clock.
        clock: ?anole.jobs.Clock = null,
    };

    pub const InitError = error{InvalidOptions} || std.mem.Allocator.Error;

    /// What the OpenAPI document says of a route behind it.
    pub const openapi: declarations.MiddlewareDoc = .{
        .responses = .{
            .bad_request = .{ .description = "The webhook signature is missing, malformed or wrong, or its timestamp is stale" },
            .conflict = .{ .description = "The same delivery is being processed; the sender retries later" },
            .service_unavailable = .{ .description = "The duplicate store failed" },
        },
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    memory: ?*dedup.Memory = null,

    /// Checks the options (secrets present and decodable, `.hmac` settings)
    /// and allocates the memory store. `error.InvalidOptions` is logged
    /// with the reason.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) InitError!*Verify {
        if (options.secrets.len == 0) return invalid("secrets is empty");
        for (options.secrets) |s| {
            if (s.len == 0) return invalid("a secret is empty");
            if (options.preset == .standard) {
                var out: [sign.public_prefix.len + 64]u8 = undefined;
                _ = &out;
                if (std.mem.startsWith(u8, s, sign.public_prefix)) {
                    const t = s[sign.public_prefix.len..];
                    if ((std.base64.standard.Decoder.calcSizeForSlice(t) catch 0) != 32) return invalid("a whpk_ key is not 32 bytes of base64");
                } else {
                    const t = if (std.mem.startsWith(u8, s, sign.secret_prefix)) s[sign.secret_prefix.len..] else s;
                    const n = std.base64.standard.Decoder.calcSizeForSlice(t) catch return invalid("a whsec_ secret is not base64");
                    if (n == 0 or n > 64) return invalid("a whsec_ secret has a bad length");
                }
            }
        }
        if (options.preset == .hmac) {
            const h = options.hmac orelse return invalid("preset hmac needs the hmac settings");
            if (h.header.len == 0) return invalid("hmac.header is empty");
        }
        const self = try gpa.create(Verify);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .options = options };
        switch (options.dedup) {
            .memory => |m| {
                const mem = try gpa.create(dedup.Memory);
                mem.* = dedup.Memory.init(gpa, io, m);
                self.memory = mem;
            },
            else => {},
        }
        return self;
    }

    fn invalid(comptime why: []const u8) error{InvalidOptions} {
        log.err("webhook_verify: {s}", .{why});
        return error.InvalidOptions;
    }

    pub fn deinit(self: *Verify) void {
        if (self.memory) |m| {
            m.deinit();
            self.gpa.destroy(m);
        }
        self.gpa.destroy(self);
    }

    /// Nothing to start (the connector hook of `app.webhookVerify`).
    pub fn start(self: *Verify, registry: anytype, tracer: anytype, health: anytype) !void {
        _ = .{ self, registry, tracer, health };
    }

    /// It marks the id after the handler, so requests behind it keep a task.
    pub const detach_safe = false;

    fn nowMs(self: *const Verify) i64 {
        if (self.options.clock) |c| return c.now(c.context).toMillis();
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    pub fn execute(self: *Verify, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        const body = (try req.body()) orelse "";
        var reason_buf: [96]u8 = undefined;
        var meta: Checked = .{};
        if (self.check(req, body, &meta, &reason_buf)) |reason| {
            log.info("webhook {t} refused: {s}", .{ self.options.preset, reason });
            res.fail(.bad_request, "invalid webhook signature");
            return;
        }
        try req.setLocal("anole.webhook", Inbound{ .preset = self.options.preset, .id = meta.id(), .timestamp = meta.timestamp });

        const id = meta.id() orelse return next.call();
        if (self.options.dedup == .none) return next.call();
        const key = dedup.keyOf(@tagName(self.options.preset), id);
        const at = self.nowMs();
        const claim: dedup.Claim = switch (self.options.dedup) {
            .none => unreachable,
            .memory => self.memory.?.claim(key, pending_ms, at),
            .redis => |r| (dedup.Redis{ .options = r }).claim(req, key, pending_ms),
        } catch {
            switch (self.options.on_store_error) {
                .reject => {
                    log.warn("webhook duplicate store failed, request refused (503)", .{});
                    res.fail(.service_unavailable, "");
                    return;
                },
                .process => {
                    log.warn("webhook duplicate store failed, request processed without it", .{});
                    return next.call();
                },
            }
        };
        switch (claim) {
            .done => {
                res.status = .ok;
                res.body = "";
                return;
            },
            .pending => {
                res.status = .conflict;
                res.body = "";
                try res.header("Retry-After", "5");
                return;
            },
            .new => {},
        }
        next.call() catch |err| {
            self.release(req, key);
            return err;
        };
        const code = @backingInt(res.status);
        if (code >= 200 and code < 300) self.markDone(req, key, self.nowMs()) else self.release(req, key);
    }

    const pending_ms: i64 = 5 * 60 * 1000;

    fn markDone(self: *Verify, req: *dusty.Request, key: u128, at: i64) void {
        switch (self.options.dedup) {
            .none => {},
            .memory => self.memory.?.markDone(key, at),
            .redis => |r| (dedup.Redis{ .options = r }).markDone(req, key),
        }
    }

    fn release(self: *Verify, req: *dusty.Request, key: u128) void {
        switch (self.options.dedup) {
            .none => {},
            .memory => self.memory.?.release(key),
            .redis => |r| (dedup.Redis{ .options = r }).release(req, key),
        }
    }

    const Checked = struct {
        id_buf: [255]u8 = undefined,
        id_len: usize = 0,
        has_id: bool = false,
        timestamp: ?i64 = null,

        fn id(self: *const Checked) ?[]const u8 {
            return if (self.has_id) self.id_buf[0..self.id_len] else null;
        }
        fn setId(self: *Checked, v: []const u8) void {
            if (v.len == 0 or v.len > self.id_buf.len) return;
            @memcpy(self.id_buf[0..v.len], v);
            self.id_len = v.len;
            self.has_id = true;
        }
    };

    /// Null when the request is genuine, else the reason (for the log).
    fn check(self: *const Verify, req: *const dusty.Request, body: []const u8, meta: *Checked, buf: []u8) ?[]const u8 {
        const o = self.options;
        const now_s = @divFloor(self.nowMs(), 1000);
        const tol: i64 = o.tolerance.toSeconds();
        switch (o.preset) {
            .standard => {
                const id = req.headers.get("webhook-id") orelse return "missing header webhook-id";
                const ts = req.headers.get("webhook-timestamp") orelse return "missing header webhook-timestamp";
                const sig = req.headers.get("webhook-signature") orelse return "missing header webhook-signature";
                sign.verify(o.secrets, id, ts, sig, body, now_s, tol) catch |e| return explain(buf, e, ts, now_s);
                meta.setId(id);
                meta.timestamp = std.fmt.parseInt(i64, ts, 10) catch null;
            },
            .stripe => {
                const h = req.headers.get("Stripe-Signature") orelse return "missing header Stripe-Signature";
                const parsed = parseStripe(h) orelse return "malformed Stripe-Signature";
                const diff = @abs(@as(i128, now_s) - parsed.t);
                if (diff > @as(u128, @intCast(@max(tol, 0)))) return std.fmt.bufPrint(buf, "timestamp {d} s off", .{diff}) catch "stale timestamp";
                var ts_buf: [24]u8 = undefined;
                const ts_text = std.fmt.bufPrint(&ts_buf, "{d}", .{parsed.t}) catch unreachable;
                var ok = false;
                for (o.secrets) |secret| {
                    for (parsed.v1[0..parsed.v1_count]) |hex| {
                        if (macMatches(std.crypto.auth.hmac.sha2.HmacSha256, secret, &.{ ts_text, ".", body }, hex, .hex)) ok = true;
                    }
                }
                if (!ok) return "no matching signature";
                meta.timestamp = parsed.t;
                var tmp: [255]u8 = undefined;
                if (jsonTopString(body, "id", &tmp)) |v| meta.setId(v);
            },
            .github => {
                const h = req.headers.get("X-Hub-Signature-256") orelse return "missing header X-Hub-Signature-256";
                if (!std.mem.startsWith(u8, h, "sha256=")) return "malformed X-Hub-Signature-256";
                var ok = false;
                for (o.secrets) |secret| {
                    if (macMatches(std.crypto.auth.hmac.sha2.HmacSha256, secret, &.{body}, h["sha256=".len..], .hex)) ok = true;
                }
                if (!ok) return "no matching signature";
                if (req.headers.get("X-GitHub-Delivery")) |d| meta.setId(d);
            },
            .slack => {
                const h = req.headers.get("X-Slack-Signature") orelse return "missing header X-Slack-Signature";
                const ts = req.headers.get("X-Slack-Request-Timestamp") orelse return "missing header X-Slack-Request-Timestamp";
                if (!std.mem.startsWith(u8, h, "v0=")) return "malformed X-Slack-Signature";
                const t = std.fmt.parseInt(i64, ts, 10) catch return "bad timestamp";
                const diff = @abs(@as(i128, now_s) - t);
                if (diff > @as(u128, @intCast(@max(tol, 0)))) return std.fmt.bufPrint(buf, "timestamp {d} s off", .{diff}) catch "stale timestamp";
                var ok = false;
                for (o.secrets) |secret| {
                    if (macMatches(std.crypto.auth.hmac.sha2.HmacSha256, secret, &.{ "v0:", ts, ":", body }, h[3..], .hex)) ok = true;
                }
                if (!ok) return "no matching signature";
                meta.timestamp = t;
                var tmp: [255]u8 = undefined;
                if (jsonTopString(body, "event_id", &tmp)) |v| meta.setId(v);
            },
            .hmac => {
                const hm = o.hmac.?;
                var h = req.headers.get(hm.header) orelse return "missing signature header";
                if (!std.mem.startsWith(u8, h, hm.prefix)) return "malformed signature header";
                h = h[hm.prefix.len..];
                var ok = false;
                for (o.secrets) |secret| {
                    const m = switch (hm.algorithm) {
                        .sha1 => macMatches(std.crypto.auth.hmac.HmacSha1, secret, &.{body}, h, hm.encoding),
                        .sha256 => macMatches(std.crypto.auth.hmac.sha2.HmacSha256, secret, &.{body}, h, hm.encoding),
                        .sha512 => macMatches(std.crypto.auth.hmac.sha2.HmacSha512, secret, &.{body}, h, hm.encoding),
                    };
                    if (m) ok = true;
                }
                if (!ok) return "no matching signature";
                if (hm.id_header) |ih| if (req.headers.get(ih)) |d| meta.setId(d);
            },
        }
        return null;
    }
};

fn explain(buf: []u8, e: sign.VerifyError, ts: []const u8, now_s: i64) []const u8 {
    return switch (e) {
        error.MissingHeader => "missing header",
        error.BadTimestamp => "bad timestamp",
        error.Stale => blk: {
            const t = std.fmt.parseInt(i64, ts, 10) catch 0;
            break :blk std.fmt.bufPrint(buf, "timestamp {d} s off", .{@abs(@as(i128, now_s) - t)}) catch "stale timestamp";
        },
        error.NoMatch => "no matching signature",
        error.InvalidSecret => "invalid secret",
    };
}

/// What `Verify` checked, for the handler: null on a route without it.
pub const Inbound = struct { preset: Verify.Preset, id: ?[]const u8, timestamp: ?i64 };

pub fn inbound(req: *const dusty.Request) ?Inbound {
    return req.local(Inbound, "anole.webhook");
}

/// Whether `encoded` (hex or base64, exactly the digest's size) is `H`'s
/// MAC of the concatenated `parts` under `key`; compared in constant time.
fn macMatches(comptime H: type, key: []const u8, parts: []const []const u8, encoded: []const u8, enc: Encoding) bool {
    var got: [H.mac_length]u8 = undefined;
    switch (enc) {
        .hex => {
            if (encoded.len != got.len * 2) return false;
            _ = std.fmt.hexToBytes(&got, encoded) catch return false;
        },
        .base64 => {
            const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
            if (n != got.len) return false;
            std.base64.standard.Decoder.decode(&got, encoded) catch return false;
        },
    }
    var h = H.init(key);
    for (parts) |p| h.update(p);
    var want: [H.mac_length]u8 = undefined;
    h.final(&want);
    return std.crypto.timing_safe.eql([H.mac_length]u8, got, want);
}

const StripeParts = struct {
    t: i64,
    v1: [4][]const u8 = undefined,
    v1_count: usize = 0,
};

/// `t=<s>,v1=<hex>[,v1=<hex>][,v0=...]`: the timestamp and up to four v1
/// signatures (several while a secret rotates); v0 is ignored.
fn parseStripe(h: []const u8) ?StripeParts {
    var out: StripeParts = .{ .t = 0 };
    var have_t = false;
    var it = std.mem.splitScalar(u8, h, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, p, "t=")) {
            out.t = std.fmt.parseInt(i64, p[2..], 10) catch return null;
            have_t = true;
        } else if (std.mem.startsWith(u8, p, "v1=")) {
            if (out.v1_count < out.v1.len) {
                out.v1[out.v1_count] = p[3..];
                out.v1_count += 1;
            }
        }
    }
    if (!have_t or out.v1_count == 0) return null;
    return out;
}

/// The first-level string member `name` of a JSON object body, copied into
/// `out`; null when the body is not an object, the member is missing, not
/// a string or longer than 255 bytes.
pub fn jsonTopString(body: []const u8, name: []const u8, out: *[255]u8) ?[]const u8 {
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();
    var sc = std.json.Scanner.initCompleteInput(a, body);
    defer sc.deinit();
    if ((sc.next() catch return null) != .object_begin) return null;
    while (true) {
        const key_tok = sc.nextAlloc(a, .alloc_if_needed) catch return null;
        const key = switch (key_tok) {
            .string, .allocated_string => |s| s,
            .object_end => return null,
            else => return null,
        };
        const is_match = std.mem.eql(u8, key, name);
        const val = sc.nextAlloc(a, .alloc_if_needed) catch return null;
        switch (val) {
            .string, .allocated_string => |s| {
                if (is_match) {
                    if (s.len == 0 or s.len > out.len) return null;
                    @memcpy(out[0..s.len], s);
                    return out[0..s.len];
                }
            },
            .object_begin, .array_begin => {
                if (is_match) return null;
                sc.skipUntilStackHeight(1) catch return null;
            },
            else => if (is_match) return null,
        }
    }
}

test "jsonTopString reads first-level strings only" {
    var out: [255]u8 = undefined;
    try std.testing.expectEqualStrings("evt_1", jsonTopString("{\"data\":{\"id\":\"no\"},\"id\":\"evt_1\"}", "id", &out).?);
    try std.testing.expect(jsonTopString("{\"data\":{\"id\":\"no\"}}", "id", &out) == null);
    try std.testing.expect(jsonTopString("[1]", "id", &out) == null);
    try std.testing.expect(jsonTopString("{\"id\":5}", "id", &out) == null);
    try std.testing.expect(jsonTopString("garbage", "id", &out) == null);
}

test "macMatches: hex and base64, wrong sizes" {
    const H = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [32]u8 = undefined;
    H.create(&mac, "body", "key");
    const hex = std.fmt.bytesToHex(mac, .lower);
    try std.testing.expect(macMatches(H, "key", &.{"body"}, &hex, .hex));
    try std.testing.expect(!macMatches(H, "key", &.{"bodz"}, &hex, .hex));
    try std.testing.expect(!macMatches(H, "key", &.{"body"}, hex[0..62], .hex));
    var b: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b, &mac);
    try std.testing.expect(macMatches(H, "key", &.{"body"}, &b, .base64));
}

test "stripe header parsing" {
    const p = parseStripe("t=1492774577,v1=abcd,v0=ffff").?;
    try std.testing.expectEqual(@as(i64, 1492774577), p.t);
    try std.testing.expectEqualStrings("abcd", p.v1[0]);
    try std.testing.expectEqual(@as(usize, 2), parseStripe("t=1,v1=a,v1=b").?.v1_count);
    try std.testing.expect(parseStripe("v1=abcd") == null);
    try std.testing.expect(parseStripe("t=x,v1=a") == null);
    try std.testing.expect(parseStripe("t=1") == null);
}

test "fuzz: json id scan and stripe header" {
    const fuzz = @import("../fuzz.zig");
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            var out: [255]u8 = undefined;
            if (jsonTopString(input, "id", &out)) |v| try std.testing.expect(v.len > 0 and v.len <= 255);
            _ = parseStripe(input);
        }
    }.check, &.{ "{\"id\":\"a\",\"x\":[1,{\"id\":\"b\"}]}", "t=1,v1=aa,v1=bb", "{\"a\":{" });
}
