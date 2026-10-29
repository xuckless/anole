//! AWS Signature Version 4 for S3: header signing and presigned URLs.
//!
//! No candidate library fits (research: design-connectors.md section 1.1),
//! so this is written from the specification
//! (https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html).
//! The canonical request is hashed as it is written, so nothing here
//! allocates and no request is too long to sign; a request with more than
//! `max_headers` headers is refused.
const std = @import("std");
const util = @import("util.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Pair = [2][]const u8;

/// Most headers a request signs, the ones the signer adds included.
pub const max_headers = 40;
/// Most query parameters a request signs.
pub const max_query = 24;

pub const algorithm = "AWS4-HMAC-SHA256";
pub const unsigned_payload = "UNSIGNED-PAYLOAD";
/// SHA-256 of the empty string, hex.
pub const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

pub const Keys = struct {
    access_key_id: []const u8,
    secret: []const u8,
    token: ?[]const u8 = null,
};

pub const PayloadHash = union(enum) {
    unsigned,
    empty,
    sha256: [32]u8,

    /// The hash of `bytes`.
    pub fn of(bytes: []const u8) PayloadHash {
        var d: [32]u8 = undefined;
        Sha256.hash(bytes, &d, .{});
        return .{ .sha256 = d };
    }

    /// The value of `x-amz-content-sha256`; `buf` holds the hex.
    pub fn text(self: PayloadHash, buf: *[64]u8) []const u8 {
        return switch (self) {
            .unsigned => unsigned_payload,
            .empty => empty_sha256,
            .sha256 => |d| std.fmt.bufPrint(buf, "{x}", .{&d}) catch unreachable,
        };
    }
};

/// What is signed. `query` holds raw names and values (the signer encodes
/// them); `canonical_uri` is already encoded, as it is sent.
pub const Request = struct {
    method: []const u8,
    host: []const u8,
    canonical_uri: []const u8,
    query: []const Pair = &.{},
    payload_hash: PayloadHash = .unsigned,
    /// `presign` only: headers that are signed too (and must then be sent
    /// by the browser exactly as given), such as content-type and
    /// content-length.
    headers: []const Pair = &.{},
};

/// The headers of a request being built, with room for what the signer
/// adds (x-amz-date, x-amz-content-sha256, x-amz-security-token and
/// Authorization). Names and values are borrowed, except what `put` copies
/// into `scratch`.
pub const HeaderList = struct {
    items: [max_headers]Pair = undefined,
    len: usize = 0,
    scratch: [2048]u8 = undefined,
    used: usize = 0,

    pub fn add(self: *HeaderList, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (self.len >= self.items.len) return error.TooManyHeaders;
        self.items[self.len] = .{ name, value };
        self.len += 1;
    }

    /// Copies `value` into the list's own storage, then adds it.
    pub fn addCopy(self: *HeaderList, name: []const u8, value: []const u8) error{ TooManyHeaders, NoSpace }!void {
        if (self.used + value.len > self.scratch.len) return error.NoSpace;
        const dst = self.scratch[self.used..][0..value.len];
        @memcpy(dst, value);
        self.used += value.len;
        try self.add(name, dst);
    }

    pub fn slice(self: *const HeaderList) []const Pair {
        return self.items[0..self.len];
    }

    pub fn get(self: *const HeaderList, name: []const u8) ?[]const u8 {
        for (self.slice()) |h| if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
        return null;
    }
};

/// Signs requests for one region and service. Shared by every executor.
pub const Signer = struct {
    region: []const u8,
    service: []const u8 = "s3",
    lock: std.atomic.Mutex = .unlocked,
    cached_day: i64 = -1,
    cached_secret: u64 = 0,
    cached_key: [32]u8 = undefined,
    /// How many times a signing key was derived (a test hook).
    derivations: std.atomic.Value(u32) = .init(0),

    pub fn init(region: []const u8) Signer {
        return .{ .region = region };
    }

    /// The signing key for `day` (days since the epoch), derived at most
    /// once per day and secret.
    pub fn signingKey(s: *Signer, secret: []const u8, day: i64, date: []const u8) [32]u8 {
        const tag = std.hash.Wyhash.hash(0x53334b, secret);
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
        defer s.lock.unlock();
        if (s.cached_day == day and s.cached_secret == tag) return s.cached_key;
        var k_secret: [4 + 256]u8 = undefined;
        const n = @min(secret.len, 256);
        @memcpy(k_secret[0..4], "AWS4");
        @memcpy(k_secret[4..][0..n], secret[0..n]);
        var k_date: [32]u8 = undefined;
        Hmac.create(&k_date, date, k_secret[0 .. 4 + n]);
        var k_region: [32]u8 = undefined;
        Hmac.create(&k_region, s.region, &k_date);
        var k_service: [32]u8 = undefined;
        Hmac.create(&k_service, s.service, &k_region);
        Hmac.create(&s.cached_key, "aws4_request", &k_service);
        s.cached_day = day;
        s.cached_secret = tag;
        _ = s.derivations.fetchAdd(1, .monotonic);
        std.crypto.secureZero(u8, &k_secret);
        return s.cached_key;
    }

    /// Adds `x-amz-date`, `x-amz-content-sha256`, `x-amz-security-token`
    /// (when the keys have a token) and `Authorization` to `headers`. Signs
    /// `host` and every header in the list except user-agent,
    /// accept-encoding, connection, content-length, expect and
    /// transfer-encoding.
    pub fn sign(s: *Signer, keys: Keys, now_s: i64, req: Request, headers: *HeaderList) error{ TooManyHeaders, NoSpace }!void {
        var stamp: Stamp = undefined;
        stamp.set(now_s);
        var hash_buf: [64]u8 = undefined;
        const payload = req.payload_hash.text(&hash_buf);
        try headers.addCopy("x-amz-content-sha256", payload);
        try headers.addCopy("x-amz-date", stamp.amz());
        if (keys.token) |t| try headers.add("x-amz-security-token", t);

        var names: [max_headers + 1]Pair = undefined;
        var n: usize = 0;
        names[n] = .{ "host", req.host };
        n += 1;
        for (headers.slice()) |h| {
            if (excluded(h[0])) continue;
            names[n] = h;
            n += 1;
        }
        const list = names[0..n];
        const order = sortedOrder(list);

        var hash: Sha256 = .init(.{});
        var w = HashWriter.init(&hash);
        try w.writeAll(req.method);
        try w.writeAll("\n");
        try w.writeAll(req.canonical_uri);
        try w.writeAll("\n");
        try writeQueryTo(&w, req.query);
        try w.writeAll("\n");
        for (order[0..n]) |i| {
            try w.writeLower(list[i][0]);
            try w.writeAll(":");
            try w.writeTrimmed(list[i][1]);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
        for (order[0..n], 0..) |i, k| {
            if (k > 0) try w.writeAll(";");
            try w.writeLower(list[i][0]);
        }
        try w.writeAll("\n");
        try w.writeAll(payload);
        var canonical: [32]u8 = undefined;
        hash.final(&canonical);

        const sts = stringToSign(&stamp, s, &canonical);
        const key = s.signingKey(keys.secret, @divFloor(now_s, std.time.s_per_day), stamp.date());
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, sts.slice(), &key);

        // Authorization: Credential, SignedHeaders and Signature.
        var auth: [1024]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&auth);
        aw.print("{s} Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders=", .{ algorithm, keys.access_key_id, stamp.date(), s.region, s.service }) catch return error.NoSpace;
        for (order[0..n], 0..) |i, k| {
            if (k > 0) aw.writeByte(';') catch return error.NoSpace;
            for (list[i][0]) |ch| aw.writeByte(std.ascii.toLower(ch)) catch return error.NoSpace;
        }
        aw.print(", Signature={x}", .{&sig}) catch return error.NoSpace;
        try headers.addCopy("Authorization", aw.buffered());
    }

    /// Writes the query string of a presigned URL (without the `?`): the
    /// request's own parameters, `X-Amz-*`, and the signature last.
    /// `req.headers` are signed and must be sent by whoever uses the URL.
    pub fn presign(s: *Signer, keys: Keys, now_s: i64, req: Request, expires_s: u32, out: *std.Io.Writer) !void {
        var stamp: Stamp = undefined;
        stamp.set(now_s);

        var cred_buf: [512]u8 = undefined;
        const credential = std.fmt.bufPrint(&cred_buf, "{s}/{s}/{s}/{s}/aws4_request", .{ keys.access_key_id, stamp.date(), s.region, s.service }) catch return error.NoSpace;
        var exp_buf: [16]u8 = undefined;
        const expires = std.fmt.bufPrint(&exp_buf, "{d}", .{expires_s}) catch unreachable;

        var names: [max_headers + 1]Pair = undefined;
        var n: usize = 0;
        names[n] = .{ "host", req.host };
        n += 1;
        for (req.headers) |h| {
            if (n >= names.len) return error.TooManyHeaders;
            names[n] = h;
            n += 1;
        }
        const list = names[0..n];
        const order = sortedOrder(list);
        var signed_buf: [512]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&signed_buf);
        for (order[0..n], 0..) |i, k| {
            if (k > 0) sw.writeByte(';') catch return error.NoSpace;
            for (list[i][0]) |ch| sw.writeByte(std.ascii.toLower(ch)) catch return error.NoSpace;
        }
        const signed_headers = sw.buffered();

        var query: [max_query + 6]Pair = undefined;
        var q: usize = 0;
        for (req.query) |p| {
            if (q >= max_query) return error.TooManyHeaders;
            query[q] = p;
            q += 1;
        }
        const amz: [5]Pair = .{
            .{ "X-Amz-Algorithm", algorithm },
            .{ "X-Amz-Credential", credential },
            .{ "X-Amz-Date", stamp.amz() },
            .{ "X-Amz-Expires", expires },
            .{ "X-Amz-SignedHeaders", signed_headers },
        };
        for (amz) |p| {
            query[q] = p;
            q += 1;
        }
        if (keys.token) |t| {
            query[q] = .{ "X-Amz-Security-Token", t };
            q += 1;
        }

        var hash: Sha256 = .init(.{});
        var w = HashWriter.init(&hash);
        try w.writeAll(req.method);
        try w.writeAll("\n");
        try w.writeAll(req.canonical_uri);
        try w.writeAll("\n");
        try writeQueryTo(&w, query[0..q]);
        try w.writeAll("\n");
        for (order[0..n]) |i| {
            try w.writeLower(list[i][0]);
            try w.writeAll(":");
            try w.writeTrimmed(list[i][1]);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
        try w.writeAll(signed_headers);
        try w.writeAll("\n");
        try w.writeAll(unsigned_payload);
        var canonical: [32]u8 = undefined;
        hash.final(&canonical);

        const sts = stringToSign(&stamp, s, &canonical);
        const key = s.signingKey(keys.secret, @divFloor(now_s, std.time.s_per_day), stamp.date());
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, sts.slice(), &key);

        try writeQuery(out, query[0..q]);
        try out.print("&X-Amz-Signature={x}", .{&sig});
    }
};

fn excluded(name: []const u8) bool {
    inline for (.{ "user-agent", "accept-encoding", "connection", "content-length", "expect", "transfer-encoding", "authorization", "x-amzn-trace-id" }) |x| {
        if (std.ascii.eqlIgnoreCase(name, x)) return true;
    }
    return false;
}

/// Indices of `list` sorted by lower-cased name.
fn sortedOrder(list: []const Pair) [max_headers + 1]u8 {
    var order: [max_headers + 1]u8 = undefined;
    for (0..list.len) |i| order[i] = @intCast(i);
    const Ctx = struct {
        list: []const Pair,
        fn less(c: @This(), a: u8, b: u8) bool {
            return lowerOrder(c.list[a][0], c.list[b][0]) == .lt;
        }
    };
    std.sort.insertion(u8, order[0..list.len], Ctx{ .list = list }, Ctx.less);
    return order;
}

fn lowerOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return std.math.order(x, y);
    }
    return std.math.order(a.len, b.len);
}

/// The date of a signature in its two forms.
const Stamp = struct {
    buf: [16]u8,

    fn set(self: *Stamp, now_s: i64) void {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now_s, 0)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        _ = std.fmt.bufPrint(&self.buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            yd.year,              md.month.numeric(),      md.day_index + 1,
            ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch unreachable;
    }

    fn amz(self: *const Stamp) []const u8 {
        return self.buf[0..16];
    }

    fn date(self: *const Stamp) []const u8 {
        return self.buf[0..8];
    }
};

const Sts = struct {
    buf: [256]u8,
    len: usize,
    fn slice(self: *const Sts) []const u8 {
        return self.buf[0..self.len];
    }
};

fn stringToSign(stamp: *const Stamp, s: *const Signer, canonical_hash: *const [32]u8) Sts {
    var out: Sts = undefined;
    const text = std.fmt.bufPrint(&out.buf, "{s}\n{s}\n{s}/{s}/{s}/aws4_request\n{x}", .{ algorithm, stamp.amz(), stamp.date(), s.region, s.service, canonical_hash }) catch unreachable;
    out.len = text.len;
    return out;
}

/// Feeds the canonical request to the hash.
const HashWriter = struct {
    hash: *Sha256,

    fn init(h: *Sha256) HashWriter {
        return .{ .hash = h };
    }

    fn writeAll(self: *HashWriter, bytes: []const u8) !void {
        self.hash.update(bytes);
    }

    fn writeLower(self: *HashWriter, bytes: []const u8) !void {
        for (bytes) |ch| self.hash.update(&.{std.ascii.toLower(ch)});
    }

    /// A header value: leading and trailing blanks removed, runs of inner
    /// blanks collapsed to one space.
    fn writeTrimmed(self: *HashWriter, bytes: []const u8) !void {
        const t = std.mem.trim(u8, bytes, " \t");
        var in_blank = false;
        for (t) |ch| {
            if (ch == ' ' or ch == '\t') {
                if (!in_blank) self.hash.update(" ");
                in_blank = true;
            } else {
                in_blank = false;
                self.hash.update(&.{ch});
            }
        }
    }
};

/// Whether `ch` is left alone by `uriEncode`.
pub fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// SigV4's URI encoding: unreserved bytes (and `/` when `keep_slash`) as
/// they are, every other byte as `%XX` in upper case.
pub fn uriEncode(w: *std.Io.Writer, bytes: []const u8, keep_slash: bool) std.Io.Writer.Error!void {
    for (bytes) |ch| {
        if (isUnreserved(ch) or (keep_slash and ch == '/')) {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

fn encodedLen(bytes: []const u8, keep_slash: bool) usize {
    var n: usize = 0;
    for (bytes) |ch| n += if (isUnreserved(ch) or (keep_slash and ch == '/')) 1 else 3;
    return n;
}

fn pairLess(_: void, a: Pair, b: Pair) bool {
    const o = std.mem.order(u8, a[0], b[0]);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a[1], b[1]) == .lt;
}

/// Writes the canonical query string: names and values encoded, sorted by
/// name and then value, an empty value keeping its `=`. Sorting is by the
/// raw bytes, which orders the same as the encoded ones for the names S3
/// uses.
pub fn writeQuery(w: *std.Io.Writer, query: []const Pair) !void {
    if (query.len == 0) return;
    var sorted: [max_query + 8]Pair = undefined;
    if (query.len > sorted.len) return error.TooManyHeaders;
    @memcpy(sorted[0..query.len], query);
    std.sort.insertion(Pair, sorted[0..query.len], {}, pairLess);
    for (sorted[0..query.len], 0..) |p, i| {
        if (i > 0) try w.writeByte('&');
        try uriEncode(w, p[0], false);
        try w.writeByte('=');
        try uriEncode(w, p[1], false);
    }
}

fn writeQueryTo(hw: *HashWriter, query: []const Pair) !void {
    if (query.len == 0) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeQuery(&w, query) catch return error.NoSpace;
    try hw.writeAll(w.buffered());
}

pub fn encodedKeyLen(key: []const u8) usize {
    return encodedLen(key, true);
}

// ---------------------------------------------------------------------------
// Tests. The examples are the worked ones on AWS's S3 API reference pages:
// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
// https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html

const testing = std.testing;

const example_keys: Keys = .{ .access_key_id = "AKIAIOSFODNN7EXAMPLE", .secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" };
// 2013-05-24T00:00:00Z
const example_time: i64 = 1369353600;

fn authSignature(h: *const HeaderList) []const u8 {
    const a = h.get("Authorization").?;
    return a[std.mem.lastIndexOf(u8, a, "Signature=").? + "Signature=".len ..];
}

test "sigv4: the S3 API reference's header-auth example, GET Object with a Range" {
    var s: Signer = .init("us-east-1");
    var h: HeaderList = .{};
    try h.add("Range", "bytes=0-9");
    try s.sign(example_keys, example_time, .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .canonical_uri = "/test.txt",
        .payload_hash = .empty,
    }, &h);
    try testing.expectEqualStrings("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", authSignature(&h));
    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        h.get("Authorization").?,
    );
}

test "sigv4: PUT Object with a signed date header and a storage class" {
    var s: Signer = .init("us-east-1");
    var h: HeaderList = .{};
    try h.add("Date", "Fri, 24 May 2013 00:00:00 GMT");
    try h.add("x-amz-storage-class", "REDUCED_REDUNDANCY");
    try s.sign(example_keys, example_time, .{
        .method = "PUT",
        .host = "examplebucket.s3.amazonaws.com",
        .canonical_uri = "/test%24file.text",
        .payload_hash = .of("Welcome to Amazon S3."),
    }, &h);
    try testing.expectEqualStrings("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", authSignature(&h));
}

test "sigv4: GET Bucket Lifecycle (a sub-resource with an empty value)" {
    var s: Signer = .init("us-east-1");
    var h: HeaderList = .{};
    try s.sign(example_keys, example_time, .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .canonical_uri = "/",
        .query = &.{.{ "lifecycle", "" }},
        .payload_hash = .empty,
    }, &h);
    try testing.expectEqualStrings("fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543", authSignature(&h));
}

test "sigv4: GET Bucket (List Objects) with two parameters" {
    var s: Signer = .init("us-east-1");
    var h: HeaderList = .{};
    try s.sign(example_keys, example_time, .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .canonical_uri = "/",
        .query = &.{ .{ "prefix", "J" }, .{ "max-keys", "2" } },
        .payload_hash = .empty,
    }, &h);
    try testing.expectEqualStrings("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", authSignature(&h));
}

test "sigv4: the presigned GET example" {
    var s: Signer = .init("us-east-1");
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.presign(example_keys, example_time, .{
        .method = "GET",
        .host = "examplebucket.s3.amazonaws.com",
        .canonical_uri = "/test.txt",
    }, 86400, &w);
    try testing.expectEqualStrings(
        "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
        w.buffered(),
    );
}

test "sigv4: uriEncode keeps unreserved bytes and the slash, encodes the rest" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try uriEncode(&w, "a b+c~d/e:f", true);
    try testing.expectEqualStrings("a%20b%2Bc~d/e%3Af", w.buffered());
    w = .fixed(&buf);
    try uriEncode(&w, "a/b", false);
    try testing.expectEqualStrings("a%2Fb", w.buffered());
    w = .fixed(&buf);
    try uriEncode(&w, "\xc3\xa9", true);
    try testing.expectEqualStrings("%C3%A9", w.buffered());
}

test "sigv4: the canonical query sorts by name then value; empty values keep the equals sign" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeQuery(&w, &.{ .{ "b", "2" }, .{ "a", "z" }, .{ "a", "y" }, .{ "c", "" } });
    try testing.expectEqualStrings("a=y&a=z&b=2&c=", w.buffered());
}

test "sigv4: header values are trimmed and inner blanks collapsed; user-agent is not signed" {
    var s: Signer = .init("us-east-1");
    var a: HeaderList = .{};
    try a.add("x-amz-meta-note", "  two   words ");
    try a.add("User-Agent", "one");
    var b: HeaderList = .{};
    try b.add("x-amz-meta-note", "two words");
    try b.add("User-Agent", "another");
    const req: Request = .{ .method = "PUT", .host = "h", .canonical_uri = "/k", .payload_hash = .unsigned };
    try s.sign(example_keys, example_time, req, &a);
    try s.sign(example_keys, example_time, req, &b);
    try testing.expectEqualStrings(authSignature(&a), authSignature(&b));
    try testing.expect(std.mem.indexOf(u8, a.get("Authorization").?, "user-agent") == null);
}

test "sigv4: a signer reused across a UTC day boundary signs with the new day's key" {
    const req: Request = .{ .method = "GET", .host = "h", .canonical_uri = "/" };
    var reused: Signer = .init("us-east-1");
    for ([_]i64{ example_time, example_time + 1, example_time + 86400 }) |t| {
        var got: HeaderList = .{};
        try reused.sign(example_keys, t, req, &got);
        var fresh: Signer = .init("us-east-1");
        var want: HeaderList = .{};
        try fresh.sign(example_keys, t, req, &want);
        try testing.expectEqualStrings(want.get("Authorization").?, got.get("Authorization").?);
    }
}

test "sigv4: a session token is signed into the header, and into the query for a presign" {
    var s: Signer = .init("us-east-1");
    var keys = example_keys;
    keys.token = "TOKEN+/=";
    var h: HeaderList = .{};
    try s.sign(keys, example_time, .{ .method = "GET", .host = "h", .canonical_uri = "/" }, &h);
    try testing.expectEqualStrings("TOKEN+/=", h.get("x-amz-security-token").?);
    try testing.expect(std.mem.indexOf(u8, h.get("Authorization").?, "x-amz-security-token") != null);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.presign(keys, example_time, .{ .method = "GET", .host = "h", .canonical_uri = "/" }, 60, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "X-Amz-Security-Token=TOKEN%2B%2F%3D") != null);
}
