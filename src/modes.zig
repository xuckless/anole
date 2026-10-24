//! Environment (development or production) and deployment (what sits in
//! front of the server) modes: defaults for the options a user left unset,
//! worked out once at startup and printed. A field set in code, JSON or a
//! variable is never changed here; only `null` fields are filled.
//! docs/config.md has the tables.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http/root.zig");
const env = @import("env.zig");
const url = @import("db/url.zig");
const server = @import("server.zig");
const features = @import("build_options");

const ServerOptions = server.Options;

pub const Environment = enum { development, production };

pub const Deployment = enum {
    /// Clients connect to this server directly (the 0.2 behaviour).
    standalone,
    /// An HTTP proxy in front (nginx, Caddy, Traefik, a cloud load balancer
    /// at L7) sets X-Forwarded-For and X-Forwarded-Proto.
    behind_proxy,
    /// An L4 load balancer in front sends a PROXY protocol header on every
    /// connection (anole-lb; HAProxy `mode tcp` with `send-proxy-v2`; AWS
    /// NLB with proxy protocol v2).
    anole_lb,
    /// A platform that runs the app behind its own proxy and names the port
    /// in PORT (Render, Heroku, Fly.io, Cloud Run, Railway).
    platform,
    /// AWS Lambda (docs/lambda.md): invocations come from the Lambda
    /// Runtime API (`AWS_LAMBDA_RUNTIME_API`), or, for a Lambda web
    /// function, one HTTP/1.1 listener at `AWS_LAMBDA_HTTP_ENDPOINT`.
    /// Listeners named in the options are set aside.
    lambda,
};

pub const Source = enum { options, variable, dotenv, build, tests, default };

pub const Build = struct {
    mode: std.builtin.OptimizeMode,
    is_test: bool,
    /// libanole: falls back to production whatever the build.
    embedded: bool = false,
    /// The deployment when neither the options nor ANOLE_DEPLOYMENT name
    /// one (`-Ddefault-deployment`; `zig build lambda` builds `lambda`).
    default_deployment: Deployment = .standalone,
    pub const current: Build = .{ .mode = builtin.mode, .is_test = builtin.is_test, .default_deployment = build_default };
    pub const abi: Build = .{ .mode = builtin.mode, .is_test = builtin.is_test, .embedded = true };
};

const build_default: Deployment = if (@hasDecl(features, "default_deployment"))
    std.meta.stringToEnum(Deployment, @tagName(features.default_deployment)).?
else
    .standalone;

/// The environment lookups resolution uses, so tests pass their own.
pub const Vars = struct {
    ctx: ?*const anyopaque = null,
    /// The process environment only.
    real: *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8,
    /// The process environment, then the `.env` entries (`url.env`).
    any: *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8,

    fn processReal(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
        return url.realEnv(null, name);
    }
    fn processAny(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
        return url.env(null, name);
    }
    /// The two above over the process.
    pub const process: Vars = .{ .real = processReal, .any = processAny };
};

pub const Error = error{ InvalidEnvironmentVariable, InvalidProxyNetwork, InvalidListenAddress, LambdaRuntimeApiMissing, LambdaNotBuilt, OutOfMemory };

pub const EnvironmentResult = struct { environment: Environment, source: Source };

/// Step 1: the environment, before any `.env` file is read.
pub fn resolveEnvironment(explicit: ?Environment, vars: Vars, build: Build, why: *std.Io.Writer) Error!EnvironmentResult {
    if (explicit) |e| return .{ .environment = e, .source = .options };
    if (vars.real(vars.ctx, "ANOLE_ENV")) |v| {
        if (std.meta.stringToEnum(Environment, v)) |e| return .{ .environment = e, .source = .variable };
        why.print("ANOLE_ENV=\"{s}\": use \"development\" or \"production\"", .{v}) catch {};
        return error.InvalidEnvironmentVariable;
    }
    if (build.is_test) return .{ .environment = .production, .source = .tests };
    if (build.embedded) return .{ .environment = .production, .source = .default };
    return .{ .environment = if (build.mode == .debug) .development else .production, .source = .build };
}

pub const Resolved = struct {
    environment: Environment,
    environment_source: Source,
    deployment: Deployment,
    deployment_source: Source,
    error_detail: bool,
    error_detail_from_mode: bool,
    /// `log.format = .auto` chose JSON Lines because the environment is
    /// production (the startup line says so).
    log_json_from_mode: bool = false,
    /// Parsed; null: no gate (standalone without proxy.trusted).
    trusted: ?[]const http.ProxyNetwork,
    /// What `trusted` was written as.
    trusted_text: []const []const u8,
    trusted_source: Source, // options, variable, dotenv, default (the mode's), or default with null
    /// For listeners whose address/port/proxy_protocol are null.
    default_address: []const u8,
    default_port: u16,
    port_source: Source, // default, variable, dotenv
    proxy_protocol_default: bool,
    listen_tls_http3: bool,
    listen_tls_http3_from_mode: bool,
    warn_untrusted_peer: bool,
    /// The .env files read (null: none were to be read).
    files: ?*const env.Files,
    /// A Debug build running as production (warned about at startup).
    debug_production: bool = false,
    /// `proxy` settings the startup line mentions.
    forward_proto: bool = true,
    forward_host: bool = false,
    trusted_hops: u8 = 0,
    /// What the listeners took from the mode, set by `fillListeners`.
    filled: struct { address: bool = false, port: bool = false, proxy_protocol: bool = false } = .{},
    /// A platform variable seen while deployment is standalone by default.
    hint: ?struct { platform: []const u8, variable: []const u8 } = null,
    /// AWS_LAMBDA_RUNTIME_API or AWS_LAMBDA_HTTP_ENDPOINT seen while the
    /// deployment is standalone by default.
    lambda_hint: ?[]const u8 = null,
    /// `deployment = lambda`: where invocations come from.
    lambda: ?Lambda = null,
    /// What the options named that `deployment = lambda` does not open
    /// (`server.zig` fills it; the startup line names it).
    set_aside: SetAside = .{},

    pub const Lambda = struct {
        sub_mode: SubMode,
        /// The Runtime API, or the web function's endpoint: host:port.
        endpoint: []const u8,
        endpoint_source: Source,
        invoke_mode: server.Options.Lambda.InvokeMode,
        invoke_mode_source: Source,
        /// Invocations at once (0 for a web function: the platform's).
        concurrency: u16,
        concurrency_source: Source,
        /// For `executors = .auto`: 1 at concurrency 1 through the Runtime
        /// API, else null (the CPU count).
        executors: ?u16,

        pub const SubMode = enum { runtime_api, web_function };
    };

    pub const SetAside = struct {
        http: bool = false,
        https: bool = false,
        listeners: usize = 0,
        http3: bool = false,
        listen: ?[]const u8 = null,
        listen_tls: ?[]const u8 = null,
        tcp: usize = 0,
        udp: usize = 0,

        pub fn any(sa: SetAside) bool {
            return sa.http or sa.https or sa.listeners > 0 or sa.http3 or sa.listen != null or sa.listen_tls != null or sa.tcp > 0 or sa.udp > 0;
        }
    };
};

const deployment_names = "\"standalone\", \"behind_proxy\", \"anole_lb\", \"platform\" or \"lambda\"";

/// Step 2 (after `.env` is read): everything else. `a` owns the result
/// (the server's arena). `why` gets the one-line reason on an error.
pub fn resolve(
    a: std.mem.Allocator,
    opts: *const ServerOptions,
    environment: Environment,
    environment_source: Source,
    files: ?*const env.Files,
    vars: Vars,
    build: Build,
    why: *std.Io.Writer,
) Error!Resolved {
    var r: Resolved = undefined;
    r.environment = environment;
    r.environment_source = environment_source;
    r.files = files;
    r.filled = .{};
    r.hint = null;
    r.lambda_hint = null;
    r.lambda = null;
    r.set_aside = .{};
    r.forward_proto = opts.proxy.trust_forwarded_proto;
    r.forward_host = opts.proxy.trust_forwarded_host;
    r.trusted_hops = opts.proxy.trusted_hops;
    r.debug_production = environment == .production and builtin.mode == .debug and !builtin.is_test and environment_source != .default;

    // 1. deployment
    if (opts.deployment) |d| {
        r.deployment = d;
        r.deployment_source = .options;
    } else if (vars.any(vars.ctx, "ANOLE_DEPLOYMENT")) |v| {
        r.deployment = std.meta.stringToEnum(Deployment, v) orelse {
            why.print("ANOLE_DEPLOYMENT=\"{s}\": use {s}", .{ v, deployment_names }) catch {};
            return error.InvalidEnvironmentVariable;
        };
        r.deployment_source = if (vars.real(vars.ctx, "ANOLE_DEPLOYMENT") != null) .variable else .dotenv;
    } else if (build.default_deployment != .standalone) {
        r.deployment = build.default_deployment;
        r.deployment_source = .build;
    } else {
        r.deployment = .standalone;
        r.deployment_source = .default;
    }
    if (r.deployment == .lambda) r.lambda = try resolveLambda(opts, vars, why);

    // 2. hint
    if (r.deployment == .standalone and r.deployment_source == .default) {
        const known = [_][2][]const u8{
            .{ "K_SERVICE", "Cloud Run" },
            .{ "DYNO", "Heroku" },
            .{ "FLY_APP_NAME", "Fly.io" },
            .{ "RENDER", "Render" },
        };
        for (known) |k| if (vars.real(vars.ctx, k[0]) != null) {
            r.hint = .{ .platform = k[1], .variable = k[0] };
            break;
        };
        for ([_][]const u8{ "AWS_LAMBDA_RUNTIME_API", "AWS_LAMBDA_HTTP_ENDPOINT" }) |name| if (vars.real(vars.ctx, name) != null) {
            r.lambda_hint = name;
            break;
        };
    }

    // 3. error_detail
    r.error_detail = opts.error_detail orelse (environment == .development);
    r.error_detail_from_mode = opts.error_detail == null;
    r.log_json_from_mode = opts.log.format == .auto and environment == .production and !builtin.is_test;

    // 4. trusted proxies
    const web_function = if (r.lambda) |l| l.sub_mode == .web_function else false;
    const mode_default = r.deployment == .behind_proxy or r.deployment == .anole_lb or r.deployment == .platform or web_function;
    if (opts.proxy.trusted) |list| {
        r.trusted_text = list;
        r.trusted_source = .options;
        r.trusted = parseTrusted(a, list) catch |err| {
            if (err == error.InvalidProxyNetwork) why.writeAll("proxy.trusted has an entry that is not an address, a CIDR network or one of loopback, private, link_local") catch {};
            return err;
        };
    } else if (vars.any(vars.ctx, "ANOLE_PROXY_TRUSTED")) |v| {
        var items: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t");
            if (item.len > 0) try items.append(a, item);
        }
        r.trusted_text = items.items;
        r.trusted_source = if (vars.real(vars.ctx, "ANOLE_PROXY_TRUSTED") != null) .variable else .dotenv;
        r.trusted = parseTrusted(a, items.items) catch |err| {
            if (err == error.InvalidProxyNetwork) why.print("ANOLE_PROXY_TRUSTED=\"{s}\": every entry is an address, a CIDR network or one of loopback, private, link_local", .{v}) catch {};
            return err;
        };
    } else if (mode_default) {
        const text: []const []const u8 = &.{ "loopback", "private" };
        r.trusted_text = text;
        r.trusted_source = .default;
        r.trusted = try parseTrusted(a, text);
    } else {
        r.trusted_text = &.{};
        r.trusted_source = .default;
        r.trusted = null;
    }

    // 5. address and port
    r.default_address = if (r.deployment == .anole_lb or r.deployment == .platform) "" else "127.0.0.1";
    r.default_port = 8080;
    r.port_source = .default;
    if (r.deployment == .platform) {
        if (vars.any(vars.ctx, "PORT")) |v| {
            const port = std.fmt.parseInt(u16, v, 10) catch 0;
            if (port == 0) {
                why.print("PORT=\"{s}\" is not a port number", .{v}) catch {};
                return error.InvalidEnvironmentVariable;
            }
            r.default_port = port;
            r.port_source = if (vars.real(vars.ctx, "PORT") != null) .variable else .dotenv;
        }
    }

    // The web function's listener is the endpoint Lambda names.
    if (r.lambda) |l| if (l.sub_mode == .web_function) {
        const hp = splitHostPort(l.endpoint).?;
        r.default_address = hp.host;
        r.default_port = hp.port;
        r.port_source = l.endpoint_source;
    };

    // 6. the rest
    r.proxy_protocol_default = r.deployment == .anole_lb;
    r.listen_tls_http3 = opts.listen_tls_http3 orelse !(r.deployment == .behind_proxy or r.deployment == .platform or r.deployment == .lambda);
    r.listen_tls_http3_from_mode = opts.listen_tls_http3 == null;
    r.warn_untrusted_peer = mode_default and r.deployment != .lambda;
    return r;
}

/// "host:port" (a bracketed IPv6 host too), port 1-65535; null otherwise.
pub fn splitHostPort(text: []const u8) ?struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0) return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

/// `deployment = lambda`: the Runtime API or the web function's endpoint,
/// the invoke mode and the concurrency (design: docs/lambda.md).
fn resolveLambda(opts: *const ServerOptions, vars: Vars, why: *std.Io.Writer) Error!Resolved.Lambda {
    if (comptime !features.lambda) {
        why.writeAll("deployment \"lambda\": this build leaves the Lambda adapter out (-Dlambda)") catch {};
        return error.LambdaNotBuilt;
    }
    const o = opts.lambda;
    var l: Resolved.Lambda = undefined;
    // The platform's variables come from the real environment only: a
    // .env line must never make a development run poll a Runtime API.
    if (o.runtime_api) |api| {
        if (splitHostPort(api) == null) {
            why.print("lambda.runtime_api=\"{s}\": use host:port", .{api}) catch {};
            return error.InvalidListenAddress;
        }
        l.sub_mode = .runtime_api;
        l.endpoint = api;
        l.endpoint_source = .options;
    } else if (vars.real(vars.ctx, "AWS_LAMBDA_HTTP_ENDPOINT")) |v| {
        if (splitHostPort(v) == null) {
            why.print("AWS_LAMBDA_HTTP_ENDPOINT=\"{s}\": use host:port", .{v}) catch {};
            return error.InvalidEnvironmentVariable;
        }
        l.sub_mode = .web_function;
        l.endpoint = v;
        l.endpoint_source = .variable;
    } else if (vars.real(vars.ctx, "AWS_LAMBDA_RUNTIME_API")) |v| {
        if (splitHostPort(v) == null) {
            why.print("AWS_LAMBDA_RUNTIME_API=\"{s}\": use host:port", .{v}) catch {};
            return error.InvalidEnvironmentVariable;
        }
        l.sub_mode = .runtime_api;
        l.endpoint = v;
        l.endpoint_source = .variable;
    } else {
        why.writeAll("deployment \"lambda\": AWS_LAMBDA_RUNTIME_API is not set; Lambda sets it, and so does the Runtime Interface Emulator (docs/lambda.md, \"Running locally\")") catch {};
        return error.LambdaRuntimeApiMissing;
    }

    if (o.invoke_mode) |m| {
        l.invoke_mode = m;
        l.invoke_mode_source = .options;
    } else if (vars.any(vars.ctx, "ANOLE_LAMBDA_INVOKE_MODE")) |v| {
        l.invoke_mode = std.meta.stringToEnum(server.Options.Lambda.InvokeMode, v) orelse {
            why.print("ANOLE_LAMBDA_INVOKE_MODE=\"{s}\": use \"buffered\" or \"response_stream\"", .{v}) catch {};
            return error.InvalidEnvironmentVariable;
        };
        l.invoke_mode_source = if (vars.real(vars.ctx, "ANOLE_LAMBDA_INVOKE_MODE") != null) .variable else .dotenv;
    } else {
        l.invoke_mode = .buffered;
        l.invoke_mode_source = .default;
    }

    if (l.sub_mode == .web_function) {
        l.concurrency = 0;
        l.concurrency_source = .default;
        l.executors = null;
        return l;
    }
    if (o.concurrency) |c| {
        if (c == 0 or c > 4096) {
            why.print("lambda.concurrency={d}: use 1 to 4096", .{c}) catch {};
            return error.InvalidEnvironmentVariable;
        }
        l.concurrency = c;
        l.concurrency_source = .options;
    } else if (vars.real(vars.ctx, "AWS_LAMBDA_MAX_CONCURRENCY")) |v| {
        const n = std.fmt.parseInt(u16, v, 10) catch 0;
        if (n == 0 or n > 4096) {
            why.print("AWS_LAMBDA_MAX_CONCURRENCY=\"{s}\": use 1 to 4096", .{v}) catch {};
            return error.InvalidEnvironmentVariable;
        }
        l.concurrency = n;
        l.concurrency_source = .variable;
    } else {
        l.concurrency = 1;
        l.concurrency_source = .default;
    }
    l.executors = if (l.concurrency == 1) 1 else null;
    return l;
}

/// `proxy.trusted` entries: names, addresses, CIDR networks.
pub fn parseTrusted(a: std.mem.Allocator, list: []const []const u8) error{ InvalidProxyNetwork, OutOfMemory }![]const http.ProxyNetwork {
    var out: std.ArrayList(http.ProxyNetwork) = .empty;
    for (list) |entry| {
        if (std.mem.eql(u8, entry, "loopback")) {
            try out.appendSlice(a, &http.proxy_networks.loopback);
        } else if (std.mem.eql(u8, entry, "private")) {
            try out.appendSlice(a, &http.proxy_networks.private);
        } else if (std.mem.eql(u8, entry, "link_local")) {
            try out.appendSlice(a, &http.proxy_networks.link_local);
        } else {
            try out.append(a, http.ProxyNetwork.parse(entry) catch return error.InvalidProxyNetwork);
        }
    }
    return out.items;
}

/// Fills the null address/port/proxy_protocol of `opts.http`, `opts.https`
/// and `opts.listeners` (copied into `a`), and creates the default listener
/// when none is named, from `r`; records what it filled in `r.filled`.
pub fn fillListeners(a: std.mem.Allocator, opts: *ServerOptions, r: *Resolved) error{OutOfMemory}!void {
    if (opts.http == null and opts.https == null and opts.listeners.len == 0) opts.http = .{};
    if (opts.http) |*h| {
        if (h.address == null) {
            h.address = r.default_address;
            r.filled.address = true;
        }
        if (h.port == null) {
            h.port = r.default_port;
            r.filled.port = true;
        }
        if (h.proxy_protocol == null) {
            h.proxy_protocol = r.proxy_protocol_default;
            r.filled.proxy_protocol = r.proxy_protocol_default;
        }
    }
    if (opts.https) |*h| {
        if (h.address == null) {
            h.address = r.default_address;
            r.filled.address = true;
        }
        if (h.proxy_protocol == null) {
            h.proxy_protocol = r.proxy_protocol_default;
            r.filled.proxy_protocol = r.proxy_protocol_default;
        }
    }
    if (opts.listeners.len > 0) {
        const copy = try a.dupe(ServerOptions.Listener, opts.listeners);
        for (copy) |*l| {
            if (l.unix != null) continue;
            if (l.address == null) {
                l.address = r.default_address;
                r.filled.address = true;
            }
            // A raw listener (p3/net) names its own port: $PORT and the 8080
            // default are HTTP's. UDP has no PROXY header to default.
            const raw = l.tcp != null or l.udp != null;
            if (l.port == null and !raw) {
                l.port = r.default_port;
                r.filled.port = true;
            }
            if (l.proxy_protocol == null and l.udp == null) {
                l.proxy_protocol = r.proxy_protocol_default;
                r.filled.proxy_protocol = r.proxy_protocol_default;
            }
        }
        opts.listeners = copy;
    }
}

pub const LineContext = struct { used_listen_tls: bool = false };

fn deploymentSourceText(s: Source) []const u8 {
    return switch (s) {
        .options => "options",
        .variable => "ANOLE_DEPLOYMENT",
        .dotenv => "ANOLE_DEPLOYMENT in .env",
        .build => "lambda build",
        else => "default",
    };
}

/// What the Runtime API deployment line says beyond the resolution.
pub const LambdaLine = struct {
    executors: usize,
    event_path: ?[]const u8,
    sigterm: bool,
    ready_ms: f64,
};

/// The deployment line of `deployment = lambda` through the Runtime API,
/// ending in "\n"; written by the adapter once it is ready.
pub fn writeLambdaLine(r: *const Resolved, info: LambdaLine, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const l = r.lambda.?;
    try w.print("deployment lambda ({s}): invocations from the Lambda Runtime API at {s}, {d} at a time on {d} executor{s}; ", .{
        deploymentSourceText(r.deployment_source), l.endpoint, l.concurrency, info.executors, if (info.executors == 1) "" else "s",
    });
    switch (l.invoke_mode) {
        .buffered => try w.writeAll("buffered answers; "),
        .response_stream => try w.writeAll("streamed answers for Function URLs and REST APIs; "),
    }
    if (info.event_path) |p| try w.print("other events to POST {s}; ", .{p}) else try w.writeAll("other events fail (event_path is null); ");
    try w.writeAll(if (info.sigterm) "SIGTERM through a no-op extension; " else "no SIGTERM (sigterm off); ");
    try w.print("ready in {d:.1} ms\n", .{info.ready_ms});
}

/// The line naming the listeners `deployment = lambda` set aside, ending
/// in "\n"; nothing when none were.
pub fn writeSetAside(r: *const Resolved, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const sa = r.set_aside;
    if (!sa.any()) return;
    const web = if (r.lambda) |l| l.sub_mode == .web_function else false;
    try w.writeAll(if (web) "deployment lambda: only the web function's listener opens here, so " else "deployment lambda: no listener opens here, so ");
    var names: [8][]const u8 = undefined;
    var bufs: [8][64]u8 = undefined;
    var n: usize = 0;
    if (sa.listen) |addr| {
        names[n] = std.fmt.bufPrint(&bufs[n], "listen(\"{s}\")", .{addr}) catch "listen()";
        n += 1;
    }
    if (sa.listen_tls) |addr| {
        names[n] = std.fmt.bufPrint(&bufs[n], "listenTls(\"{s}\")", .{addr}) catch "listenTls()";
        n += 1;
    }
    if (sa.http) {
        names[n] = "http";
        n += 1;
    }
    if (sa.https) {
        names[n] = "https";
        n += 1;
    }
    if (sa.listeners > 0) {
        names[n] = std.fmt.bufPrint(&bufs[n], "listeners ({d})", .{sa.listeners}) catch "listeners";
        n += 1;
    }
    if (sa.tcp > 0) {
        names[n] = std.fmt.bufPrint(&bufs[n], "tcp ({d})", .{sa.tcp}) catch "tcp";
        n += 1;
    }
    if (sa.udp > 0) {
        names[n] = std.fmt.bufPrint(&bufs[n], "udp ({d})", .{sa.udp}) catch "udp";
        n += 1;
    }
    if (sa.http3) {
        names[n] = "http3";
        n += 1;
    }
    for (names[0..n], 0..) |name, i| {
        if (i > 0) try w.writeAll(if (i == n - 1) " and " else ", ");
        try w.writeAll(name);
    }
    try w.writeAll(if (n == 1) " is set aside; " else " are set aside; ");
    try w.writeAll(if (web) "requests come to the web function's endpoint\n" else "requests come from Lambda\n");
}

fn sourceText(s: Source, build_mode: std.builtin.OptimizeMode) []const u8 {
    return switch (s) {
        .options => "options",
        .variable => "ANOLE_ENV",
        .dotenv => "ANOLE_ENV in .env",
        .build => if (build_mode == .debug) "Debug build" else "release build",
        .tests => "tests",
        .default => "default",
    };
}

fn writeNets(w: *std.Io.Writer, nets: []const http.ProxyNetwork) std.Io.Writer.Error!void {
    for (nets, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try n.format(w);
    }
}

/// The startup lines, each ending in "\n"; a line starting with "!" is a
/// warning. Nothing for a standalone production server with nothing from the
/// environment beyond the environment line.
pub fn writeLines(r: *const Resolved, ctx: LineContext, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // Environment line.
    try w.print("environment {t} ({s})", .{ r.environment, sourceText(r.environment_source, builtin.mode) });
    var first = true;
    const sep = struct {
        fn go(wr: *std.Io.Writer, f: *bool) std.Io.Writer.Error!void {
            try wr.writeAll(if (f.*) ": " else "; ");
            f.* = false;
        }
    }.go;
    if (r.files) |files| {
        try sep(w, &first);
        if (files.read.len == 0) {
            try w.writeAll("no .env file found");
        } else {
            try w.writeAll("read ");
            for (files.read, 0..) |f, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s} ({d} value{s})", .{ f.path, f.count, if (f.count == 1) "" else "s" });
            }
        }
    }
    if (r.error_detail_from_mode and r.error_detail) {
        try sep(w, &first);
        try w.writeAll("500 answers name the error");
    }
    if (r.log_json_from_mode) {
        try sep(w, &first);
        try w.writeAll("JSON Lines logs");
    }
    try w.writeByte('\n');
    if (r.files) |files| if (files.saw_anole_env) |f| {
        try w.print("ANOLE_ENV in {s} is not used: it decides whether .env files are read, so set it in the environment\n", .{f});
    };
    if (r.debug_production) try w.writeAll("!a Debug build running as production: Debug builds are several times slower; build with -Doptimize=ReleaseSafe\n");

    // proxy.trusted from a variable.
    if (r.trusted_source == .variable or r.trusted_source == .dotenv) {
        try w.print("proxy.trusted from ANOLE_PROXY_TRUSTED{s}: ", .{if (r.trusted_source == .dotenv) " in .env" else ""});
        if (r.trusted) |nets| {
            if (nets.len == 0) try w.writeAll("none") else try writeNets(w, nets);
        } else try w.writeAll("none");
        try w.writeByte('\n');
    }

    if (r.hint) |h| try w.print("this looks like {s} ({s} is set): set ANOLE_DEPLOYMENT=platform to listen on $PORT and trust its proxy\n", .{ h.platform, h.variable });
    if (r.lambda_hint) |name| {
        if (std.mem.eql(u8, name, "AWS_LAMBDA_RUNTIME_API")) {
            try w.writeAll("AWS_LAMBDA_RUNTIME_API is set: to serve Lambda invocations, set ANOLE_DEPLOYMENT=lambda or build with zig build lambda (behind the Lambda Web Adapter, leave it as is)\n");
        } else {
            try w.writeAll("AWS_LAMBDA_HTTP_ENDPOINT is set: set ANOLE_DEPLOYMENT=lambda to listen there\n");
        }
    }

    // Deployment line.
    if (r.deployment == .standalone) return;
    if (r.lambda) |l| {
        // Through the Runtime API the adapter writes it once it is ready
        // (`writeLambdaLine`): it knows the executors and the time taken.
        if (l.sub_mode == .runtime_api) return;
        try w.print("deployment lambda ({s}): a Lambda web function: HTTP/1.1 on {s} from AWS_LAMBDA_HTTP_ENDPOINT; X-Forwarded-For and X-Forwarded-Proto from ", .{ deploymentSourceText(r.deployment_source), l.endpoint });
        if (r.trusted) |nets| {
            if (nets.len == 0) try w.writeAll("none") else try writeNets(w, nets);
        } else try w.writeAll("none");
        try w.writeAll(" (proxy.trusted); drain at most 900 ms\n");
        return;
    }
    try w.print("deployment {t} ({s})", .{ r.deployment, deploymentSourceText(r.deployment_source) });
    first = true;
    if (r.trusted_source == .default) if (r.trusted) |nets| {
        try sep(w, &first);
        try w.writeAll("X-Forwarded-For");
        if (r.forward_proto and r.forward_host) {
            try w.writeAll(", X-Forwarded-Proto and X-Forwarded-Host");
        } else if (r.forward_proto) {
            try w.writeAll(" and X-Forwarded-Proto");
        } else if (r.forward_host) {
            try w.writeAll(" and X-Forwarded-Host");
        }
        try w.writeAll(" from ");
        try writeNets(w, nets);
        if (r.trusted_hops > 0) try w.print(" (proxy.trusted, trusted_hops {d})", .{r.trusted_hops}) else try w.writeAll(" (proxy.trusted)");
    };
    if (r.filled.proxy_protocol) {
        try sep(w, &first);
        try w.writeAll("a PROXY protocol header on every listener's connections, from those networks (proxy_protocol)");
    }
    if (r.filled.address) {
        if (r.deployment == .behind_proxy) {
            try sep(w, &first);
            try w.writeAll("127.0.0.1 only: a proxy in another container or on another host needs address \"\"");
        } else if (r.deployment == .anole_lb or r.deployment == .platform) {
            try sep(w, &first);
            try w.writeAll("every interface (address \"\")");
        }
    }
    if (r.filled.port and r.deployment == .platform) {
        try sep(w, &first);
        switch (r.port_source) {
            .variable => try w.print("port {d} from PORT", .{r.default_port}),
            .dotenv => try w.print("port {d} from PORT in .env", .{r.default_port}),
            else => try w.print("port {d} (PORT is not set)", .{r.default_port}),
        }
    }
    if (r.listen_tls_http3_from_mode and !r.listen_tls_http3 and ctx.used_listen_tls) {
        try sep(w, &first);
        try w.writeAll("no HTTP/3 from listenTls (listen_tls_http3)");
    }
    try w.writeByte('\n');
}

// ---- tests ----

const testing = std.testing;

const TestVars = struct {
    real: []const [2][]const u8 = &.{},
    dotenv: []const [2][]const u8 = &.{},

    fn find(list: []const [2][]const u8, name: []const u8) ?[]const u8 {
        for (list) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return null;
    }
    fn realFn(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx.?));
        return find(self.real, name);
    }
    fn anyFn(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestVars = @ptrCast(@alignCast(ctx.?));
        return find(self.real, name) orelse find(self.dotenv, name);
    }
    fn vars(self: *const TestVars) Vars {
        return .{ .ctx = self, .real = realFn, .any = anyFn };
    }
};

fn resolveFor(a: std.mem.Allocator, opts: ServerOptions, tv: *const TestVars, why: *std.Io.Writer) Error!Resolved {
    return resolve(a, &opts, .production, .tests, null, tv.vars(), .current, why);
}

test "modes: environment resolution" {
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const none: TestVars = .{};
    const explicit = try resolveEnvironment(.development, none.vars(), .current, &why);
    try testing.expectEqual(Environment.development, explicit.environment);
    try testing.expectEqual(Source.options, explicit.source);
    const set: TestVars = .{ .real = &.{.{ "ANOLE_ENV", "development" }} };
    const from_var = try resolveEnvironment(null, set.vars(), .{ .mode = .fast, .is_test = false }, &why);
    try testing.expectEqual(Environment.development, from_var.environment);
    try testing.expectEqual(Source.variable, from_var.source);
    const dbg = try resolveEnvironment(null, none.vars(), .{ .mode = .debug, .is_test = false }, &why);
    try testing.expectEqual(Environment.development, dbg.environment);
    try testing.expectEqual(Source.build, dbg.source);
    const rel = try resolveEnvironment(null, none.vars(), .{ .mode = .safe, .is_test = false }, &why);
    try testing.expectEqual(Environment.production, rel.environment);
    const tst = try resolveEnvironment(null, none.vars(), .{ .mode = .debug, .is_test = true }, &why);
    try testing.expectEqual(Environment.production, tst.environment);
    try testing.expectEqual(Source.tests, tst.source);
    const emb = try resolveEnvironment(null, none.vars(), .{ .mode = .debug, .is_test = false, .embedded = true }, &why);
    try testing.expectEqual(Environment.production, emb.environment);
    try testing.expectEqual(Source.default, emb.source);
    const bad: TestVars = .{ .real = &.{.{ "ANOLE_ENV", "prod" }} };
    try testing.expectError(error.InvalidEnvironmentVariable, resolveEnvironment(null, bad.vars(), .current, &why));
}

test "modes: standalone changes nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const tv: TestVars = .{};
    var opts: ServerOptions = .{};
    var r = try resolveFor(a, opts, &tv, &why);
    try fillListeners(a, &opts, &r);
    try testing.expectEqualStrings("127.0.0.1", opts.http.?.address.?);
    try testing.expectEqual(@as(u16, 8080), opts.http.?.port.?);
    try testing.expectEqual(false, opts.http.?.proxy_protocol.?);
    try testing.expect(r.listen_tls_http3);
    try testing.expect(r.trusted == null);
    try testing.expect(!r.warn_untrusted_peer);
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeLines(&r, .{}, &w);
    try testing.expectEqualStrings("environment production (tests)\n", w.buffered());
}

test "modes: behind_proxy row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const tv: TestVars = .{ .real = &.{.{ "ANOLE_DEPLOYMENT", "behind_proxy" }} };
    var opts: ServerOptions = .{};
    var r = try resolveFor(a, opts, &tv, &why);
    try fillListeners(a, &opts, &r);
    try testing.expectEqual(Deployment.behind_proxy, r.deployment);
    try testing.expectEqual(@as(usize, 6), r.trusted.?.len);
    try testing.expectEqualStrings("127.0.0.1", opts.http.?.address.?);
    try testing.expectEqual(false, opts.http.?.proxy_protocol.?);
    try testing.expect(!r.listen_tls_http3);
    try testing.expect(r.warn_untrusted_peer);
    var out: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeLines(&r, .{}, &w);
    try testing.expectEqualStrings(
        "environment production (tests)\n" ++
            "deployment behind_proxy (ANOLE_DEPLOYMENT): X-Forwarded-For and X-Forwarded-Proto from 127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 (proxy.trusted); 127.0.0.1 only: a proxy in another container or on another host needs address \"\"\n",
        w.buffered(),
    );
}

test "modes: anole_lb row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const tv: TestVars = .{};
    var opts: ServerOptions = .{ .deployment = .anole_lb, .listeners = &.{ .{}, .{ .proxy_protocol = false } } };
    var r = try resolveFor(a, opts, &tv, &why);
    try fillListeners(a, &opts, &r);
    try testing.expectEqualStrings("", opts.listeners[0].address.?);
    try testing.expectEqual(true, opts.listeners[0].proxy_protocol.?);
    try testing.expectEqual(false, opts.listeners[1].proxy_protocol.?);
    try testing.expect(r.listen_tls_http3);
}

test "modes: platform row and PORT" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    {
        const tv: TestVars = .{ .real = &.{.{ "PORT", "41234" }} };
        var opts: ServerOptions = .{ .deployment = .platform };
        var r = try resolveFor(a, opts, &tv, &why);
        try fillListeners(a, &opts, &r);
        try testing.expectEqual(@as(u16, 41234), opts.http.?.port.?);
        try testing.expectEqual(Source.variable, r.port_source);
        try testing.expectEqualStrings("", opts.http.?.address.?);
        try testing.expect(!r.listen_tls_http3);
    }
    {
        const tv: TestVars = .{ .dotenv = &.{.{ "PORT", "5000" }} };
        const opts: ServerOptions = .{ .deployment = .platform };
        const r = try resolveFor(a, opts, &tv, &why);
        try testing.expectEqual(Source.dotenv, r.port_source);
    }
    {
        const tv: TestVars = .{};
        const opts: ServerOptions = .{ .deployment = .platform };
        const r = try resolveFor(a, opts, &tv, &why);
        try testing.expectEqual(@as(u16, 8080), r.default_port);
    }
    for ([_][]const u8{ "abc", "0", "70000" }) |bad| {
        const tv: TestVars = .{ .real = &.{.{ "PORT", bad }} };
        const opts: ServerOptions = .{ .deployment = .platform };
        try testing.expectError(error.InvalidEnvironmentVariable, resolveFor(a, opts, &tv, &why));
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "PORT", "41234" }} };
        var opts: ServerOptions = .{ .deployment = .platform, .http = .{ .port = 3000 } };
        var r = try resolveFor(a, opts, &tv, &why);
        try fillListeners(a, &opts, &r);
        try testing.expectEqual(@as(u16, 3000), opts.http.?.port.?);
    }
}

test "modes: explicit wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const tv: TestVars = .{};
    var opts: ServerOptions = .{
        .deployment = .platform,
        .error_detail = false,
        .listen_tls_http3 = true,
        .proxy = .{ .trusted = &.{} },
        .http = .{ .address = "127.0.0.1", .port = 9, .proxy_protocol = true },
    };
    var r = try resolveFor(a, opts, &tv, &why);
    try fillListeners(a, &opts, &r);
    try testing.expectEqualStrings("127.0.0.1", opts.http.?.address.?);
    try testing.expectEqual(@as(u16, 9), opts.http.?.port.?);
    try testing.expectEqual(true, opts.http.?.proxy_protocol.?);
    try testing.expect(r.listen_tls_http3);
    try testing.expectEqual(@as(usize, 0), r.trusted.?.len);
    try testing.expect(!r.error_detail);
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeLines(&r, .{ .used_listen_tls = true }, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "every interface") == null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "no HTTP/3") == null);
}

test "modes: ANOLE_PROXY_TRUSTED" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    {
        const tv: TestVars = .{ .real = &.{.{ "ANOLE_PROXY_TRUSTED", "private, 203.0.113.7" }} };
        const r = try resolveFor(a, .{ .deployment = .behind_proxy }, &tv, &why);
        try testing.expectEqual(@as(usize, 5), r.trusted.?.len);
        try testing.expectEqual(Source.variable, r.trusted_source);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "proxy.trusted from ANOLE_PROXY_TRUSTED: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7, 203.0.113.7/32\n") != null);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "ANOLE_PROXY_TRUSTED", "" }} };
        const r = try resolveFor(a, .{ .deployment = .behind_proxy }, &tv, &why);
        try testing.expectEqual(@as(usize, 0), r.trusted.?.len);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "ANOLE_PROXY_TRUSTED", "10.0.0/8" }} };
        why = .fixed(&buf);
        try testing.expectError(error.InvalidProxyNetwork, resolveFor(a, .{}, &tv, &why));
        try testing.expect(std.mem.indexOf(u8, why.buffered(), "ANOLE_PROXY_TRUSTED") != null);
    }
}

test "modes: lambda row (runtime API)" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const tv: TestVars = .{ .real = &.{.{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" }} };
    const r = try resolveFor(a, .{ .deployment = .lambda }, &tv, &why);
    const l = r.lambda.?;
    try testing.expectEqual(Resolved.Lambda.SubMode.runtime_api, l.sub_mode);
    try testing.expectEqualStrings("127.0.0.1:9001", l.endpoint);
    try testing.expectEqual(Source.variable, l.endpoint_source);
    try testing.expectEqual(@as(u16, 1), l.concurrency);
    try testing.expectEqual(@as(?u16, 1), l.executors);
    try testing.expect(l.invoke_mode == .buffered);
    try testing.expect(r.trusted == null);
    try testing.expect(!r.warn_untrusted_peer);
    try testing.expect(!r.listen_tls_http3);
    // The deployment line is the adapter's (it knows the time taken).
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeLines(&r, .{}, &w);
    try testing.expectEqualStrings("environment production (tests)\n", w.buffered());
    w = .fixed(&out);
    try writeLambdaLine(&r, .{ .executors = 1, .event_path = "/_lambda/event", .sigterm = true, .ready_ms = 3.4 }, &w);
    try testing.expectEqualStrings("deployment lambda (options): invocations from the Lambda Runtime API at 127.0.0.1:9001, 1 at a time on 1 executor; buffered answers; other events to POST /_lambda/event; SIGTERM through a no-op extension; ready in 3.4 ms\n", w.buffered());
}

test "modes: lambda Managed Instances and Web Functions" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    {
        const tv: TestVars = .{ .real = &.{ .{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" }, .{ "AWS_LAMBDA_MAX_CONCURRENCY", "8" } } };
        const r = try resolveFor(a, .{ .deployment = .lambda }, &tv, &why);
        try testing.expectEqual(@as(u16, 8), r.lambda.?.concurrency);
        try testing.expectEqual(@as(?u16, null), r.lambda.?.executors);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "AWS_LAMBDA_HTTP_ENDPOINT", "127.0.0.1:9002" }} };
        var opts: ServerOptions = .{ .deployment = .lambda };
        var r = try resolveFor(a, opts, &tv, &why);
        try fillListeners(a, &opts, &r);
        try testing.expectEqual(Resolved.Lambda.SubMode.web_function, r.lambda.?.sub_mode);
        try testing.expectEqualStrings("127.0.0.1", opts.http.?.address.?);
        try testing.expectEqual(@as(u16, 9002), opts.http.?.port.?);
        try testing.expectEqual(@as(usize, 6), r.trusted.?.len);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "deployment lambda (options): a Lambda web function: HTTP/1.1 on 127.0.0.1:9002 from AWS_LAMBDA_HTTP_ENDPOINT; X-Forwarded-For and X-Forwarded-Proto from 127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 (proxy.trusted); drain at most 900 ms\n") != null);
    }
}

test "modes: lambda variables" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    {
        var why: std.Io.Writer = .fixed(&buf);
        const tv: TestVars = .{};
        try testing.expectError(error.LambdaRuntimeApiMissing, resolveFor(a, .{ .deployment = .lambda }, &tv, &why));
        try testing.expectEqualStrings("deployment \"lambda\": AWS_LAMBDA_RUNTIME_API is not set; Lambda sets it, and so does the Runtime Interface Emulator (docs/lambda.md, \"Running locally\")", why.buffered());
    }
    const cases = [_]struct { name: []const u8, value: []const u8, want: []const u8 }{
        .{ .name = "AWS_LAMBDA_RUNTIME_API", .value = "localhost", .want = "AWS_LAMBDA_RUNTIME_API=\"localhost\": use host:port" },
        .{ .name = "ANOLE_LAMBDA_INVOKE_MODE", .value = "stream", .want = "ANOLE_LAMBDA_INVOKE_MODE=\"stream\": use \"buffered\" or \"response_stream\"" },
        .{ .name = "AWS_LAMBDA_MAX_CONCURRENCY", .value = "0", .want = "AWS_LAMBDA_MAX_CONCURRENCY=\"0\": use 1 to 4096" },
    };
    for (cases) |c| {
        var why: std.Io.Writer = .fixed(&buf);
        const api: [2][]const u8 = .{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" };
        const real: []const [2][]const u8 = if (std.mem.eql(u8, c.name, "AWS_LAMBDA_RUNTIME_API")) &.{.{ c.name, c.value }} else &.{ api, .{ c.name, c.value } };
        const tv: TestVars = .{ .real = real };
        try testing.expectError(error.InvalidEnvironmentVariable, resolveFor(a, .{ .deployment = .lambda }, &tv, &why));
        try testing.expectEqualStrings(c.want, why.buffered());
    }
}

test "modes: lambda build default, hints and explicit options" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const lambda_build: Build = .{ .mode = .safe, .is_test = true, .default_deployment = .lambda };
    {
        const tv: TestVars = .{ .real = &.{.{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" }} };
        const r = try resolve(a, &.{}, .production, .tests, null, tv.vars(), lambda_build, &why);
        try testing.expectEqual(Deployment.lambda, r.deployment);
        try testing.expectEqual(Source.build, r.deployment_source);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try writeLambdaLine(&r, .{ .executors = 1, .event_path = null, .sigterm = false, .ready_ms = 1 }, &w);
        try testing.expect(std.mem.startsWith(u8, w.buffered(), "deployment lambda (lambda build): "));
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "other events fail (event_path is null); no SIGTERM (sigterm off)") != null);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "ANOLE_DEPLOYMENT", "standalone" }} };
        const r = try resolve(a, &.{}, .production, .tests, null, tv.vars(), lambda_build, &why);
        try testing.expectEqual(Deployment.standalone, r.deployment);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" }} };
        const r = try resolveFor(a, .{}, &tv, &why);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "AWS_LAMBDA_RUNTIME_API is set: to serve Lambda invocations, set ANOLE_DEPLOYMENT=lambda or build with zig build lambda (behind the Lambda Web Adapter, leave it as is)\n") != null);
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "AWS_LAMBDA_HTTP_ENDPOINT", "127.0.0.1:9002" }} };
        const r = try resolveFor(a, .{}, &tv, &why);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "AWS_LAMBDA_HTTP_ENDPOINT is set: set ANOLE_DEPLOYMENT=lambda to listen there\n") != null);
    }
    {
        // Explicit options stay as set; ANOLE_LAMBDA_INVOKE_MODE from a .env file counts.
        const tv: TestVars = .{ .real = &.{ .{ "AWS_LAMBDA_RUNTIME_API", "127.0.0.1:9001" }, .{ "AWS_LAMBDA_MAX_CONCURRENCY", "8" } }, .dotenv = &.{.{ "ANOLE_LAMBDA_INVOKE_MODE", "buffered" }} };
        const r = try resolveFor(a, .{ .deployment = .lambda, .lambda = .{ .runtime_api = "10.0.0.1:9009", .invoke_mode = .response_stream, .concurrency = 2 } }, &tv, &why);
        const l = r.lambda.?;
        try testing.expectEqualStrings("10.0.0.1:9009", l.endpoint);
        try testing.expect(l.invoke_mode == .response_stream);
        try testing.expectEqual(Source.options, l.invoke_mode_source);
        try testing.expectEqual(@as(u16, 2), l.concurrency);
    }
}

test "modes: lambda set-aside line" {
    var r: Resolved = undefined;
    r.lambda = null;
    r.set_aside = .{ .listen = ":3000", .https = true };
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeSetAside(&r, &w);
    try testing.expectEqualStrings("deployment lambda: no listener opens here, so listen(\":3000\") and https are set aside; requests come from Lambda\n", w.buffered());
    r.set_aside = .{};
    w = .fixed(&out);
    try writeSetAside(&r, &w);
    try testing.expectEqualStrings("", w.buffered());
}

test "modes: startup lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    var files: env.Files = .{};
    const read = [_]env.Files.Read{ .{ .path = ".env", .count = 3 }, .{ .path = ".env.local", .count = 1 } };
    files.read = &read;
    var out: [1024]u8 = undefined;
    {
        const tv: TestVars = .{};
        var r = try resolve(a, &.{}, .development, .build, &files, tv.vars(), .current, &why);
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        const want = if (builtin.mode == .debug) "Debug build" else "release build";
        const expected = try std.fmt.allocPrint(a, "environment development ({s}): read .env (3 values), .env.local (1 value); 500 answers name the error\n", .{want});
        try testing.expectEqualStrings(expected, w.buffered());
    }
    {
        const tv: TestVars = .{};
        const empty: env.Files = .{};
        const r = try resolve(a, &.{}, .development, .variable, &empty, tv.vars(), .current, &why);
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expectEqualStrings("environment development (ANOLE_ENV): no .env file found; 500 answers name the error\n", w.buffered());
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "PORT", "41234" }} };
        var opts: ServerOptions = .{ .deployment = .platform };
        var r = try resolveFor(a, opts, &tv, &why);
        try fillListeners(a, &opts, &r);
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{ .used_listen_tls = true }, &w);
        try testing.expectEqualStrings(
            "environment production (tests)\n" ++
                "deployment platform (options): X-Forwarded-For and X-Forwarded-Proto from 127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 (proxy.trusted); every interface (address \"\"); port 41234 from PORT; no HTTP/3 from listenTls (listen_tls_http3)\n",
            w.buffered(),
        );
    }
    {
        const tv: TestVars = .{ .real = &.{.{ "K_SERVICE", "x" }} };
        const r = try resolveFor(a, .{}, &tv, &why);
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "this looks like Cloud Run (K_SERVICE is set): set ANOLE_DEPLOYMENT=platform to listen on $PORT and trust its proxy\n") != null);
    }
    {
        var f2: env.Files = .{};
        f2.saw_anole_env = ".env.local";
        const tv: TestVars = .{};
        const r = try resolve(a, &.{}, .development, .build, &f2, tv.vars(), .current, &why);
        var w: std.Io.Writer = .fixed(&out);
        try writeLines(&r, .{}, &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "ANOLE_ENV in .env.local is not used: it decides whether .env files are read, so set it in the environment\n") != null);
    }
}

test "modes: parseTrusted names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nets = try parseTrusted(a, &.{ "loopback", "link_local", "192.0.2.7" });
    try testing.expectEqual(@as(usize, 5), nets.len);
    try testing.expectError(error.InvalidProxyNetwork, parseTrusted(a, &.{"nope"}));
}
