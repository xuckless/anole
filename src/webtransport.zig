//! WebTransport over HTTP/3 (-Dhttp3), the draft Chrome and Firefox speak
//! by default (draft-ietf-webtrans-http3-02): sessions with streams in
//! both directions and datagrams, on the same router as everything else.
//! The short form is a route of its own (`Server.webtransport`, through
//! `route`), which also turns WebTransport on for the HTTP/3 listener:
//!
//!     fn echo(session: *anole.webtransport.Session) !void {
//!         while (true) {
//!             const stream = session.acceptStream() catch return;
//!             defer stream.release();
//!             var buf: [4096]u8 = undefined;
//!             const n = try stream.reader().readSliceShort(&buf);
//!             try stream.writer().writeAll(buf[0..n]);
//!             try stream.closeSend();
//!         }
//!     }
//!     app.webtransport("/echo", echo);
//!
//! and from any handler, `accept`, once WebTransport is on
//! (`ServerOptions.Http3.webtransport`):
//!
//!     var session = (try anole.webtransport.accept(req, res, .{})) orelse
//!         return res.fail(.bad_request, "");
//!     defer session.deinit();
//!
//! A session is open until either side closes it (`Session.close`, with an
//! application code and a message), the CONNECT stream ends, or the
//! connection goes; then every stream of it is reset and every wait on it
//! fails with `error.SessionClosed`. When the server drains, each open
//! session gets DRAIN_WEBTRANSPORT_SESSION and is closed (code 0) unless
//! `AcceptOptions.close_on_drain` is off.
//!
//! nghttp3 has no WebTransport yet (ngtcp2/nghttp3 PR #442 waits for the
//! RFC): Anole's nghttp3 fork sends the SETTINGS, and the HTTP/3 engine
//! takes the WebTransport streams before nghttp3 sees them
//! (src/h3/webtransport.zig).
const std = @import("std");
const dusty = @import("dusty");
const engine = @import("h3/webtransport.zig");
const placement = dusty.placement;
const origin = @import("origin.zig");
/// Which pages may open a session (`AcceptOptions.allowed_origins`).
pub const Origins = origin.Origins;

/// A session: `acceptStream`, `acceptUniStream`, `openStream`,
/// `openUniStream`, `receiveDatagram`, `sendDatagram`, `close`.
pub const Session = engine.Session;
/// One stream: `reader`, `writer`, `closeSend`, `reset`, `stopSending`,
/// `release`.
pub const Stream = engine.Stream;
/// How a session ended: the application code, the reason, and which side
/// (`Session.closeInfo`).
pub const CloseInfo = engine.CloseInfo;
/// What session and stream calls fail with: `SessionClosed`,
/// `StreamReset`, `StreamStopped`, `ConnectionClosed`, `Canceled`.
pub const Error = engine.Error;

/// How `accept` (and `app.webtransportWith`) opens a session.
pub const AcceptOptions = struct {
    /// The pages that may open the session, by the CONNECT's `Origin`: by
    /// default only the request's own host and port (`:authority`). A
    /// browser request from anywhere else gets 403 (`error.Forbidden` from
    /// `accept`); clients that send no `Origin` are not affected. List the
    /// other sites (`.{ .list = &.{"https://app.example.com"} }`), or
    /// `.any` for an endpoint that does not rely on cookies.
    allowed_origins: Origins = .same_origin,
    /// Replaces the request's timeout once the session is open: a session
    /// outlives `timeout.request`.
    timeout: std.Io.Timeout = .none,
    /// When the server starts to drain, close the session (code 0, with
    /// `drain_reason`) right after the DRAIN_WEBTRANSPORT_SESSION capsule.
    /// Off: the session stays open until the handler ends it
    /// (`Session.draining` tells it to) or `timeout.shutdown` cuts it.
    close_on_drain: bool = true,
    /// The reason sent with the drain's close.
    drain_reason: []const u8 = "server shutting down",
};

/// The server's end of a session: the request body and the streamed
/// response of the CONNECT stream, in the request's arena.
const ServerSession = struct {
    session: Session,
    body: dusty.RequestBodyReader,
    out: dusty.StreamingBodyWriter,
    in_buf: [4 + engine.max_close_message + 16]u8,
    out_buf: [16 + engine.max_close_message]u8,

    fn end(ctx: *anyopaque) void {
        const self: *ServerSession = @ptrCast(@alignCast(ctx));
        self.out.end() catch {};
    }
};

/// Accepts the WebTransport session `req` asks for (an extended CONNECT
/// with `:protocol webtransport` over HTTP/3) and answers 200. Null when
/// `req` is no such request, or the listener does not speak WebTransport
/// (the handler answers it as it sees fit). The session lives in the
/// request's arena: `deinit` it before the handler returns.
pub fn accept(req: *dusty.Request, res: *dusty.Response, options: AcceptOptions) !?*Session {
    const connect = req.local(engine.Connect, engine.local_key) orelse return null;
    if (!origin.allowed(req, options.allowed_origins)) return error.Forbidden;
    const self = try req.arena.create(ServerSession);
    self.* = .{ .session = undefined, .body = undefined, .out = undefined, .in_buf = undefined, .out_buf = undefined };
    res.status = .ok;
    // Chrome sends this for draft-02, and h2o and aioquic answer it so.
    if (req.headers.get("sec-webtransport-http3-draft02") != null)
        try res.header("sec-webtransport-http3-draft", "draft02");
    self.out = try res.stream(&self.out_buf);
    self.body = try req.reader(&self.in_buf);
    try self.session.start(connect.core, connect.session_id, .{
        .reader = &self.body.interface,
        .writer = &self.out.interface,
        .ctx = self,
        .end_fn = ServerSession.end,
    }, .{
        .drain = req.drain,
        .close_on_drain = options.close_on_drain,
        .drain_reason = try req.arena.dupe(u8, options.drain_reason),
    });
    errdefer self.session.deinit();
    // The 200 out now: the client opens streams once it has it.
    try self.out.interface.flush();
    req.setDeadline(options.timeout);
    return &self.session;
}

/// A route handler for `Server.webtransport`: accepts, runs `handler` with
/// the session, and closes it when `handler` returns (code 0; a failed
/// handler's message says so). A request that is no WebTransport session
/// gets 400. `handler` is `fn (*Session) !void`, `fn (*Session, *Request)
/// !void`, or with the server's state first, `fn (*Ctx, *Session,
/// *Request) !void`.
pub fn route(comptime Ctx: type, comptime handler: anytype, comptime options: AcceptOptions) dusty.Router(Ctx).Handler {
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    switch (params.len) {
        1, 2 => {},
        3 => if (Ctx == void) @compileError("a WebTransport handler with three parameters takes the server's state first, but this server has none"),
        else => @compileError("a WebTransport handler takes (*anole.webtransport.Session) or (*anole.webtransport.Session, *anole.Request), got " ++ @typeName(@TypeOf(handler))),
    }
    const S = struct {
        fn serve(ctx: if (Ctx == void) void else *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            const session = (try accept(req, res, options)) orelse
                return res.fail(.bad_request, "this endpoint speaks WebTransport over HTTP/3");
            defer session.deinit();
            const result = switch (params.len) {
                1 => handler(session),
                2 => handler(session, req),
                3 => handler(ctx, session, req),
                else => unreachable,
            };
            result catch |err| {
                const e: anyerror = err;
                if (e == error.Canceled) return e;
                // The session or the connection went: not the handler's fault.
                if (e == error.SessionClosed or e == error.ConnectionClosed or res.peerGone()) return;
                std.log.scoped(.anole).warn("WebTransport handler for {s} failed: {t}", .{ req.url, e });
                session.close(0, "server error") catch {};
                return;
            };
            session.close(0, "") catch {};
        }
    };
    return if (Ctx == void) struct {
        fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return S.serve({}, req, res);
        }
    }.h else S.serve;
}

test {
    _ = engine;
    _ = @import("h3/webtransport_test.zig");
}
