//! The client against a fake mongod in the test process: a replica set
//! member of one that speaks OP_MSG and answers a handful of commands
//! (hello, find and getMore in small batches, insert, killCursors, ping),
//! with failures on request. It runs in every `zig build test`; the live
//! tests (live_test.zig) cover the real servers.
const std = @import("std");
const zio = @import("zio");
const bson = @import("bson");
const db = @import("../db/root.zig");
const wire = @import("wire.zig");
const mongodb = @import("root.zig");
const client_mod = @import("client.zig");
const dusty = @import("dusty");

const testing = std.testing;
const wait = @import("anole_test_wait");
const safety = @import("anole_safety");
const gpa = testing.allocator;

const Fake = struct {
    listener: std.Io.net.Server,
    address: [32]u8 = undefined,
    address_len: usize = 0,
    group: std.Io.Group = .init,
    /// Fail the next inserts with NotWritablePrimary (a retryable write
    /// error), or drop the connection on the next finds.
    fail_inserts: std.atomic.Value(u32) = .init(0),
    drop_finds: std.atomic.Value(u32) = .init(0),
    inserts: std.atomic.Value(u32) = .init(0),
    /// The txnNumbers and session ids the inserts came with.
    txn_numbers: [8]i64 = @splat(-1),
    lsids: [8][16]u8 = undefined,
    killed: std.atomic.Value(u32) = .init(0),
    get_mores: std.atomic.Value(u32) = .init(0),
    /// Finds answered; while `find_gate` is set to an event, each find
    /// waits for it before answering.
    finds: std.atomic.Value(u32) = .init(0),
    find_gate: std.atomic.Value(?*std.Io.Event) = .init(null),
    /// The stress test's other member. A primary with `alternate` lists itself
    /// alone and itself with `peer` on alternate hellos; a `secondary`
    /// lists `peer` (the primary) and itself.
    peer: ?*Fake = null,
    alternate: bool = false,
    secondary: bool = false,
    hellos: std.atomic.Value(u32) = .init(0),

    fn init(f: *Fake, io: std.Io) !void {
        const listen_at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        f.* = .{ .listener = try listen_at.listen(io, .{}) };
        f.address_len = (try std.fmt.bufPrint(&f.address, "127.0.0.1:{d}", .{f.listener.socket.address.getPort()})).len;
        try f.group.concurrent(io, acceptLoop, .{ f, io });
    }

    fn deinit(f: *Fake, io: std.Io) void {
        f.group.cancel(io);
        f.listener.deinit(io);
    }

    fn addr(f: *const Fake) []const u8 {
        return f.address[0..f.address_len];
    }

    fn acceptLoop(f: *Fake, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            const conn = f.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // A client that gave up before the accept (a monitor
                // canceled mid-connect): the next one is still served.
                error.ConnectionAborted => continue,
                else => return,
            };
            f.group.concurrent(io, serve, .{ f, io, conn }) catch conn.close(io);
        }
    }

    fn serve(f: *Fake, io: std.Io, conn: std.Io.net.Stream) std.Io.Cancelable!void {
        defer conn.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var w = conn.writer(io, &wbuf);
        var in: std.ArrayList(u8) = .empty;
        defer in.deinit(gpa);
        var b: bson.Builder = .init(gpa);
        defer b.deinit();
        while (true) {
            const bytes = wire.read(&r.interface, gpa, &in, 48_000_000) catch return;
            const msg = wire.parse(bytes) catch return;
            const keep = f.answer(io, &b, msg) catch return;
            if (!keep) return;
            w.interface.writeAll(b.buf.items) catch return;
            w.interface.flush() catch return;
        }
    }

    /// Builds the reply to `msg` in `b`; false drops the connection.
    fn answer(f: *Fake, io: std.Io, b: *bson.Builder, msg: wire.Reply) !bool {
        var m = try wire.Message.begin(b);
        var it = msg.body.iterator();
        const command = it.next().?.name;
        if (std.mem.eql(u8, command, "isMaster") or std.mem.eql(u8, command, "hello")) {
            const n = f.hellos.fetchAdd(1, .acq_rel);
            try b.append("helloOk", .{ .boolean = true });
            try b.append("isWritablePrimary", .{ .boolean = !f.secondary });
            if (f.secondary) try b.append("secondary", .{ .boolean = true });
            try b.append("setName", .{ .string = "rs0" });
            try b.beginArray("hosts");
            if (f.secondary) try b.append("", .{ .string = f.peer.?.addr() });
            try b.append("", .{ .string = f.addr() });
            if (f.alternate and n % 2 == 1) try b.append("", .{ .string = f.peer.?.addr() });
            try b.end();
            try b.append("me", .{ .string = f.addr() });
            if (!f.secondary) {
                try b.append("setVersion", .{ .int32 = 1 });
                try b.append("electionId", .{ .object_id = try .parse("7fffffff0000000000000001") });
            }
            try b.append("minWireVersion", .{ .int32 = 0 });
            try b.append("maxWireVersion", .{ .int32 = 21 });
            try b.append("logicalSessionTimeoutMinutes", .{ .int32 = 30 });
            try b.append("ok", .{ .double = 1 });
        } else if (std.mem.eql(u8, command, "find")) {
            if (dec(&f.drop_finds)) return false;
            _ = f.finds.fetchAdd(1, .monotonic);
            if (f.find_gate.load(.acquire)) |gate| try gate.wait(io);
            // Ten documents, four per batch. The cursor id is where the
            // next batch starts, so cursors running at once stay apart.
            try f.batch(b, "firstBatch", 0, 4);
        } else if (std.mem.eql(u8, command, "getMore")) {
            _ = f.get_mores.fetchAdd(1, .monotonic);
            const start: i32 = @intCast(msg.body.get("getMore").?.int64);
            try f.batch(b, "nextBatch", start, if (start + 4 >= 10) 0 else start + 4);
        } else if (std.mem.eql(u8, command, "killCursors")) {
            _ = f.killed.fetchAdd(1, .monotonic);
            try b.append("ok", .{ .double = 1 });
        } else if (std.mem.eql(u8, command, "insert")) {
            const i = f.inserts.fetchAdd(1, .monotonic);
            if (i < f.txn_numbers.len) {
                f.txn_numbers[i] = if (msg.body.get("txnNumber")) |v| v.int64 else -1;
                if (msg.body.getPath("lsid.id")) |v| @memcpy(&f.lsids[i], v.binary.data[0..16]);
            }
            var docs = msg.sequence("documents");
            const first = docs.next().?;
            if (dec(&f.fail_inserts)) {
                try b.append("ok", .{ .double = 0 });
                try b.append("code", .{ .int32 = 10107 });
                try b.append("codeName", .{ .string = "NotWritablePrimary" });
                try b.append("errmsg", .{ .string = "not primary" });
                try b.beginArray("errorLabels");
                try b.append("", .{ .string = "RetryableWriteError" });
                try b.end();
            } else if (first.get("dup") != null) {
                try b.append("n", .{ .int32 = 0 });
                try b.beginArray("writeErrors");
                try b.beginDocument("");
                try b.append("index", .{ .int32 = 0 });
                try b.append("code", .{ .int32 = 11000 });
                try b.append("errmsg", .{ .string = "E11000 duplicate key error collection: app.users index: email_1" });
                try b.end();
                try b.end();
                try b.append("ok", .{ .double = 1 });
            } else {
                try b.append("n", .{ .int32 = 1 });
                try b.append("ok", .{ .double = 1 });
            }
        } else {
            try b.append("ok", .{ .double = 1 });
        }
        try m.endBody();
        const bytes = try m.finish(9);
        std.mem.writeInt(i32, b.buf.items[8..12], msg.header.request_id, .little);
        _ = bytes;
        return true;
    }

    fn batch(_: *Fake, b: *bson.Builder, name: []const u8, start: i32, id: i64) !void {
        try b.beginDocument("cursor");
        try b.append("id", .{ .int64 = id });
        try b.append("ns", .{ .string = "app.users" });
        try b.beginArray(name);
        var i = start;
        while (i < @min(start + 4, 10)) : (i += 1) {
            try b.beginDocument("");
            try b.append("n", .{ .int32 = i });
            try b.end();
        }
        try b.end();
        try b.end();
        try b.append("ok", .{ .double = 1 });
    }

    fn dec(v: *std.atomic.Value(u32)) bool {
        var n = v.load(.monotonic);
        while (n > 0) : (n = v.load(.monotonic)) {
            if (v.cmpxchgWeak(n, n - 1, .monotonic, .monotonic) == null) return true;
        }
        return false;
    }
};

const Row = struct { n: i32 };

/// A client of the fake, as a replica set of one.
fn open(io: std.Io, fake: *Fake) !*mongodb.Client {
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "mongodb://{s}/app?replicaSet=rs0&heartbeatFrequencyMS=500", .{fake.addr()});
    return mongodb.Client.init(gpa, io, .{ .url = url, .server_selection_timeout = .fromSeconds(5) });
}

test "fake mongod: find reads every batch through getMore" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    try testing.expectEqualStrings("app", users.database);
    const rows = try users.find(Row, &c, .{}, .{ .batch_size = 4 });
    try testing.expectEqual(@as(usize, 10), rows.len);
    for (rows, 0..) |row, i| try testing.expectEqual(@as(i32, @intCast(i)), row.n);
}

test "fake mongod: the shared verbs are the same calls, and with() hands its options to the databases and collections it leads to" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    try testing.expectEqual(@as(usize, 10), (try users.all(Row, &c, .{}, .{ .batch_size = 4 })).len);
    try testing.expectEqual(@as(i32, 0), (try users.one(Row, &c, .{}, .{})).n);
    try testing.expectEqual(@as(i32, 0), (try users.optional(Row, &c, .{}, .{})).?.n);
    const timed = client.with(.{ .timeout = .fromSeconds(5) }).collection("users");
    try testing.expect(timed.options.timeout != null);
    try testing.expectEqualStrings("app", timed.database);
    try testing.expectEqual(@as(usize, 10), (try timed.all(Row, &c, .{}, .{ .batch_size = 4 })).len);
    try testing.expect(client.with(.{ .coalesce = true }).db("app").collection("users").options.coalesce);
}

test "fake mongod: a cursor left early is killed" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    var cursor = try users.iterate(Row, &c, .{}, .{});
    try testing.expectEqual(@as(i32, 0), (try cursor.next()).?.n);
    cursor.deinit();
    try testing.expectEqual(@as(u32, 1), fake.killed.load(.monotonic));
}

test "fake mongod: a retryable write error is sent again with the same session and txnNumber; the next write is a new statement" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    fake.fail_inserts.store(1, .monotonic);
    const r = try users.insertOne(&c, .{ .name = "Ada" });
    try testing.expect(r.objectId() != null);
    try testing.expectEqual(@as(u32, 2), fake.inserts.load(.monotonic));
    try testing.expect(fake.txn_numbers[0] >= 1);
    try testing.expectEqual(fake.txn_numbers[0], fake.txn_numbers[1]);
    try testing.expectEqualSlices(u8, &fake.lsids[0], &fake.lsids[1]);
    _ = try users.insertOne(&c, .{ .name = "Grace" });
    try testing.expectEqual(fake.txn_numbers[1] + 1, fake.txn_numbers[2]);
}

test "fake mongod: a retried write that fails again is a 503 with the server's code" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    // A warning the test expects, kept out of its output.
    fake.fail_inserts.store(2, .monotonic);
    {
        const level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = level;
        try testing.expectError(error.ServiceUnavailable, users.insertOne(&c, .{ .name = "Linus" }));
    }
    try testing.expectEqualStrings("10107", db.lastError(&c).?.code);
}

test "fake mongod: a duplicate key is a Conflict, not retried" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    const before = fake.inserts.load(.monotonic);
    try testing.expectError(error.Conflict, users.insertOne(&c, .{ .dup = true }));
    try testing.expectEqual(before + 1, fake.inserts.load(.monotonic));
    try testing.expectEqual(db.Class.unique, db.lastError(&c).?.class);
}

test "fake mongod: a read whose connection dropped is retried on a new one" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    fake.drop_finds.store(1, .monotonic);
    try testing.expectEqual(@as(i32, 0), (try users.findOne(Row, &c, .{}, .{})).n);
    try client.ping(&c);
}

test "fake mongod: an unreachable server is a 503, a call's own shorter timeout a 504" {
    // Every call here fails on purpose, and logs a warning saying why.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    // Nothing listens on port 1: server selection gives up, 503.
    const client = try mongodb.Client.init(gpa, io, .{ .url = "mongodb://127.0.0.1:1/?serverSelectionTimeoutMS=300&connectTimeoutMS=200" });
    defer client.deinit();
    try testing.expectError(error.ServiceUnavailable, client.ping(&c));
    try testing.expectEqual(db.Class.unavailable, db.lastError(&c).?.class);
    // A timeout of the call's own, 250 ms shorter than server selection
    // (slack for a runner whose timers fire late): 504.
    try testing.expectError(error.GatewayTimeout, client.db("admin").with(.{ .timeout = .fromMilliseconds(50) }).runCommand(&c, .{ .ping = 1 }));
}

test "mongodb: a bad connection string, and a URL that would turn off TLS the code asks for, are refused" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    try testing.expectError(error.InvalidUri, mongodb.Client.init(gpa, io, .{ .url = "mongodb://host:99999/" }));
    try testing.expectError(error.Unsupported, mongodb.Client.init(gpa, io, .{ .url = "mongodb://host/?readPreference=secondary" }));
    try testing.expectError(error.Unsupported, mongodb.Client.init(gpa, io, .{ .url = "mongodb+srv://cluster.example.com/" }));
    // TLS that the code asks for, which the URL would turn off or stop
    // verifying: refused, not overridden.
    for ([_][]const u8{
        "mongodb://host/?tls=false",
        "mongodb://host/?ssl=false",
        "mongodb://host/?tlsInsecure=true",
        "mongodb://host/?tlsAllowInvalidCertificates=true",
        "mongodb://host/?tlsAllowInvalidHostnames=true",
    }) |url| {
        try testing.expectError(error.InvalidUri, mongodb.Client.init(gpa, io, .{ .url = url, .tls = .{ .ca = .system } }));
    }
}

test "mongodb: max_connections = 0 and a URL's maxPoolSize=0 are InvalidOptions" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    try testing.expectError(error.InvalidOptions, mongodb.Client.init(gpa, io, .{ .url = "mongodb://127.0.0.1:1/", .max_connections = 0 }));
    try testing.expectError(error.InvalidOptions, mongodb.Client.init(gpa, io, .{ .url = "mongodb://127.0.0.1:1/?maxPoolSize=0" }));
}

test "mongodb: connect_at_start fails start when nothing listens" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const client = try mongodb.Client.init(gpa, io, .{
        .url = "mongodb://127.0.0.1:1/?connectTimeoutMS=200",
        .server_selection_timeout = .fromMilliseconds(200),
        .connect_at_start = true,
    });
    defer client.deinit();
    try testing.expectError(error.ServiceUnavailable, client.start(null, null, null));
}

test "fake mongod: coalesced and cached reads, invalidation" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);

    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // Found before the counting starts.
    try client.ping(&c);

    // 8 callers on each of 2 executors: one find per executor. Each find
    // waits for the gate, so every caller joins one in flight however
    // slow the machine is.
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    fake.find_gate.store(&gate, .release);
    defer fake.find_gate.store(null, .release);
    const Worker = struct {
        fn run(coll: mongodb.Collection, io_: std.Io, bad: *std.atomic.Value(u32)) void {
            var a: std.heap.ArenaAllocator = .init(gpa);
            defer a.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = a.allocator() };
            const rows = coll.with(.{ .coalesce = true }).find(Row, &ctx, .{ .active = true }, .{ .batch_size = 4 }) catch {
                _ = bad.fetchAdd(1, .monotonic);
                return;
            };
            if (rows.len != 10 or rows[9].n != 9) _ = bad.fetchAdd(1, .monotonic);
        }
    };
    var bad: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |i| try @import("dusty").placement.concurrent(&group, io, .{ .executor = i % 2 }, Worker.run, .{ users, io, &bad });
    const Joined = struct {
        fn f(cl: *mongodb.Client) bool {
            return cl.cache.stats().coalesced >= 14;
        }
    };
    try wait.waitUntil(io, "the 14 identical finds joined the two in flight", client, Joined.f);
    gate.set(io);
    try group.await(io);
    fake.find_gate.store(null, .release);
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fake.finds.load(.monotonic));
    try testing.expectEqual(@as(u64, 14), client.cache.stats().coalesced);

    // Cached: one find until invalidated. Another filter is another key,
    // and so is the same value under another field name.
    const cached = users.with(.{ .cache = .{ .ttl = .fromSeconds(60), .tag = "users" } });
    fake.finds.store(0, .monotonic);
    try testing.expectEqual(@as(i32, 0), (try cached.findOne(Row, &c, .{ .name = "Ada" }, .{})).n);
    try testing.expectEqual(@as(i32, 0), (try cached.findOne(Row, &c, .{ .name = "Ada" }, .{})).n);
    try testing.expectEqual(@as(usize, 10), (try cached.find(Row, &c, .{ .name = "Ada" }, .{})).len);
    try testing.expectEqual(@as(u32, 2), fake.finds.load(.monotonic));
    _ = try cached.findOne(Row, &c, .{ .email = "Ada" }, .{});
    try testing.expectEqual(@as(u32, 3), fake.finds.load(.monotonic));
    client.cache.invalidate(.{ .tag = "users" });
    _ = try cached.findOne(Row, &c, .{ .name = "Ada" }, .{});
    try testing.expectEqual(@as(u32, 4), fake.finds.load(.monotonic));
    // A plain find is never cached.
    _ = try users.findOne(Row, &c, .{ .name = "Ada" }, .{});
    _ = try users.findOne(Row, &c, .{ .name = "Ada" }, .{});
    try testing.expectEqual(@as(u32, 6), fake.finds.load(.monotonic));
}

test "mongodb: with(options).dynamic is the dynamic runner with the context first" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    // The server found first, as an app's first call after start finds it.
    try client.ping(&c);
    _ = users;
    var b: bson.Builder = .init(arena.allocator());
    try b.begin();
    try b.end();
    const empty: bson.Document = .{ .bytes = b.bytes() };
    const found = try client.with(.{}).dynamic(&c, .find, "users", &.{empty});
    try testing.expectEqual(@as(usize, 10), found.documents.len);

    var d: bson.Builder = .init(arena.allocator());
    try d.begin();
    try d.append("name", .{ .string = "Ada" });
    try d.end();
    const inserted = try client.with(.{}).dynamic(&c, .insertOne, "users", &.{.{ .bytes = d.bytes() }});
    try testing.expectEqual(@as(u64, 1), inserted.write.changes);
    try testing.expect(inserted.write.summary.get("insertedId") != null);
}

/// The spawn test's hook: a yield right after a monitor's spawn, as the spawn itself
/// yields on a busy executor (zio's run-queue threshold). The executor is
/// busy: the new monitor waits in its run queue.
const SpawnYield = struct {
    var ran: std.atomic.Value(bool) = .init(false);
    /// The locks the spawning task held at the spawn.
    var held: std.atomic.Value(usize) = .init(0);

    fn yield(io: std.Io) void {
        held.store(safety.heldLocks(), .release);
        ran.store(true, .release);
        zio.yield() catch io.recancel();
    }

    fn openAndPing(fake: *Fake, io: std.Io, failure: *?anyerror) void {
        run(fake, io) catch |err| {
            failure.* = err;
        };
    }

    fn run(fake: *Fake, io: std.Io) !void {
        const client = try open(io, fake);
        defer client.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
        try client.ping(&c);
    }
};

test "mongodb: a monitor started while the executor is busy does not suspend under the topology lock" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    SpawnYield.ran.store(false, .release);
    SpawnYield.held.store(0, .release);
    client_mod.test_after_monitor_spawn = SpawnYield.yield;
    defer client_mod.test_after_monitor_spawn = null;
    // On executor 0, where the monitor is spawned.
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var failure: ?anyerror = null;
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, SpawnYield.openAndPing, .{ &fake, io, &failure });
    try group.await(io);
    if (failure) |err| return err;
    // A monitor was spawned, and its spawn (which may yield) ran with no
    // lock held.
    try testing.expect(SpawnYield.ran.load(.acquire));
    try testing.expectEqual(@as(usize, 0), SpawnYield.held.load(.acquire));
}

/// The close test's hooks: a monitor's end, watched from `deinit` without suspending.
const MonitorEnd = struct {
    var closed: std.atomic.Value(bool) = .init(false);
    var held: std.atomic.Value(bool) = .init(false);
    /// `hold` gave up waiting: the monitor did not end on its own.
    var timed_out: std.atomic.Value(bool) = .init(false);

    fn monitorClosed(_: *client_mod.Server) void {
        closed.store(true, .release);
    }

    /// Wakes the server's monitor, which ends (the client is closing) and
    /// closes its connection, and waits until it has without suspending:
    /// `deinit` runs on another executor than the monitor. The wait
    /// deadline is a hang guard.
    fn hold(s: *client_mod.Server) void {
        const io = s.client.io;
        held.store(true, .release);
        s.check_now.set(io);
        const until = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = wait.deadline(), .clock = .awake });
        while (!closed.load(.acquire)) {
            if (until.untilNow(io).raw.nanoseconds >= 0) return timed_out.store(true, .release);
            std.Thread.yield() catch {};
        }
    }

    fn close(client: *mongodb.Client) void {
        client.deinit();
    }
};

test "mongodb: closing the client while a monitor ends frees the monitor's connection once" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    var open_client: ?*mongodb.Client = client;
    defer if (open_client) |cl| cl.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    // A primary found: the monitor has checked the server, and holds its
    // connection.
    try client.ping(&c);

    MonitorEnd.closed.store(false, .release);
    MonitorEnd.held.store(false, .release);
    MonitorEnd.timed_out.store(false, .release);
    client_mod.test_monitor_closed = MonitorEnd.monitorClosed;
    defer client_mod.test_monitor_closed = null;
    client_mod.test_close_hold = MonitorEnd.hold;
    defer client_mod.test_close_hold = null;
    // `deinit` on executor 1; the monitor runs on executor 0.
    open_client = null;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try dusty.placement.concurrent(&group, io, .{ .executor = 1 }, MonitorEnd.close, .{client});
    try group.await(io);
    // `deinit` held while the monitor ended on its own and closed its
    // connection, then freed the rest.
    try testing.expect(MonitorEnd.held.load(.acquire));
    try testing.expect(!MonitorEnd.timed_out.load(.acquire));
    try testing.expect(MonitorEnd.closed.load(.acquire));
}

/// One task's finds on a client of the two fakes.
const Finder = struct {
    fn run(client: *mongodb.Client, io: std.Io, finds: u32, failures: *std.atomic.Value(u32)) void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
        const users = client.collection("users");
        for (0..finds) |_| {
            _ = arena.reset(.retain_capacity);
            _ = users.findOne(Row, &c, .{}, .{}) catch {
                _ = failures.fetchAdd(1, .monotonic);
            };
        }
    }
};

const HelloWait = struct {
    fake: *Fake,
    from: u32,

    fn twiceMore(w: HelloWait) bool {
        return w.fake.hellos.load(.acquire) >= w.from + 2;
    }
};

test "mongodb: [stress] servers joining and leaving while calls run and the client closes" {
    try wait.requireStress();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var a: Fake = undefined;
    try a.init(io);
    defer a.deinit(io);
    var b: Fake = undefined;
    try b.init(io);
    defer b.deinit(io);
    // A's hellos list A alone, then A and B, and so on: B's monitor
    // starts when it joins and stops when it leaves.
    a.peer = &b;
    a.alternate = true;
    b.peer = &a;
    b.secondary = true;

    const seed: u64 = 0x53_0d1e;
    errdefer std.debug.print("mongodb stress: seed 0x{x}\n", .{seed});
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var failures: std.atomic.Value(u32) = .init(0);
    for (0..100) |_| {
        // Server selection waits up to the hang guard: the claim is that a
        // find always finds the primary, not how soon on a loaded machine.
        var url_buf: [96]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "mongodb://{s}/app?replicaSet=rs0&heartbeatFrequencyMS=500", .{a.addr()});
        const client = try mongodb.Client.init(gpa, io, .{ .url = url, .server_selection_timeout = wait.deadline() });
        defer client.deinit();
        const from = a.hellos.load(.acquire);
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..4) |t| try dusty.placement.concurrent(&group, io, .{ .executor = t % 2 }, Finder.run, .{ client, io, random.intRangeAtMost(u32, 1, 40), &failures });
        // Half the rounds last until A answered two more hellos, so its
        // monitor's next check (a heartbeat later) moves B in or out
        // while the calls run; the rest close at once.
        if (random.boolean()) try wait.waitUntil(io, "two more hellos from A", HelloWait{ .fake = &a, .from = from }, HelloWait.twiceMore);
        try group.await(io);
    }
    // A stays the primary throughout: every find succeeds. The rest of the
    // claim is no fault and no leak (the test allocator).
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}
