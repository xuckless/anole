//! Serving zig-protobuf services over HTTP/2: `register` turns a service's
//! generated method table, instantiated with `Call` as its user data,
//!
//!     const Echo = echo_pb.Echo(anole.grpc.Call, anyerror);
//!     anole.grpc.register(void, app.router, Echo, .{
//!         .Unary = unary, .ServerStream = serverStream, ...
//!     });
//!
//! into one POST route per method (`/package.Service/Method`), and runs
//! each call: request frames decoded into messages, the handler, response
//! messages framed back, and the status in the trailers. A unary method
//! marked `option idempotency_level = NO_SIDE_EFFECTS` also gets a GET
//! route, for Connect's GET form, and a method annotated with
//! `google.api.http` gets REST routes that speak JSON (transcode.zig).
//!
//! Unary methods run on the stream's task. A streaming method's handler, its
//! request reader and its response writer run as tasks of one group, on the
//! stream's own executor (`placement .local`), joined
//! through `std.Io.Queue`s (zig-protobuf's streaming signatures); a failure
//! or the deadline in any of them cancels the others.
const std = @import("std");
const dusty = @import("dusty");
const frame = @import("frame.zig");
const status_mod = @import("status.zig");
const metadata_mod = @import("metadata.zig");
const deadline = @import("deadline.zig");
const Compression = @import("compression.zig").Compression;
const transcode = @import("transcode.zig");
const features = @import("build_options");
const placement = dusty.placement;

const Code = status_mod.Code;
const log = std.log.scoped(.anole_grpc);

/// The largest request message a registration takes unless its options say
/// otherwise; a larger one fails the call with RESOURCE_EXHAUSTED.
pub const default_max_message_size = 4 * 1024 * 1024;

/// Per registration (`registerWith`): the same service can be registered
/// twice, on two routers, with different options.
pub const RegisterOptions = struct {
    /// The largest request message, after decompression.
    max_message_size: usize = default_max_message_size,
    /// The most request message bytes one call takes in all, each message
    /// counted at its size plus 64. Decoded messages live in the call's
    /// arena until the call ends, so this bounds what a client-streaming
    /// or bidirectional call holds; past it the call fails with
    /// RESOURCE_EXHAUSTED. Raise it for long streams of large messages
    /// (an upload in chunks), or split them over several calls.
    max_received_bytes: usize = 64 * 1024 * 1024,
    /// How long a request message may take to arrive: from the start of
    /// the call for unary and server-streaming methods (and for the whole
    /// body of a Connect unary or gRPC-Web text call), and from its first
    /// byte in a client- or bidirectional-streaming call, whose client may
    /// pause between messages for as long as the call's deadline allows.
    /// Past it the call fails with DEADLINE_EXCEEDED. Null: no limit but
    /// the call's deadline.
    read_timeout: ?std.Io.Duration = .fromSeconds(30),
    /// The longest a call may run: a cap on the client's deadline
    /// (`grpc-timeout`, `connect-timeout-ms`) and the deadline of a call
    /// that sent none. Null (the default) lets a call without a client
    /// deadline run as long as its handler does, as gRPC servers do; set
    /// it to bound long-lived streams, which otherwise end only when the
    /// client or the handler ends them.
    max_call_duration: ?std.Io.Duration = null,
    /// Handed to every call of this registration as `Call.data`: state for
    /// handlers that serve more than one registration (`Health` keeps its
    /// registry here).
    data: ?*anyopaque = null,
    /// REST routes for the methods annotated with `google.api.http` (JSON
    /// transcoding). False registers the gRPC routes alone.
    transcode: bool = true,
    /// When response messages are gzipped. Needs `-Dcompression` and a
    /// client whose grpc-accept-encoding lists gzip, which most clients
    /// send on every call whether or not they compress themselves.
    response_compression: ResponseCompression = .mirror,
    /// The unary methods' handlers never wait (see `anole.noWait`): no
    /// database, cache or other service, no sleeping. Over HTTP/2 a call
    /// that arrives whole in one read then runs right where the connection
    /// reads it, without a task, and its `grpc-timeout` is not enforced
    /// (it has nothing to wait for). Streaming methods keep their tasks.
    no_wait: bool = false,
};

/// When a registration gzips its response messages
/// (`RegisterOptions.response_compression`).
pub const ResponseCompression = enum {
    /// When the request came gzipped too, as grpc-go does by default.
    mirror,
    /// Whenever the client accepts gzip: a deflate per message, worth it
    /// for large, compressible messages on slow links. On small ones it
    /// costs more CPU than the call itself (zlib-ng zeroes a 128 KiB hash
    /// table per message).
    accepted,
    /// Never: response messages go out uncompressed.
    never,
};

const default_options: RegisterOptions = .{};

/// What a client is told when a handler fails with an error that is not a
/// gRPC status, as grpc-java words it. The error itself is logged: its name
/// is the server's business.
pub const unknown_error_message = "Application error processing RPC";

/// One call, as its handler sees it: the request's metadata, its deadline,
/// an arena for the call, and the status and trailing metadata to send.
///
/// A handler takes it first and returns the response message, or
/// `call.fail(code, message)` to end the call with another status:
///
///     fn sayHello(call: *anole.grpc.Call, req: pb.HelloRequest) !pb.HelloReply {
///         if (req.name.len == 0) return call.fail(.invalid_argument, "name is required");
///         return .{ .message = try std.fmt.allocPrint(call.arena, "Hello, {s}", .{req.name}) };
///     }
///
/// Any other error ends the call with UNKNOWN; its name is logged, not
/// sent. `impl` is the server's own.
pub const Call = struct {
    /// The HTTP request the call came in as.
    req: *dusty.Request,
    /// The HTTP response the call goes out on. Use `addHeader` and
    /// `addTrailer` rather than writing to it.
    res: *dusty.Response,
    /// The call's arena (the request's): messages decoded for the handler
    /// live here, and what the handler returns may too. Thread-safe.
    arena: std.mem.Allocator,
    /// The server's runtime, for the handler's own I/O.
    io: std.Io,
    /// The application state of a `Server(Ctx)`, or null.
    ctx: ?*anyopaque,
    /// `RegisterOptions.data` of the registration that routed the call.
    data: ?*anyopaque = null,
    /// When the client's grpc-timeout runs out, if it sent one.
    deadline: ?std.Io.Clock.Timestamp = null,
    /// Set by `fail`, or left at OK.
    status: Code = .ok,
    /// Set by `fail`: sent as grpc-message.
    status_message: []const u8 = "",
    /// The server's own state for the call (framing, compression, the
    /// response writer). Internal: read and change the call through the
    /// fields above and the methods below.
    impl: Impl,

    /// What `impl` holds. Internal to Anole; not part of the API.
    const Impl = struct {
        /// Trailing metadata to send with the status (`addTrailer`).
        trailers: std.ArrayList(metadata_mod.Entry) = .empty,
        /// The largest request message this call accepts
        /// (`RegisterOptions.max_message_size`).
        max_message_size: usize,
        /// `RegisterOptions.max_received_bytes`, and what was received so
        /// far against it.
        max_received_bytes: usize = std.math.maxInt(usize),
        received: usize = 0,
        /// `RegisterOptions.read_timeout`.
        read_timeout: ?std.Io.Duration = null,
        /// How the client compressed its messages (grpc-encoding).
        request_compression: Compression = .identity,
        /// How the response messages are compressed
        /// (`RegisterOptions.response_compression`).
        response_compression: Compression = .identity,
        /// The response body, started by the first message (so initial
        /// metadata can be added until then).
        out: ?dusty.StreamingBodyWriter = null,
        out_buf: [16 * 1024]u8 = undefined,
        write_mutex: std.Io.Mutex = .init,
        /// The wire protocol and message encoding, from the request's
        /// content type.
        protocol: Protocol = .grpc,
        codec: Codec = .proto,
        /// Connect unary: the request was read; the response waits here for
        /// `finish`.
        unary_read: bool = false,
        unary_response: ?[]const u8 = null,
        /// gRPC-Web text: the request body, base64-decoded.
        text_input: ?std.Io.Reader = null,
        /// Connect GET: the request message, from the query.
        get_message: ?[]const u8 = null,
    };

    /// What `fail` returns: the status is on the call.
    pub const Error = error{GrpcStatus};

    /// Request metadata (a header), by lower-case name.
    pub fn metadata(self: *const Call, name: []const u8) ?[]const u8 {
        return self.req.headers.get(name);
    }

    /// The application state, as the `Ctx` it is.
    pub fn state(self: *const Call, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ctx.?));
    }

    /// Ends the call with `code` and `message`: return what this returns.
    pub fn fail(self: *Call, code: Code, message: []const u8) Error {
        self.status = code;
        self.status_message = message;
        return error.GrpcStatus;
    }

    /// Adds initial metadata (a response header). The response head goes
    /// out with the first response message: once it has started this
    /// returns `error.HeadersSent`. In a streaming handler, where the
    /// response writer runs as its own task, add headers before the first
    /// `putOne`.
    pub fn addHeader(self: *Call, name: []const u8, value: []const u8) !void {
        // The writer starts the head under the same lock (`writeBytes`).
        try self.impl.write_mutex.lock(self.io);
        defer self.impl.write_mutex.unlock(self.io);
        if (self.impl.out != null) return error.HeadersSent;
        try self.res.header(name, value);
    }

    /// Adds trailing metadata, sent with the status.
    pub fn addTrailer(self: *Call, name: []const u8, value: []const u8) !void {
        try self.impl.trailers.append(self.arena, .{ .key = name, .value = value });
    }

    /// The client went away (reset the stream or closed the connection),
    /// or the deadline passed. On HTTP/2 under zio the handler is canceled
    /// then anyway (its next wait returns `error.Canceled`); this is for
    /// work that does not wait, and for other runtimes and protocols.
    pub fn cancelled(self: *Call) bool {
        return self.res.peerGone() or self.deadlineExceeded();
    }

    /// How the client compressed its request messages (grpc-encoding):
    /// `.identity` or `.gzip`.
    pub fn requestCompression(self: *const Call) Compression {
        return self.impl.request_compression;
    }

    /// The wire protocol the call came in on: gRPC, gRPC-Web, Connect or
    /// JSON transcoding.
    pub fn protocol(self: *const Call) Protocol {
        return self.impl.protocol;
    }

    /// How its messages are encoded: protobuf binary or JSON.
    pub fn codec(self: *const Call) Codec {
        return self.impl.codec;
    }

    /// Whether the client's grpc-timeout has run out. False without one.
    pub fn deadlineExceeded(self: *const Call) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, d);
    }
};

/// The four gRPC call shapes, told apart by a generated method's
/// signature: one request or a queue of them, one response or a queue.
pub const MethodKind = enum { unary, server_streaming, client_streaming, bidi_streaming };

/// The protocols one route serves, told apart by the content type.
pub const Protocol = enum {
    /// gRPC over HTTP/2: length-prefixed messages, status in trailers.
    grpc,
    /// gRPC-Web (HTTP/1.1 or 2): the status in a final body frame.
    grpc_web,
    /// gRPC-Web with the body base64-encoded.
    grpc_web_text,
    /// Connect unary: one bare message each way, errors as JSON.
    connect,
    /// Connect streaming: enveloped messages, an end-stream message.
    connect_stream,
    /// JSON transcoding (`google.api.http`): a REST request, the response
    /// as JSON (a server stream as one JSON array), errors as
    /// google.rpc.Status JSON.
    http_json,
};

/// How messages are encoded: protobuf binary, or JSON (Connect's and
/// gRPC-Web's `+json` content types, and transcoding).
pub const Codec = enum { proto, json };

/// The element type of a `*std.Io.Queue(T)` parameter.
fn QueueElem(comptime P: type) type {
    const Q = @typeInfo(P).pointer.child;
    return @typeInfo(@typeInfo(@TypeOf(Q.init)).@"fn".param_types[0].?).pointer.child;
}

/// The kind and message types of a generated method's function pointer type:
/// `kind`, `Request` and `Response`.
pub const MethodOf = Method;

fn Method(comptime F: type) type {
    const info = @typeInfo(@typeInfo(F).pointer.child).@"fn";
    const params = info.param_types;
    const ret = @typeInfo(info.return_type.?).error_union.payload;
    const second_is_queue = @typeInfo(params[1].?) == .pointer;
    return struct {
        /// Which of the four call shapes the method is.
        pub const kind: MethodKind = if (params.len == 2)
            (if (second_is_queue) .client_streaming else .unary)
        else if (second_is_queue) .bidi_streaming else .server_streaming;
        /// The request message type.
        pub const Request = if (second_is_queue) QueueElem(params[1].?) else params[1].?;
        /// The response message type.
        pub const Response = if (params.len == 3) QueueElem(params[2].?) else ret;
    };
}

/// Registers every method of `Service` (a zig-protobuf service type,
/// `Svc(anole.grpc.Call, ErrorSet)`) on `router` with the handlers in
/// `impl`. For a `Server(Ctx)`, `Ctx` is its state type and `Call.ctx`
/// points at it. `registerWith` takes options.
pub fn register(comptime Ctx: type, router: *dusty.Router(Ctx), comptime Service: type, comptime impl: Service) void {
    registerWith(Ctx, router, Service, impl, .{});
}

/// `register`, with options for this registration (a message size limit,
/// data for the handlers).
pub fn registerWith(comptime Ctx: type, router: *dusty.Router(Ctx), comptime Service: type, comptime impl: Service, options: RegisterOptions) void {
    // The routes hand it to each call; it lives as long as the router.
    const registration = router.arena.allocator().create(RegisterOptions) catch @panic("OOM");
    registration.* = options;
    const info = @typeInfo(Service).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const path = "/" ++ Service.package ++ "." ++ Service.service_name ++ "/" ++ name;
        const handler = @field(impl, name);
        const M = Method(F);
        const Adapter = struct {
            fn run(ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response) !void {
                try serve(M, handler, ctx, req, res);
            }
        };
        const route = if (Ctx == void) struct {
            fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
                return Adapter.run(null, req, res);
            }
        }.h else struct {
            fn h(ctx: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                return Adapter.run(ctx, req, res);
            }
        }.h;
        const route_options: dusty.RouteOptions = .{ .data = registration, .no_wait = options.no_wait and M.kind == .unary };
        router.addRouteWith(.post, path, route, route_options);
        if (M.kind == .unary and comptime hasNoSideEffects(Service, name)) router.addRouteWith(.get, path, route, route_options);
        if (comptime transcode.annotated(Service, name)) {
            if (options.transcode) transcode.registerMethod(Ctx, router, Service, name, M, handler, registration);
        }
    }
}

/// Whether the method is marked `option idempotency_level =
/// NO_SIDE_EFFECTS`, which zig-protobuf's codegen keeps in the service's
/// `_method_options`.
fn hasNoSideEffects(comptime Service: type, comptime method: []const u8) bool {
    if (!@hasDecl(Service, "_method_options")) return false;
    const all = Service._method_options;
    if (!@hasField(@TypeOf(all), method)) return false;
    const options = @field(all, method);
    if (!@hasField(@TypeOf(options), "idempotency_level")) return false;
    return std.mem.eql(u8, @tagName(options.idempotency_level), "NO_SIDE_EFFECTS");
}

fn serve(comptime M: type, comptime handler: anytype, ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response) !void {
    const options: *const RegisterOptions = if (req.route) |route|
        (if (route.data) |d| @ptrCast(@alignCast(d)) else &default_options)
    else
        &default_options;
    // Connect GET (only routed for unary methods without side effects):
    // the codec comes from the query, not a content type.
    const is_get = req.method == .get or req.method == .head;
    const content_type = req.headers.get("content-type") orelse "";
    const kind = (if (is_get) classifyGet(req.query.get("encoding") orelse "") else classify(content_type)) orelse {
        res.status = .unsupported_media_type;
        return;
    };
    // gRPC proper needs HTTP/2's trailers; gRPC-Web and Connect do not.
    if (kind.protocol == .grpc and req.version_major != 2) {
        res.status = .http_version_not_supported;
        return;
    }
    // Connect's bare-message form is for unary methods only.
    if (kind.protocol == .connect and M.kind != .unary) {
        res.status = .unsupported_media_type;
        return;
    }

    var call: Call = .{
        .req = req,
        .res = res,
        .arena = req.arena,
        .io = req.io,
        .ctx = ctx,
        .data = options.data,
        .impl = .{
            .max_message_size = options.max_message_size,
            .max_received_bytes = options.max_received_bytes,
            .read_timeout = options.read_timeout,
            .protocol = kind.protocol,
            .codec = kind.codec,
        },
    };
    res.status = .ok;
    try res.header("content-type", kind.response_type);

    switch (call.impl.protocol) {
        .grpc, .grpc_web, .grpc_web_text, .connect_stream => {
            const prefix = if (call.impl.protocol == .connect_stream) "connect-" else "grpc-";
            var name_buf: [32]u8 = undefined;
            if (req.headers.get(concat(&name_buf, prefix, "content-encoding", "encoding"))) |enc| {
                call.impl.request_compression = Compression.parse(enc) orelse {
                    // Not `concat`: the response keeps the name past this frame.
                    try res.header(if (call.impl.protocol == .connect_stream) "connect-accept-encoding" else "grpc-accept-encoding", acceptEncoding());
                    return finish(&call, call.fail(.unimplemented, "unsupported message encoding"));
                };
                if (call.impl.request_compression == .gzip and !features.compression)
                    return finish(&call, call.fail(.unimplemented, "gzip is not built in"));
            }
            const compress = switch (options.response_compression) {
                .mirror => call.impl.request_compression == .gzip,
                .accepted => true,
                .never => false,
            };
            if (features.compression and compress) if (req.headers.get(concat(&name_buf, prefix, "accept-encoding", "accept-encoding"))) |accepted| {
                if (std.mem.indexOf(u8, accepted, "gzip") != null) call.impl.response_compression = .gzip;
            };
            if (call.impl.response_compression == .gzip) try res.header(if (call.impl.protocol == .connect_stream) "connect-content-encoding" else "grpc-encoding", "gzip");
            try res.header(if (call.impl.protocol == .connect_stream) "connect-accept-encoding" else "grpc-accept-encoding", acceptEncoding());
        },
        // HTTP's own Content-Encoding: dusty decodes the request body and
        // compresses the response (JSON; protobuf is not on its list).
        .connect => res.compress = true,
        // Only `serveTranscoded` makes these.
        .http_json => unreachable,
    }

    var timeout_ns: ?u64 = null;
    if (call.impl.protocol == .connect or call.impl.protocol == .connect_stream) {
        if (req.headers.get("connect-timeout-ms")) |value| {
            const ms = std.fmt.parseInt(u64, value, 10) catch
                return finish(&call, call.fail(.invalid_argument, "malformed connect-timeout-ms"));
            timeout_ns = ms *| std.time.ns_per_ms;
        }
    } else if (req.headers.get("grpc-timeout")) |value| {
        timeout_ns = deadline.parseTimeout(value) catch
            return finish(&call, call.fail(.internal, "malformed grpc-timeout"));
    }
    // A call can outlive the server's request timeout: the client's own
    // deadline bounds it, and `max_call_duration`; reading the request
    // messages is bounded by `read_timeout`.
    setDeadline(&call, timeout_ns, options.max_call_duration);
    defer boundTheRest(&call);

    if (is_get) call.impl.get_message = getMessage(&call) catch |err| return finish(&call, err);

    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);

    const result = switch (M.kind) {
        .unary => runUnary(M, handler, &call, &body),
        .server_streaming => runServerStreaming(M, handler, &call, &body),
        .client_streaming => runClientStreaming(M, handler, &call, &body),
        .bidi_streaming => runBidi(M, handler, &call, &body),
    };
    return finish(&call, result);
}

/// `prefix ++ grpc_name` or `prefix ++ connect_name`: the header names
/// gRPC and Connect use for the same thing.
fn concat(buf: *[32]u8, prefix: []const u8, connect_name: []const u8, grpc_name: []const u8) []const u8 {
    const name = if (std.mem.eql(u8, prefix, "connect-")) connect_name else grpc_name;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..name.len], name);
    return buf[0 .. prefix.len + name.len];
}

const Kind = struct { protocol: Protocol, codec: Codec, response_type: []const u8 };

/// The protocol and codec a content type asks for, and the content type to
/// answer with; null for one this does not serve.
fn classify(content_type: []const u8) ?Kind {
    const ct = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(ct, "application/grpc") or eq(ct, "application/grpc+proto"))
        return .{ .protocol = .grpc, .codec = .proto, .response_type = "application/grpc" };
    if (eq(ct, "application/grpc-web") or eq(ct, "application/grpc-web+proto"))
        return .{ .protocol = .grpc_web, .codec = .proto, .response_type = "application/grpc-web+proto" };
    if (eq(ct, "application/grpc-web-text") or eq(ct, "application/grpc-web-text+proto"))
        return .{ .protocol = .grpc_web_text, .codec = .proto, .response_type = "application/grpc-web-text+proto" };
    if (eq(ct, "application/proto"))
        return .{ .protocol = .connect, .codec = .proto, .response_type = "application/proto" };
    if (eq(ct, "application/json"))
        return .{ .protocol = .connect, .codec = .json, .response_type = "application/json" };
    if (eq(ct, "application/connect+proto"))
        return .{ .protocol = .connect_stream, .codec = .proto, .response_type = "application/connect+proto" };
    if (eq(ct, "application/connect+json"))
        return .{ .protocol = .connect_stream, .codec = .json, .response_type = "application/connect+json" };
    return null;
}

/// Connect GET's `encoding` query parameter, as `classify` answers.
fn classifyGet(encoding: []const u8) ?Kind {
    if (std.mem.eql(u8, encoding, "proto"))
        return .{ .protocol = .connect, .codec = .proto, .response_type = "application/proto" };
    if (std.mem.eql(u8, encoding, "json"))
        return .{ .protocol = .connect, .codec = .json, .response_type = "application/json" };
    return null;
}

/// Connect GET: the request message from the query (`message`, `base64`,
/// `compression`), back to the codec's bytes. Unknown parameters are
/// ignored, as the protocol asks.
fn getMessage(call: *Call) ![]const u8 {
    const query = &call.req.query;
    if (query.get("connect")) |version| {
        if (!std.mem.eql(u8, version, "v1")) return call.fail(.invalid_argument, "unsupported connect protocol version");
    }
    const compression: Compression = if (query.get("compression")) |name|
        Compression.parse(name) orelse return call.fail(.unimplemented, "unsupported compression; supported: " ++ comptime acceptEncoding())
    else
        .identity;
    if (compression == .gzip and !features.compression) return call.fail(.unimplemented, "gzip is not built in");
    const base64 = if (query.get("base64")) |flag| std.mem.eql(u8, flag, "1") else false;
    return decodeGetMessage(call.arena, query.get("message") orelse "", base64, compression, call.impl.max_message_size) catch |err| switch (err) {
        error.InvalidBase64 => call.fail(.invalid_argument, "message is not URL-safe base64"),
        else => |e| e,
    };
}

/// The `message` query parameter of a Connect GET (already percent-decoded)
/// back to the codec's bytes: URL-safe base64 (padded or not) undone when
/// `base64`, then inflated for gzip; at most `max_message_size` bytes.
fn decodeGetMessage(arena: std.mem.Allocator, text: []const u8, base64: bool, compression: Compression, max_message_size: usize) ![]const u8 {
    var message = text;
    if (base64) {
        const trimmed = std.mem.trimEnd(u8, message, "=");
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const len = decoder.calcSizeForSlice(trimmed) catch return error.InvalidBase64;
        const decoded = try arena.alloc(u8, len);
        decoder.decode(decoded, trimmed) catch return error.InvalidBase64;
        message = decoded;
    }
    // An empty message is never decompressed.
    if (compression == .gzip and message.len > 0) message = try frame.decompressGzip(arena, message, max_message_size);
    if (message.len > max_message_size) return error.MessageTooLarge;
    return message;
}

fn acceptEncoding() []const u8 {
    return if (features.compression) "identity,gzip" else "identity";
}

/// Sends the status (and trailing metadata) the protocol's way and ends
/// the response. Runs even when the call's task was canceled by its
/// deadline.
fn finish(call: *Call, result: anyerror!void) !void {
    const protection = call.io.swapCancelProtection(.blocked);
    defer _ = call.io.swapCancelProtection(protection);
    if (result) |_| {} else |err| switch (err) {
        error.GrpcStatus => {},
        error.Canceled => {
            if (call.deadlineExceeded()) {
                call.status = .deadline_exceeded;
                call.status_message = "deadline exceeded";
            } else {
                call.status = .cancelled;
                call.status_message = "cancelled";
            }
        },
        error.MessageTooLarge => {
            call.status = .resource_exhausted;
            call.status_message = "message larger than the limit";
        },
        error.CallLimitExceeded => {
            call.status = .resource_exhausted;
            call.status_message = "request messages over the call's limit";
        },
        error.ReadTimeout => {
            call.status = .deadline_exceeded;
            call.status_message = "request message not received in time";
        },
        error.DecodeFailed, error.TruncatedFrame, error.InvalidCompressedFlag, error.CompressionMismatch, error.MalformedCompressedMessage => {
            call.status = .internal;
            call.status_message = switch (err) {
                error.DecodeFailed => "request message does not decode",
                error.TruncatedFrame => "request message frame cut short",
                error.InvalidCompressedFlag => "invalid compressed flag in a message frame",
                error.CompressionMismatch => "compressed message without a message encoding",
                else => "malformed compressed message",
            };
        },
        error.ExpectedUnaryMessage => {
            call.status = .unimplemented;
            call.status_message = "more than one request message for a unary method";
        },
        // The peer is gone: nothing can be told.
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => {
            const path = call.req.url[0 .. std.mem.indexOfScalar(u8, call.req.url, '?') orelse call.req.url.len];
            if (call.res.peerGone()) {
                log.debug("{s}: {t} after the client went away", .{ path, err });
                return;
            }
            // The error's name stays here; the client gets a generic
            // message (grpc-java's), not an internal identifier.
            if (call.req.id.len > 0) {
                log.warn("{s} failed with error.{t} (request {s}); the client gets UNKNOWN", .{ path, err, call.req.id });
            } else {
                log.warn("{s} failed with error.{t}; the client gets UNKNOWN", .{ path, err });
            }
            call.status = .unknown;
            call.status_message = unknown_error_message;
        },
    }
    switch (call.impl.protocol) {
        .grpc => {
            // Static text: the response keeps the slice, and HTTP/2 sends the
            // trailers from its writer task after this frame has returned.
            try call.res.trailer("grpc-status", statusText(call.status));
            if (call.status_message.len > 0) try call.res.trailer("grpc-message", try percentEncode(call.arena, call.status_message));
            for (call.impl.trailers.items) |t| try call.res.trailer(t.key, t.value);
            if (call.impl.out) |*o| {
                o.end() catch {};
            } else {
                // Nothing streamed yet: the status goes out with an empty body.
                call.res.body = "";
            }
        },
        .grpc_web, .grpc_web_text => {
            // The trailers are a last frame, flagged 0x80, of HTTP/1-style
            // header lines.
            var block: std.ArrayList(u8) = .empty;
            try block.print(call.arena, "grpc-status:{d}\r\n", .{@backingInt(call.status)});
            if (call.status_message.len > 0) try block.print(call.arena, "grpc-message:{s}\r\n", .{try percentEncode(call.arena, call.status_message)});
            for (call.impl.trailers.items) |t| try block.print(call.arena, "{s}:{s}\r\n", .{ t.key, t.value });
            try writeFrame(call, 0x80, block.items);
            if (call.impl.out) |*o| o.end() catch {};
        },
        .connect_stream => {
            var json: std.ArrayList(u8) = .empty;
            try json.appendSlice(call.arena, "{");
            if (call.status != .ok) {
                try json.print(call.arena, "\"error\":{{\"code\":\"{s}\",\"message\":{f}}}", .{ connectCode(call.status), std.json.fmt(call.status_message, .{}) });
            }
            if (call.impl.trailers.items.len > 0) {
                if (call.status != .ok) try json.appendSlice(call.arena, ",");
                try json.appendSlice(call.arena, "\"metadata\":{");
                for (call.impl.trailers.items, 0..) |t, i| {
                    if (i > 0) try json.appendSlice(call.arena, ",");
                    try json.print(call.arena, "{f}:[{f}]", .{ std.json.fmt(t.key, .{}), std.json.fmt(t.value, .{}) });
                }
                try json.appendSlice(call.arena, "}");
            }
            try json.appendSlice(call.arena, "}");
            // End-of-stream message: flag 0x02, never compressed.
            try writeFrame(call, 0x02, json.items);
            if (call.impl.out) |*o| o.end() catch {};
        },
        .connect => {
            for (call.impl.trailers.items) |t| {
                try call.res.header(try std.fmt.allocPrint(call.arena, "trailer-{s}", .{t.key}), t.value);
            }
            if (call.status == .ok) {
                call.res.body = call.impl.unary_response orelse "";
            } else {
                call.res.status = connectHttpStatus(call.status);
                call.res.header("content-type", "application/json") catch {};
                call.res.body = try std.fmt.allocPrint(call.arena, "{{\"code\":\"{s}\",\"message\":{f}}}", .{ connectCode(call.status), std.json.fmt(call.status_message, .{}) });
            }
        },
        .http_json => {
            if (call.impl.out) |*o| {
                // A server stream's array has started, under a 200: an error
                // now can only cut it short, which the client sees as a
                // reset stream (HTTP/2) or a body without its last chunk
                // (HTTP/1.1), never as a complete array. Envoy does the same.
                if (call.status != .ok) {
                    if (call.res.peerGone()) return;
                    const path = call.req.url[0 .. std.mem.indexOfScalar(u8, call.req.url, '?') orelse call.req.url.len];
                    log.warn("{s}: JSON stream cut short by {t}: {s}", .{ path, call.status, call.status_message });
                    return call.res.abort();
                }
                for (call.impl.trailers.items) |t| try call.res.trailer(t.key, t.value);
                try writeBytes(call, "]");
                o.end() catch {};
            } else {
                // Trailing metadata as headers, as grpc-gateway sends it.
                for (call.impl.trailers.items) |t| {
                    try call.res.header(try std.fmt.allocPrint(call.arena, "grpc-trailer-{s}", .{t.key}), t.value);
                }
                if (call.status == .ok) {
                    // A server stream that sent nothing is an empty array.
                    call.res.body = call.impl.unary_response orelse "[]";
                } else {
                    call.res.status = connectHttpStatus(call.status);
                    call.res.body = try transcode.errorBody(call.arena, @backingInt(call.status), call.status_message);
                }
            }
        },
    }
}

/// A request a `google.api.http` binding matched (transcode.zig): the
/// request message from the path, the query and the body, the handler, and
/// the response (or each message of a server stream, as elements of one
/// array) as JSON. Client and bidirectional streaming are not transcoded:
/// they answer UNIMPLEMENTED (501).
pub fn serveTranscoded(
    comptime M: type,
    comptime handler: anytype,
    comptime body: []const u8,
    comptime response_body: []const u8,
    ctx: ?*anyopaque,
    req: *dusty.Request,
    res: *dusty.Response,
    captures: []const transcode.Capture,
    options: *const RegisterOptions,
) !void {
    var call: Call = .{
        .req = req,
        .res = res,
        .arena = req.arena,
        .io = req.io,
        .ctx = ctx,
        .data = options.data,
        .impl = .{
            .max_message_size = options.max_message_size,
            .max_received_bytes = options.max_received_bytes,
            .read_timeout = options.read_timeout,
            .protocol = .http_json,
            .codec = .json,
        },
    };
    res.status = .ok;
    try res.header("content-type", "application/json");
    // HTTP's own Content-Encoding, both ways (dusty decodes the request).
    res.compress = true;
    const streaming_request = comptime M.kind == .client_streaming or M.kind == .bidi_streaming;
    if (streaming_request) return finish(&call, call.fail(.unimplemented, unimplemented_streaming));

    const timeout_ns: ?u64 = if (req.headers.get("grpc-timeout")) |value|
        deadline.parseTimeout(value) catch return finish(&call, call.fail(.invalid_argument, "malformed grpc-timeout"))
    else
        null;

    // The body is read under the server's request timeout, as on any
    // route; the call's own deadline starts once the request is in.
    defer boundTheRest(&call);
    const request = transcodedRequest(M.Request, body, &call, captures) catch |err| {
        // The body did not arrive (the request timed out, or the peer went
        // away): nothing to answer, and the connection closes.
        if (@as(anyerror, err) == error.ReadFailed or @as(anyerror, err) == error.Canceled) return err;
        // Only a binding with a body can fail this way.
        if (@as(anyerror, err) == error.UnsupportedMediaType) {
            res.status = .unsupported_media_type;
            res.body = try transcode.errorBody(call.arena, @backingInt(Code.invalid_argument), "the request body must be JSON (Content-Type: application/json)");
            return;
        }
        return finish(&call, err);
    };
    setDeadline(&call, timeout_ns, options.max_call_duration);
    const result = switch (M.kind) {
        .unary => runTranscodedUnary(M, handler, response_body, &call, request),
        .server_streaming => runTranscodedStream(M, handler, response_body, &call, request),
        .client_streaming, .bidi_streaming => call.fail(.unimplemented, unimplemented_streaming),
    };
    return finish(&call, result);
}

const unimplemented_streaming = "client and bidirectional streaming methods are not transcoded; call them over gRPC, gRPC-Web or Connect";

/// The request message of a transcoded call; a request that does not make
/// one fails the call with INVALID_ARGUMENT.
fn transcodedRequest(comptime Req: type, comptime body: []const u8, call: *Call, captures: []const transcode.Capture) !Req {
    var body_text: []const u8 = "";
    if (body.len > 0) {
        var in_buf: [16 * 1024]u8 = undefined;
        var reader = try call.req.reader(&in_buf);
        body_text = reader.interface.allocRemaining(call.arena, .limited(call.impl.max_message_size +| 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.MessageTooLarge,
            else => |e| return e,
        };
        if (body_text.len > call.impl.max_message_size) return error.MessageTooLarge;
        // A body of another type is refused, so that a cross-site form or
        // `text/plain` request, which browsers send without asking first,
        // cannot reach the handler.
        if (std.mem.trim(u8, body_text, " \t\r\n").len > 0 and !isJsonType(call.req.headers.get("content-type") orelse ""))
            return error.UnsupportedMediaType;
    }
    const query = if (std.mem.indexOfScalar(u8, call.req.url, '?')) |q| call.req.url[q + 1 ..] else "";
    var diag: transcode.Diagnostic = .{};
    return transcode.decodeRequest(Req, call.arena, body, body_text, captures, query, &diag) catch |err| switch (err) {
        error.InvalidArgument => call.fail(.invalid_argument, diag.message),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Whether a Content-Type is JSON: `application/json` or a `+json` type,
/// with any parameters.
fn isJsonType(content_type: []const u8) bool {
    const media = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return true;
    return media.len > 5 and std.ascii.eqlIgnoreCase(media[media.len - 5 ..], "+json") and std.mem.indexOfScalar(u8, media, '/') != null;
}

fn runTranscodedUnary(comptime M: type, comptime handler: anytype, comptime response_body: []const u8, call: *Call, request: M.Request) !void {
    const response = try handler(call, request);
    call.impl.unary_response = try transcode.encodeResponse(M.Response, call.arena, response, response_body);
}

/// A server stream as one JSON array, sent element by element: `[` with
/// the first message, `,` before each next one, and `]` from `finish`.
fn runTranscodedStream(comptime M: type, comptime handler: anytype, comptime response_body: []const u8, call: *Call, request: M.Request) !void {
    var buf: [queue_len]M.Response = undefined;
    var responses: std.Io.Queue(M.Response) = .init(&buf);
    var group: std.Io.Group = .init;
    defer group.cancel(call.io);
    var handler_result: anyerror!void = {};
    try placement.concurrent(&group, call.io, .local, Tasks(M, handler).serverStreaming, .{ call, request, &responses, &handler_result });
    while (true) {
        const message = responses.getOne(call.io) catch |err| switch (err) {
            error.Closed => break,
            error.Canceled => return error.Canceled,
        };
        const json = try transcode.encodeResponse(M.Response, call.arena, message, response_body);
        try writeBytes(call, try std.mem.concat(call.arena, u8, &.{ if (call.impl.out == null) "[" else ",", json }));
    }
    try group.await(call.io);
    return handler_result;
}

/// Connect's name for a code: gRPC's, but "canceled".
fn connectCode(code: Code) []const u8 {
    return if (code == .cancelled) "canceled" else @tagName(code);
}

/// The HTTP status of a Connect unary error.
fn connectHttpStatus(code: Code) dusty.Status {
    return switch (code) {
        .ok => .ok,
        .cancelled => @fromBackingInt(@intCast(499)),
        .unknown, .internal, .data_loss => .internal_server_error,
        .invalid_argument, .failed_precondition, .out_of_range => .bad_request,
        .deadline_exceeded => .gateway_timeout,
        .not_found => .not_found,
        .already_exists, .aborted => .conflict,
        .permission_denied => .forbidden,
        .resource_exhausted => .too_many_requests,
        .unimplemented => .not_implemented,
        .unavailable => .service_unavailable,
        .unauthenticated => .unauthorized,
    };
}

/// grpc-message is percent-encoded UTF-8 (gRPC over HTTP/2, "Responses").
fn percentEncode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch >= 0x20 and ch <= 0x7e and ch != '%') {
            try out.append(arena, ch);
        } else {
            try out.print(arena, "%{X:0>2}", .{ch});
        }
    }
    return out.items;
}

/// Where request frames are read and inflated, to be freed as soon as
/// they are decoded into the call's arena.
const scratch = if (@import("builtin").is_test) std.testing.allocator else std.heap.smp_allocator;

/// What a request message counts against `max_received_bytes` beyond its
/// size: decoding allocates even for an empty one.
const per_message_charge = 64;

/// The next request message, or null at the end of the request. `streaming`
/// for the reader of a client- or bidirectional-streaming call, whose
/// client may wait before a message as long as it likes.
fn readRequest(comptime Req: type, call: *Call, body: *dusty.RequestBodyReader, streaming: bool) !?Req {
    var owned: ?[]u8 = null;
    defer if (owned) |p| scratch.free(p);
    const payload = switch (call.impl.protocol) {
        .connect => blk: {
            // The whole body is the one message (Connect GET: the query's).
            if (call.impl.unary_read) return null;
            call.impl.unary_read = true;
            if (call.impl.get_message) |message| break :blk message;
            break :blk try readWhole(call, &body.interface, call.impl.max_message_size +| 1, streaming);
        },
        .grpc_web_text => blk: {
            if (call.impl.text_input == null) {
                const text = try readWhole(call, &body.interface, call.impl.max_message_size *| 2 +| 4096, streaming);
                call.impl.text_input = .fixed(try decodeBase64Chunks(call.arena, text));
            }
            const msg = (try frame.readMessage(&call.impl.text_input.?, scratch, call.impl.max_message_size, call.impl.request_compression)) orelse return null;
            owned = msg.payload;
            break :blk msg.payload;
        },
        else => blk: {
            const msg = (try readFrame(call, &body.interface, streaming)) orelse return null;
            owned = msg.payload;
            break :blk msg.payload;
        },
    };
    if (payload.len > call.impl.max_message_size) return error.MessageTooLarge;
    call.impl.received +|= payload.len + per_message_charge;
    if (call.impl.received > call.impl.max_received_bytes) return error.CallLimitExceeded;
    return try decodePayload(Req, call.arena, call.impl.codec, payload);
}

/// The next message frame off the body, read into `scratch` within the
/// call's `read_timeout`.
fn readFrame(call: *Call, reader: *std.Io.Reader, streaming: bool) !?frame.Decoder.DecodedMessage {
    const timeout = call.impl.read_timeout orelse
        return frame.readMessage(reader, scratch, call.impl.max_message_size, call.impl.request_compression);
    if (streaming) {
        // Waiting for the next message is not timed; its bytes are.
        _ = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
    }
    const limit: dusty.Deadline = .init(call.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
    return limit.run(frame.readMessage, .{ reader, scratch, call.impl.max_message_size, call.impl.request_compression }) catch |err| switch (err) {
        error.Timeout => error.ReadTimeout,
        else => |e| e,
    };
}

/// The rest of the body, of at most `limit - 1` bytes, in the call's
/// arena, read within the call's `read_timeout`.
fn readWhole(call: *Call, reader: *std.Io.Reader, limit: usize, streaming: bool) ![]u8 {
    const read = struct {
        fn all(r: *std.Io.Reader, arena: std.mem.Allocator, max: usize) ![]u8 {
            return r.allocRemaining(arena, .limited(max)) catch |err| switch (err) {
                error.StreamTooLong => error.MessageTooLarge,
                else => |e| e,
            };
        }
    }.all;
    const timeout = call.impl.read_timeout orelse return read(reader, call.arena, limit);
    if (streaming) {
        _ = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => return &.{},
            else => |e| return e,
        };
    }
    const bound: dusty.Deadline = .init(call.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
    return bound.run(read, .{ reader, call.arena, limit }) catch |err| switch (err) {
        error.Timeout => error.ReadTimeout,
        else => |e| e,
    };
}

/// Once the call is done, what the server still does for the request
/// (send the response, read what is left of the body) is bounded by
/// `read_timeout` rather than by the call's deadline, or by none.
fn boundTheRest(call: *Call) void {
    const timeout = call.impl.read_timeout orelse return;
    call.req.setTimeout(.{ .duration = .{ .raw = timeout, .clock = .awake } });
}

/// Sets the call's deadline: the client's (`client_ns`), capped at
/// `max_call_duration`, or that alone. With neither, the request's own
/// timeout is lifted: the call runs as long as its handler does.
fn setDeadline(call: *Call, client_ns: ?u64, max_call_duration: ?std.Io.Duration) void {
    var ns = client_ns;
    if (max_call_duration) |max| {
        const cap: u64 = @intCast(std.math.clamp(max.toNanoseconds(), 0, std.math.maxInt(i64)));
        ns = if (ns) |n| @min(n, cap) else cap;
    }
    const n = ns orelse return call.req.setTimeout(.none);
    const d = std.Io.Clock.Timestamp.now(call.io, .awake).addDuration(.{ .raw = .fromNanoseconds(@intCast(@min(n, std.math.maxInt(i64)))), .clock = .awake });
    call.deadline = d;
    call.req.setTimeout(.{ .deadline = d });
}

/// One request message's bytes decoded as `Req`, into `arena`, in `codec`:
/// `error.DecodeFailed` for bytes that are not a `Req`. The result does
/// not point into `payload`. Protobuf input nests at most zig-protobuf's
/// `recursion_limit` deep; JSON input, `transcode.max_json_depth`.
pub fn decodePayload(comptime Req: type, arena: std.mem.Allocator, codec: Codec, payload: []const u8) error{ DecodeFailed, OutOfMemory }!Req {
    switch (codec) {
        .proto => {
            var reader: std.Io.Reader = .fixed(payload);
            return Req.decode(&reader, arena) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.DecodeFailed,
            };
        },
        .json => {
            // Parsing into a message type that contains itself recurses
            // once per level.
            if (!transcode.jsonDepthWithin(payload, transcode.max_json_depth)) return error.DecodeFailed;
            const parsed = Req.jsonDecode(payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }, arena) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.DecodeFailed,
            };
            return parsed.value;
        },
    }
}

/// gRPC-Web text bodies may be several base64 chunks, each with its own
/// padding: decoded four characters at a time.
fn decodeBase64Chunks(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var quad: [4]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '\r' or ch == '\n' or ch == ' ') continue;
        quad[n] = ch;
        n += 1;
        if (n == 4) {
            var bytes: [3]u8 = undefined;
            const len = std.base64.standard.Decoder.calcSizeForSlice(&quad) catch return error.DecodeFailed;
            std.base64.standard.Decoder.decode(bytes[0..len], &quad) catch return error.DecodeFailed;
            try out.appendSlice(arena, bytes[0..len]);
            n = 0;
        }
    }
    if (n != 0) return error.DecodeFailed;
    return out.items;
}

/// JSON as the proto3 mapping writes it (protojson, which Connect and JSON
/// transcoding both speak): a oneof's member is a field of the message.
/// zig-protobuf's default nests it in an object named after the oneof.
pub const json_options: @import("protobuf").json.Options = .{ .emit_oneof_field_name = false };

fn encodeMessage(comptime Msg: type, call: *Call, message: Msg) ![]const u8 {
    switch (call.impl.codec) {
        .proto => {
            var encoded: std.Io.Writer.Allocating = .init(call.arena);
            try message.encode(&encoded.writer, call.arena);
            return encoded.written();
        },
        .json => return message.jsonEncode(.{}, json_options, call.arena),
    }
}

fn writeResponse(comptime Resp: type, call: *Call, message: Resp) !void {
    const payload = try encodeMessage(Resp, call, message);
    if (call.impl.protocol == .connect) {
        call.impl.unary_response = payload;
        return;
    }
    const framed = try frame.encodeWithCompression(call.arena, payload, call.impl.response_compression);
    try writeBytes(call, framed);
}

/// The decimal text of a status code, for the grpc-status trailer. Static,
/// so it outlives the call: a response holds its trailer values by
/// reference until they are on the wire.
fn statusText(code: status_mod.Code) []const u8 {
    const texts = comptime blk: {
        const values = @typeInfo(status_mod.Code).@"enum".field_values;
        var out: [values.len][]const u8 = undefined;
        for (values) |v| out[v] = std.fmt.comptimePrint("{d}", .{v});
        break :blk out;
    };
    return texts[@backingInt(code)];
}

/// One frame with these flags (gRPC-Web's trailers, Connect's end of
/// stream).
fn writeFrame(call: *Call, flags: u8, payload: []const u8) !void {
    const framed = try call.arena.alloc(u8, frame.header_size + payload.len);
    framed[0] = flags;
    std.mem.writeInt(u32, framed[1..5], @intCast(payload.len), .big);
    @memcpy(framed[frame.header_size..], payload);
    try writeBytes(call, framed);
}

/// Response body bytes, base64-encoded for gRPC-Web text, starting the
/// response with the first.
fn writeBytes(call: *Call, bytes: []const u8) !void {
    const data = if (call.impl.protocol == .grpc_web_text) blk: {
        const enc = try call.arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        break :blk std.base64.standard.Encoder.encode(enc, bytes);
    } else bytes;
    try call.impl.write_mutex.lock(call.io);
    defer call.impl.write_mutex.unlock(call.io);
    if (call.impl.out == null) call.impl.out = try call.res.stream(&call.impl.out_buf);
    const out = &call.impl.out.?;
    out.interface.writeAll(data) catch return out.err orelse error.WriteFailed;
    out.interface.flush() catch return out.err orelse error.WriteFailed;
}

fn runUnary(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    const request = (try readRequest(M.Request, call, body, false)) orelse
        return call.fail(.unimplemented, "a unary call needs one request message");
    if (try readRequest(M.Request, call, body, false) != null) return error.ExpectedUnaryMessage;
    const response = try handler(call, request);
    try writeResponse(M.Response, call, response);
}

const queue_len = 16;

fn runServerStreaming(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    const request = (try readRequest(M.Request, call, body, false)) orelse
        return call.fail(.unimplemented, "a server-streaming call needs one request message");
    if (try readRequest(M.Request, call, body, false) != null) return error.ExpectedUnaryMessage;
    var buf: [queue_len]M.Response = undefined;
    var responses: std.Io.Queue(M.Response) = .init(&buf);
    var group: std.Io.Group = .init;
    defer group.cancel(call.io);
    var handler_result: anyerror!void = {};
    try placement.concurrent(&group, call.io, .local, Tasks(M, handler).serverStreaming, .{ call, request, &responses, &handler_result });
    try pumpResponses(M.Response, call, &responses);
    try group.await(call.io);
    return handler_result;
}

/// The tasks of a streaming call, made concrete per method (a task cannot
/// be a generic function).
fn Tasks(comptime M: type, comptime handler: anytype) type {
    return struct {
        fn serverStreaming(call: *Call, request: M.Request, responses: *std.Io.Queue(M.Response), result: *anyerror!void) std.Io.Cancelable!void {
            defer responses.close(call.io);
            handler(call, request, responses) catch |err| {
                result.* = err;
            };
        }

        fn bidi(call: *Call, requests: *std.Io.Queue(M.Request), responses: *std.Io.Queue(M.Response), result: *anyerror!void) std.Io.Cancelable!void {
            defer responses.close(call.io);
            defer requests.close(call.io);
            handler(call, requests, responses) catch |err| {
                result.* = err;
            };
        }

        /// Decodes each request message into the queue, closing it at the
        /// end of the body.
        fn readRequests(call: *Call, body: *dusty.RequestBodyReader, requests: *std.Io.Queue(M.Request), result: *anyerror!void) std.Io.Cancelable!void {
            defer requests.close(call.io);
            while (true) {
                const message = readRequest(M.Request, call, body, true) catch |err| {
                    result.* = err;
                    return;
                } orelse return;
                requests.putOne(call.io, message) catch |err| switch (err) {
                    // The handler is done reading.
                    error.Closed => return,
                    error.Canceled => return error.Canceled,
                };
            }
        }
    };
}

/// Frames each response the handler queues until it closes the queue.
fn pumpResponses(comptime Resp: type, call: *Call, responses: *std.Io.Queue(Resp)) !void {
    while (true) {
        const message = responses.getOne(call.io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        try writeResponse(Resp, call, message);
    }
}

fn runClientStreaming(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    var buf: [queue_len]M.Request = undefined;
    var requests: std.Io.Queue(M.Request) = .init(&buf);
    var group: std.Io.Group = .init;
    defer group.cancel(call.io);
    var reader_result: anyerror!void = {};
    try placement.concurrent(&group, call.io, .local, Tasks(M, handler).readRequests, .{ call, body, &requests, &reader_result });
    const response = handler(call, &requests) catch |err| {
        // The reader's failure, if it failed first, says more.
        reader_result catch |rerr| return rerr;
        return err;
    };
    requests.close(call.io);
    try group.await(call.io);
    try reader_result;
    try writeResponse(M.Response, call, response);
}

fn runBidi(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    var in_buf: [queue_len]M.Request = undefined;
    var requests: std.Io.Queue(M.Request) = .init(&in_buf);
    var out_buf: [queue_len]M.Response = undefined;
    var responses: std.Io.Queue(M.Response) = .init(&out_buf);
    var group: std.Io.Group = .init;
    defer group.cancel(call.io);
    var reader_result: anyerror!void = {};
    var handler_result: anyerror!void = {};
    try placement.concurrent(&group, call.io, .local, Tasks(M, handler).readRequests, .{ call, body, &requests, &reader_result });
    try placement.concurrent(&group, call.io, .local, Tasks(M, handler).bidi, .{ call, &requests, &responses, &handler_result });
    try pumpResponses(M.Response, call, &responses);
    try group.await(call.io);
    try reader_result;
    return handler_result;
}

test "fuzz: Connect GET messages, base64 and gzip" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            // The first byte picks base64 and gzip, and a limit.
            const base64 = input[0] & 1 != 0;
            const compression: Compression = if (input[0] & 2 != 0 and features.compression) .gzip else .identity;
            const max: usize = if (input[0] & 4 != 0) 64 else 1024;
            // Refusing the input is fine; running out of memory is not.
            const message = decodeGetMessage(arena.allocator(), input[1..], base64, compression, max) catch |err| {
                if (err == error.OutOfMemory) return err;
                return;
            };
            if (message.len > max) return error.OverLimit;
        }
    }.check, &.{
        "\x01CgJoaQ",
        "\x01CgJoaQ==",
        "\x00{\"message\":\"hi\"}",
        "\x03H4sIAAAAAAAAA-PiYGFgYGRgAAA",
        "\x07H4sIAAAAAAAA",
        "\x02\x1f\x8b\x08\x00",
    });
}

test "percentEncode leaves printable ASCII and escapes the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("not found: %25x%0A%C3%A9", try percentEncode(arena.allocator(), "not found: %x\né"));
}
