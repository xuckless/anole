//! Credentials for S3: static keys, or the AWS SDKs' chain (design-connectors.md S6).
//!
//! Order when no key is given: the environment, the shared credentials
//! file, then (AWS endpoints only) web identity (STS), the container
//! credentials endpoint (ECS, EKS Pod Identity) and EC2 IMDSv2. Temporary
//! credentials are renewed five minutes before they expire, by one task on
//! executor 0; a failed renewal keeps the old ones until they expire.
//! Not supported: SSO, `credential_process`, assume-role chains in the
//! config file.
const std = @import("std");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const url_mod = @import("../db/url.zig");
const fetch = @import("fetch.zig");
const xml = @import("xml.zig");
const util = @import("util.zig");
const sigv4 = @import("sigv4.zig");

const placement = dusty.placement;
const log = @import("../errors.zig").log;

/// How long before expiry the credentials are renewed.
pub const renew_before_s: i64 = 300;

/// Immutable credentials, shared by the calls signing with them.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    access_key_id: []const u8,
    secret: []const u8,
    token: ?[]const u8,
    /// Seconds since the epoch; null: do not expire.
    expires: ?i64,

    pub fn keys(self: *const Snapshot) sigv4.Keys {
        return .{ .access_key_id = self.access_key_id, .secret = self.secret, .token = self.token };
    }

    fn create(gpa: std.mem.Allocator, akid: []const u8, secret: []const u8, token: ?[]const u8, expires: ?i64) !*Snapshot {
        const s = try gpa.create(Snapshot);
        errdefer gpa.destroy(s);
        const a = try gpa.dupe(u8, akid);
        errdefer gpa.free(a);
        const b = try gpa.dupe(u8, secret);
        errdefer gpa.free(b);
        const t = if (token) |x| if (x.len > 0) try gpa.dupe(u8, x) else null else null;
        s.* = .{ .gpa = gpa, .access_key_id = a, .secret = b, .token = t, .expires = expires };
        return s;
    }

    fn destroy(self: *Snapshot) void {
        std.crypto.secureZero(u8, @constCast(self.secret));
        self.gpa.free(self.access_key_id);
        self.gpa.free(self.secret);
        if (self.token) |t| self.gpa.free(t);
        self.gpa.destroy(self);
    }
};

/// Where environment variables come from (a test injects its own).
pub const Env = struct {
    context: ?*const anyopaque = null,
    get_fn: *const fn (context: ?*const anyopaque, environ: ?std.process.Environ, name: []const u8, real_only: bool) ?[]const u8 = process,

    fn process(_: ?*const anyopaque, environ: ?std.process.Environ, name: []const u8, real_only: bool) ?[]const u8 {
        return if (real_only) url_mod.realEnv(environ, name) else url_mod.env(environ, name);
    }
};

pub const Source = enum { static, environment, file, web_identity, container, imds, anonymous };

pub const Provider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http: *dusty.Client,
    label: []const u8,
    environ: ?std.process.Environ,
    env: Env = .{},
    /// Only AWS endpoints use roles (S6).
    is_aws: bool,
    region: []const u8,
    imds_base: []const u8 = "http://169.254.169.254",
    sts_url: ?[]const u8 = null,
    /// A shared credentials file path override (tests).
    file_path: ?[]const u8 = null,
    anonymous: bool = false,

    lock: std.atomic.Mutex = .unlocked,
    current_: ?*Snapshot = null,
    source: Source = .anonymous,
    /// Why each source was skipped, for the start error.
    report: std.ArrayList(u8) = .empty,
    refresh_failures: u32 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,

    pub fn deinit(self: *Provider) void {
        self.group.cancel(self.io);
        if (self.current_) |s| self.release(s);
        self.report.deinit(self.gpa);
    }

    /// The current credentials with a reference held (give it back with
    /// `release`), or null for anonymous.
    pub fn acquire(self: *Provider) ?*Snapshot {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const s = self.current_ orelse return null;
        _ = s.refs.fetchAdd(1, .acq_rel);
        return s;
    }

    pub fn release(_: *Provider, s: *Snapshot) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.destroy();
    }

    fn swap(self: *Provider, next: ?*Snapshot) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        const old = self.current_;
        self.current_ = next;
        self.lock.unlock();
        if (old) |o| self.release(o);
    }

    /// Installs fixed keys.
    pub fn setStatic(self: *Provider, akid: []const u8, secret: []const u8, token: ?[]const u8) !void {
        self.source = .static;
        self.swap(try Snapshot.create(self.gpa, akid, secret, token, null));
    }

    fn getenv(self: *Provider, name: []const u8, real_only: bool) ?[]const u8 {
        const v = self.env.get_fn(self.env.context, self.environ, name, real_only) orelse return null;
        return if (v.len == 0) null else v;
    }

    fn note(self: *Provider, comptime fmt: []const u8, args: anytype) void {
        if (self.report.items.len > 0) self.report.appendSlice(self.gpa, "; ") catch return;
        self.report.print(self.gpa, fmt, args) catch {};
    }

    pub const ResolveError = error{ NoCredentials, OutOfMemory, Canceled };

    /// Runs the chain once. On failure `report` lists what was tried.
    pub fn resolve(self: *Provider, now_s: i64) ResolveError!void {
        self.report.clearRetainingCapacity();
        if (try self.fromEnvironment()) return;
        if (try self.fromFile()) return;
        if (self.is_aws) {
            if (try self.fromWebIdentity(now_s)) return;
            if (try self.fromContainer(now_s)) return;
            if (try self.fromImds(now_s)) return;
        } else {
            self.note("web identity, container and EC2 metadata: only for AWS endpoints", .{});
        }
        return error.NoCredentials;
    }

    fn fromEnvironment(self: *Provider) ResolveError!bool {
        const akid = self.getenv("AWS_ACCESS_KEY_ID", false) orelse {
            self.note("environment: AWS_ACCESS_KEY_ID not set", .{});
            return false;
        };
        const secret = self.getenv("AWS_SECRET_ACCESS_KEY", false) orelse {
            self.note("environment: AWS_SECRET_ACCESS_KEY not set", .{});
            return false;
        };
        const token = self.getenv("AWS_SESSION_TOKEN", false);
        self.source = .environment;
        self.swap(try Snapshot.create(self.gpa, akid, secret, token, null));
        return true;
    }

    fn fromFile(self: *Provider) ResolveError!bool {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = self.file_path orelse self.getenv("AWS_SHARED_CREDENTIALS_FILE", true) orelse blk: {
            const home = self.getenv("HOME", true) orelse self.getenv("USERPROFILE", true) orelse {
                self.note("credentials file: no HOME", .{});
                return false;
            };
            break :blk std.fmt.allocPrint(a, "{s}/.aws/credentials", .{home}) catch return error.OutOfMemory;
        };
        const profile = self.getenv("AWS_PROFILE", false) orelse "default";
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(1 << 20)) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.note("{s}: no file", .{path});
            return false;
        };
        const keys = parseCredentialsFile(text, profile) orelse {
            self.note("{s}: no keys in profile \"{s}\"", .{ path, profile });
            return false;
        };
        self.source = .file;
        self.swap(try Snapshot.create(self.gpa, keys.akid, keys.secret, keys.token, null));
        return true;
    }

    fn fromWebIdentity(self: *Provider, now_s: i64) ResolveError!bool {
        _ = now_s;
        const token_file = self.getenv("AWS_WEB_IDENTITY_TOKEN_FILE", true) orelse {
            self.note("web identity: AWS_WEB_IDENTITY_TOKEN_FILE not set", .{});
            return false;
        };
        const role = self.getenv("AWS_ROLE_ARN", true) orelse {
            self.note("web identity: AWS_ROLE_ARN not set", .{});
            return false;
        };
        const got = self.fetchWebIdentity(token_file, role) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.note("web identity: {t}", .{err});
            return false;
        };
        self.source = .web_identity;
        self.swap(got);
        return true;
    }

    fn fetchWebIdentity(self: *Provider, token_file: []const u8, role: []const u8) !*Snapshot {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const token = std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(self.io, token_file, a, .limited(64 * 1024)), " \t\r\n");
        const url = self.sts_url orelse try std.fmt.allocPrint(a, "https://sts.{s}.amazonaws.com/", .{self.region});
        var form: std.Io.Writer.Allocating = .init(a);
        const w = &form.writer;
        try w.writeAll("Action=AssumeRoleWithWebIdentity&Version=2011-06-15&RoleArn=");
        try sigv4.uriEncode(w, role, false);
        try w.print("&RoleSessionName=anole-{d}&WebIdentityToken=", .{std.c.getpid()});
        try sigv4.uriEncode(w, token, false);
        const res = try fetch.simple(self.http, a, url, .post, &.{
            .{ "Content-Type", "application/x-www-form-urlencoded" },
            .{ "Accept", "application/xml" },
        }, form.written(), .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }, 64 * 1024);
        if (res.status != 200) return error.StsRefused;
        const c = try xml.parseStsCredentials(a, res.body);
        if (c.access_key_id.len == 0 or c.secret_access_key.len == 0) return error.StsRefused;
        const exp = if (db.Time.parse(c.expiration)) |t| t.toSeconds() else |_| null;
        return Snapshot.create(self.gpa, c.access_key_id, c.secret_access_key, c.session_token, exp);
    }

    fn fromContainer(self: *Provider, now_s: i64) ResolveError!bool {
        _ = now_s;
        const rel = self.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", true);
        const full = self.getenv("AWS_CONTAINER_CREDENTIALS_FULL_URI", true);
        if (rel == null and full == null) {
            self.note("container: not set", .{});
            return false;
        }
        const got = self.fetchContainer(rel, full) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.note("container: {t}", .{err});
            return false;
        };
        self.source = .container;
        self.swap(got);
        return true;
    }

    fn fetchContainer(self: *Provider, rel: ?[]const u8, full: ?[]const u8) !*Snapshot {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const url = if (full) |f| f else try std.fmt.allocPrint(a, "http://169.254.170.2{s}", .{rel.?});
        var token: ?[]const u8 = self.getenv("AWS_CONTAINER_AUTHORIZATION_TOKEN", true);
        if (self.getenv("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", true)) |f| {
            token = std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(self.io, f, a, .limited(16 * 1024)), " \t\r\n");
        }
        var pairs: [1]fetch.Pair = undefined;
        var n: usize = 0;
        if (token) |t| {
            pairs[0] = .{ "Authorization", t };
            n = 1;
        }
        const res = try fetch.simple(self.http, a, url, .get, pairs[0..n], null, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }, 64 * 1024);
        if (res.status != 200) return error.ContainerRefused;
        return parseRoleJson(self.gpa, a, res.body);
    }

    fn fromImds(self: *Provider, now_s: i64) ResolveError!bool {
        _ = now_s;
        if (self.getenv("AWS_EC2_METADATA_DISABLED", true)) |v| if (std.ascii.eqlIgnoreCase(v, "true")) {
            self.note("EC2 metadata: disabled", .{});
            return false;
        };
        const got = self.fetchImds() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.note("EC2 metadata: no answer in 1 s", .{});
            return false;
        };
        self.source = .imds;
        self.swap(got);
        return true;
    }

    fn fetchImds(self: *Provider) !*Snapshot {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const one_s: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
        const tok_url = try std.fmt.allocPrint(a, "{s}/latest/api/token", .{self.imds_base});
        const tok = try fetch.simple(self.http, a, tok_url, .put, &.{.{ "X-aws-ec2-metadata-token-ttl-seconds", "21600" }}, "", one_s, 1024);
        if (tok.status != 200) return error.ImdsRefused;
        const hdr: fetch.Pair = .{ "X-aws-ec2-metadata-token", tok.body };
        const list_url = try std.fmt.allocPrint(a, "{s}/latest/meta-data/iam/security-credentials/", .{self.imds_base});
        const roles = try fetch.simple(self.http, a, list_url, .get, &.{hdr}, null, one_s, 4096);
        if (roles.status != 200) return error.ImdsRefused;
        const role = std.mem.trim(u8, roles.body[0 .. std.mem.indexOfScalar(u8, roles.body, '\n') orelse roles.body.len], " \r\t");
        if (role.len == 0) return error.ImdsNoRole;
        const cred_url = try std.fmt.allocPrint(a, "{s}{s}", .{ list_url, role });
        const res = try fetch.simple(self.http, a, cred_url, .get, &.{hdr}, null, one_s, 64 * 1024);
        if (res.status != 200) return error.ImdsRefused;
        return parseRoleJson(self.gpa, a, res.body);
    }

    /// Whether the credentials are due for renewal at `now_s`.
    pub fn refreshDue(self: *Provider, now_s: i64) bool {
        const s = self.acquire() orelse return false;
        defer self.release(s);
        const exp = s.expires orelse return false;
        return now_s >= exp - renew_before_s;
    }

    /// Fetches new credentials from the source the current ones came from.
    /// A failure keeps the old ones. True when new credentials were installed.
    pub fn refreshOnce(self: *Provider, now_s: i64) bool {
        const ok = switch (self.source) {
            .web_identity => self.fromWebIdentity(now_s) catch false,
            .container => self.fromContainer(now_s) catch false,
            .imds => self.fromImds(now_s) catch false,
            else => false,
        };
        if (!ok) {
            self.refresh_failures += 1;
            log.warn("s3 \"{s}\": renewing credentials failed ({s}); keeping the old ones until they expire", .{ self.label, self.report.items });
        } else self.refresh_failures = 0;
        return ok;
    }

    /// Starts the renewal task when the credentials expire.
    pub fn start(self: *Provider) void {
        const s = self.acquire() orelse return;
        defer self.release(s);
        if (s.expires == null) return;
        placement.concurrent(&self.group, self.io, .{ .executor = 0 }, loop, .{self}) catch |err| {
            log.warn("s3 \"{s}\": no task to renew credentials ({t})", .{ self.label, err });
        };
    }

    fn loop(self: *Provider) std.Io.Cancelable!void {
        while (!self.stop.load(.acquire)) {
            const now = util.nowSeconds(self.io);
            var wait_s: i64 = 30;
            if (self.refreshDue(now)) {
                self.report.clearRetainingCapacity();
                if (!self.refreshOnce(now)) {
                    // 1 s, 2 s ... 60 s.
                    const shift: u6 = @intCast(@min(self.refresh_failures, 6));
                    wait_s = @min(60, @as(i64, 1) << shift);
                } else wait_s = 1;
            } else if (self.acquire()) |s| {
                defer self.release(s);
                if (s.expires) |e| wait_s = std.math.clamp(e - renew_before_s - now, 1, 300);
            }
            try self.io.sleep(.fromSeconds(wait_s), .awake);
        }
    }
};

const FileKeys = struct { akid: []const u8, secret: []const u8, token: ?[]const u8 };

/// The static keys of `[profile]` in an AWS credentials file.
pub fn parseCredentialsFile(text: []const u8, profile: []const u8) ?FileKeys {
    var in_profile = false;
    var akid: ?[]const u8 = null;
    var secret: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_profile = std.mem.eql(u8, std.mem.trim(u8, line[1..end], " \t"), profile);
            continue;
        }
        if (!in_profile) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "aws_access_key_id")) akid = v;
        if (std.mem.eql(u8, k, "aws_secret_access_key")) secret = v;
        if (std.mem.eql(u8, k, "aws_session_token")) token = v;
    }
    if (akid == null or secret == null) return null;
    return .{ .akid = akid.?, .secret = secret.?, .token = token };
}

const RoleJson = struct {
    AccessKeyId: []const u8 = "",
    SecretAccessKey: []const u8 = "",
    Token: []const u8 = "",
    SessionToken: []const u8 = "",
    Expiration: []const u8 = "",
};

fn parseRoleJson(gpa: std.mem.Allocator, arena: std.mem.Allocator, body: []const u8) !*Snapshot {
    const j = try std.json.parseFromSliceLeaky(RoleJson, arena, body, .{ .ignore_unknown_fields = true });
    if (j.AccessKeyId.len == 0 or j.SecretAccessKey.len == 0) return error.NoKeysInAnswer;
    const token = if (j.Token.len > 0) j.Token else j.SessionToken;
    const exp = if (db.Time.parse(j.Expiration)) |t| t.toSeconds() else |_| null;
    return Snapshot.create(gpa, j.AccessKeyId, j.SecretAccessKey, token, exp);
}

const testing = std.testing;

test "credentials: a profile in the shared file" {
    const text =
        \\[default]
        \\aws_access_key_id = AKDEFAULT
        \\aws_secret_access_key = sdefault
        \\
        \\[work]
        \\aws_access_key_id=AKWORK
        \\aws_secret_access_key=swork
        \\aws_session_token=twork
    ;
    const w = parseCredentialsFile(text, "work").?;
    try testing.expectEqualStrings("AKWORK", w.akid);
    try testing.expectEqualStrings("twork", w.token.?);
    try testing.expectEqualStrings("AKDEFAULT", parseCredentialsFile(text, "default").?.akid);
    try testing.expect(parseCredentialsFile(text, "other") == null);
}

test "credentials: the role JSON of IMDS and container endpoints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try parseRoleJson(testing.allocator, arena.allocator(), "{\"Code\":\"Success\",\"AccessKeyId\":\"AK\",\"SecretAccessKey\":\"S\",\"Token\":\"T\",\"Expiration\":\"2026-10-23T11:00:00Z\"}");
    defer s.destroy();
    try testing.expectEqualStrings("T", s.token.?);
    try testing.expect(s.expires.? > 1_700_000_000);
}

test "credentials: refresh is due five minutes before expiry; a failed refresh keeps the old keys" {
    var http = dusty.Client.init(testing.allocator, testing.io, .{});
    defer http.deinit();
    var p: Provider = .{ .gpa = testing.allocator, .io = testing.io, .http = &http, .label = "t", .environ = null, .is_aws = true, .region = "us-east-1" };
    defer p.deinit();
    p.swap(try Snapshot.create(testing.allocator, "AK", "S", "T", 10_000));
    p.source = .container;
    try testing.expect(!p.refreshDue(10_000 - renew_before_s - 1));
    try testing.expect(p.refreshDue(10_000 - renew_before_s));
    // No container variables: the refresh fails and the old keys stay.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    p.env = .{ .get_fn = struct {
        fn none(_: ?*const anyopaque, _: ?std.process.Environ, _: []const u8, _: bool) ?[]const u8 {
            return null;
        }
    }.none };
    try testing.expect(!p.refreshOnce(10_000));
    const s = p.acquire().?;
    defer p.release(s);
    try testing.expectEqualStrings("AK", s.access_key_id);
}

test "credentials: missing everything lists every source" {
    var http = dusty.Client.init(testing.allocator, testing.io, .{});
    defer http.deinit();
    var p: Provider = .{ .gpa = testing.allocator, .io = testing.io, .http = &http, .label = "t", .environ = null, .is_aws = true, .region = "us-east-1", .file_path = "/nonexistent/anole/credentials" };
    defer p.deinit();
    p.env = .{ .get_fn = struct {
        fn only(_: ?*const anyopaque, _: ?std.process.Environ, name: []const u8, _: bool) ?[]const u8 {
            if (std.mem.eql(u8, name, "AWS_EC2_METADATA_DISABLED")) return "true";
            return null;
        }
    }.only };
    try testing.expectError(error.NoCredentials, p.resolve(0));
    const r = p.report.items;
    try testing.expect(std.mem.indexOf(u8, r, "environment: AWS_ACCESS_KEY_ID not set") != null);
    try testing.expect(std.mem.indexOf(u8, r, "web identity: AWS_WEB_IDENTITY_TOKEN_FILE not set") != null);
    try testing.expect(std.mem.indexOf(u8, r, "container: not set") != null);
    try testing.expect(std.mem.indexOf(u8, r, "EC2 metadata") != null);
}

test "credentials: environment keys" {
    var http = dusty.Client.init(testing.allocator, testing.io, .{});
    defer http.deinit();
    var p: Provider = .{ .gpa = testing.allocator, .io = testing.io, .http = &http, .label = "t", .environ = null, .is_aws = false, .region = "us-east-1" };
    defer p.deinit();
    p.env = .{ .get_fn = struct {
        fn some(_: ?*const anyopaque, _: ?std.process.Environ, name: []const u8, _: bool) ?[]const u8 {
            if (std.mem.eql(u8, name, "AWS_ACCESS_KEY_ID")) return "AKENV";
            if (std.mem.eql(u8, name, "AWS_SECRET_ACCESS_KEY")) return "senv";
            return null;
        }
    }.some };
    try p.resolve(0);
    const s = p.acquire().?;
    defer p.release(s);
    try testing.expectEqualStrings("AKENV", s.access_key_id);
    try testing.expect(s.token == null);
}
