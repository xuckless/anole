//! The schema parity gate: every option of a Zig options type has a key in
//! the C ABI's JSON configuration (same name, same group, same default), or
//! an entry here saying why the ABI has none. A new option in Zig, or a key
//! in the JSON that drifts from it, stops the build of the tests until the
//! table here (and the schema, `include/anole.schema.json`) says what it is.
//!
//! Other areas add their own tables with the same API: routes, WebSocket
//! and WebTransport options, static files, middleware, the database
//! connectors, gRPC registration.
const std = @import("std");

pub const Kind = enum {
    /// The same value type and name: defaults must be equal. On a struct
    /// path, every leaf under it maps to the same path in the JSON.
    same,
    /// `?Duration` / `Duration` in Zig, `?u32` / `u32` `<name>_ms` in JSON:
    /// the defaults are equal in milliseconds.
    ms,
    /// The JSON group is typed by the Zig type itself: not descended into.
    same_type,
    /// A different representation: `note` says how.
    custom,
};

pub const Entry = struct {
    /// "timeouts.request", "listeners[].tls.cert": a leaf, or a struct whose
    /// leaves the entry covers.
    zig: []const u8,
    /// "timeouts.request_ms"; null with `omitted`.
    json: ?[]const u8 = null,
    kind: Kind = .same,
    /// Why the ABI has no key, in one line (shown in docs/c-abi.md).
    omitted: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

/// Whether `leaf` is `prefix` or lies under it.
fn under(leaf: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, leaf, prefix)) return false;
    if (leaf.len == prefix.len) return true;
    return leaf[prefix.len] == '.' or leaf[prefix.len] == '[';
}

/// Whether an entry ends the descent into a struct at its path.
fn stops(e: Entry) bool {
    return e.omitted != null or e.kind == .same_type or e.kind == .custom;
}

fn entryStopping(comptime table: []const Entry, comptime path: []const u8) bool {
    for (table) |e| if (std.mem.eql(u8, e.zig, path) and stops(e)) return true;
    return false;
}

/// The paths of the leaves of `T` under `prefix`: scalars, enums, slices of
/// non-structs, optionals of those, unions, `Duration`, pointers. Structs and
/// optional structs are descended into (unless an entry stops it), and
/// `[]const Struct` as "name[]".
fn leaves(comptime T: type, comptime prefix: []const u8, comptime table: []const Entry) []const []const u8 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var out: []const []const u8 = &.{};
        const info = @typeInfo(T);
        if (info != .@"struct" or T == std.Io.Duration) return out;
        for (info.@"struct".field_names, info.@"struct".field_types) |name, FT| {
            const path = if (prefix.len == 0) name else prefix ++ "." ++ name;
            out = out ++ fieldLeaves(FT, path, table);
        }
        return out;
    }
}

fn fieldLeaves(comptime FT: type, comptime path: []const u8, comptime table: []const Entry) []const []const u8 {
    comptime {
        if (entryStopping(table, path)) return &.{path};
        switch (@typeInfo(FT)) {
            .optional => |o| return fieldLeaves(o.child, path, table),
            .@"struct" => {
                if (FT == std.Io.Duration) return &.{path};
                const inner = leaves(FT, path, table);
                return if (inner.len == 0) &.{path} else inner;
            },
            .pointer => |p| {
                if (p.size == .slice and @typeInfo(p.child) == .@"struct" and p.child != std.Io.Duration)
                    return leaves(p.child, path ++ "[]", table);
                return &.{path};
            },
            else => return &.{path},
        }
    }
}

/// The entry that covers `leaf`: the one with the longest `zig`.
fn entryFor(comptime table: []const Entry, comptime leaf: []const u8) ?Entry {
    comptime {
        var best: ?Entry = null;
        for (table) |e| if (under(leaf, e.zig)) {
            if (best == null or e.zig.len > best.?.zig.len) best = e;
        };
        return best;
    }
}

/// Fails compilation naming every leaf of `Zig` without an entry and every
/// entry naming no leaf.
pub fn checkCoverage(comptime Zig: type, comptime table: []const Entry) void {
    comptime {
        @setEvalBranchQuota(2_000_000);
        const all = leaves(Zig, "", table);
        var message: []const u8 = "";
        for (all) |leaf| {
            if (entryFor(table, leaf) == null) message = message ++ "\n  " ++ @typeName(Zig) ++ "." ++ leaf ++
                " has no C ABI key: add it to include/anole.schema.json and src/capi/config.zig with the same name, or to the omitted list in src/capi/parity.zig with a reason";
        }
        for (table) |e| {
            var found = false;
            for (all) |leaf| {
                if (under(leaf, e.zig)) found = true;
            }
            if (!found) message = message ++ "\n  the parity entry \"" ++ e.zig ++ "\" names no leaf of " ++ @typeName(Zig);
        }
        for (table) |e| {
            if (e.omitted == null and e.json == null) message = message ++ "\n  the parity entry \"" ++ e.zig ++ "\" has neither a json key nor a reason";
        }
        if (message.len > 0) @compileError("schema parity:" ++ message);
    }
}

/// A default, reduced to what can be compared.
const Default = union(enum) {
    int: i128,
    boolean: bool,
    string: []const u8,
    null_value,
    unknown,

    fn eql(a: Default, b: Default) bool {
        if (a == .unknown or b == .unknown) return true;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .int => |x| x == b.int,
            .boolean => |x| x == b.boolean,
            .string => |x| std.mem.eql(u8, x, b.string),
            .null_value => true,
            .unknown => true,
        };
    }
};

fn defaultOf(comptime FT: type, comptime v: FT) Default {
    switch (@typeInfo(FT)) {
        .int, .comptime_int => return .{ .int = v },
        .bool => return .{ .boolean = v },
        .@"enum" => return .{ .string = @tagName(v) },
        .optional => |o| return if (v) |x| defaultOf(o.child, x) else .null_value,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return .{ .string = v };
            return .unknown;
        },
        .@"struct" => {
            if (FT == std.Io.Duration) return .{ .int = v.toMilliseconds() };
            return .unknown;
        },
        else => return .unknown,
    }
}

/// The default of the field at `path` ("limits.body_max") in `T`, following
/// the field types down; `.unknown` where it cannot be reduced.
fn defaultAt(comptime T: type, comptime path: []const u8) Default {
    comptime {
        var rest: []const u8 = path;
        var Cur = T;
        while (true) {
            const dot = std.mem.indexOfScalar(u8, rest, '.');
            const raw = if (dot) |i| rest[0..i] else rest;
            const list = std.mem.endsWith(u8, raw, "[]");
            const name = if (list) raw[0 .. raw.len - 2] else raw;
            const info = @typeInfo(Cur);
            if (info != .@"struct") return .unknown;
            const idx = for (info.@"struct".field_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) break i;
            } else return .unknown;
            const FT = info.@"struct".field_types[idx];
            if (dot == null) {
                if (info.@"struct".field_attrs[idx].defaultValue(FT)) |dv| return defaultOf(FT, dv);
                return .unknown;
            }
            Cur = switch (@typeInfo(FT)) {
                .optional => |o| o.child,
                .pointer => |p| if (list) p.child else FT,
                else => FT,
            };
            rest = rest[dot.? + 1 ..];
        }
    }
}

/// The schema node at the JSON path "timeouts.request_ms" (through `$ref`,
/// `anyOf` and `items`), or null.
fn schemaAt(schema: std.json.Value, path: []const u8) ?std.json.Value {
    const defs = schema.object.get("$defs").?.object;
    var node = schema;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |raw| {
        const name = if (std.mem.endsWith(u8, raw, "[]")) raw[0 .. raw.len - 2] else raw;
        node = resolve(node, defs);
        const props = (node.object.get("properties") orelse return null).object;
        node = props.get(name) orelse return null;
        if (std.mem.endsWith(u8, raw, "[]")) {
            node = resolve(node, defs);
            node = node.object.get("items") orelse return null;
        }
    }
    return node;
}

fn resolve(node_in: std.json.Value, defs: std.json.ObjectMap) std.json.Value {
    var n = node_in;
    while (true) {
        if (n.object.get("$ref")) |r| {
            n = defs.get(r.string["#/$defs/".len..]).?;
            continue;
        }
        if (n.object.get("anyOf")) |any| {
            n = any.array.items[0];
            continue;
        }
        return n;
    }
}

fn jsonDefault(prop: std.json.Value) ?Default {
    const have = blk: {
        if (prop.object.get("default")) |d| break :blk d;
        if (prop.object.get("anyOf")) |any| if (any.array.items[0].object.get("default")) |d| break :blk d;
        return null;
    };
    return switch (have) {
        .integer => |i| .{ .int = i },
        .bool => |b| .{ .boolean = b },
        .string => |s| .{ .string = s },
        .null => .null_value,
        else => .unknown,
    };
}

/// At test time: every `json` path exists in the schema, and for `same`
/// and `ms` entries the Zig default equals the schema's and `Config`'s at
/// that path.
pub fn checkSchemaAndDefaults(comptime Zig: type, comptime Config: type, comptime table: []const Entry, schema: std.json.Value) !void {
    const all = comptime leaves(Zig, "", table);
    inline for (all) |leaf| {
        const e = comptime entryFor(table, leaf).?;
        if (comptime e.omitted != null or e.json == null) continue;
        // The JSON path of this leaf: the entry's, with what lies below the
        // entry's Zig path appended.
        const json_path = comptime (e.json.? ++ leaf[e.zig.len..]);
        const node = schemaAt(schema, json_path) orelse {
            std.debug.print("parity: {s}.{s} -> \"{s}\" is not in include/anole.schema.json\n", .{ @typeName(Zig), leaf, json_path });
            return error.ParityMissingKey;
        };
        if (comptime e.kind == .same_type or e.kind == .custom) continue;
        const zig_default = comptime defaultAt(Zig, leaf);
        const config_default = comptime defaultAt(Config, json_path);
        if (!zig_default.eql(config_default)) {
            std.debug.print("parity: {s} defaults to {any} in Zig but \"{s}\" to {any} in Config\n", .{ leaf, zig_default, json_path, config_default });
            return error.ParityDefaultDiffers;
        }
        if (jsonDefault(node)) |sd| if (!zig_default.eql(sd)) {
            std.debug.print("parity: {s} defaults to {any} in Zig but the schema says {any}\n", .{ leaf, zig_default, sd });
            return error.ParityDefaultDiffers;
        };
    }
}

// ---------------------------------------------------------------------------
// ServerOptions

/// `anole.ServerOptions` against the JSON configuration (`Config`).
pub const server_options = [_]Entry{
    .{ .zig = "http", .omitted = "a shorthand for a listener; the ABI names every listener in `listeners`" },
    .{ .zig = "https", .omitted = "a shorthand for a listener; the ABI names every listener in `listeners`" },
    .{ .zig = "listen_tls_http3", .omitted = "the ABI says `http3: true` on the listener" },
    .{ .zig = "listeners[].name", .json = "listeners[].name" },
    .{ .zig = "listeners[].address", .json = "listeners[].address" },
    .{ .zig = "listeners[].port", .json = "listeners[].port" },
    .{ .zig = "listeners[].unix", .json = "listeners[].unix" },
    .{ .zig = "listeners[].unix_mode", .omitted = "the socket file mode (0o660 default) is not in the ABI config yet; a later key can add it" },
    .{ .zig = "listeners[].http1", .json = "listeners[].http1" },
    .{ .zig = "listeners[].http2", .json = "listeners[].http2", .kind = .custom, .note = "Zig defaults to whether -Dhttp2 is built in; the schema and Config say true" },
    .{ .zig = "listeners[].http3", .json = "listeners[].http3" },
    .{ .zig = "listeners[].proxy_protocol", .json = "listeners[].proxy_protocol" },
    .{ .zig = "listeners[].proxy_protocol_from", .json = "listeners[].proxy_protocol_from" },
    // ---- p3/net ----
    .{ .zig = "listeners[].tcp", .json = "listeners[].tcp", .kind = .custom, .note = "the keys of `anole.net.Tcp.Options` (net_tcp below) plus handler, the number carried in the listener's records" },
    .{ .zig = "listeners[].udp", .json = "listeners[].udp", .kind = .custom, .note = "the keys of `anole.net.Udp.Options` (net_udp below) plus handler" },
    // ---- end p3/net ----
    .{ .zig = "listeners[].tls", .json = "listeners[].tls", .kind = .custom, .note = "cert: cert_file + key_file, cert_pem + key_pem or self_signed; client_auth: client_auth + one of client_ca_file, client_ca_pem, client_ca_dir, client_ca_system; alpn: alpn" },
    .{ .zig = "http3", .json = "http3", .kind = .same },
    .{ .zig = "http3.idle_timeout", .json = "http3.idle_timeout_ms", .kind = .ms },
    .{ .zig = "http3.hq_interop_root", .omitted = "QUIC interop runner only" },
    .{ .zig = "http3.webtransport", .omitted = "on when a route is `webtransport`" },
    .{ .zig = "timeouts.request", .json = "timeouts.request_ms", .kind = .ms, .note = "the consumer deadline (504); the core gets the longest plus 5 s" },
    .{ .zig = "timeouts.read_header", .json = "timeouts.read_header_ms", .kind = .ms },
    .{ .zig = "timeouts.write", .json = "timeouts.write_ms", .kind = .ms },
    .{ .zig = "timeouts.keepalive", .json = "timeouts.keepalive_ms", .kind = .ms },
    .{ .zig = "timeouts.idle_park", .json = "timeouts.idle_park_ms", .kind = .ms },
    .{ .zig = "timeouts.shutdown", .json = "timeouts.shutdown_ms", .kind = .ms },
    .{ .zig = "limits", .json = "limits", .kind = .same },
    .{ .zig = "proxy", .json = "proxy", .kind = .same_type },
    .{ .zig = "request", .json = "request", .kind = .same_type },
    .{ .zig = "response", .json = "response", .kind = .same_type, .note = "default_content_type by tag name: \"text\", \"json\"; null: none" },
    .{ .zig = "http2", .json = "http2", .kind = .same_type },
    .{ .zig = "errors", .json = "errors", .kind = .same },
    .{ .zig = "error_handler", .omitted = "a function: the language answers its own errors (`anole_fail`)" },
    .{ .zig = "executors", .json = "executors", .kind = .custom, .note = "0 is `.auto`, n is `.exact(n)`" },
    .{ .zig = "max_stack_size", .omitted = "stacks run Anole's native work only, never language handlers; the default fits the bundled code" },
    .{ .zig = "raise_fd_limit", .omitted = "always on under the ABI" },
    .{ .zig = "signals", .omitted = "the ANOLE_SERVER_SIGNALS flag of `anole_server_create`, not the JSON" },
    .{ .zig = "process", .omitted = "embedded mode: no hand-off, SIGUSR2, LISTEN_FDS or sd_notify" },
    .{ .zig = "restart_timeout", .omitted = "embedded mode: no hand-off, SIGUSR2, LISTEN_FDS or sd_notify" },
    .{ .zig = "blocking", .omitted = "the ABI starts a pool when SQLite is configured; WSGI runs on anole-py's own threads" },
    .{ .zig = "client", .omitted = "no outbound client in the ABI v0" },
    .{ .zig = "environment", .json = "environment" },
    .{ .zig = "deployment", .json = "deployment" },
    .{ .zig = "error_detail", .json = "error_detail" },
    .{ .zig = "banner", .json = "banner", .kind = .custom, .note = "true in Zig, false in the ABI (a binding opts in)" },
    .{ .zig = "log.format", .json = "log.format" },
    .{ .zig = "log.level", .omitted = "the ABI keeps `anole_server_options.log_level`" },
    .{ .zig = "log.service", .json = "log.service" },
    .{ .zig = "console", .json = "console", .kind = .same },
    .{ .zig = "console.keys", .omitted = "a binding owns stdin: it reads the hotkey and calls anole_console_open" },
    .{ .zig = "_console_runtime", .omitted = "internal: the ABI's console.runtime" },
    .{ .zig = "env_files", .omitted = "the binding reads .env files into its language's environment (anole_dotenv_read)" },
    .{ .zig = "_resolved", .omitted = "internal: the C ABI resolves the modes at create" },
    // ---- p3/lambda ----
    .{ .zig = "lambda", .json = "lambda", .kind = .same },
    .{ .zig = "lambda.deadline_margin", .json = "lambda.deadline_margin_ms", .kind = .ms },
    .{ .zig = "lambda.idle_reset", .json = "lambda.idle_reset_ms", .kind = .ms },
    .{ .zig = "lambda.shutdown_timeout", .json = "lambda.shutdown_timeout_ms", .kind = .ms },
    .{ .zig = "lambda.flush_timeout", .json = "lambda.flush_timeout_ms", .kind = .ms },
    // ---- end p3/lambda ----
};

// ---------------------------------------------------------------------------
// WebSocket routes

/// `anole.websocket.UpgradeOptions` against `routes[].websocket`.
pub const websocket_options = [_]Entry{
    .{ .zig = "allowed_origins", .json = "routes[].websocket.origins", .kind = .custom, .note = "a list of origins; \"*\" for any; left out: the request's own host" },
    .{ .zig = "max_message_size", .omitted = "limits.ws_max_message applies to every socket" },
    .{ .zig = "timeout", .omitted = "sockets under the ABI have no deadline of their own: `anole_ws_close` ends one" },
    .{ .zig = "compression", .json = "routes[].websocket.compression", .kind = .custom, .note = "on by default where -Dcompression is built in" },
    .{ .zig = "deflate", .omitted = "permessage-deflate runs on its defaults" },
    .{ .zig = "close_on_drain", .json = "routes[].websocket.close_on_drain" },
    .{ .zig = "drain_reason", .omitted = "the drain's close carries the default reason" },
    .{ .zig = "subprotocols", .json = "routes[].websocket.subprotocols", .note = "\"accept\": \"auto\" only; with \"consumer\" the application picks in anole_ws_accept" },
    .{ .zig = "headers", .omitted = "Zig only: the consumer passes headers per accept (anole_ws_accept_options.headers)" },
};

// ---------------------------------------------------------------------------
// Database connectors

fn dbCommon(comptime kind: []const u8) [4]Entry {
    return .{
        .{ .zig = "name", .json = "databases[].name" },
        .{ .zig = "errors", .json = "databases[].errors", .kind = .same },
        .{ .zig = "cache", .json = "databases[].cache", .kind = .custom, .note = "max_entries and max_bytes, over every executor" },
        .{ .zig = "timeout", .json = "databases[].timeout_ms", .kind = .ms, .note = "0 is none (`" ++ kind ++ "`)" },
    };
}

/// `breaker` and `retry` of the network connectors (not SQLite).
const resilience_entries = [_]Entry{
    .{ .zig = "breaker", .json = "databases[].breaker", .kind = .custom, .note = "an object (consecutive_failures, failure_ratio, min_calls, window_ms, open_ms, max_open_ms, half_open_calls), or null for none; ignored for SQLite" },
    .{ .zig = "retry", .json = "databases[].retry", .kind = .custom, .note = "an object (attempts, base_ms, max_ms, multiplier, attempt_timeout_ms, max_retry_after_ms): what `ANOLE_DB_F_RETRY` retries with" },
};

/// `anole.nats.Options` against `brokers[].nats`.
pub const nats_options = [_]Entry{
    .{ .zig = "url", .json = "brokers[].nats.url" },
    .{ .zig = "name", .json = "brokers[].nats.name" },
    .{ .zig = "label", .json = "brokers[].name", .kind = .custom, .note = "the broker's name" },
    .{ .zig = "auth", .json = "brokers[].nats.token", .kind = .custom, .note = "token; user + password; nkey_seed or nkey_seed_file; creds or creds_file (exactly one form)" },
    .{ .zig = "tls", .json = "brokers[].nats.ca_file", .kind = .custom, .note = "ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify; tls_first; tls_required" },
    .{ .zig = "connections", .json = "brokers[].nats.connections", .kind = .custom, .note = "\"one\" or \"per_executor\"" },
    .{ .zig = "timeout", .json = "brokers[].timeout_ms", .kind = .ms, .note = "0 is none" },
    .{ .zig = "connect_timeout", .json = "brokers[].nats.connect_timeout_ms", .kind = .ms },
    .{ .zig = "connect_at_start", .json = "brokers[].nats.connect_at_start" },
    .{ .zig = "ping_interval", .json = "brokers[].nats.ping_interval_ms", .kind = .ms },
    .{ .zig = "max_outstanding_pings", .json = "brokers[].nats.max_outstanding_pings" },
    .{ .zig = "no_echo", .json = "brokers[].nats.no_echo" },
    .{ .zig = "reconnect", .json = "brokers[].nats.reconnect", .kind = .custom, .note = "min_delay_ms and max_delay_ms for the durations; the rest as in Zig" },
    .{ .zig = "limits", .json = "brokers[].nats.limits", .kind = .custom, .note = "the same names; sizes in bytes" },
    .{ .zig = "errors", .json = "brokers[].errors", .kind = .same },
    .{ .zig = "retry", .json = "brokers[].retry", .kind = .custom, .note = "an object (attempts, base_ms, max_ms, multiplier, attempt_timeout_ms, max_retry_after_ms): what ANOLE_NATS_F_RETRY requests retry with" },
    .{ .zig = "jetstream", .json = "brokers[].nats.jetstream", .kind = .custom, .note = "domain; streams[] and consumers[] with the same names, durations as _ms, `extra` for any other key" },
    .{ .zig = "readiness", .omitted = "always on in the ABI (anole_server_set_ready aside, /readyz includes the broker)" },
    .{ .zig = "environ", .omitted = "Zig only: the process environment" },
};

const tls_note = "ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify";

/// `anole.pg.Options` against `databases[].postgres`.
pub const pg_options = dbCommon("postgres") ++ resilience_entries ++ [_]Entry{
    .{ .zig = "url", .json = "databases[].postgres.url" },
    .{ .zig = "max_connections", .json = "databases[].postgres.max_connections" },
    .{ .zig = "acquire_timeout", .json = "databases[].postgres.acquire_timeout_ms", .kind = .ms },
    .{ .zig = "connect_timeout", .json = "databases[].postgres.connect_timeout_ms", .kind = .ms },
    .{ .zig = "statement_cache_size", .json = "databases[].postgres.statement_cache_size" },
    .{ .zig = "max_lifetime", .json = "databases[].postgres.max_lifetime_ms", .kind = .ms },
    .{ .zig = "idle_timeout", .json = "databases[].postgres.idle_timeout_ms", .kind = .ms },
    .{ .zig = "sslmode", .json = "databases[].postgres.sslmode", .kind = .custom, .note = "by name: \"disable\", \"verify-full\"..." },
    .{ .zig = "tls", .json = "databases[].postgres.ca_file", .kind = .custom, .note = tls_note },
    .{ .zig = "connect_at_start", .json = "databases[].postgres.connect_at_start" },
    .{ .zig = "application_name", .json = "databases[].postgres.application_name" },
    .{ .zig = "ping_timeout", .json = "databases[].postgres.ping_timeout_ms", .kind = .ms },
    .{ .zig = "environ", .omitted = "the ABI reads the process's environment" },
    .{ .zig = "reset_session", .json = "databases[].postgres.reset_session" },
};

/// `anole.sqlite.Options` against `databases[].sqlite`.
pub const sqlite_options = dbCommon("sqlite") ++ [_]Entry{
    .{ .zig = "path", .json = "databases[].sqlite.path" },
    .{ .zig = "uri", .json = "databases[].sqlite.uri" },
    .{ .zig = "readers", .json = "databases[].sqlite.readers" },
    .{ .zig = "busy_timeout", .json = "databases[].sqlite.busy_timeout_ms", .kind = .ms },
    .{ .zig = "statement_cache_size", .json = "databases[].sqlite.statement_cache_size" },
    .{ .zig = "ping_timeout", .json = "databases[].sqlite.ping_timeout_ms", .kind = .ms },
    .{ .zig = "pragmas", .json = "databases[].sqlite.pragmas", .kind = .custom },
};

/// `anole.redis.Options` against `databases[].redis`.
pub const redis_options = dbCommon("redis") ++ resilience_entries ++ [_]Entry{
    .{ .zig = "url", .json = "databases[].redis.url" },
    .{ .zig = "max_connections", .json = "databases[].redis.max_connections" },
    .{ .zig = "acquire_timeout", .json = "databases[].redis.acquire_timeout_ms", .kind = .ms },
    .{ .zig = "connect_timeout", .json = "databases[].redis.connect_timeout_ms", .kind = .ms },
    .{ .zig = "idle_timeout", .json = "databases[].redis.idle_timeout_ms", .kind = .ms },
    .{ .zig = "tls", .json = "databases[].redis.ca_file", .kind = .custom, .note = tls_note },
    .{ .zig = "connect_at_start", .json = "databases[].redis.connect_at_start" },
    .{ .zig = "ping_timeout", .json = "databases[].redis.ping_timeout_ms", .kind = .ms },
    .{ .zig = "environ", .omitted = "the ABI reads the process's environment" },
};

/// `anole.mongodb.Options` against `databases[].mongodb`.
pub const mongodb_options = dbCommon("mongodb") ++ resilience_entries ++ [_]Entry{
    .{ .zig = "url", .json = "databases[].mongodb.url" },
    .{ .zig = "environ", .omitted = "the ABI reads the process's environment" },
    .{ .zig = "database", .json = "databases[].mongodb.database" },
    .{ .zig = "tls", .json = "databases[].mongodb.ca_file", .kind = .custom, .note = tls_note },
    .{ .zig = "max_connections", .json = "databases[].mongodb.max_connections" },
    .{ .zig = "acquire_timeout", .json = "databases[].mongodb.acquire_timeout_ms", .kind = .ms },
    .{ .zig = "server_selection_timeout", .json = "databases[].mongodb.server_selection_timeout_ms", .kind = .ms },
    .{ .zig = "connect_timeout", .json = "databases[].mongodb.connect_timeout_ms", .kind = .ms },
    .{ .zig = "heartbeat", .json = "databases[].mongodb.heartbeat_ms", .kind = .ms },
    .{ .zig = "idle_timeout", .json = "databases[].mongodb.idle_timeout_ms", .kind = .custom, .note = "0 is null (never)" },
    .{ .zig = "retry_reads", .json = "databases[].mongodb.retry_reads" },
    .{ .zig = "retry_writes", .json = "databases[].mongodb.retry_writes" },
    .{ .zig = "connect_at_start", .json = "databases[].mongodb.connect_at_start" },
    .{ .zig = "ping_timeout", .json = "databases[].mongodb.ping_timeout_ms", .kind = .ms },
};

/// `anole.kafka.Options` against `brokers[].kafka`.
pub const kafka_options = [_]Entry{
    .{ .zig = "brokers", .json = "brokers[].kafka.brokers" },
    .{ .zig = "client_id", .json = "brokers[].kafka.client_id" },
    .{ .zig = "label", .json = "brokers[].name", .kind = .custom, .note = "the broker's name" },
    .{ .zig = "tls", .json = "brokers[].kafka.tls", .kind = .custom, .note = "tls: true, or any of ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify" },
    .{ .zig = "sasl", .json = "brokers[].kafka.sasl", .kind = .custom, .note = "an object: mechanism \"PLAIN\", \"SCRAM-SHA-256\" or \"SCRAM-SHA-512\", username, password" },
    .{ .zig = "timeout", .json = "brokers[].timeout_ms", .kind = .ms, .note = "0 is none; bounds the flush" },
    .{ .zig = "connect_timeout", .json = "brokers[].kafka.connect_timeout_ms", .kind = .ms },
    .{ .zig = "request_timeout", .json = "brokers[].kafka.request_timeout_ms", .kind = .ms },
    .{ .zig = "metadata_max_age", .json = "brokers[].kafka.metadata_max_age_ms", .kind = .ms },
    .{ .zig = "connect_at_start", .json = "brokers[].kafka.connect_at_start" },
    .{ .zig = "producer", .json = "brokers[].kafka.producer", .kind = .custom, .note = "acks \"none\"|\"leader\"|\"all\", idempotent, linger_ms, batch_bytes, buffer_bytes, compression \"none\"|\"gzip\"|\"zstd\"|\"lz4\", delivery_timeout_ms, metadata_wait_ms, max_request_bytes" },
    .{ .zig = "errors", .json = "brokers[].errors", .kind = .same },
    .{ .zig = "readiness", .omitted = "always on in the ABI (/readyz includes the broker)" },
    .{ .zig = "environ", .omitted = "the process environment, as the other connectors" },
};

// ---- p3/net ----
/// `anole.net.Tcp.Options` against `listeners[].tcp`.
pub const net_tcp = [_]Entry{
    .{ .zig = "framing", .json = "listeners[].tcp.framing", .kind = .custom, .note = "an object with exactly one of lines {max, strip_cr, crlf}, length {bytes, endian, includes_header, max}, varint {max}; left out: none" },
    .{ .zig = "half_open", .json = "listeners[].tcp.half_open" },
    .{ .zig = "no_delay", .json = "listeners[].tcp.no_delay" },
    .{ .zig = "keepalive", .json = "listeners[].tcp.keepalive_ms", .kind = .ms },
    .{ .zig = "handshake_timeout", .json = "listeners[].tcp.handshake_timeout_ms", .kind = .ms },
    .{ .zig = "idle_timeout", .json = "listeners[].tcp.idle_timeout_ms", .kind = .ms },
    .{ .zig = "lifetime", .json = "listeners[].tcp.lifetime_ms", .kind = .ms },
    .{ .zig = "write_timeout", .json = "listeners[].tcp.write_timeout_ms", .kind = .ms },
    .{ .zig = "write_high_water", .json = "listeners[].tcp.write_high_water" },
    .{ .zig = "write_max", .json = "listeners[].tcp.write_max" },
    .{ .zig = "read_window", .json = "listeners[].tcp.read_window" },
    .{ .zig = "read_ahead", .json = "listeners[].tcp.read_ahead" },
    .{ .zig = "max_connections", .json = "listeners[].tcp.max_connections" },
    .{ .zig = "log_connections", .json = "listeners[].tcp.log_connections" },
};

/// `anole.net.Udp.Options` against `listeners[].udp`.
pub const net_udp = [_]Entry{
    .{ .zig = "sockets", .json = "listeners[].udp.sockets" },
    .{ .zig = "max_datagram", .json = "listeners[].udp.max_datagram" },
    .{ .zig = "batch", .json = "listeners[].udp.batch" },
    .{ .zig = "send_queue", .json = "listeners[].udp.send_queue" },
    .{ .zig = "receive_buffer", .json = "listeners[].udp.receive_buffer" },
    .{ .zig = "send_buffer", .json = "listeners[].udp.send_buffer" },
    .{ .zig = "sessions", .omitted = "per-peer state is the binding's: a Map or dict keyed by address" },
};
// ---- end p3/net ----

// ---- p3/jobs ----
/// `anole.jobs.Options` against `jobs`.
pub const jobs_options = [_]Entry{
    .{ .zig = "store", .json = "jobs.store", .kind = .custom, .note = "a databases[].name (SQLite, PostgreSQL or Redis), or \"memory\"" },
    .{ .zig = "queues", .json = "jobs.queues", .kind = .custom, .note = "name and concurrency, as in Zig" },
    .{ .zig = "run", .omitted = "the ABI always runs workers for the consumer's kinds (enqueue only under deployment lambda)" },
    .{ .zig = "lease", .json = "jobs.lease_ms", .kind = .ms },
    .{ .zig = "poll_interval", .json = "jobs.poll_ms", .kind = .ms },
    .{ .zig = "keep", .json = "jobs.keep", .kind = .custom, .note = "completed_ms, dead_ms, cancelled_ms" },
    .{ .zig = "table_prefix", .json = "jobs.table_prefix" },
    .{ .zig = "key_prefix", .json = "jobs.key_prefix" },
    .{ .zig = "migrate", .json = "jobs.migrate" },
    .{ .zig = "notify", .json = "jobs.notify" },
    .{ .zig = "leader", .json = "jobs.leader", .kind = .custom, .note = "method \"auto\"|\"advisory_lock\"|\"lease_row\", ttl_ms, renew_ms" },
    .{ .zig = "clock", .omitted = "tests / Zig only" },
    .{ .zig = "gate", .omitted = "the ABI's own: workers claim once the server runs" },
    .{ .zig = "name", .omitted = "Anole names the process (hostname and pid)" },
    .{ .zig = "kinds", .json = "jobs.kinds", .kind = .custom, .note = "name, queue, priority, attempts, timeout_ms" },
    .{ .zig = "drain_timeout", .json = "jobs.drain_ms", .kind = .ms },
    .{ .zig = "on_dead", .omitted = "Zig only; the admin ops list dead jobs" },
};

/// `anole.jobs.Kind` against `jobs.kinds[]`.
pub const jobs_kind = [_]Entry{
    .{ .zig = "name", .json = "jobs.kinds[].name" },
    .{ .zig = "queue", .json = "jobs.kinds[].queue" },
    .{ .zig = "priority", .json = "jobs.kinds[].priority", .kind = .custom, .note = "\"critical\"|\"high\"|\"normal\"|\"low\"" },
    .{ .zig = "attempts", .json = "jobs.kinds[].attempts" },
    .{ .zig = "backoff", .omitted = "the ABI's kinds use the default backoff (15 s doubling to 6 h, equal jitter); a worker's RETRY may name a delay" },
    .{ .zig = "timeout", .json = "jobs.kinds[].timeout_ms", .kind = .ms },
};

/// `anole.jobs.CronOptions` against `jobs.cron[]`.
pub const jobs_cron = [_]Entry{
    .{ .zig = "tz", .json = "jobs.cron[].tz" },
    .{ .zig = "missed", .json = "jobs.cron[].missed", .kind = .custom, .note = "\"once\"|\"skip\"|\"all\"" },
    .{ .zig = "catch_up", .json = "jobs.cron[].catch_up_ms", .kind = .ms },
    .{ .zig = "job", .omitted = "the schedule's job takes its kind's defaults" },
};
// ---- end p3/jobs ----

// ---- p3/webhooks ----

/// `anole.webhooks.Options` against `webhooks`.
pub const webhooks_options = [_]Entry{
    .{ .zig = "jobs", .omitted = "the ABI's \"jobs\" configuration is the one jobs client" },
    .{ .zig = "queue", .json = "webhooks.queue" },
    .{ .zig = "timeout", .json = "webhooks.timeout_ms", .kind = .ms },
    .{ .zig = "attempts", .json = "webhooks.attempts" },
    .{ .zig = "backoff", .json = "webhooks.backoff", .kind = .custom, .note = "base_ms, max_ms, multiplier and jitter (\"full\", \"equal\", \"none\")" },
    .{ .zig = "breaker", .json = "webhooks.breaker", .kind = .custom, .note = "an object as databases[].breaker, or null" },
    .{ .zig = "allow_private_addresses", .json = "webhooks.allow_private_addresses" },
    .{ .zig = "require_https", .json = "webhooks.require_https" },
    .{ .zig = "user_agent", .json = "webhooks.user_agent" },
    .{ .zig = "max_payload", .json = "webhooks.max_payload" },
    .{ .zig = "response_kept", .json = "webhooks.response_kept" },
    .{ .zig = "keep_messages", .json = "webhooks.keep_messages_ms", .kind = .ms },
    .{ .zig = "keep_attempts", .json = "webhooks.keep_attempts_ms", .kind = .ms },
    .{ .zig = "disable_after", .json = "webhooks.disable_after_ms", .kind = .ms },
    .{ .zig = "secrets_key", .json = "webhooks.secrets_key_env", .kind = .custom, .note = "the name of an environment variable that holds the key" },
    .{ .zig = "max_endpoints_per_owner", .json = "webhooks.max_endpoints_per_owner" },
    .{ .zig = "on_event", .omitted = "anole_webhooks_watch delivers ANOLE_EV_WEBHOOK_STATUS" },
    .{ .zig = "clock", .omitted = "tests / Zig only" },
};

/// `anole.webhooks.Verify.Options` against the `webhook_verify` middleware.
pub const webhook_verify_options = [_]Entry{
    .{ .zig = "preset", .json = "middleware[].webhook_verify.preset" },
    .{ .zig = "secrets", .json = "middleware[].webhook_verify.secrets", .kind = .custom, .note = "secrets, or secrets_env naming a variable with one secret or several separated by spaces" },
    .{ .zig = "tolerance", .json = "middleware[].webhook_verify.tolerance_ms", .kind = .ms },
    .{ .zig = "dedup", .json = "middleware[].webhook_verify.dedup", .kind = .custom, .note = "\"memory\", \"none\" or \"redis:<database>\"; dedup_ttl_ms is the ttl" },
    .{ .zig = "on_store_error", .json = "middleware[].webhook_verify.on_store_error" },
    .{ .zig = "hmac", .json = "middleware[].webhook_verify.hmac", .kind = .custom, .note = "header, algorithm, encoding, prefix, id_header" },
    .{ .zig = "clock", .omitted = "tests / Zig only" },
};
// ---- end p3/webhooks ----

// ---- p3/realtime ----
// ---- end p3/realtime ----

// ---- p3/s3 ----
const s3_tls_note = "ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify";

/// `anole.s3.Options` against `storage[]`.
pub const s3_options = [_]Entry{
    .{ .zig = "endpoint", .json = "storage[].s3.endpoint" },
    .{ .zig = "region", .json = "storage[].s3.region" },
    .{ .zig = "bucket", .json = "storage[].s3.bucket" },
    .{ .zig = "credentials", .json = "storage[].s3.access_key_id", .kind = .custom, .note = "access_key_id + secret_access_key (+ session_token), or anonymous; neither takes the AWS credential chain" },
    .{ .zig = "provider", .json = "storage[].s3.provider", .kind = .custom, .note = "by name: \"auto\", \"aws\", \"r2\", \"b2\", \"supabase\", \"minio\", \"generic\"" },
    .{ .zig = "addressing", .json = "storage[].s3.addressing", .kind = .custom, .note = "\"auto\", \"path\" or \"virtual_host\"" },
    .{ .zig = "payload_signing", .json = "storage[].s3.payload_signing", .kind = .custom, .note = "\"auto\", \"signed\" or \"unsigned\"" },
    .{ .zig = "name", .json = "storage[].name", .kind = .custom, .note = "the store's name" },
    .{ .zig = "tls", .json = "storage[].s3.ca_file", .kind = .custom, .note = s3_tls_note },
    .{ .zig = "timeout", .json = "storage[].timeout_ms", .kind = .ms, .note = "0 is none" },
    .{ .zig = "min_throughput", .json = "storage[].s3.min_throughput" },
    .{ .zig = "connect_timeout", .json = "storage[].s3.connect_timeout_ms", .kind = .ms },
    .{ .zig = "max_idle_connections", .json = "storage[].s3.max_idle_connections" },
    .{ .zig = "part_size", .json = "storage[].s3.part_size" },
    .{ .zig = "multipart_threshold", .json = "storage[].s3.multipart_threshold" },
    .{ .zig = "concurrency", .json = "storage[].s3.concurrency" },
    .{ .zig = "upload_memory", .json = "storage[].s3.upload_memory" },
    .{ .zig = "max_object_bytes", .json = "storage[].s3.max_object_bytes" },
    .{ .zig = "errors", .json = "storage[].errors", .kind = .same },
    .{ .zig = "retry", .json = "storage[].retry", .kind = .custom, .note = "an object (attempts, base_ms, max_ms, multiplier, attempt_timeout_ms, max_retry_after_ms), or null for none; on by default (every S3 call is idempotent); ANOLE_S3_F_NO_RETRY tries one call once" },
    .{ .zig = "breaker", .json = "storage[].breaker", .kind = .custom, .note = "an object (consecutive_failures, failure_ratio, min_calls, window_ms, open_ms, max_open_ms, half_open_calls), or null for none" },
    .{ .zig = "readiness", .json = "storage[].s3.readiness" },
    .{ .zig = "environ", .omitted = "the process environment, as the other connectors" },
};
// ---- end p3/s3 ----

// ---- p3/smtp ----
/// `anole.smtp.Options` against `mail[].smtp`.
pub const smtp_options = [_]Entry{
    .{ .zig = "url", .json = "mail[].smtp.url" },
    .{ .zig = "from", .json = "mail[].smtp.from" },
    .{ .zig = "username", .json = "mail[].smtp.username" },
    .{ .zig = "password", .json = "mail[].smtp.password" },
    .{ .zig = "tls_mode", .json = "mail[].smtp.tls_mode", .kind = .custom, .note = "\"auto\", \"starttls\", \"implicit\" or \"none\"" },
    .{ .zig = "tls", .json = "mail[].smtp.ca_file", .kind = .custom, .note = "ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify" },
    .{ .zig = "helo_name", .json = "mail[].smtp.helo_name" },
    .{ .zig = "name", .json = "mail[].name", .kind = .custom, .note = "the mail server's name" },
    .{ .zig = "max_connections", .json = "mail[].smtp.max_connections" },
    .{ .zig = "max_messages_per_connection", .json = "mail[].smtp.max_messages_per_connection" },
    .{ .zig = "idle_timeout", .json = "mail[].smtp.idle_timeout_ms", .kind = .ms, .note = "0 is never" },
    .{ .zig = "acquire_timeout", .json = "mail[].smtp.acquire_timeout_ms", .kind = .ms },
    .{ .zig = "connect_timeout", .json = "mail[].smtp.connect_timeout_ms", .kind = .ms },
    .{ .zig = "timeout", .json = "mail[].timeout_ms", .kind = .ms, .note = "0 is none" },
    .{ .zig = "min_throughput", .json = "mail[].smtp.min_throughput" },
    .{ .zig = "max_message_bytes", .json = "mail[].smtp.max_message_bytes" },
    .{ .zig = "errors", .json = "mail[].errors", .kind = .same },
    .{ .zig = "retry", .json = "mail[].retry", .kind = .custom, .note = "an object (attempts, base_ms, max_ms, multiplier, attempt_timeout_ms, max_retry_after_ms): what `ANOLE_SMTP_F_RETRY` sends retry with" },
    .{ .zig = "breaker", .json = "mail[].breaker", .kind = .custom, .note = "an object (consecutive_failures, failure_ratio, min_calls, window_ms, open_ms, max_open_ms, half_open_calls), or null for none" },
    .{ .zig = "readiness", .json = "mail[].smtp.readiness" },
    .{ .zig = "environment", .omitted = "the server's environment (`environment` in the configuration)" },
    .{ .zig = "environ", .omitted = "the process environment, as the other connectors" },
};
// ---- end p3/smtp ----

// ---- p3/lambda ----
// ---- end p3/lambda ----
