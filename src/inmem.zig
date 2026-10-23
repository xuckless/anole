//! A request and its response built over a body slice and a sink, for an
//! engine with no connection: `anole.testing`, and the Lambda adapter. The
//! shape is the HTTP/2 engine's stream setup (src/http/core/server/h2.zig),
//! without the stream.

const std = @import("std");
const dusty = @import("dusty");

/// A request header field.
pub const Field = struct { name: []const u8, value: []const u8 };

/// What a failed read of the body source was: never anything here.
fn bodyError(_: *std.Io.Reader) @typeInfo(@typeInfo(@FieldType(dusty.BodySource, "err")).pointer.child).@"fn".return_type.? {
    return null;
}

pub fn Exchange(comptime Ctx: type) type {
    return struct {
        request: dusty.Request,
        response: dusty.Response,
        body_reader: std.Io.Reader,

        const Self = @This();

        pub const Spec = struct {
            method: dusty.Method,
            /// Starts with "/".
            target: []const u8,
            headers: []const Field = &.{},
            body: []const u8 = "",
            client: ?std.Io.net.IpAddress = null,
            secure: bool = false,
            listener: *const dusty.Listener,
            version: struct { u8, u8 } = .{ 1, 1 },
            id: []const u8 = "",
        };

        pub const Ready = enum { ready, answered };

        /// The request over a fixed reader and the response over `sink`
        /// (`configureResponse`; `res.head` for HEAD), the headers (Host
        /// added when absent; Content-Length when a body is given and none
        /// is), the entity headers and the 413 check. `.answered` when it
        /// already wrote an error (413, 431) to the sink. `self` must not
        /// move afterwards.
        pub fn init(self: *Self, core: *dusty.Server(Ctx), arena: std.mem.Allocator, sink: dusty.Sink, spec: Spec) !Ready {
            const io = core.io;
            self.body_reader = .fixed(spec.body);
            self.request = .{
                .arena = arena,
                .io = io,
                ._parser = undefined,
                ._transport = undefined,
                ._config = core.config.request,
                .listener = spec.listener,
                .secure = spec.secure,
                .version_major = spec.version[0],
                .version_minor = spec.version[1],
                .drain = &core.draining,
                ._drain_hooks = &core.drain_hooks,
            };
            const req = &self.request;
            req._body_source = .{ .reader = &self.body_reader, .err = bodyError };
            req.method = spec.method;
            req.url = spec.target;
            req.id = spec.id;
            if (spec.client) |c| req.remote_address = c;

            self.response = try dusty.Response._initSink(arena, io, sink, core.config.response.max_header_count);
            const res = &self.response;
            core.configureResponse(res);
            // Deterministic: no Date header.
            res._send_date = false;
            res._request = req;
            req._response = res;
            res.head = spec.method == .head;

            req.headers = try dusty.Headers.init(arena, core.config.request.max_header_count);
            var too_many = false;
            var has_host = false;
            var has_length = false;
            for (spec.headers) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, "host")) has_host = true;
                if (std.ascii.eqlIgnoreCase(f.name, "content-length") or std.ascii.eqlIgnoreCase(f.name, "transfer-encoding")) has_length = true;
                req.headers.addRequestField(arena, f.name, f.value) catch |err| switch (err) {
                    error.TooManyHeaders => {
                        too_many = true;
                        break;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            if (!too_many and !has_host) req.headers.add("Host", "localhost") catch {
                too_many = true;
            };
            if (!too_many and spec.body.len > 0 and !has_length) {
                const text = try std.fmt.allocPrint(arena, "{d}", .{spec.body.len});
                req.headers.add("Content-Length", text) catch {
                    too_many = true;
                };
            }
            if (too_many) {
                res.status = .request_header_fields_too_large;
                try res.write();
                return .answered;
            }
            req._applyEntityHeaders();
            if (core.config.request.max_content_length) |max| {
                if (req.content_length) |len| if (len > max) {
                    res.status = .payload_too_large;
                    res.content_type = .text;
                    res.body = "413 Content Too Large\n";
                    try res.write();
                    return .answered;
                };
            }
            if (spec.client != null) core.applyForwardedFrom(req, req.remote_address);
            return .ready;
        }
    };
}
