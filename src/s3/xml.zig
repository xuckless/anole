//! A small XML pull reader and the response shapes S3 (and STS) answer with.
//!
//! Built rather than adopted (design-connectors.md section 1.1): S3 needs
//! six fixed shapes and no DTDs. The reader handles elements (attributes
//! are skipped), text with the five entities and numeric references,
//! CDATA, comments and the XML declaration. A DOCTYPE or an entity
//! declaration is refused (no XXE), unbalanced tags are an error, and every
//! slice it returns lies in the input or in the arena it was given.
const std = @import("std");

pub const Error = error{ Malformed, DoctypeRefused, TooDeep, OutOfMemory };

pub const max_depth = 32;

pub const Token = union(enum) {
    start: []const u8,
    end: []const u8,
    text: []const u8,
};

pub const Reader = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    stack: [max_depth][]const u8 = undefined,
    depth: usize = 0,
    /// A self-closing tag's end waiting to be returned.
    pending_end: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Reader {
        return .{ .src = src, .arena = arena };
    }

    /// The names of the open elements, outermost first.
    pub fn path(self: *const Reader) []const []const u8 {
        return self.stack[0..self.depth];
    }

    /// The next token, or null at the end of a balanced document.
    pub fn next(self: *Reader) Error!?Token {
        if (self.pending_end) |name| {
            self.pending_end = null;
            return .{ .end = name };
        }
        while (true) {
            if (self.pos >= self.src.len) {
                if (self.depth != 0) return error.Malformed;
                return null;
            }
            if (self.src[self.pos] != '<') {
                const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
                const raw = self.src[self.pos..end];
                self.pos = end;
                if (self.depth == 0) {
                    if (std.mem.trim(u8, raw, " \t\r\n\xef\xbb\xbf").len != 0) return error.Malformed;
                    continue;
                }
                return .{ .text = try self.decode(raw) };
            }
            const rest = self.src[self.pos..];
            if (std.mem.startsWith(u8, rest, "<?")) {
                const e = std.mem.find(u8, rest, "?>") orelse return error.Malformed;
                self.pos += e + 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const e = std.mem.find(u8, rest[4..], "-->") orelse return error.Malformed;
                self.pos += 4 + e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const e = std.mem.find(u8, rest[9..], "]]>") orelse return error.Malformed;
                const text = rest[9..][0..e];
                self.pos += 9 + e + 3;
                if (self.depth == 0) return error.Malformed;
                return .{ .text = text };
            }
            if (std.mem.startsWith(u8, rest, "<!")) {
                // <!DOCTYPE and <!ENTITY, or anything else declared.
                return error.DoctypeRefused;
            }
            if (std.mem.startsWith(u8, rest, "</")) {
                const e = std.mem.indexOfScalar(u8, rest, '>') orelse return error.Malformed;
                const name = localName(std.mem.trim(u8, rest[2..e], " \t\r\n"));
                if (self.depth == 0 or !std.mem.eql(u8, self.stack[self.depth - 1], name)) return error.Malformed;
                self.depth -= 1;
                self.pos += e + 1;
                return .{ .end = name };
            }
            // A start tag: name, attributes (skipped), maybe `/`.
            var i: usize = 1;
            while (i < rest.len and !isSpace(rest[i]) and rest[i] != '>' and rest[i] != '/') : (i += 1) {}
            if (i == 1 or i >= rest.len) return error.Malformed;
            const name = localName(rest[1..i]);
            var quote: u8 = 0;
            while (i < rest.len) : (i += 1) {
                const ch = rest[i];
                if (quote != 0) {
                    if (ch == quote) quote = 0;
                } else if (ch == '"' or ch == '\'') {
                    quote = ch;
                } else if (ch == '>') break;
            } else return error.Malformed;
            const self_closing = rest[i - 1] == '/';
            self.pos += i + 1;
            if (self.depth >= max_depth) return error.TooDeep;
            self.stack[self.depth] = name;
            self.depth += 1;
            if (self_closing) {
                self.depth -= 1;
                self.pending_end = name;
            }
            return .{ .start = name };
        }
    }

    fn decode(self: *Reader, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(self.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.Malformed;
            const ent = raw[i + 1 .. semi];
            i = semi + 1;
            if (std.mem.eql(u8, ent, "amp")) {
                try out.append(self.arena, '&');
            } else if (std.mem.eql(u8, ent, "lt")) {
                try out.append(self.arena, '<');
            } else if (std.mem.eql(u8, ent, "gt")) {
                try out.append(self.arena, '>');
            } else if (std.mem.eql(u8, ent, "quot")) {
                try out.append(self.arena, '"');
            } else if (std.mem.eql(u8, ent, "apos")) {
                try out.append(self.arena, '\'');
            } else if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x' or ent[1] == 'X')
                    std.fmt.parseInt(u21, ent[2..], 16)
                else
                    std.fmt.parseInt(u21, ent[1..], 10)) catch return error.Malformed;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.Malformed;
                try out.appendSlice(self.arena, buf[0..n]);
            } else return error.Malformed;
        }
        return out.items;
    }
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |c| return name[c + 1 ..];
    return name;
}

/// What `walk` reports.
pub const Event = union(enum) {
    /// An element opened; `path` ends with its name.
    open,
    /// An element's text (its first text node, trimmed of nothing).
    leaf: []const u8,
    close,
};

/// Runs the reader over `src`, calling `cb(ctx, path, event)` for each
/// element. Text in elements that also have children is ignored.
pub fn walk(arena: std.mem.Allocator, src: []const u8, ctx: anytype, comptime cb: anytype) !void {
    var r = Reader.init(arena, src);
    var text: ?[]const u8 = null;
    var had_child: [max_depth]bool = @splat(false);
    while (try r.next()) |tok| switch (tok) {
        .start => {
            if (r.depth >= 2) had_child[r.depth - 2] = true;
            had_child[r.depth - 1] = false;
            text = null;
            try cb(ctx, r.path(), Event.open);
        },
        .text => |t| {
            if (text == null) text = t else if (t.len > 0) {
                text = try std.mem.concat(arena, u8, &.{ text.?, t });
            }
        },
        .end => {
            // `r.depth` is already decremented for a real end tag; the path
            // for the close event includes the closing element.
            const full = r.stack[0 .. r.depth + 1];
            if (!had_child[r.depth]) try cb(ctx, full, Event{ .leaf = text orelse "" });
            try cb(ctx, full, Event.close);
            text = null;
        },
    };
}

// ---------------------------------------------------------------------------
// Shapes

pub const ErrorBody = struct {
    code: []const u8 = "",
    message: []const u8 = "",
    request_id: []const u8 = "",
    /// PermanentRedirect and AuthorizationHeaderMalformed name the region.
    region: []const u8 = "",
    endpoint: []const u8 = "",
};

/// `<Error>...`, or null when the document is not one.
pub fn parseError(arena: std.mem.Allocator, src: []const u8) ?ErrorBody {
    const Ctx = struct {
        body: ErrorBody = .{},
        is_error: bool = false,
        fn cb(c: *@This(), path: []const []const u8, ev: Event) !void {
            switch (ev) {
                .open => if (path.len == 1) {
                    c.is_error = std.mem.eql(u8, path[0], "Error");
                },
                .leaf => |t| if (path.len == 2 and c.is_error) {
                    const n = path[1];
                    if (std.mem.eql(u8, n, "Code")) c.body.code = t;
                    if (std.mem.eql(u8, n, "Message")) c.body.message = t;
                    if (std.mem.eql(u8, n, "RequestId")) c.body.request_id = t;
                    if (std.mem.eql(u8, n, "Region")) c.body.region = t;
                    if (std.mem.eql(u8, n, "Endpoint")) c.body.endpoint = t;
                },
                .close => {},
            }
        }
    };
    var c: Ctx = .{};
    walk(arena, src, &c, Ctx.cb) catch return null;
    if (!c.is_error) return null;
    return c.body;
}

pub const Entry = struct {
    key: []const u8 = "",
    size: u64 = 0,
    etag: []const u8 = "",
    last_modified: ?[]const u8 = null,
    storage_class: ?[]const u8 = null,
};

pub const ListResult = struct {
    entries: []const Entry,
    prefixes: []const []const u8,
    truncated: bool,
    next: ?[]const u8,
};

/// ListObjectsV2. With `url_encoded` (the request asked for
/// `encoding-type=url`) keys, prefixes and the continuation hints are
/// percent-decoded, `+` meaning a space.
pub fn parseListObjects(arena: std.mem.Allocator, src: []const u8, url_encoded: bool) Error!ListResult {
    const Ctx = struct {
        arena: std.mem.Allocator,
        url: bool,
        entries: std.ArrayList(Entry) = .empty,
        prefixes: std.ArrayList([]const u8) = .empty,
        truncated: bool = false,
        next: ?[]const u8 = null,
        cur: Entry = .{},
        fn dec(c: *@This(), t: []const u8) ![]const u8 {
            return if (c.url) urlDecode(c.arena, t) else t;
        }
        fn cb(c: *@This(), path: []const []const u8, ev: Event) !void {
            const last = path[path.len - 1];
            switch (ev) {
                .open => if (path.len == 2 and std.mem.eql(u8, last, "Contents")) {
                    c.cur = .{};
                },
                .close => if (path.len == 2 and std.mem.eql(u8, last, "Contents")) {
                    try c.entries.append(c.arena, c.cur);
                },
                .leaf => |t| {
                    if (path.len == 2) {
                        if (std.mem.eql(u8, last, "IsTruncated")) c.truncated = std.mem.eql(u8, t, "true");
                        if (std.mem.eql(u8, last, "NextContinuationToken")) c.next = t;
                    } else if (path.len == 3 and std.mem.eql(u8, path[1], "Contents")) {
                        if (std.mem.eql(u8, last, "Key")) c.cur.key = try c.dec(t);
                        if (std.mem.eql(u8, last, "Size")) c.cur.size = std.fmt.parseInt(u64, t, 10) catch 0;
                        if (std.mem.eql(u8, last, "ETag")) c.cur.etag = t;
                        if (std.mem.eql(u8, last, "LastModified")) c.cur.last_modified = t;
                        if (std.mem.eql(u8, last, "StorageClass")) c.cur.storage_class = t;
                    } else if (path.len == 3 and std.mem.eql(u8, path[1], "CommonPrefixes") and std.mem.eql(u8, last, "Prefix")) {
                        try c.prefixes.append(c.arena, try c.dec(t));
                    }
                },
            }
        }
    };
    var c: Ctx = .{ .arena = arena, .url = url_encoded };
    try walk(arena, src, &c, Ctx.cb);
    return .{ .entries = c.entries.items, .prefixes = c.prefixes.items, .truncated = c.truncated, .next = c.next };
}

/// The text of the first element called `name` at any depth, or null.
pub fn firstText(arena: std.mem.Allocator, src: []const u8, name: []const u8) Error!?[]const u8 {
    const Ctx = struct {
        name: []const u8,
        found: ?[]const u8 = null,
        fn cb(c: *@This(), path: []const []const u8, ev: Event) !void {
            switch (ev) {
                .leaf => |t| if (c.found == null and std.mem.eql(u8, path[path.len - 1], c.name)) {
                    c.found = t;
                },
                else => {},
            }
        }
    };
    var c: Ctx = .{ .name = name };
    try walk(arena, src, &c, Ctx.cb);
    return c.found;
}

pub const Failure = struct { key: []const u8, code: []const u8, message: []const u8 };

pub const DeleteResult = struct { deleted: u32, failures: []const Failure };

pub fn parseDeleteResult(arena: std.mem.Allocator, src: []const u8) Error!DeleteResult {
    const Ctx = struct {
        arena: std.mem.Allocator,
        deleted: u32 = 0,
        failures: std.ArrayList(Failure) = .empty,
        cur: Failure = .{ .key = "", .code = "", .message = "" },
        fn cb(c: *@This(), path: []const []const u8, ev: Event) !void {
            const last = path[path.len - 1];
            switch (ev) {
                .open => if (path.len == 2 and std.mem.eql(u8, last, "Error")) {
                    c.cur = .{ .key = "", .code = "", .message = "" };
                },
                .close => if (path.len == 2) {
                    if (std.mem.eql(u8, last, "Deleted")) c.deleted += 1;
                    if (std.mem.eql(u8, last, "Error")) try c.failures.append(c.arena, c.cur);
                },
                .leaf => |t| if (path.len == 3 and std.mem.eql(u8, path[1], "Error")) {
                    if (std.mem.eql(u8, last, "Key")) c.cur.key = t;
                    if (std.mem.eql(u8, last, "Code")) c.cur.code = t;
                    if (std.mem.eql(u8, last, "Message")) c.cur.message = t;
                },
            }
        }
    };
    var c: Ctx = .{ .arena = arena };
    try walk(arena, src, &c, Ctx.cb);
    return .{ .deleted = c.deleted, .failures = c.failures.items };
}

pub const StsCredentials = struct {
    access_key_id: []const u8 = "",
    secret_access_key: []const u8 = "",
    session_token: []const u8 = "",
    expiration: []const u8 = "",
};

/// AssumeRoleWithWebIdentityResponse's `<Credentials>`.
pub fn parseStsCredentials(arena: std.mem.Allocator, src: []const u8) Error!StsCredentials {
    const Ctx = struct {
        out: StsCredentials = .{},
        fn cb(c: *@This(), path: []const []const u8, ev: Event) !void {
            switch (ev) {
                .leaf => |t| {
                    const n = path[path.len - 1];
                    if (std.mem.eql(u8, n, "AccessKeyId")) c.out.access_key_id = t;
                    if (std.mem.eql(u8, n, "SecretAccessKey")) c.out.secret_access_key = t;
                    if (std.mem.eql(u8, n, "SessionToken")) c.out.session_token = t;
                    if (std.mem.eql(u8, n, "Expiration")) c.out.expiration = t;
                },
                else => {},
            }
        }
    };
    var c: Ctx = .{};
    try walk(arena, src, &c, Ctx.cb);
    return c.out;
}

/// Percent-decoding as S3's `encoding-type=url` does it: `+` is a space.
pub fn urlDecode(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "%+") == null) return text;
    var out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '+') {
            out[n] = ' ';
        } else if (ch == '%' and i + 2 < text.len) {
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.Malformed;
            i += 2;
        } else if (ch == '%') {
            return error.Malformed;
        } else out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn arenaFor(a: *std.heap.ArenaAllocator) std.mem.Allocator {
    a.* = .init(testing.allocator);
    return a.allocator();
}

test "xml: ListBucketResult with entities, CommonPrefixes and a continuation token" {
    var a: std.heap.ArenaAllocator = undefined;
    const arena = arenaFor(&a);
    defer a.deinit();
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\<Name>b</Name><IsTruncated>true</IsTruncated><NextContinuationToken>tok&amp;1</NextContinuationToken>
        \\<Contents><Key>a&amp;b&lt;c&#x41;</Key><LastModified>2026-10-23T10:00:00.000Z</LastModified><ETag>&quot;abc&quot;</ETag><Size>12</Size><StorageClass>STANDARD</StorageClass></Contents>
        \\<Contents><Key>k2</Key><Size>0</Size><ETag>"d"</ETag></Contents>
        \\<CommonPrefixes><Prefix>photos/</Prefix></CommonPrefixes>
        \\</ListBucketResult>
    ;
    const r = try parseListObjects(arena, src, false);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("tok&1", r.next.?);
    try testing.expectEqual(@as(usize, 2), r.entries.len);
    try testing.expectEqualStrings("a&b<cA", r.entries[0].key);
    try testing.expectEqualStrings("\"abc\"", r.entries[0].etag);
    try testing.expectEqual(@as(u64, 12), r.entries[0].size);
    try testing.expectEqualStrings("STANDARD", r.entries[0].storage_class.?);
    try testing.expectEqualStrings("photos/", r.prefixes[0]);
}

test "xml: url-encoded keys keep control characters" {
    var a: std.heap.ArenaAllocator = undefined;
    const arena = arenaFor(&a);
    defer a.deinit();
    const r = try parseListObjects(arena, "<ListBucketResult><Contents><Key>a%0Ab+c%20d</Key></Contents></ListBucketResult>", true);
    try testing.expectEqualStrings("a\nb c d", r.entries[0].key);
}

test "xml: Error, InitiateMultipartUploadResult, CompleteMultipartUploadResult, DeleteResult, CopyObjectResult" {
    var a: std.heap.ArenaAllocator = undefined;
    const arena = arenaFor(&a);
    defer a.deinit();
    const e = parseError(arena, "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><Key>x</Key><RequestId>4442587FB7D0A2F9</RequestId></Error>").?;
    try testing.expectEqualStrings("NoSuchKey", e.code);
    try testing.expectEqualStrings("4442587FB7D0A2F9", e.request_id);
    try testing.expect(parseError(arena, "<CopyObjectResult><ETag>\"a\"</ETag></CopyObjectResult>") == null);
    try testing.expectEqualStrings("VXBsb2Fk", (try firstText(arena, "<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>VXBsb2Fk</UploadId></InitiateMultipartUploadResult>", "UploadId")).?);
    try testing.expectEqualStrings("\"3858\"", (try firstText(arena, "<CompleteMultipartUploadResult><Location>l</Location><ETag>\"3858\"</ETag></CompleteMultipartUploadResult>", "ETag")).?);
    const d = try parseDeleteResult(arena, "<DeleteResult><Deleted><Key>a</Key></Deleted><Deleted><Key>b</Key></Deleted><Error><Key>c</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error></DeleteResult>");
    try testing.expectEqual(@as(u32, 2), d.deleted);
    try testing.expectEqualStrings("c", d.failures[0].key);
    try testing.expectEqualStrings("AccessDenied", d.failures[0].code);
    const c = try parseStsCredentials(arena, "<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>S</SecretAccessKey><SessionToken>T</SessionToken><Expiration>2026-10-23T11:00:00Z</Expiration></Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>");
    try testing.expectEqualStrings("AK", c.access_key_id);
    try testing.expectEqualStrings("T", c.session_token);
}

test "xml: a DOCTYPE or an entity declaration is refused; unbalanced tags are an error" {
    var a: std.heap.ArenaAllocator = undefined;
    const arena = arenaFor(&a);
    defer a.deinit();
    try testing.expectError(error.DoctypeRefused, walkAll(arena, "<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><x>&e;</x>"));
    try testing.expectError(error.Malformed, walkAll(arena, "<a><b></a>"));
    try testing.expectError(error.Malformed, walkAll(arena, "<a>"));
    try testing.expectError(error.Malformed, walkAll(arena, "<a>&bogus;</a>"));
    try walkAll(arena, "<a><![CDATA[<x>]]><b/></a>");
}

fn walkAll(arena: std.mem.Allocator, src: []const u8) Error!void {
    var r = Reader.init(arena, src);
    while (try r.next()) |_| {}
}

test "fuzz: s3 xml" {
    const fuzz = @import("../fuzz.zig");
    const seeds = [_][]const u8{
        "<ListBucketResult><Contents><Key>a&amp;b</Key><Size>1</Size></Contents></ListBucketResult>",
        "<Error><Code>X</Code><Message>m</Message></Error>",
        "<a><b/><c>t</c></a>",
        "<!DOCTYPE a><a/>",
        "<DeleteResult><Deleted><Key>k</Key></Deleted></DeleteResult>",
    };
    try fuzz.bytes(fuzzCheck, &seeds);
}

/// The property: no crash, and every returned slice lies in the input or
/// in the arena.
fn fuzzCheck(input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = Reader.init(arena.allocator(), input);
    while (r.next() catch return) |tok| {
        const s = switch (tok) {
            .start, .end, .text => |x| x,
        };
        if (s.len == 0) continue;
        const lo = @intFromPtr(input.ptr);
        const p = @intFromPtr(s.ptr);
        if (p >= lo and p + s.len <= lo + input.len) continue;
        // Otherwise it must have been decoded into the arena: a copy that is
        // no longer than the input.
        if (s.len > input.len) return error.TestUnexpectedResult;
    }
    _ = parseListObjects(arena.allocator(), input, true) catch {};
    _ = parseError(arena.allocator(), input);
    _ = parseDeleteResult(arena.allocator(), input) catch {};
}
