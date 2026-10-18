//! The server side of the interop runner's WebTransport mode
//! (quic-interop-runner's webtransport.md; tests/interop/webtransport):
//! sessions on /ENDPOINT, files from WWW/ENDPOINT, saved to
//! DOWNLOADS/ENDPOINT.
//!
//!   wt-interop-server CERT KEY WWW DOWNLOADS PORT TESTCASE PROTOCOLS REQUESTS
//!
//! TESTCASE `handshake` accepts sessions; `transfer` answers "GET name" on
//! unidirectional streams (with a stream of its own, "PUSH name\n" and the
//! file), on bidirectional streams (the file on the same stream) and in
//! datagrams ("PUSH name\n" and the file); `transfer-TYPE-send` asks the
//! client for each of REQUESTS ("endpoint/name ...") that way and closes the
//! session once every file is in. PROTOCOLS (space-separated) are the
//! application protocols the server takes: the first the client offers
//! (`wt-available-protocols`) is answered in `wt-protocol` and written to
//! DOWNLOADS/negotiated_protocol.txt.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;
const wt = anole.webtransport;

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

const Kind = enum { unidirectional, bidirectional, datagram };

const Ctx = struct {
    gpa: std.mem.Allocator,
    www: std.Io.Dir,
    downloads: std.Io.Dir,
    protocols: []const u8,
    /// Null: answer requests (`transfer`, `handshake`).
    send: ?Kind,
    requests: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cert = args.next() orelse return error.Usage;
    const key = args.next() orelse return error.Usage;
    const www = args.next() orelse return error.Usage;
    const downloads = args.next() orelse return error.Usage;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);
    const testcase = args.next() orelse return error.Usage;
    const protocols = args.next() orelse "";
    const requests = args.next() orelse "";

    var send: ?Kind = null;
    if (std.mem.startsWith(u8, testcase, "transfer-") and std.mem.endsWith(u8, testcase, "-send")) {
        send = std.meta.stringToEnum(Kind, testcase["transfer-".len .. testcase.len - "-send".len]) orelse return error.Usage;
    }
    const io = init.io;
    var ctx: Ctx = .{
        .gpa = init.gpa,
        .www = try std.Io.Dir.cwd().openDir(io, www, .{}),
        .downloads = try std.Io.Dir.cwd().openDir(io, downloads, .{}),
        .protocols = protocols,
        .send = send,
        .requests = requests,
    };
    var app = try anole.Server(Ctx).init(init.gpa, .{
        .http = null,
        .https = .{ .address = "0.0.0.0", .port = port, .cert = .{ .files = .{ .cert_path = cert, .key_path = key } } },
        .http3 = .{ .webtransport = true, .max_streams_bidi = 1000 },
    }, &ctx);
    defer app.deinit();
    app.get("/:endpoint", session);
    std.log.info("WebTransport interop server on port {d} ({s})", .{ port, testcase });
    try app.run();
}

/// The first protocol the client offers (`wt-available-protocols`, a
/// structured-field list of strings) that the server takes.
fn negotiate(offer: []const u8, ours: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, offer, ',');
    while (it.next()) |item| {
        const p = std.mem.trim(u8, std.mem.trim(u8, item, " \t"), "\"");
        var mine = std.mem.tokenizeScalar(u8, ours, ' ');
        while (mine.next()) |m| if (std.mem.eql(u8, m, p)) return p;
    }
    return null;
}

fn session(ctx: *Ctx, req: *http.Request, res: *http.Response) !void {
    const endpoint = req.params.get("endpoint") orelse return res.fail(.not_found, "");
    var chosen: []const u8 = "";
    if (req.headers.get("wt-available-protocols")) |offer| if (negotiate(offer, ctx.protocols)) |p| {
        chosen = p;
        try res.header("wt-protocol", try std.fmt.allocPrint(req.arena, "\"{s}\"", .{p}));
    };
    ctx.downloads.writeFile(req.io, .{ .sub_path = "negotiated_protocol.txt", .data = chosen }) catch {};
    const s = (try wt.accept(req, res, .{})) orelse return res.fail(.bad_request, "WebTransport only");
    defer s.deinit();
    std.log.info("session on /{s}, protocol \"{s}\"", .{ endpoint, chosen });
    const dir = ctx.www.openDir(req.io, endpoint, .{}) catch null;
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    if (ctx.send) |kind| {
        ask(ctx, s, req.io, endpoint, kind) catch |err| std.log.err("asking for files: {t}", .{err});
        s.close(0, "") catch {};
        return;
    }
    const files = dir orelse return wait(s);
    try group.concurrent(req.io, answerUni, .{ s, req.io, files });
    try group.concurrent(req.io, answerBidi, .{ s, req.io, files });
    try group.concurrent(req.io, answerDatagrams, .{ s, req.io, ctx.gpa, files });
    group.await(req.io) catch {};
}

/// Until the client closes the session.
fn wait(s: *wt.Session) void {
    while (s.acceptStream()) |stream| stream.release() else |_| {}
}

fn readRequest(stream: *wt.Stream, buf: []u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    _ = stream.reader().streamRemaining(&w) catch return null;
    const line = w.buffered();
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    return std.mem.trim(u8, line["GET ".len..], " \r\n");
}

fn sendFile(files: std.Io.Dir, io: std.Io, name: []const u8, out: *std.Io.Writer) !void {
    var file = try files.openFile(io, name, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var r = file.reader(io, &buf);
    _ = try r.interface.streamRemaining(out);
}

fn answerUni(s: *wt.Session, io: std.Io, files: std.Io.Dir) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const in = s.acceptUniStream() catch return;
        group.concurrent(io, pushOne, .{ s, io, files, in }) catch in.release();
    }
}

fn pushOne(s: *wt.Session, io: std.Io, files: std.Io.Dir, in: *wt.Stream) std.Io.Cancelable!void {
    var buf: [512]u8 = undefined;
    const name = readRequest(in, &buf);
    in.release();
    const n = name orelse return;
    const out = s.openUniStream() catch return;
    defer out.release();
    out.writer().print("PUSH {s}\n", .{n}) catch return;
    sendFile(files, io, n, out.writer()) catch |err| {
        std.log.warn("PUSH {s}: {t}", .{ n, err });
        out.reset(0);
        return;
    };
    out.closeSend() catch {};
}

fn answerBidi(s: *wt.Session, io: std.Io, files: std.Io.Dir) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = s.acceptStream() catch return;
        group.concurrent(io, answerOne, .{ io, files, stream }) catch stream.release();
    }
}

fn answerOne(io: std.Io, files: std.Io.Dir, stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    var buf: [512]u8 = undefined;
    const name = readRequest(stream, &buf) orelse return;
    sendFile(files, io, name, stream.writer()) catch |err| {
        std.log.warn("GET {s}: {t}", .{ name, err });
        stream.reset(0);
        return;
    };
    stream.closeSend() catch {};
}

fn answerDatagrams(s: *wt.Session, io: std.Io, gpa: std.mem.Allocator, files: std.Io.Dir) std.Io.Cancelable!void {
    var buf: [2048]u8 = undefined;
    while (true) {
        const d = s.receiveDatagram(&buf) catch return;
        if (!std.mem.startsWith(u8, d, "GET ")) continue;
        const name = std.mem.trim(u8, d["GET ".len..], " \r\n");
        const data = files.readFileAlloc(io, name, gpa, .limited(64 * 1024)) catch continue;
        defer gpa.free(data);
        const out = std.fmt.allocPrint(gpa, "PUSH {s}\n{s}", .{ name, data }) catch continue;
        defer gpa.free(out);
        s.sendDatagram(out) catch |err| std.log.warn("datagram PUSH {s} ({d} bytes): {t}", .{ name, out.len, err });
    }
}

/// transfer-KIND-send: every file of `endpoint` in REQUESTS, from the client.
fn ask(ctx: *Ctx, s: *wt.Session, io: std.Io, endpoint: []const u8, kind: Kind) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var it = std.mem.tokenizeScalar(u8, ctx.requests, ' ');
    while (it.next()) |r| {
        const slash = std.mem.indexOfScalar(u8, r, '/') orelse continue;
        if (std.mem.eql(u8, r[0..slash], endpoint)) try names.append(ctx.gpa, r[slash + 1 ..]);
    }
    try ctx.downloads.createDirPath(io, endpoint);
    const out = try ctx.downloads.openDir(io, endpoint, .{});
    defer out.close(io);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    switch (kind) {
        .bidirectional => {
            for (names.items) |n| try group.concurrent(io, askBidi, .{ ctx.gpa, s, io, out, n });
            try group.await(io);
        },
        .unidirectional => {
            for (names.items) |n| try group.concurrent(io, askUni, .{ s, n });
            for (names.items) |_| {
                const in = try s.acceptUniStream();
                defer in.release();
                try save(ctx.gpa, io, out, in.reader());
            }
            try group.await(io);
        },
        .datagram => {
            var got: usize = 0;
            var buf: [2048]u8 = undefined;
            // Spaced out, as the browser clients do: a burst of 200 would
            // outrun the receiver's datagram queue.
            for (names.items) |n| {
                const d = try std.fmt.bufPrint(&buf, "GET {s}", .{n});
                try s.sendDatagram(d);
                try io.sleep(.fromMilliseconds(5), .awake);
            }
            while (got < names.items.len) : (got += 1) {
                const d = try s.receiveDatagram(&buf);
                var r: std.Io.Reader = .fixed(d);
                try save(ctx.gpa, io, out, &r);
            }
        },
    }
    std.log.info("{d} files in from /{s}", .{ names.items.len, endpoint });
}

fn askUni(s: *wt.Session, name: []const u8) std.Io.Cancelable!void {
    const out = s.openUniStream() catch return;
    defer out.release();
    out.writer().print("GET {s}", .{name}) catch return;
    out.closeSend() catch {};
}

fn askBidi(gpa: std.mem.Allocator, s: *wt.Session, io: std.Io, dir: std.Io.Dir, name: []const u8) std.Io.Cancelable!void {
    const stream = s.openStream() catch return;
    defer stream.release();
    stream.writer().print("GET {s}", .{name}) catch return;
    stream.closeSend() catch return;
    const data = stream.reader().allocRemaining(gpa, .unlimited) catch return;
    defer gpa.free(data);
    dir.writeFile(io, .{ .sub_path = name, .data = data }) catch |err| std.log.err("saving {s}: {t}", .{ name, err });
}

/// "PUSH name\n" and the file, saved under its name.
fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, r: *std.Io.Reader) !void {
    const head = try r.takeDelimiterExclusive('\n');
    r.toss(1);
    if (!std.mem.startsWith(u8, head, "PUSH ")) return error.NotAPush;
    const name = try gpa.dupe(u8, std.mem.trim(u8, head["PUSH ".len..], " \r"));
    defer gpa.free(name);
    const data = try r.allocRemaining(gpa, .unlimited);
    defer gpa.free(data);
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}
