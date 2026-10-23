// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const DrainHooks = @import("drain_hooks.zig").DrainHooks;

const http = @import("http.zig");
const RouteInfo = @import("router.zig").RouteInfo;
const RequestParser = @import("parser.zig").RequestParser;
const RequestBodyReader = @import("parser.zig").RequestBodyReader;
/// Where an HTTP/2 or HTTP/3 stream's body comes from (`Request.body_source`).
pub const BodySource = @import("parser.zig").BodySource;
const Transport = @import("transport.zig").Transport;
const ParseError = @import("parser.zig").ParseError;
const ServerConfig = @import("config.zig").ServerConfig;
const Listener = @import("config.zig").Listener;
const body_read_reserve = @import("config.zig").body_read_reserve;
const Response = @import("response.zig").Response;
/// The request's cookies (`Request.cookies`).
pub const Cookie = @import("cookie.zig").Cookie;
/// `Request.session`, filled by `middleware.Session`.
pub const SessionData = @import("middleware/Session.zig").SessionData;
/// `Request.locals` (`setLocal`, `local`).
pub const Locals = @import("locals.zig").Locals;

const bind_mod = @import("bind.zig");
const bind_strings = @import("bind_strings.zig");
const bind_violations = @import("bind_violations.zig");
const validate = @import("validate");
const anole_log = @import("anole_log");

const scope_log = std.log.scoped(.anole);

const placeholder_listener: Listener = .{ .address = .{ .ip = .{ .ip4 = .unspecified(0) } } };

/// What a handler gets for one request, over any protocol (HTTP/1.1,
/// HTTP/2, HTTP/3): method, URL, headers, path and query parameters, and
/// the body, read on demand (`body`, `bind`, `reader`, `formData`).
///
/// Everything it holds lives until the response has gone out. Allocate
/// what the response needs from `arena`, which is freed in one go after
/// it; the strings the request hands out (headers, parameters, the body)
/// are borrowed for as long, so copy what must outlive it.
///
///     fn show(req: *anole.Request, res: *anole.Response) !void {
///         const id = req.params.getInt(u64, "id") orelse return error.NotFound;
///         const page = req.query.getInt(u32, "page") orelse 1;
///         const agent = req.headers.get("User-Agent") orelse "";
///         try res.json(.{ .id = id, .page = page, .agent = agent });
///     }
pub const Request = struct {
    /// The method; HEAD reaches GET routes, an extended CONNECT is routed
    /// as GET (see `protocol`).
    method: http.Method = undefined,
    /// The request target as sent: path and query string
    /// ("/users/42?page=2"), not decoded.
    url: []const u8 = "",
    /// 1 for HTTP/1.x, 2 for HTTP/2, 3 for HTTP/3.
    version_major: u8 = 0,
    version_minor: u8 = 0,
    /// The request headers, looked up case-insensitively:
    /// `req.headers.get("Authorization")`.
    headers: http.Headers = .{},
    /// The body's media type from `Content-Type`, when it is one the
    /// server knows by name; read the header for the rest.
    content_type: ?http.ContentType = null,
    /// The coding the body arrived in. Undone by the body reader unless
    /// `config.decompress` is off, in which case reading the body yields
    /// what the wire carried.
    ///
    /// Once it is being undone the `Content-Encoding` header is removed,
    /// because it would describe the body a handler is about to read as
    /// something it is not. This still says what arrived.
    content_encoding: http.ContentEncoding = .identity,
    /// How long the body was on the wire, when the headers said. Removed
    /// from the headers alongside the coding for the same reason, and kept
    /// here for the same one.
    content_length: ?usize = null,
    /// The route the request matched, null when none did.
    route: ?*const RouteInfo = null,
    /// The route's path parameters, raw (percent-encoded, as in the path):
    /// for "/users/:id", `req.params.get("id")` or
    /// `req.params.getInt(u64, "id")`; a `*wildcard` segment's rest of the
    /// path under its name. `paramDecoded` gives the decoded text.
    params: http.Params = .{},
    /// The query string's values, percent-decoded:
    /// `req.query.get("q")`, `req.query.getInt(u32, "page")`. A name
    /// without `=` has the value ""; of a repeated name, the last wins.
    query: http.Params = .{},
    /// The client address. This is the socket peer unless
    /// `ServerConfig.trusted_proxy_hops` resolves it through
    /// `X-Forwarded-For`. A Unix socket peer has no address of its own and is
    /// reported as IPv4 loopback, which is what both zio and
    /// `std.Io.Threaded` substitute on accept. A forwarded address has port
    /// zero because the header does not carry the client's source port.
    remote_address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) },
    /// The listener the connection came in on: one of those in
    /// `ServerConfig.listeners`, so a handler can compare it against them or
    /// read its address. A placeholder in a request the server did not build.
    listener: *const Listener = &placeholder_listener,
    /// Whether the client's connection is TLS: this server's, or, behind a
    /// trusted proxy, the proxy's (PROXY protocol v2's SSL TLV, or
    /// `X-Forwarded-Proto` under `ServerConfig.trusted_proxy_hops`).
    secure: bool = false,
    /// The `:protocol` of an HTTP/2 extended CONNECT (RFC 8441), such as
    /// "websocket"; null otherwise. Such a request is routed as a GET.
    protocol: ?[]const u8 = null,
    /// `X-Forwarded-Host` from the nearest trusted proxy, under
    /// `ServerConfig.trusted_proxy_hops`. See `host`.
    forwarded_host: ?[]const u8 = null,
    /// The client's TLS certificate (the leaf, DER), as the engine found it
    /// on the connection. See `peerCertificate`.
    peer_certificate: ?[]const u8 = null,
    /// This request's ID, set by the RequestId middleware: for log lines,
    /// traces and error reports. Empty without it.
    id: []const u8 = "",
    /// The W3C trace context of this request (hex trace and span IDs), set
    /// by a tracing middleware; empty without one.
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    /// Set when the server starts to drain: a handler that runs for long
    /// (a WebSocket, an event stream) can wait on it, or check `isSet`, to
    /// wind down rather than be cut off at `timeout.shutdown`. Null in a
    /// request the server did not build.
    drain: ?*std.Io.Event = null,
    /// The server's drain callbacks (`DrainHooks`): what a long-lived
    /// request registers with instead of keeping a task waiting on `drain`.
    /// Null in a request the server did not build.
    _drain_hooks: ?*DrainHooks = null,

    /// Freed in one go once the response has gone out: for anything the
    /// handler builds for this request.
    arena: std.mem.Allocator,
    /// The server's runtime, for I/O from a handler (files, sockets,
    /// sleeping, locks): calls through it wait without blocking the
    /// thread.
    io: std.Io = undefined,

    // Installed by the server for real requests. Kept as a callback so this
    // module does not depend on the server's backend-specific timer type.
    _timeout_context: ?*anyopaque = null,
    _set_timeout: ?*const fn (*anyopaque, std.Io, std.Io.Timeout) void = null,
    /// The last deadline the handler set with `setTimeout`, on the awake
    /// clock; null for none (or `.none`). The rest of an unread body is
    /// drained no later than this.
    _handler_deadline: ?std.Io.Clock.Timestamp = null,
    /// A handler called `setTimeout` or `setDeadline`: a stream or file body
    /// then leaves its deadline alone (`Response.liftDeadline`).
    _deadline_from_handler: bool = false,

    // Body reading support
    _parser: *RequestParser,
    _transport: Transport,
    /// Set by a protocol engine that delivers the body itself, unframed (an
    /// HTTP/2 stream), in place of `parser` and `transport`, which are then
    /// unused.
    _body_source: ?BodySource = null,
    _config: ServerConfig.Request = .{},
    _body: ?[]const u8 = null,
    _body_read: bool = false,
    // Set up on the first body read that calls for decoding, and kept so a
    // second `reader()` does not build a second decoder over the same body.
    _decode: ?*RequestBodyReader.Decode = null,
    _body_reader_taken: bool = false,
    _fd: std.StringHashMapUnmanaged([]const u8) = .{},
    _fd_read: bool = false,
    _mfd: std.StringHashMapUnmanaged(MultipartForm.Entry) = .{},
    _mfd_read: bool = false,
    /// The signed-cookie session `middleware.Session` loads and saves;
    /// empty without it. (`anole.session` has its own stores.)
    session: SessionData = .{},
    /// Values a middleware hands to the handler for this request: see
    /// `setLocal` and `local`.
    locals: Locals = .{},

    /// The violations `bind*` and `addViolation` recorded (see `violations`).
    _violations: std.ArrayList(http.Violation) = .empty,
    _violations_truncated: bool = false,

    // 100-continue support
    _response: ?*Response = null,
    _expects_continue: bool = false,

    /// The host the client asked for: `X-Forwarded-Host` from a trusted
    /// proxy, else `Host` (which HTTP/2's `:authority` fills).
    pub fn host(self: *const Request) ?[]const u8 {
        return self.forwarded_host orelse self.headers.get("Host");
    }

    /// The certificate the client presented on this server's TLS (mutual
    /// TLS, `ServerConfig.Tls.client_auth`): the leaf, DER-encoded, already
    /// verified against the listener's CAs. Null without TLS, without
    /// `client_auth`, when the client sent none (`.request` mode), or with
    /// a TLS module that does not expose it (`Connection.peerCertificate`).
    /// Borrowed from the connection: valid for this request.
    pub fn peerCertificate(self: *const Request) ?[]const u8 {
        return self.peer_certificate;
    }

    /// Clears the request for reuse on the same connection. Called by
    /// the server between requests; not for handlers.
    pub fn _reset(self: *Request) void {
        const arena = self.arena;
        const io = self.io;
        const parser = self._parser;
        const transport = self._transport;
        const cfg = self._config;
        const res = self._response;
        const timeout_context = self._timeout_context;
        const set_timeout = self._set_timeout;
        // Belongs to the connection, not the request, so it outlives the
        // reset the way the reader and the parser do.
        const addr = self.remote_address;
        const listener = self.listener;
        const secure = self.secure;
        const drain = self.drain;
        const drain_hooks = self._drain_hooks;
        const peer_certificate = self.peer_certificate;
        self.* = .{
            .arena = arena,
            .io = io,
            ._parser = parser,
            ._transport = transport,
            ._config = cfg,
            ._response = res,
            .remote_address = addr,
            .listener = listener,
            .secure = secure,
            .drain = drain,
            ._drain_hooks = drain_hooks,
            .peer_certificate = peer_certificate,
            ._timeout_context = timeout_context,
            ._set_timeout = set_timeout,
        };
    }

    /// Fills `content_type`, `content_encoding` and `content_length` from
    /// the headers. The HTTP/1.x parser calls it when the head is complete;
    /// another protocol engine calls it once it has the headers.
    pub fn _applyEntityHeaders(self: *Request) void {
        if (self.headers.get("Content-Type")) |content_type| {
            self.content_type = http.ContentType.fromContentType(content_type);
        }
        if (self.headers.get("Content-Encoding")) |content_encoding| {
            self.content_encoding = http.ContentEncoding.fromString(content_encoding);
        }
        if (self.headers.get("Content-Length")) |content_length| {
            self.content_length = std.fmt.parseInt(usize, content_length, 10) catch null;
        }
    }

    /// Replaces this request's deadline with one `timeout` from now; null
    /// for none. The server installs its normal keepalive deadline after the
    /// handler returns. A response that streams (`res.stream`,
    /// `res.startEventStream`) or sends a file lifts the request deadline
    /// itself, once its head is out (`timeouts.write` then bounds each
    /// write); a deadline set here before that is kept.
    ///
    /// Call from the connection's handler task, not concurrently from a task
    /// spawned by the handler.
    pub fn setTimeout(self: *Request, timeout: ?std.Io.Duration) void {
        self.setDeadline(if (timeout) |d| .{ .duration = .{ .raw = d, .clock = .awake } } else .none);
    }

    /// As `setTimeout`, with a `std.Io.Timeout`: a duration starts now, a
    /// deadline is absolute, and `.none` disables the deadline.
    pub fn setDeadline(self: *Request, deadline: std.Io.Timeout) void {
        self._deadline_from_handler = true;
        self._applyDeadline(deadline);
    }

    /// The deadline in place, without marking it the handler's.
    pub fn _applyDeadline(self: *Request, timeout: std.Io.Timeout) void {
        const set = self._set_timeout orelse return;
        self._handler_deadline = if (timeout.toDurationFromNow(self.io)) |d|
            std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = d.raw, .clock = .awake })
        else
            null;
        set(self._timeout_context.?, self.io, timeout);
    }

    /// The request body: transfer framing undone, and the content coding
    /// too unless `config.decompress` is off. Read through `.interface`,
    /// and `.err` says what an `error.ReadFailed` from it actually was.
    ///
    /// `buffer` is where bytes wait between the connection and the caller,
    /// the way `Response.stream` takes one for the other direction. It is
    /// what `peek` and the `take` family read out of, so size it for the
    /// longest thing they need to see at once; an empty slice is fine for a
    /// caller that only ever streams.
    ///
    /// One per body. `body` takes it if you have not, so a handler that
    /// streams cannot then ask for the body whole.
    pub fn reader(self: *Request, buffer: []u8) !RequestBodyReader {
        return self.readerLimited(buffer, self._config.max_body_size);
    }

    /// `reader` with a limit of your own: the most bytes the body may bring
    /// (decoded), `null` for any amount (an upload to a file, say). Past the
    /// limit reading fails with `error.BodyTooBig` (a 413). `reader` stops
    /// at `limits.body_max`, chunked bodies too.
    pub fn readerLimited(self: *Request, buffer: []u8, limit: ?usize) !RequestBodyReader {
        var r = RequestBodyReader.init(self._parser, self._transport, buffer);
        r.body_limit = limit;
        r.raw = self._body_source;

        // Once the body is in memory there is nothing left on the wire, and
        // what is cached has already been decoded.
        if (self._body_read) {
            r.interface = .fixed(self._body orelse &.{});
            return r;
        }

        // The buffer belongs to the caller, so a second reader starts empty
        // and whatever the first one had buffered is unreachable -- bytes off
        // the body, with nothing to say they went missing.
        if (self._body_reader_taken) return error.BodyReaderTaken;

        r.request = self;
        if (self._decode) |decode| {
            r.decode = decode;
        } else if (self._config.decompress) {
            try r.startDecoding(self.arena, self.content_encoding);
            if (r.decode != null) self.dropEncodedBodyHeaders();
            self._decode = r.decode;
        }

        // Claimed only once there is a reader to claim it for. A coding we
        // cannot undo fails above, and nothing was read; a caller that
        // handles that error has to be able to ask again.
        self._body_reader_taken = true;
        return r;
    }

    /// Both of these describe the body as it arrived, and it is not going
    /// to arrive that way any more: what the handler reads is decoded, and
    /// a longer or shorter number of bytes. Leaving them is how a proxy
    /// comes to forward plain bytes labelled `gzip`. `content_encoding` and
    /// `content_length` keep the answer for a handler that wants it.
    fn dropEncodedBodyHeaders(self: *Request) void {
        _ = self.headers.remove("Content-Encoding");
        _ = self.headers.remove("Content-Length");
    }

    /// The whole body, in the request's arena, or null when there is none.
    /// The result is kept, so later calls return it again. Fails with
    /// `error.BodyTooBig` (a 413) past `config.max_body_size`.
    pub fn body(self: *Request) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        // Nothing to stage: `allocRemaining` streams straight into the arena.
        var no_buf: [0]u8 = .{};
        var r = try self.reader(&no_buf);
        const result = r.interface.allocRemaining(self.arena, .limited(self._config.max_body_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooBig,
            // The interface can only say that a read failed; the reader
            // holds what it was.
            error.ReadFailed => return r.err orelse error.Unexpected,
            else => |e| return e,
        };

        self._body_read = true;
        if (result.len == 0) {
            self._body = null;
            return null;
        }
        self._body = result;
        return result;
    }

    /// A path parameter by name, null when the route has none of that name:
    /// `req.param("id")` for "/users/:id". The same as `req.params.get`;
    /// `req.params.getInt(u64, "id")` parses one.
    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// The route parameter `name`, percent-decoded into the request's arena
    /// (the slice in `params` itself when it has no '%'). `params` holds the
    /// raw, percent-encoded text: matching runs on the raw path, so an
    /// encoded '/' (%2F) never splits a segment, and decodes to '/' here.
    /// '+' stays '+'. `error.BadRequest` (400) for a '%' not followed by
    /// two hex digits.
    pub fn paramDecoded(self: *Request, name: []const u8) error{ BadRequest, OutOfMemory }!?[]const u8 {
        const raw = self.params.get(name) orelse return null;
        return try http.percentDecode(self.arena, raw, false);
    }

    /// A query-string value by name, percent-decoded, null when absent:
    /// `req.queryParam("page")` for "?page=2". The same as `req.query.get`;
    /// `req.query.getInt(u32, "page")` parses one.
    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }

    /// The JSON body as a `T` in the request's arena, mapped field by field
    /// and checked by `T`'s `field_rules` (`anole.validate`):
    /// `const in = try req.bind(NewUser);`. A request without a body fails
    /// with `error.MissingBody` and one that is not JSON with
    /// `error.InvalidJsonBody` (both 400); lists past 4 x `max_body_size`
    /// with `error.BodyTooBig` (413). A value that does not fit `T` (a wrong
    /// type, a missing required field, an unknown field in a type that says
    /// `pub const unknown_fields = .reject;`) or breaks a rule fails with
    /// `error.ValidationFailed` (422), every problem in `violations()`.
    /// Unknown fields are ignored otherwise. The `Content-Type` is not
    /// checked.
    pub fn bind(self: *Request, comptime T: type) !T {
        return try self.json(T) orelse error.MissingBody;
    }

    /// `bind` with `std.json`'s parse options as given, and no mapping or
    /// rules (the opt-out): any mismatch is `error.InvalidJsonBody` (400).
    /// Their default refuses fields `T` lacks, which `bind` ignores.
    pub fn bindWith(self: *Request, comptime T: type, options: std.json.ParseOptions) !T {
        return try self.jsonWith(T, options) orelse error.MissingBody;
    }

    /// `bind`, with null for a request without a body.
    pub fn json(self: *Request, comptime T: type) !?T {
        const b = try self.body() orelse return null;
        const result = bind_mod.bindJson(T, self.arena, b, .{ .max_list_bytes = self._config.max_body_size *| 4 }) catch |err| {
            scope_log.debug("request body is not the JSON expected: {t}", .{err});
            return err;
        };
        switch (result) {
            .ok => |value| return value,
            .invalid => |found| {
                self.recordViolations(found);
                return error.ValidationFailed;
            },
        }
    }

    fn jsonWith(self: *Request, comptime T: type, options: std.json.ParseOptions) !?T {
        const b = try self.body() orelse return null;
        return std.json.parseFromSliceLeaky(T, self.arena, b, options) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                scope_log.debug("request body is not the JSON expected: {t}", .{err});
                return error.InvalidJsonBody;
            },
        };
    }

    /// The query string as a `T`: names by outside names, `?tag=a&tag=b`
    /// into `[]const T`, defaults for absent fields, unknown names ignored.
    /// A problem is a violation (`in = query`) and `error.ValidationFailed`
    /// (422); a broken percent-escape or invalid UTF-8 is `error.BadRequest`
    /// (400). The rules of `T` run after the mapping.
    pub fn bindQuery(self: *Request, comptime T: type) !T {
        comptime bind_strings.check(T, .query);
        const raw = if (std.mem.indexOfScalar(u8, self.url, '?')) |q| self.url[q + 1 ..] else "";
        var pairs: std.ArrayList(bind_strings.Pair) = .empty;
        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |piece| {
            if (piece.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, piece, '=');
            const name = try http.percentDecode(self.arena, piece[0 .. eq orelse piece.len], true);
            const value = try http.percentDecode(self.arena, if (eq) |e| piece[e + 1 ..] else "", true);
            if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value)) return error.BadRequest;
            try pairs.append(self.arena, .{ .name = name, .value = value });
        }
        return self.mapStrings(T, .query, pairs.items, .query);
    }

    /// The route's parameters as a `T` (`%2F` decoded, `+` kept). Any
    /// problem, an absent or ill-fitting value or a broken rule, is
    /// `error.NotFound` (404) and records no violation: a value that does
    /// not fit the route names no resource.
    pub fn bindPath(self: *Request, comptime T: type) !T {
        comptime bind_strings.check(T, .path);
        var pairs: std.ArrayList(bind_strings.Pair) = .empty;
        var it = self.params.iterator();
        while (it.next()) |entry| {
            const value = http.percentDecode(self.arena, entry.value, false) catch return error.NotFound;
            if (!std.unicode.utf8ValidateSlice(value)) return error.NotFound;
            try pairs.append(self.arena, .{ .name = entry.key, .value = value });
        }
        return self.mapStrings(T, .path, pairs.items, .body) catch |err| switch (err) {
            error.ValidationFailed => {
                self._violations.clearRetainingCapacity();
                self._violations_truncated = false;
                return error.NotFound;
            },
            error.BadRequest => return error.NotFound,
            else => |e| return e,
        };
    }

    /// The request headers as a `T`: a field `x_request_id` reads
    /// `X-Request-Id` (any case; `v.rename` names the header otherwise),
    /// `?T` for optional ones, defaults when absent. Problems are
    /// violations with `in = header` and `field` the header's name, and
    /// `error.ValidationFailed` (422).
    pub fn bindHeaders(self: *Request, comptime T: type) !T {
        comptime bind_strings.check(T, .headers);
        var pairs: std.ArrayList(bind_strings.Pair) = .empty;
        for (self.headers.keys[0..self.headers.len], self.headers.values[0..self.headers.len]) |k, val| {
            try pairs.append(self.arena, .{ .name = k, .value = val });
        }
        return self.mapStrings(T, .headers, pairs.items, .header);
    }

    fn mapStrings(self: *Request, comptime T: type, comptime source: bind_strings.Source, pairs: []const bind_strings.Pair, in: http.Violation.Source) !T {
        var sink: bind_violations.Collector = .init(self.arena);
        const mapped = bind_strings.map(T, source, self.arena, pairs, bind_strings.unknownPolicy(T, .ignore), &sink) catch |err| switch (err) {
            error.InvalidRequest => return error.BadRequest,
            error.OutOfMemory => return error.OutOfMemory,
        };
        var value = mapped orelse {
            self.recordViolations(try bind_mod.toViolations(self.arena, &sink, in));
            return error.ValidationFailed;
        };
        const bad = bind_mod.applyRules(T, self.arena, &value, in) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TransformFailed => return error.BadRequest,
        };
        if (bad) |found| {
            self.recordViolations(found);
            return error.ValidationFailed;
        }
        return value;
    }

    fn recordViolations(self: *Request, found: http.Violations) void {
        for (found.items) |item| self.pushViolation(item);
        if (found.truncated) self._violations_truncated = true;
    }

    fn pushViolation(self: *Request, item: http.Violation) void {
        if (self._violations.items.len >= validate.max_report_violations) {
            self._violations_truncated = true;
            return;
        }
        self._violations.append(self.arena, item) catch {
            self._violations_truncated = true;
        };
    }

    /// The violations of this request's failed binds and `invalid` /
    /// `addViolation` calls, in the order they were found.
    pub fn violations(self: *const Request) http.Violations {
        return .{ .items = self._violations.items, .truncated = self._violations_truncated };
    }

    /// Adds a violation (`in = body`) without failing; at most 100 are kept.
    /// `field` must live as long as the request (a literal or the arena);
    /// `code` follows `v.custom`'s grammar (`users.email_taken`).
    pub fn addViolation(self: *Request, field: ?[]const u8, comptime code: []const u8, comptime message: []const u8) void {
        comptime validate.checkCode("req.addViolation", code);
        comptime if (validate.messageProblem(message)) |p| @compileError("anole: req.addViolation: " ++ validate.describeMessageProblem(p));
        self.pushViolation(.{ .in = .body, .field = field, .code = code, .message = message });
    }

    /// `addViolation`, then `error.ValidationFailed`:
    /// `return req.invalid("email", "users.email_taken", "is already taken");`
    pub fn invalid(self: *Request, field: ?[]const u8, comptime code: []const u8, comptime message: []const u8) error{ValidationFailed} {
        self.addViolation(field, code, message);
        return error.ValidationFailed;
    }

    /// A logger whose records carry this request's id, trace id and span id.
    pub fn log(self: *const Request) anole_log.Logger {
        return .{ .context = .{ .request_id = self.id, .trace_id = self.trace_id, .span_id = self.span_id, .route = if (self.route) |r| r.path else "" } };
    }

    /// The JSON body as a generic value; null without a body, and
    /// `error.InvalidJsonBody` (a 400) when it is not JSON.
    pub fn jsonValue(self: *Request) !?std.json.Value {
        const b = try self.body() orelse return null;
        return std.json.parseFromSliceLeaky(std.json.Value, self.arena, b, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJsonBody,
        };
    }

    /// The JSON body as an object; null without a body or when it is some
    /// other JSON value.
    pub fn jsonObject(self: *Request) !?std.json.ObjectMap {
        const value = try self.jsonValue() orelse return null;
        switch (value) {
            .object => |o| return o,
            else => return null,
        }
    }

    /// Stores `value` under `key` for the rest of this request, for a
    /// handler or a later middleware to read with `local`: the way a
    /// middleware hands what it found (a user, a tenant, verified claims)
    /// to the handler. A copy of `value` lives in the request's arena;
    /// `key` is not copied and must outlive the request (a literal). A
    /// second value under the same key replaces the first.
    pub fn setLocal(self: *Request, key: []const u8, value: anytype) !void {
        return self.locals.put(self.arena, key, value);
    }

    /// The value stored under `key` with `setLocal`, if it was stored as a
    /// `T`; null when there is none, or it is of another type.
    pub fn local(self: *const Request, comptime T: type, key: []const u8) ?T {
        return self.locals.get(T, key);
    }

    /// The `Cookie` header's cookies: `req.cookies().get("theme")`.
    pub fn cookies(self: *const Request) Cookie {
        return .{
            .header = self.headers.get("Cookie") orelse "",
        };
    }

    /// The body as an `application/x-www-form-urlencoded` form, names and
    /// values decoded, in the request's arena: `(try
    /// req.formData()).get("email")`. Parsed once; later calls return the
    /// same map.
    pub fn formData(self: *Request) !*std.StringHashMapUnmanaged([]const u8) {
        if (self._fd_read) {
            return &self._fd;
        }

        if (self.content_type == null or self.content_type != .form) {
            return error.NotForm;
        }

        const buffer = try self.body() orelse {
            self._fd_read = true;

            return &self._fd;
        };

        var entry_iterator = std.mem.splitScalar(u8, buffer, '&');

        while (entry_iterator.next()) |entry| {
            if (self._fd.count() >= self._config.max_form_count) {
                return error.TooManyFormFields;
            }

            if (std.mem.indexOfScalar(u8, entry, '=')) |separator| {
                const key = try Request.urlUnescape(self.arena, entry[0..separator]);
                const value = try Request.urlUnescape(self.arena, entry[separator + 1 ..]);

                try self._fd.put(self.arena, key, value);
            } else {
                try self._fd.put(self.arena, try Request.urlUnescape(self.arena, entry), "");
            }
        }

        self._fd_read = true;

        return &self._fd;
    }

    /// The body as a `multipart/form-data` form (file uploads), by field
    /// name, in the request's arena. Parsed once; later calls return the
    /// same map.
    pub fn multiFormData(self: *Request) !*std.StringHashMapUnmanaged(MultipartForm.Entry) {
        if (self._mfd_read) {
            return &self._mfd;
        }

        if (self.content_type == null or self.content_type != .multipart_form) {
            return error.NotMultipartForm;
        }

        const buffer = try self.body() orelse {
            self._mfd_read = true;

            return &self._mfd;
        };

        // The following chunk of code is from https://github.com/karlseguin/http.zig, see LICENSE for more details.

        var boundary_buf: [72]u8 = undefined;
        const boundary = blk: {
            const directive = (self.headers.get("Content-Type") orelse unreachable)["multipart/form-data".len..];
            for (directive, 0..) |b, i| loop: {
                if (b != ' ' and b != ';') {
                    if (std.ascii.startsWithIgnoreCase(directive[i..], "boundary=")) {
                        const raw_boundary = directive["boundary=".len + i ..];
                        if (raw_boundary.len > 0 and raw_boundary.len <= 70) {
                            boundary_buf[0] = '-';
                            boundary_buf[1] = '-';
                            if (raw_boundary[0] == '"') {
                                if (raw_boundary.len > 2 and raw_boundary[raw_boundary.len - 1] == '"') {
                                    // it's really -2, since we need to strip out the two quotes
                                    // but buf is already at + 2, so they cancel out.
                                    const end = raw_boundary.len;
                                    @memcpy(boundary_buf[2..end], raw_boundary[1 .. raw_boundary.len - 1]);
                                    break :blk boundary_buf[0..end];
                                }
                            } else {
                                const end = 2 + raw_boundary.len;
                                @memcpy(boundary_buf[2..end], raw_boundary);
                                break :blk boundary_buf[0..end];
                            }
                        }
                    }
                    // not valid, break out of the loop so we can return
                    // an error.InvalidMultiPartFormDataHeader
                    break :loop;
                }
            }
            return error.InvalidMultiPartFormDataHeader;
        };

        var entry_it = std.mem.splitSequence(u8, buffer, boundary);

        {
            // We expect the body to begin with a boundary
            const first = entry_it.next() orelse {
                self._mfd_read = true;
                return &self._mfd;
            };
            if (first.len != 0) {
                return error.InvalidMultiPartEncoding;
            }
        }

        while (entry_it.next()) |entry| {
            // body ends with -- after a final boundary
            if (entry.len == 4 and entry[0] == '-' and entry[1] == '-' and entry[2] == '\r' and entry[3] == '\n') {
                break;
            }

            if (self._mfd.count() >= self._config.max_multiform_count) {
                return error.TooManyMultiFormFields;
            }

            if (entry.len < 2 or entry[0] != '\r' or entry[1] != '\n') return error.InvalidMultiPartEncoding;

            // [2..] to skip our boundary's trailing line terminator
            const field = try MultipartForm.parseMultiPartEntry(entry[2..]);
            try self._mfd.put(self.arena, field.name, field.value);
        }

        // End of chunk.

        self._mfd_read = true;

        return &self._mfd;
    }

    /// Decodes a URL-encoded string: %XX sequences to bytes and '+' to a
    /// space. Returns `input` itself when there is nothing to decode, else
    /// a copy allocated with `allocator`.
    pub fn urlUnescape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        return http.percentDecode(allocator, input, true) catch |err| switch (err) {
            error.BadRequest => error.InvalidEscapeSequence,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
};

const MultipartForm = struct {
    const Entry = struct { value: []const u8, filename: ?[]const u8 = null };

    // The following chunk of code is from https://github.com/karlseguin/http.zig, see LICENSE for more details.

    const Field = struct {
        name: []const u8,
        value: Entry,
    };

    fn parseMultiPartEntry(entry: []const u8) !Field {
        var pos: usize = 0;
        var attributes: ?ContentDispositionAttributes = null;

        while (true) {
            const end_line_pos = std.mem.indexOfScalarPos(u8, entry, pos, '\n') orelse return error.InvalidMultiPartEncoding;
            const line = entry[pos..end_line_pos];

            pos = end_line_pos + 1;
            if (line.len == 0 or line[line.len - 1] != '\r') return error.InvalidMultiPartEncoding;

            if (line.len == 1) {
                break;
            }

            // we need to look for the name
            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:") == false) {
                continue;
            }

            const value = trimLeadingSpace(line["content-disposition:".len..]);
            if (std.ascii.startsWithIgnoreCase(value, "form-data;") == false) {
                return error.InvalidMultiPartEncoding;
            }

            // constCast is safe here because we know this ultimately comes from one of our buffers
            const value_start = "form-data;".len;
            const value_end = value.len - 1; // remove the trailing \r
            attributes = try getContentDispositionAttributes(@constCast(trimLeadingSpace(value[value_start..value_end])));
        }

        const value = entry[pos..];
        if (value.len < 2 or value[value.len - 2] != '\r' or value[value.len - 1] != '\n') {
            return error.InvalidMultiPartEncoding;
        }

        const attr = attributes orelse return error.InvalidMultiPartEncoding;

        return .{
            .name = attr.name,
            .value = .{
                .value = value[0 .. value.len - 2],
                .filename = attr.filename,
            },
        };
    }

    const ContentDispositionAttributes = struct {
        name: []const u8,
        filename: ?[]const u8 = null,
    };

    fn getContentDispositionAttributes(fields: []u8) !ContentDispositionAttributes {
        var pos: usize = 0;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;

        while (pos < fields.len) {
            {
                const b = fields[pos];
                if (b == ';' or b == ' ' or b == '\t') {
                    pos += 1;
                    continue;
                }
            }

            const sep = std.mem.indexOfScalarPos(u8, fields, pos, '=') orelse return error.InvalidMultiPartEncoding;
            const field_name = fields[pos..sep];

            // skip the equal
            const value_start = sep + 1;
            if (value_start == fields.len) {
                return error.InvalidMultiPartEncoding;
            }

            var value: []const u8 = undefined;
            if (fields[value_start] != '"') {
                // Search from value_start, not pos: a stray ';' inside the
                // field name (malformed input the parser doesn't reject)
                // would otherwise place value_end before value_start.
                const value_end = std.mem.indexOfScalarPos(u8, fields, value_start, ';') orelse fields.len;
                pos = value_end;
                value = fields[value_start..value_end];
            } else blk: {
                // skip the double quote
                pos = value_start + 1;
                var write_pos = pos;
                while (pos < fields.len) {
                    switch (fields[pos]) {
                        '\\' => {
                            // Trailing backslash with no character to escape.
                            if (pos + 1 >= fields.len) {
                                return error.InvalidMultiPartEncoding;
                            }
                            // supposedly MSIE doesn't always escape \, so if the \ isn't escape
                            // one of the special characters, it must be a single \. This is what Go does.
                            switch (fields[pos + 1]) {
                                // from Go's mime parser func isTSpecial(r rune) bool
                                '(', ')', '<', '>', '@', ',', ';', ':', '"', '/', '[', ']', '?', '=' => |n| {
                                    fields[write_pos] = n;
                                    pos += 1;
                                },
                                else => fields[write_pos] = '\\',
                            }
                        },
                        '"' => {
                            pos += 1;
                            value = fields[value_start + 1 .. write_pos];
                            break :blk;
                        },
                        else => |b| fields[write_pos] = b,
                    }
                    pos += 1;
                    write_pos += 1;
                }
                return error.InvalidMultiPartEncoding;
            }

            if (std.mem.eql(u8, field_name, "name")) {
                name = value;
            } else if (std.mem.eql(u8, field_name, "filename")) {
                filename = value;
            }
        }

        return .{
            .name = name orelse return error.InvalidMultiPartEncoding,
            .filename = filename,
        };
    }

    inline fn trimLeadingSpaceCount(in: []const u8) struct { []const u8, usize } {
        if (in.len > 1 and in[0] == ' ') {
            // very common case
            const n = in[1];
            if (n != ' ' and n != '\t') {
                return .{ in[1..], 1 };
            }
        }

        for (in, 0..) |b, i| {
            if (b != ' ' and b != '\t') return .{ in[i..], i };
        }
        return .{ "", in.len };
    }

    inline fn trimLeadingSpace(in: []const u8) []const u8 {
        const out, _ = trimLeadingSpaceCount(in);
        return out;
    }

    // End of chunk.
};

/// How many headers `parseHeaders` makes room for before it has to grow the
/// table.
const initial_header_room = 16;

const ParseHeadersError = std.Io.Reader.Error || ParseError ||
    error{ IncompleteRequest, HeadersTooLarge, OutOfMemory };

/// Parse HTTP headers from a reader and prepare for body reading.
///
/// The head is bounded by `reader.buffer`, less `body_read_reserve`: it is
/// never tossed while it is being parsed, because the header slices point
/// into it, so whatever it does not use is all the body reader will have.
/// A head is accepted exactly when it fits in that much.
///
/// Returns error.EndOfStream if connection closed cleanly with no data.
/// Returns error.IncompleteRequest if connection closed mid-request.
/// Returns error.HeadersTooLarge if the head does not fit.
pub fn parseHeaders(reader: *std.Io.Reader, parser: *RequestParser) ParseHeadersError!void {
    // The arena is reset between requests, and may be another pooled set's
    // by the next one, so the headers are allocated for each: room for
    // most heads, grown to `max_header_count` for one with more, so that an
    // ordinary request takes little of its arena.
    parser.request.headers = try http.Headers.init(parser.request.arena, @min(parser.request._config.max_header_count, initial_header_room));
    var parsed_len: usize = 0;
    while (!parser.state.headers_complete) {
        const buffered = reader.buffered();
        const unparsed = buffered[parsed_len..];
        if (unparsed.len > 0) {
            parser.feed(unparsed) catch |err| switch (err) {
                error.Paused => {
                    const consumed = parser.getConsumedBytes(unparsed.ptr);
                    parsed_len += consumed;
                    continue;
                },
                else => |e| return e,
            };
            parsed_len += unparsed.len;
            continue;
        }
        // Every buffered byte has been consumed as head and it is still
        // open, so filling again is the only way forward -- and doing so
        // would eat into the reserve. `fillMore` on a buffer with no room
        // asks its rebase to free a byte that nothing can free, and asserts.
        if (reader.buffer.len - reader.end < body_read_reserve) return error.HeadersTooLarge;
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (parsed_len == 0) return error.EndOfStream;
                return error.IncompleteRequest;
            },
            else => |e| return e,
        };
    }
    // A fill is free to use every byte it was given room for, so a head can
    // still finish inside the reserve even though the check above passed
    // each time it ran. What is left is all the body reader gets, and
    // `BodyReader.stream` can no more fill a zero-length buffer than the
    // loop above could -- so the head is over the limit either way.
    if (reader.buffer.len - parsed_len < body_read_reserve) return error.HeadersTooLarge;

    reader.toss(parsed_len);
    parser.resumeParsing();

    // Shorten buffer so body reading doesn't overwrite header data.
    // Headers remain valid in buffer[0..headers_len], body uses the rest.
    std.debug.assert(reader.seek == parsed_len);
    const headers_len = reader.seek;
    reader.buffer = reader.buffer[headers_len..];
    reader.end -= headers_len;
    reader.seek = 0;

    // Feed empty buffer to advance state machine for bodyless requests
    parser.feed(&.{}) catch |err| switch (err) {
        error.Paused => {},
        else => |e| return e,
    };
}

/// A reader over `raw` with `body_read_reserve` bytes of slack past it, the
/// way a connection's read buffer has slack past the head it just parsed.
/// `Reader.fixed` alone leaves none, and a head with nothing behind it is
/// rejected -- the body reader would have nowhere to read into.
fn fixedMessageReader(gpa: std.mem.Allocator, raw: []const u8) !std.Io.Reader {
    const backing = try gpa.alloc(u8, raw.len + body_read_reserve);
    @memcpy(backing[0..raw.len], raw);
    var r: std.Io.Reader = .fixed(backing);
    r.end = raw.len;
    return r;
}

test "Request.setTimeout: forwards relative, absolute, and disabled deadlines" {
    const Probe = struct {
        calls: usize = 0,
        last: std.Io.Timeout = .none,

        fn set(context: *anyopaque, _: std.Io, timeout: std.Io.Timeout) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.last = timeout;
        }
    };

    var probe: Probe = .{};
    var req: Request = .{
        .arena = std.testing.allocator,
        .io = std.testing.io,
        ._parser = undefined,
        ._transport = undefined,
        ._timeout_context = &probe,
        ._set_timeout = Probe.set,
    };

    req.setTimeout(.fromSeconds(7));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(7), probe.last.duration.raw);
    try std.testing.expect(req._deadline_from_handler);

    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .real).addDuration(.{
        .raw = .fromSeconds(11),
        .clock = .real,
    });
    req.setDeadline(.{ .deadline = deadline });
    try std.testing.expectEqual(deadline, probe.last.deadline);

    req.setTimeout(null);
    try std.testing.expect(probe.last == .none);
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "Request.peerCertificate: belongs to the connection, so it outlives reset" {
    var req: Request = .{
        .arena = std.testing.allocator,
        .io = std.testing.io,
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), req.peerCertificate());
    const der = "\x30\x82\x01\x00";
    req.peer_certificate = der;
    req.url = "/a";
    req._reset();
    try std.testing.expectEqualStrings(der, req.peerCertificate().?);
    try std.testing.expectEqualStrings("", req.url);
}

test "Request: no std.Io.Reader sentinel escapes the body-reading API" {
    // `ReadFailed` says only that a read failed, which the caller knew when
    // it called. None of these may report it.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        ErrorSetOf(Request.body),
        ErrorSetOf(Request.jsonValue),
        ErrorSetOf(Request.formData),
        ErrorSetOf(Request.multiFormData),
        // The wrapper a streaming caller resolves through, not just the
        // functions that resolve for them.
        RequestBodyReader.Error,
    }) |Set| {
        inline for (comptime std.meta.fieldNames(Set)) |e_name| {
            try std.testing.expect(!std.mem.eql(u8, e_name, "ReadFailed"));
            // Not a sentinel, but not a cause either: the body layer calls a
            // stream that stopped early `IncompleteBody`, and `EndOfStream`
            // here would be read as the peer having hung up.
            try std.testing.expect(!std.mem.eql(u8, e_name, "EndOfStream"));
        }
    }
}

test "Request.body: basic POST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "Request.body: built without zlib, a coded body is refused" {
    if (@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;
    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.UnsupportedContentEncoding, req.body());
}

test "Request.body: a gzip request body is decoded" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello", gzip compressed.
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectEqual(http.ContentEncoding.gzip, req.content_encoding);
    const body = try req.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "Request.body: a chunked gzip body is unwrapped by both layers" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "Hello from test!" gzipped, then cut across three chunks -- so the
    // decoder is fed from a stream whose framing it cannot see.
    const chunked_gzip = "6\r\n\x1f\x8b\x08\x00\x00\x00\r\n" ++
        "e\r\n\x00\x00\x02\x03\xf3\x48\xcd\xc9\xc9\x57\x48\x2b\xca\xcf\r\n" ++
        "10\r\n\x55\x28\x49\x2d\x2e\x51\x04\x00\x7c\xe6\xd9\x99\x10\x00\x00\x00\r\n" ++
        "0\r\n\r\n";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n" ++ chunked_gzip;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings("Hello from test!", body.?);
}

/// Serves `source` into the reader's buffer, as much as fits each time, the
/// way a socket read does when the peer is ahead. That is what puts a fill
/// boundary at the end of the buffer.
const SourceReader = struct {
    source: []const u8,
    pos: usize = 0,
    interface: std.Io.Reader,

    fn init(source: []const u8, buffer: []u8) SourceReader {
        return .{
            .source = source,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        const self: *SourceReader = @fieldParentPtr("interface", r);
        const rest = self.source[self.pos..];
        if (rest.len == 0) return error.EndOfStream;
        const dest = r.buffer[r.end..];
        const n = @min(dest.len, rest.len);
        @memcpy(dest[0..n], rest[0..n]);
        r.end += n;
        self.pos += n;
        return 0;
    }

    // The body reader only ever fills; nothing here streams.
    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = r;
        _ = w;
        _ = limit;
        return error.EndOfStream;
    }
};

test "Request.body: a chunked trailer split across a buffer wrap is dropped, not asserted on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The body region is what the head leaves of the buffer. The body is
    // sized so the region ends inside the trailer name: the first fill
    // stops there, the body reader drains it, and the next fill lands at
    // the start of the buffer with the rest of the name.
    const head = "POST /test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    const region = 2048;
    const data = &@as([2033]u8, @splat('a'));
    const body = "7f1\r\n" ++ data ++ "\r\n0\r\n" ++ "X-Trailer: value\r\n\r\n";
    comptime std.debug.assert(("7f1\r\n" ++ data ++ "\r\n0\r\n" ++ "X-Tra").len == region);

    var buffer: [head.len + region]u8 = undefined;
    var source = SourceReader.init(head ++ body, &buffer);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &source.interface, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&source.interface, &parser);

    try std.testing.expectEqualStrings(data, (try req.body()).?);
    try std.testing.expectEqual(null, req.headers.get("X-Trailer"));
}

test "Request: decoding takes the headers that described the encoded body" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // Both are true of the body until the moment it is decoded.
    try std.testing.expectEqualStrings("gzip", req.headers.get("Content-Encoding").?);
    try std.testing.expectEqualStrings("25", req.headers.get("Content-Length").?);

    const body = try req.body();
    try std.testing.expectEqualStrings("hello", body.?);

    // A handler forwarding these would send five plain bytes labelled as
    // twenty-five gzipped ones.
    try std.testing.expectEqual(@as(?[]const u8, null), req.headers.get("Content-Encoding"));
    try std.testing.expectEqual(@as(?[]const u8, null), req.headers.get("Content-Length"));

    // What arrived is still answerable, just not as a header.
    try std.testing.expectEqual(http.ContentEncoding.gzip, req.content_encoding);
    try std.testing.expectEqual(@as(?usize, 25), req.content_length);
}

test "Request: decoding off leaves the headers alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
        ._config = .{ .decompress = false },
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);
    _ = try req.body();

    // Nothing was undone, so both still describe what the handler has.
    try std.testing.expectEqualStrings("gzip", req.headers.get("Content-Encoding").?);
    try std.testing.expectEqualStrings("25", req.headers.get("Content-Length").?);
}

test "Request.body: decoding off yields what the wire carried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
        ._config = .{ .decompress = false },
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings(gzip_hello, body.?);
}

test "Request.body: a compressed body cut short is a bad body, not a departed peer" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A valid gzip stream, truncated. The peer is still there and the HTTP
    // message is whole; it is the compressed stream inside that stops early.
    const cut_gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xcb\x48\xcd\xc9\xc9";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 15\r\n\r\n" ++ cut_gzip;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // The decoder calls this `EndOfStream`, which is how a peer that hung up
    // is spelled -- `Transport.isPeerGone` would believe it and tear the
    // connection down rather than answering. The framing half already calls
    // the same condition `IncompleteBody`, and so must this one.
    try std.testing.expectError(error.IncompleteBody, req.body());
    try std.testing.expect(!Transport.isPeerGone(error.IncompleteBody));
}

test "Request.body: a coding we cannot undo is refused rather than guessed at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: br\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // Handing the handler brotli bytes it would read as the body is worse
    // than saying we cannot.
    try std.testing.expectError(error.UnsupportedContentEncoding, req.body());
}

test "Request.body: a body read that failed before it started can be asked for again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: br\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // Nothing was read, so nothing was taken. A handler that answers 415 by
    // way of an error handler that logs the body -- or one that just tries
    // again -- gets the same answer rather than tripping the one-reader
    // assert on a request a peer chose the encoding for.
    try std.testing.expectError(error.UnsupportedContentEncoding, req.body());
    try std.testing.expectError(error.UnsupportedContentEncoding, req.body());
    try std.testing.expectError(error.UnsupportedContentEncoding, req.jsonValue());
}

test "Request: a streaming read resolves through the reader it hands out" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++
        ("not a gzip stream at all" ++ "12345678");
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // A handler streaming the body never calls `body`, so the reader itself
    // has to answer -- including for a failure in the layer it added.
    var read_buf: [64]u8 = undefined;
    var r = try req.reader(&read_buf);
    var sink_buf: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buf);
    try std.testing.expectError(error.ReadFailed, r.interface.stream(&sink, .limited(64)));
    try std.testing.expectEqual(error.MalformedBody, r.err.?);
}

test "Request.body: a body cut short is IncompleteBody, not a failed read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The headers promise five bytes and the peer sends two, then stops.
    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // Nothing is wrong with the connection, so it has no cause to offer,
    // and nothing is wrong with the framing either: the peer stopped early.
    try std.testing.expectError(error.IncompleteBody, req.body());
}

test "Request.body: a chunked body cut short is IncompleteBody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A chunk of five bytes, two of them sent.
    const raw_request = "POST /test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.IncompleteBody, req.body());
}

test "Request.body: framing the parser rejects is reported as itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A chunk size that is not a number.
    const raw_request = "POST /test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.MalformedBody, req.body());
}

test "Request.body: large body over 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body_content = &@as([256]u8, @splat('A'));
    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 256\r\n\r\n" ++ body_content;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqual(256, body.?.len);
    try std.testing.expectEqualStrings(body_content, body.?);
}

test "Request.cookies: parse cookies from header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "GET /test HTTP/1.1\r\nCookie: session=abc123; user=john\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const cookies = req.cookies();
    try std.testing.expectEqualStrings("abc123", cookies.get("session").?);
    try std.testing.expectEqualStrings("john", cookies.get("user").?);
    try std.testing.expectEqual(null, cookies.get("missing"));
}

test "Request.formData: basic key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 15\r\n\r\nfoo=123&bar=abc";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("123", form_data.get("foo").?);
    try std.testing.expectEqualStrings("abc", form_data.get("bar").?);
}

test "Request.formData: URL-encoded key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 17\r\n\r\nfoo+bar=123%21abc";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("123!abc", form_data.get("foo bar").?);
}

test "Request.formData: entry with no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nfoo";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("", form_data.get("foo").?);
}

test "Request.multiFormData: basic key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--boundary123\r\nContent-Length: 155\r\n\r\n----boundary123\r\nContent-Disposition: form-data; name=\"foo\"\r\n\r\n123\r\n----boundary123\r\nContent-Disposition: form-data; name=\"bar\"\r\n\r\nabc\r\n----boundary123--\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.multiFormData();
    try std.testing.expectEqualStrings("123", form_data.get("foo").?.value);
    try std.testing.expectEqualStrings("abc", form_data.get("bar").?.value);
}

test "Request.multiFormData: entry with filename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--boundary123\r\nContent-Length: 133\r\n\r\n----boundary123\r\nContent-Disposition: form-data; name=\"foo\"; filename=\"foo.txt\"\r\nContent-Type: text/plain\r\n\r\n123\r\n----boundary123--\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.multiFormData();
    try std.testing.expectEqualStrings("foo.txt", form_data.get("foo").?.filename.?);
}

test "Request.multiFormData: semicolon in attribute name (regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Content-Disposition attribute name containing ';' — the parser
    // searched for the value-terminating ';' from the field-name start
    // instead of from the value start, so value_end could land before
    // value_start and slice [value_start..value_end] panicked.
    const body = "----b\r\nContent-Disposition: form-data; name;x=v\r\n\r\nval\r\n----b--\r\n";
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});

    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(std.testing.allocator);
    try req_buf.appendSlice(std.testing.allocator, "POST /t HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--b\r\nContent-Length: ");
    try req_buf.appendSlice(std.testing.allocator, cl);
    try req_buf.appendSlice(std.testing.allocator, "\r\n\r\n");
    try req_buf.appendSlice(std.testing.allocator, body);

    var reader = try fixedMessageReader(arena.allocator(), req_buf.items);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    // Should error out cleanly, not panic.
    _ = req.multiFormData() catch {};
}

test "Request.multiFormData: trailing backslash in quoted attribute (regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Quoted name value ends with a backslash and no closing quote — the parser
    // currently looks at fields[pos+1] without bounds-checking, panicking on
    // safety-checked builds. Should return InvalidMultiPartEncoding instead.
    const body = "----b\r\nContent-Disposition: form-data; name=\"x\\\r\n\r\nval\r\n----b--\r\n";
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});

    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(std.testing.allocator);
    try req_buf.appendSlice(std.testing.allocator, "POST /t HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--b\r\nContent-Length: ");
    try req_buf.appendSlice(std.testing.allocator, cl);
    try req_buf.appendSlice(std.testing.allocator, "\r\n\r\n");
    try req_buf.appendSlice(std.testing.allocator, body);

    var reader = try fixedMessageReader(arena.allocator(), req_buf.items);

    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = .{ .reader = &reader, .writer = undefined },
        ._parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.InvalidMultiPartEncoding, req.multiFormData());
}

fn noBodySourceError(_: *std.Io.Reader) ?Transport.ReadError {
    return null;
}

test "Request.body: a body source delivers the body without the HTTP/1 parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source: std.Io.Reader = .fixed("unframed body bytes");
    var req: Request = .{ .arena = arena.allocator(), ._transport = undefined, ._parser = undefined };
    req.headers = try http.Headers.init(arena.allocator(), 4);
    try req.headers.put("content-type", "application/json");
    try req.headers.put("content-length", "19");
    req._applyEntityHeaders();
    req._body_source = .{ .reader = &source, .err = noBodySourceError };

    try std.testing.expectEqual(http.ContentType.json, req.content_type.?);
    try std.testing.expectEqual(@as(?usize, 19), req.content_length);
    try std.testing.expectEqualStrings("unframed body bytes", (try req.body()).?);
}

test "Request.body: a gzip body from a body source is decoded" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    var source: std.Io.Reader = .fixed(gzip_hello);
    var req: Request = .{ .arena = arena.allocator(), ._transport = undefined, ._parser = undefined };
    req.headers = try http.Headers.init(arena.allocator(), 4);
    try req.headers.put("content-encoding", "gzip");
    req._applyEntityHeaders();
    req._body_source = .{ .reader = &source, .err = noBodySourceError };

    try std.testing.expectEqualStrings("hello", (try req.body()).?);
}

test "Request.body: 100 Continue goes through the response's sink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Probe = struct {
        interim: ?http.Status = null,
        w: std.Io.Writer = .failing,
        fn sink(self: *@This()) @import("sink.zig").Sink {
            return .{ .ptr = self, .vtable = &.{
                .head = head,
                .interim = interimFn,
                .body = bodyFn,
                .end = end,
                .writeError = writeError,
                .peerGone = peerGone,
            } };
        }
        fn head(_: *anyopaque, _: http.Status, _: *const http.Headers, _: ?usize) std.Io.Writer.Error!void {}
        fn interimFn(ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.interim = status;
        }
        fn bodyFn(ptr: *anyopaque) *std.Io.Writer {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return &self.w;
        }
        fn end(_: *anyopaque, _: ?*const http.Headers) std.Io.Writer.Error!void {}
        fn writeError(_: *anyopaque) ?Response.SendError {
            return null;
        }
        fn peerGone(_: *anyopaque) bool {
            return false;
        }
    };
    var probe: Probe = .{};
    var res = try Response._initSink(arena.allocator(), std.testing.io, probe.sink(), 8);

    var source: std.Io.Reader = .fixed("data");
    var req: Request = .{ .arena = arena.allocator(), ._transport = undefined, ._parser = undefined };
    req.headers = try http.Headers.init(arena.allocator(), 4);
    req._body_source = .{ .reader = &source, .err = noBodySourceError };
    req._expects_continue = true;
    req._response = &res;

    try std.testing.expectEqualStrings("data", (try req.body()).?);
    try std.testing.expectEqual(http.Status.@"continue", probe.interim.?);
    try std.testing.expect(!req._expects_continue);
}

test "misuse: a second reader is BodyReaderTaken in every build mode" {
    var req: Request = .{
        .arena = std.testing.allocator,
        .io = std.testing.io,
        ._parser = undefined,
        ._transport = undefined,
    };
    var buf: [16]u8 = undefined;
    _ = try req.reader(&buf);
    try std.testing.expectError(error.BodyReaderTaken, req.reader(&buf));
    // And `body` after `reader` is the same mistake.
    try std.testing.expectError(error.BodyReaderTaken, req.body());
}

test "Request.paramDecoded: %C3%BC, %2F, a lone %, no escapes returns the same slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: Request = .{
        .arena = arena.allocator(),
        ._transport = undefined,
        ._parser = undefined,
    };
    try req.params.map.put(arena.allocator(), "name", "J%C3%BCrgen");
    try req.params.map.put(arena.allocator(), "path", "a%2Fb+c");
    try req.params.map.put(arena.allocator(), "bad", "50%");
    try req.params.map.put(arena.allocator(), "bad2", "%zz");
    try req.params.map.put(arena.allocator(), "plain", "plain");
    try std.testing.expectEqualStrings("Jürgen", (try req.paramDecoded("name")).?);
    try std.testing.expectEqualStrings("a/b+c", (try req.paramDecoded("path")).?);
    try std.testing.expectError(error.BadRequest, req.paramDecoded("bad"));
    try std.testing.expectError(error.BadRequest, req.paramDecoded("bad2"));
    const raw = req.params.get("plain").?;
    try std.testing.expectEqual(raw.ptr, (try req.paramDecoded("plain")).?.ptr);
    try std.testing.expect((try req.paramDecoded("missing")) == null);
    // The raw text is what `params` keeps.
    try std.testing.expectEqualStrings("J%C3%BCrgen", req.params.get("name").?);
}

// ------------------------------------------------------------------ bind, bindQuery, bindPath

const BindBody = struct {
    reader: std.Io.Reader = undefined,

    fn noError(_: *std.Io.Reader) ?Transport.ReadError {
        return null;
    }

    fn request(self: *BindBody, arena: std.mem.Allocator, bytes: []const u8) Request {
        self.reader = .fixed(bytes);
        return .{
            .arena = arena,
            ._parser = undefined,
            ._transport = undefined,
            ._body_source = .{ .reader = &self.reader, .err = noError },
        };
    }
};

const rules = @import("validate");

const Todo = struct {
    title: []const u8,
    due: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .title = .{ rules.trim, rules.notBlank, rules.maxLength(10) },
        .tags = .{ rules.maxItems(2), rules.each(rules.notEmpty) },
    };
};

fn expectViolationAt(req: *const Request, index: usize, in: http.Violation.Source, field: ?[]const u8, code: []const u8) !void {
    const found = req.violations().items;
    try std.testing.expect(index < found.len);
    try std.testing.expectEqual(in, found[index].in);
    try std.testing.expectEqualStrings(code, found[index].code);
    if (field) |f| try std.testing.expectEqualStrings(f, found[index].field.?) else try std.testing.expect(found[index].field == null);
}

test "bind: a plain DTO with a wrong type is ValidationFailed with every violation (in = body)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Plain = struct { name: []const u8, age: u8, ok: bool };
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "{\"name\":1,\"age\":\"x\"}");
    try std.testing.expectError(error.ValidationFailed, req.bind(Plain));
    try std.testing.expectEqual(@as(usize, 3), req.violations().items.len);
    try expectViolationAt(&req, 0, .body, "name", "http.invalid_type");
    try expectViolationAt(&req, 1, .body, "age", "http.invalid_type");
    try expectViolationAt(&req, 2, .body, "ok", "http.missing_field");
}

test "bind: field_rules run after mapping; all violations, paths by outside names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "{\"title\":\"   \",\"tags\":[\"a\",\"\",\"c\"]}");
    try std.testing.expectError(error.ValidationFailed, req.bind(Todo));
    try expectViolationAt(&req, 0, .body, "title", "validation.not_blank");
    try expectViolationAt(&req, 1, .body, "tags", "validation.max_items");
}

test "bind: transforms run before rules (trim then notBlank)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "{\"title\":\"  hello  \"}");
    const todo = try req.bind(Todo);
    try std.testing.expectEqualStrings("hello", todo.title);
}

test "bind: unknown fields ignored by default, reported with unknown_fields = .reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Strict = struct {
        a: u8,
        pub const unknown_fields = .reject;
    };
    const Loose = struct { a: u8 };
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "{\"a\":1,\"extra\":true}");
    try std.testing.expectEqual(@as(u8, 1), (try req.bind(Loose)).a);
    var body2: BindBody = .{};
    var req2 = body2.request(arena.allocator(), "{\"a\":1,\"extra\":true}");
    try std.testing.expectError(error.ValidationFailed, req2.bind(Strict));
    try expectViolationAt(&req2, 0, .body, "extra", "http.unknown_field");
}

test "bind: not JSON is InvalidJsonBody; no body is MissingBody; json() is null without a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Plain = struct { a: u8 };
    var b1: BindBody = .{};
    var r1 = b1.request(arena.allocator(), "not json");
    try std.testing.expectError(error.InvalidJsonBody, r1.bind(Plain));
    var b2: BindBody = .{};
    var r2 = b2.request(arena.allocator(), "");
    try std.testing.expectError(error.MissingBody, r2.bind(Plain));
    var b3: BindBody = .{};
    var r3 = b3.request(arena.allocator(), "");
    try std.testing.expect((try r3.json(Plain)) == null);
    var b4: BindBody = .{};
    var r4 = b4.request(arena.allocator(), "{\"a\":1,\"a\":2}");
    try std.testing.expectError(error.InvalidJsonBody, r4.bind(Plain));
}

test "bind: lists past 4 x max_body_size are BodyTooBig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "[1,2,3,4]");
    req._config.max_body_size = 1;
    // Four u64 items take 32 bytes, past 4 x 1.
    try std.testing.expectError(error.BodyTooBig, req.bind([]const u64));
}

test "bind: a fallback type (with [2]i32) maps with std.json and still runs rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Fallback = struct {
        pair: [2]i32,
        name: []const u8,
        pub const field_rules = .{ .name = rules.notBlank };
    };
    var b1: BindBody = .{};
    var r1 = b1.request(arena.allocator(), "{\"pair\":[3,4],\"name\":\"x\"}");
    try std.testing.expectEqual(@as(i32, 4), (try r1.bind(Fallback)).pair[1]);
    var b2: BindBody = .{};
    var r2 = b2.request(arena.allocator(), "{\"pair\":[3,4],\"name\":\" \"}");
    try std.testing.expectError(error.ValidationFailed, r2.bind(Fallback));
    var b3: BindBody = .{};
    var r3 = b3.request(arena.allocator(), "{\"pair\":\"no\",\"name\":\"x\"}");
    try std.testing.expectError(error.InvalidJsonBody, r3.bind(Fallback));
}

test "bindWith: std.json options, no rules (an invalid DTO passes)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "{\"title\":\"   \",\"extra\":1}");
    const todo = try req.bindWith(Todo, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("   ", todo.title);
}

const Search = struct {
    q: []const u8 = "",
    page: u32 = 1,
    tag: []const []const u8 = &.{},
    pub const field_rules = .{ .page = rules.range(1, 100) };
};

test "bindQuery: ?tag=a&tag=b into []const []const u8, %20 and + decoded, defaults kept, 422 with in = query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    req.url = "/search?q=a%20b+c&tag=x&tag=y&unknown=1";
    const s = try req.bindQuery(Search);
    try std.testing.expectEqualStrings("a b c", s.q);
    try std.testing.expectEqual(@as(u32, 1), s.page);
    try std.testing.expectEqual(@as(usize, 2), s.tag.len);
    try std.testing.expectEqualStrings("y", s.tag[1]);

    var body2: BindBody = .{};
    var bad = body2.request(arena.allocator(), "");
    bad.url = "/search?page=x";
    try std.testing.expectError(error.ValidationFailed, bad.bindQuery(Search));
    try expectViolationAt(&bad, 0, .query, "page", "http.invalid_type");
    var body3: BindBody = .{};
    var rule = body3.request(arena.allocator(), "");
    rule.url = "/search?page=500";
    try std.testing.expectError(error.ValidationFailed, rule.bindQuery(Search));
    try expectViolationAt(&rule, 0, .query, "page", "validation.range");
}

test "bindQuery: a broken percent-escape is BadRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    req.url = "/search?q=%zz";
    try std.testing.expectError(error.BadRequest, req.bindQuery(Search));
}

fn fuzzQuery(bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    const url = try std.fmt.allocPrint(arena.allocator(), "/q?{s}", .{bytes});
    req.url = url;
    if (req.bindQuery(Search)) |s| {
        try std.testing.expect(s.page >= 1 and s.page <= 100);
    } else |_| {
        try std.testing.expect(req.violations().items.len <= rules.max_report_violations);
    }
}

test "fuzz: bindQuery decoding" {
    try @import("fuzz.zig").bytes(fuzzQuery, &.{ "q=a&page=2", "tag=x&tag=y", "page=%00", "q=%e2%82", "&&=&=" });
}

test "bindPath: a value that does not fit, or breaks a rule, is NotFound and records no violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Path = struct {
        id: u64,
        slug: []const u8 = "x",
        pub const field_rules = .{ .id = rules.positive };
    };
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    try req.params.map.put(arena.allocator(), "id", "42");
    try req.params.map.put(arena.allocator(), "slug", "a%2Fb");
    const p = try req.bindPath(Path);
    try std.testing.expectEqual(@as(u64, 42), p.id);
    try std.testing.expectEqualStrings("a/b", p.slug);

    var b2: BindBody = .{};
    var r2 = b2.request(arena.allocator(), "");
    try r2.params.map.put(arena.allocator(), "id", "abc");
    try std.testing.expectError(error.NotFound, r2.bindPath(Path));
    try std.testing.expectEqual(@as(usize, 0), r2.violations().items.len);
    var b3: BindBody = .{};
    var r3 = b3.request(arena.allocator(), "");
    try r3.params.map.put(arena.allocator(), "id", "0");
    try std.testing.expectError(error.NotFound, r3.bindPath(Path));
    try std.testing.expectEqual(@as(usize, 0), r3.violations().items.len);
}

test "bindHeaders: x_request_id reads X-Request-Id, optional ones are null, problems are in = header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Hdrs = struct {
        x_request_id: []const u8,
        x_retries: ?u8 = null,
    };
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    req.headers = try http.Headers.init(arena.allocator(), 8);
    try req.headers.add("x-request-id", "r-1");
    const h = try req.bindHeaders(Hdrs);
    try std.testing.expectEqualStrings("r-1", h.x_request_id);
    try std.testing.expect(h.x_retries == null);

    var b2: BindBody = .{};
    var r2 = b2.request(arena.allocator(), "");
    r2.headers = try http.Headers.init(arena.allocator(), 8);
    try r2.headers.add("X-Retries", "many");
    try std.testing.expectError(error.ValidationFailed, r2.bindHeaders(Hdrs));
    // In the DTO's field order: x_request_id (absent), then x_retries
    // (present, not a number).
    try expectViolationAt(&r2, 0, .header, "X-Request-Id", "http.missing_field");
    try expectViolationAt(&r2, 1, .header, "X-Retries", "http.invalid_type");
}

test "invalid/addViolation: appended in order, at most 100, ValidationFailed returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body: BindBody = .{};
    var req = body.request(arena.allocator(), "");
    req.addViolation("a", "users.first", "one");
    try std.testing.expectEqual(error.ValidationFailed, req.invalid("b", "users.second", "two"));
    try expectViolationAt(&req, 0, .body, "a", "users.first");
    try expectViolationAt(&req, 1, .body, "b", "users.second");
    for (0..150) |_| req.addViolation(null, "users.many", "m");
    try std.testing.expectEqual(@as(usize, 100), req.violations().items.len);
    try std.testing.expect(req.violations().truncated);
}
