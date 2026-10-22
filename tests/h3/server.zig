//! A server for checking HTTP/3 with an independent client
//! (tests/h3/client.py on aioquic): downloads, uploads and echoes of any
//! size, beside HTTP/1.1 and HTTP/2 on the same routes; WebSocket over
//! HTTP/3 (RFC 9220) at /ws and WebTransport at /wt, echoing.
//!
//!   zig build h3-test-server && zig-out/bin/h3-test-server 8443 [retry] [early] [drain=MS] [ADDRESS]
//!
//! With `retry`, every new client proves its address with a Retry first.
//! With `early`, clients that resume may send 0-RTT.
//! `drain=MS` bounds the shutdown drain (default 30 s). ADDRESS (default
//! 127.0.0.1) is where it listens, 0.0.0.0 for every interface.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

/// GET /slow?ms=N: answers after N milliseconds.
fn slow(req: *http.Request, res: *http.Response) !void {
    const ms = std.fmt.parseInt(i64, req.query.get("ms") orelse "0", 10) catch 0;
    try req.io.sleep(.fromMilliseconds(ms), .awake);
    res.body = "slow\n";
}

/// GET /download?n=BYTES: that many bytes, streamed.
fn download(req: *http.Request, res: *http.Response) !void {
    const n = std.fmt.parseInt(usize, req.query.get("n") orelse "0", 10) catch 0;
    var w = res.writer();
    var chunk: [16 * 1024]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @truncate(i);
    var left = n;
    while (left > 0) {
        const k = @min(left, chunk.len);
        try w.interface.writeAll(chunk[0..k]);
        left -= k;
    }
    try w.end();
}

/// GET /early, POST /early: whether the request may be a replay of 0-RTT
/// data ("early"), or not ("late").
fn early(req: *http.Request, res: *http.Response) !void {
    res.body = if (anole.early_data.isEarly(req)) "early" else "late";
}

/// POST /upload: the body's length and a checksum.
fn upload(req: *http.Request, res: *http.Response) !void {
    var reader_buf: [16 * 1024]u8 = undefined;
    var r = try req.reader(&reader_buf);
    var buf: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var sum: u32 = 0;
    while (true) {
        const got = r.interface.readSliceShort(&buf) catch return r.err orelse error.ReadFailed;
        if (got == 0) break;
        for (buf[0..got]) |b| sum +%= b;
        total += got;
    }
    try res.print(.text, "{d} {d}", .{ total, sum });
}

/// POST /echo: the body back, as it arrives.
fn echo(req: *http.Request, res: *http.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

/// WebSocket at /ws (RFC 9220 over HTTP/3): each message back. Only with
/// `-Dwebsocket`.
fn wsEcho(ws: *anole.websocket.Socket) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

const wt = anole.webtransport;

/// WebTransport at /wt: each bidirectional stream back on itself, each
/// unidirectional stream back on one the server opens, each datagram back.
/// A datagram "close" closes the session with code 7 and "asked to".
fn wtEcho(session: *wt.Session, req: *http.Request) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    try group.concurrent(req.io, wtBidi, .{ session, req.io });
    try group.concurrent(req.io, wtUni, .{session});
    try group.concurrent(req.io, wtDatagrams, .{session});
    group.await(req.io) catch {};
}

fn wtBidi(session: *wt.Session, io: std.Io) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = session.acceptStream() catch return;
        group.concurrent(io, wtStream, .{stream}) catch stream.release();
    }
}

fn wtStream(stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    _ = stream.reader().streamRemaining(stream.writer()) catch return;
    stream.closeSend() catch {};
}

fn wtUni(session: *wt.Session) std.Io.Cancelable!void {
    while (true) {
        const in = session.acceptUniStream() catch return;
        defer in.release();
        const out = session.openUniStream() catch return;
        defer out.release();
        _ = in.reader().streamRemaining(out.writer()) catch return;
        out.closeSend() catch return;
    }
}

fn wtDatagrams(session: *wt.Session) std.Io.Cancelable!void {
    var buf: [2048]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "close")) {
            session.close(7, "asked to") catch {};
            return;
        }
        session.sendDatagram(d) catch return;
    }
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8443;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    var retry = false;
    var early_data = false;
    var drain: ?std.Io.Duration = .fromSeconds(30);
    var address: []const u8 = "127.0.0.1";
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "retry")) {
            retry = true;
        } else if (std.mem.eql(u8, a, "early")) {
            early_data = true;
        } else if (std.mem.startsWith(u8, a, "drain=")) {
            drain = .fromMilliseconds(try std.fmt.parseInt(i64, a["drain=".len..], 10));
        } else address = a;
    }
    var app = try anole.Server(void).init(init.gpa, .{
        .http = null,
        .https = .{ .address = address, .port = port, .cert = .dev_self_signed },
        .http3 = .{ .validate_address = retry, .early_data = early_data },
        .server = .{ .timeout = .{ .shutdown = drain } },
    }, {});
    defer app.deinit();
    app.get("/download", download);
    app.get("/slow", slow);
    app.post("/upload", upload);
    app.post("/echo", echo);
    // The same, run inline when the request arrives whole (`noWait`): the
    // responses outgrow the ring with nothing waiting for the peer.
    app.get("/nw/download", anole.noWait(download));
    app.post("/nw/echo", anole.noWait(echo));
    app.get("/early", early);
    app.post("/early", early);
    if (anole.features.websocket) app.ws("/ws", wsEcho);
    app.webtransport("/wt", wtEcho);
    std.log.info("h3 test server on https://{s}:{d} (TCP and UDP)", .{ address, port });
    try app.run();
}
