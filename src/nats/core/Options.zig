// Adapted from vkiryakov/zefir src/nats/Options.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Client options. Only `servers` has no default:
//!
//! ```zig
//! const options: nats.Options = .{
//!     .servers = &.{ "nats://10.0.0.1:4222", "nats://10.0.0.2:4222" },
//!     .name = "orders-service",
//!     .auth = .{ .user_password = .{ .username = "orders", .password = password } },
//! };
//! ```
//!
//! The client checks the options before it connects and keeps its own copy,
//! so the strings may be freed once the client is created.

const std = @import("std");
const Duration = std.Io.Duration;
const ServerAddress = @import("ServerAddress.zig");
const ClientStream = @import("../../net/client_stream.zig").ClientStream;
const ConnectOptions = @import("../../net/client_stream.zig").ConnectOptions;
const nkeys = @import("../nkeys.zig");
const encoder = @import("protocol/encoder.zig");
const Options = @This();

/// `nats://host:port`, `host:port` or `[::1]:4222`; the port defaults to
/// 4222. Several servers are alternatives for failover, not a pool: the
/// client keeps one connection.
servers: []const []const u8,
/// The connection name the server shows in its monitoring.
name: ?[]const u8 = null,
/// The credentials sent in CONNECT.
auth: Auth = .none,
/// One attempt on one server: DNS, TCP and the INFO, CONNECT, PONG exchange.
/// On `std.Io.Threaded` under macOS, and Linux with glibc, DNS is a
/// blocking `getaddrinfo` that cancellation may not stop: then an attempt,
/// and a `close()` during it, can take as long as the resolver.
connect_timeout: Duration = .fromSeconds(5),
/// How often the client PINGs the server to check that the connection is
/// alive.
ping_interval: Duration = .fromSeconds(30),
/// PINGs the server got and left unanswered before the connection counts
/// as dead. A PING still waiting behind what a slow link has not sent yet
/// does not count; a server that takes nothing at all for this many
/// intervals while frames wait counts as dead too.
max_outstanding_pings: u8 = 2,
/// Do not deliver this client's own messages to its subscriptions.
no_echo: bool = false,
/// A request that reaches no subscriber fails at once with NoResponders.
no_responders: bool = true,
/// The server confirms every operation with +OK; for debugging only.
verbose: bool = false,
/// The server checks subjects more strictly.
pedantic: bool = false,
/// Try the servers in random order, so that clients spread over a cluster;
/// the servers the cluster announces join in random places too.
randomize_servers: bool = true,
/// Use only `servers`, not the servers the cluster announces in INFO.
ignore_discovered_servers: bool = false,
/// `connect()` returns at once and keeps trying in the background.
retry_initial_connect: bool = false,
/// What happens after the connection is lost.
reconnect: ReconnectOptions = .{},
/// Bounds on what the client holds in memory.
limits: Limits = .{},
/// TLS (`tls://` addresses, a server that requires it, or `required`);
/// null: plain only. Held by reference: it must outlive the client.
tls: ?*const Tls = null,

pub const Auth = union(enum) {
    none,
    /// Sent in plaintext: use it only on a trusted network.
    user_password: UserPassword,
    /// An authentication token.
    token: []const u8,
    /// An NKey seed ("SU..."): the server's nonce is signed with it.
    nkey: NKey,
    /// A user JWT and its NKey seed (a `.creds` file's two parts).
    creds: Creds,

    pub const NKey = struct { seed: []const u8 };
    pub const Creds = struct { jwt: []const u8, seed: []const u8 };

    pub const UserPassword = struct {
        username: []const u8,
        password: []const u8,
    };
};

/// How TLS is set up; `settings` is `ClientStream`'s (CAs, client
/// certificate, verification).
pub const Tls = struct {
    settings: ConnectOptions.Tls = .{},
    /// TLS before the server's INFO (nats-server `handshake_first`).
    first: bool = false,
    /// TLS even for `nats://` addresses.
    required: bool = false,
};

pub const ReconnectOptions = struct {
    /// Reconnect after the connection is lost; when false, the client closes.
    enabled: bool = true,
    /// Attempts in a row that fail to connect before the client gives up;
    /// any connection made starts the count over. Null: never.
    max_attempts: ?u32 = null,
    /// The first attempt is immediate after a connection that lasted at
    /// least `max_delay`; then the delay doubles from `min_delay` up to
    /// `max_delay`, which is the longest. A shorter connection counts as a
    /// failed attempt for the delays, though not for `max_attempts`, so a
    /// server that drops every connection at once is not hammered. Leaving
    /// a server in lame duck mode is immediate once the connection lasted
    /// `min_delay`.
    min_delay: Duration = .fromMilliseconds(500),
    max_delay: Duration = .fromSeconds(10),
    /// Every delay is cut by a random part of up to a fifth, so that
    /// clients do not reconnect in step.
    jitter: bool = true,
    /// Publishes and requests kept while reconnecting and sent once
    /// connected, after the subscriptions are restored; a frame record of a
    /// few bytes each counts too. One that does not fit fails at once with
    /// BufferFull; with 0 they fail at once with Disconnected. Nothing is
    /// ever sent twice.
    buffer_bytes: usize = 8 * 1024 * 1024,
    /// Stop after a server rejects the credentials twice the same way in a
    /// row. A refusal on a live connection, as when the password changes on
    /// the server, counts as the first: with one server the client stops at
    /// the first refused reconnect, as nats.go does.
    abort_on_auth_error: bool = true,
};

pub const Limits = struct {
    /// Frames waiting to be written: publish waits while the queue holds
    /// this many bytes or more, then queues its frame whole.
    outbound_bytes: usize = 8 * 1024 * 1024,
    /// Messages a subscription holds before its overflow policy drops some.
    subscription_messages: u32 = 1024,
    /// Bytes a subscription holds before its overflow policy drops messages;
    /// a message larger than this on its own is dropped as it comes.
    subscription_bytes: usize = 8 * 1024 * 1024,
    /// Requests waiting for a reply at once; more fail with
    /// TooManyPendingRequests. A stream of requestMany counts until its
    /// last response came, or until its owner's `next()` returned null or
    /// an error after the deadline, or its `deinit()`.
    max_pending_requests: u32 = 65_536,
    /// Subscriptions at once, each until its `deinit()`; more fail with
    /// TooManySubscriptions.
    max_subscriptions: u32 = 65_536,
    /// The server's `max_control_line`: the longest arguments of a protocol
    /// line this client sends, such as a subject with its reply-to. Raise
    /// it together with the server's setting. It must hold this client's
    /// CONNECT, which the server checks against the same limit. Lines from
    /// the server may be longer: the client reads any line up to 64 KiB, or
    /// up to four times this limit when that is more, since a -ERR quotes a
    /// refused subject with every byte that does not print escaped.
    max_control_line_bytes: u32 = 4096,
    /// The largest message accepted, headers included; larger ones are
    /// read past, dropped and counted. A larger reply to a request is
    /// dropped too, and the request ends with Timeout.
    max_inbound_frame_bytes: u32 = 64 * 1024 * 1024,
    /// The largest header block accepted; messages with a larger one are
    /// read past, dropped and counted, replies to requests too.
    max_header_bytes: u32 = 64 * 1024,
    /// Events kept for `nextEvent()`; more are dropped and counted.
    max_event_queue: u32 = 1024,
};

pub const Error = error{InvalidOptions};

/// The longest CONNECT JSON a server accepts by default (its `max_control_line`).
pub const max_connect_json = 4096;
/// Servers given and discovered, together.
pub const max_servers = 64;
/// The largest `limits.max_control_line_bytes`. The read buffer holds the
/// longest line the server may send: 64 KiB, or four times the limit when
/// that is more.
pub const max_control_line_limit = 64 * 1024;

/// Checks every option; nothing touches the network.
pub fn validate(options: Options) Error!void {
    if (options.servers.len == 0 or options.servers.len > max_servers) return error.InvalidOptions;
    for (options.servers) |url| {
        _ = ServerAddress.parse(url) catch return error.InvalidOptions;
    }
    if (options.name) |name| {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidOptions;
    }
    switch (options.auth) {
        .none => {},
        .user_password => |credentials| {
            for ([_][]const u8{ credentials.username, credentials.password }) |text| {
                if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidOptions;
            }
        },
        .token => |t| if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return error.InvalidOptions,
        .nkey => |k| _ = nkeys.decodeSeed(k.seed) catch return error.InvalidOptions,
        .creds => |c| {
            if (c.jwt.len == 0 or !std.unicode.utf8ValidateSlice(c.jwt)) return error.InvalidOptions;
            _ = nkeys.decodeSeed(c.seed) catch return error.InvalidOptions;
        },
    }
    if (options.connect_timeout.nanoseconds <= 0 or options.ping_interval.nanoseconds <= 0) return error.InvalidOptions;
    if (options.max_outstanding_pings == 0) return error.InvalidOptions;

    const reconnect = options.reconnect;
    if (reconnect.min_delay.nanoseconds <= 0) return error.InvalidOptions;
    if (reconnect.max_delay.nanoseconds < reconnect.min_delay.nanoseconds) return error.InvalidOptions;
    if (reconnect.max_attempts == 0) return error.InvalidOptions;
    if (options.retry_initial_connect and !reconnect.enabled) return error.InvalidOptions;

    const limits = options.limits;
    if (limits.outbound_bytes == 0 or limits.subscription_messages == 0 or limits.subscription_bytes == 0 or
        limits.max_pending_requests == 0 or limits.max_subscriptions == 0 or limits.max_inbound_frame_bytes == 0 or
        limits.max_header_bytes == 0 or limits.max_event_queue == 0) return error.InvalidOptions;
    if (limits.max_control_line_bytes == 0 or limits.max_control_line_bytes > max_control_line_limit) return error.InvalidOptions;
    if (limits.max_header_bytes > limits.max_inbound_frame_bytes) return error.InvalidOptions;

    // The server checks CONNECT against its control line limit too.
    const connect_len = longestConnectJson(options);
    if (connect_len > max_connect_json or connect_len > limits.max_control_line_bytes) return error.InvalidOptions;
}

const nkey_placeholder: [56]u8 = @splat('U');
const sig_placeholder: [86]u8 = @splat('A');

/// The CONNECT JSON as long as it can get: as if the server supported headers.
fn longestConnectJson(options: Options) usize {
    return encoder.connectJsonLen(.{
        .verbose = options.verbose,
        .pedantic = options.pedantic,
        .echo = !options.no_echo,
        .headers = true,
        .no_responders = options.no_responders,
        .name = options.name,
        .user = switch (options.auth) {
            .user_password => |credentials| credentials.username,
            else => null,
        },
        .pass = switch (options.auth) {
            .user_password => |credentials| credentials.password,
            else => null,
        },
        .auth_token = switch (options.auth) {
            .token => |t| t,
            else => null,
        },
        .jwt = switch (options.auth) {
            .creds => |c| c.jwt,
            else => null,
        },
        .nkey = switch (options.auth) {
            .nkey, .creds => &nkey_placeholder,
            else => null,
        },
        .sig = switch (options.auth) {
            .nkey, .creds => &sig_placeholder,
            else => null,
        },
    });
}

const testing = std.testing;
const one_server: []const []const u8 = &.{"nats://127.0.0.1:4222"};

fn expectInvalid(options: Options) !void {
    try testing.expectError(error.InvalidOptions, validate(options));
}

test "defaults are valid and match the spec" {
    const options: Options = .{ .servers = one_server };
    try validate(options);
    try testing.expectEqual(5, options.connect_timeout.toSeconds());
    try testing.expectEqual(30, options.ping_interval.toSeconds());
    try testing.expectEqual(500, options.reconnect.min_delay.toMilliseconds());
    try testing.expectEqual(8 * 1024 * 1024, options.reconnect.buffer_bytes);
    try testing.expectEqual(4096, options.limits.max_control_line_bytes);
}

test "servers: at least one, at most 64, every one parses" {
    try expectInvalid(.{ .servers = &.{} });
    try validate(.{ .servers = &.{ "nats://a:4222", "tls://b:4222" } });
    try expectInvalid(.{ .servers = &.{ "nats://a:4222", "ws://b:4222" } });
    const many: [max_servers + 1][]const u8 = @splat("a:4222");
    try validate(.{ .servers = many[0..max_servers] });
    try expectInvalid(.{ .servers = &many });
}

test "name and credentials" {
    try expectInvalid(.{ .servers = one_server, .name = "" });
    try expectInvalid(.{ .servers = one_server, .name = "bad\xff" });
    try validate(.{ .servers = one_server, .name = "сервис" });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "", .password = "p" } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "" } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "\xc3" } } });
    try validate(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = "p\"w\\d" } } });
}

test "durations and reconnect" {
    try expectInvalid(.{ .servers = one_server, .connect_timeout = .zero });
    try expectInvalid(.{ .servers = one_server, .ping_interval = .fromSeconds(-1) });
    try expectInvalid(.{ .servers = one_server, .max_outstanding_pings = 0 });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .min_delay = .zero } });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .min_delay = .fromSeconds(2), .max_delay = .fromSeconds(1) } });
    try expectInvalid(.{ .servers = one_server, .reconnect = .{ .max_attempts = 0 } });
    try expectInvalid(.{ .servers = one_server, .retry_initial_connect = true, .reconnect = .{ .enabled = false } });
    try validate(.{ .servers = one_server, .retry_initial_connect = true });
    try validate(.{ .servers = one_server, .reconnect = .{ .buffer_bytes = 0 } });
}

test "limits" {
    for ([_]Limits{
        .{ .outbound_bytes = 0 },                                  .{ .subscription_messages = 0 },                                .{ .subscription_bytes = 0 },
        .{ .max_pending_requests = 0 },                            .{ .max_subscriptions = 0 },                                    .{ .max_inbound_frame_bytes = 0 },
        .{ .max_header_bytes = 0 },                                .{ .max_event_queue = 0 },                                      .{ .max_control_line_bytes = 0 },
        .{ .max_control_line_bytes = max_control_line_limit + 1 }, .{ .max_header_bytes = 1024, .max_inbound_frame_bytes = 1023 },
    }) |limits| {
        try expectInvalid(.{ .servers = one_server, .limits = limits });
    }
    try validate(.{ .servers = one_server, .limits = .{ .max_control_line_bytes = max_control_line_limit } });
}

test "CONNECT must fit in 4096 bytes after JSON escaping" {
    // The JSON with a one-letter name, minus that letter: what the name adds to.
    const base = encoder.connectJsonLen(.{ .headers = true, .no_responders = true, .name = "x" }) - 1;
    const names: [max_connect_json]u8 = @splat('x');
    try validate(.{ .servers = one_server, .name = names[0 .. max_connect_json - base] });
    try expectInvalid(.{ .servers = one_server, .name = names[0 .. max_connect_json - base + 1] });

    // An escaped quote takes two bytes in the JSON.
    const quotes: [2100]u8 = @splat('"');
    try validate(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = names[0..2100] } } });
    try expectInvalid(.{ .servers = one_server, .auth = .{ .user_password = .{ .username = "u", .password = &quotes } } });
}

test "the control line limit must hold this client's CONNECT" {
    // The server checks CONNECT against its max_control_line too.
    const connect_len = longestConnectJson(.{ .servers = one_server, .name = "orders" });
    const fits: u32 = @intCast(connect_len);
    try validate(.{ .servers = one_server, .name = "orders", .limits = .{ .max_control_line_bytes = fits } });
    try expectInvalid(.{ .servers = one_server, .name = "orders", .limits = .{ .max_control_line_bytes = fits - 1 } });
    try expectInvalid(.{ .servers = one_server, .limits = .{ .max_control_line_bytes = 1 } });
}
