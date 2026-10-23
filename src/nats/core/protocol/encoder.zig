// Adapted from vkiryakov/zefir src/nats/protocol/encoder.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Frames the client sends: CONNECT, PUB, HPUB, SUB, UNSUB, PING and PONG.
//! Each `write*` has a `*Len` twin that gives the exact length of the frame
//! before anything is written, so a frame can be checked against limits and
//! get its room in the outbound queue first.
//!
//! Only formatting happens here: callers check subjects (`subject.zig`) and
//! headers (`Headers.validate`) before.

const std = @import("std");
const Writer = std.Io.Writer;
const Headers = @import("../Headers.zig");
const Header = Headers.Header;

/// The library version from build.zig.zon, sent in CONNECT.
pub const version: []const u8 = @import("build_options").version;

pub const ping = "PING\r\n";
pub const pong = "PONG\r\n";

/// What the client tells the server in CONNECT. The strings must be valid
/// UTF-8: the server replaces invalid bytes, so a password would no longer
/// match. `Options.validate` checks this for the client's options.
pub const Connect = struct {
    verbose: bool = false,
    pedantic: bool = false,
    echo: bool = true,
    /// The server announced `headers` in INFO. Without it neither `headers`
    /// nor `no_responders` is sent: the server would close the connection.
    headers: bool,
    no_responders: bool,
    name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    /// An authentication token.
    auth_token: ?[]const u8 = null,
    /// A user JWT, with `nkey` and `sig` (a signed nonce).
    jwt: ?[]const u8 = null,
    nkey: ?[]const u8 = null,
    sig: ?[]const u8 = null,
};

/// The CONNECT object, fields in the order they are written. `verbose`
/// and `pedantic` are always sent: the server takes a missing one as true.
const ConnectJson = struct {
    verbose: bool,
    pedantic: bool,
    lang: []const u8 = "zig",
    version: []const u8 = version,
    protocol: u8 = 1,
    echo: bool,
    headers: ?bool,
    no_responders: ?bool,
    name: ?[]const u8,
    user: ?[]const u8,
    pass: ?[]const u8,
    auth_token: ?[]const u8,
    jwt: ?[]const u8,
    nkey: ?[]const u8,
    sig: ?[]const u8,
};

const json_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

fn connectJson(c: Connect) ConnectJson {
    return .{
        .verbose = c.verbose,
        .pedantic = c.pedantic,
        .echo = c.echo,
        .headers = if (c.headers) true else null,
        .no_responders = if (c.headers and c.no_responders) true else null,
        .name = c.name,
        .user = c.user,
        .pass = c.pass,
        .auth_token = c.auth_token,
        .jwt = c.jwt,
        .nkey = c.nkey,
        .sig = c.sig,
    };
}

/// `CONNECT {...}\r\n`. The frame holds the password: never log it.
pub fn writeConnect(w: *Writer, c: Connect) Writer.Error!void {
    try w.writeAll("CONNECT ");
    try std.json.Stringify.value(connectJson(c), json_options, w);
    try w.writeAll("\r\n");
}

/// The length of the CONNECT JSON alone. The server counts it against its
/// control-line limit (4096 bytes by default) and closes the connection
/// when it is longer.
pub fn connectJsonLen(c: Connect) usize {
    var counter: Writer.Discarding = .init(&.{});
    std.json.Stringify.value(connectJson(c), json_options, &counter.writer) catch unreachable; // discarding never fails
    return @intCast(counter.fullCount());
}

/// `PUB <subject> [reply-to] <size>\r\n<payload>\r\n`.
pub fn writePub(w: *Writer, subject: []const u8, reply_to: ?[]const u8, payload: []const u8) Writer.Error!void {
    try w.print("PUB {s}", .{subject});
    if (reply_to) |reply| try w.print(" {s}", .{reply});
    try w.print(" {d}\r\n", .{payload.len});
    try w.writeAll(payload);
    try w.writeAll("\r\n");
}

pub fn pubLen(subject: []const u8, reply_to: ?[]const u8, payload_len: usize) usize {
    return "PUB ".len + subject.len + replyLen(reply_to) + 1 + digits(payload_len) + 2 + payload_len + 2;
}

/// `HPUB <subject> [reply-to] <header-size> <total-size>\r\n<headers><payload>\r\n`.
/// Headers count toward the server's `max_payload`.
pub fn writeHpub(w: *Writer, subject: []const u8, reply_to: ?[]const u8, headers: []const Header, payload: []const u8) Writer.Error!void {
    const header_len = headerBlockLen(headers);
    try w.print("HPUB {s}", .{subject});
    if (reply_to) |reply| try w.print(" {s}", .{reply});
    try w.print(" {d} {d}\r\n", .{ header_len, header_len + payload.len });
    try writeHeaderBlock(w, headers);
    try w.writeAll(payload);
    try w.writeAll("\r\n");
}

/// `header_len` is `headerBlockLen(headers)`.
pub fn hpubLen(subject: []const u8, reply_to: ?[]const u8, header_len: usize, payload_len: usize) usize {
    const total = header_len + payload_len;
    return "HPUB ".len + subject.len + replyLen(reply_to) + 1 + digits(header_len) + 1 + digits(total) + 2 + total + 2;
}

/// `SUB <subject> [queue] <sid>\r\n`.
pub fn writeSub(w: *Writer, subject: []const u8, queue: ?[]const u8, sid: u64) Writer.Error!void {
    try w.print("SUB {s}", .{subject});
    if (queue) |q| try w.print(" {s}", .{q});
    try w.print(" {d}\r\n", .{sid});
}

pub fn subLen(subject: []const u8, queue: ?[]const u8, sid: u64) usize {
    return "SUB ".len + subject.len + replyLen(queue) + 1 + digits(sid) + 2;
}

/// `UNSUB <sid> [max]\r\n`. With `max`, the server delivers messages until
/// the subscription has received `max` in total, then removes it.
pub fn writeUnsub(w: *Writer, sid: u64, max: ?u64) Writer.Error!void {
    try w.print("UNSUB {d}", .{sid});
    if (max) |m| try w.print(" {d}", .{m});
    try w.writeAll("\r\n");
}

pub fn unsubLen(sid: u64, max: ?u64) usize {
    return "UNSUB ".len + digits(sid) + (if (max) |m| 1 + digits(m) else 0) + 2;
}

/// The largest size the server reads in a PUB, HPUB or UNSUB line: it
/// takes nine digits at most.
pub const max_size = 999_999_999;

/// The arguments of a PUB line: what the server counts against its
/// `max_control_line`, the line without `PUB ` and CRLF.
pub fn pubArgsLen(subject: []const u8, reply_to: ?[]const u8, payload_len: usize) usize {
    return subject.len + replyLen(reply_to) + 1 + digits(payload_len);
}

/// The arguments of an HPUB line, as `pubArgsLen` counts them.
pub fn hpubArgsLen(subject: []const u8, reply_to: ?[]const u8, header_len: usize, payload_len: usize) usize {
    return subject.len + replyLen(reply_to) + 1 + digits(header_len) + 1 + digits(header_len + payload_len);
}

/// The arguments of a SUB line, as `pubArgsLen` counts them.
pub fn subArgsLen(subject: []const u8, queue: ?[]const u8, sid: u64) usize {
    return subject.len + replyLen(queue) + 1 + digits(sid);
}

/// The length of the block `writeHeaderBlock` writes; HPUB announces it.
pub fn headerBlockLen(headers: []const Header) usize {
    var len: usize = "NATS/1.0\r\n".len + 2;
    for (headers) |header| len += header.name.len + 2 + header.value.len + 2;
    return len;
}

/// Writes `NATS/1.0`, one `Name: value` line per header and the blank line.
pub fn writeHeaderBlock(w: *Writer, headers: []const Header) Writer.Error!void {
    try w.writeAll("NATS/1.0\r\n");
    for (headers) |header| {
        try w.writeAll(header.name);
        try w.writeAll(": ");
        try w.writeAll(header.value);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
}

fn replyLen(optional: ?[]const u8) usize {
    return if (optional) |s| 1 + s.len else 0;
}

fn digits(n: u64) usize {
    return std.fmt.count("{d}", .{n});
}

const testing = std.testing;

/// Writes one frame into a buffer and checks that `len` predicted it.
fn expectFrame(expected: []const u8, len: usize, frame: anytype) !void {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try @call(.auto, frame[0], .{&w} ++ frame[1]);
    try testing.expectEqualStrings(expected, w.buffered());
    try testing.expectEqual(expected.len, len);
}

test "client frames match what nats-server 2.15.1 accepted" {
    // Recorded from nats-server 2.15.1, which accepted every one of them.
    try expectFrame("SUB foo 1\r\n", subLen("foo", null, 1), .{ writeSub, .{ "foo", null, 1 } });
    try expectFrame("SUB foo.* 2\r\n", subLen("foo.*", null, 2), .{ writeSub, .{ "foo.*", null, 2 } });
    try expectFrame("SUB q.work workers 3\r\n", subLen("q.work", "workers", 3), .{ writeSub, .{ "q.work", "workers", 3 } });
    try expectFrame("PUB foo 5\r\nhello\r\n", pubLen("foo", null, 5), .{ writePub, .{ "foo", null, "hello" } });
    try expectFrame("PUB foo reply.to.me 5\r\nworld\r\n", pubLen("foo", "reply.to.me", 5), .{ writePub, .{ "foo", "reply.to.me", "world" } });
    try expectFrame("PUB foo.bar 0\r\n\r\n", pubLen("foo.bar", null, 0), .{ writePub, .{ "foo.bar", null, "" } });
    try expectFrame("UNSUB 6 1\r\n", unsubLen(6, 1), .{ writeUnsub, .{ 6, 1 } });
    try expectFrame("UNSUB 6\r\n", unsubLen(6, null), .{ writeUnsub, .{ 6, null } });

    const multi = [_]Header{ .{ .name = "X-Multi", .value = "one" }, .{ .name = "X-Multi", .value = "two" }, .{ .name = "X-Single", .value = "v" } };
    try expectFrame(
        "HPUB h.test 53 61\r\nNATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nX-Single: v\r\n\r\npayload!\r\n",
        hpubLen("h.test", null, headerBlockLen(&multi), 8),
        .{ writeHpub, .{ "h.test", null, @as([]const Header, &multi), "payload!" } },
    );
    const only = [_]Header{.{ .name = "X-Only-Header", .value = "yes" }};
    try expectFrame(
        "HPUB h.test reply.h 32 32\r\nNATS/1.0\r\nX-Only-Header: yes\r\n\r\n\r\n",
        hpubLen("h.test", "reply.h", headerBlockLen(&only), 0),
        .{ writeHpub, .{ "h.test", "reply.h", @as([]const Header, &only), "" } },
    );
    try testing.expectEqualStrings("PING\r\n", ping);
    try testing.expectEqualStrings("PONG\r\n", pong);
}

test "lengths across digit boundaries" {
    var payload: [1001]u8 = undefined;
    @memset(&payload, 'x');
    const headers = [_]Header{.{ .name = "A", .value = "b" }}; // a 18-byte block
    for ([_]usize{ 0, 1, 9, 10, 81, 82, 99, 100, 981, 982, 999, 1000, 1001 }) |n| {
        var buffer: [1200]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try writePub(&w, "s", "r", payload[0..n]);
        try testing.expectEqual(w.buffered().len, pubLen("s", "r", n));
        w = .fixed(&buffer);
        try writeHpub(&w, "s", null, &headers, payload[0..n]);
        try testing.expectEqual(w.buffered().len, hpubLen("s", null, headerBlockLen(&headers), n));
    }
    for ([_]u64{ 0, 9, 10, std.math.maxInt(u64) }) |n| {
        var buffer: [64]u8 = undefined;
        var w: Writer = .fixed(&buffer);
        try writeSub(&w, "s", null, n);
        try testing.expectEqual(w.buffered().len, subLen("s", null, n));
        w = .fixed(&buffer);
        try writeUnsub(&w, n, n);
        try testing.expectEqual(w.buffered().len, unsubLen(n, n));
    }
}

/// The arguments of the line `frame` starts with: after `op` and its
/// space, up to CRLF.
fn argsOf(frame: []const u8, op: []const u8) usize {
    const line_end = std.mem.find(u8, frame, "\r\n").?;
    return line_end - op.len - 1;
}

test "the arguments of a line, as the server counts them" {
    const headers = [_]Header{.{ .name = "A", .value = "b" }};
    const payload: [1000]u8 = @splat('x');
    for ([_]usize{ 0, 9, 10, 1000 }) |n| {
        var buffer: [1200]u8 = undefined;
        for ([_]?[]const u8{ null, "reply.to" }) |reply| {
            var w: Writer = .fixed(&buffer);
            try writePub(&w, "s.t", reply, payload[0..n]);
            try testing.expectEqual(argsOf(w.buffered(), "PUB"), pubArgsLen("s.t", reply, n));
            w = .fixed(&buffer);
            try writeHpub(&w, "s.t", reply, &headers, payload[0..n]);
            try testing.expectEqual(argsOf(w.buffered(), "HPUB"), hpubArgsLen("s.t", reply, headerBlockLen(&headers), n));
        }
    }
    for ([_]?[]const u8{ null, "workers" }) |queue| {
        for ([_]u64{ 1, 10, std.math.maxInt(u64) }) |sid| {
            var buffer: [64]u8 = undefined;
            var w: Writer = .fixed(&buffer);
            try writeSub(&w, "s.*", queue, sid);
            try testing.expectEqual(argsOf(w.buffered(), "SUB"), subArgsLen("s.*", queue, sid));
        }
    }
}

test "CONNECT sends verbose and pedantic always, headers only when the server has them" {
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeConnect(&w, .{ .headers = true, .no_responders = true });
    try testing.expectEqualStrings("CONNECT {\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"" ++ version ++
        "\",\"protocol\":1,\"echo\":true,\"headers\":true,\"no_responders\":true}\r\n", w.buffered());
    try testing.expectEqual(w.buffered().len - "CONNECT ".len - 2, connectJsonLen(.{ .headers = true, .no_responders = true }));

    w = .fixed(&buffer);
    try writeConnect(&w, .{ .headers = false, .no_responders = true, .echo = false });
    try testing.expectEqualStrings("CONNECT {\"verbose\":false,\"pedantic\":false,\"lang\":\"zig\",\"version\":\"" ++ version ++
        "\",\"protocol\":1,\"echo\":false}\r\n", w.buffered());

    w = .fixed(&buffer);
    try writeConnect(&w, .{ .headers = true, .no_responders = false, .name = "orders", .user = "a", .pass = "b" });
    try testing.expectStringEndsWith(w.buffered(), ",\"headers\":true,\"name\":\"orders\",\"user\":\"a\",\"pass\":\"b\"}\r\n");
}

test "CONNECT escapes names and credentials as JSON" {
    const connect: Connect = .{
        .headers = true,
        .no_responders = true,
        .name = "svc \"quoted\" \\ back\x01ctl ünï",
        .user = "user\ttab",
        .pass = "p\"w\\d\r\n}",
    };
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeConnect(&w, connect);
    const frame = w.buffered();
    try testing.expect(std.mem.findAny(u8, frame[0 .. frame.len - 2], "\r\n") == null);
    const json = frame["CONNECT ".len .. frame.len - 2];
    try testing.expectEqual(json.len, connectJsonLen(connect));

    const Parsed = struct { name: []const u8, user: []const u8, pass: []const u8 };
    const parsed = try std.json.parseFromSlice(Parsed, testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings(connect.name.?, parsed.value.name);
    try testing.expectEqualStrings(connect.user.?, parsed.value.user);
    try testing.expectEqualStrings(connect.pass.?, parsed.value.pass);
}

test "the header block round-trips through Headers and matches its length" {
    const headers = [_]Header{ .{ .name = "X-Multi", .value = "one" }, .{ .name = "X-Multi", .value = "two" }, .{ .name = "X-Single", .value = "v" } };
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeHeaderBlock(&w, &headers);
    // The block nats-server 2.15.1 relayed in HMSG h.test 4 53 61.
    try testing.expectEqualStrings("NATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nX-Single: v\r\n\r\n", w.buffered());
    try testing.expectEqual(53, headerBlockLen(&headers));
    try testing.expectEqual(w.buffered().len, headerBlockLen(&headers));

    const h: Headers = .{ .block = w.buffered() };
    var fields = h.iterator();
    for (headers) |expected| {
        const field = fields.next().?;
        try testing.expectEqualStrings(expected.name, field.name);
        try testing.expectEqualStrings(expected.value, field.value);
    }
    try testing.expect(fields.next() == null);
}
