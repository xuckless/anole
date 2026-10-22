//! The video-call app (bench/videocall/SPEC.md) on Anole: sign-up, a lobby
//! that pairs users into 1:1 calls, chat, and a media relay that deflates
//! every packet it forwards, over WebSocket and WebTransport.
//!
//!   zig build -Doptimize=ReleaseSafe && zig-out/bin/videocall
const std = @import("std");
const anole = @import("anole");
const websocket = anole.websocket;
const wt = anole.webtransport;
const zlib = anole.compression.zlib;

pub const std_options = anole.std_options;
pub const panic = anole.panic;

const header_len = 24;
/// The largest media message: the header and 1 MiB of payload.
const max_media = header_len + (1 << 20);
const history_len = 100;
const kind_video = 1;
const flag_compressed = 2;

/// A user's realtime connection, on either transport.
const Conn = union(enum) {
    ws: *websocket.Socket,
    wt: *WtLink,
};

/// The server's side of a WebTransport session: the control stream the
/// client opened, and the media streams we open to it, one per kind.
const WtLink = struct {
    session: *wt.Session,
    control: *wt.Stream,
    media: [2]?*wt.Stream = .{ null, null },
};

const User = struct {
    id: u64,
    name: []const u8,
    token: [32]u8,
    /// Under `App.mutex`.
    call: ?*Call = null,
    connected: bool = false,
    /// Held while anything is sent to this user, so messages from different
    /// tasks don't interleave, and the connection isn't torn down mid-send.
    send_mutex: std.Io.Mutex = .init,
    conn: ?Conn = null,
};

const Call = struct {
    id: u64,
    a: *User,
    b: *User,
    next_message: u64 = 1,
    /// The last `history_len` chat messages as they were broadcast, oldest
    /// first.
    history: std.ArrayList([]u8) = .empty,

    fn peerOf(call: *Call, user: *User) *User {
        return if (call.a == user) call.b else call.a;
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    users: std.ArrayList(*User) = .empty,
    tokens: std.StringHashMapUnmanaged(*User) = .empty,
    calls: std.ArrayList(*Call) = .empty,
    lobby: std.ArrayList(*User) = .empty,

    fn deinit(app: *App) void {
        for (app.calls.items) |call| {
            for (call.history.items) |m| app.gpa.free(m);
            call.history.deinit(app.gpa);
            app.gpa.destroy(call);
        }
        for (app.users.items) |user| {
            app.gpa.free(user.name);
            app.gpa.destroy(user);
        }
        app.calls.deinit(app.gpa);
        app.users.deinit(app.gpa);
        app.tokens.deinit(app.gpa);
        app.lobby.deinit(app.gpa);
    }

    /// The user a bearer token or `?token=` names.
    fn userByToken(app: *App, io: std.Io, token: ?[]const u8) !?*User {
        const t = token orelse return null;
        try app.mutex.lock(io);
        defer app.mutex.unlock(io);
        return app.tokens.get(t);
    }
};

// --- HTTP API -------------------------------------------------------------

fn health(_: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .status = "ok" });
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn createUser(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const body = try req.body() orelse return res.fail(.bad_request, "malformed JSON body");
    const in = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch
        return res.fail(.bad_request, "malformed JSON body");
    const name = switch (in) {
        .object => |o| switch (o.get("name") orelse .null) {
            .string => |s| s,
            else => "",
        },
        else => "",
    };
    if (!validName(name)) return res.fail(.bad_request, "invalid name");

    var secret: [16]u8 = undefined;
    try req.io.randomSecure(&secret);
    const user = try app.gpa.create(User);
    errdefer app.gpa.destroy(user);
    user.* = .{ .id = 0, .name = try app.gpa.dupe(u8, name), .token = std.fmt.bytesToHex(secret, .lower) };
    errdefer app.gpa.free(user.name);
    {
        try app.mutex.lock(req.io);
        defer app.mutex.unlock(req.io);
        try app.users.append(app.gpa, user);
        user.id = app.users.items.len;
        try app.tokens.put(app.gpa, &user.token, user);
    }
    res.status = .created;
    try res.json(.{ .id = user.id, .name = user.name, .token = &user.token });
}

fn bearer(req: *anole.Request) ?[]const u8 {
    const h = req.headers.get("Authorization") orelse return null;
    if (!std.mem.startsWith(u8, h, "Bearer ")) return null;
    return h["Bearer ".len..];
}

fn callMessages(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const user = try app.userByToken(req.io, bearer(req)) orelse return res.fail(.unauthorized, "unauthorized");
    const id = req.params.getInt(u64, "id") orelse 0;
    var out: std.Io.Writer.Allocating = .init(req.arena);
    {
        try app.mutex.lock(req.io);
        defer app.mutex.unlock(req.io);
        if (id == 0 or id > app.calls.items.len) return res.fail(.not_found, "call not found");
        const call = app.calls.items[id - 1];
        if (call.a != user and call.b != user) return res.fail(.forbidden, "forbidden");
        try out.writer.print("{{\"call_id\":{d},\"messages\":[", .{id});
        for (call.history.items, 0..) |m, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(m);
        }
        try out.writer.writeAll("]}");
    }
    res.content_type = .json;
    res.body = out.written();
}

// --- realtime: what both transports share ---------------------------------

/// Messages to send once `App.mutex` is let go.
const Outbox = struct {
    items: std.ArrayList(struct { to: *User, text: []const u8 }) = .empty,

    fn add(o: *Outbox, arena: std.mem.Allocator, to: *User, text: []const u8) !void {
        try o.items.append(arena, .{ .to = to, .text = text });
    }

    fn flush(o: *Outbox, io: std.Io) void {
        for (o.items.items) |m| sendText(io, m.to, m.text);
    }
};

fn sendText(io: std.Io, user: *User, text: []const u8) void {
    user.send_mutex.lockUncancelable(io);
    defer user.send_mutex.unlock(io);
    switch (user.conn orelse return) {
        .ws => |ws| ws.send(.text, text) catch {},
        .wt => |link| writeFrame(link.control, text) catch {},
    }
}

fn sendMedia(io: std.Io, user: *User, kind: u8, msg: []const u8) void {
    user.send_mutex.lockUncancelable(io);
    defer user.send_mutex.unlock(io);
    switch (user.conn orelse return) {
        .ws => |ws| ws.send(.binary, msg) catch {},
        .wt => |link| {
            const slot = &link.media[if (kind == kind_video) 0 else 1];
            if (slot.* == null) slot.* = link.session.openUniStream() catch return;
            writeFrame(slot.*.?, msg) catch {};
        },
    }
}

/// One WebTransport message: a u32 LE length, then the bytes.
fn writeFrame(stream: *wt.Stream, bytes: []const u8) !void {
    const w = stream.writer();
    try w.writeInt(u32, @intCast(bytes.len), .little);
    try w.writeAll(bytes);
    try w.flush();
}

/// Pairs the two longest-waiting users while two are waiting, with the
/// `call` messages for them in `out`. Under `App.mutex`.
fn pairLocked(app: *App, arena: std.mem.Allocator, out: *Outbox) !void {
    while (app.lobby.items.len >= 2) {
        const a = app.lobby.orderedRemove(0);
        const b = app.lobby.orderedRemove(0);
        const call = try app.gpa.create(Call);
        call.* = .{ .id = app.calls.items.len + 1, .a = a, .b = b };
        try app.calls.append(app.gpa, call);
        a.call = call;
        b.call = call;
        try out.add(arena, a, try callMessage(arena, call, b));
        try out.add(arena, b, try callMessage(arena, call, a));
    }
}

fn callMessage(arena: std.mem.Allocator, call: *Call, peer: *User) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .type = "call",
        .call_id = call.id,
        .peer = .{ .id = peer.id, .name = peer.name },
    }, .{});
}

/// Ends `user`'s call: the peer hears `peer_left` and goes back to the
/// lobby, and so does `user` when `requeue` (a `leave`, not a disconnect).
fn endCallLocked(app: *App, arena: std.mem.Allocator, user: *User, requeue: bool, out: *Outbox) !void {
    const call = user.call orelse return;
    const peer = call.peerOf(user);
    call.a.call = null;
    call.b.call = null;
    if (peer.connected) {
        try out.add(arena, peer, try std.fmt.allocPrint(arena, "{{\"type\":\"peer_left\",\"call_id\":{d}}}", .{call.id}));
        try app.lobby.append(app.gpa, peer);
    }
    if (requeue and user.connected) try app.lobby.append(app.gpa, user);
    try pairLocked(app, arena, out);
}

/// A user whose connection is open: greeting, lobby, and the calls that
/// follow; one per connection, used by its own task only.
const Session = struct {
    app: *App,
    io: std.Io,
    user: *User,
    /// Reset after each message.
    arena: std.heap.ArenaAllocator,

    fn init(app: *App, io: std.Io, user: *User) Session {
        return .{ .app = app, .io = io, .user = user, .arena = .init(app.gpa) };
    }

    fn deinit(s: *Session) void {
        s.arena.deinit();
    }

    /// The connection is up (`user.conn` set): say hello and join the lobby.
    fn open(s: *Session) !void {
        defer _ = s.arena.reset(.retain_capacity);
        const a = s.arena.allocator();
        const app = s.app;
        sendText(s.io, s.user, try std.json.Stringify.valueAlloc(a, .{
            .type = "hello",
            .user = .{ .id = s.user.id, .name = s.user.name },
        }, .{}));
        var out: Outbox = .{};
        {
            try app.mutex.lock(s.io);
            defer app.mutex.unlock(s.io);
            try app.lobby.append(app.gpa, s.user);
            try pairLocked(app, a, &out);
        }
        out.flush(s.io);
    }

    /// The connection is gone: nothing more is sent to it, the call ends,
    /// and the user leaves the lobby.
    fn close(s: *Session, link: ?*WtLink) void {
        const app, const user = .{ s.app, s.user };
        {
            user.send_mutex.lockUncancelable(s.io);
            defer user.send_mutex.unlock(s.io);
            user.conn = null;
            if (link) |l| for (l.media) |m| if (m) |stream| stream.release();
        }
        _ = s.arena.reset(.retain_capacity);
        var out: Outbox = .{};
        {
            app.mutex.lockUncancelable(s.io);
            defer app.mutex.unlock(s.io);
            user.connected = false;
            for (app.lobby.items, 0..) |u, i| if (u == user) {
                _ = app.lobby.orderedRemove(i);
                break;
            };
            endCallLocked(app, s.arena.allocator(), user, false, &out) catch {};
        }
        out.flush(s.io);
    }

    fn text(s: *Session, data: []const u8) !void {
        defer _ = s.arena.reset(.retain_capacity);
        const a = s.arena.allocator();
        const app, const user = .{ s.app, s.user };
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch
            return sendText(s.io, user, "{\"type\":\"error\",\"error\":\"bad message\"}");
        const obj = switch (msg) {
            .object => |o| o,
            else => return sendText(s.io, user, "{\"type\":\"error\",\"error\":\"bad message\"}"),
        };
        const kind = switch (obj.get("type") orelse .null) {
            .string => |t| t,
            else => "",
        };
        var out: Outbox = .{};
        if (std.mem.eql(u8, kind, "chat")) {
            const body = switch (obj.get("text") orelse .null) {
                .string => |t| t,
                else => "",
            };
            const sent_us: i64 = switch (obj.get("sent_us") orelse .null) {
                .integer => |n| n,
                else => -1,
            };
            const chars = std.unicode.utf8CountCodepoints(body) catch 0;
            if (chars < 1 or chars > 500 or sent_us < 0)
                return sendText(s.io, user, "{\"type\":\"error\",\"error\":\"invalid chat\"}");
            const in_call = blk: {
                try app.mutex.lock(s.io);
                defer app.mutex.unlock(s.io);
                const call = user.call orelse break :blk false;
                const line = try std.json.Stringify.valueAlloc(a, .{
                    .type = "chat",
                    .call_id = call.id,
                    .id = call.next_message,
                    .from = user.name,
                    .text = body,
                    .sent_us = sent_us,
                }, .{});
                call.next_message += 1;
                if (call.history.items.len == history_len) app.gpa.free(call.history.orderedRemove(0));
                try call.history.append(app.gpa, try app.gpa.dupe(u8, line));
                try out.add(a, user, line);
                try out.add(a, call.peerOf(user), line);
                break :blk true;
            };
            if (!in_call) return sendText(s.io, user, "{\"type\":\"error\",\"error\":\"not in a call\"}");
        } else if (std.mem.eql(u8, kind, "leave")) {
            try app.mutex.lock(s.io);
            defer app.mutex.unlock(s.io);
            try endCallLocked(app, a, user, true, &out);
        } else {
            return sendText(s.io, user, "{\"type\":\"error\",\"error\":\"bad message\"}");
        }
        out.flush(s.io);
    }

    /// Relays a media message to the peer, its payload deflated.
    fn media(s: *Session, packer: *Packer, msg: []const u8) !void {
        if (msg.len < header_len or msg[1] & flag_compressed != 0) return;
        const peer = blk: {
            try s.app.mutex.lock(s.io);
            defer s.app.mutex.unlock(s.io);
            const call = s.user.call orelse return;
            break :blk call.peerOf(s.user);
        };
        sendMedia(s.io, peer, msg[0], try packer.pack(msg));
    }
};

/// Deflates media payloads (raw DEFLATE at zlib's default level, each
/// message a stream of its own), reusing one compressor and buffer.
const Packer = struct {
    gpa: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    z: ?zlib.Compress = null,

    fn init(gpa: std.mem.Allocator) !Packer {
        return .{ .gpa = gpa, .out = try .initCapacity(gpa, 64 * 1024) };
    }

    fn deinit(p: *Packer) void {
        if (p.z) |*z| z.deinit();
        p.out.deinit();
    }

    fn pack(p: *Packer, msg: []const u8) ![]const u8 {
        p.out.clearRetainingCapacity();
        try p.out.writer.writeAll(msg[0..header_len]);
        if (p.z) |*z| z.reset(&p.out.writer) else p.z = try .init(p.gpa, &p.out.writer, &.{}, .raw, .{});
        const z = &p.z.?;
        try z.writer.writeAll(msg[header_len..]);
        try z.finish();
        const packed_msg = p.out.written();
        packed_msg[1] |= flag_compressed;
        return packed_msg;
    }
};

/// Checks the token and claims the user's one connection; the answer to
/// send instead when that fails.
fn claim(app: *App, req: *anole.Request, res: *anole.Response) !?*User {
    const user = try app.userByToken(req.io, req.query.get("token")) orelse {
        res.fail(.unauthorized, "unauthorized");
        return null;
    };
    try app.mutex.lock(req.io);
    defer app.mutex.unlock(req.io);
    if (user.connected) {
        res.fail(.conflict, "already connected");
        return null;
    }
    user.connected = true;
    return user;
}

fn release(app: *App, io: std.Io, user: *User) void {
    app.mutex.lockUncancelable(io);
    defer app.mutex.unlock(io);
    user.connected = false;
}

// --- WebSocket ------------------------------------------------------------

fn wsConnect(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const user = try claim(app, req, res) orelse return;
    var ws = (anole.websocket.upgrade(req, res, .{
        .max_message_size = max_media,
        .compression = false,
        .allowed_origins = .any,
    }) catch |err| {
        release(app, req.io, user);
        return err;
    }) orelse {
        release(app, req.io, user);
        return res.fail(.bad_request, "this endpoint speaks WebSocket");
    };
    defer ws.deinit();

    var session: Session = .init(app, req.io, user);
    defer session.deinit();
    var packer: Packer = try .init(app.gpa);
    defer packer.deinit();
    {
        user.send_mutex.lockUncancelable(req.io);
        defer user.send_mutex.unlock(req.io);
        user.conn = .{ .ws = &ws };
    }
    defer session.close(null);
    try session.open();
    while (try ws.next()) |msg| switch (msg.type) {
        .text => try session.text(msg.data),
        .binary => try session.media(&packer, msg.data),
        else => {},
    };
}

// --- WebTransport ---------------------------------------------------------

fn wtConnect(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const user = try claim(app, req, res) orelse return;
    const s = (wt.accept(req, res, .{ .allowed_origins = .any }) catch |err| {
        release(app, req.io, user);
        return err;
    }) orelse {
        release(app, req.io, user);
        return res.fail(.bad_request, "this endpoint speaks WebTransport over HTTP/3");
    };
    defer s.deinit();
    const control = s.acceptStream() catch {
        release(app, req.io, user);
        return;
    };
    defer control.release();

    var link: WtLink = .{ .session = s, .control = control };
    var session: Session = .init(app, req.io, user);
    defer session.deinit();
    {
        user.send_mutex.lockUncancelable(req.io);
        defer user.send_mutex.unlock(req.io);
        user.conn = .{ .wt = &link };
    }
    defer session.close(&link);
    try session.open();

    // Media arrives on the uni streams the client opens; text on control.
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    try group.concurrent(req.io, acceptMedia, .{ &session, s });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(app.gpa);
    while (readFrame(control.reader(), app.gpa, &buf) catch null) |msg| try session.text(msg);
    s.close(0, "") catch {};
}

fn acceptMedia(session: *Session, s: *wt.Session) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(session.io);
    while (true) {
        const stream = s.acceptUniStream() catch return;
        group.concurrent(session.io, readMedia, .{ session, s, stream }) catch stream.release();
    }
}

fn readMedia(session: *Session, s: *wt.Session, stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    const gpa = session.app.gpa;
    var packer = Packer.init(gpa) catch return;
    defer packer.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (true) {
        const msg = readFrame(stream.reader(), gpa, &buf) catch |err| {
            if (err == error.TooLarge) s.close(0, "message too large") catch {};
            return;
        } orelse return;
        session.media(&packer, msg) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
    }
}

/// The next u32 LE length-prefixed message, or null at the end.
fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !?[]u8 {
    const n = r.takeInt(u32, .little) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    if (n > max_media) return error.TooLarge;
    try buf.resize(gpa, n);
    try r.readSliceAll(buf.items);
    return buf.items;
}

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const port = std.fmt.parseInt(u16, env.get("PORT") orelse "8443", 10) catch 8443;
    const cert: anole.Cert = .fromFiles(env.get("CERT") orelse "/certs/cert.pem", env.get("KEY") orelse "/certs/key.pem");

    var state: App = .{ .gpa = init.gpa };
    defer state.deinit();
    var app = try anole.Server(App).init(init.gpa, .{
        .errors = .json,
        .https = .{ .address = "0.0.0.0", .port = port, .cert = cert },
        .http3 = .{ .webtransport = true },
    }, &state);
    defer app.deinit();

    app.get("/health", health);
    app.post("/api/users", createUser);
    app.get("/api/calls/:id/messages", callMessages);
    app.get("/ws", wsConnect);
    app.get("/wt", wtConnect);
    try app.run();
}
