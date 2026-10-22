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
    .{ .zig = "listeners[].http1", .json = "listeners[].http1" },
    .{ .zig = "listeners[].http2", .json = "listeners[].http2" },
    .{ .zig = "listeners[].http3", .json = "listeners[].http3" },
    .{ .zig = "listeners[].proxy_protocol", .json = "listeners[].proxy_protocol" },
    .{ .zig = "listeners[].proxy_protocol_from", .json = "listeners[].proxy_protocol_from" },
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

const tls_note = "ca_file or ca_pem; client_cert_file + client_key_file or client_cert_pem + client_key_pem; insecure_skip_verify";

/// `anole.pg.Options` against `databases[].postgres`.
pub const pg_options = dbCommon("postgres") ++ [_]Entry{
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
pub const redis_options = dbCommon("redis") ++ [_]Entry{
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
pub const mongodb_options = dbCommon("mongodb") ++ [_]Entry{
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
