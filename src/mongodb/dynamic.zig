//! Collection calls named at run time, with their arguments as BSON
//! documents: what the C ABI (`anole_db_*`) and the language bindings
//! send. Each `Op` is the collection method of the same name, its
//! arguments in the order the official drivers take them (`find(filter,
//! options)`, `updateOne(filter, update, options)`...), and options under
//! the command's own names (`sort`, `limit`, `batchSize`, `allowDiskUse`,
//! `upsert`, `arrayFilters`...), as the Node driver spells them. The calls
//! are the typed ones underneath (`Collection.find` and the rest), so
//! retries, sessions, the cache and the errors are theirs.
const std = @import("std");
const bson = @import("bson");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const coll = @import("collection.zig");

const Collection = coll.Collection;
const Database = coll.Database;
pub const Error = coll.Error;

/// The calls. `runCommand` is a database's: its one argument is the
/// command document, sent as it is.
pub const Op = enum {
    find,
    findOne,
    aggregate,
    countDocuments,
    insertOne,
    insertMany,
    updateOne,
    updateMany,
    replaceOne,
    deleteOne,
    deleteMany,
    runCommand,

    /// Whether the call only reads (and may be coalesced or cached).
    pub fn reads(op: Op) bool {
        return switch (op) {
            .find, .findOne, .aggregate, .countDocuments => true,
            else => false,
        };
    }
};

/// What a call returns, in the context's arena.
pub const Result = union(enum) {
    /// `find`, `findOne` (none or one) and `aggregate`.
    documents: []const bson.Document,
    /// `countDocuments`.
    count: u64,
    /// The writes and `runCommand`: what the driver's result says, as a
    /// document (`{insertedId}`, `{insertedCount, insertedIds}`,
    /// `{matchedCount, modifiedCount, upsertedId}`, `{deletedCount}`, or
    /// the command's reply), and the documents the write changed
    /// (inserted, modified or upserted, deleted).
    write: struct { summary: bson.Document, changes: u64 },
};

/// Runs `op` on `collection` (on `database` for `runCommand`) with `args`.
/// A missing or extra argument, an unknown option or one of the wrong type
/// fails with `error.BadRequest` (a 400), the reason in `lastError`.
pub fn run(collection: Collection, database: Database, cx: *db.Ctx, op: Op, args: []const bson.Document) Error!Result {
    const a = cx.arena;
    switch (op) {
        .find, .findOne => {
            try arity(cx, op, args, 0, 2);
            var opts = try options(FindOptions, coll.find_options, cx, op, at(args, 1));
            if (op == .findOne) {
                if (opts.limit == null) opts.limit = .{ .int32 = 1 };
                const one = try collection.findOptional(bson.Document, cx, filter(args), opts);
                return .{ .documents = if (one) |d| try a.dupe(bson.Document, &.{d}) else &.{} };
            }
            return .{ .documents = try collection.find(bson.Document, cx, filter(args), opts) };
        },
        .aggregate => {
            try arity(cx, op, args, 1, 2);
            const opts = try options(AggregateOptions, coll.aggregate_options, cx, op, at(args, 1));
            const stages = try asArray(cx, args[0]);
            return .{ .documents = try collection.aggregate(bson.Document, cx, stages, opts) };
        },
        .countDocuments => {
            try arity(cx, op, args, 0, 2);
            const opts = try options(CountOptions, count_options, cx, op, at(args, 1));
            return .{ .count = try collection.countDocuments(cx, filter(args), opts) };
        },
        .insertOne => {
            try arity(cx, op, args, 1, 1);
            const r = try collection.insertOne(cx, args[0]);
            return write(cx, 1, .{ .insertedId = r.inserted_id });
        },
        .insertMany => {
            if (args.len == 0) return badRequest(cx, "insertMany: one or more documents", .{});
            const r = try collection.insertMany(cx, args, .{});
            return write(cx, r.inserted_count, .{ .insertedCount = r.inserted_count, .insertedIds = r.inserted_ids });
        },
        .updateOne, .updateMany, .replaceOne => {
            try arity(cx, op, args, 2, 3);
            const opts = try options(UpdateOptions, coll.update_options, cx, op, at(args, 2));
            const r = if (op == .replaceOne)
                try collection.replaceOne(cx, args[0], args[1], opts)
            else if (isArray(args[1])) blk: {
                // An update pipeline: stages, as an array.
                const stages: bson.Array = .{ .doc = args[1] };
                break :blk if (op == .updateOne) try collection.updateOne(cx, args[0], stages, opts) else try collection.updateMany(cx, args[0], stages, opts);
            } else if (op == .updateOne) try collection.updateOne(cx, args[0], args[1], opts) else try collection.updateMany(cx, args[0], args[1], opts);
            const upserted: u64 = @intFromBool(r.upserted_id != null);
            return write(cx, r.modified_count + upserted, .{ .matchedCount = r.matched_count, .modifiedCount = r.modified_count, .upsertedId = r.upserted_id });
        },
        .deleteOne, .deleteMany => {
            try arity(cx, op, args, 1, 2);
            const opts = try options(DeleteOptions, coll.delete_options, cx, op, at(args, 1));
            const r = if (op == .deleteOne) try collection.deleteOne(cx, args[0], opts) else try collection.deleteMany(cx, args[0], opts);
            return write(cx, r.deleted_count, .{ .deletedCount = r.deleted_count });
        },
        .runCommand => {
            try arity(cx, op, args, 1, 1);
            return .{ .write = .{ .summary = try database.runCommand(cx, args[0]), .changes = 0 } };
        },
    }
}

// Options as the commands name them; each is left out unless given.
// `batchSize` and `countDocuments`' `skip` and `limit` are numbers the
// calls read themselves.

const V = ?bson.Value;

const FindOptions = struct {
    sort: V = null,
    projection: V = null,
    skip: V = null,
    limit: V = null,
    batch_size: ?i64 = null,
    hint: V = null,
    collation: V = null,
    comment: V = null,
    allow_disk_use: V = null,
    let: V = null,
    max: V = null,
    min: V = null,
    return_key: V = null,
    show_record_id: V = null,
};

const AggregateOptions = struct {
    allow_disk_use: V = null,
    batch_size: ?i64 = null,
    hint: V = null,
    collation: V = null,
    comment: V = null,
    let: V = null,
    bypass_document_validation: V = null,
};

const count_options = .{ .{ "skip", "skip" }, .{ "limit", "limit" }, .{ "hint", "hint" }, .{ "collation", "collation" }, .{ "comment", "comment" } };

const CountOptions = struct {
    skip: ?i64 = null,
    limit: ?i64 = null,
    hint: V = null,
    collation: V = null,
    comment: V = null,
};

const UpdateOptions = struct {
    upsert: V = null,
    array_filters: V = null,
    hint: V = null,
    collation: V = null,
};

const DeleteOptions = struct {
    hint: V = null,
    collation: V = null,
};

/// `doc`'s elements as an `O`, by the command names `names` pairs with
/// `O`'s fields.
fn options(comptime O: type, comptime names: anytype, cx: *db.Ctx, op: Op, doc: ?bson.Document) Error!O {
    var out: O = .{};
    const d = doc orelse return out;
    var it = d.iterator();
    while (it.next()) |e| {
        var known = false;
        inline for (names) |pair| {
            if (comptime @hasField(O, pair[0])) {
                if (std.mem.eql(u8, e.name, pair[1])) {
                    known = true;
                    const F = @FieldType(O, pair[0]);
                    @field(out, pair[0]) = if (F == ?i64)
                        (integer(e.value) orelse return badRequest(cx, "{t}: option \"{s}\" is a number", .{ op, e.name }))
                    else
                        e.value;
                }
            }
        }
        if (!known) return badRequest(cx, "{t}: unknown option \"{s}\"", .{ op, e.name });
    }
    return out;
}

fn integer(v: bson.Value) ?i64 {
    return switch (v) {
        .int32 => |n| n,
        .int64 => |n| n,
        .double => |f| if (@trunc(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

fn arity(cx: *db.Ctx, op: Op, args: []const bson.Document, min: usize, max: usize) Error!void {
    if (args.len < min or args.len > max) {
        if (min == max) return badRequest(cx, "{t} takes {d} document{s}, not {d}", .{ op, min, if (min == 1) "" else "s", args.len });
        return badRequest(cx, "{t} takes {d} to {d} documents, not {d}", .{ op, min, max, args.len });
    }
}

fn at(args: []const bson.Document, i: usize) ?bson.Document {
    return if (i < args.len) args[i] else null;
}

/// The filter, `{}` when none is given.
fn filter(args: []const bson.Document) bson.Document {
    return at(args, 0) orelse .empty;
}

/// Whether `doc`'s keys are "0", "1"...: an array (a pipeline).
fn isArray(doc: bson.Document) bool {
    var it = doc.iterator();
    var i: usize = 0;
    var buf: [20]u8 = undefined;
    while (it.next()) |e| : (i += 1) {
        if (!std.mem.eql(u8, e.name, std.fmt.bufPrint(&buf, "{d}", .{i}) catch return false)) return false;
    }
    return i > 0;
}

/// `doc`'s values in order as an array, whatever its keys (a binding may
/// encode a list as a document): the stages of a pipeline.
fn asArray(cx: *db.Ctx, doc: bson.Document) Error!bson.Array {
    if (isArray(doc)) return .{ .doc = doc };
    var b: bson.Builder = .init(cx.arena);
    b.begin() catch return error.OutOfMemory;
    b.beginArray("a") catch return error.OutOfMemory;
    var it = doc.iterator();
    while (it.next()) |e| b.append("", e.value) catch return error.OutOfMemory;
    b.end() catch return error.OutOfMemory;
    b.end() catch return error.OutOfMemory;
    const outer = bson.Document.init(b.bytes()) catch return error.OutOfMemory;
    return outer.get("a").?.array;
}

/// A write's result: its summary as a document, and its count.
fn write(cx: *db.Ctx, changes: u64, summary: anytype) Error!Result {
    var b: bson.Builder = .init(cx.arena);
    b.begin() catch return error.OutOfMemory;
    bson.appendFields(&b, summary, .{}) catch return error.OutOfMemory;
    b.end() catch return error.OutOfMemory;
    return .{ .write = .{ .summary = .{ .bytes = b.bytes() }, .changes = changes } };
}

/// Fails the call with `error.BadRequest` (a 400), `fmt` in `lastError`.
pub fn badRequest(cx: *db.Ctx, comptime fmt: []const u8, args: anytype) Error {
    const message = std.fmt.allocPrint(cx.arena, fmt, args) catch "a bad argument";
    return internal.fail(cx, .{ .other = .bad_request }, .{ .system = .mongodb, .class = .other, .message = message });
}

fn enc(a: std.mem.Allocator, v: anytype) !bson.Document {
    return bson.Document.init(try bson.encode(a, v, .{}));
}

test "mongodb: dynamic options by the command's names, arrays, write summaries" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cx: db.Ctx = .{ .io = std.testing.io, .arena = a };

    const doc = try enc(a, .{ .sort = .{ .at = -1 }, .limit = 5, .batchSize = 2.0, .allowDiskUse = true });
    const o = try options(FindOptions, coll.find_options, &cx, .find, doc);
    try std.testing.expectEqual(@as(?i64, 2), o.batch_size);
    try std.testing.expectEqual(@as(i32, 5), o.limit.?.int32);
    try std.testing.expect(o.allow_disk_use.?.boolean);
    try std.testing.expect(o.sort.? == .document);

    try std.testing.expectError(error.BadRequest, options(FindOptions, coll.find_options, &cx, .find, try enc(a, .{ .limt = 5 })));
    try std.testing.expect(std.mem.indexOf(u8, db.lastError(&cx).?.message, "unknown option \"limt\"") != null);
    try std.testing.expectError(error.BadRequest, options(CountOptions, count_options, &cx, .countDocuments, try enc(a, .{ .skip = "x" })));
    try std.testing.expectError(error.BadRequest, arity(&cx, .insertOne, &.{}, 1, 1));

    // A list encoded as a document keyed otherwise: its values, in order.
    const stages = try asArray(&cx, try enc(a, .{ .x = .{ .@"$match" = .{ .a = 1 } }, .y = .{ .@"$limit" = 2 } }));
    try std.testing.expectEqual(@as(usize, 2), stages.count());
    try std.testing.expect(isArray(stages.doc));

    const w = try write(&cx, 3, .{ .deletedCount = @as(u64, 3) });
    try std.testing.expectEqual(@as(u64, 3), w.write.changes);
    try std.testing.expectEqual(@as(i64, 3), w.write.summary.get("deletedCount").?.int64);
}
