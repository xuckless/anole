// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The HTTP core (adapted from lalinsky/dusty): server, HTTP/2 engine,
//! router, middleware, static files and client. Applications reach it as
//! `anole.http`, and through `anole.Server`.

const std = @import("std");

pub const Server = @import("server.zig").Server;
/// What takes an HTTP/1.1 connection over after an upgrade, served in
/// bursts with the connection parked in between (`Response.adopt`).
pub const Adopter = @import("server.zig").Adopter;
/// One run of an `Adopter`: what it waits for input with, and how it ends.
pub const Burst = @import("server.zig").Burst;
pub const Address = @import("config.zig").Address;
pub const Listener = @import("config.zig").Listener;
pub const ServerConfig = @import("config.zig").ServerConfig;
pub const Cert = @import("tls_options.zig").Cert;
pub const Ca = @import("tls_options.zig").Ca;
pub const ClientAuth = @import("tls_options.zig").ClientAuth;
/// A peer range for `Listener.proxy_protocol_from`.
pub const ProxyNetwork = @import("proxy_protocol.zig").Network;
pub const proxy_networks = @import("proxy_protocol.zig").networks;
pub const isPublicAddress = @import("proxy_protocol.zig").isPublic;
pub const Router = @import("router.zig").Router;
pub const Action = @import("router.zig").Action;
pub const RouteInfo = @import("router.zig").RouteInfo;
pub const RouteOptions = @import("router.zig").RouteOptions;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
/// Where a response goes when a protocol engine (HTTP/2) frames it; see `Response.initSink`.
pub const Sink = @import("sink.zig").Sink;
/// A response finished after its handler returned, with no task waiting
/// (`Response.detach`): HTTP/2 and HTTP/3 requests that ran on the reader.
pub const Detached = @import("detach.zig").Detached;
/// Task placement on zio's executors, for protocol engines outside the
/// core (HTTP/3) that keep a connection's tasks on one executor.
pub const placement = @import("placement.zig");
/// Live connection and stream counts per executor.
pub const gauges = @import("gauges.zig");

/// Tests that provoke `err` logs on purpose declare it here.
pub const expect_log = @import("expect_log.zig");
pub const DrainHooks = @import("drain_hooks.zig").DrainHooks;
/// One time budget shared by several blocking calls (a request, then the
/// reads of its body), as the client's `timeout` is; for protocol clients
/// outside the core (HTTP/2, HTTP/3).
pub const Deadline = @import("deadline.zig").Deadline;
/// A request body delivered unframed by a protocol engine; see `Request.body_source`.
pub const BodySource = @import("request.zig").BodySource;
pub const BodyWriter = @import("response.zig").BodyWriter;
pub const StreamingBodyWriter = @import("response.zig").StreamingBodyWriter;
/// What `Request.reader` returns.
pub const RequestBodyReader = @import("parser.zig").RequestBodyReader;
pub const EventStream = @import("response.zig").EventStream;
pub const EventWriter = @import("response.zig").EventWriter;
pub const WebSocket = @import("websocket.zig").WebSocket;
/// Whether an HTTP/1.1 request is a valid WebSocket handshake.
pub const isWebSocketHandshake = @import("websocket.zig").isHandshake;
/// How a WebSocket sends once per read (`WebSocket`); for layers that
/// frame WebSocket messages themselves.
pub const WebSocketBatch = @import("websocket.zig").Batch;
pub const Method = @import("http.zig").Method;
pub const Status = @import("http.zig").Status;
pub const Headers = @import("http.zig").Headers;
pub const Params = @import("http.zig").Params;
pub const ContentType = @import("http.zig").ContentType;
pub const MisuseError = @import("http.zig").MisuseError;
pub const Violation = @import("http.zig").Violation;
pub const Violations = @import("http.zig").Violations;
pub const Problem = @import("http.zig").Problem;
pub const bindJson = @import("bind.zig").bindJson;
pub const BindOptions = @import("bind.zig").BindOptions;
pub const BindResult = @import("bind.zig").BindResult;
pub const UnknownFields = @import("bind.zig").UnknownFields;
pub const route_pattern = @import("route_pattern.zig");
/// The request mappers behind `req.bind*`, for tools that check types at compile time.
pub const input = struct {
    pub const strings = @import("bind_strings.zig");
    pub const json = @import("bind.zig");
};
pub const ContentEncoding = @import("http.zig").ContentEncoding;
pub const Cookie = @import("cookie.zig").Cookie;
pub const CookieOpts = @import("cookie.zig").CookieOpts;
pub const SessionCookieOpts = @import("cookie.zig").SessionCookieOpts;
pub const validateCookieName = @import("cookie.zig").validateCookieName;
pub const validateCookieValue = @import("cookie.zig").validateCookieValue;
/// Whether a header name or value may go on the wire (the C ABI checks
/// replies with them before they reach a `Response`).
pub const validateHeaderName = @import("http.zig").validateHeaderName;
pub const validateHeaderValue = @import("http.zig").validateHeaderValue;
/// Response header names only the server writes (`Connection`,
/// `Transfer-Encoding`), which `Response.header` refuses.
pub const isReservedHeader = @import("response.zig").isReservedHeader;
pub const SessionData = @import("middleware/Session.zig").SessionData;
/// `Request.locals`: per-request values a middleware hands to the handler.
pub const Locals = @import("locals.zig").Locals;
/// How the server writes its own error answers (`ServerConfig.errors`).
pub const ErrorFormat = @import("config.zig").ErrorFormat;
/// `ServerConfig.error_handler`.
pub const ErrorHandler = @import("config.zig").ErrorHandler;
pub const middleware = @import("middleware/middleware.zig");
pub const Middleware = @import("middleware.zig").Middleware;
pub const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;
pub const Chain = @import("middleware.zig").Chain;
/// The status a handler error stands for (status-named errors such as
/// `error.Unauthorized`, request-body faults), or null for a 500: for
/// middleware that records the status it will send.
pub const errorStatus = @import("middleware.zig").errorStatus;
/// `errorStatus` by error name, at compile time.
pub const comptimeErrorStatus = @import("middleware.zig").comptimeErrorStatus;
/// `errorStatus` with the default answer's text body.
pub const clientError = @import("middleware.zig").clientError;
/// The answer the server gives an error when nothing else does, for an
/// `uncaughtError` or `error_handler` to fall back on.
pub const defaultError = @import("middleware.zig").defaultError;
/// "404 Not Found\n" for a standard 4xx or 5xx status.
pub const statusBody = @import("middleware.zig").statusBody;
/// Fails when another socket already listens on the address, which
/// SO_REUSEPORT would silently share.
pub const checkAddressFree = @import("server.zig").checkAddressFree;
/// A listening TCP socket, with IPV6_V6ONLY as asked (dual-stack `::`).
pub const listenIp = @import("server.zig").listenIp;
/// `listenIp`'s options.
pub const ListenIpOptions = @import("server.zig").ListenIpOptions;
/// An IPv4-mapped IPv6 address as the IPv4 address it stands for.
pub const unmapIpv4 = @import("server.zig").unmapIpv4;
/// What the startup line says about a listener: "https://127.0.0.1:8443
/// (HTTP/2, HTTP/1.1)".
pub const describeListener = @import("server.zig").describeListener;
/// The open-file limit, and the connection cap worked out from it.
pub const fd_limit = @import("fd_limit.zig");
pub const StaticOptions = @import("server/static.zig").StaticOptions;
pub const Precompressed = @import("server/static.zig").Precompressed;
pub const EmbeddedOptions = @import("server/static.zig").EmbeddedOptions;

// Client
pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").ClientOptions;
pub const TlsOptions = @import("client.zig").TlsOptions;
pub const ClientResponse = @import("client.zig").ClientResponse;
pub const FetchOptions = @import("client.zig").FetchOptions;
pub const WebSocketClient = @import("client.zig").WebSocketClient;
pub const WebSocketUpgradeOptions = @import("client.zig").WebSocketUpgradeOptions;
pub const Redirect = @import("client.zig").Redirect;
pub const RedirectAction = @import("client.zig").RedirectAction;
pub const RedirectPolicy = @import("client.zig").RedirectPolicy;
pub const isPrivateAddress = @import("client.zig").isPrivateAddress;

test {
    std.testing.refAllDecls(@This());
}

// Import tests
comptime {
    _ = @import("server_test.zig");
    _ = @import("server/request_buffers.zig");
    _ = @import("drain_hooks.zig");
    _ = @import("websocket.zig");
    _ = @import("client.zig");
    _ = @import("client_test.zig");
    _ = @import("client_redirect_test.zig");
    _ = @import("deadline.zig");
    _ = @import("cgroup.zig");
    _ = @import("somaxconn.zig");
    _ = @import("fd_limit.zig");
    _ = @import("config.zig");
    _ = @import("middleware.zig");
    _ = @import("middleware/middleware.zig");
    _ = @import("locals.zig");
    _ = @import("placement.zig");
    _ = @import("api_test.zig");
    _ = @import("proxy_protocol.zig");
    _ = @import("fuzz.zig");
    _ = @import("request_fuzz_test.zig");
    _ = @import("server/static.zig");
    _ = @import("server/static_test.zig");
    if (@import("build_options").use_http2) _ = @import("server/h2_test.zig");
    if (@import("build_options").use_brotli) _ = @import("brotli_io.zig");
    _ = @import("block_cache.zig");
    _ = @import("bind.zig");
    _ = @import("bind_strings.zig");
    _ = @import("bind_violations.zig");
    _ = @import("json_out.zig");
    _ = @import("route_pattern.zig");
}
