//! Databases, collections and cursors: the CRUD API, shaped like the
//! official drivers' (find, findOne, insertOne, updateMany, aggregate,
//! countDocuments...) with Anole's conventions: the request comes first,
//! results land in its arena, and failures are `anole.db` errors that
//! become statuses (a duplicate key is a 409, no primary a 503, a timeout
//! a 504; `anole.db.lastError(req)` has the server's code and message).
//!
//! Filters, updates, sorts, projections and pipelines are Zig values:
//! anonymous literals map to documents and tuples to arrays,
//!
//!     .{ .age = .{ .@"$gte" = 18 }, .tags = "beta" }
//!     .{ .{ .@"$match" = .{ .active = true } }, .{ .@"$count" = "n" } }
//!
//! and documents map onto structs by field name (see `anole.bson`).
//! Options are anonymous literals too, checked at compile time against
//! the names each call takes (`.{ .sort = .{ .created = -1 }, .limit = 20 }`).
const std = @import("std");
const bson = @import("bson");
const db = @import("../db/root.zig");
const wire = @import("wire.zig");
const sdam = @import("sdam.zig");
const client_mod = @import("client.zig");
const conn_mod = @import("connection.zig");

const Client = client_mod.Client;
const Context = client_mod.Context;
const Exchange = client_mod.Exchange;
const Operation = client_mod.Operation;
pub const Error = client_mod.Error;

/// A database of a client: `client.db("app")`.
pub const Database = struct {
    client: *Client,
    name: []const u8,
    options: db.QueryOptions = .{},

    /// The collection `name` of this database, with the same options.
    pub fn collection(self: Database, name: []const u8) Collection {
        return .{ .client = self.client, .database = self.name, .name = name, .options = self.options };
    }

    /// The calls with `opts`: a timeout of their own, and for reads
    /// `coalesce` and `cache` (`anole.db.QueryOptions`).
    pub fn with(self: Database, opts: db.QueryOptions) Database {
        var out = self;
        out.options = opts;
        return out;
    }

    /// Runs `command` (a document: `.{ .ping = 1 }`, `.{ .collMod = "users", ... }`)
    /// on this database and returns the server's reply, in `c`'s arena. A
    /// reply with `ok: 0` fails as any call does.
    pub fn runCommand(self: Database, c: anytype, command: anytype) Error!bson.Document {
        var cx = client_mod.erase(c);
        var ctx: RunCommand(@TypeOf(command)) = .{ .command = command, .arena = cx.arena };
        return client_mod.execute(self.client, &cx, .{ .name = "command", .database = self.name, .kind = .command, .options = self.options }, &ctx);
    }

    /// Drops the database.
    pub fn drop(self: Database, c: anytype) Error!void {
        _ = try self.runCommand(c, .{ .dropDatabase = 1 });
    }
};

/// A collection: `client.db("app").collection("users")`, or
/// `client.collection("users")` in the connection string's database.
pub const Collection = struct {
    client: *Client,
    database: []const u8,
    name: []const u8,
    options: db.QueryOptions = .{},

    /// The calls with `opts`: `users.with(.{ .timeout = .fromSeconds(2) }).find(...)`.
    /// The timeout bounds the call (server selection, the pool, the round
    /// trips) and goes to the server as `maxTimeMS`; `coalesce` and
    /// `cache` share or keep the reads (`anole.db.QueryOptions`).
    pub fn with(self: Collection, opts: db.QueryOptions) Collection {
        var out = self;
        out.options = opts;
        return out;
    }

    fn op(self: Collection, name: []const u8, kind: Operation.Kind, retry: Operation.Retry) Operation {
        return .{ .name = name, .database = self.database, .collection = self.name, .kind = kind, .retry = retry, .options = self.options };
    }

    // -----------------------------------------------------------------------
    // Reads

    /// Every document matching `filter`, as `T`s in `c`'s arena.
    /// Options: sort, projection, skip, limit, batch_size, hint, collation,
    /// comment, allow_disk_use, let, max, min, return_key, show_record_id.
    pub fn find(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error![]T {
        return self.client.cache.read([]T, c, self.options, "find", .{ self.database, self.name, filter, opts }, Shared(.find, T){ .collection = self });
    }

    fn findNow(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error![]T {
        var cx = client_mod.erase(c);
        var out: std.ArrayList(T) = .empty;
        var sink: AllSink(T) = .{ .arena = cx.arena, .out = &out };
        const body: FindBody(@TypeOf(filter), @TypeOf(opts)) = .{ .collection = self.name, .filter = filter, .opts = opts };
        try self.drain(&cx, "find", body, &sink, batchSizeOf(opts));
        return out.items;
    }

    /// The first document matching `filter`; none: `error.NotFound` (a 404).
    pub fn findOne(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!T {
        return try self.findOptional(T, c, filter, opts) orelse error.NotFound;
    }

    /// The first document matching `filter`, or null.
    pub fn findOptional(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!?T {
        return self.client.cache.read(?T, c, self.options, "findOne", .{ self.database, self.name, filter, opts }, Shared(.find_optional, T){ .collection = self });
    }

    fn findOptionalNow(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!?T {
        var cx = client_mod.erase(c);
        var out: std.ArrayList(T) = .empty;
        var sink: AllSink(T) = .{ .arena = cx.arena, .out = &out };
        const body: FindBody(@TypeOf(filter), @TypeOf(opts)) = .{ .collection = self.name, .filter = filter, .opts = opts, .one = true };
        try self.drain(&cx, "find", body, &sink, null);
        return if (out.items.len > 0) out.items[0] else null;
    }

    /// The matching documents one batch at a time, for results too large
    /// to hold at once: `while (try cursor.next()) |doc|`, then `deinit`.
    /// Each document is decoded into `c`'s arena.
    pub fn iterate(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!Cursor(T) {
        const cx = client_mod.erase(c);
        const body: FindBody(@TypeOf(filter), @TypeOf(opts)) = .{ .collection = self.name, .filter = filter, .opts = opts };
        return self.open(T, cx, "find", body, batchSizeOf(opts), .read);
    }

    /// Runs the aggregation `pipeline` (a tuple of stages) and returns its
    /// documents as `T`s. A pipeline ending in `$out` or `$merge` writes,
    /// and is sent as a write (with the write concern, not retried).
    pub fn aggregate(self: Collection, comptime T: type, c: anytype, pipeline: anytype, opts: anytype) Error![]T {
        // Shared only when the pipeline is known to read: a tuple of
        // stages whose last is neither `$out` nor `$merge`.
        if (comptime !readsOnly(@TypeOf(pipeline))) return self.aggregateNow(T, c, pipeline, opts);
        return self.client.cache.read([]T, c, self.options, "aggregate", .{ self.database, self.name, pipeline, opts }, Shared(.aggregate, T){ .collection = self });
    }

    fn aggregateNow(self: Collection, comptime T: type, c: anytype, pipeline: anytype, opts: anytype) Error![]T {
        var cx = client_mod.erase(c);
        var out: std.ArrayList(T) = .empty;
        var sink: AllSink(T) = .{ .arena = cx.arena, .out = &out };
        const stages = try encodePipeline(&cx, self.client, pipeline, self.name);
        const body: AggregateBody(@TypeOf(opts)) = .{ .collection = self.name, .pipeline = stages, .opts = opts };
        try self.drainKind(&cx, "aggregate", body, &sink, batchSizeOf(opts), if (writes(stages)) .write else .read);
        return out.items;
    }

    /// `aggregate`, one document at a time (see `iterate`).
    pub fn aggregateIterate(self: Collection, comptime T: type, c: anytype, pipeline: anytype, opts: anytype) Error!Cursor(T) {
        var cx = client_mod.erase(c);
        const stages = try encodePipeline(&cx, self.client, pipeline, self.name);
        const body: AggregateBody(@TypeOf(opts)) = .{ .collection = self.name, .pipeline = stages, .opts = opts };
        return self.open(T, cx, "aggregate", body, batchSizeOf(opts), if (writes(stages)) .write else .read);
    }

    /// How many documents match `filter` (an aggregation, as the drivers
    /// count). Options: skip, limit, hint, collation, comment.
    pub fn countDocuments(self: Collection, c: anytype, filter: anytype, opts: anytype) Error!u64 {
        comptime checkOptions(@TypeOf(opts), .{ .{ "skip", "" }, .{ "limit", "" }, .{ "hint", "hint" }, .{ "collation", "collation" }, .{ "comment", "comment" } });
        const Count = struct { n: i64 = 0 };
        const skip: ?i64 = if (@hasField(@TypeOf(opts), "skip")) opts.skip else null;
        const limit: ?i64 = if (@hasField(@TypeOf(opts), "limit")) opts.limit else null;
        const Rest = struct { hint: ?bson.Value = null };
        _ = Rest;
        const pipeline = .{
            .{ .@"$match" = asDocument(filter) },
            .{ .@"$skip" = skip orelse 0 },
            .{ .@"$limit" = limit orelse std.math.maxInt(i64) },
            .{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } },
        };
        const rest = pickOptions(opts, .{ "hint", "collation", "comment" });
        const rows = try self.aggregate(Count, c, pipeline, rest);
        return if (rows.len > 0) @intCast(@max(rows[0].n, 0)) else 0;
    }

    /// The collection's size from its metadata: fast, but it may be off
    /// after an unclean shutdown, and it ignores no filter.
    pub fn estimatedDocumentCount(self: Collection, c: anytype) Error!u64 {
        return self.client.cache.read(u64, c, self.options, "count", .{ self.database, self.name }, Shared(.estimated_count, void){ .collection = self });
    }

    fn estimatedDocumentCountNow(self: Collection, c: anytype) Error!u64 {
        var cx = client_mod.erase(c);
        var ctx: CountCmd = .{ .collection = self.name };
        return client_mod.execute(self.client, &cx, self.op("count", .read, .read), &ctx);
    }

    /// The distinct values of `field` among the documents matching
    /// `filter`, as `T`s.
    pub fn distinct(self: Collection, comptime T: type, c: anytype, field: []const u8, filter: anytype) Error![]T {
        return self.client.cache.read([]T, c, self.options, "distinct", .{ self.database, self.name, field, filter }, Shared(.distinct, T){ .collection = self });
    }

    fn distinctNow(self: Collection, comptime T: type, c: anytype, field: []const u8, filter: anytype) Error![]T {
        var cx = client_mod.erase(c);
        var ctx: Distinct(T, @TypeOf(filter)) = .{ .collection = self.name, .key = field, .filter = filter, .arena = cx.arena };
        return client_mod.execute(self.client, &cx, self.op("distinct", .read, .read), &ctx);
    }

    /// A read as `anole.db.QueryCache` makes it: the plain call, on the
    /// database and collection named in `args` (the cache's own copies
    /// when the call is shared), with the caller's context or a shared
    /// call's own.
    fn Shared(comptime verb: enum { find, find_optional, aggregate, estimated_count, distinct }, comptime T: type) type {
        return struct {
            collection: Collection,

            pub fn run(r: @This(), c: anytype, _: []const u8, args: anytype) Error!switch (verb) {
                .find, .aggregate, .distinct => []T,
                .find_optional => ?T,
                .estimated_count => u64,
            } {
                var self = r.collection;
                self.database = args[0];
                self.name = args[1];
                return switch (verb) {
                    .find => self.findNow(T, c, args[2], args[3]),
                    .find_optional => self.findOptionalNow(T, c, args[2], args[3]),
                    .aggregate => self.aggregateNow(T, c, args[2], args[3]),
                    .estimated_count => self.estimatedDocumentCountNow(c),
                    .distinct => self.distinctNow(T, c, args[2], args[3]),
                };
            }
        };
    }

    // -----------------------------------------------------------------------
    // The shared verbs (`anole.db`): `one`, `optional`, `all`, and
    // `iterate` above. The filter takes the place of the SQL, and `opts`
    // that of its arguments.

    /// `findOne`: the first document matching `filter`; none:
    /// `error.NotFound` (a 404).
    pub fn one(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!T {
        return self.findOne(T, c, filter, opts);
    }

    /// `findOptional`: the first document matching `filter`, or null.
    pub fn optional(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!?T {
        return self.findOptional(T, c, filter, opts);
    }

    /// `find`: every document matching `filter`.
    pub fn all(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error![]T {
        return self.find(T, c, filter, opts);
    }

    // -----------------------------------------------------------------------
    // Writes

    /// Inserts `doc` (a struct, an anonymous literal or a `bson.Document`).
    /// A document without an `_id` (no such field, or a null one) gets a
    /// new ObjectId, which the result carries. A duplicate key fails with
    /// `error.Conflict` (a 409).
    pub fn insertOne(self: Collection, c: anytype, doc: anytype) Error!InsertOneResult {
        var cx = client_mod.erase(c);
        const ids = try cx.arena.alloc(?bson.ObjectId, 1);
        ids[0] = if (hasId(doc)) null else bson.ObjectId.generate(cx.io);
        var ctx: Insert(@TypeOf(doc)) = .{ .collection = self.name, .docs = (&doc)[0..1], .ids = ids, .ordered = true, .arena = cx.arena };
        try client_mod.execute(self.client, &cx, self.op("insert", .write, .write), &ctx);
        return .{ .inserted_id = ctx.first_id orelse .null };
    }

    /// Inserts `docs` (a slice), in batches the server takes. Ordered by
    /// default: the first failure stops the rest. Options: ordered,
    /// bypass_document_validation, comment.
    pub fn insertMany(self: Collection, c: anytype, docs: anytype, opts: anytype) Error!InsertManyResult {
        comptime checkOptions(@TypeOf(opts), insert_many_options);
        var cx = client_mod.erase(c);
        const ids = try cx.arena.alloc(?bson.ObjectId, docs.len);
        for (docs, ids) |d, *id| id.* = if (hasId(d)) null else bson.ObjectId.generate(cx.io);
        const ordered = if (@hasField(@TypeOf(opts), "ordered")) opts.ordered else true;
        var inserted_ids = try cx.arena.alloc(bson.Value, docs.len);
        var inserted: u64 = 0;
        var start: usize = 0;
        while (start < docs.len) {
            var ctx: Insert(std.meta.Elem(@TypeOf(docs))) = .{
                .collection = self.name,
                .docs = docs[start..],
                .ids = ids[start..],
                .ordered = ordered,
                .arena = cx.arena,
                .out_ids = inserted_ids[start..],
                .extra = encodeOptionsAlloc(cx.arena, opts, insert_many_options) catch return error.OutOfMemory,
            };
            try client_mod.execute(self.client, &cx, self.op("insert", .write, .write), &ctx);
            inserted += ctx.n;
            start += ctx.sent;
        }
        return .{ .inserted_count = inserted, .inserted_ids = inserted_ids };
    }

    /// Applies `update` (`.{ .@"$set" = .{ ... } }`, or a pipeline tuple) to
    /// the first document matching `filter`. Options: upsert,
    /// array_filters, hint, collation.
    pub fn updateOne(self: Collection, c: anytype, filter: anytype, update: anytype, opts: anytype) Error!UpdateResult {
        return self.updateImpl(c, filter, update, opts, false, .update);
    }

    /// `updateOne` for every matching document (not retried: a multi
    /// update is not a retryable write).
    pub fn updateMany(self: Collection, c: anytype, filter: anytype, update: anytype, opts: anytype) Error!UpdateResult {
        return self.updateImpl(c, filter, update, opts, true, .update);
    }

    /// Replaces the first document matching `filter` with `replacement`
    /// (which has no update operators). Options: upsert, hint, collation.
    pub fn replaceOne(self: Collection, c: anytype, filter: anytype, replacement: anytype, opts: anytype) Error!UpdateResult {
        return self.updateImpl(c, filter, replacement, opts, false, .replace);
    }

    fn updateImpl(self: Collection, c: anytype, filter: anytype, update: anytype, opts: anytype, multi: bool, kind: UpdateKind) Error!UpdateResult {
        comptime checkOptions(@TypeOf(opts), update_options);
        var cx = client_mod.erase(c);
        var ctx: Update(@TypeOf(filter), @TypeOf(update), @TypeOf(opts)) = .{
            .collection = self.name,
            .filter = filter,
            .update = update,
            .opts = opts,
            .multi = multi,
            .kind = kind,
            .arena = cx.arena,
        };
        return client_mod.execute(self.client, &cx, self.op("update", .write, if (multi) .none else .write), &ctx);
    }

    /// Deletes the first document matching `filter`. Options: hint, collation.
    pub fn deleteOne(self: Collection, c: anytype, filter: anytype, opts: anytype) Error!DeleteResult {
        return self.deleteImpl(c, filter, opts, false);
    }

    /// Deletes every document matching `filter` (not retried).
    pub fn deleteMany(self: Collection, c: anytype, filter: anytype, opts: anytype) Error!DeleteResult {
        return self.deleteImpl(c, filter, opts, true);
    }

    fn deleteImpl(self: Collection, c: anytype, filter: anytype, opts: anytype, multi: bool) Error!DeleteResult {
        comptime checkOptions(@TypeOf(opts), delete_options);
        var cx = client_mod.erase(c);
        var ctx: Delete(@TypeOf(filter), @TypeOf(opts)) = .{ .collection = self.name, .filter = filter, .opts = opts, .multi = multi };
        return client_mod.execute(self.client, &cx, self.op("delete", .write, if (multi) .none else .write), &ctx);
    }

    /// Applies `update` to the first document matching `filter` and
    /// returns it, as it was (the default) or, with
    /// `.return_document = .after`, as it became; null when none matched.
    pub fn findOneAndUpdate(self: Collection, comptime T: type, c: anytype, filter: anytype, update: anytype, opts: anytype) Error!?T {
        return self.findAndModify(T, c, filter, update, opts, .update);
    }

    /// `findOneAndUpdate` with a whole replacement document.
    pub fn findOneAndReplace(self: Collection, comptime T: type, c: anytype, filter: anytype, replacement: anytype, opts: anytype) Error!?T {
        return self.findAndModify(T, c, filter, replacement, opts, .replace);
    }

    /// Deletes the first document matching `filter` and returns it, or null.
    pub fn findOneAndDelete(self: Collection, comptime T: type, c: anytype, filter: anytype, opts: anytype) Error!?T {
        return self.findAndModify(T, c, filter, {}, opts, .delete);
    }

    fn findAndModify(self: Collection, comptime T: type, c: anytype, filter: anytype, update: anytype, opts: anytype, kind: ModifyKind) Error!?T {
        comptime checkOptions(@TypeOf(opts), find_and_modify_options);
        var cx = client_mod.erase(c);
        var ctx: FindAndModify(T, @TypeOf(filter), @TypeOf(update), @TypeOf(opts)) = .{
            .collection = self.name,
            .filter = filter,
            .update = update,
            .opts = opts,
            .kind = kind,
            .arena = cx.arena,
        };
        return client_mod.execute(self.client, &cx, self.op("findAndModify", .write, .write), &ctx);
    }

    // -----------------------------------------------------------------------
    // Indexes and the collection itself

    /// Creates an index on `keys` (`.{ .email = 1 }`, `.{ .created = -1 }`,
    /// `.{ .body = "text" }`) unless it exists, and returns its name (by
    /// default as the server would name it: "email_1"). Options: name,
    /// unique, sparse, expire_after_seconds, partial_filter_expression,
    /// collation, hidden, weights, default_language.
    pub fn createIndex(self: Collection, c: anytype, keys: anytype, opts: anytype) Error![]const u8 {
        comptime checkOptions(@TypeOf(opts), index_options);
        var cx = client_mod.erase(c);
        const key_doc = try encodeDoc(&cx, self.client, keys, self.name);
        const name: []const u8 = if (@hasField(@TypeOf(opts), "name")) opts.name else try indexName(cx.arena, key_doc);
        var ctx: CreateIndex(@TypeOf(opts)) = .{ .collection = self.name, .keys = key_doc, .name = name, .opts = opts };
        try client_mod.execute(self.client, &cx, self.op("createIndexes", .write, .none), &ctx);
        return name;
    }

    /// Drops the index named `name`.
    pub fn dropIndex(self: Collection, c: anytype, name: []const u8) Error!void {
        _ = try self.dbHandle().runCommand(c, .{ .dropIndexes = self.name, .index = name });
    }

    /// Drops the collection; one that does not exist is no error.
    pub fn drop(self: Collection, c: anytype) Error!void {
        var cx = client_mod.erase(c);
        var ctx: Drop = .{ .collection = self.name };
        try client_mod.execute(self.client, &cx, self.op("drop", .write, .none), &ctx);
    }

    fn dbHandle(self: Collection) Database {
        return .{ .client = self.client, .name = self.database, .options = self.options };
    }

    // -----------------------------------------------------------------------
    // Cursors

    /// Runs a cursor command and reads every batch into `sink`.
    fn drain(self: Collection, cx: *const Context, comptime name: []const u8, body: anytype, sink: anytype, batch_size: ?i64) Error!void {
        return self.drainKind(cx, name, body, sink, batch_size, .read);
    }

    fn drainKind(self: Collection, cx: *const Context, comptime name: []const u8, body: anytype, sink: anytype, batch_size: ?i64, kind: Operation.Retry) Error!void {
        var first: FirstBatch(@TypeOf(body), @TypeOf(sink)) = .{ .cmd = body, .sink = sink };
        try client_mod.execute(self.client, cx, self.op(name, if (kind == .write) .write else .read, kind), &first);
        var state: CursorState = .{ .client = self.client, .database = self.database, .collection = self.name, .id = first.id, .server = first.server, .session = first.session, .batch_size = batch_size, .options = self.options };
        defer state.finish(cx);
        while (state.id != 0) {
            var more: GetMore(@TypeOf(sink)) = .{ .state = &state, .sink = sink };
            try client_mod.execute(self.client, cx, state.getMoreOp(), &more);
        }
    }

    fn open(self: Collection, comptime T: type, cx: Context, comptime name: []const u8, body: anytype, batch_size: ?i64, kind: Operation.Retry) Error!Cursor(T) {
        var cursor: Cursor(T) = .{ .cx = cx, .state = undefined };
        errdefer cursor.buf.deinit(self.client.gpa);
        var sink: RawSink = .{ .gpa = self.client.gpa, .buf = &cursor.buf };
        var first: FirstBatch(@TypeOf(body), *RawSink) = .{ .cmd = body, .sink = &sink };
        try client_mod.execute(self.client, &cursor.cx, self.op(name, if (kind == .write) .write else .read, kind), &first);
        cursor.state = .{ .client = self.client, .database = self.database, .collection = self.name, .id = first.id, .server = first.server, .session = first.session, .batch_size = batch_size, .options = self.options };
        cursor.it = (bson.Array{ .doc = .{ .bytes = cursor.buf.items } }).iterator();
        return cursor;
    }
};

// The options each call takes, as pairs of the Zig field name and the
// command's: `opts` takes any of them (`.{ .sort = .{ .created = -1 },
// .limit = 20 }`), or `.{}` for none; another field is a compile error
// that lists these. An empty command name is handled by the call itself.

/// The options `find`, `findOne`, `findOptional` and `iterate` take, and
/// `all`, `one` and `optional`, which are the same calls.
const find_options = .{
    .{ "sort", "sort" },            .{ "projection", "projection" },       .{ "skip", "skip" },
    .{ "limit", "limit" },          .{ "batch_size", "batchSize" },        .{ "hint", "hint" },
    .{ "collation", "collation" },  .{ "comment", "comment" },             .{ "allow_disk_use", "allowDiskUse" },
    .{ "let", "let" },              .{ "max", "max" },                     .{ "min", "min" },
    .{ "return_key", "returnKey" }, .{ "show_record_id", "showRecordId" },
};

/// The options `aggregate` and `aggregateIterate` take (see
/// `find_options`).
const aggregate_options = .{
    .{ "allow_disk_use", "allowDiskUse" },                         .{ "batch_size", "batchSize" }, .{ "hint", "hint" },
    .{ "collation", "collation" },                                 .{ "comment", "comment" },      .{ "let", "let" },
    .{ "bypass_document_validation", "bypassDocumentValidation" },
};

/// The options `insertMany` takes (see `find_options`).
const insert_many_options = .{ .{ "ordered", "ordered" }, .{ "bypass_document_validation", "bypassDocumentValidation" }, .{ "comment", "comment" } };

/// The options `updateOne`, `updateMany` and `replaceOne` take (see
/// `find_options`).
const update_options = .{ .{ "upsert", "upsert" }, .{ "array_filters", "arrayFilters" }, .{ "hint", "hint" }, .{ "collation", "collation" } };

/// The options `deleteOne` and `deleteMany` take (see `find_options`).
const delete_options = .{ .{ "hint", "hint" }, .{ "collation", "collation" } };

/// The options `findOneAndUpdate`, `findOneAndReplace` and
/// `findOneAndDelete` take (see `find_options`); `return_document` is
/// a `ReturnDocument`.
const find_and_modify_options = .{
    .{ "sort", "sort" },                  .{ "projection", "fields" }, .{ "upsert", "upsert" },
    .{ "array_filters", "arrayFilters" }, .{ "hint", "hint" },         .{ "collation", "collation" },
    .{ "return_document", "" },           .{ "comment", "comment" },   .{ "let", "let" },
};

/// The options `createIndex` takes (see `find_options`).
const index_options = .{
    .{ "name", "name" },                               .{ "unique", "unique" },                                     .{ "sparse", "sparse" },
    .{ "expire_after_seconds", "expireAfterSeconds" }, .{ "partial_filter_expression", "partialFilterExpression" }, .{ "collation", "collation" },
    .{ "hidden", "hidden" },                           .{ "weights", "weights" },                                   .{ "default_language", "default_language" },
};

/// What `insertOne` returns: the inserted document's `_id` (an ObjectId
/// unless the document brought its own), in the call's arena.
pub const InsertOneResult = struct {
    /// The document's `_id`.
    inserted_id: bson.Value,

    /// The id as an ObjectId, when it is one.
    pub fn objectId(r: InsertOneResult) ?bson.ObjectId {
        return if (r.inserted_id == .object_id) r.inserted_id.object_id else null;
    }
};

/// What `insertMany` returns, in the call's arena.
pub const InsertManyResult = struct {
    /// How many documents went in.
    inserted_count: u64,
    /// By the index of `docs`; `.null` for documents not inserted.
    inserted_ids: []bson.Value,
};

/// What `updateOne`, `updateMany` and `replaceOne` return.
pub const UpdateResult = struct {
    /// Documents that matched the filter.
    matched_count: u64,
    /// Documents that changed (a match the update left as it was is not
    /// counted).
    modified_count: u64,
    /// The new document's `_id` when an upsert inserted one.
    upserted_id: ?bson.Value = null,
};

/// What `deleteOne` and `deleteMany` return.
pub const DeleteResult = struct {
    /// Documents deleted.
    deleted_count: u64,
};

/// The documents of `iterate` and `aggregateIterate`, a batch at a time;
/// each is decoded into the call's arena. `deinit` ends the cursor on the
/// server when it is not exhausted.
pub fn Cursor(comptime T: type) type {
    return struct {
        const Self = @This();

        cx: Context,
        state: CursorState,
        /// The current batch (a BSON array), owned.
        buf: std.ArrayList(u8) = .empty,
        it: @TypeOf(bson.Array.empty.iterator()) = (bson.Array.empty).iterator(),

        /// The next document, or null after the last.
        pub fn next(self: *Self) Error!?T {
            while (true) {
                if (self.it.next()) |v| {
                    if (v != .document) continue;
                    return bson.decodeDocument(T, self.cx.arena, v.document, .{}) catch |err| self.cx.fail(self.state.client.errors, .{
                        .system = .mongodb,
                        .class = .other,
                        .message = if (err == error.MissingField) "a document lacks a field the struct has no default for" else "a document does not fit the struct it is read into",
                        .table = self.state.collection,
                    });
                }
                if (self.state.id == 0) return null;
                var sink: RawSink = .{ .gpa = self.state.client.gpa, .buf = &self.buf };
                var more: GetMore(*RawSink) = .{ .state = &self.state, .sink = &sink };
                try client_mod.execute(self.state.client, &self.cx, self.state.getMoreOp(), &more);
                self.it = (bson.Array{ .doc = .{ .bytes = self.buf.items } }).iterator();
            }
        }

        /// Ends the cursor on the server if documents are left, and frees
        /// the batch.
        pub fn deinit(self: *Self) void {
            self.state.finish(&self.cx);
            self.buf.deinit(self.state.client.gpa);
            self.* = undefined;
        }
    };
}

/// A server-side cursor: its id, where it lives, the session it belongs to.
const CursorState = struct {
    client: *Client,
    database: []const u8,
    collection: []const u8,
    id: i64,
    server: *client_mod.Server,
    session: ?*client_mod.Session,
    batch_size: ?i64,
    options: db.QueryOptions,

    fn getMoreOp(s: *const CursorState) Operation {
        return .{
            .name = "getMore",
            .database = s.database,
            .collection = s.collection,
            .kind = .command,
            .server = s.server,
            .lsid = if (s.session) |sess| sess.id else null,
            .session = false,
            // A getMore's maxTimeMS means something else (awaitData).
            .max_time = false,
            .options = s.options,
        };
    }

    /// killCursors when the cursor is still open (best effort, without the
    /// caller's deadline), then gives the session back.
    fn finish(s: *CursorState, cx: *const Context) void {
        if (s.id != 0) {
            var ctx: KillCursors = .{ .collection = s.collection, .id = s.id };
            var op = s.getMoreOp();
            op.name = "killCursors";
            op.options = .{ .timeout = .fromSeconds(1) };
            // A canceled request still ends its cursors.
            const protection = cx.io.swapCancelProtection(.blocked);
            defer _ = cx.io.swapCancelProtection(protection);
            var buf: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            var quiet: db.Ctx = .{ .io = cx.io, .arena = fba.allocator() };
            const quiet_cx = client_mod.erase(&quiet);
            client_mod.execute(s.client, &quiet_cx, op, &ctx) catch {};
            s.id = 0;
        }
        if (s.session) |sess| client_mod.giveSession(s.client, sess, cx.io);
        s.session = null;
    }
};

// ---------------------------------------------------------------------------
// The commands: each a context for `client_mod.execute` (`body`, `result`).

fn FindBody(comptime F: type, comptime O: type) type {
    comptime checkOptions(O, find_options);
    return struct {
        collection: []const u8,
        filter: F,
        opts: O,
        one: bool = false,

        fn write(self: @This(), b: *bson.Builder) !void {
            try b.append("find", .{ .string = self.collection });
            try appendDocument(b, "filter", self.filter);
            try appendOptions(b, self.opts, find_options);
            if (self.one) {
                if (!@hasField(O, "limit")) try b.append("limit", .{ .int32 = 1 });
                try b.append("singleBatch", .{ .boolean = true });
            }
        }
    };
}

fn AggregateBody(comptime O: type) type {
    comptime checkOptions(O, aggregate_options);
    return struct {
        collection: []const u8,
        pipeline: bson.Array,
        opts: O,

        fn write(self: @This(), b: *bson.Builder) !void {
            try b.append("aggregate", .{ .string = self.collection });
            try b.append("pipeline", .{ .array = self.pipeline });
            try b.beginDocument("cursor");
            if (@hasField(O, "batch_size")) try bson.appendField(b, "batchSize", self.opts.batch_size, .{});
            try b.end();
            try appendOptions(b, pickOptions(self.opts, .{ "allow_disk_use", "hint", "collation", "comment", "let", "bypass_document_validation" }), aggregate_options);
        }
    };
}

fn FirstBatch(comptime Body: type, comptime Sink: type) type {
    return struct {
        pub const Result = void;
        cmd: Body,
        sink: Sink,
        id: i64 = 0,
        server: *client_mod.Server = undefined,
        session: ?*client_mod.Session = null,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try self.cmd.write(b);
        }

        pub fn result(self: *@This(), x: *Exchange, reply: bson.Document) !void {
            const cur = try cursorOf(reply, "firstBatch");
            try self.sink.take(cur.batch);
            self.id = cur.id;
            self.server = x.server;
            if (cur.id != 0) {
                self.session = x.session;
                x.keep_session = true;
            }
        }
    };
}

fn GetMore(comptime Sink: type) type {
    return struct {
        pub const Result = void;
        state: *CursorState,
        sink: Sink,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("getMore", .{ .int64 = self.state.id });
            try b.append("collection", .{ .string = self.state.collection });
            if (self.state.batch_size) |n| try b.append("batchSize", .{ .int64 = n });
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) !void {
            const cur = try cursorOf(reply, "nextBatch");
            try self.sink.take(cur.batch);
            self.state.id = cur.id;
        }

        /// A failed getMore leaves no cursor to kill.
        pub fn accepts(self: *@This(), _: conn_mod.ServerError) bool {
            self.state.id = 0;
            return false;
        }
    };
}

const KillCursors = struct {
    pub const Result = void;
    collection: []const u8,
    id: i64,

    pub fn body(self: *KillCursors, b: *bson.Builder, _: *Exchange) !void {
        try b.append("killCursors", .{ .string = self.collection });
        try b.beginArray("cursors");
        try b.append("", .{ .int64 = self.id });
        try b.end();
    }

    pub fn result(_: *KillCursors, _: *Exchange, _: bson.Document) !void {}
};

const CursorReply = struct { id: i64, batch: bson.Array };

fn cursorOf(reply: bson.Document, batch_name: []const u8) error{InvalidReply}!CursorReply {
    const cur = switch (reply.get("cursor") orelse return error.InvalidReply) {
        .document => |d| d,
        else => return error.InvalidReply,
    };
    const batch = switch (cur.get(batch_name) orelse return error.InvalidReply) {
        .array => |a| a,
        else => return error.InvalidReply,
    };
    return .{ .id = sdam.intOf(cur.get("id")) orelse 0, .batch = batch };
}

/// Decodes every document of each batch into the arena.
fn AllSink(comptime T: type) type {
    return struct {
        arena: std.mem.Allocator,
        out: *std.ArrayList(T),

        fn take(self: *@This(), batch: bson.Array) !void {
            try self.out.ensureUnusedCapacity(self.arena, batch.count());
            var it = batch.iterator();
            while (it.next()) |v| {
                if (v != .document) continue;
                self.out.appendAssumeCapacity(try bson.decodeDocument(T, self.arena, v.document, .{}));
            }
        }
    };
}

/// Keeps the batch's bytes for a `Cursor` to decode one at a time.
const RawSink = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),

    fn take(self: *RawSink, batch: bson.Array) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, batch.doc.bytes);
    }
};

fn RunCommand(comptime C: type) type {
    return struct {
        pub const Result = bson.Document;
        command: C,
        arena: std.mem.Allocator,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try bson.appendFields(b, self.command, .{});
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) !bson.Document {
            return reply.dupe(self.arena);
        }
    };
}

const CountCmd = struct {
    pub const Result = u64;
    collection: []const u8,

    pub fn body(self: *CountCmd, b: *bson.Builder, _: *Exchange) !void {
        try b.append("count", .{ .string = self.collection });
    }

    pub fn result(_: *CountCmd, _: *Exchange, reply: bson.Document) !u64 {
        return @intCast(@max(sdam.intOf(reply.get("n")) orelse 0, 0));
    }
};

fn Distinct(comptime T: type, comptime F: type) type {
    return struct {
        pub const Result = []T;
        collection: []const u8,
        key: []const u8,
        filter: F,
        arena: std.mem.Allocator,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("distinct", .{ .string = self.collection });
            try b.append("key", .{ .string = self.key });
            try appendDocument(b, "query", self.filter);
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) ![]T {
            const values = switch (reply.get("values") orelse return error.InvalidReply) {
                .array => |a| a,
                else => return error.InvalidReply,
            };
            return bson.decodeValue([]T, self.arena, .{ .array = values }, .{});
        }
    };
}

fn Insert(comptime D: type) type {
    return struct {
        pub const Result = void;
        collection: []const u8,
        /// From the first not yet sent.
        docs: []const D,
        ids: []const ?bson.ObjectId,
        ordered: bool,
        arena: std.mem.Allocator,
        out_ids: ?[]bson.Value = null,
        extra: ?bson.Document = null,
        /// How many documents this command carried, and how many went in.
        sent: usize = 0,
        n: u64 = 0,
        first_id: ?bson.Value = null,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("insert", .{ .string = self.collection });
            try b.append("ordered", .{ .boolean = self.ordered });
            if (self.extra) |e| try b.appendElements(e);
        }

        /// The documents as a kind-1 sequence: as many as fit the
        /// server's batch and message limits.
        pub fn sequences(self: *@This(), m: *wire.Message, x: *Exchange) !void {
            const limit_count = x.connection.max_write_batch_size;
            const limit_bytes = x.connection.max_message_size;
            try m.beginSequence("documents");
            var i: usize = 0;
            while (i < self.docs.len and i < limit_count) : (i += 1) {
                const before = m.b.buf.items.len;
                const b = m.b;
                try b.begin();
                if (self.ids[i]) |id| try b.append("_id", .{ .object_id = id });
                try bson.appendFields(b, self.docs[i], .{});
                try b.end();
                const doc_len = b.buf.items.len - before;
                if (doc_len > x.connection.max_bson_object_size) return error.DocumentTooLarge;
                if (b.buf.items.len > limit_bytes) {
                    // The first always goes; a later one waits for the next command.
                    if (i == 0) return error.DocumentTooLarge;
                    b.buf.shrinkRetainingCapacity(before);
                    break;
                }
                if (i == 0 or self.out_ids != null) {
                    const doc: bson.Document = .{ .bytes = b.buf.items[before..] };
                    const id = try (doc.get("_id") orelse @as(bson.Value, .null)).dupe(self.arena);
                    if (i == 0) self.first_id = id;
                    if (self.out_ids) |out| out[i] = id;
                }
            }
            try m.endSequence();
            self.sent = i;
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) !void {
            self.n = @intCast(@max(sdam.intOf(reply.get("n")) orelse 0, 0));
        }
    };
}

const UpdateKind = enum { update, replace };

fn Update(comptime F: type, comptime U: type, comptime O: type) type {
    return struct {
        pub const Result = UpdateResult;
        collection: []const u8,
        filter: F,
        update: U,
        opts: O,
        multi: bool,
        kind: UpdateKind,
        arena: std.mem.Allocator,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("update", .{ .string = self.collection });
            try b.append("ordered", .{ .boolean = true });
        }

        pub fn sequences(self: *@This(), m: *wire.Message, _: *Exchange) !void {
            try m.beginSequence("updates");
            const b = m.b;
            try b.begin();
            try appendDocument(b, "q", self.filter);
            try bson.appendField(b, "u", self.update, .{});
            if (self.multi) try b.append("multi", .{ .boolean = true });
            try appendOptions(b, self.opts, update_options);
            try b.end();
            try m.endSequence();
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) !UpdateResult {
            var out: UpdateResult = .{
                .matched_count = @intCast(@max(sdam.intOf(reply.get("n")) orelse 0, 0)),
                .modified_count = @intCast(@max(sdam.intOf(reply.get("nModified")) orelse 0, 0)),
            };
            if (reply.get("upserted")) |v| if (v == .array) if (v.array.at(0)) |first| if (first == .document) {
                if (first.document.get("_id")) |id| out.upserted_id = try id.dupe(self.arena);
                // An upsert's insert is not counted as matched.
                out.matched_count -|= 1;
            };
            return out;
        }
    };
}

fn Delete(comptime F: type, comptime O: type) type {
    return struct {
        pub const Result = DeleteResult;
        collection: []const u8,
        filter: F,
        opts: O,
        multi: bool,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("delete", .{ .string = self.collection });
            try b.append("ordered", .{ .boolean = true });
        }

        pub fn sequences(self: *@This(), m: *wire.Message, _: *Exchange) !void {
            try m.beginSequence("deletes");
            const b = m.b;
            try b.begin();
            try appendDocument(b, "q", self.filter);
            try b.append("limit", .{ .int32 = if (self.multi) 0 else 1 });
            try appendOptions(b, self.opts, delete_options);
            try b.end();
            try m.endSequence();
        }

        pub fn result(_: *@This(), _: *Exchange, reply: bson.Document) !DeleteResult {
            return .{ .deleted_count = @intCast(@max(sdam.intOf(reply.get("n")) orelse 0, 0)) };
        }
    };
}

const ModifyKind = enum { update, replace, delete };

/// `findOneAndUpdate`'s `return_document`.
pub const ReturnDocument = enum { before, after };

fn FindAndModify(comptime T: type, comptime F: type, comptime U: type, comptime O: type) type {
    return struct {
        pub const Result = ?T;
        collection: []const u8,
        filter: F,
        update: U,
        opts: O,
        kind: ModifyKind,
        arena: std.mem.Allocator,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("findAndModify", .{ .string = self.collection });
            try appendDocument(b, "query", self.filter);
            if (self.kind == .delete) {
                try b.append("remove", .{ .boolean = true });
            } else {
                if (U != void) try bson.appendField(b, "update", self.update, .{});
                if (@hasField(O, "return_document")) {
                    const rd: ReturnDocument = self.opts.return_document;
                    try b.append("new", .{ .boolean = rd == .after });
                }
            }
            try appendOptions(b, self.opts, find_and_modify_options);
        }

        pub fn result(self: *@This(), _: *Exchange, reply: bson.Document) !?T {
            const v = reply.get("value") orelse return null;
            return switch (v) {
                .document => |d| try bson.decodeDocument(T, self.arena, d, .{}),
                else => null,
            };
        }
    };
}

fn CreateIndex(comptime O: type) type {
    return struct {
        pub const Result = void;
        collection: []const u8,
        keys: bson.Document,
        name: []const u8,
        opts: O,

        pub fn body(self: *@This(), b: *bson.Builder, _: *Exchange) !void {
            try b.append("createIndexes", .{ .string = self.collection });
            try b.beginArray("indexes");
            try b.beginDocument("");
            try b.append("key", .{ .document = self.keys });
            try b.append("name", .{ .string = self.name });
            try appendOptions(b, pickOptions(self.opts, .{ "unique", "sparse", "expire_after_seconds", "partial_filter_expression", "collation", "hidden", "weights", "default_language" }), index_options);
            try b.end();
            try b.end();
        }

        pub fn result(_: *@This(), _: *Exchange, _: bson.Document) !void {}
    };
}

const Drop = struct {
    pub const Result = void;
    collection: []const u8,

    pub fn body(self: *Drop, b: *bson.Builder, _: *Exchange) !void {
        try b.append("drop", .{ .string = self.collection });
    }

    pub fn result(_: *Drop, _: *Exchange, _: bson.Document) !void {}

    /// NamespaceNotFound: there was nothing to drop.
    pub fn accepts(_: *Drop, se: conn_mod.ServerError) bool {
        return se.code == 26 or std.mem.indexOf(u8, se.message, "ns not found") != null;
    }
};

// ---------------------------------------------------------------------------
// Options and encoding

/// A compile error for a field of `O` that `names` (pairs of the Zig name
/// and the command's) does not list.
fn checkOptions(comptime O: type, comptime names: anytype) void {
    if (O == @TypeOf(.{})) return;
    const info = @typeInfo(O);
    if (info != .@"struct") @compileError("options are an anonymous struct literal, such as .{ .limit = 10 }, not " ++ @typeName(O));
    outer: for (info.@"struct".field_names) |field| {
        for (names) |pair| if (std.mem.eql(u8, pair[0], field)) continue :outer;
        var list: []const u8 = "";
        for (names, 0..) |pair, i| list = list ++ (if (i > 0) ", " else "") ++ pair[0];
        @compileError("unknown option ." ++ field ++ "; this call takes: " ++ list);
    }
}

/// Appends the fields of `opts` that `names` maps to a command field (an
/// empty one is handled by the caller), under that name.
fn appendOptions(b: *bson.Builder, opts: anytype, comptime names: anytype) !void {
    const O = @TypeOf(opts);
    if (@typeInfo(O) != .@"struct") return;
    inline for (@typeInfo(O).@"struct".field_names) |field| {
        const wire_name = comptime for (names) |pair| {
            if (std.mem.eql(u8, pair[0], field)) break pair[1];
        } else "";
        if (wire_name.len > 0) try bson.appendField(b, wire_name, @field(opts, field), .{});
    }
}

/// The fields of `opts` named in `keep`, as a new anonymous struct.
fn pickOptions(opts: anytype, comptime keep: anytype) Picked(@TypeOf(opts), keep) {
    var out: Picked(@TypeOf(opts), keep) = undefined;
    inline for (@typeInfo(@TypeOf(out)).@"struct".field_names) |field| @field(out, field) = @field(opts, field);
    return out;
}

fn Picked(comptime O: type, comptime keep: anytype) type {
    if (@typeInfo(O) != .@"struct") return struct {};
    const all_names = @typeInfo(O).@"struct".field_names;
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    for (all_names, @typeInfo(O).@"struct".field_types) |field, F| {
        for (keep) |k| if (std.mem.eql(u8, k, field)) {
            names = names ++ .{field};
            types = types ++ .{F};
        };
    }
    const n = names.len;
    const name_array: [n][]const u8 = names[0..n].*;
    const type_array: [n]type = types[0..n].*;
    return @Struct(.auto, null, &name_array, &type_array, &@splat(.{}));
}

/// `opts`' fields that `names` maps, as a document in `arena`.
fn encodeOptionsAlloc(arena: std.mem.Allocator, opts: anytype, comptime names: anytype) !?bson.Document {
    if (@typeInfo(@TypeOf(opts)) != .@"struct" or @typeInfo(@TypeOf(opts)).@"struct".field_names.len == 0) return null;
    var b: bson.Builder = .init(arena);
    try b.begin();
    inline for (@typeInfo(@TypeOf(opts)).@"struct".field_names) |field| {
        const wire_name = comptime for (names) |pair| {
            if (std.mem.eql(u8, pair[0], field)) break pair[1];
        } else "";
        // `ordered` goes in the command itself.
        if (wire_name.len > 0 and !std.mem.eql(u8, field, "ordered")) bson.appendField(&b, wire_name, @field(opts, field), .{}) catch return error.OutOfMemory;
    }
    try b.end();
    return .{ .bytes = b.bytes() };
}

fn batchSizeOf(opts: anytype) ?i64 {
    if (@typeInfo(@TypeOf(opts)) == .@"struct" and @hasField(@TypeOf(opts), "batch_size")) return opts.batch_size;
    return null;
}

/// `pipeline` (a tuple of stages, or a `bson.Array`) as a BSON array in
/// the arena, encoded once for every attempt.
fn encodePipeline(cx: *const Context, client: *Client, pipeline: anytype, collection: []const u8) Error!bson.Array {
    if (@TypeOf(pipeline) == bson.Array) return pipeline;
    const doc = try encodeDoc(cx, client, .{ .p = pipeline }, collection);
    return switch (doc.get("p").?) {
        .array => |a| a,
        else => cx.fail(client.errors, .{ .system = .mongodb, .class = .other, .message = "a pipeline is a tuple of stages", .table = collection }),
    };
}

fn encodeDoc(cx: *const Context, client: *Client, v: anytype, collection: []const u8) Error!bson.Document {
    if (@TypeOf(v) == bson.Document) return v;
    const bytes = bson.encode(cx.arena, v, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => cx.fail(client.errors, .{ .system = .mongodb, .class = .other, .message = "a value could not be encoded as BSON", .table = collection }),
    };
    return .{ .bytes = bytes };
}

/// The pipeline's last stage is `$out` or `$merge`.
/// Whether a pipeline of type `P` is known at compile time to only read:
/// a tuple of stages (structs) whose last is neither `$out` nor `$merge`.
fn readsOnly(comptime P: type) bool {
    const info = @typeInfo(P);
    if (info != .@"struct" or !info.@"struct".is_tuple) return false;
    const stages = info.@"struct".field_types;
    for (stages) |S| if (@typeInfo(S) != .@"struct") return false;
    if (stages.len == 0) return true;
    const last = @typeInfo(stages[stages.len - 1]).@"struct".field_names;
    for (last) |name| if (std.mem.eql(u8, name, "$out") or std.mem.eql(u8, name, "$merge")) return false;
    return true;
}

fn writes(pipeline: bson.Array) bool {
    var last: ?bson.Value = null;
    var it = pipeline.iterator();
    while (it.next()) |v| last = v;
    const stage = last orelse return false;
    if (stage != .document) return false;
    var fields = stage.document.iterator();
    const first = fields.next() orelse return false;
    return std.mem.eql(u8, first.name, "$out") or std.mem.eql(u8, first.name, "$merge");
}

/// Whether `doc` brings its own `_id`.
fn hasId(doc: anytype) bool {
    const D = @TypeOf(doc);
    if (D == bson.Document) return doc.get("_id") != null;
    switch (@typeInfo(D)) {
        .@"struct" => {
            if (!@hasField(D, "_id")) return false;
            const F = @FieldType(D, "_id");
            if (@typeInfo(F) == .optional) return @field(doc, "_id") != null;
            return true;
        },
        .pointer => |p| if (p.size == .one) return hasId(doc.*),
        else => {},
    }
    return false;
}

/// `v` as a document: `.{}` (an empty tuple to the BSON mapping, so an
/// empty array) means the empty document wherever a document goes.
fn asDocument(v: anytype) if (@TypeOf(v) == @TypeOf(.{})) bson.Document else @TypeOf(v) {
    return if (@TypeOf(v) == @TypeOf(.{})) .empty else v;
}

fn appendDocument(b: *bson.Builder, name: []const u8, v: anytype) !void {
    try bson.appendField(b, name, asDocument(v), .{});
}

/// The name the server gives an index on `keys`: "a_1_b_-1".
fn indexName(arena: std.mem.Allocator, keys: bson.Document) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var it = keys.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) out.writer.writeByte('_') catch return error.OutOfMemory;
        first = false;
        out.writer.writeAll(e.name) catch return error.OutOfMemory;
        out.writer.writeByte('_') catch return error.OutOfMemory;
        (switch (e.value) {
            .int32 => |n| out.writer.print("{d}", .{n}),
            .int64 => |n| out.writer.print("{d}", .{n}),
            .double => |n| out.writer.print("{d}", .{n}),
            .string => |s| out.writer.writeAll(s),
            else => out.writer.writeAll("x"),
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "hasId: structs, optionals, documents" {
    try testing.expect(!hasId(.{ .name = "a" }));
    try testing.expect(hasId(.{ ._id = 5 }));
    const WithOptional = struct { _id: ?bson.ObjectId = null, name: []const u8 };
    try testing.expect(!hasId(WithOptional{ .name = "a" }));
    try testing.expect(hasId(WithOptional{ ._id = bson.ObjectId.generate(testing.io), .name = "a" }));
}

test "indexName: as the server names them" {
    const bytes = try bson.encode(testing.allocator, .{ .email = 1, .created = -1, .body = "text" }, .{});
    defer testing.allocator.free(bytes);
    const name = try indexName(testing.allocator, .{ .bytes = bytes });
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("email_1_created_-1_body_text", name);
}

test "writes: a pipeline ending in $out or $merge" {
    const a = try bson.encode(testing.allocator, .{ .p = .{ .{ .@"$match" = .{ .x = 1 } }, .{ .@"$out" = "copy" } } }, .{});
    defer testing.allocator.free(a);
    try testing.expect(writes((bson.Document{ .bytes = a }).get("p").?.array));
    const b = try bson.encode(testing.allocator, .{ .p = .{.{ .@"$match" = .{ .x = 1 } }} }, .{});
    defer testing.allocator.free(b);
    try testing.expect(!writes((bson.Document{ .bytes = b }).get("p").?.array));
}

test "options: picked and appended under the command's names" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.begin();
    try appendOptions(&b, .{ .batch_size = 5, .allow_disk_use = true }, find_options);
    try b.end();
    const doc: bson.Document = .{ .bytes = b.bytes() };
    try testing.expectEqual(@as(i32, 5), doc.get("batchSize").?.int32);
    try testing.expect(doc.get("allowDiskUse").?.boolean);
    const picked = pickOptions(.{ .hint = "x", .skip = 3 }, .{"hint"});
    try testing.expectEqualStrings("x", picked.hint);
    try testing.expect(!@hasField(@TypeOf(picked), "skip"));
}
