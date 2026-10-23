//! `anole.s3.testing.FakeServer`: an S3 in process, on Anole's HTTP server,
//! for tests that need no Docker. Memory store; verifies every request's
//! SigV4 signature (header or presigned) with `sigv4.zig`; ListObjectsV2,
//! multipart, conditional and range requests; scripted failures.
//!
//!     var fake = try s3.testing.FakeServer.start(gpa, io);
//!     defer fake.stop();
//!     const files = try s3.Client.init(gpa, io, .{ .endpoint = fake.url(), .bucket = "b",
//!         .credentials = fake.credentials() });
//!
//! Path-style addressing only. It checks what S3 checks (signature,
//! preconditions, part sizes); it does not model versions, ACLs or
//! eventual consistency.
const std = @import("std");
const dusty = @import("dusty");
const sigv4 = @import("sigv4.zig");
const xml = @import("xml.zig");
const util = @import("util.zig");

const Md5 = std.crypto.hash.Md5;

pub const access_key_id = "AKIAFAKEFAKEFAKE0001";
pub const secret_access_key = "fake/secret/access/key+for+tests";

pub const Object = struct {
    bytes: []u8,
    etag: []u8,
    content_type: []u8,
    cache_control: ?[]u8 = null,
    content_disposition: ?[]u8 = null,
    content_encoding: ?[]u8 = null,
    metadata: []const [2][]u8 = &.{},
    modified: i64,
};

const Upload = struct {
    key: []u8,
    content_type: []u8,
    metadata: []const [2][]u8,
    parts: std.AutoArrayHashMapUnmanaged(u16, []u8) = .empty,
};

/// Fails matching requests: `method` (null: any), a query parameter that
/// must be present, how many times, and what to answer.
pub const Fault = struct {
    method: ?[]const u8 = null,
    query: ?[]const u8 = null,
    remaining: u32 = 1,
    status: u16 = 503,
    code: []const u8 = "SlowDown",
    /// Answer with this `Date` header (clock-skew tests).
    date: ?[]const u8 = null,
};

pub const Logged = struct {
    method: []const u8,
    target: []const u8,
    status: u16,
};

pub const FakeServer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: dusty.Server(FakeServer),
    future: ?std.Io.Future(anyerror!void) = null,
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    objects: std.StringArrayHashMapUnmanaged(Object) = .empty,
    uploads: std.StringArrayHashMapUnmanaged(Upload) = .empty,
    faults: std.ArrayList(Fault) = .empty,
    log: std.ArrayList(Logged) = .empty,
    next_upload: u32 = 1,
    /// The key and secret requests must be signed with.
    expect_token: ?[]const u8 = null,
    /// Part uploads wait here until `releaseParts` (back-pressure tests).
    hold_parts: bool = false,
    parts_gate: std.Io.Event = .unset,
    /// A GET of a key in `stall_keys` sends half its body and then waits.
    stall_gets: bool = false,
    stall_gate: std.Io.Event = .unset,
    /// Requests currently inside a handler holding a part.
    held_parts: std.atomic.Value(u32) = .init(0),
    now_override: ?i64 = null,
    signature_failures: u32 = 0,

    pub fn start(gpa: std.mem.Allocator, io: std.Io) !*FakeServer {
        const self = try gpa.create(FakeServer);
        errdefer gpa.destroy(self);
        const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};
        self.* = .{
            .gpa = gpa,
            .io = io,
            .server = dusty.Server(FakeServer).init(gpa, io, .{
                .listeners = loopback,
                .request = .{ .max_body_size = 256 * 1024 * 1024 },
            }, self),
            .arena = .init(gpa),
        };
        self.server.router.any("/", handle);
        self.server.router.any("/*", handle);
        self.future = try io.concurrent(runServer, .{self});
        try self.server.waitReady(io);
        return self;
    }

    fn runServer(self: *FakeServer) anyerror!void {
        try self.server.run();
    }

    pub fn stop(self: *FakeServer) void {
        self.parts_gate.set(self.io);
        self.stall_gate.set(self.io);
        if (self.future) |*f| _ = f.cancel(self.io) catch {};
        self.server.deinit();
        self.objects.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.faults.deinit(self.gpa);
        self.log.deinit(self.gpa);
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// "http://127.0.0.1:<port>".
    pub fn url(self: *FakeServer) []const u8 {
        const a = self.arena.allocator();
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.server.address.ip.getPort()}) catch "";
    }

    /// Credentials that match the server's.
    pub fn credentials(self: *const FakeServer) @import("root.zig").Options.Credentials {
        _ = self;
        return .{ .static = .{ .access_key_id = access_key_id, .secret_access_key = secret_access_key } };
    }

    // ---- Test controls -------------------------------------------------------

    pub fn addFault(self: *FakeServer, f: Fault) !void {
        try self.lock();
        defer self.unlock();
        try self.faults.append(self.gpa, f);
    }

    pub fn releaseParts(self: *FakeServer) void {
        self.hold_parts = false;
        self.parts_gate.set(self.io);
    }

    pub fn releaseStall(self: *FakeServer) void {
        self.stall_gate.set(self.io);
    }

    /// Stores an object directly.
    pub fn putObject(self: *FakeServer, bucket: []const u8, key: []const u8, bytes: []const u8, content_type: []const u8) !void {
        try self.lock();
        defer self.unlock();
        try self.store(bucket, key, bytes, content_type, &.{}, null);
    }

    /// The bytes of an object, or null; valid until the server stops.
    pub fn getObject(self: *FakeServer, bucket: []const u8, key: []const u8) ?[]const u8 {
        self.lock() catch return null;
        defer self.unlock();
        var buf: [1200]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}/{s}", .{ bucket, key }) catch return null;
        const o = self.objects.get(k) orelse return null;
        return o.bytes;
    }

    /// Requests seen so far with `method` (null: all) whose target contains `contains`.
    pub fn count(self: *FakeServer, method: ?[]const u8, contains: []const u8) usize {
        self.lock() catch return 0;
        defer self.unlock();
        var n: usize = 0;
        for (self.log.items) |l| {
            if (method) |m| if (!std.mem.eql(u8, m, l.method)) continue;
            if (std.mem.indexOf(u8, l.target, contains) != null) n += 1;
        }
        return n;
    }

    fn lock(self: *FakeServer) !void {
        try self.mutex.lock(self.io);
    }

    fn unlock(self: *FakeServer) void {
        self.mutex.unlock(self.io);
    }

    fn dupe(self: *FakeServer, bytes: []const u8) ![]u8 {
        return self.gpa.dupe(u8, bytes);
    }

    fn store(self: *FakeServer, bucket: []const u8, key: []const u8, bytes: []const u8, content_type: []const u8, metadata: []const [2][]u8, extra: ?*const Extra) !void {
        const k = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ bucket, key });
        var md5: [16]u8 = undefined;
        Md5.hash(bytes, &md5, .{});
        const etag = try std.fmt.allocPrint(self.gpa, "\"{x}\"", .{&md5});
        const obj: Object = .{
            .bytes = try self.dupe(bytes),
            .etag = etag,
            .content_type = try self.dupe(content_type),
            .cache_control = if (extra) |e| if (e.cache_control) |v| try self.dupe(v) else null else null,
            .content_disposition = if (extra) |e| if (e.content_disposition) |v| try self.dupe(v) else null else null,
            .content_encoding = if (extra) |e| if (e.content_encoding) |v| try self.dupe(v) else null else null,
            .metadata = metadata,
            .modified = util.nowSeconds(self.io),
        };
        const gop = try self.objects.getOrPut(self.gpa, k);
        gop.value_ptr.* = obj;
    }

    const Extra = struct {
        cache_control: ?[]const u8,
        content_disposition: ?[]const u8,
        content_encoding: ?[]const u8,
    };

    // ---- The handler -------------------------------------------------------------

    fn handle(self: *FakeServer, req: *dusty.Request, res: *dusty.Response) !void {
        try self.dispatch(req, res);
        try self.lock();
        defer self.unlock();
        try self.log.append(self.gpa, .{
            .method = try self.arena.allocator().dupe(u8, @tagName(req.method)),
            .target = try self.arena.allocator().dupe(u8, req.url),
            .status = @intFromEnum(res.status),
        });
    }

    fn errorXml(res: *dusty.Response, status: dusty.Status, code: []const u8, message: []const u8) !void {
        res.status = status;
        try res.header("Content-Type", "application/xml");
        res.body = try std.fmt.allocPrint(res.arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>{s}</Code><Message>{s}</Message><RequestId>FAKEREQ0001</RequestId></Error>", .{ code, message });
    }

    const Query = struct { pairs: []const [2][]const u8 };

    fn parseQuery(arena: std.mem.Allocator, raw: []const u8) ![]const [2][]const u8 {
        var out: std.ArrayList([2][]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=');
            const k = if (eq) |e| part[0..e] else part;
            const v = if (eq) |e| part[e + 1 ..] else "";
            try out.append(arena, .{ try xml.urlDecode(arena, k), try xml.urlDecode(arena, v) });
        }
        return out.items;
    }

    fn queryGet(q: []const [2][]const u8, name: []const u8) ?[]const u8 {
        for (q) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }

    fn dispatch(self: *FakeServer, req: *dusty.Request, res: *dusty.Response) !void {
        const arena = res.arena;
        const target = req.url;
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const raw_path = if (qmark) |i| target[0..i] else target;
        const raw_query = if (qmark) |i| target[i + 1 ..] else "";
        const query = try parseQuery(arena, raw_query);
        const method = @tagName(req.method);

        // Scripted failures first.
        {
            try self.lock();
            defer self.unlock();
            for (self.faults.items) |*f| {
                if (f.remaining == 0) continue;
                if (f.method) |m| if (!std.mem.eql(u8, m, method)) continue;
                if (f.query) |qn| if (queryGet(query, qn) == null) continue;
                f.remaining -= 1;
                if (f.date) |d| try res.header("Date", d);
                try errorXml(res, dusty.Status.fromCode(f.status) catch .internal_server_error, f.code, "scripted failure");
                return;
            }
        }

        if (!try self.verify(req, res, raw_path, query)) return;

        // /<bucket>[/<key>]
        const path = try xml.urlDecode(arena, raw_path);
        if (path.len < 2) return errorXml(res, .bad_request, "InvalidRequest", "no bucket");
        const rest = path[1..];
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const bucket = if (slash) |s| rest[0..s] else rest;
        const key = if (slash) |s| rest[s + 1 ..] else "";

        if (key.len == 0) {
            switch (req.method) {
                .head => {
                    res.status = .ok;
                    return;
                },
                .get => return self.list(res, bucket, query),
                .post => if (queryGet(query, "delete") != null) return self.deleteMany(req, res, bucket),
                else => {},
            }
            return errorXml(res, .method_not_allowed, "MethodNotAllowed", "not supported on a bucket");
        }
        switch (req.method) {
            .put => {
                if (req.headers.get("x-amz-copy-source")) |src| return self.copy(req, res, bucket, key, src);
                if (queryGet(query, "uploadId")) |id| return self.uploadPart(req, res, id, queryGet(query, "partNumber") orelse "0");
                return self.putObject_(req, res, bucket, key);
            },
            .get, .head => return self.getObject_(req, res, bucket, key),
            .delete => {
                if (queryGet(query, "uploadId")) |id| return self.abortUpload(res, id);
                try self.lock();
                defer self.unlock();
                const k = try std.fmt.allocPrint(arena, "{s}/{s}", .{ bucket, key });
                _ = self.objects.swapRemove(k);
                res.status = .no_content;
            },
            .post => {
                if (queryGet(query, "uploads") != null) return self.initiate(req, res, bucket, key);
                if (queryGet(query, "uploadId")) |id| return self.complete(req, res, bucket, key, id);
                return errorXml(res, .bad_request, "InvalidRequest", "unknown POST");
            },
            else => return errorXml(res, .method_not_allowed, "MethodNotAllowed", "not supported"),
        }
    }

    // ---- Signature -------------------------------------------------------------------

    /// True when the request's signature is right; otherwise answers 403.
    fn verify(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, raw_path: []const u8, query: []const [2][]const u8) !bool {
        const arena = res.arena;
        const keys: sigv4.Keys = .{ .access_key_id = access_key_id, .secret = secret_access_key, .token = self.expect_token };
        const host = req.headers.get("Host") orelse "";
        const region = "us-east-1";
        var signer: sigv4.Signer = .init(region);

        const deny = struct {
            fn f(s: *FakeServer, r: *dusty.Response, why: []const u8) !bool {
                s.signature_failures += 1;
                try errorXml(r, .forbidden, "SignatureDoesNotMatch", why);
                return false;
            }
        }.f;

        if (queryGet(query, "X-Amz-Signature")) |given| {
            // Presigned.
            const date = queryGet(query, "X-Amz-Date") orelse return deny(self, res, "no X-Amz-Date");
            const expires = std.fmt.parseInt(u32, queryGet(query, "X-Amz-Expires") orelse "0", 10) catch 0;
            const signed = queryGet(query, "X-Amz-SignedHeaders") orelse "host";
            var plain: std.ArrayList([2][]const u8) = .empty;
            for (query) |p| {
                if (std.mem.startsWith(u8, p[0], "X-Amz-")) continue;
                try plain.append(arena, p);
            }
            var extra: std.ArrayList([2][]const u8) = .empty;
            var it = std.mem.splitScalar(u8, signed, ';');
            while (it.next()) |name| {
                if (std.mem.eql(u8, name, "host")) continue;
                try extra.append(arena, .{ name, req.headers.get(name) orelse "" });
            }
            const now_s = parseAmzDate(date) orelse return deny(self, res, "bad X-Amz-Date");
            var out: std.Io.Writer.Allocating = .init(arena);
            var k = keys;
            if (queryGet(query, "X-Amz-Security-Token")) |t| k.token = t else k.token = null;
            try signer.presign(k, now_s, .{
                .method = @tagName(req.method),
                .host = host,
                .canonical_uri = raw_path,
                .query = plain.items,
                .headers = extra.items,
            }, expires, &out.writer);
            const text = out.written();
            const sig = text[std.mem.lastIndexOf(u8, text, "X-Amz-Signature=").? + "X-Amz-Signature=".len ..];
            if (!std.mem.eql(u8, sig, given)) return deny(self, res, "the presigned signature does not match");
            return true;
        }

        const auth = req.headers.get("Authorization") orelse return deny(self, res, "no Authorization header");
        const sig_at = std.mem.lastIndexOf(u8, auth, "Signature=") orelse return deny(self, res, "no Signature");
        const given = auth[sig_at + "Signature=".len ..];
        const sh_at = std.mem.indexOf(u8, auth, "SignedHeaders=") orelse return deny(self, res, "no SignedHeaders");
        const sh_end = std.mem.indexOfScalarPos(u8, auth, sh_at, ',') orelse auth.len;
        const signed = auth[sh_at + "SignedHeaders=".len .. sh_end];
        const date = req.headers.get("x-amz-date") orelse return deny(self, res, "no x-amz-date");
        const now_s = parseAmzDate(date) orelse return deny(self, res, "bad x-amz-date");
        const payload_text = req.headers.get("x-amz-content-sha256") orelse return deny(self, res, "no x-amz-content-sha256");
        const payload: sigv4.PayloadHash = if (std.mem.eql(u8, payload_text, sigv4.unsigned_payload)) .unsigned else blk: {
            var d: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&d, payload_text) catch return deny(self, res, "bad x-amz-content-sha256");
            // The declared hash must be the body's.
            const body = (try req.body()) orelse "";
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &actual, .{});
            if (!std.mem.eql(u8, &d, &actual)) {
                try errorXml(res, .bad_request, "XAmzContentSHA256Mismatch", "the provided x-amz-content-sha256 does not match what was computed");
                return false;
            }
            break :blk .{ .sha256 = d };
        };
        var hl: sigv4.HeaderList = .{};
        var it = std.mem.splitScalar(u8, signed, ';');
        while (it.next()) |name| {
            if (std.mem.eql(u8, name, "host") or std.mem.eql(u8, name, "x-amz-date") or std.mem.eql(u8, name, "x-amz-content-sha256") or std.mem.eql(u8, name, "x-amz-security-token")) continue;
            try hl.add(name, req.headers.get(name) orelse "");
        }
        var k = keys;
        k.token = req.headers.get("x-amz-security-token");
        try signer.sign(k, now_s, .{
            .method = @tagName(req.method),
            .host = host,
            .canonical_uri = raw_path,
            .query = query,
            .payload_hash = payload,
        }, &hl);
        const mine = hl.get("Authorization").?;
        const my_sig = mine[std.mem.lastIndexOf(u8, mine, "Signature=").? + "Signature=".len ..];
        if (!std.mem.eql(u8, my_sig, given)) return deny(self, res, "the request signature does not match");
        // The signed header names must be the ones the signer would sign.
        if (std.mem.indexOf(u8, mine, signed) == null) return deny(self, res, "the signed headers differ");
        return true;
    }

    fn parseAmzDate(text: []const u8) ?i64 {
        if (text.len != 16 or text[8] != 'T' or text[15] != 'Z') return null;
        const y = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
        const mo = std.fmt.parseInt(u8, text[4..6], 10) catch return null;
        const d = std.fmt.parseInt(u8, text[6..8], 10) catch return null;
        const h = std.fmt.parseInt(u8, text[9..11], 10) catch return null;
        const mi = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
        const s = std.fmt.parseInt(u8, text[13..15], 10) catch return null;
        // Days from civil, as in util.
        const yy: i64 = if (mo <= 2) @as(i64, y) - 1 else y;
        const era = @divFloor(yy, 400);
        const yoe = yy - era * 400;
        const mp: i64 = (mo + 9) % 12;
        const doy = @divFloor(153 * mp + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const days = era * 146097 + doe - 719468;
        return days * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + s;
    }

    // ---- Objects -----------------------------------------------------------------------

    fn userMetadata(self: *FakeServer, req: *dusty.Request) ![]const [2][]u8 {
        var out: std.ArrayList([2][]u8) = .empty;
        var it = req.headers.iterator();
        while (it.next()) |e| {
            if (e.key.len > 11 and std.ascii.eqlIgnoreCase(e.key[0..11], "x-amz-meta-")) {
                try out.append(self.arena.allocator(), .{ try self.arena.allocator().dupe(u8, e.key[11..]), try self.arena.allocator().dupe(u8, e.value) });
            }
        }
        return out.items;
    }

    fn putObject_(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8, key: []const u8) !void {
        const body = (try req.body()) orelse "";
        try self.lock();
        defer self.unlock();
        const k = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, key });
        const existing = self.objects.get(k);
        if (req.headers.get("If-None-Match")) |inm| if (std.mem.eql(u8, inm, "*") and existing != null)
            return errorXml(res, .precondition_failed, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
        if (req.headers.get("If-Match")) |im| if (existing == null or !std.mem.eql(u8, im, existing.?.etag))
            return errorXml(res, .precondition_failed, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
        const extra: Extra = .{
            .cache_control = req.headers.get("Cache-Control"),
            .content_disposition = req.headers.get("Content-Disposition"),
            .content_encoding = req.headers.get("Content-Encoding"),
        };
        try self.store(bucket, key, body, req.headers.get("Content-Type") orelse "binary/octet-stream", try self.userMetadata(req), &extra);
        const o = self.objects.get(k).?;
        try res.header("ETag", o.etag);
        res.status = .ok;
    }

    fn getObject_(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8, key: []const u8) !void {
        {
            try self.lock();
            defer self.unlock();
        }
        const k = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, key });
        var o: Object = undefined;
        {
            try self.lock();
            defer self.unlock();
            o = self.objects.get(k) orelse {
                if (req.method == .head) {
                    res.status = .not_found;
                    return;
                }
                return errorXml(res, .not_found, "NoSuchKey", "The specified key does not exist.");
            };
        }
        if (req.headers.get("If-Match")) |im| if (!std.mem.eql(u8, im, o.etag))
            return errorXml(res, .precondition_failed, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
        try res.header("ETag", o.etag);
        var date: [29]u8 = undefined;
        try res.header("Last-Modified", try res.arena.dupe(u8, util.formatHttpDate(&date, o.modified)));
        try res.header("Accept-Ranges", "bytes");
        try res.header("Content-Type", o.content_type);
        if (o.cache_control) |v| try res.header("Cache-Control", v);
        if (o.content_disposition) |v| try res.header("Content-Disposition", v);
        if (o.content_encoding) |v| try res.header("Content-Encoding", v);
        for (o.metadata) |m| try res.header(try std.fmt.allocPrint(res.arena, "x-amz-meta-{s}", .{m[0]}), m[1]);
        if (req.headers.get("If-None-Match")) |inm| if (std.mem.eql(u8, inm, o.etag)) {
            res.status = .not_modified;
            return;
        };
        if (req.headers.get("If-Modified-Since")) |ims| if (util.parseHttpDate(ims)) |t| if (o.modified <= t) {
            res.status = .not_modified;
            return;
        };
        var bytes: []const u8 = o.bytes;
        res.status = .ok;
        if (req.headers.get("Range")) |range| {
            // bytes=a-b | bytes=a-
            if (std.mem.startsWith(u8, range, "bytes=")) {
                const spec = range[6..];
                const dash = std.mem.indexOfScalar(u8, spec, '-') orelse 0;
                const first = std.fmt.parseInt(u64, spec[0..dash], 10) catch 0;
                const end_incl = if (dash + 1 < spec.len) (std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch o.bytes.len - 1) else o.bytes.len - 1;
                if (first >= o.bytes.len) return errorXml(res, .range_not_satisfiable, "InvalidRange", "The requested range is not satisfiable");
                const end = @min(end_incl, o.bytes.len - 1);
                bytes = o.bytes[first .. end + 1];
                res.status = .partial_content;
                try res.header("Content-Range", try std.fmt.allocPrint(res.arena, "bytes {d}-{d}/{d}", .{ first, end, o.bytes.len }));
            }
        }
        if (req.method == .head) {
            try res.header("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{bytes.len}));
            return;
        }
        if (self.stall_gets and bytes.len > 1) {
            // Half the body, then nothing until the test lets go.
            try res.header("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{bytes.len}));
            const buf = try res.arena.alloc(u8, 4096);
            var w = try res.stream(buf);
            try w.interface.writeAll(bytes[0 .. bytes.len / 2]);
            try w.interface.flush();
            self.stall_gate.wait(self.io) catch {};
            return;
        }
        res.body = bytes;
    }

    fn copy(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8, key: []const u8, src: []const u8) !void {
        const decoded = try xml.urlDecode(res.arena, src);
        const noquery = if (std.mem.indexOfScalar(u8, decoded, '?')) |i| decoded[0..i] else decoded;
        const trimmed = std.mem.trimStart(u8, noquery, "/");
        try self.lock();
        defer self.unlock();
        const o = self.objects.get(trimmed) orelse return errorXml(res, .not_found, "NoSuchKey", "The specified key does not exist.");
        const replace = if (req.headers.get("x-amz-metadata-directive")) |d| std.mem.eql(u8, d, "REPLACE") else false;
        if (req.headers.get("If-None-Match")) |inm| if (std.mem.eql(u8, inm, "*")) {
            const dk = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, key });
            if (self.objects.contains(dk)) return errorXml(res, .precondition_failed, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
        };
        const meta = if (replace) try self.userMetadata(req) else o.metadata;
        const ct = if (replace) (req.headers.get("Content-Type") orelse o.content_type) else o.content_type;
        const bytes = try self.gpa.dupe(u8, o.bytes);
        defer self.gpa.free(bytes);
        try self.store(bucket, key, bytes, ct, meta, null);
        const dk = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, key });
        const n = self.objects.get(dk).?;
        res.status = .ok;
        try res.header("Content-Type", "application/xml");
        res.body = try std.fmt.allocPrint(res.arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CopyObjectResult><ETag>{s}</ETag><LastModified>2026-10-23T10:00:00.000Z</LastModified></CopyObjectResult>", .{n.etag});
    }

    // ---- Lists -------------------------------------------------------------------------

    fn list(self: *FakeServer, res: *dusty.Response, bucket: []const u8, query: []const [2][]const u8) !void {
        const arena = res.arena;
        const prefix = queryGet(query, "prefix") orelse "";
        const delimiter = queryGet(query, "delimiter");
        const after = queryGet(query, "continuation-token") orelse queryGet(query, "start-after") orelse "";
        const max_keys = std.fmt.parseInt(usize, queryGet(query, "max-keys") orelse "1000", 10) catch 1000;
        const url_enc = if (queryGet(query, "encoding-type")) |e| std.mem.eql(u8, e, "url") else false;

        try self.lock();
        defer self.unlock();
        var keys: std.ArrayList([]const u8) = .empty;
        const bprefix = try std.fmt.allocPrint(arena, "{s}/", .{bucket});
        for (self.objects.keys()) |full| {
            if (!std.mem.startsWith(u8, full, bprefix)) continue;
            const key = full[bprefix.len..];
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            try keys.append(arena, key);
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        var contents: std.Io.Writer.Allocating = .init(arena);
        var prefixes: std.ArrayList([]const u8) = .empty;
        var emitted: usize = 0;
        var truncated = false;
        var last: []const u8 = "";
        for (keys.items) |key| {
            if (after.len > 0 and std.mem.order(u8, key, after) != .gt) continue;
            if (delimiter) |d| {
                const tail = key[prefix.len..];
                if (std.mem.indexOf(u8, tail, d)) |i| {
                    const cp = key[0 .. prefix.len + i + d.len];
                    var seen = false;
                    for (prefixes.items) |p| if (std.mem.eql(u8, p, cp)) {
                        seen = true;
                    };
                    if (seen) continue;
                    if (emitted >= max_keys) {
                        truncated = true;
                        break;
                    }
                    try prefixes.append(arena, cp);
                    emitted += 1;
                    last = cp;
                    continue;
                }
            }
            if (emitted >= max_keys) {
                truncated = true;
                break;
            }
            const o = self.objects.get(try std.fmt.allocPrint(arena, "{s}/{s}", .{ bucket, key })).?;
            try contents.writer.writeAll("<Contents><Key>");
            try writeKey(&contents.writer, key, url_enc);
            try contents.writer.print("</Key><LastModified>2026-10-23T10:00:00.000Z</LastModified><ETag>{s}</ETag><Size>{d}</Size><StorageClass>STANDARD</StorageClass></Contents>", .{ try escapeXml(arena, o.etag), o.bytes.len });
            emitted += 1;
            last = key;
        }
        try w.print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>{s}</Name><Prefix>{s}</Prefix><KeyCount>{d}</KeyCount><MaxKeys>{d}</MaxKeys><IsTruncated>{s}</IsTruncated>", .{ bucket, prefix, emitted, max_keys, if (truncated) "true" else "false" });
        if (url_enc) try w.writeAll("<EncodingType>url</EncodingType>");
        if (truncated) {
            try w.writeAll("<NextContinuationToken>");
            try writeKey(w, last, false);
            try w.writeAll("</NextContinuationToken>");
        }
        try w.writeAll(contents.written());
        for (prefixes.items) |p| {
            try w.writeAll("<CommonPrefixes><Prefix>");
            try writeKey(w, p, url_enc);
            try w.writeAll("</Prefix></CommonPrefixes>");
        }
        try w.writeAll("</ListBucketResult>");
        try res.header("Content-Type", "application/xml");
        res.status = .ok;
        res.body = out.written();
    }

    fn escapeXml(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeKey(&out.writer, text, false);
        return out.written();
    }

    fn writeKey(w: *std.Io.Writer, key: []const u8, url_enc: bool) !void {
        if (url_enc) return sigv4.uriEncode(w, key, true);
        for (key) |ch| switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(ch),
        };
    }

    fn deleteMany(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8) !void {
        if (req.headers.get("Content-MD5") == null) return errorXml(res, .bad_request, "InvalidRequest", "Missing required header for this request: Content-MD5.");
        const body = (try req.body()) orelse "";
        var r = xml.Reader.init(res.arena, body);
        try self.lock();
        defer self.unlock();
        var n: usize = 0;
        var in_key = false;
        while (try r.next()) |tok| switch (tok) {
            .start => |name| in_key = std.mem.eql(u8, name, "Key"),
            .text => |t| if (in_key) {
                const k = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, t });
                _ = self.objects.swapRemove(k);
                n += 1;
            },
            .end => in_key = false,
        };
        res.status = .ok;
        try res.header("Content-Type", "application/xml");
        res.body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<DeleteResult></DeleteResult>";
    }

    // ---- Multipart ----------------------------------------------------------------------

    fn initiate(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8, key: []const u8) !void {
        try self.lock();
        defer self.unlock();
        const id = try std.fmt.allocPrint(self.arena.allocator(), "upload-{d}", .{self.next_upload});
        self.next_upload += 1;
        const k = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ bucket, key });
        try self.uploads.put(self.gpa, id, .{
            .key = @constCast(k),
            .content_type = try self.dupe(req.headers.get("Content-Type") orelse "binary/octet-stream"),
            .metadata = try self.userMetadata(req),
        });
        res.status = .ok;
        try res.header("Content-Type", "application/xml");
        res.body = try std.fmt.allocPrint(res.arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<InitiateMultipartUploadResult><Bucket>{s}</Bucket><Key>{s}</Key><UploadId>{s}</UploadId></InitiateMultipartUploadResult>", .{ bucket, try escapeXml(res.arena, key), id });
    }

    fn uploadPart(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, id: []const u8, number_text: []const u8) !void {
        const body = (try req.body()) orelse "";
        if (self.hold_parts) {
            _ = self.held_parts.fetchAdd(1, .acq_rel);
            defer _ = self.held_parts.fetchSub(1, .acq_rel);
            self.parts_gate.wait(self.io) catch {};
        }
        const number = std.fmt.parseInt(u16, number_text, 10) catch return errorXml(res, .bad_request, "InvalidArgument", "bad part number");
        try self.lock();
        defer self.unlock();
        const up = self.uploads.getPtr(id) orelse return errorXml(res, .not_found, "NoSuchUpload", "The specified upload does not exist.");
        const copy_ = try self.dupe(body);
        const gop = try up.parts.getOrPut(self.gpa, number);
        gop.value_ptr.* = copy_;
        var md5: [16]u8 = undefined;
        Md5.hash(body, &md5, .{});
        res.status = .ok;
        try res.header("ETag", try std.fmt.allocPrint(res.arena, "\"{x}\"", .{&md5}));
    }

    fn complete(self: *FakeServer, req: *dusty.Request, res: *dusty.Response, bucket: []const u8, key: []const u8, id: []const u8) !void {
        const body = (try req.body()) orelse "";
        try self.lock();
        defer self.unlock();
        const up = self.uploads.getPtr(id) orelse return errorXml(res, .not_found, "NoSuchUpload", "The specified upload does not exist.");
        // The listed parts, in order.
        var r = xml.Reader.init(res.arena, body);
        var numbers: std.ArrayList(u16) = .empty;
        var in_num = false;
        while (try r.next()) |tok| switch (tok) {
            .start => |name| in_num = std.mem.eql(u8, name, "PartNumber"),
            .text => |t| if (in_num) try numbers.append(res.arena, std.fmt.parseInt(u16, t, 10) catch 0),
            .end => in_num = false,
        };
        var last_number: u16 = 0;
        var all: std.ArrayList(u8) = .empty;
        var md5s: std.ArrayList(u8) = .empty;
        for (numbers.items, 0..) |n, i| {
            if (n <= last_number) return errorXml(res, .bad_request, "InvalidPartOrder", "The list of parts was not in ascending order.");
            last_number = n;
            const part = up.parts.get(n) orelse return errorXml(res, .bad_request, "InvalidPart", "One or more of the specified parts could not be found.");
            if (i + 1 < numbers.items.len and part.len < 5 * 1024 * 1024)
                return errorXml(res, .bad_request, "EntityTooSmall", "Your proposed upload is smaller than the minimum allowed size");
            try all.appendSlice(res.arena, part);
            var d: [16]u8 = undefined;
            Md5.hash(part, &d, .{});
            try md5s.appendSlice(res.arena, &d);
        }
        const k = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ bucket, key });
        if (req.headers.get("If-None-Match")) |inm| if (std.mem.eql(u8, inm, "*") and self.objects.contains(k))
            return errorXml(res, .precondition_failed, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
        try self.store(bucket, key, all.items, up.content_type, up.metadata, null);
        // The multipart ETag: md5 of the part md5s, "-N".
        var total: [16]u8 = undefined;
        Md5.hash(md5s.items, &total, .{});
        const etag = try std.fmt.allocPrint(self.gpa, "\"{x}-{d}\"", .{ &total, numbers.items.len });
        self.gpa.free(self.objects.getPtr(k).?.etag);
        self.objects.getPtr(k).?.etag = etag;
        for (up.parts.values()) |p| self.gpa.free(p);
        up.parts.deinit(self.gpa);
        _ = self.uploads.swapRemove(id);
        res.status = .ok;
        try res.header("Content-Type", "application/xml");
        res.body = try std.fmt.allocPrint(res.arena, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUploadResult><Location>http://fake/{s}/{s}</Location><Bucket>{s}</Bucket><Key>{s}</Key><ETag>{s}</ETag></CompleteMultipartUploadResult>", .{ bucket, key, bucket, key, try escapeXml(res.arena, etag) });
    }

    fn abortUpload(self: *FakeServer, res: *dusty.Response, id: []const u8) !void {
        try self.lock();
        defer self.unlock();
        const up = self.uploads.getPtr(id) orelse return errorXml(res, .not_found, "NoSuchUpload", "The specified upload does not exist.");
        for (up.parts.values()) |p| self.gpa.free(p);
        up.parts.deinit(self.gpa);
        _ = self.uploads.swapRemove(id);
        res.status = .no_content;
    }

    /// Multipart uploads begun and not completed or aborted.
    pub fn openUploads(self: *FakeServer) usize {
        self.lock() catch return 0;
        defer self.unlock();
        return self.uploads.count();
    }
};
