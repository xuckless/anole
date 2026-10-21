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

const testing = std.testing;
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
            try b.append("helloOk", .{ .boolean = true });
            try b.append("isWritablePrimary", .{ .boolean = true });
            try b.append("setName", .{ .string = "rs0" });
            try b.beginArray("hosts");
            try b.append("", .{ .string = f.addr() });
            try b.end();
            try b.append("me", .{ .string = f.addr() });
            try b.append("setVersion", .{ .int32 = 1 });
            try b.append("electionId", .{ .object_id = try .parse("7fffffff0000000000000001") });
            try b.append("minWireVersion", .{ .int32 = 0 });
            try b.append("maxWireVersion", .{ .int32 = 21 });
            try b.append("logicalSessionTimeoutMinutes", .{ .int32 = 30 });
            try b.append("ok", .{ .double = 1 });
        } else if (std.mem.eql(u8, command, "find")) {
            if (dec(&f.drop_finds)) return false;
            // Ten documents, four per batch: cursor 42.
            try f.batch(b, "firstBatch", 0, 42);
        } else if (std.mem.eql(u8, command, "getMore")) {
            const n = f.get_mores.fetchAdd(1, .monotonic);
            const start: i32 = @intCast(4 * (n % 2 + 1));
            try f.batch(b, "nextBatch", start, if (start + 4 >= 10) 0 else 42);
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
        _ = io;
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

test "fake mongod: discovery, cursors, retryable writes and reads, errors" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io);
    defer fake.deinit(io);

    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "mongodb://{s}/app?replicaSet=rs0&heartbeatFrequencyMS=500", .{fake.addr()});
    const client = try mongodb.Client.connect(gpa, io, .{ .url = url, .server_selection_timeout = .fromSeconds(5) });
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const users = client.collection("users");
    try testing.expectEqualStrings("app", users.database);

    // Every batch, through getMore.
    const rows = try users.find(Row, &c, .{}, .{ .batch_size = 4 });
    try testing.expectEqual(@as(usize, 10), rows.len);
    for (rows, 0..) |row, i| try testing.expectEqual(@as(i32, @intCast(i)), row.n);

    // A cursor left early is killed.
    fake.get_mores.store(0, .monotonic);
    var cursor = try users.iterate(Row, &c, .{}, .{});
    try testing.expectEqual(@as(i32, 0), (try cursor.next()).?.n);
    cursor.deinit();
    try testing.expectEqual(@as(u32, 1), fake.killed.load(.monotonic));

    // NotWritablePrimary with RetryableWriteError: sent again, with the
    // same session and transaction number.
    fake.fail_inserts.store(1, .monotonic);
    const r = try users.insertOne(&c, .{ .name = "Ada" });
    try testing.expect(r.objectId() != null);
    try testing.expectEqual(@as(u32, 2), fake.inserts.load(.monotonic));
    try testing.expect(fake.txn_numbers[0] >= 1);
    try testing.expectEqual(fake.txn_numbers[0], fake.txn_numbers[1]);
    try testing.expectEqualSlices(u8, &fake.lsids[0], &fake.lsids[1]);
    // The next write is a new statement.
    _ = try users.insertOne(&c, .{ .name = "Grace" });
    try testing.expectEqual(fake.txn_numbers[1] + 1, fake.txn_numbers[2]);

    // Twice: the retry fails as well, and the call with it.
    fake.fail_inserts.store(2, .monotonic);
    try testing.expectError(error.ServiceUnavailable, users.insertOne(&c, .{ .name = "Linus" }));
    try testing.expectEqualStrings("10107", db.lastError(&c).?.code);

    // A duplicate key: a Conflict, not retried.
    const before = fake.inserts.load(.monotonic);
    try testing.expectError(error.Conflict, users.insertOne(&c, .{ .dup = true }));
    try testing.expectEqual(before + 1, fake.inserts.load(.monotonic));
    try testing.expectEqual(db.Class.unique, db.lastError(&c).?.class);

    // The connection dropped mid-read: retried on a new one (after the
    // server is found again).
    fake.drop_finds.store(1, .monotonic);
    try testing.expectEqual(@as(i32, 0), (try users.findOne(Row, &c, .{}, .{})).n);

    try client.ping(&c);
}

test "fake mongod: no server, a timeout and a bad connection string" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    // Nothing listens on port 1: server selection gives up, 503.
    const client = try mongodb.Client.connect(gpa, io, .{ .url = "mongodb://127.0.0.1:1/?serverSelectionTimeoutMS=300&connectTimeoutMS=200" });
    defer client.deinit();
    try testing.expectError(error.ServiceUnavailable, client.ping(&c));
    try testing.expectEqual(db.Class.unavailable, db.lastError(&c).?.class);
    // A timeout of the call's own, shorter than server selection: 504.
    try testing.expectError(error.GatewayTimeout, client.db("admin").with(.{ .timeout = .fromMilliseconds(50) }).runCommand(&c, .{ .ping = 1 }));

    try testing.expectError(error.InvalidUri, mongodb.Client.connect(gpa, io, .{ .url = "mongodb://host:99999/" }));
    try testing.expectError(error.Unsupported, mongodb.Client.connect(gpa, io, .{ .url = "mongodb://host/?readPreference=secondary" }));
    try testing.expectError(error.Unsupported, mongodb.Client.connect(gpa, io, .{ .url = "mongodb+srv://cluster.example.com/" }));
}
