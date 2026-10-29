//! Tests against a live server: `zig build test -Dmongodb-test-url=mongodb://...`
//! (tests/mongodb/run.sh starts MongoDB 7.0, 8.0 or 9.0 in Docker: a replica
//! set of one with authentication, plain and over TLS).
const std = @import("std");
const zio = @import("zio");
const bson = @import("bson");
const db = @import("../db/root.zig");
const mongodb = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn url() ?[]const u8 {
    return @import("build_options").mongodb_test_url;
}

const User = struct {
    _id: ?bson.ObjectId = null,
    name: []const u8,
    email: []const u8,
    age: i32 = 0,
    tags: []const []const u8 = &.{},
};

/// A fresh collection for one test, dropped after it.
const Fixture = struct {
    rt: *zio.Runtime,
    client: *mongodb.Client,
    arena: std.heap.ArenaAllocator,
    c: db.Ctx,
    name_buf: [32]u8 = undefined,
    coll: mongodb.Collection = undefined,

    fn init(f: *Fixture, executors: ?usize) !void {
        f.rt = try zio.Runtime.init(gpa, if (executors) |n| .{ .executors = .exact(@intCast(n)) } else .{});
        errdefer f.rt.deinit();
        const io = f.rt.io();
        f.client = try mongodb.Client.init(gpa, io, .{ .url = url().?, .database = "anole_test", .server_selection_timeout = .fromSeconds(10) });
        f.arena = .init(gpa);
        f.c = .{ .io = io, .arena = f.arena.allocator() };
        var random: [4]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bufPrint(&f.name_buf, "t_{x}", .{std.mem.readInt(u32, &random, .little)}) catch unreachable;
        f.coll = f.client.collection(name);
    }

    fn deinit(f: *Fixture) void {
        f.coll.drop(&f.c) catch {};
        f.arena.deinit();
        f.client.deinit();
        f.rt.deinit();
    }
};

/// Ada (36, two tags) and Grace (45, the `_id` given): Ada's `_id` back.
fn seedTwo(f: *Fixture) !bson.ObjectId {
    const ada = try f.coll.insertOne(&f.c, User{ .name = "Ada", .email = "ada@example.com", .age = 36, .tags = &.{ "math", "beta" } });
    _ = try f.coll.insertOne(&f.c, .{ ._id = bson.ObjectId.generate(f.c.io), .name = "Grace", .email = "grace@example.com", .age = 45 });
    return ada.objectId().?;
}

/// Fifty users named "many", aged 0 to 49.
fn seedMany(f: *Fixture) !void {
    var many: [50]User = undefined;
    var emails: [50][32]u8 = undefined;
    for (&many, 0..) |*u, i| {
        const email = std.fmt.bufPrint(&emails[i], "user{d}@example.com", .{i}) catch unreachable;
        u.* = .{ .name = "many", .email = email, .age = @intCast(i) };
    }
    const inserted = try f.coll.insertMany(&f.c, @as([]const User, &many), .{});
    if (inserted.inserted_count != 50) return error.TestUnexpectedResult;
}

test "live: tls=true in the URL puts every connection over TLS" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = users;
    try f.client.ping(c);
    // The server also takes plain connections, so nothing else would tell.
    try testing.expectEqual(std.mem.indexOf(u8, url().?, "tls=true") != null, f.client.settings.tls != null);
}

test "live: insertOne makes an _id when the document has none and keeps a given one" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    const ada = try users.insertOne(c, User{ .name = "Ada", .email = "ada@example.com", .age = 36 });
    try testing.expect(ada.objectId() != null);
    const grace_id = bson.ObjectId.generate(c.io);
    const grace = try users.insertOne(c, .{ ._id = grace_id, .name = "Grace", .email = "grace@example.com", .age = 45 });
    try testing.expect(grace.objectId().?.eql(grace_id));
}

test "live: findOne finds, findOptional gives null and findOne NotFound for no match" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    const ada_id = try seedTwo(&f);
    const found = try users.findOne(User, c, .{ .email = "ada@example.com" }, .{});
    try testing.expectEqualStrings("Ada", found.name);
    try testing.expect(found._id.?.eql(ada_id));
    try testing.expectEqual(@as(usize, 2), found.tags.len);
    try testing.expect(try users.findOptional(User, c, .{ .email = "nobody" }, .{}) == null);
    try testing.expectError(error.NotFound, users.findOne(User, c, .{ .email = "nobody" }, .{}));
}

test "live: a duplicate on a unique index is a Conflict with the server's code kept" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    try testing.expectEqualStrings("email_1", try users.createIndex(c, .{ .email = 1 }, .{ .unique = true }));
    try testing.expectError(error.Conflict, users.insertOne(c, .{ .name = "Ada again", .email = "ada@example.com" }));
    const detail = db.lastError(c).?;
    try testing.expectEqualStrings("11000", detail.code);
    try testing.expectEqual(db.Class.unique, detail.class);
    try users.dropIndex(c, "email_1");
}

test "live: insertMany, then find with a sort, a limit and a projection" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    var many: [50]User = undefined;
    var emails: [50][32]u8 = undefined;
    for (&many, 0..) |*u, i| {
        const email = std.fmt.bufPrint(&emails[i], "user{d}@example.com", .{i}) catch unreachable;
        u.* = .{ .name = "many", .email = email, .age = @intCast(i) };
    }
    const inserted = try users.insertMany(c, @as([]const User, &many), .{});
    try testing.expectEqual(@as(u64, 50), inserted.inserted_count);
    try testing.expectEqual(bson.Type.object_id, std.meta.activeTag(inserted.inserted_ids[49]));
    const young = try users.find(User, c, .{ .name = "many", .age = .{ .@"$lt" = 10 } }, .{ .sort = .{ .age = -1 }, .limit = 3 });
    try testing.expectEqual(@as(usize, 3), young.len);
    try testing.expectEqual(@as(i32, 9), young[0].age);
    const Name = struct { name: []const u8 };
    const names = try users.find(Name, c, .{ .age = .{ .@"$gte" = 30 } }, .{ .projection = .{ .name = 1, ._id = 0 }, .sort = .{ .age = 1 } });
    try testing.expectEqual(@as(usize, 22), names.len);
}

test "live: several batches arrive through getMore, by find and by a cursor; a cursor left early is killed" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    try seedMany(&f);
    try testing.expectEqual(@as(usize, 50), (try users.find(User, c, .{ .name = "many" }, .{ .batch_size = 7 })).len);
    var cursor = try users.iterate(User, c, .{ .name = "many" }, .{ .batch_size = 5, .sort = .{ .age = 1 } });
    var seen: i32 = 0;
    while (try cursor.next()) |u| : (seen += 1) try testing.expectEqual(seen, u.age);
    cursor.deinit();
    try testing.expectEqual(@as(i32, 50), seen);
    // Left early: killCursors.
    var early = try users.iterate(User, c, .{ .name = "many" }, .{ .batch_size = 2 });
    _ = try early.next();
    early.deinit();
}

test "live: countDocuments, estimatedDocumentCount and distinct" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    try seedMany(&f);
    try testing.expectEqual(@as(u64, 52), try users.countDocuments(c, .{}, .{}));
    try testing.expectEqual(@as(u64, 10), try users.countDocuments(c, .{ .name = "many" }, .{ .skip = 40 }));
    try testing.expectEqual(@as(u64, 52), try users.estimatedDocumentCount(c));
    const distinct_names = try users.distinct([]const u8, c, "name", .{});
    try testing.expectEqual(@as(usize, 3), distinct_names.len);
}

test "live: aggregate runs the pipeline into typed rows" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    try seedMany(&f);
    const Group = struct { _id: []const u8, n: i32 };
    const groups = try users.aggregate(Group, c, .{
        .{ .@"$group" = .{ ._id = "$name", .n = .{ .@"$sum" = 1 } } },
        .{ .@"$sort" = .{ .n = -1 } },
    }, .{});
    try testing.expectEqualStrings("many", groups[0]._id);
    try testing.expectEqual(@as(i32, 50), groups[0].n);
}

test "live: updateOne, updateMany, an upsert and replaceOne report what they matched and changed" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    try seedMany(&f);
    const one = try users.updateOne(c, .{ .email = "ada@example.com" }, .{ .@"$inc" = .{ .age = 1 } }, .{});
    try testing.expectEqual(@as(u64, 1), one.matched_count);
    try testing.expectEqual(@as(u64, 1), one.modified_count);
    const multi = try users.updateMany(c, .{ .name = "many" }, .{ .@"$set" = .{ .tags = .{"bulk"} } }, .{});
    try testing.expectEqual(@as(u64, 50), multi.modified_count);
    const upsert = try users.updateOne(c, .{ .email = "new@example.com" }, .{ .@"$set" = .{ .name = "New" } }, .{ .upsert = true });
    try testing.expectEqual(@as(u64, 0), upsert.matched_count);
    try testing.expect(upsert.upserted_id != null);
    const replaced = try users.replaceOne(c, .{ .email = "new@example.com" }, .{ .name = "Newer", .email = "new@example.com" }, .{});
    try testing.expectEqual(@as(u64, 1), replaced.modified_count);
}

test "live: findOneAndUpdate gives the document before or after, findOneAndDelete the deleted one or null" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    _ = try users.insertOne(c, .{ .name = "Newer", .email = "new@example.com" });
    const before = (try users.findOneAndUpdate(User, c, .{ .email = "grace@example.com" }, .{ .@"$set" = .{ .age = 46 } }, .{})).?;
    try testing.expectEqual(@as(i32, 45), before.age);
    const after = (try users.findOneAndUpdate(User, c, .{ .email = "grace@example.com" }, .{ .@"$inc" = .{ .age = 1 } }, .{ .return_document = mongodb.ReturnDocument.after })).?;
    try testing.expectEqual(@as(i32, 47), after.age);
    try testing.expect(try users.findOneAndDelete(User, c, .{ .email = "nobody" }, .{}) == null);
    try testing.expectEqualStrings("Newer", (try users.findOneAndDelete(User, c, .{ .email = "new@example.com" }, .{})).?.name);
}

test "live: deleteOne and deleteMany count what they deleted" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    try seedMany(&f);
    try testing.expectEqual(@as(u64, 1), (try users.deleteOne(c, .{ .name = "many" }, .{})).deleted_count);
    try testing.expectEqual(@as(u64, 49), (try users.deleteMany(c, .{ .name = "many" }, .{})).deleted_count);
}

test "live: runCommand sends a database command and returns its reply" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    const stats = try f.client.db("anole_test").runCommand(c, .{ .collStats = users.name });
    try testing.expect(stats.get("ns") != null);
}

test "live: a call past its own timeout is a 504 and its connection closes without waiting (0d9944a)" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const users = f.coll;
    _ = try seedTwo(&f);
    // The server stops too; the TLS leg failed here before 0d9944a (a
    // canceled read, then close parked on close_notify).
    const slow = users.with(.{ .timeout = .fromMilliseconds(100) }).find(User, c, .{ .@"$where" = "sleep(300) || true" }, .{});
    if (slow) |_| return error.TestUnexpectedResult else |err| try testing.expectEqual(error.GatewayTimeout, err);
}

test "live: retryable writes and reads over failCommand" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(null);
    defer f.deinit();
    const c = &f.c;
    const admin = f.client.db("admin");
    // failCommand needs enableTestCommands, which tests/mongodb/run.sh
    // always sets: a server without it fails the test, never skips it.
    _ = admin.runCommand(c, .{ .configureFailPoint = "failCommand", .mode = "off" }) catch |err| {
        std.debug.print("live: failCommand refused ({t}); start mongod with --setParameter enableTestCommands=1\n", .{err});
        return err;
    };
    defer _ = admin.runCommand(c, .{ .configureFailPoint = "failCommand", .mode = "off" }) catch {};

    // A primary stepping down mid-write: retried once, done once.
    _ = try admin.runCommand(c, .{ .configureFailPoint = "failCommand", .mode = .{ .times = 1 }, .data = .{
        .failCommands = .{"insert"},
        .errorCode = 10107,
        .errorLabels = .{"RetryableWriteError"},
    } });
    _ = try f.coll.insertOne(c, .{ .name = "retried", .email = "r@example.com" });
    try testing.expectEqual(@as(u64, 1), try f.coll.countDocuments(c, .{ .name = "retried" }, .{}));

    // The connection dropped mid-read: retried on a new one.
    _ = try admin.runCommand(c, .{ .configureFailPoint = "failCommand", .mode = .{ .times = 1 }, .data = .{
        .failCommands = .{"find"},
        .closeConnection = true,
    } });
    try testing.expectEqualStrings("retried", (try f.coll.findOne(User, c, .{ .name = "retried" }, .{})).name);

    // Twice in a row: the retry fails too, and the call says so.
    _ = try admin.runCommand(c, .{ .configureFailPoint = "failCommand", .mode = .{ .times = 2 }, .data = .{
        .failCommands = .{"insert"},
        .errorCode = 10107,
        .errorLabels = .{"RetryableWriteError"},
    } });
    try testing.expectError(error.ServiceUnavailable, f.coll.insertOne(c, .{ .name = "twice", .email = "t@example.com" }));
}

test "live: inserts from 16 tasks on 4 executors all land" {
    if (url() == null) return error.SkipZigTest;
    var f: Fixture = .{ .rt = undefined, .client = undefined, .arena = undefined, .c = undefined };
    try f.init(4);
    defer f.deinit();
    const io = f.c.io;
    const Worker = struct {
        fn run(coll: mongodb.Collection, worker: usize, failures: *std.atomic.Value(usize)) void {
            const wio = coll.client.io;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = wio, .arena = arena.allocator() };
            for (0..25) |i| {
                _ = coll.insertOne(&c, .{ .worker = @as(i64, @intCast(worker)), .i = @as(i64, @intCast(i)) }) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
            }
        }
    };
    var failures: std.atomic.Value(usize) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |w| try @import("dusty").placement.concurrent(&group, io, .{ .executor = w }, Worker.run, .{ f.coll, w, &failures });
    try group.await(io);
    try testing.expectEqual(@as(usize, 0), failures.load(.monotonic));
    try testing.expectEqual(@as(u64, 400), try f.coll.countDocuments(&f.c, .{}, .{}));
}
