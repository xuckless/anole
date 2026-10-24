//! An invocation's event JSON as a request: which front door sent it (API
//! Gateway REST or HTTP API, a Function URL, ALB, VPC Lattice v2), and its
//! method, target, headers, body and client. Anything else is a non-HTTP
//! event (SQS, SNS, S3, EventBridge, API Gateway WebSocket, ...) that the
//! adapter hands to the route on `event_path`.
//!
//! The rules are written down in docs/lambda.md ("What reaches your
//! routes"); the detection order is Hono's `@hono/aws-lambda`, the rest
//! follows each front door's documented payload (see THIRD_PARTY_NOTICES
//! for the sample events the tests use).

const std = @import("std");
const lambda = @import("root.zig");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Field = @import("../inmem.zig").Field;

pub const Incoming = struct {
    source: lambda.Source,
    /// The method as sent ("GET"); empty for `.event`.
    method: []const u8,
    /// Path and query, percent-encoded, always starting with "/"; empty
    /// for `.event`.
    target: []const u8,
    headers: []const Field,
    body: []const u8,
    /// The client as the front door saw it; null when the event has none.
    client: ?std.Io.net.IpAddress,
    secure: bool,
    /// ALB: the event used multiValueHeaders (answer in kind).
    multi_value: bool,
    stage: ?[]const u8,
    request_context: ?Value,
};

pub const ParseOptions = struct {
    base_path: ?[]const u8 = null,
    keep_stage: bool = false,
};

pub const Error = error{ InvalidEvent, OutOfMemory };

/// Headers a client must never set through the event: the adapter adds its
/// own copies (`x-amzn-*`), and `100-continue` means nothing in a buffered
/// event.
const removed_headers = [_][]const u8{ "x-amzn-request-context", "x-amzn-lambda-context", "expect" };

/// `bytes` is the event; the result points into `bytes` and `arena`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8, opts: ParseOptions) Error!Incoming {
    const root = std.json.parseFromSliceLeaky(Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEvent,
    };
    if (root != .object) return error.InvalidEvent;
    const rc_value = field(root, "requestContext");
    const source = detect(root, rc_value);
    var in: Incoming = .{
        .source = source,
        .method = "",
        .target = "",
        .headers = &.{},
        .body = bytes,
        .client = null,
        .secure = true,
        .multi_value = false,
        .stage = null,
        .request_context = null,
    };
    if (source == .event) return in;

    var headers: std.ArrayList(Field) = .empty;
    var path: []const u8 = undefined;
    var query: []const u8 = "";
    switch (source) {
        .rest_api => {
            in.method = str(root, "httpMethod") orelse return error.InvalidEvent;
            path = try encodePath(arena, str(root, "path") orelse return error.InvalidEvent);
            const multi = field(root, "multiValueQueryStringParameters");
            query = try joinQuery(arena, if (multi != null and multi.? == .object) multi else field(root, "queryStringParameters"), .encode);
            try addHeaders(arena, &headers, if (isObject(field(root, "multiValueHeaders"))) field(root, "multiValueHeaders") else field(root, "headers"));
            in.client = parseIp(str(path_field(rc_value, "identity"), "sourceIp"));
            in.stage = str(rc_value, "stage");
        },
        .http_api, .function_url => {
            const http = field(rc_value, "http");
            in.method = str(http, "method") orelse return error.InvalidEvent;
            path = str(root, "rawPath") orelse return error.InvalidEvent;
            query = str(root, "rawQueryString") orelse "";
            try addHeaders(arena, &headers, field(root, "headers"));
            if (field(root, "cookies")) |cookies| if (cookies == .array and cookies.array.items.len > 0) {
                var joined: std.Io.Writer.Allocating = .init(arena);
                for (cookies.array.items, 0..) |c, i| {
                    if (c != .string) return error.InvalidEvent;
                    if (i > 0) joined.writer.writeAll("; ") catch return error.OutOfMemory;
                    joined.writer.writeAll(c.string) catch return error.OutOfMemory;
                }
                dropHeader(&headers, "cookie");
                try headers.append(arena, .{ .name = "cookie", .value = joined.written() });
            };
            in.client = parseIp(str(http, "sourceIp"));
            if (source == .http_api) {
                in.stage = str(rc_value, "stage");
                if (!opts.keep_stage) if (in.stage) |stage| {
                    path = stripStage(path, stage);
                };
            }
        },
        .alb => {
            in.method = str(root, "httpMethod") orelse return error.InvalidEvent;
            path = str(root, "path") orelse return error.InvalidEvent;
            const multi = field(root, "multiValueQueryStringParameters");
            query = try joinQuery(arena, if (multi != null and multi.? == .object) multi else field(root, "queryStringParameters"), .raw);
            const multi_headers = field(root, "multiValueHeaders");
            in.multi_value = isObject(multi_headers);
            try addHeaders(arena, &headers, if (in.multi_value) multi_headers else field(root, "headers"));
            in.client = clientFromForwardedFor(headers.items);
            in.secure = if (headerValue(headers.items, "x-forwarded-proto")) |p| std.ascii.eqlIgnoreCase(std.mem.trim(u8, p, " "), "https") else false;
        },
        .vpc_lattice => {
            in.method = str(root, "method") orelse return error.InvalidEvent;
            path = str(root, "path") orelse return error.InvalidEvent;
            // v2 keeps the query beside the path; a path that carries one
            // is used as it is.
            if (std.mem.indexOfScalar(u8, path, '?')) |q| {
                query = path[q + 1 ..];
                path = path[0..q];
            } else {
                query = try joinQuery(arena, field(root, "queryStringParameters"), .raw);
            }
            try addHeaders(arena, &headers, field(root, "headers"));
            in.client = clientFromForwardedFor(headers.items);
            in.secure = if (headerValue(headers.items, "x-forwarded-proto")) |p| std.ascii.eqlIgnoreCase(std.mem.trim(u8, p, " "), "https") else true;
        },
        .event => unreachable,
    }

    if (opts.base_path) |base| path = stripBase(path, base);
    if (path.len == 0 or path[0] != '/') return error.InvalidEvent;
    in.target = if (query.len == 0) path else try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, query });

    in.body = try decodeBody(arena, root);

    // Never trust the client's copies of what the adapter sets itself.
    var i: usize = 0;
    while (i < headers.items.len) {
        if (isRemoved(headers.items[i].name)) _ = headers.orderedRemove(i) else i += 1;
    }
    if (headerValue(headers.items, "host") == null) {
        if (str(rc_value, "domainName")) |domain| try headers.append(arena, .{ .name = "host", .value = domain });
    }
    in.headers = headers.items;
    in.request_context = rc_value;
    return in;
}

/// Hono's order, by which fields are present (a `rawPath` test mistakes a
/// version 1 event behind a custom domain for version 2).
pub fn detect(root: Value, rc: ?Value) lambda.Source {
    if (rc) |r| {
        if (field(r, "elb") != null) return .alb;
        if (field(r, "serviceArn") != null) return .vpc_lattice;
        if (str(root, "version")) |v| if (std.mem.eql(u8, v, "2.0") and field(r, "http") != null) {
            const domain = str(r, "domainName") orelse "";
            return if (std.mem.indexOf(u8, domain, ".lambda-url.") != null) .function_url else .http_api;
        };
    }
    if (field(root, "httpMethod") != null) {
        // API Gateway WebSocket events carry an eventType.
        if (rc) |r| if (field(r, "eventType") != null) return .event;
        return .rest_api;
    }
    return .event;
}

fn field(v: ?Value, key: []const u8) ?Value {
    const value = v orelse return null;
    if (value != .object) return null;
    const f = value.object.get(key) orelse return null;
    return if (f == .null) null else f;
}

fn path_field(v: ?Value, key: []const u8) ?Value {
    return field(v, key);
}

fn str(v: ?Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn isObject(v: ?Value) bool {
    return v != null and v.? == .object;
}

fn isRemoved(name: []const u8) bool {
    for (removed_headers) |r| if (std.ascii.eqlIgnoreCase(name, r)) return true;
    return false;
}

fn headerValue(headers: []const Field, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn dropHeader(headers: *std.ArrayList(Field), name: []const u8) void {
    var i: usize = 0;
    while (i < headers.items.len) {
        if (std.ascii.eqlIgnoreCase(headers.items[i].name, name)) _ = headers.orderedRemove(i) else i += 1;
    }
}

/// A map of name to string or to an array of strings; one field per value.
fn addHeaders(arena: std.mem.Allocator, list: *std.ArrayList(Field), map: ?Value) Error!void {
    const m = map orelse return;
    if (m != .object) return;
    var it = m.object.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.*) {
            .string => |s| try list.append(arena, .{ .name = e.key_ptr.*, .value = s }),
            .array => |a| for (a.items) |item| {
                if (item == .string) try list.append(arena, .{ .name = e.key_ptr.*, .value = item.string });
            },
            else => {},
        }
    }
}

const QueryMode = enum { encode, raw };

/// `n=v&n=v` in the event's key order: values and names percent-encoded
/// (REST gives them decoded) or as they are (ALB and Lattice do not decode).
fn joinQuery(arena: std.mem.Allocator, map: ?Value, mode: QueryMode) Error![]const u8 {
    const m = map orelse return "";
    if (m != .object) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var first = true;
    var it = m.object.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.*) {
            .string => |s| try writePair(w, &first, e.key_ptr.*, s, mode),
            .array => |a| for (a.items) |item| {
                if (item == .string) try writePair(w, &first, e.key_ptr.*, item.string, mode);
            },
            else => {},
        }
    }
    return out.written();
}

fn writePair(w: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8, mode: QueryMode) Error!void {
    (blk: {
        if (!first.*) w.writeByte('&') catch |e| break :blk e;
        first.* = false;
        switch (mode) {
            .encode => {
                writeEncoded(w, name, query_unreserved) catch |e| break :blk e;
                w.writeByte('=') catch |e| break :blk e;
                writeEncoded(w, value, query_unreserved) catch |e| break :blk e;
            },
            .raw => {
                w.writeAll(name) catch |e| break :blk e;
                w.writeByte('=') catch |e| break :blk e;
                w.writeAll(value) catch |e| break :blk e;
            },
        }
        break :blk {};
    }) catch return error.OutOfMemory;
}

/// Characters a path keeps unescaped: RFC 3986 `pchar` and '/'.
fn pathUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/' => true,
        else => false,
    };
}

fn query_unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn writeEncoded(w: *std.Io.Writer, s: []const u8, comptime keep: fn (u8) bool) std.Io.Writer.Error!void {
    for (s) |c| {
        if (keep(c)) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

/// API Gateway REST decodes `path`; this encodes it again: every byte
/// outside `pathUnreserved` becomes %XX, including `%` itself.
pub fn encodePath(arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeEncoded(&out.writer, path, pathUnreserved) catch return error.OutOfMemory;
    return out.written();
}

/// Percent-encodes a query name or value (space is %20).
pub fn encodeQuery(arena: std.mem.Allocator, s: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeEncoded(&out.writer, s, query_unreserved) catch return error.OutOfMemory;
    return out.written();
}

/// "/Prod/my/path" with stage "Prod" gives "/my/path"; `$default` and
/// look-alikes ("/Production/x") are left alone. An empty rest is "/".
fn stripStage(path: []const u8, stage: []const u8) []const u8 {
    if (std.mem.eql(u8, stage, "$default") or stage.len == 0) return path;
    if (path.len < stage.len + 1 or path[0] != '/') return path;
    if (!std.mem.eql(u8, path[1 .. 1 + stage.len], stage)) return path;
    const rest = path[1 + stage.len ..];
    if (rest.len == 0) return "/";
    return if (rest[0] == '/') rest else path;
}

/// `base` off the front, on a segment boundary only ("/v1x" is kept).
fn stripBase(path: []const u8, base_in: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, base_in, "/");
    if (base.len == 0 or !std.mem.startsWith(u8, path, base)) return path;
    const rest = path[base.len..];
    if (rest.len == 0) return "/";
    return if (rest[0] == '/') rest else path;
}

fn decodeBody(arena: std.mem.Allocator, root: Value) Error![]const u8 {
    const body = str(root, "body") orelse return "";
    const encoded = if (field(root, "isBase64Encoded")) |b| b == .bool and b.bool else false;
    if (!encoded) return body;
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(body) catch return error.InvalidEvent;
    const out = try arena.alloc(u8, n);
    decoder.decode(out, body) catch return error.InvalidEvent;
    return out;
}

fn parseIp(text: ?[]const u8) ?std.Io.net.IpAddress {
    const t = text orelse return null;
    return std.Io.net.IpAddress.parse(std.mem.trim(u8, t, " "), 0) catch null;
}

/// The last entry of `X-Forwarded-For` (the balancer appends the peer),
/// with a port ("1.2.3.4:5678", "[::1]:80") or without.
fn clientFromForwardedFor(headers: []const Field) ?std.Io.net.IpAddress {
    var last: ?[]const u8 = null;
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) {
        last = h.value;
    };
    const value = last orelse return null;
    const entry = if (std.mem.lastIndexOfScalar(u8, value, ',')) |c| value[c + 1 ..] else value;
    var t = std.mem.trim(u8, entry, " ");
    if (t.len == 0) return null;
    if (t[0] == '[') {
        const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
        t = t[1..close];
    } else if (std.mem.count(u8, t, ":") == 1) {
        t = t[0..std.mem.indexOfScalar(u8, t, ':').?];
    }
    return std.Io.net.IpAddress.parse(t, 0) catch null;
}

// ---- tests ----

const testing = std.testing;

fn fixture(comptime name: []const u8) []const u8 {
    return @import("anole_lambda_events").get(name);
}

fn parseFixture(arena: std.mem.Allocator, comptime name: []const u8, opts: ParseOptions) !Incoming {
    return parse(arena, fixture(name), opts);
}

fn headerCount(headers: []const Field, name: []const u8) usize {
    var n: usize = 0;
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
        n += 1;
    };
    return n;
}

fn expectIp(expected: []const u8, actual: ?std.Io.net.IpAddress) !void {
    const want = try std.Io.net.IpAddress.parse(expected, 0);
    try testing.expect(actual != null);
    try testing.expect(want.eql(&actual.?));
}

test "lambda event: REST GET" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const in = try parseFixture(arena_state.allocator(), "apigw_multi_value_proxy_request", .{});
    try testing.expectEqual(lambda.Source.rest_api, in.source);
    try testing.expectEqualStrings("POST", in.method);
    // name=me, multiValueName=you&me, in the event's order.
    try testing.expectEqualStrings("/hello/world?name=me&multiValueName=you&multiValueName=me", in.target);
    try testing.expectEqual(@as(usize, 1), headerCount(in.headers, "accept"));
    try expectIp("192.168.196.186", in.client);
    try testing.expect(in.secure);
    try testing.expectEqualStrings("testStage", in.stage.?);
    try testing.expectEqualStrings("{\r\n\t\"a\": 1\r\n}", in.body);

    const single = try parseFixture(arena_state.allocator(), "apigw_proxy_request", .{});
    try testing.expectEqualStrings("/hello?name=me", single.target);
    try testing.expectEqualStrings("test", single.stage.?);
}

test "lambda event: REST multi-value headers stay separate fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"httpMethod":"GET","path":"/a","multiValueHeaders":{"Cookie":["a=1","b=2"],"Host":["h.example"]},
        \\ "requestContext":{"stage":"prod","identity":{"sourceIp":"10.1.2.3"}}}
    ;
    const in = try parse(arena_state.allocator(), json, .{});
    try testing.expectEqual(@as(usize, 2), headerCount(in.headers, "cookie"));
    try testing.expectEqualStrings("/a", in.target);
    try expectIp("10.1.2.3", in.client);
}

test "lambda event: REST POST base64 body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"httpMethod":"POST","path":"/up","body":"AAECA/8=","isBase64Encoded":true,"headers":{"host":"x"},"requestContext":{"stage":"s"}}
    ;
    const in = try parse(arena_state.allocator(), json, .{});
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 0xff }, in.body);
}

test "lambda event: REST path with %, space and UTF-8 is encoded again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"httpMethod":"GET","path":"/100%/a b/caf\u00e9","queryStringParameters":{"q":"a b&c","é":"1"},"requestContext":{"stage":"s"}}
    ;
    const in = try parse(arena_state.allocator(), json, .{});
    try testing.expectEqualStrings("/100%25/a%20b/caf%C3%A9?q=a%20b%26c&%C3%A9=1", in.target);
}

test "lambda event: HTTP API v2 with cookies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const in = try parseFixture(arena_state.allocator(), "apigw_v2_proxy_request", .{});
    try testing.expectEqual(lambda.Source.http_api, in.source);
    try testing.expectEqualStrings("POST", in.method);
    try testing.expectEqualStrings("/my/path?parameter1=value1&parameter1=value2&parameter2=value", in.target);
    try testing.expectEqual(@as(usize, 1), headerCount(in.headers, "cookie"));
    try testing.expectEqualStrings("cookie1=value1; cookie2=value2", headerValue(in.headers, "cookie").?);
    try testing.expectEqualStrings("Hello from Lambda", in.body);
    // The fixture's sourceIp is a placeholder, not an address.
    try testing.expect(in.client == null);
    // No host header in the event: the domain name stands in.
    try testing.expectEqualStrings("id.execute-api.us-east-1.amazonaws.com", headerValue(in.headers, "host").?);
}

test "lambda event: HTTP API v2 path with a space is kept as sent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const in = try parseFixture(arena_state.allocator(), "apigw_request_path_with_space", .{});
    try testing.expectEqual(lambda.Source.http_api, in.source);
    try testing.expect(std.mem.startsWith(u8, in.target, "/my/path-with space?"));
}

test "lambda event: HTTP API stage in the path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stripped = try parseFixture(a, "apigw_v2_proxy_request_with_stage_in_path", .{});
    try testing.expect(std.mem.startsWith(u8, stripped.target, "/my/path?"));
    try testing.expectEqualStrings("Prod", stripped.stage.?);
    const kept = try parseFixture(a, "apigw_v2_proxy_request_with_stage_in_path", .{ .keep_stage = true });
    try testing.expect(std.mem.startsWith(u8, kept.target, "/Prod/my/path?"));
    // $default is no prefix.
    const dflt = try parseFixture(a, "apigw_v2_proxy_request", .{});
    try testing.expect(std.mem.startsWith(u8, dflt.target, "/my/path?"));
    // A look-alike is not the stage.
    try testing.expectEqualStrings("/Production/x", stripStage("/Production/x", "Prod"));
    try testing.expectEqualStrings("/", stripStage("/Prod", "Prod"));
    try testing.expectEqualStrings("/x", stripStage("/Prod/x", "Prod"));
}

test "lambda event: Function URL detection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const in = try parseFixture(arena_state.allocator(), "lambda_function_url_request", .{});
    try testing.expectEqual(lambda.Source.function_url, in.source);
    try testing.expect(in.stage == null);
    try expectIp("65.78.31.245", in.client);
    try testing.expectEqualStrings("test=hi", headerValue(in.headers, "cookie").?);
}

test "lambda event: ALB single and multi-value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const single = try parseFixture(a, "alb_request", .{});
    try testing.expectEqual(lambda.Source.alb, single.source);
    try testing.expect(!single.multi_value);
    try testing.expectEqualStrings("/?myKey=val2", single.target);
    try expectIp("72.21.198.66", single.client);
    try testing.expect(single.secure);

    const multi = try parseFixture(a, "alb_multi_value_request", .{});
    try testing.expect(multi.multi_value);
    try testing.expectEqualStrings("/?myKey=val1&myKey=val2&myOtherKey=val3&myOtherKey=val4", multi.target);
    try testing.expectEqual(@as(usize, 2), headerCount(multi.headers, "cookie"));

    // Raw query: the encoded value stays encoded.
    const encoded = try parseFixture(a, "alb_request_encoded_query_parameters", .{});
    try testing.expectEqualStrings("/?myKey=%3FshowAll%3Dtrue", encoded.target);

    // x-forwarded-proto: http is not secure; a port on the address is dropped.
    const json =
        \\{"httpMethod":"GET","path":"/","headers":{"x-forwarded-for":"1.1.1.1, 9.8.7.6:4433","x-forwarded-proto":"http","host":"h"},"requestContext":{"elb":{}}}
    ;
    const plain = try parse(a, json, .{});
    try testing.expect(!plain.secure);
    try expectIp("9.8.7.6", plain.client);
}

test "lambda event: VPC Lattice v2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const in = try parseFixture(a, "vpc_lattice_v2_request", .{});
    try testing.expectEqual(lambda.Source.vpc_lattice, in.source);
    try testing.expectEqualStrings("GET", in.method);
    try testing.expectEqualStrings("/health?state=prod&multi=a&multi=DEF&multi=g", in.target);
    // Array headers expand to one field per value.
    try testing.expectEqual(@as(usize, 2), headerCount(in.headers, "multi"));
    try expectIp("10.0.2.100", in.client);
    try testing.expect(in.secure);

    const b64 = try parseFixture(a, "vpc_lattice_v2_request_base64", .{});
    try testing.expectEqualStrings("All is good", b64.body);
    try testing.expectEqualStrings("www.site.com", headerValue(b64.headers, "host").?);

    const encoded = try parseFixture(a, "vpc_lattice_v2_request_encoded_query", .{});
    try testing.expectEqualStrings("/search?filter=%3FshowAll%3Dtrue&q=hello%20world", encoded.target);

    // A path that already carries the query is used as it is.
    const inline_query =
        \\{"version":"2.0","method":"GET","path":"/s?x=1","requestContext":{"serviceArn":"arn"}}
    ;
    const q = try parse(a, inline_query, .{});
    try testing.expectEqualStrings("/s?x=1", q.target);
}

test "lambda event: v1 behind a custom domain carrying rawPath stays REST" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"httpMethod":"GET","path":"/v1/x","rawPath":"/v1/x","headers":{"host":"api.example.com"},
        \\ "requestContext":{"stage":"prod","domainName":"api.example.com","identity":{"sourceIp":"2001:db8::1"}}}
    ;
    const in = try parse(arena_state.allocator(), json, .{});
    try testing.expectEqual(lambda.Source.rest_api, in.source);
    try expectIp("2001:db8::1", in.client);
}

test "lambda event: non-HTTP events carry the whole event as the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    inline for (.{ "sqs_event", "eventbridge_schedule", "s3_event", "apigw_websocket_request" }) |name| {
        const in = try parseFixture(a, name, .{});
        try testing.expectEqual(lambda.Source.event, in.source);
        try testing.expectEqualStrings(fixture(name), in.body);
        try testing.expectEqualStrings("", in.method);
        try testing.expect(in.request_context == null);
    }
}

test "lambda event: invalid events" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.InvalidEvent, parse(a, "not json", .{}));
    try testing.expectError(error.InvalidEvent, parse(a, "[1,2]", .{}));
    try testing.expectError(error.InvalidEvent, parse(a, "{\"httpMethod\":1}", .{}));
    try testing.expectError(error.InvalidEvent, parse(a,
        \\{"httpMethod":"POST","path":"/a","body":"!!!","isBase64Encoded":true,"requestContext":{}}
    , .{}));
    try testing.expectError(error.InvalidEvent, parse(a,
        \\{"httpMethod":"GET","path":"nope","requestContext":{}}
    , .{}));
    try testing.expectError(error.InvalidEvent, parse(a,
        \\{"version":"2.0","rawPath":"/x","requestContext":{"http":{}}}
    , .{}));
}

test "lambda event: base_path comes off on a segment boundary only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const template =
        \\{{"httpMethod":"GET","path":"{s}","requestContext":{{"stage":"s"}}}}
    ;
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "/v1/users", .want = "/users" },
        .{ .path = "/v1", .want = "/" },
        .{ .path = "/v1x/users", .want = "/v1x/users" },
        .{ .path = "/other", .want = "/other" },
    }) |c| {
        const json = try std.fmt.allocPrint(a, template, .{c.path});
        const in = try parse(a, json, .{ .base_path = "/v1" });
        try testing.expectEqualStrings(c.want, in.target);
    }
}

test "lambda event: spoofed context headers are removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const json =
        \\{"httpMethod":"GET","path":"/","headers":{"X-Amzn-Request-Context":"{}","x-amzn-lambda-context":"{}","Expect":"100-continue","Accept":"*/*"},"requestContext":{}}
    ;
    const in = try parse(arena_state.allocator(), json, .{});
    try testing.expectEqual(@as(usize, 0), headerCount(in.headers, "x-amzn-request-context"));
    try testing.expectEqual(@as(usize, 0), headerCount(in.headers, "x-amzn-lambda-context"));
    try testing.expectEqual(@as(usize, 0), headerCount(in.headers, "expect"));
    try testing.expectEqual(@as(usize, 1), headerCount(in.headers, "accept"));
}

test "fuzz: lambda event parse" {
    const seeds = [_][]const u8{
        fixture("apigw_proxy_request"),         fixture("apigw_multi_value_proxy_request"), fixture("apigw_v2_proxy_request"),
        fixture("lambda_function_url_request"), fixture("alb_request"),                     fixture("alb_multi_value_request"),
        fixture("vpc_lattice_v2_request"),      fixture("vpc_lattice_v2_request_base64"),   fixture("sqs_event"),
        fixture("apigw_websocket_request"),     "{}",                                       "{\"httpMethod\":\"GET\",\"path\":\"/\"}",
    };
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            const in = parse(arena_state.allocator(), input, .{ .base_path = "/v1" }) catch |err| switch (err) {
                error.InvalidEvent => return,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (in.source != .event) {
                if (in.target.len == 0 or in.target[0] != '/') return error.BadTarget;
                for (in.headers) |h| if (isRemoved(h.name)) return error.SpoofedHeader;
            }
        }
    }.check, &seeds);
}
