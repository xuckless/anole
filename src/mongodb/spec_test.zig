//! The MongoDB driver specifications' own tests (mongodb/specifications,
//! the pinned `mongodb_specs` dependency, CC BY-NC-SA 3.0 US, so fetched,
//! never vendored), over the client's pure parts: the connection string
//! and its options, credentials, SCRAM, and the topology state machine.
//! build.zig runs this binary from the specification's `source` directory
//! and reads the JSON files from there.
//!
//! Every case is run or skipped with a reason (`skipped` below); a pin
//! bump that adds cases shows up in the counts printed at the end.
const std = @import("std");
const uri = @import("uri.zig");

const testing = std.testing;
const gpa = testing.allocator;
const json = std.json;

/// The `.json` files of `dir`, sorted, owned by `arena`.
fn jsonFiles(arena: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn readJson(arena: std.mem.Allocator, path: []const u8) !json.Value {
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(8 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn field(v: json.Value, name: []const u8) ?json.Value {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    if (f == .null) return null;
    return f;
}

/// Cases run and skipped in one suite, checked against the pinned
/// specification's counts so a bump that adds or drops cases is noticed.
const Tally = struct {
    passed: usize = 0,
    skipped: usize = 0,

    fn expect(t: Tally, passed: usize, skipped: usize) !void {
        if (t.passed != passed or t.skipped != skipped) {
            std.debug.print("expected {d} passed and {d} skipped, got {d} and {d}\n", .{ passed, skipped, t.passed, t.skipped });
            return error.CaseCountChanged;
        }
    }
};

// ---------------------------------------------------------------------------
// connection-string, uri-options, auth (legacy connection strings)

/// Cases skipped, by description, with the reason.
const uri_skipped = [_]struct { []const u8, []const u8 }{
    // The auth tests disagree with themselves: user:password@localhost is
    // valid and user:pass@localhost.com is not, with the same mechanism.
    // Anole has no MONGODB-AWS; its rule (both or neither) takes the first.
    .{ "should throw an exception if username and password provided (MONGODB-AWS)", "the spec's AWS cases contradict each other; no MONGODB-AWS in Anole" },
    .{ "should throw an exception if username provided (MONGODB-AWS)", "the spec's AWS cases contradict each other; no MONGODB-AWS in Anole" },
};

fn uriSkip(description: []const u8) ?[]const u8 {
    for (uri_skipped) |s| if (std.mem.eql(u8, s[0], description)) return s[1];
    return null;
}

test "spec: connection-string, uri-options and auth connection strings" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(arena, try jsonFiles(arena, "connection-string/tests"));
    try files.appendSlice(arena, try jsonFiles(arena, "uri-options/tests"));
    try files.append(arena, "auth/tests/legacy/connection-string.json");

    var tally: Tally = .{};
    var failures: usize = 0;
    for (files.items) |path| {
        const doc = try readJson(arena, path);
        for (field(doc, "tests").?.array.items) |case| {
            const description = field(case, "description").?.string;
            if (uriSkip(description)) |_| {
                tally.skipped += 1;
                continue;
            }
            checkUriCase(arena, case) catch |err| {
                failures += 1;
                std.debug.print("FAIL {s}: {s}: {t}\n", .{ path, description, err });
                continue;
            };
            tally.passed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try tally.expect(323, 2);
}

fn checkUriCase(arena: std.mem.Allocator, case: json.Value) !void {
    const text = field(case, "uri").?.string;
    const valid = field(case, "valid").?.bool;
    var diag: uri.Diagnostic = .{};
    const parsed = uri.parse(arena, text, &diag);
    // The auth file checks credentials: a URI whose credential is
    // refused is invalid too.
    const cs = parsed catch |err| {
        if (valid) {
            std.debug.print("  refused: {s}\n", .{diag.message});
            return err;
        }
        return;
    };
    const cred = uri.credential(arena, cs, &diag) catch |err| {
        if (valid) {
            std.debug.print("  credential refused: {s}\n", .{diag.message});
            return err;
        }
        return;
    };
    if (!valid) return error.AcceptedInvalid;

    if (field(case, "warning")) |w| {
        if (w.bool != (cs.warnings.len > 0)) {
            for (cs.warnings) |msg| std.debug.print("  warning: {s}\n", .{msg});
            return if (w.bool) error.MissingWarning else error.UnexpectedWarning;
        }
    }
    if (field(case, "hosts")) |hosts| {
        if (hosts.array.items.len != cs.hosts.len) return error.HostCount;
        for (hosts.array.items, cs.hosts) |want, got| {
            if (!std.mem.eql(u8, field(want, "host").?.string, got.name)) return error.HostName;
            if (field(want, "port")) |port| {
                if (got.port == null or port.integer != got.port.?) return error.HostPort;
            } else if (got.port != null) return error.HostPort;
            if (field(want, "type")) |t| if (!std.mem.eql(u8, t.string, @tagName(got.kind))) return error.HostType;
        }
    }
    if (field(case, "auth")) |auth| {
        try expectOptionalString(field(auth, "username"), cs.username);
        try expectOptionalString(field(auth, "password"), cs.password);
        try expectOptionalString(field(auth, "db"), cs.database);
    }
    if (field(case, "options")) |options| {
        var it = options.object.iterator();
        while (it.next()) |e| {
            const got = cs.get(e.key_ptr.*) orelse {
                std.debug.print("  option {s} missing\n", .{e.key_ptr.*});
                return error.OptionMissing;
            };
            if (!optionEql(e.value_ptr.*, got)) {
                std.debug.print("  option {s} differs\n", .{e.key_ptr.*});
                return error.OptionDiffers;
            }
        }
    }
    if (case.object.get("credential")) |want_cred| {
        if (want_cred == .null) {
            if (cred != null) return error.UnexpectedCredential;
        } else {
            const got = cred orelse return error.CredentialMissing;
            try expectOptionalString(field(want_cred, "username"), got.username);
            try expectOptionalString(field(want_cred, "password"), got.password);
            if (field(want_cred, "source")) |s| if (!std.mem.eql(u8, s.string, got.source)) return error.CredentialSource;
            if (field(want_cred, "mechanism")) |m| {
                if (got.mechanism == null or !std.mem.eql(u8, m.string, got.mechanism.?.name())) return error.CredentialMechanism;
            } else if (got.mechanism != null) return error.CredentialMechanism;
            if (field(want_cred, "mechanism_properties")) |props| {
                var it = props.object.iterator();
                while (it.next()) |e| {
                    const v = got.property(e.key_ptr.*) orelse return error.CredentialProperty;
                    const want = switch (e.value_ptr.*) {
                        .string => |s| s,
                        .bool => |b| if (b) "true" else "false",
                        else => return error.CredentialProperty,
                    };
                    if (!std.mem.eql(u8, want, v)) return error.CredentialProperty;
                }
            }
        }
    }
}

fn expectOptionalString(want: ?json.Value, got: ?[]const u8) !void {
    const w = want orelse return;
    const g = got orelse return error.FieldMissing;
    if (!std.mem.eql(u8, w.string, g)) return error.FieldDiffers;
}

fn optionEql(want: json.Value, got: uri.Value) bool {
    return switch (got) {
        .boolean => |b| want == .bool and want.bool == b,
        .int => |n| want == .integer and want.integer == n,
        .string => |s| want == .string and std.mem.eql(u8, want.string, s),
        .list => |l| blk: {
            if (want != .array or want.array.items.len != l.len) break :blk false;
            for (want.array.items, l) |w, g| if (w != .string or !std.mem.eql(u8, w.string, g)) break :blk false;
            break :blk true;
        },
        .pairs => |pairs| pairsEql(want, pairs),
        .tag_sets => |sets| blk: {
            if (want != .array or want.array.items.len != sets.len) break :blk false;
            for (want.array.items, sets) |w, g| if (!pairsEql(w, g)) break :blk false;
            break :blk true;
        },
    };
}

fn pairsEql(want: json.Value, pairs: []const uri.Pair) bool {
    if (want != .object or want.object.count() != pairs.len) return false;
    for (pairs) |p| {
        const w = want.object.get(p.key) orelse return false;
        const text = switch (w) {
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            else => return false,
        };
        if (!std.mem.eql(u8, text, p.value)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// server-discovery-and-monitoring: single, rs, sharded, errors

const sdam = @import("sdam.zig");
const bson = @import("bson");

/// SDAM files skipped, with the reason.
const sdam_skipped = [_]struct { []const u8, []const u8 }{};

fn sdamSkip(path: []const u8) ?[]const u8 {
    for (sdam_skipped) |s| if (std.mem.endsWith(u8, path, s[0])) return s[1];
    return null;
}

/// A JSON value as BSON (through Extended JSON), in `arena`.
fn toBson(arena: std.mem.Allocator, v: json.Value) !bson.Document {
    const text = try json.Stringify.valueAlloc(arena, v, .{});
    return bson.Document.init(try bson.extjson.parse(arena, text));
}

test "spec: server discovery and monitoring (single, rs, sharded, errors)" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "single", "rs", "sharded", "errors" }) |dir| {
        try files.appendSlice(arena, try jsonFiles(arena, try std.fmt.allocPrint(arena, "server-discovery-and-monitoring/tests/{s}", .{dir})));
    }
    var tally: Tally = .{};
    var failures: usize = 0;
    for (files.items) |path| {
        if (sdamSkip(path)) |_| {
            tally.skipped += 1;
            continue;
        }
        runSdamFile(arena, path) catch |err| {
            failures += 1;
            std.debug.print("FAIL {s}: {t}\n", .{ path, err });
            continue;
        };
        tally.passed += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try tally.expect(177, 0);
}

fn runSdamFile(arena: std.mem.Allocator, path: []const u8) !void {
    const doc = try readJson(arena, path);
    const cs = try uri.parse(arena, field(doc, "uri").?.string, null);
    var seeds: std.ArrayList([]const u8) = .empty;
    for (cs.hosts) |h| try seeds.append(arena, try sdam.formatAddress(arena, h.name, h.port, h.kind == .unix));
    const single_dir = std.mem.indexOf(u8, path, "/single/") != null;
    var topology = try sdam.Topology.init(gpa, .{
        .seeds = seeds.items,
        .set_name = cs.string("replicaSet"),
        .direct = cs.boolean("directConnection") orelse (single_dir and seeds.items.len == 1),
    });
    defer topology.deinit();

    for (field(doc, "phases").?.array.items, 0..) |phase, phase_index| {
        if (field(phase, "responses")) |responses| for (responses.array.items) |pair| {
            const address = pair.array.items[0].string;
            const reply = pair.array.items[1];
            const d = if (reply.object.count() == 0)
                try sdam.unknown(gpa, address, "network error", null)
            else
                try sdam.describe(gpa, address, try toBson(arena, reply), 1_000_000);
            try topology.apply(d);
        };
        if (field(phase, "applicationErrors")) |errors| for (errors.array.items) |e| {
            const kind = field(e, "type").?.string;
            _ = try topology.handleError(.{
                .address = field(e, "address").?.string,
                .generation = if (field(e, "generation")) |g| @intCast(g.integer) else null,
                .max_wire_version = @intCast(field(e, "maxWireVersion").?.integer),
                .when = if (std.mem.eql(u8, field(e, "when").?.string, "beforeHandshakeCompletes")) .before_handshake else .after_handshake,
                .kind = if (std.mem.eql(u8, kind, "network")) .network else if (std.mem.eql(u8, kind, "timeout")) .timeout else .command,
                .response = if (field(e, "response")) |r| try toBson(arena, r) else null,
            });
        };
        // Requests and removals are the client's business.
        gpa.free(try topology.takeRemoved());
        const checks = try topology.takeCheckRequests();
        for (checks) |c| gpa.free(c);
        gpa.free(checks);
        checkSdamOutcome(arena, &topology, field(phase, "outcome").?) catch |err| {
            std.debug.print("  phase {d}: {s}\n", .{ phase_index, if (field(phase, "description")) |d| d.string else "" });
            return err;
        };
    }
}

fn checkSdamOutcome(arena: std.mem.Allocator, t: *sdam.Topology, outcome: json.Value) !void {
    if (field(outcome, "topologyType")) |want| if (!std.mem.eql(u8, want.string, t.type.specName())) {
        std.debug.print("  topologyType {s}, want {s}\n", .{ t.type.specName(), want.string });
        return error.TopologyType;
    };
    if (outcome.object.get("setName")) |want| {
        if (want == .null) {
            if (t.set_name != null) return error.SetName;
        } else if (t.set_name == null or !std.mem.eql(u8, want.string, t.set_name.?)) return error.SetName;
    }
    if (outcome.object.get("logicalSessionTimeoutMinutes")) |want| {
        if (want == .null) {
            if (t.logical_session_timeout_minutes != null) return error.SessionTimeout;
        } else if (t.logical_session_timeout_minutes != want.integer) return error.SessionTimeout;
    }
    if (field(outcome, "maxSetVersion")) |want| if (t.max_set_version != want.integer) return error.MaxSetVersion;
    if (field(outcome, "maxElectionId")) |want| {
        const id = try bson.ObjectId.parse(field(want, "$oid").?.string);
        if (t.max_election_id == null or !t.max_election_id.?.eql(id)) return error.MaxElectionId;
    }
    if (field(outcome, "compatible")) |want| if (want.bool != t.compatible) return error.Compatible;
    const servers = field(outcome, "servers") orelse return;
    if (servers.object.count() != t.servers.items.len) {
        std.debug.print("  {d} servers, want {d}\n", .{ t.servers.items.len, servers.object.count() });
        for (t.servers.items) |s| std.debug.print("    have {s}\n", .{s.description.address});
        return error.ServerCount;
    }
    var it = servers.object.iterator();
    while (it.next()) |e| {
        const s = t.find(e.key_ptr.*) orelse {
            std.debug.print("  no server {s}\n", .{e.key_ptr.*});
            return error.ServerMissing;
        };
        const want = e.value_ptr.*;
        const d = s.description;
        if (field(want, "type")) |ty| if (!std.mem.eql(u8, ty.string, d.type.specName())) {
            std.debug.print("  {s}: type {s}, want {s}\n", .{ d.address, d.type.specName(), ty.string });
            return error.ServerType;
        };
        if (want.object.get("setName")) |sn| {
            if (sn == .null) {
                if (d.set_name != null) return error.ServerSetName;
            } else if (d.set_name == null or !std.mem.eql(u8, sn.string, d.set_name.?)) return error.ServerSetName;
        }
        if (want.object.get("setVersion")) |v| {
            if (v == .null) {
                if (d.set_version != null) return error.ServerSetVersion;
            } else if (d.set_version != v.integer) return error.ServerSetVersion;
        }
        if (want.object.get("electionId")) |v| {
            if (v == .null) {
                if (d.election_id != null) return error.ServerElectionId;
            } else {
                const id = try bson.ObjectId.parse(field(v, "$oid").?.string);
                if (d.election_id == null or !d.election_id.?.eql(id)) return error.ServerElectionId;
            }
        }
        if (want.object.get("logicalSessionTimeoutMinutes")) |v| {
            if (v == .null) {
                if (d.logical_session_timeout_minutes != null) return error.ServerSessionTimeout;
            } else if (d.logical_session_timeout_minutes != v.integer) return error.ServerSessionTimeout;
        }
        if (field(want, "minWireVersion")) |v| if (d.min_wire_version != v.integer) return error.ServerWireVersion;
        if (field(want, "maxWireVersion")) |v| if (d.max_wire_version != v.integer) return error.ServerWireVersion;
        if (want.object.get("topologyVersion")) |v| {
            if (v == .null) {
                if (d.topology_version != null) return error.ServerTopologyVersion;
            } else {
                const tv = sdam.TopologyVersion.fromValue(.{ .document = try toBson(arena, v) }).?;
                if (d.topology_version == null or !d.topology_version.?.process_id.eql(tv.process_id) or d.topology_version.?.counter != tv.counter)
                    return error.ServerTopologyVersion;
            }
        }
        if (field(want, "pool")) |pool| if (s.generation != field(pool, "generation").?.integer) {
            std.debug.print("  {s}: generation {d}, want {d}\n", .{ d.address, s.generation, field(pool, "generation").?.integer });
            return error.PoolGeneration;
        };
        if (field(want, "error")) |msg| {
            const have = d.@"error" orelse return error.ServerError;
            if (std.mem.indexOf(u8, have, msg.string) == null) return error.ServerError;
        }
    }
}
