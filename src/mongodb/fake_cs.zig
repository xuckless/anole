//! A fake replica-set member that scripts change streams: it answers
//! `hello`, and every `aggregate` and `getMore` with the next step of a
//! script, recording the commands it got. Tests of change streams
//! (below) and of `anole.watch` over MongoDB use it; the live tests
//! (live_test.zig) cover the real servers.
const std = @import("std");
const zio = @import("zio");
const bson = @import("bson");
const db = @import("../db/root.zig");
const wire = @import("wire.zig");
const mongodb = @import("root.zig");
const cs = @import("change_stream.zig");

const testing = std.testing;
const gpa = testing.allocator;

pub const Step = union(enum) {
    /// A batch of events. An id above 0 makes an event with `_id`
    /// `{_data: "t<id>"}`; 0 an event with no `_id`; below 0 one whose
    /// `_id` is a string.
    batch: struct {
        ids: []const i32 = &.{},
        cursor: i64 = 7,
        pbrt: ?[]const u8 = null,
    },
    fail: struct {
        code: i32,
        name: []const u8 = "Error",
        labels: []const []const u8 = &.{},
    },
};

pub const Fake = struct {
    listener: std.Io.net.Server,
    address: [32]u8 = undefined,
    address_len: usize = 0,
    group: std.Io.Group = .init,
    script: []const Step = &.{},
    next_step: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// The aggregate and getMore command bodies, in order (BSON, owned).
    commands: std.ArrayList([]u8) = .empty,
    killed: std.atomic.Value(u32) = .init(0),

    pub fn init(f: *Fake, io: std.Io, script: []const Step) !void {
        const listen_at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        f.* = .{ .listener = try listen_at.listen(io, .{}), .script = script };
        f.address_len = (try std.fmt.bufPrint(&f.address, "127.0.0.1:{d}", .{f.listener.socket.address.getPort()})).len;
        try f.group.concurrent(io, acceptLoop, .{ f, io });
    }

    pub fn deinit(f: *Fake, io: std.Io) void {
        f.group.cancel(io);
        f.listener.deinit(io);
        for (f.commands.items) |c| gpa.free(c);
        f.commands.deinit(gpa);
    }

    pub fn addr(f: *const Fake) []const u8 {
        return f.address[0..f.address_len];
    }

    /// The nth recorded command.
    pub fn command(f: *Fake, io: std.Io, n: usize) bson.Document {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return .{ .bytes = f.commands.items[n] };
    }

    pub fn commandCount(f: *Fake, io: std.Io) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.commands.items.len;
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
            f.answer(io, &b, msg) catch return;
            w.interface.writeAll(b.buf.items) catch return;
            w.interface.flush() catch return;
        }
    }

    fn answer(f: *Fake, io: std.Io, b: *bson.Builder, msg: wire.Reply) !void {
        var m = try wire.Message.begin(b);
        var it = msg.body.iterator();
        const name = it.next().?.name;
        if (std.mem.eql(u8, name, "isMaster") or std.mem.eql(u8, name, "hello")) {
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
        } else if (std.mem.eql(u8, name, "aggregate") or std.mem.eql(u8, name, "getMore")) {
            const copy = try gpa.dupe(u8, msg.body.bytes);
            {
                f.mutex.lockUncancelable(io);
                defer f.mutex.unlock(io);
                f.commands.append(gpa, copy) catch {
                    gpa.free(copy);
                    return error.OutOfMemory;
                };
            }
            const i = f.next_step.fetchAdd(1, .monotonic);
            const first = std.mem.eql(u8, name, "aggregate");
            if (i < f.script.len) {
                switch (f.script[i]) {
                    .batch => |bt| try writeBatch(b, first, bt.cursor, bt.ids, bt.pbrt),
                    .fail => |fl| {
                        try b.append("ok", .{ .double = 0 });
                        try b.append("code", .{ .int32 = fl.code });
                        try b.append("codeName", .{ .string = fl.name });
                        try b.append("errmsg", .{ .string = "scripted failure" });
                        if (fl.labels.len > 0) {
                            try b.beginArray("errorLabels");
                            for (fl.labels) |l| try b.append("", .{ .string = l });
                            try b.end();
                        }
                    },
                }
            } else {
                // The script is over: an open cursor with nothing to say.
                try io.sleep(.fromMilliseconds(20), .awake);
                try writeBatch(b, first, 7, &.{}, null);
            }
        } else if (std.mem.eql(u8, name, "killCursors")) {
            _ = f.killed.fetchAdd(1, .monotonic);
            try b.append("ok", .{ .double = 1 });
        } else {
            try b.append("ok", .{ .double = 1 });
        }
        try m.endBody();
        _ = try m.finish(9);
        std.mem.writeInt(i32, b.buf.items[8..12], msg.header.request_id, .little);
    }

    fn writeBatch(b: *bson.Builder, first: bool, cursor: i64, ids: []const i32, pbrt: ?[]const u8) !void {
        try b.beginDocument("cursor");
        try b.append("id", .{ .int64 = cursor });
        try b.append("ns", .{ .string = "app.users" });
        try b.beginArray(if (first) "firstBatch" else "nextBatch");
        for (ids) |id| {
            try b.beginDocument("");
            if (id > 0) {
                try b.beginDocument("_id");
                var tok: [16]u8 = undefined;
                try b.append("_data", .{ .string = try std.fmt.bufPrint(&tok, "t{d}", .{id}) });
                try b.end();
            } else if (id < 0) try b.append("_id", .{ .string = "bad" });
            try b.append("operationType", .{ .string = "insert" });
            try b.beginDocument("ns");
            try b.append("db", .{ .string = "app" });
            try b.append("coll", .{ .string = "users" });
            try b.end();
            try b.beginDocument("documentKey");
            try b.append("_id", .{ .int32 = id });
            try b.end();
            try b.beginDocument("fullDocument");
            try b.append("_id", .{ .int32 = id });
            try b.append("x", .{ .int32 = id * 10 });
            try b.end();
            try b.end();
        }
        try b.end();
        if (pbrt) |p| {
            try b.beginDocument("postBatchResumeToken");
            try b.append("_data", .{ .string = p });
            try b.end();
        }
        try b.end();
        if (first) try b.append("operationTime", .{ .timestamp = .{ .t = 1000, .i = 1 } });
        try b.append("ok", .{ .double = 1 });
    }
};

fn open(io: std.Io, fake: *Fake) !*mongodb.Client {
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "mongodb://{s}/app?replicaSet=rs0&heartbeatFrequencyMS=500", .{fake.addr()});
    return mongodb.Client.init(gpa, io, .{ .url = url, .server_selection_timeout = .fromSeconds(5) });
}

fn tokenData(d: bson.Document) []const u8 {
    return d.get("_data").?.string;
}

fn pipelineStage(cmd: bson.Document, n: usize) bson.Document {
    var it = cmd.get("pipeline").?.array.iterator();
    var i: usize = 0;
    while (it.next()) |v| : (i += 1) if (i == n) return v.document;
    unreachable;
}

test "change stream: the aggregate carries the options, user stages and batch size; getMore its maxTimeMS; tokens are cached" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, &.{
        .{ .batch = .{ .ids = &.{ 1, 2 }, .pbrt = "p1" } },
        .{ .batch = .{ .ids = &.{3}, .pbrt = "p2" } },
        .{ .batch = .{ .ids = &.{}, .pbrt = "p3" } },
    });
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    var s = try client.collection("users").watch(cs.ChangeEvent, &c, .{.{ .@"$match" = .{ .operationType = "insert" } }}, .{
        .full_document = .update_lookup,
        .batch_size = 5,
        .max_await = .fromMilliseconds(250),
    });
    defer s.deinit();

    const agg = fake.command(io, 0);
    try testing.expectEqualStrings("users", agg.get("aggregate").?.string);
    const stage0 = pipelineStage(agg, 0).get("$changeStream").?.document;
    try testing.expectEqualStrings("updateLookup", stage0.get("fullDocument").?.string);
    try testing.expectEqualStrings("insert", pipelineStage(agg, 1).getPath("$match.operationType").?.string);
    try testing.expectEqual(@as(i32, 5), agg.getPath("cursor.batchSize").?.int32);

    // The _id of each event is the token, the batch's postBatchResumeToken
    // takes over at the end of the batch.
    const e1 = (try s.next()).?;
    try testing.expectEqualStrings("t1", tokenData(e1._id));
    var tok = (try s.resumeToken(arena.allocator())).?;
    try testing.expectEqualStrings("t1", tokenData(tok));
    _ = (try s.next()).?;
    tok = (try s.resumeToken(arena.allocator())).?;
    try testing.expectEqualStrings("t2", tokenData(tok));
    // Reading the first batch through moves to its post-batch token only
    // when the next read starts: the getMore.
    const e3 = (try s.next()).?;
    try testing.expectEqualStrings("t3", tokenData(e3._id));
    const more = fake.command(io, 1);
    try testing.expectEqual(@as(i64, 250), more.get("maxTimeMS").?.int64);
    try testing.expectEqualStrings("users", more.get("collection").?.string);
    try testing.expect((try s.tryNext()) == null);
    tok = (try s.resumeToken(arena.allocator())).?;
    try testing.expectEqualStrings("p3", tokenData(tok));
}

test "change stream: a resumable error resumes once with the cached token; startAfter stays before any event" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, &.{
        .{ .batch = .{ .ids = &.{1} } },
        .{ .fail = .{ .code = 91, .name = "ShutdownInProgress" } },
        .{ .batch = .{ .ids = &.{2} } },
    });
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    var s = try client.collection("users").watch(cs.ChangeEvent, &c, .{}, .{ .max_await = .fromMilliseconds(50) });
    defer s.deinit();
    try testing.expectEqualStrings("t1", tokenData((try s.next()).?._id));
    // The getMore fails with 91; the stream opens again after t1.
    try testing.expectEqualStrings("t2", tokenData((try s.next()).?._id));
    const resumed = fake.command(io, 2);
    var rit = resumed.iterator();
    try testing.expectEqualStrings("aggregate", rit.next().?.name);
    const stage = pipelineStage(resumed, 0).get("$changeStream").?.document;
    try testing.expectEqualStrings("t1", tokenData(stage.get("resumeAfter").?.document));
    try testing.expect(stage.get("startAfter") == null);
}

test "change stream: startAfter is used again on a resume before any event, resumeAfter once there was one" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, &.{
        .{ .batch = .{ .ids = &.{} } },
        .{ .fail = .{ .code = 6, .name = "HostUnreachable" } },
        .{ .batch = .{ .ids = &.{} } },
    });
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const start = try bson.Document.init(try bson.encode(arena.allocator(), .{ ._data = "start" }, .{}));

    var s = try client.collection("users").watch(cs.ChangeEvent, &c, .{}, .{ .start_after = start, .max_await = .fromMilliseconds(20) });
    defer s.deinit();
    try testing.expect((try s.tryNext()) == null);
    try testing.expect((try s.tryNext()) == null);
    const stage = pipelineStage(fake.command(io, 2), 0).get("$changeStream").?.document;
    try testing.expectEqualStrings("start", tokenData(stage.get("startAfter").?.document));
}

test "change stream: startAtOperationTime comes from the open's operationTime when there is no token" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, &.{
        .{ .batch = .{ .ids = &.{} } },
        .{ .fail = .{ .code = 91, .name = "ShutdownInProgress" } },
        .{ .batch = .{ .ids = &.{} } },
    });
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    var s = try client.collection("users").watch(cs.ChangeEvent, &c, .{}, .{ .max_await = .fromMilliseconds(20) });
    defer s.deinit();
    try testing.expect((try s.tryNext()) == null);
    try testing.expect((try s.tryNext()) == null);
    const stage = pipelineStage(fake.command(io, 2), 0).get("$changeStream").?.document;
    const ts = stage.get("startAtOperationTime").?.timestamp;
    try testing.expectEqual(@as(u32, 1000), ts.t);
}

fn expectFails(script: []const Step, code: []const u8) !void {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, script);
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var failed = false;
    if (client.collection("users").watch(cs.ChangeEvent, &c, .{}, .{ .max_await = .fromMilliseconds(20) })) |opened| {
        var s = opened;
        defer s.deinit();
        if (s.next()) |_| {} else |_| failed = true;
    } else |_| failed = true;
    try testing.expect(failed);
    try testing.expectEqualStrings(code, db.lastError(&c).?.code);
}

test "change stream: 286 is change_stream_history_lost, 40573 needs a replica set, an event without _id is missing_id" {
    try expectFails(&.{.{ .fail = .{ .code = 286, .name = "ChangeStreamHistoryLost" } }}, "change_stream_history_lost");
    try expectFails(&.{.{ .fail = .{ .code = 40573, .name = "Location40573" } }}, "change_streams_need_replica_set");
    try expectFails(&.{.{ .batch = .{ .ids = &.{0} } }}, "change_stream_missing_id");
}

test "change stream: a non-resumable error is returned, not resumed" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var fake: Fake = undefined;
    try fake.init(io, &.{
        .{ .batch = .{ .ids = &.{1} } },
        .{ .fail = .{ .code = 2, .name = "BadValue" } },
    });
    defer fake.deinit(io);
    const client = try open(io, &fake);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    var s = try client.collection("users").watch(cs.ChangeEvent, &c, .{}, .{ .max_await = .fromMilliseconds(20) });
    defer s.deinit();
    _ = (try s.next()).?;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    if (s.next()) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectEqual(@as(usize, 2), fake.commandCount(io));
}
