//! An answer in the shape each Lambda front door expects: API Gateway REST
//! (`multiValueHeaders` only), HTTP API and Function URLs (`headers` plus
//! `cookies`), ALB (`statusDescription`, single or multi-value headers) and
//! VPC Lattice. The JSON is written straight into the writer; the body goes
//! out as text or base64 from the answer's parts, with no joined copy.
//!
//! The rules are in docs/lambda.md ("Answers").

const std = @import("std");
const dusty = @import("dusty");
const lambda = @import("root.zig");

pub const Answer = struct {
    status: u16,
    headers: *const dusty.Headers,
    /// The body, in parts (the sink's `complete`) or one buffer.
    parts: []const []const u8,
    /// A HEAD request: no body.
    head: bool,
};

/// The 8 NUL bytes between the prelude and the body of a streamed answer.
pub const delimiter: [8]u8 = @splat(0);

const Error = std.Io.Writer.Error;

/// Lambda's buffered answer for `source`. `multi_value` is for ALB (the
/// event used multiValueHeaders). `cookies_dropped` counts the `Set-Cookie`
/// lines a front door that takes one value per header could not carry.
pub fn writeBuffered(w: *std.Io.Writer, source: lambda.Source, multi_value: bool, a: Answer, cookies_dropped: *usize) Error!void {
    try w.print("{{\"statusCode\":{d}", .{a.status});
    if (source == .alb) {
        try w.writeAll(",\"statusDescription\":");
        var buf: [64]u8 = undefined;
        const desc = if (dusty.Status.fromCode(a.status)) |s|
            std.fmt.bufPrint(&buf, "{d} {s}", .{ a.status, s.phrase() }) catch "200 OK"
        else |_|
            std.fmt.bufPrint(&buf, "{d}", .{a.status}) catch "200";
        try writeJsonString(w, desc);
    }
    switch (source) {
        .rest_api => {
            try w.writeAll(",\"multiValueHeaders\":");
            try writeMulti(w, a.headers, false);
        },
        .alb => if (multi_value) {
            try w.writeAll(",\"multiValueHeaders\":");
            try writeMulti(w, a.headers, false);
        } else {
            try w.writeAll(",\"headers\":");
            cookies_dropped.* += try writeJoined(w, a.headers, .first_only, false);
        },
        .vpc_lattice => {
            try w.writeAll(",\"headers\":");
            cookies_dropped.* += try writeJoined(w, a.headers, .first_only, false);
        },
        .http_api, .function_url, .event => {
            try w.writeAll(",\"headers\":");
            _ = try writeJoined(w, a.headers, .omit, false);
            try writeCookies(w, a.headers);
        },
    }
    try w.writeAll(",\"body\":");
    const bodiless = a.head or a.status == 204 or a.status == 304;
    const content_type = a.headers.get("content-type");
    const content_encoding = a.headers.get("content-encoding");
    if (bodiless) {
        try w.writeAll("\"\",\"isBase64Encoded\":false}");
    } else if (isText(content_type, content_encoding, a.parts)) {
        try w.writeByte('"');
        for (a.parts) |p| try writeEscaped(w, p);
        try w.writeAll("\",\"isBase64Encoded\":false}");
    } else {
        try w.writeByte('"');
        try writeBase64Parts(w, a.parts);
        try w.writeAll("\",\"isBase64Encoded\":true}");
    }
}

/// The streaming prelude (no delimiter): REST uses `multiValueHeaders`,
/// Function URLs `headers` plus `cookies`. `content-type` defaults to
/// `application/octet-stream`, as both Lambda runtimes do.
pub fn writePrelude(w: *std.Io.Writer, source: lambda.Source, status: u16, headers: *const dusty.Headers) Error!void {
    try w.print("{{\"statusCode\":{d}", .{status});
    const has_type = headers.get("content-type") != null;
    if (source == .rest_api) {
        try w.writeAll(",\"multiValueHeaders\":");
        try writeMulti(w, headers, !has_type);
    } else {
        try w.writeAll(",\"headers\":");
        _ = try writeJoined(w, headers, .omit, !has_type);
        try writeCookies(w, headers);
    }
    try w.writeByte('}');
}

/// Whether a body goes out as JSON text rather than base64: no content
/// coding, a textual type (none, `text/*`, JSON, JavaScript, XML, YAML,
/// url-encoded forms, or a `+json`, `+xml` or `+yaml` suffix) and valid
/// UTF-8.
pub fn isText(content_type: ?[]const u8, content_encoding: ?[]const u8, body_parts: []const []const u8) bool {
    if (content_encoding) |enc| {
        const e = std.mem.trim(u8, enc, " \t");
        if (e.len != 0 and !std.ascii.eqlIgnoreCase(e, "identity")) return false;
    }
    if (content_type) |ct| if (!textualType(ct)) return false;
    return validUtf8Parts(body_parts);
}

fn textualType(content_type: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const raw = std.mem.trim(u8, content_type[0..semi], " \t");
    if (raw.len == 0) return true;
    var buf: [128]u8 = undefined;
    if (raw.len > buf.len) return false;
    const t = std.ascii.lowerString(&buf, raw);
    if (std.mem.startsWith(u8, t, "text/")) return true;
    for ([_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "application/yaml",
        "application/x-www-form-urlencoded",
    }) |known| if (std.mem.eql(u8, t, known)) return true;
    for ([_][]const u8{ "+json", "+xml", "+yaml" }) |suffix| if (std.mem.endsWith(u8, t, suffix)) return true;
    return false;
}

/// UTF-8 validity of the concatenation of `parts`, which may split a
/// character between two of them.
fn validUtf8Parts(parts: []const []const u8) bool {
    var carry: [4]u8 = undefined;
    var carry_len: usize = 0;
    for (parts) |part| {
        var s = part;
        if (carry_len > 0) {
            const seq = std.unicode.utf8ByteSequenceLength(carry[0]) catch return false;
            const take = @min(seq - carry_len, s.len);
            @memcpy(carry[carry_len..][0..take], s[0..take]);
            carry_len += take;
            s = s[take..];
            if (carry_len < seq) continue;
            if (!std.unicode.utf8ValidateSlice(carry[0..carry_len])) return false;
            carry_len = 0;
        }
        // Leave an incomplete character at the end for the next part.
        var end = s.len;
        var i = s.len;
        var looked: usize = 0;
        while (i > 0 and looked < 3) : (looked += 1) {
            i -= 1;
            const b = s[i];
            if (b & 0xC0 == 0x80) continue;
            if (b >= 0x80) {
                const seq = std.unicode.utf8ByteSequenceLength(b) catch return false;
                if (seq > s.len - i) end = i;
            }
            break;
        }
        if (!std.unicode.utf8ValidateSlice(s[0..end])) return false;
        carry_len = s.len - end;
        @memcpy(carry[0..carry_len], s[end..]);
    }
    return carry_len == 0;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// The inside of a JSON string, bytewise: valid UTF-8 passes through (a
/// part may end inside a character), controls and quotes are escaped.
fn writeEscaped(w: *std.Io.Writer, s: []const u8) Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            0...7, 0x0b, 0x0e...0x1f, 0x7f => null,
            else => continue,
        };
        try w.writeAll(s[start..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// The concatenation of `parts` as standard base64, with padding at the
/// very end only.
fn writeBase64Parts(w: *std.Io.Writer, parts: []const []const u8) Error!void {
    const enc = std.base64.standard.Encoder;
    var carry: [3]u8 = undefined;
    var carry_len: usize = 0;
    for (parts) |part| {
        var s = part;
        if (carry_len > 0) {
            const take = @min(3 - carry_len, s.len);
            @memcpy(carry[carry_len..][0..take], s[0..take]);
            carry_len += take;
            s = s[take..];
            if (carry_len < 3) continue;
            try enc.encodeWriter(w, &carry);
            carry_len = 0;
        }
        const whole = s.len - s.len % 3;
        if (whole > 0) try enc.encodeWriter(w, s[0..whole]);
        carry_len = s.len - whole;
        @memcpy(carry[0..carry_len], s[whole..]);
    }
    if (carry_len > 0) try enc.encodeWriter(w, carry[0..carry_len]);
}

/// Headers that belong to a connection or that each front door computes.
fn dropped(name: []const u8) bool {
    inline for (.{ "connection", "keep-alive", "transfer-encoding", "upgrade", "te", "trailer", "proxy-connection", "content-length" }) |d| {
        if (std.ascii.eqlIgnoreCase(name, d)) return true;
    }
    return false;
}

fn writeLowerName(w: *std.Io.Writer, name: []const u8) Error!void {
    try w.writeByte('"');
    var buf: [64]u8 = undefined;
    var rest = name;
    while (rest.len > 0) {
        const n = @min(rest.len, buf.len);
        try writeEscaped(w, std.ascii.lowerString(buf[0..n], rest[0..n]));
        rest = rest[n..];
    }
    try w.writeByte('"');
}

/// Whether entry `i` is the first with its (case-insensitive) name.
fn firstWithName(h: *const dusty.Headers, i: usize) bool {
    for (h.keys[0..i]) |k| if (std.ascii.eqlIgnoreCase(k, h.keys[i])) return false;
    return true;
}

/// `{"name":["a","b"],...}`, names lowercased, in order of first appearance.
fn writeMulti(w: *std.Io.Writer, h: *const dusty.Headers, default_type: bool) Error!void {
    try w.writeByte('{');
    var first = true;
    if (default_type) {
        try w.writeAll("\"content-type\":[\"application/octet-stream\"]");
        first = false;
    }
    for (h.keys[0..h.len], 0..) |name, i| {
        if (dropped(name) or !firstWithName(h, i)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeLowerName(w, name);
        try w.writeAll(":[");
        var n: usize = 0;
        for (h.keys[0..h.len], h.values[0..h.len]) |other, value| {
            if (!std.ascii.eqlIgnoreCase(other, name)) continue;
            if (n > 0) try w.writeByte(',');
            n += 1;
            try writeJsonString(w, value);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

const CookieMode = enum {
    /// `Set-Cookie` lines leave the object (they go in `cookies`).
    omit,
    /// A front door with one value per header: the first `Set-Cookie` stays.
    first_only,
};

/// `{"name":"a, b",...}`; returns how many `Set-Cookie` lines `first_only`
/// left out.
fn writeJoined(w: *std.Io.Writer, h: *const dusty.Headers, cookie_mode: CookieMode, default_type: bool) Error!usize {
    try w.writeByte('{');
    var first = true;
    var lost: usize = 0;
    if (default_type) {
        try w.writeAll("\"content-type\":\"application/octet-stream\"");
        first = false;
    }
    for (h.keys[0..h.len], 0..) |name, i| {
        if (dropped(name) or !firstWithName(h, i)) continue;
        const is_cookie = std.ascii.eqlIgnoreCase(name, "set-cookie");
        if (is_cookie and cookie_mode == .omit) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeLowerName(w, name);
        try w.writeAll(":\"");
        var n: usize = 0;
        for (h.keys[0..h.len], h.values[0..h.len]) |other, value| {
            if (!std.ascii.eqlIgnoreCase(other, name)) continue;
            if (is_cookie and n > 0) {
                lost += 1;
                continue;
            }
            if (n > 0) try w.writeAll(", ");
            n += 1;
            try writeEscaped(w, value);
        }
        try w.writeByte('"');
    }
    try w.writeByte('}');
    return lost;
}

/// `,"cookies":["a=1","b=2"]` when there are `Set-Cookie` headers.
fn writeCookies(w: *std.Io.Writer, h: *const dusty.Headers) Error!void {
    var n: usize = 0;
    for (h.keys[0..h.len], h.values[0..h.len]) |name, value| {
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        try w.writeAll(if (n == 0) ",\"cookies\":[" else ",");
        n += 1;
        try writeJsonString(w, value);
    }
    if (n > 0) try w.writeByte(']');
}

// ---- tests ----

const testing = std.testing;

fn headersOf(pairs: []const [2][]const u8) !dusty.Headers {
    var h = try dusty.Headers.init(testing.allocator, 16);
    for (pairs) |p| try h.add(p[0], p[1]);
    return h;
}

fn encodeToString(source: lambda.Source, multi: bool, a: Answer, lost: *usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writeBuffered(&out.writer, source, multi, a, lost);
    return out.toOwnedSlice();
}

test "lambda encode: isText table" {
    const text: []const []const u8 = &.{"hello"};
    try testing.expect(isText(null, null, text));
    try testing.expect(isText("text/html; charset=utf-8", null, text));
    try testing.expect(isText("TEXT/PLAIN", "identity", text));
    try testing.expect(isText("application/json", null, text));
    try testing.expect(isText("application/problem+json", null, text));
    try testing.expect(isText("application/atom+xml", null, text));
    try testing.expect(isText("application/javascript", null, text));
    try testing.expect(isText("application/x-www-form-urlencoded", null, text));
    try testing.expect(isText("application/yaml", null, text));
    try testing.expect(!isText("image/png", null, text));
    try testing.expect(!isText("application/octet-stream", null, text));
    try testing.expect(!isText("application/pdf", null, text));
    try testing.expect(!isText("text/html", "gzip", text));
    try testing.expect(!isText("text/html", "br", text));
    // Invalid UTF-8 is never text.
    try testing.expect(!isText("text/html", null, &.{"\xff\xfe"}));
    try testing.expect(!isText(null, null, &.{"\xc3"}));
    // A character split between parts is still valid.
    try testing.expect(isText("text/plain", null, &.{ "caf\xc3", "\xa9 ok" }));
    try testing.expect(isText("text/plain", null, &.{ "\xe2", "\x82", "\xac" }));
    try testing.expect(!isText("text/plain", null, &.{ "\xe2", "\x82" }));
    try testing.expect(!isText("text/plain", null, &.{ "a\xc3", "(" }));
}

test "lambda encode: REST multi-value" {
    var h = try headersOf(&.{ .{ "Content-Type", "application/json" }, .{ "Set-Cookie", "a=1" }, .{ "set-cookie", "b=2" } });
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const out = try encodeToString(.rest_api, false, .{ .status = 200, .headers = &h, .parts = &.{"{\"a\":1}"}, .head = false }, &lost);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"statusCode\":200,\"multiValueHeaders\":{\"content-type\":[\"application/json\"],\"set-cookie\":[\"a=1\",\"b=2\"]},\"body\":\"{\\\"a\\\":1}\",\"isBase64Encoded\":false}",
        out,
    );
}

test "lambda encode: HTTP API" {
    var h = try headersOf(&.{ .{ "Content-Type", "text/plain" }, .{ "Vary", "Accept-Encoding" }, .{ "Vary", "Origin" }, .{ "Set-Cookie", "a=1" }, .{ "Set-Cookie", "b=2" } });
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const out = try encodeToString(.http_api, false, .{ .status = 201, .headers = &h, .parts = &.{ "he", "llo" }, .head = false }, &lost);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"statusCode\":201,\"headers\":{\"content-type\":\"text/plain\",\"vary\":\"Accept-Encoding, Origin\"},\"cookies\":[\"a=1\",\"b=2\"],\"body\":\"hello\",\"isBase64Encoded\":false}",
        out,
    );
    try testing.expectEqual(@as(usize, 0), lost);

    var plain = try headersOf(&.{.{ "Content-Type", "text/plain" }});
    defer plain.deinit(testing.allocator);
    const none = try encodeToString(.function_url, false, .{ .status = 200, .headers = &plain, .parts = &.{"x"}, .head = false }, &lost);
    defer testing.allocator.free(none);
    try testing.expect(std.mem.indexOf(u8, none, "cookies") == null);
}

test "lambda encode: ALB" {
    var h = try headersOf(&.{ .{ "Content-Type", "text/plain" }, .{ "Set-Cookie", "a=1" }, .{ "Set-Cookie", "b=2" } });
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const multi = try encodeToString(.alb, true, .{ .status = 404, .headers = &h, .parts = &.{"no"}, .head = false }, &lost);
    defer testing.allocator.free(multi);
    try testing.expectEqualStrings(
        "{\"statusCode\":404,\"statusDescription\":\"404 Not Found\",\"multiValueHeaders\":{\"content-type\":[\"text/plain\"],\"set-cookie\":[\"a=1\",\"b=2\"]},\"body\":\"no\",\"isBase64Encoded\":false}",
        multi,
    );
    try testing.expectEqual(@as(usize, 0), lost);
    const single = try encodeToString(.alb, false, .{ .status = 404, .headers = &h, .parts = &.{"no"}, .head = false }, &lost);
    defer testing.allocator.free(single);
    try testing.expectEqualStrings(
        "{\"statusCode\":404,\"statusDescription\":\"404 Not Found\",\"headers\":{\"content-type\":\"text/plain\",\"set-cookie\":\"a=1\"},\"body\":\"no\",\"isBase64Encoded\":false}",
        single,
    );
    try testing.expectEqual(@as(usize, 1), lost);
}

test "lambda encode: VPC Lattice" {
    var h = try headersOf(&.{.{ "Content-Type", "application/json" }});
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const out = try encodeToString(.vpc_lattice, false, .{ .status = 200, .headers = &h, .parts = &.{"{}"}, .head = false }, &lost);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"statusCode\":200,\"headers\":{\"content-type\":\"application/json\"},\"body\":\"{}\",\"isBase64Encoded\":false}", out);
}

test "lambda encode: hop-by-hop and content-length dropped, names lowercased" {
    var h = try headersOf(&.{ .{ "Connection", "close" }, .{ "Content-Length", "2" }, .{ "Transfer-Encoding", "chunked" }, .{ "Keep-Alive", "x" }, .{ "X-Custom-Name", "v" } });
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const out = try encodeToString(.http_api, false, .{ .status = 200, .headers = &h, .parts = &.{"ok"}, .head = false }, &lost);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"statusCode\":200,\"headers\":{\"x-custom-name\":\"v\"},\"body\":\"ok\",\"isBase64Encoded\":false}", out);
}

test "lambda encode: HEAD, 204 and 304 have an empty body" {
    var h = try headersOf(&.{.{ "Content-Type", "text/plain" }});
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    inline for (.{ .{ 200, true }, .{ 204, false }, .{ 304, false } }) |c| {
        const out = try encodeToString(.http_api, false, .{ .status = c[0], .headers = &h, .parts = &.{"ignored"}, .head = c[1] }, &lost);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.endsWith(u8, out, "\"body\":\"\",\"isBase64Encoded\":false}"));
    }
}

test "lambda encode: base64 body from parts equals the concatenation" {
    var h = try headersOf(&.{.{ "Content-Type", "image/png" }});
    defer h.deinit(testing.allocator);
    const whole = "\x89PNG\r\n\x1a\n\x00\xff\xfe-and-some-more-bytes";
    var expected: [64]u8 = undefined;
    const want = std.base64.standard.Encoder.encode(&expected, whole);
    var lost: usize = 0;
    // Every way to cut the body in two (and three) gives the same bytes.
    for (0..whole.len + 1) |i| {
        for (i..whole.len + 1) |j| {
            const out = try encodeToString(.http_api, false, .{ .status = 200, .headers = &h, .parts = &.{ whole[0..i], whole[i..j], whole[j..] }, .head = false }, &lost);
            defer testing.allocator.free(out);
            const body_start = std.mem.indexOf(u8, out, "\"body\":\"").? + 8;
            const body_end = std.mem.indexOfPos(u8, out, body_start, "\"").?;
            try testing.expectEqualStrings(want, out[body_start..body_end]);
            try testing.expect(std.mem.endsWith(u8, out, "\"isBase64Encoded\":true}"));
        }
    }
}

test "lambda encode: text escapes controls and quotes, keeps UTF-8" {
    var h = try headersOf(&.{.{ "Content-Type", "text/plain" }});
    defer h.deinit(testing.allocator);
    var lost: usize = 0;
    const out = try encodeToString(.http_api, false, .{ .status = 200, .headers = &h, .parts = &.{ "a\"b\\c\n\x01 caf\xc3", "\xa9" }, .head = false }, &lost);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"body\":\"a\\\"b\\\\c\\n\\u0001 caf\xc3\xa9\"") != null);
    // The result is valid JSON that decodes back to the body.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\"b\\c\n\x01 caf\xc3\xa9", parsed.value.object.get("body").?.string);
}

test "lambda encode: prelude" {
    var h = try headersOf(&.{ .{ "Content-Type", "text/event-stream" }, .{ "Set-Cookie", "s=1" }, .{ "X-A", "1" }, .{ "x-a", "2" } });
    defer h.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writePrelude(&out.writer, .function_url, 200, &h);
    try testing.expectEqualStrings("{\"statusCode\":200,\"headers\":{\"content-type\":\"text/event-stream\",\"x-a\":\"1, 2\"},\"cookies\":[\"s=1\"]}", out.written());

    var rest: std.Io.Writer.Allocating = .init(testing.allocator);
    defer rest.deinit();
    try writePrelude(&rest.writer, .rest_api, 200, &h);
    try testing.expectEqualStrings("{\"statusCode\":200,\"multiValueHeaders\":{\"content-type\":[\"text/event-stream\"],\"set-cookie\":[\"s=1\"],\"x-a\":[\"1\",\"2\"]}}", rest.written());

    // No content type: both runtimes default to octet-stream.
    var bare = try headersOf(&.{.{ "X-A", "1" }});
    defer bare.deinit(testing.allocator);
    var d: std.Io.Writer.Allocating = .init(testing.allocator);
    defer d.deinit();
    try writePrelude(&d.writer, .function_url, 204, &bare);
    try testing.expectEqualStrings("{\"statusCode\":204,\"headers\":{\"content-type\":\"application/octet-stream\",\"x-a\":\"1\"}}", d.written());
}
