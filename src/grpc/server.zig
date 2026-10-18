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
//! messages framed back, and the status in the trailers.
//!
//! Unary methods run on the stream's task. A streaming method's handler, its
//! request reader and its response writer run as tasks of one group, joined
//! through `std.Io.Queue`s (zig-protobuf's streaming signatures); a failure
//! or the deadline in any of them cancels the others.
const std = @import("std");
const dusty = @import("dusty");
const frame = @import("frame.zig");
const status_mod = @import("status.zig");
const metadata_mod = @import("metadata.zig");
const deadline = @import("deadline.zig");
const Compression = @import("compression.zig").Compression;
const features = @import("build_options");

const Code = status_mod.Code;

pub const default_max_message_size = 4 * 1024 * 1024;

/// One call, as its handler sees it: the request's metadata, its deadline,
/// an arena for the call, and the status and trailing metadata to send.
pub const Call = struct {
    req: *dusty.Request,
    res: *dusty.Response,
    /// The call's arena (the request's): messages decoded for the handler
    /// live here, and what the handler returns may too. Thread-safe.
    arena: std.mem.Allocator,
    io: std.Io,
    /// The application state of a `Server(Ctx)`, or null.
    ctx: ?*anyopaque,
    /// When the client's grpc-timeout runs out, if it sent one.
    deadline: ?std.Io.Clock.Timestamp = null,
    /// Set by `fail`, or left at OK.
    status: Code = .ok,
    status_message: []const u8 = "",
    trailers: std.ArrayList(metadata_mod.Entry) = .empty,
    max_message_size: usize,
    request_compression: Compression = .identity,
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

    /// Adds initial metadata (a response header). Only before the first
    /// response message is sent.
    pub fn addHeader(self: *Call, name: []const u8, value: []const u8) !void {
        try self.res.header(name, value);
    }

    /// Adds trailing metadata, sent with the status.
    pub fn addTrailer(self: *Call, name: []const u8, value: []const u8) !void {
        try self.trailers.append(self.arena, .{ .key = name, .value = value });
    }

    /// The client went away (reset the stream or closed the connection),
    /// or the deadline passed. A handler that waits a long time on
    /// something other than its queues (a timer, a condition) checks this
    /// between waits: the engine does not cancel it on the client's reset.
    pub fn cancelled(self: *Call) bool {
        return self.res.peerGone() or self.deadlineExceeded();
    }

    pub fn deadlineExceeded(self: *const Call) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, d);
    }
};

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
};

pub const Codec = enum { proto, json };

/// The element type of a `*std.Io.Queue(T)` parameter.
fn QueueElem(comptime P: type) type {
    const Q = @typeInfo(P).pointer.child;
    return @typeInfo(@typeInfo(@TypeOf(Q.init)).@"fn".param_types[0].?).pointer.child;
}

/// The kind and message types of a generated method's function pointer type.
pub const MethodOf = Method;

fn Method(comptime F: type) type {
    const info = @typeInfo(@typeInfo(F).pointer.child).@"fn";
    const params = info.param_types;
    const ret = @typeInfo(info.return_type.?).error_union.payload;
    const second_is_queue = @typeInfo(params[1].?) == .pointer;
    return struct {
        pub const kind: MethodKind = if (params.len == 2)
            (if (second_is_queue) .client_streaming else .unary)
        else if (second_is_queue) .bidi_streaming else .server_streaming;
        pub const Request = if (second_is_queue) QueueElem(params[1].?) else params[1].?;
        pub const Response = if (params.len == 3) QueueElem(params[2].?) else ret;
    };
}

/// Registers every method of `Service` (a zig-protobuf service type,
/// `Svc(anole.grpc.Call, ErrorSet)`) on `router` with the handlers in
/// `impl`. For a `Server(Ctx)`, `Ctx` is its state type and `Call.ctx`
/// points at it.
pub fn register(comptime Ctx: type, router: *dusty.Router(Ctx), comptime Service: type, comptime impl: Service) void {
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
        if (Ctx == void) {
            router.post(path, struct {
                fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
                    return Adapter.run(null, req, res);
                }
            }.h);
        } else {
            router.post(path, struct {
                fn h(ctx: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                    return Adapter.run(ctx, req, res);
                }
            }.h);
        }
    }
}

fn serve(comptime M: type, comptime handler: anytype, ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response) !void {
    const content_type = req.headers.get("content-type") orelse "";
    const kind = classify(content_type) orelse {
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
        .max_message_size = default_max_message_size,
        .protocol = kind.protocol,
        .codec = kind.codec,
    };
    res.status = .ok;
    try res.header("content-type", kind.response_type);

    switch (call.protocol) {
        .grpc, .grpc_web, .grpc_web_text, .connect_stream => {
            const prefix = if (call.protocol == .connect_stream) "connect-" else "grpc-";
            var name_buf: [32]u8 = undefined;
            if (req.headers.get(concat(&name_buf, prefix, "content-encoding", "encoding"))) |enc| {
                call.request_compression = Compression.parse(enc) orelse {
                    try res.header(concat(&name_buf, prefix, "accept-encoding", "accept-encoding"), acceptEncoding());
                    return finish(&call, call.fail(.unimplemented, "unsupported message encoding"));
                };
                if (call.request_compression == .gzip and !features.compression)
                    return finish(&call, call.fail(.unimplemented, "gzip is not built in"));
            }
            if (features.compression) if (req.headers.get(concat(&name_buf, prefix, "accept-encoding", "accept-encoding"))) |accepted| {
                if (std.mem.indexOf(u8, accepted, "gzip") != null) call.response_compression = .gzip;
            };
            if (call.response_compression == .gzip) try res.header(if (call.protocol == .connect_stream) "connect-content-encoding" else "grpc-encoding", "gzip");
            try res.header(if (call.protocol == .connect_stream) "connect-accept-encoding" else "grpc-accept-encoding", acceptEncoding());
        },
        // HTTP's own Content-Encoding: dusty decodes the request body and
        // compresses the response (JSON; protobuf is not on its list).
        .connect => res.compress = true,
    }

    var timeout_ns: ?u64 = null;
    if (call.protocol == .connect or call.protocol == .connect_stream) {
        if (req.headers.get("connect-timeout-ms")) |value| {
            const ms = std.fmt.parseInt(u64, value, 10) catch
                return finish(&call, call.fail(.invalid_argument, "malformed connect-timeout-ms"));
            timeout_ns = ms *| std.time.ns_per_ms;
        }
    } else if (req.headers.get("grpc-timeout")) |value| {
        timeout_ns = deadline.parseTimeout(value) catch
            return finish(&call, call.fail(.internal, "malformed grpc-timeout"));
    }
    if (timeout_ns) |ns| {
        const d = std.Io.Clock.Timestamp.now(req.io, .awake).addDuration(.{ .raw = .fromNanoseconds(@intCast(@min(ns, std.math.maxInt(i64)))), .clock = .awake });
        call.deadline = d;
        req.setTimeout(.{ .deadline = d });
    } else {
        // A call can outlive the server's request timeout; only the
        // client's own deadline bounds it.
        req.setTimeout(.none);
    }

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
        error.DecodeFailed, error.TruncatedFrame, error.InvalidCompressedFlag, error.CompressionMismatch, error.MalformedCompressedMessage => {
            call.status = .internal;
            call.status_message = @errorName(err);
        },
        error.ExpectedUnaryMessage => {
            call.status = .unimplemented;
            call.status_message = "more than one request message for a unary method";
        },
        // The peer is gone: nothing can be told.
        error.ConnectionResetByPeer, error.BrokenPipe => return,
        else => {
            call.status = .unknown;
            call.status_message = @errorName(err);
        },
    }
    switch (call.protocol) {
        .grpc => {
            var code_buf: [4]u8 = undefined;
            const code_text = std.fmt.bufPrint(&code_buf, "{d}", .{@backingInt(call.status)}) catch unreachable;
            try call.res.trailer("grpc-status", code_text);
            if (call.status_message.len > 0) try call.res.trailer("grpc-message", try percentEncode(call.arena, call.status_message));
            for (call.trailers.items) |t| try call.res.trailer(t.key, t.value);
            if (call.out) |*o| {
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
            for (call.trailers.items) |t| try block.print(call.arena, "{s}:{s}\r\n", .{ t.key, t.value });
            try writeFrame(call, 0x80, block.items);
            if (call.out) |*o| o.end() catch {};
        },
        .connect_stream => {
            var json: std.ArrayList(u8) = .empty;
            try json.appendSlice(call.arena, "{");
            if (call.status != .ok) {
                try json.print(call.arena, "\"error\":{{\"code\":\"{s}\",\"message\":{f}}}", .{ connectCode(call.status), std.json.fmt(call.status_message, .{}) });
            }
            if (call.trailers.items.len > 0) {
                if (call.status != .ok) try json.appendSlice(call.arena, ",");
                try json.appendSlice(call.arena, "\"metadata\":{");
                for (call.trailers.items, 0..) |t, i| {
                    if (i > 0) try json.appendSlice(call.arena, ",");
                    try json.print(call.arena, "{f}:[{f}]", .{ std.json.fmt(t.key, .{}), std.json.fmt(t.value, .{}) });
                }
                try json.appendSlice(call.arena, "}");
            }
            try json.appendSlice(call.arena, "}");
            // End-of-stream message: flag 0x02, never compressed.
            try writeFrame(call, 0x02, json.items);
            if (call.out) |*o| o.end() catch {};
        },
        .connect => {
            for (call.trailers.items) |t| {
                try call.res.header(try std.fmt.allocPrint(call.arena, "trailer-{s}", .{t.key}), t.value);
            }
            if (call.status == .ok) {
                call.res.body = call.unary_response orelse "";
            } else {
                call.res.status = connectHttpStatus(call.status);
                call.res.headers.put("content-type", "application/json") catch {};
                call.res.body = try std.fmt.allocPrint(call.arena, "{{\"code\":\"{s}\",\"message\":{f}}}", .{ connectCode(call.status), std.json.fmt(call.status_message, .{}) });
            }
        },
    }
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

fn readRequest(comptime Req: type, call: *Call, body: *dusty.RequestBodyReader) !?Req {
    const payload = switch (call.protocol) {
        .connect => blk: {
            // The whole body is the one message.
            if (call.unary_read) return null;
            call.unary_read = true;
            break :blk body.interface.allocRemaining(call.arena, .limited(call.max_message_size + 1)) catch |err| switch (err) {
                error.StreamTooLong => return error.MessageTooLarge,
                else => |e| return e,
            };
        },
        .grpc_web_text => blk: {
            if (call.text_input == null) {
                const text = body.interface.allocRemaining(call.arena, .limited(call.max_message_size *| 2 +| 4096)) catch |err| switch (err) {
                    error.StreamTooLong => return error.MessageTooLarge,
                    else => |e| return e,
                };
                call.text_input = .fixed(try decodeBase64Chunks(call.arena, text));
            }
            const msg = (try frame.readMessage(&call.text_input.?, call.arena, call.max_message_size, call.request_compression)) orelse return null;
            break :blk msg.payload;
        },
        else => blk: {
            const msg = (try frame.readMessage(&body.interface, call.arena, call.max_message_size, call.request_compression)) orelse return null;
            break :blk msg.payload;
        },
    };
    if (payload.len > call.max_message_size) return error.MessageTooLarge;
    switch (call.codec) {
        .proto => {
            var reader: std.Io.Reader = .fixed(payload);
            return Req.decode(&reader, call.arena) catch error.DecodeFailed;
        },
        .json => {
            const parsed = Req.jsonDecode(payload, .{ .ignore_unknown_fields = true }, call.arena) catch return error.DecodeFailed;
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

fn encodeMessage(comptime Msg: type, call: *Call, message: Msg) ![]const u8 {
    switch (call.codec) {
        .proto => {
            var encoded: std.Io.Writer.Allocating = .init(call.arena);
            try message.encode(&encoded.writer, call.arena);
            return encoded.written();
        },
        .json => return message.jsonEncode(.{}, .{}, call.arena),
    }
}

fn writeResponse(comptime Resp: type, call: *Call, message: Resp) !void {
    const payload = try encodeMessage(Resp, call, message);
    if (call.protocol == .connect) {
        call.unary_response = payload;
        return;
    }
    const framed = try frame.encodeWithCompression(call.arena, payload, call.response_compression);
    try writeBytes(call, framed);
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
    const data = if (call.protocol == .grpc_web_text) blk: {
        const enc = try call.arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        break :blk std.base64.standard.Encoder.encode(enc, bytes);
    } else bytes;
    try call.write_mutex.lock(call.io);
    defer call.write_mutex.unlock(call.io);
    if (call.out == null) call.out = try call.res.stream(&call.out_buf);
    const out = &call.out.?;
    out.interface.writeAll(data) catch return out.err orelse error.WriteFailed;
    out.interface.flush() catch return out.err orelse error.WriteFailed;
}

fn runUnary(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    const request = (try readRequest(M.Request, call, body)) orelse
        return call.fail(.unimplemented, "a unary call needs one request message");
    if (try readRequest(M.Request, call, body) != null) return error.ExpectedUnaryMessage;
    const response = try handler(call, request);
    try writeResponse(M.Response, call, response);
}

const queue_len = 16;

fn runServerStreaming(comptime M: type, comptime handler: anytype, call: *Call, body: *dusty.RequestBodyReader) !void {
    const request = (try readRequest(M.Request, call, body)) orelse
        return call.fail(.unimplemented, "a server-streaming call needs one request message");
    if (try readRequest(M.Request, call, body) != null) return error.ExpectedUnaryMessage;
    var buf: [queue_len]M.Response = undefined;
    var responses: std.Io.Queue(M.Response) = .init(&buf);
    var group: std.Io.Group = .init;
    defer group.cancel(call.io);
    var handler_result: anyerror!void = {};
    try group.concurrent(call.io, Tasks(M, handler).serverStreaming, .{ call, request, &responses, &handler_result });
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
                const message = readRequest(M.Request, call, body) catch |err| {
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
    try group.concurrent(call.io, Tasks(M, handler).readRequests, .{ call, body, &requests, &reader_result });
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
    try group.concurrent(call.io, Tasks(M, handler).readRequests, .{ call, body, &requests, &reader_result });
    try group.concurrent(call.io, Tasks(M, handler).bidi, .{ call, &requests, &responses, &handler_result });
    try pumpResponses(M.Response, call, &responses);
    try group.await(call.io);
    try reader_result;
    return handler_result;
}

test "percentEncode leaves printable ASCII and escapes the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("not found: %25x%0A%C3%A9", try percentEncode(arena.allocator(), "not found: %x\né"));
}
