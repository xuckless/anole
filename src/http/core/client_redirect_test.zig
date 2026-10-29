// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The client's redirect policy: the Referer it sends, where a body goes,
//! the policy hook, the private-address check, and long redirect chains.
const std = @import("std");
const dusty = @import("root.zig");

/// A peer on 127.0.0.1 that answers each request on one connection with
/// what `answer` returns for its head, and keeps the last head it saw.
const Peer = struct {
    listener: std.Io.net.Server,
    future: std.Io.Future(void) = undefined,
    answer: *const fn (peer: *Peer, head: []const u8, out: *std.Io.Writer) anyerror!void,
    /// Where another peer is (for redirects across origins).
    other_port: u16 = 0,
    last: [4096]u8 = undefined,
    last_len: usize = 0,
    requests: usize = 0,
    /// Set before the cancel: a cancel lands only once, so a read it
    /// interrupts must not lead back into `accept`.
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(io: std.Io, answer: *const fn (*Peer, []const u8, *std.Io.Writer) anyerror!void) !*Peer {
        const self = try std.testing.allocator.create(Peer);
        errdefer std.testing.allocator.destroy(self);
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .listener = try addr.listen(io, .{ .reuse_address = true }), .answer = answer };
        self.future = try io.concurrent(run, .{ self, io });
        return self;
    }

    fn stop(self: *Peer, io: std.Io) void {
        self.stopping.store(true, .release);
        self.future.cancel(io);
        self.listener.deinit(io);
        std.testing.allocator.destroy(self);
    }

    fn port(self: *const Peer) u16 {
        return self.listener.socket.address.getPort();
    }

    fn lastHead(self: *const Peer) []const u8 {
        return self.last[0..self.last_len];
    }

    fn run(self: *Peer, io: std.Io) void {
        while (!self.stopping.load(.acquire)) {
            const s = self.listener.accept(io) catch return;
            defer s.close(io);
            var rbuf: [8192]u8 = undefined;
            var rd = s.reader(io, &rbuf);
            var wbuf: [4096]u8 = undefined;
            var w = s.writer(io, &wbuf);
            while (true) {
                const request = readWholeRequest(&rd.interface) catch break;
                const n = @min(request.len, self.last.len);
                @memcpy(self.last[0..n], request[0..n]);
                self.last_len = n;
                self.requests += 1;
                rd.interface.toss(request.len);
                self.answer(self, request, &w.interface) catch break;
                w.interface.flush() catch break;
            }
        }
    }
};

/// Buffers one request, headers and Content-Length body, and returns it.
fn readWholeRequest(r: *std.Io.Reader) ![]const u8 {
    while (true) {
        const buf = r.buffered();
        if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |end| {
            var len: usize = 0;
            var lines = std.mem.splitSequence(u8, buf[0..end], "\r\n");
            while (lines.next()) |line| {
                const prefix = "content-length:";
                if (line.len > prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
                    len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " "), 10);
                }
            }
            if (buf.len >= end + 4 + len) return buf[0 .. end + 4 + len];
        }
        try r.fillMore();
    }
}

fn ok(_: *Peer, _: []const u8, out: *std.Io.Writer) !void {
    try out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
}

/// "/same": 302 to "/landed" here; "/307-same": 307 there; "/307-other" and
/// "/other": 307 and 302 to the other peer; anything else is 200.
fn redirector(peer: *Peer, head: []const u8, out: *std.Io.Writer) !void {
    const target = head[std.mem.indexOfScalar(u8, head, ' ').? + 1 ..];
    if (std.mem.startsWith(u8, target, "/same?")) {
        try out.writeAll("HTTP/1.1 302 Found\r\nLocation: /landed\r\nContent-Length: 0\r\n\r\n");
    } else if (std.mem.startsWith(u8, target, "/307-same ")) {
        try out.writeAll("HTTP/1.1 307 Temporary Redirect\r\nLocation: /landed\r\nContent-Length: 0\r\n\r\n");
    } else if (std.mem.startsWith(u8, target, "/307-other ")) {
        try out.print("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:{d}/landed\r\nContent-Length: 0\r\n\r\n", .{peer.other_port});
    } else if (std.mem.startsWith(u8, target, "/other?")) {
        try out.print("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/landed\r\nContent-Length: 0\r\n\r\n", .{peer.other_port});
    } else {
        try out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nlanded");
    }
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head[0 .. std.mem.indexOf(u8, head, "\r\n\r\n") orelse head.len], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn url(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

test "Client redirects: the Referer carries the whole URL within an origin and only the origin across" {
    const io = std.testing.io;
    const a = try Peer.start(io, redirector);
    defer a.stop(io);
    const b = try Peer.start(io, ok);
    defer b.stop(io);
    a.other_port = b.port();
    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var buf: [128]u8 = undefined;

    {
        var resp = try client.fetch(try url(&buf, a.port(), "/same?token=secret"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        var want: [128]u8 = undefined;
        try std.testing.expectEqualStrings(try url(&want, a.port(), "/same?token=secret"), header(a.lastHead(), "Referer").?);
    }
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/other?token=secret"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        var want: [128]u8 = undefined;
        try std.testing.expectEqualStrings(try url(&want, a.port(), "/"), header(b.lastHead(), "Referer").?);
    }
}

test "Client redirects: a 307 keeps its body within an origin, and is not followed with it to another" {
    const io = std.testing.io;
    const a = try Peer.start(io, redirector);
    defer a.stop(io);
    const b = try Peer.start(io, ok);
    defer b.stop(io);
    a.other_port = b.port();
    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var buf: [128]u8 = undefined;

    {
        var resp = try client.fetch(try url(&buf, a.port(), "/307-same"), .{ .method = .post, .body = "payload" });
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expect(std.mem.endsWith(u8, a.lastHead(), "\r\n\r\npayload"));
    }
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/307-other"), .{ .method = .post, .body = "payload" });
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.temporary_redirect, resp.status());
        try std.testing.expectEqual(@as(usize, 0), b.requests);
    }
    {
        // Without a body it is followed.
        var resp = try client.fetch(try url(&buf, a.port(), "/307-other"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expectEqual(@as(usize, 1), b.requests);
    }
}

const Decide = struct {
    var action: dusty.RedirectAction = .follow;
    var seen: ?dusty.Redirect = null;

    fn check(_: ?*anyopaque, redirect: *const dusty.Redirect) dusty.RedirectAction {
        seen = redirect.*;
        return action;
    }
};

test "Client redirects: check_redirect follows, stops or fails each one" {
    const io = std.testing.io;
    const a = try Peer.start(io, redirector);
    defer a.stop(io);
    const b = try Peer.start(io, ok);
    defer b.stop(io);
    a.other_port = b.port();
    var client = dusty.Client.init(std.testing.allocator, io, .{ .check_redirect = .{ .check = Decide.check } });
    defer client.deinit();
    var buf: [128]u8 = undefined;

    Decide.action = .follow;
    {
        // The hook replaces the default: this body goes to the other origin.
        var resp = try client.fetch(try url(&buf, a.port(), "/307-other"), .{ .method = .post, .body = "payload" });
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expect(std.mem.endsWith(u8, b.lastHead(), "\r\n\r\npayload"));
        const seen = Decide.seen.?;
        try std.testing.expectEqual(@as(u16, 307), seen.status);
        try std.testing.expect(seen.cross_origin and seen.has_body);
        try std.testing.expectEqual(dusty.Method.post, seen.method);
        try std.testing.expectEqual(@as(u8, 0), seen.hops);
    }
    Decide.action = .stop;
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/same?x=1"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.found, resp.status());
        try std.testing.expect(!Decide.seen.?.cross_origin);
    }
    Decide.action = .fail;
    try std.testing.expectError(error.RedirectRefused, client.fetch(try url(&buf, a.port(), "/same?x=1"), .{}));
}

/// "/dir/start": 302 to the relative "landed"; "/dir/sub/dots": 302 to
/// "../up/./landed?x=1"; anything else is 200.
fn relative(_: *Peer, head: []const u8, out: *std.Io.Writer) !void {
    const target = head[std.mem.indexOfScalar(u8, head, ' ').? + 1 ..];
    if (std.mem.startsWith(u8, target, "/dir/start ")) {
        try out.writeAll("HTTP/1.1 302 Found\r\nLocation: landed\r\nContent-Length: 0\r\n\r\n");
    } else if (std.mem.startsWith(u8, target, "/dir/sub/dots ")) {
        try out.writeAll("HTTP/1.1 302 Found\r\nLocation: ../up/./landed?x=1\r\nContent-Length: 0\r\n\r\n");
    } else {
        try out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nlanded");
    }
}

test "Client redirects: a relative Location resolves against the request's path, dot segments removed" {
    const io = std.testing.io;
    const a = try Peer.start(io, relative);
    defer a.stop(io);
    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var buf: [128]u8 = undefined;
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/dir/start"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expect(std.mem.startsWith(u8, a.lastHead(), "GET /dir/landed HTTP/1.1\r\n"));
    }
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/dir/sub/dots"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expect(std.mem.startsWith(u8, a.lastHead(), "GET /dir/up/landed?x=1 HTTP/1.1\r\n"));
    }
}

test "Client redirects: the Referer leaves out the URL's userinfo and fragment" {
    const io = std.testing.io;
    const a = try Peer.start(io, redirector);
    defer a.stop(io);
    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var buf: [128]u8 = undefined;
    const start = try std.fmt.bufPrint(&buf, "http://user:pass@127.0.0.1:{d}/same?token=1#frag", .{a.port()});
    var resp = try client.fetch(start, .{});
    defer resp.deinit();
    try std.testing.expectEqual(dusty.Status.ok, resp.status());
    var want: [128]u8 = undefined;
    try std.testing.expectEqualStrings(try url(&want, a.port(), "/same?token=1"), header(a.lastHead(), "Referer").?);
}

/// "/start": 302 to "/back" on the other peer by the name "localhost" (a
/// different host from 127.0.0.1); "/back": 302 to "/landed" on the other
/// peer at 127.0.0.1; anything else is 200.
fn hostHop(peer: *Peer, head: []const u8, out: *std.Io.Writer) !void {
    const target = head[std.mem.indexOfScalar(u8, head, ' ').? + 1 ..];
    if (std.mem.startsWith(u8, target, "/start ")) {
        try out.print("HTTP/1.1 302 Found\r\nLocation: http://localhost:{d}/back\r\nContent-Length: 0\r\n\r\n", .{peer.other_port});
    } else if (std.mem.startsWith(u8, target, "/back ")) {
        try out.print("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/landed\r\nContent-Length: 0\r\n\r\n", .{peer.other_port});
    } else {
        try out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nlanded");
    }
}

test "Client redirects: credentials stripped on a hop to another host stay stripped back on the first host" {
    const io = std.testing.io;
    const a = try Peer.start(io, hostHop);
    defer a.stop(io);
    const b = try Peer.start(io, hostHop);
    defer b.stop(io);
    a.other_port = b.port();
    b.other_port = a.port();
    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var headers = try dusty.Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Authorization", "Bearer secret");
    try headers.put("Cookie", "session=abc");
    try headers.put("X-Custom", "keep-me");
    var buf: [128]u8 = undefined;
    var resp = try client.fetch(try url(&buf, a.port(), "/start"), .{ .headers = &headers });
    defer resp.deinit();
    try std.testing.expectEqual(dusty.Status.ok, resp.status());
    try std.testing.expectEqual(@as(usize, 1), b.requests);
    try std.testing.expectEqual(@as(usize, 2), a.requests);
    // The last request is back on 127.0.0.1, the first hop's host.
    try std.testing.expect(std.mem.startsWith(u8, a.lastHead(), "GET /landed HTTP/1.1\r\n"));
    try std.testing.expect(header(a.lastHead(), "Authorization") == null);
    try std.testing.expect(header(a.lastHead(), "Cookie") == null);
    try std.testing.expectEqualStrings("keep-me", header(a.lastHead(), "X-Custom").?);
}

/// "/N" redirects to "/N-1" until "/0", which is 200.
fn countdown(_: *Peer, head: []const u8, out: *std.Io.Writer) !void {
    const target = head[std.mem.indexOfScalar(u8, head, ' ').? + 2 ..];
    const n = try std.fmt.parseInt(u32, target[0..std.mem.indexOfScalar(u8, target, ' ').?], 10);
    if (n == 0) return out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone");
    try out.print("HTTP/1.1 302 Found\r\nLocation: /{d}\r\nContent-Length: 0\r\n\r\n", .{n - 1});
}

test "Client redirects: a chain of 255 is followed, one hop at a time" {
    const io = std.testing.io;
    const a = try Peer.start(io, countdown);
    defer a.stop(io);
    var client = dusty.Client.init(std.testing.allocator, io, .{ .max_redirects = 255 });
    defer client.deinit();
    var buf: [128]u8 = undefined;
    {
        var resp = try client.fetch(try url(&buf, a.port(), "/255"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.ok, resp.status());
        try std.testing.expectEqualStrings("done", (try resp.body()).?);
    }
    {
        // One more than allowed: the last redirect is the response.
        var resp = try client.fetch(try url(&buf, a.port(), "/256"), .{});
        defer resp.deinit();
        try std.testing.expectEqual(dusty.Status.found, resp.status());
    }
}

test "Client: deny_private_addresses refuses a loopback server" {
    const io = std.testing.io;
    const a = try Peer.start(io, ok);
    defer a.stop(io);
    var client = dusty.Client.init(std.testing.allocator, io, .{ .deny_private_addresses = true });
    defer client.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.AddressNotAllowed, client.fetch(try url(&buf, a.port(), "/"), .{}));
    try std.testing.expectEqual(@as(usize, 0), a.requests);
}

test "isPrivateAddress: loopback, private, link-local, CGNAT, multicast, unspecified and mapped/NAT64/6to4 forms are private; public addresses are not" {
    const private = [_][]const u8{
        "127.0.0.1",  "10.1.2.3", "172.16.0.1",         "172.31.255.255",         "192.168.1.1", "169.254.169.254",
        "100.64.0.1", "0.0.0.0",  "224.0.0.1",          "255.255.255.255",        "198.18.0.1",  "192.0.0.8",
        "::1",        "::",       "::ffff:127.0.0.1",   "::ffff:169.254.169.254", "fe80::1",     "fd00::1",
        "fc00::1",    "ff02::1",  "64:ff9b::a9fe:a9fe", "2002:7f00:1::",
    };
    for (private) |text| {
        const a = try std.Io.net.IpAddress.parse(text, 80);
        std.testing.expect(dusty.isPrivateAddress(a)) catch |err| {
            std.debug.print("not private: {s}\n", .{text});
            return err;
        };
    }
    const public = [_][]const u8{ "8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1", "2001:4860:4860::8888", "::ffff:8.8.8.8", "2606:4700::1111" };
    for (public) |text| {
        const a = try std.Io.net.IpAddress.parse(text, 80);
        std.testing.expect(!dusty.isPrivateAddress(a)) catch |err| {
            std.debug.print("not public: {s}\n", .{text});
            return err;
        };
    }
}
