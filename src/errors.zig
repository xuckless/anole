//! The errors `init`, `listen`, `listenTls`, `run`, `waitReady` and the
//! certificate reloads can end with: named sets you can switch on, and
//! stable names the C ABI reports.
const std = @import("std");

/// Every way `init`, `listen`, `listenTls`, `run` and `waitReady` fail.
/// The names are stable: the C ABI reports them as `anole_last_error_name`.
pub const ServerError = error{
    // The options
    InvalidListenAddress,
    ListenersAlreadySet,
    InvalidListenerName,
    DuplicateListenerName,
    InvalidProxyNetwork,
    InvalidEnvironmentVariable,
    InvalidEnvFile,
    ProxyProtocolNoPeers,
    // ---- p3/net ----
    NetNotBuilt,
    NetListenerNeedsPort,
    NetListenerHttp3,
    TcpAndUdp,
    UdpWithTls,
    UdpOnUnixSocket,
    UdpWithProxyProtocol,
    InvalidFraming,
    NetHandlerContext,
    // ---- end p3/net ----

    // ---- p3/lambda ----
    LambdaRuntimeApiMissing,
    LambdaNotBuilt,
    LambdaRuntimeApiFailed,
    SnapStartUnsupported,
    // ---- end p3/lambda ----

    // The OpenAPI document (`app.openapi`, `zig build openapi`)
    OpenApiNameClash,
    OpenApiOutOfDate,
    OpenApiNotBuilt,
    NoProtocols,
    SeveralHttp3Listeners,
    Http3NeedsTls,
    Http3NeedsHttps,
    TooManyListeners,
    RouteConflict,
    HqInteropNotAllowed,
    // Left out of this build
    TlsNotBuilt,
    Http2NotBuilt,
    Http3NotBuilt,
    // Binding
    AddressInUse,
    AddressNotAvailable,
    AccessDenied,
    InheritedSocketMismatch,
    // Certificates (also TlsLoadError)
    NoTlsListener,
    FileNotFound,
    InvalidCertificate,
    InvalidKey,
    KeyMismatch,
    // Connectors opened at start (`connect_at_start`)
    DatabaseUnavailable,
    // The process
    ServerAlreadyOnThread,
    SystemResources,
    OutOfMemory,
    Canceled,
    Unexpected,
};

/// `reloadCertificates` and `setCertificate`: a subset of `ServerError`.
pub const TlsLoadError = error{
    NoTlsListener,
    TlsNotBuilt,
    FileNotFound,
    AccessDenied,
    InvalidCertificate,
    InvalidKey,
    KeyMismatch,
    SystemResources,
    OutOfMemory,
    Canceled,
    Unexpected,
};

/// The names of `ServerError`'s members, for documentation and tests.
pub const server_error_names: []const []const u8 = blk: {
    const members = @typeInfo(ServerError).error_set.error_names.?;
    var names: [members.len][]const u8 = undefined;
    for (members, 0..) |m, i| names[i] = m;
    const final = names;
    break :blk &final;
};

/// Names other layers use for the same thing, and what they become.
const aliases = [_][2][]const u8{
    .{ "AddressUnavailable", "AddressNotAvailable" },
    .{ "PermissionDenied", "AccessDenied" },
    .{ "TlsInvalidCertificate", "InvalidCertificate" },
    .{ "TlsFailure", "InvalidCertificate" },
    .{ "TlsInvalidPrivateKey", "InvalidKey" },
    .{ "TlsKeyMismatch", "KeyMismatch" },
    .{ "ProcessFdQuotaExceeded", "SystemResources" },
    .{ "SystemFdQuotaExceeded", "SystemResources" },
    .{ "NoSpaceLeft", "SystemResources" },
    .{ "ConcurrencyUnavailable", "SystemResources" },
};

fn toSet(comptime Set: type, err: anyerror) Set {
    const name = @errorName(err);
    const members = @typeInfo(Set).error_set.error_names.?;
    inline for (members) |m| if (std.mem.eql(u8, name, m)) return @field(Set, m);
    inline for (aliases) |alias| if (std.mem.eql(u8, name, alias[0])) {
        inline for (members) |m| if (comptime std.mem.eql(u8, alias[1], m)) return @field(Set, m);
    };
    // (A test that maps an unknown name on purpose must not fail on the log.)
    if (!@import("builtin").is_test) std.log.scoped(.anole).err("unexpected error while starting: {s}", .{name});
    return error.Unexpected;
}

/// Maps what the layers below return onto `ServerError`, logging the
/// original name at `err` when it becomes `Unexpected`.
pub fn toServerError(err: anyerror) ServerError {
    return toSet(ServerError, err);
}

/// As `toServerError`, for the certificate reloads.
pub fn toTlsLoadError(err: anyerror) TlsLoadError {
    return toSet(TlsLoadError, err);
}

/// The OS errno a name stands for (POSIX values), for the C ABI's
/// `anole_last_errno`; 0 when it is not an OS error.
pub fn posixErrno(name: anyerror) i32 {
    const E = std.posix.E;
    const n = @errorName(name);
    const pairs = .{
        .{ "AddressInUse", E.ADDRINUSE },
        .{ "AddressNotAvailable", E.ADDRNOTAVAIL },
        .{ "AccessDenied", E.ACCES },
        .{ "FileNotFound", E.NOENT },
        .{ "OutOfMemory", E.NOMEM },
        .{ "SystemResources", E.MFILE },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, n, p[0])) return @backingInt(p[1]);
    return 0;
}

test "errors: TlsLoadError is a subset of ServerError" {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(TlsLoadError).error_set.error_names.?) |m| {
        comptime var found = false;
        inline for (@typeInfo(ServerError).error_set.error_names.?) |s| {
            if (comptime std.mem.eql(u8, m, s)) found = true;
        }
        if (!found) @compileError("TlsLoadError." ++ m ++ " is not in ServerError");
    }
}

test "errors: every member maps to itself; unknown names become Unexpected" {
    inline for (@typeInfo(ServerError).error_set.error_names.?) |m| {
        try std.testing.expectEqual(@field(ServerError, m), toServerError(@field(anyerror, m)));
    }
    try std.testing.expectEqual(error.AddressNotAvailable, toServerError(error.AddressUnavailable));
    try std.testing.expectEqual(error.KeyMismatch, toServerError(error.TlsKeyMismatch));
    try std.testing.expectEqual(error.Unexpected, toServerError(error.SomethingElseEntirely));
    try std.testing.expectEqual(error.InvalidKey, toTlsLoadError(error.TlsInvalidPrivateKey));
    try std.testing.expectEqual(error.Unexpected, toTlsLoadError(error.AddressInUse));
    try std.testing.expectEqual(@as(usize, @typeInfo(ServerError).error_set.error_names.?.len), server_error_names.len);
    try std.testing.expectEqual(@as(i32, @backingInt(std.posix.E.ADDRINUSE)), posixErrno(error.AddressInUse));
    try std.testing.expectEqual(@as(i32, 0), posixErrno(error.KeyMismatch));
}

// ------------------------------------------------------------------ readable startup errors

/// What a startup error is about, for `explain`. Nothing here is a secret:
/// no credential is ever put in a context (a connector's URL goes through
/// `redactUrl`).
pub const Context = struct {
    /// The listener the error is about: its name and address (as written)
    /// and port.
    listener: ?[]const u8 = null,
    address: ?[]const u8 = null,
    port: ?u16 = null,
    /// A file (a certificate, a key).
    path: ?[]const u8 = null,
    /// A connector ("postgres") and where it connects (a URL or host:port;
    /// a password in it is hidden).
    system: ?[]const u8 = null,
    host: ?[]const u8 = null,
    /// The cause the layer below reported (an OS error name, say).
    cause: ?[]const u8 = null,
    /// A message of the error's own, kept as is (a route conflict).
    detail: ?[]const u8 = null,
};

/// `url` with the password of `scheme://user:password@host` written as `***`.
pub fn redactUrl(url: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return w.writeAll(url);
    const rest = url[scheme_end + 3 ..];
    const at = std.mem.lastIndexOfScalar(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len], '@') orelse return w.writeAll(url);
    const userinfo = rest[0..at];
    const colon = std.mem.indexOfScalar(u8, userinfo, ':') orelse return w.writeAll(url);
    try w.writeAll(url[0 .. scheme_end + 3]);
    try w.writeAll(userinfo[0..colon]);
    try w.writeAll(":***");
    try w.writeAll(rest[at..]);
}

/// Writes `err` as two lines: "can't <what>: <cause>." and, indented, the
/// way out. Every member of `ServerError` has its text (the switch is
/// exhaustive). The same text goes to the log (`logExplained`) and to the C
/// ABI's `anole_last_error`.
pub fn explain(err: ServerError, ctx: Context, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const where = struct {
        fn listener(c: Context, wr: *std.Io.Writer) std.Io.Writer.Error!void {
            if (c.address) |a| {
                try wr.writeAll(a);
                if (c.port) |p| if (std.mem.indexOfScalar(u8, a, ':') == null or a[a.len - 1] == ']') try wr.print(":{d}", .{p});
            } else if (c.port) |p| {
                try wr.print("port {d}", .{p});
            } else if (c.listener) |n| {
                try wr.print("the listener \"{s}\"", .{n});
            } else {
                try wr.writeAll("the configured address");
            }
        }
        fn file(c: Context, wr: *std.Io.Writer, comptime fallback: []const u8) std.Io.Writer.Error!void {
            try wr.writeAll(c.path orelse fallback);
        }
    };
    const fix = struct {
        fn line(wr: *std.Io.Writer, comptime text: []const u8) std.Io.Writer.Error!void {
            try wr.writeAll("\n  " ++ text);
        }
    }.line;
    switch (err) {
        error.InvalidListenAddress => {
            try w.writeAll("can't listen on ");
            try where.listener(ctx, w);
            try w.writeAll(": that is not an address.");
            try fix(w, "Write it as \":3000\" (every interface), \"127.0.0.1:3000\" or \"[::1]:3000\".");
        },
        error.ListenersAlreadySet => {
            try w.writeAll("can't set up the listeners: they were already set up.");
            try fix(w, "Use init's options (http, https) or listen()/listenTls(), not both; serve the first with run().");
        },
        error.InvalidListenerName => {
            try w.writeAll("can't use that listener name: it is empty, longer than 255 bytes or has a ':'.");
            try fix(w, "Name the listener with 1 to 255 bytes and no ':' (LISTEN_FDNAMES separates names with it).");
        },
        error.DuplicateListenerName => {
            try w.writeAll("can't start with two listeners of the same name.");
            try fix(w, "Give each listener its own name; \"http\" and \"https\" are taken by the http and https options.");
        },
        error.InvalidProxyNetwork => {
            try w.writeAll("can't read a proxy network: an entry is not an address or a CIDR network.");
            try fix(w, "Write proxy.trusted entries as \"10.0.0.0/8\", \"203.0.113.7\" or one of loopback, private, link_local.");
        },
        error.InvalidEnvironmentVariable => {
            try w.writeAll("can't read the environment: a variable Anole reads has a value it cannot use");
            if (ctx.detail) |d| try w.print(" ({s})", .{d});
            try w.writeAll(".");
            try fix(w, "The line above names the variable; fix its value or unset it.");
        },
        error.InvalidEnvFile => {
            try w.writeAll("can't read a .env file: it has a line that is not NAME=value.");
            try fix(w, "The log above says which file and line; comment it out with '#' or fix it.");
        },
        error.ProxyProtocolNoPeers => {
            try w.writeAll("can't turn on the PROXY protocol: no peer is allowed to send the header.");
            try fix(w, "Name the load balancers in proxy.trusted or the listener's proxy_protocol_from.");
        },
        // ---- p3/net ----
        error.NetNotBuilt => {
            try w.writeAll("can't serve raw TCP or UDP: this build leaves it out.");
            try fix(w, "Build with -Dnet (on in the web and full profiles).");
        },
        error.NetListenerNeedsPort => {
            try w.writeAll("can't start a raw TCP or UDP listener: ");
            try w.writeAll(ctx.detail orelse "it has no port");
            try w.writeAll(".");
            try fix(w, "Give it a port (0 picks a free one) or a unix socket path; a raw listener never takes $PORT or 8080.");
        },
        error.NetListenerHttp3 => {
            try w.writeAll("can't serve HTTP/3 on a raw TCP or UDP listener.");
            try fix(w, "Turn http3 off for that listener.");
        },
        error.TcpAndUdp => {
            try w.writeAll("can't make one listener both TCP and UDP.");
            try fix(w, "Use two listeners: one with tcp, one with udp.");
        },
        error.UdpWithTls => {
            try w.writeAll("can't use TLS on a UDP listener: DTLS is not supported.");
            try fix(w, "Leave tls out of the UDP listener, or serve the protocol over TCP.");
        },
        error.UdpOnUnixSocket => {
            try w.writeAll("can't listen for UDP on a unix socket.");
            try fix(w, "Give the UDP listener an address and a port.");
        },
        error.UdpWithProxyProtocol => {
            try w.writeAll("can't read the PROXY protocol on a UDP listener.");
            try fix(w, "Turn proxy_protocol off for the UDP listener.");
        },
        error.InvalidFraming => {
            try w.writeAll("can't use these raw listener options: ");
            try w.writeAll(ctx.detail orelse "a limit is out of range");
            try w.writeAll(".");
            try fix(w, "Length prefixes are 1, 2 or 4 bytes, a frame max 1 byte to 1 GiB, read_window 4 KiB to 64 KiB, batch 1 to 64, max_datagram up to 65507.");
        },
        error.NetHandlerContext => {
            try w.writeAll("can't serve a raw listener built for another server state type.");
            try fix(w, "Build the service with this server's Ctx (app.tcp and app.udp do).");
        },
        // ---- end p3/net ----

        // ---- p3/lambda ----
        error.LambdaRuntimeApiMissing => {
            try w.writeAll("can't start in deployment \"lambda\": AWS_LAMBDA_RUNTIME_API is not set; Lambda sets it, and so does the Runtime Interface Emulator (docs/lambda.md, \"Running locally\").");
            try fix(w, "Run it on Lambda or under the Runtime Interface Emulator, set lambda.runtime_api, or use another deployment.");
        },
        error.LambdaNotBuilt => {
            try w.writeAll("can't start in deployment \"lambda\": this build leaves the Lambda adapter out (-Dlambda).");
            try fix(w, "Build with -Dlambda (on in every profile), or use another deployment.");
        },
        error.LambdaRuntimeApiFailed => {
            try w.print("can't go on with the Lambda Runtime API at {s}: {s}; exiting so Lambda starts a new environment.", .{ ctx.address orelse "AWS_LAMBDA_RUNTIME_API", ctx.detail orelse "it gave an answer the adapter cannot use" });
            try fix(w, "Nothing to fix in the app; if it repeats, the function's logs before this line say why.");
        },
        error.SnapStartUnsupported => {
            try w.writeAll("can't run under Lambda SnapStart: it is not supported yet (restored copies would share random-number state).");
            try fix(w, "Publish the function without SnapStart.");
        },
        // ---- end p3/lambda ----

        error.NoProtocols => {
            try w.writeAll("can't start a listener that speaks neither HTTP/1.1 nor HTTP/2.");
            try fix(w, "Turn http1 or http2 on for the listener.");
        },
        error.SeveralHttp3Listeners => {
            try w.writeAll("can't serve HTTP/3 on more than one listener.");
            try fix(w, "Set http3 on one TLS listener only.");
        },
        error.Http3NeedsTls => {
            try w.writeAll("can't serve HTTP/3 on a listener without TLS: QUIC is TLS 1.3.");
            try fix(w, "Give the listener a certificate (listenTls, or https), or turn http3 off.");
        },
        error.Http3NeedsHttps => {
            try w.writeAll("can't serve HTTP/3: the http3 option is set but no TLS listener carries it.");
            try fix(w, "Set https as well, or set http3 = true on a TLS listener.");
        },
        error.TooManyListeners => {
            try w.writeAll("can't hand over this many listeners on a restart.");
            try fix(w, "Use fewer TCP listeners, or leave out the process option (no zero-downtime restart).");
        },
        error.RouteConflict => {
            try w.writeAll("can't register the routes: ");
            try w.writeAll(ctx.detail orelse "two of them conflict, or one is malformed");
            try w.writeAll(".");
            try fix(w, "Change the path or the method of one of them; a parameter at one position has one name.");
        },
        error.OpenApiNameClash => {
            try w.writeAll("can't build the OpenAPI document: two types or security schemes have the same name.");
            try fix(w, "The log names both. Name one with pub const openapi: anole.openapi.Doc(@This()) = .{ .name = \"...\" }, or with app.openapi(.{ .rename = ... }).");
        },
        error.OpenApiOutOfDate => {
            try w.writeAll("can't go on: the OpenAPI file ");
            if (ctx.path) |p| {
                try w.writeAll(p);
                try w.writeAll(" ");
            }
            try w.writeAll("does not match the app's routes.");
            try fix(w, "Run `zig build openapi` to write it again, and commit the result.");
        },
        error.OpenApiNotBuilt => {
            try w.writeAll("can't write or check the OpenAPI file: this build leaves OpenAPI out (-Dopenapi=false).");
            try fix(w, "Build with -Dopenapi (on in the web and full profiles), or drop the openapi steps from build.zig.");
        },
        error.HqInteropNotAllowed => {
            try w.writeAll("can't serve the hq-interop test protocol from this program.");
            try fix(w, "It is for the QUIC interop runner only; leave Http3.hq_interop_root unset.");
        },
        error.TlsNotBuilt => {
            try w.writeAll("can't use TLS: this build leaves it out (-Dtls=none).");
            try fix(w, "Build with -Dtls=boringssl (the default), or remove the certificate and https settings.");
        },
        error.Http2NotBuilt => {
            try w.writeAll("can't speak HTTP/2: this build leaves it out (-Dhttp2=false).");
            try fix(w, "Build with -Dhttp2 (the default), or turn http2 off on the listener.");
        },
        error.Http3NotBuilt => {
            try w.writeAll("can't speak HTTP/3: this build leaves it out (-Dhttp3=false).");
            try fix(w, "Build with -Dhttp3 (the default in the full profile), or turn http3 off.");
        },
        error.AddressInUse => {
            try w.writeAll("can't listen on ");
            try where.listener(ctx, w);
            try w.writeAll(": the port is already in use.");
            if (ctx.port) |p| {
                try w.print("\n  Another process holds it (`lsof -i :{d}` shows which); stop it or use app.listen(\":{d}\").", .{ p, if (p < 65535) p + 1 else p - 1 });
            } else {
                try fix(w, "Another process holds it (`lsof -i :<port>` shows which); stop it or use another port.");
            }
        },
        error.AddressNotAvailable => {
            try w.writeAll("can't listen on ");
            try where.listener(ctx, w);
            try w.writeAll(": this machine has no such address.");
            try fix(w, "Use \"0.0.0.0\" (every interface) or an address of one of this machine's interfaces.");
        },
        error.AccessDenied => {
            try w.writeAll("can't listen on ");
            try where.listener(ctx, w);
            try w.writeAll(": the system refuses.");
            try fix(w, "Ports below 1024 need privileges: use a higher port, or let the platform's proxy listen on 80/443.");
        },
        error.InheritedSocketMismatch => {
            try w.writeAll("can't use the listening sockets handed over (LISTEN_FDS): they do not match the listeners.");
            try fix(w, "Name the sockets http/https in LISTEN_FDNAMES, or hand over as many as there are listeners.");
        },
        error.NoTlsListener => {
            try w.writeAll("can't load a certificate: the server has no TLS listener.");
            try fix(w, "Add a TLS listener (listenTls, the https option) before reloading certificates.");
        },
        error.FileNotFound => {
            try w.writeAll("can't read ");
            try where.file(ctx, w, "the certificate or key file");
            try w.writeAll(": it does not exist.");
            try fix(w, "Check the paths in listenTls / Cert.fromFiles (relative paths start in the working directory).");
        },
        error.InvalidCertificate => {
            try w.writeAll("can't use ");
            try where.file(ctx, w, "the certificate");
            try w.writeAll(": it is not a PEM certificate.");
            try fix(w, "Pass the certificate chain as PEM (\"-----BEGIN CERTIFICATE-----\"), leaf first.");
        },
        error.InvalidKey => {
            try w.writeAll("can't use ");
            try where.file(ctx, w, "the private key");
            try w.writeAll(": it is not a PEM private key.");
            try fix(w, "Pass the key as PEM, unencrypted (\"-----BEGIN PRIVATE KEY-----\").");
        },
        error.KeyMismatch => {
            try w.writeAll("can't use the certificate with this key: they are not a pair.");
            try fix(w, "Check that the key file belongs to the certificate file (compare their public keys).");
        },
        error.DatabaseUnavailable => {
            try w.writeAll("can't connect to ");
            try w.writeAll(ctx.system orelse "a database");
            if (ctx.host) |h| {
                try w.writeAll(" at ");
                try redactUrl(h, w);
            }
            try w.writeAll(": ");
            try w.writeAll(ctx.cause orelse "it did not answer");
            try w.writeAll(".");
            try fix(w, "Check the connection URL (DATABASE_URL, REDIS_URL, ...) and that the server is up; connect_at_start = false starts without it.");
        },
        error.ServerAlreadyOnThread => {
            try w.writeAll("can't start a second server on this thread.");
            try fix(w, "One runtime binds to a thread: deinit the first server before creating another.");
        },
        error.SystemResources => {
            try w.writeAll("can't start: the system is out of a resource (file descriptors, threads or memory).");
            try fix(w, "Raise the open-file limit (ulimit -n) or lower executors and limits.max_connections.");
        },
        error.OutOfMemory => {
            try w.writeAll("can't start: out of memory.");
            try fix(w, "Give the process more memory, or lower executors and the buffer limits.");
        },
        error.Canceled => {
            try w.writeAll("can't start: the start was canceled.");
            try fix(w, "Something stopped the server while it was starting.");
        },
        error.Unexpected => {
            try w.writeAll("can't start: an error nothing here expected");
            if (ctx.cause) |c| try w.print(" ({s})", .{c});
            try w.writeAll(".");
            try fix(w, "The log above names it; please report it with that line.");
        },
    }
}

/// `explain` into `buf`; what fits.
pub fn explainBuf(buf: []u8, err: ServerError, ctx: Context) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    explain(err, ctx, &w) catch {};
    return w.buffered();
}

/// The member of `ServerError` that `name` stands for (an alias too), or
/// null. Does not log.
pub fn serverErrorNamed(name: []const u8) ?ServerError {
    inline for (@typeInfo(ServerError).error_set.error_names.?) |m| if (std.mem.eql(u8, name, m)) return @field(ServerError, m);
    inline for (aliases) |alias| if (std.mem.eql(u8, name, alias[0])) {
        inline for (@typeInfo(ServerError).error_set.error_names.?) |m| if (comptime std.mem.eql(u8, alias[1], m)) return @field(ServerError, m);
    };
    return null;
}

/// Logs `explain`'s text once at `err` (scope `anole`). In test builds at
/// `warn`: a test that provokes a startup error on purpose does not fail
/// on the log.
pub fn logExplained(err: ServerError, ctx: Context) void {
    var buf: [1024]u8 = undefined;
    const text = explainBuf(&buf, err, ctx);
    if (@import("builtin").is_test) {
        std.log.scoped(.anole).warn("{s}", .{text});
    } else {
        log.err("{s}", .{text});
    }
}

test "explain: every member of ServerError has text, and none holds a credential" {
    var buf: [1024]u8 = undefined;
    inline for (@typeInfo(ServerError).error_set.error_names.?) |m| {
        const text = explainBuf(&buf, @field(ServerError, m), .{
            .host = "postgres://app:s3cret@db.internal:5432/app",
            .system = "postgres",
            .port = 3000,
            .address = "0.0.0.0",
        });
        try std.testing.expect(std.mem.startsWith(u8, text, "can't "));
        try std.testing.expect(std.mem.indexOf(u8, text, "\n  ") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "s3cret") == null);
    }
}

test "explain: the examples" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "can't listen on 0.0.0.0:3000: the port is already in use.\n" ++
            "  Another process holds it (`lsof -i :3000` shows which); stop it or use app.listen(\":3001\").",
        explainBuf(&buf, error.AddressInUse, .{ .address = "0.0.0.0", .port = 3000 }),
    );
    const db = explainBuf(&buf, error.DatabaseUnavailable, .{ .system = "postgres", .host = "postgres://app:pw@db:5432/x", .cause = "ConnectionRefused" });
    try std.testing.expect(std.mem.startsWith(u8, db, "can't connect to postgres at postgres://app:***@db:5432/x: ConnectionRefused."));
    try std.testing.expect(std.mem.indexOf(u8, db, "pw@") == null);
    const cert = explainBuf(&buf, error.FileNotFound, .{ .path = "certs/server.pem" });
    try std.testing.expect(std.mem.startsWith(u8, cert, "can't read certs/server.pem: it does not exist."));
}

test "redactUrl: the password only" {
    var buf: [128]u8 = undefined;
    inline for (.{
        .{ "postgres://u:p@h:1/d", "postgres://u:***@h:1/d" },
        .{ "redis://:secret@h", "redis://:***@h" },
        .{ "postgres://u@h/d", "postgres://u@h/d" },
        .{ "h:5432", "h:5432" },
        .{ "mongodb://a:b@c,d/e?x=y@z", "mongodb://a:***@c,d/e?x=y@z" },
    }) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try redactUrl(c[0], &w);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
}

test "serverErrorNamed: members and aliases, nothing else" {
    try std.testing.expectEqual(error.AddressInUse, serverErrorNamed("AddressInUse").?);
    try std.testing.expectEqual(error.AccessDenied, serverErrorNamed("PermissionDenied").?);
    try std.testing.expect(serverErrorNamed("Nope") == null);
}

/// A test that provokes `err` logs on purpose: `const g = errors.expectLog();
/// defer g.deinit();` around the call. Elsewhere an `err` log still fails
/// the test runner.
pub const expectLog = @import("dusty").expect_log.expect;

/// The `anole` log scope. Its `err` is dropped only inside `expectLog`.
pub const log = struct {
    const scoped = std.log.scoped(.anole);
    pub const debug = scoped.debug;
    pub const info = scoped.info;
    pub const warn = scoped.warn;
    pub fn err(comptime format: []const u8, args: anytype) void {
        if (@import("dusty").expect_log.swallow()) return;
        scoped.err(format, args);
    }
};
