//! MongoDB change streams, as the drivers' change-streams specification has
//! them: an `aggregate` whose first stage is `$changeStream`, a cursor read
//! with `getMore` (the server holds each one up to `maxTimeMS`, awaitData),
//! the resume token cached after every event and every batch, and an
//! automatic resume on the errors the specification calls resumable.
//!
//!     var stream = try app.db.collection("orders").watch(bson.Document, req, .{}, .{});
//!     defer stream.deinit();
//!     while (try stream.next()) |event| { ... }
//!
//! `Collection.watch`, `Database.watch` and `Client.watch` open one. A stream
//! holds the request (or `anole.db.Ctx`) it was opened with, and one
//! pooled connection while it waits in a `getMore`. `anole.watch` runs one
//! per watch and feeds topics with it.

const std = @import("std");
const bson = @import("bson");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const client_mod = @import("client.zig");
const conn_mod = @import("connection.zig");
const sdam = @import("sdam.zig");

const Client = client_mod.Client;
const Context = client_mod.Context;
const Exchange = client_mod.Exchange;
const Operation = client_mod.Operation;
pub const Error = client_mod.Error;

pub const FullDocument = enum { default, update_lookup, when_available, required };
pub const FullDocumentBeforeChange = enum { off, when_available, required };

pub const ChangeStreamOptions = struct {
    full_document: FullDocument = .default,
    full_document_before_change: FullDocumentBeforeChange = .off,
    /// Events after this token (an event's `_id`).
    resume_after: ?bson.Document = null,
    /// Like `resume_after`, and survives an `invalidate` event.
    start_after: ?bson.Document = null,
    start_at_operation_time: ?bson.Timestamp = null,
    /// How long a `getMore` may wait for an event (the server's
    /// `maxAwaitTimeMS`); null: the server's, 1 s.
    max_await: ?std.Io.Duration = null,
    batch_size: ?u32 = null,
    show_expanded_events: bool = false,
    comment: ?[]const u8 = null,
};

/// The change event, typed: a convenient `T` for `ChangeStream`.
pub const ChangeEvent = struct {
    _id: bson.Document,
    operationType: []const u8,
    ns: ?struct { db: []const u8, coll: ?[]const u8 = null } = null,
    documentKey: ?bson.Document = null,
    fullDocument: ?bson.Document = null,
    fullDocumentBeforeChange: ?bson.Document = null,
    updateDescription: ?bson.Document = null,
    clusterTime: ?bson.Timestamp = null,
};

/// What a stream watches.
pub const Scope = union(enum) {
    collection: struct { database: []const u8, name: []const u8 },
    database: []const u8,
    cluster,
};

/// What the server said about the last failed command, kept by the
/// commands' `accepts` hook for the resume decision.
const ErrInfo = struct {
    have: bool = false,
    code: i64 = 0,
    resumable_label: bool = false,
    non_resumable_label: bool = false,
};

const Mode = enum { none, resume_after, start_after, operation_time };

/// A change stream over BSON events; `ChangeStream(T)` decodes them.
pub const Stream = struct {
    client: *Client,
    cx: Context,
    scope: Scope,
    opts: ChangeStreamOptions,
    /// The user's stages after `$changeStream`: a BSON array, owned.
    stages: []u8,
    /// The cursor.
    id: i64 = 0,
    server: *client_mod.Server = undefined,
    session: ?*client_mod.Session = null,
    /// The cursor's collection name for `getMore` (from the reply's `ns`).
    more_collection: []u8 = &.{},
    /// The current batch (a BSON array), owned, and the read position in it.
    buf: std.ArrayList(u8) = .empty,
    it: @TypeOf(bson.Array.empty.iterator()) = (bson.Array.empty).iterator(),
    /// The resume token to use (an event's `_id` or a batch's
    /// `postBatchResumeToken`), a document, owned.
    token: ?[]u8 = null,
    /// The batch's `postBatchResumeToken`, owned; becomes `token` once the
    /// batch is read through.
    pbrt: ?[]u8 = null,
    initial: Mode = .none,
    initial_time: ?bson.Timestamp = null,
    /// The open's `operationTime`, for a resume before any token.
    op_time: ?bson.Timestamp = null,
    had_event: bool = false,
    err: ErrInfo = .{},

    /// Opens the stream (the `aggregate`) and reads the first batch.
    fn open(client: *Client, cx: Context, scope: Scope, pipeline_stages: bson.Array, opts: ChangeStreamOptions) Error!Stream {
        var s: Stream = .{
            .client = client,
            .cx = cx,
            .scope = scope,
            .opts = opts,
            .stages = &.{},
        };
        errdefer s.deinitBuffers();
        s.stages = client.gpa.dupe(u8, pipeline_stages.doc.bytes) catch return error.OutOfMemory;
        if (opts.start_after) |d| {
            s.token = client.gpa.dupe(u8, d.bytes) catch return error.OutOfMemory;
            s.initial = .start_after;
        } else if (opts.resume_after) |d| {
            s.token = client.gpa.dupe(u8, d.bytes) catch return error.OutOfMemory;
            s.initial = .resume_after;
        } else if (opts.start_at_operation_time) |t| {
            s.initial = .operation_time;
            s.initial_time = t;
        }
        try s.run(s.chooseMode());
        return s;
    }

    /// Ends the cursor on the server and frees the stream.
    pub fn deinit(s: *Stream) void {
        s.killCursor();
        s.deinitBuffers();
        s.* = undefined;
    }

    fn deinitBuffers(s: *Stream) void {
        const gpa = s.client.gpa;
        if (s.stages.len > 0) gpa.free(s.stages);
        if (s.token) |t| gpa.free(t);
        if (s.pbrt) |t| gpa.free(t);
        if (s.more_collection.len > 0) gpa.free(s.more_collection);
        s.buf.deinit(gpa);
        s.stages = &.{};
        s.token = null;
        s.pbrt = null;
        s.more_collection = &.{};
    }

    /// The database a command goes to.
    fn databaseName(s: *const Stream) []const u8 {
        return switch (s.scope) {
            .collection => |c| c.database,
            .database => |d| d,
            .cluster => "admin",
        };
    }

    fn collectionName(s: *const Stream) ?[]const u8 {
        return switch (s.scope) {
            .collection => |c| c.name,
            else => null,
        };
    }

    fn chooseMode(s: *const Stream) Mode {
        if (s.token != null) {
            if (s.initial == .start_after and !s.had_event) return .start_after;
            return .resume_after;
        }
        if (s.op_time != null or s.initial_time != null) return .operation_time;
        return .none;
    }

    // -- the commands ----------------------------------------------------

    fn writeAggregate(s: *Stream, b: *bson.Builder, mode: Mode) !void {
        switch (s.scope) {
            .collection => |c| try b.append("aggregate", .{ .string = c.name }),
            else => try b.append("aggregate", .{ .int32 = 1 }),
        }
        try b.beginArray("pipeline");
        try b.beginDocument("");
        try b.beginDocument("$changeStream");
        switch (s.opts.full_document) {
            .default => {},
            .update_lookup => try b.append("fullDocument", .{ .string = "updateLookup" }),
            .when_available => try b.append("fullDocument", .{ .string = "whenAvailable" }),
            .required => try b.append("fullDocument", .{ .string = "required" }),
        }
        switch (s.opts.full_document_before_change) {
            .off => {},
            .when_available => try b.append("fullDocumentBeforeChange", .{ .string = "whenAvailable" }),
            .required => try b.append("fullDocumentBeforeChange", .{ .string = "required" }),
        }
        switch (mode) {
            .none => {},
            .resume_after => try b.append("resumeAfter", .{ .document = .{ .bytes = s.token.? } }),
            .start_after => try b.append("startAfter", .{ .document = .{ .bytes = s.token.? } }),
            .operation_time => try b.append("startAtOperationTime", .{ .timestamp = s.op_time orelse s.initial_time.? }),
        }
        if (s.scope == .cluster) try b.append("allChangesForCluster", .{ .boolean = true });
        if (s.opts.show_expanded_events) try b.append("showExpandedEvents", .{ .boolean = true });
        try b.end(); // $changeStream
        try b.end(); // the stage
        const user: bson.Array = .{ .doc = .{ .bytes = s.stages } };
        var it = user.iterator();
        while (it.next()) |v| try b.append("", v);
        try b.end(); // pipeline
        try b.beginDocument("cursor");
        if (s.opts.batch_size) |n| try b.append("batchSize", .{ .int32 = @intCast(@min(n, std.math.maxInt(i32))) });
        try b.end();
        if (s.opts.comment) |c| try b.append("comment", .{ .string = c });
    }

    const OpenCmd = struct {
        pub const Result = void;
        s: *Stream,
        mode: Mode,
        got_cursor: bool = false,

        pub fn body(self: *OpenCmd, b: *bson.Builder, _: *Exchange) !void {
            try self.s.writeAggregate(b, self.mode);
        }

        pub fn result(self: *OpenCmd, x: *Exchange, reply: bson.Document) !void {
            const s = self.s;
            const cur = switch (reply.get("cursor") orelse return error.InvalidReply) {
                .document => |d| d,
                else => return error.InvalidReply,
            };
            const batch = switch (cur.get("firstBatch") orelse return error.InvalidReply) {
                .array => |a| a,
                else => return error.InvalidReply,
            };
            try s.takeBatch(batch, cur);
            s.id = sdam.intOf(cur.get("id")) orelse 0;
            s.server = x.server;
            // The collection `getMore` names: the part of `ns` after the database.
            const ns = sdam.stringOf(cur.get("ns")) orelse "";
            const dot = std.mem.indexOfScalar(u8, ns, '.');
            const coll_name = if (dot) |d| ns[d + 1 ..] else "";
            if (s.more_collection.len > 0) s.client.gpa.free(s.more_collection);
            s.more_collection = try s.client.gpa.dupe(u8, if (coll_name.len > 0) coll_name else "$cmd.aggregate");
            if (s.op_time == null and s.token == null) {
                if (reply.get("operationTime")) |v| if (v == .timestamp) {
                    s.op_time = v.timestamp;
                };
            }
            if (s.id != 0) {
                s.session = x.session;
                x.keep_session = true;
            }
            self.got_cursor = true;
        }

        pub fn accepts(self: *OpenCmd, se: conn_mod.ServerError) bool {
            self.s.noteError(se);
            return false;
        }
    };

    const MoreCmd = struct {
        pub const Result = void;
        s: *Stream,

        pub fn body(self: *MoreCmd, b: *bson.Builder, _: *Exchange) !void {
            const s = self.s;
            try b.append("getMore", .{ .int64 = s.id });
            try b.append("collection", .{ .string = s.more_collection });
            if (s.opts.batch_size) |n| try b.append("batchSize", .{ .int64 = n });
            if (s.opts.max_await) |d| try b.append("maxTimeMS", .{ .int64 = @max(1, d.toMilliseconds()) });
        }

        pub fn result(self: *MoreCmd, _: *Exchange, reply: bson.Document) !void {
            const s = self.s;
            const cur = switch (reply.get("cursor") orelse return error.InvalidReply) {
                .document => |d| d,
                else => return error.InvalidReply,
            };
            const batch = switch (cur.get("nextBatch") orelse return error.InvalidReply) {
                .array => |a| a,
                else => return error.InvalidReply,
            };
            try s.takeBatch(batch, cur);
            s.id = sdam.intOf(cur.get("id")) orelse 0;
        }

        /// A failed getMore leaves no cursor to kill; the error is noted
        /// for the resume decision.
        pub fn accepts(self: *MoreCmd, se: conn_mod.ServerError) bool {
            self.s.noteError(se);
            return false;
        }
    };

    const KillCmd = struct {
        pub const Result = void;
        collection: []const u8,
        id: i64,

        pub fn body(self: *KillCmd, b: *bson.Builder, _: *Exchange) !void {
            try b.append("killCursors", .{ .string = self.collection });
            try b.beginArray("cursors");
            try b.append("", .{ .int64 = self.id });
            try b.end();
        }

        pub fn result(_: *KillCmd, _: *Exchange, _: bson.Document) !void {}
    };

    fn noteError(s: *Stream, se: conn_mod.ServerError) void {
        s.err = .{
            .have = true,
            .code = se.code orelse 0,
            .resumable_label = se.hasLabel("ResumableChangeStreamError"),
            .non_resumable_label = se.hasLabel("NonResumableChangeStreamError"),
        };
    }

    /// Keeps the batch for reading, and its post-batch resume token.
    fn takeBatch(s: *Stream, batch: bson.Array, cur: bson.Document) !void {
        const gpa = s.client.gpa;
        s.buf.clearRetainingCapacity();
        try s.buf.appendSlice(gpa, batch.doc.bytes);
        s.it = (bson.Array{ .doc = .{ .bytes = s.buf.items } }).iterator();
        if (s.pbrt) |old| gpa.free(old);
        s.pbrt = null;
        if (cur.get("postBatchResumeToken")) |v| if (v == .document) {
            s.pbrt = try gpa.dupe(u8, v.document.bytes);
        };
    }

    /// The aggregate, with `mode`'s resume option.
    fn run(s: *Stream, mode: Mode) Error!void {
        s.err = .{};
        var cmd: OpenCmd = .{ .s = s, .mode = mode };
        const op: Operation = .{
            .name = "aggregate",
            .database = s.databaseName(),
            .collection = s.collectionName(),
            .kind = .read,
            .retry = .read,
            .options = .{},
        };
        client_mod.execute(s.client, &s.cx, op, &cmd) catch |err| return s.mapOpenFailure(err);
    }

    /// One `getMore`, held by the server up to `max_await`.
    fn getMore(s: *Stream) Error!void {
        s.err = .{};
        var cmd: MoreCmd = .{ .s = s };
        const base: std.Io.Duration = internal.callTimeout(null, s.client.options.timeout) orelse .fromSeconds(30);
        const await_ms: i64 = if (s.opts.max_await) |d| d.toMilliseconds() else 1000;
        const op: Operation = .{
            .name = "getMore",
            .database = s.databaseName(),
            .collection = s.more_collection,
            .kind = .command,
            .server = s.server,
            .lsid = if (s.session) |sess| sess.id else null,
            .session = false,
            // The command carries its own maxTimeMS: the await.
            .max_time = false,
            .options = .{ .timeout = .fromMilliseconds(base.toMilliseconds() + await_ms) },
        };
        client_mod.execute(s.client, &s.cx, op, &cmd) catch |err| {
            // A failed getMore leaves no cursor on the server to kill.
            s.id = 0;
            return err;
        };
    }

    /// killCursors when the cursor is still open (best effort, whatever the
    /// caller's deadline), then gives the session back.
    fn killCursor(s: *Stream) void {
        if (s.id != 0 and s.more_collection.len > 0) {
            var cmd: KillCmd = .{ .collection = s.more_collection, .id = s.id };
            const op: Operation = .{
                .name = "killCursors",
                .database = s.databaseName(),
                .collection = s.more_collection,
                .kind = .command,
                .server = s.server,
                .lsid = if (s.session) |sess| sess.id else null,
                .session = false,
                .max_time = false,
                .options = .{ .timeout = .fromSeconds(1) },
            };
            const protection = s.cx.io.swapCancelProtection(.blocked);
            defer _ = s.cx.io.swapCancelProtection(protection);
            var buf: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            var quiet: db.Ctx = .{ .io = s.cx.io, .arena = fba.allocator() };
            const quiet_cx = client_mod.erase(&quiet);
            client_mod.execute(s.client, &quiet_cx, op, &cmd) catch {};
            s.id = 0;
        }
        if (s.session) |sess| client_mod.giveSession(s.client, sess, s.cx.io);
        s.session = null;
    }

    // -- errors and resume -----------------------------------------------

    /// The codes servers without error labels (before 4.4) mean by
    /// resumable (the specification's list), and `CursorNotFound`.
    const resumable_codes = [_]i64{ 6, 7, 89, 91, 189, 262, 9001, 10107, 11600, 11602, 13435, 13436, 63, 150, 13388, 234, 133, 43 };

    fn isResumable(s: *const Stream, err: anyerror) bool {
        if (err == error.Canceled or err == error.OutOfMemory) return false;
        if (s.err.have) {
            if (s.err.non_resumable_label) return false;
            if (s.err.resumable_label) return true;
            for (resumable_codes) |c| if (c == s.err.code) return true;
            return false;
        }
        // No server error: the connection broke, or the server went away.
        return err == error.ServiceUnavailable or err == error.GatewayTimeout;
    }

    /// A failure of the opening aggregate or a resume: the specification's
    /// fatal cases get a code of their own for `lastError`.
    fn mapOpenFailure(s: *Stream, err: Error) Error {
        if (!s.err.have) return err;
        switch (s.err.code) {
            40573 => return s.cx.fail(s.client.errors, .{
                .system = .mongodb,
                .class = .other,
                .code = "change_streams_need_replica_set",
                .message = "MongoDB change streams need a replica set or a sharded cluster: start mongod with --replSet rs0 and run rs.initiate() once (a single-node replica set works)",
                .table = s.collectionName(),
            }),
            286 => return s.historyLost(),
            else => return err,
        }
    }

    fn historyLost(s: *Stream) Error {
        return s.cx.fail(s.client.errors, .{
            .system = .mongodb,
            .class = .other,
            .code = "change_stream_history_lost",
            .message = "the oplog no longer holds the events after the stream's resume token: events were lost; start a new stream",
            .table = s.collectionName(),
        });
    }

    /// Resumes once after a resumable failure: the dead cursor is killed,
    /// a server is selected again, the aggregate runs with the cached
    /// token.
    fn resumeAfter(s: *Stream, failure: Error) Error!void {
        if (!s.isResumable(failure)) {
            if (s.err.have and s.err.code == 286) return s.historyLost();
            return failure;
        }
        s.killCursor();
        try s.run(s.chooseMode());
    }

    // -- reading ---------------------------------------------------------

    /// The next event, waiting (`getMore` after `getMore`) until one comes;
    /// null once the cursor is closed (after an `invalidate` event). The
    /// document points into the stream's batch: valid until the next call.
    pub fn nextDocument(s: *Stream) Error!?bson.Document {
        while (true) {
            if (try s.tryNextDocument()) |d| return d;
            if (s.id == 0) return null;
        }
    }

    /// One round: an event from the batch, or one `getMore` (held by the
    /// server up to `max_await`) and then an event, or null when none came
    /// (or the cursor is closed: `nextDocument` tells the two apart).
    pub fn tryNextDocument(s: *Stream) Error!?bson.Document {
        if (try s.fromBatch()) |d| return d;
        if (s.id == 0) return null;
        s.getMore() catch |err| {
            try s.resumeAfter(err);
            return s.fromBatch();
        };
        return s.fromBatch();
    }

    fn fromBatch(s: *Stream) Error!?bson.Document {
        while (s.it.next()) |v| {
            if (v != .document) continue;
            const id = switch (v.document.get("_id") orelse return s.cx.fail(s.client.errors, .{
                .system = .mongodb,
                .class = .other,
                .code = "change_stream_missing_id",
                .message = "the change stream's pipeline removed _id from an event, which resuming needs; leave _id in the projection",
                .table = s.collectionName(),
            })) {
                .document => |d| d,
                else => return s.cx.fail(s.client.errors, .{
                    .system = .mongodb,
                    .class = .other,
                    .code = "change_stream_missing_id",
                    .message = "the change stream's pipeline changed _id of an event, which resuming needs",
                    .table = s.collectionName(),
                }),
            };
            try s.setToken(id.bytes);
            s.had_event = true;
            return v.document;
        }
        // The batch is read through: its post-batch token is the position.
        if (s.pbrt) |p| {
            try s.setToken(p);
            s.client.gpa.free(p);
            s.pbrt = null;
        }
        return null;
    }

    fn setToken(s: *Stream, bytes: []const u8) Error!void {
        const gpa = s.client.gpa;
        const copy = gpa.dupe(u8, bytes) catch return error.OutOfMemory;
        if (s.token) |old| gpa.free(old);
        s.token = copy;
    }

    /// The token to resume after the last event returned (or the last
    /// batch's `postBatchResumeToken`), copied into `arena`.
    pub fn resumeToken(s: *const Stream, arena: std.mem.Allocator) error{OutOfMemory}!?bson.Document {
        const t = s.token orelse return null;
        return .{ .bytes = try arena.dupe(u8, t) };
    }
};

/// A change stream whose events decode into `T` (`bson.Document` for the
/// raw event: use `nextDocument` of `raw` for a view without a copy).
pub fn ChangeStream(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: Stream,

        /// The next event, waiting until one comes; null after an
        /// `invalidate` (the stream is closed).
        pub fn next(self: *Self) Error!?T {
            const doc = (try self.raw.nextDocument()) orelse return null;
            return try self.decode(doc);
        }

        /// One `getMore`: an event, or null when none came within `max_await`.
        pub fn tryNext(self: *Self) Error!?T {
            const doc = (try self.raw.tryNextDocument()) orelse return null;
            return try self.decode(doc);
        }

        fn decode(self: *Self, doc: bson.Document) Error!T {
            if (T == bson.Document) return doc.dupe(self.raw.cx.arena) catch error.OutOfMemory;
            return bson.decodeDocument(T, self.raw.cx.arena, doc, .{}) catch self.raw.cx.fail(self.raw.client.errors, .{
                .system = .mongodb,
                .class = .other,
                .message = "a change event does not fit the struct it is read into",
                .table = self.raw.collectionName(),
            });
        }

        /// The token to resume after the last event returned (or the
        /// batch's `postBatchResumeToken`), copied into `arena`.
        pub fn resumeToken(self: *Self, arena: std.mem.Allocator) error{OutOfMemory}!?bson.Document {
            return self.raw.resumeToken(arena);
        }

        pub fn deinit(self: *Self) void {
            self.raw.deinit();
        }
    };
}

/// Opens a stream over `scope`: `pipeline` is a tuple of stages (or a
/// `bson.Array`) after `$changeStream`. Used by `Collection.watch` and
/// the like.
pub fn open(client: *Client, c: anytype, scope: Scope, pipeline: anytype, opts: ChangeStreamOptions) Error!Stream {
    const cx = client_mod.erase(c);
    const stages = try encodeStages(&cx, client, pipeline);
    return Stream.open(client, cx, scope, stages, opts);
}

fn encodeStages(cx: *const Context, client: *Client, pipeline: anytype) Error!bson.Array {
    if (@TypeOf(pipeline) == bson.Array) return pipeline;
    const bytes = bson.encode(cx.arena, .{ .p = pipeline }, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => cx.fail(client.errors, .{ .system = .mongodb, .class = .other, .message = "a pipeline is a tuple of stages" }),
    };
    const doc: bson.Document = .{ .bytes = bytes };
    return switch (doc.get("p").?) {
        .array => |a| a,
        else => cx.fail(client.errors, .{ .system = .mongodb, .class = .other, .message = "a pipeline is a tuple of stages" }),
    };
}

/// Opens a stream whose pipeline is an Extended JSON array
/// (`[{"$match": {...}}]`), as `anole.watch` takes it. `pipeline_json`
/// is parsed into `arena`.
pub fn openJson(client: *Client, c: anytype, scope: Scope, pipeline_json: []const u8, opts: ChangeStreamOptions) !Stream {
    const cx = client_mod.erase(c);
    const arr = try parsePipeline(cx.arena, pipeline_json);
    return Stream.open(client, cx, scope, arr, opts);
}

pub const PipelineError = error{ InvalidPipeline, OutOfMemory };

/// `text`, an Extended JSON array of stage documents, as a BSON array
/// in `arena`.
pub fn parsePipeline(arena: std.mem.Allocator, text: []const u8) PipelineError!bson.Array {
    var wrapped: std.ArrayList(u8) = .empty;
    wrapped.appendSlice(arena, "{\"p\":") catch return error.OutOfMemory;
    wrapped.appendSlice(arena, text) catch return error.OutOfMemory;
    wrapped.appendSlice(arena, "}") catch return error.OutOfMemory;
    const bytes = bson.extjson.parse(arena, wrapped.items) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPipeline,
    };
    const doc = bson.Document.init(bytes) catch return error.InvalidPipeline;
    const v = doc.get("p") orelse return error.InvalidPipeline;
    if (v != .array) return error.InvalidPipeline;
    var it = v.array.iterator();
    while (it.next()) |stage| if (stage != .document) return error.InvalidPipeline;
    return v.array;
}

test "parsePipeline: an Extended JSON array of stages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try parsePipeline(arena.allocator(), "[{\"$match\": {\"operationType\": {\"$in\": [\"insert\", \"update\"]}}}, {\"$project\": {\"x\": 1}}]");
    try std.testing.expectEqual(@as(usize, 2), a.count());
    try std.testing.expectError(error.InvalidPipeline, parsePipeline(arena.allocator(), "{\"a\": 1}"));
    try std.testing.expectError(error.InvalidPipeline, parsePipeline(arena.allocator(), "[1, 2]"));
    try std.testing.expectError(error.InvalidPipeline, parsePipeline(arena.allocator(), "[{"));
    const empty = try parsePipeline(arena.allocator(), "[]");
    try std.testing.expectEqual(@as(usize, 0), empty.count());
}
