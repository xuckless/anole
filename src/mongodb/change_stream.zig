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
    code: i64,
    /// The server's label; when it sends both, non-resumable wins.
    label: enum { none, resumable, non_resumable },
};

/// Where a resume starts, which `$changeStream` option it takes (tokens
/// are owned documents). Every transition is in `open`, `OpenCmd.result`,
/// `takeToken`; `writeAggregate` reads it.
const Resume = union(enum) {
    none,
    start_after: []u8,
    resume_after: []u8,
    at_time: bson.Timestamp,
};

/// A change stream over BSON events; `ChangeStream(T)` decodes them.
pub const Stream = struct {
    client: *Client,
    cx: Context,
    scope: Scope,
    opts: ChangeStreamOptions,
    /// The user's stages after `$changeStream`: a BSON array, owned.
    stages: []u8,
    /// The server's cursor; null once it is exhausted, closed or failed.
    cursor: ?Cursor = null,
    /// The current batch (a BSON array), owned, and the read position in it.
    buf: std.ArrayList(u8) = .empty,
    it: @TypeOf(bson.Array.empty.iterator()) = (bson.Array.empty).iterator(),
    /// The resume point: an event's `_id` or a batch's
    /// `postBatchResumeToken` replace it as they are read.
    @"resume": Resume = .none,
    /// The batch's `postBatchResumeToken`, owned; becomes the resume token
    /// once the batch is read through.
    pbrt: ?[]u8 = null,
    /// The last failed command's error, for the resume decision.
    err: ?ErrInfo = null,

    const Cursor = struct {
        id: i64,
        server: *client_mod.Server,
        session: ?*client_mod.Session,
        /// The collection name for `getMore` (from the reply's `ns`), owned.
        collection: []u8,
    };

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
            try s.setToken(.start_after, d.bytes);
        } else if (opts.resume_after) |d| {
            try s.setToken(.resume_after, d.bytes);
        } else if (opts.start_at_operation_time) |t| {
            s.@"resume" = .{ .at_time = t };
        }
        const time = try s.run();
        // Without a token the open's operationTime is the start of a resume.
        switch (s.@"resume") {
            .none, .at_time => if (time) |t| {
                s.@"resume" = .{ .at_time = t };
            },
            .start_after, .resume_after => {},
        }
        return s;
    }

    /// Ends the cursor on the server and frees the stream.
    pub fn deinit(s: *Stream) void {
        s.closeCursor(true);
        s.deinitBuffers();
        s.* = undefined;
    }

    fn deinitBuffers(s: *Stream) void {
        const gpa = s.client.gpa;
        if (s.stages.len > 0) gpa.free(s.stages);
        switch (s.@"resume") {
            .start_after, .resume_after => |t| gpa.free(t),
            .none, .at_time => {},
        }
        if (s.pbrt) |t| gpa.free(t);
        s.buf.deinit(gpa);
        s.stages = &.{};
        s.@"resume" = .none;
        s.pbrt = null;
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

    // -- the commands ----------------------------------------------------

    fn writeAggregate(s: *Stream, b: *bson.Builder) !void {
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
        switch (s.@"resume") {
            .none => {},
            .resume_after => |t| try b.append("resumeAfter", .{ .document = .{ .bytes = t } }),
            .start_after => |t| try b.append("startAfter", .{ .document = .{ .bytes = t } }),
            .at_time => |t| try b.append("startAtOperationTime", .{ .timestamp = t }),
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
        /// The reply's `operationTime`.
        time: ?bson.Timestamp = null,

        pub fn body(self: *OpenCmd, b: *bson.Builder, _: *Exchange) !void {
            try self.s.writeAggregate(b);
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
            if (reply.get("operationTime")) |v| if (v == .timestamp) {
                self.time = v.timestamp;
            };
            // A reply with no cursor id (an invalidate, exhausted) leaves nothing to kill.
            if ((sdam.intOf(cur.get("id")) orelse 0) == 0) return;
            // The collection `getMore` names: the part of `ns` after the database.
            const ns = sdam.stringOf(cur.get("ns")) orelse "";
            const dot = std.mem.indexOfScalar(u8, ns, '.');
            const coll_name = if (dot) |d| ns[d + 1 ..] else "";
            s.cursor = .{
                .id = sdam.intOf(cur.get("id")).?,
                .server = x.server,
                .session = x.session,
                .collection = try s.client.gpa.dupe(u8, if (coll_name.len > 0) coll_name else "$cmd.aggregate"),
            };
            x.keep_session = true;
        }

        pub fn accepts(self: *OpenCmd, se: conn_mod.ServerError) bool {
            self.s.noteError(se);
            return false;
        }
    };

    const MoreCmd = struct {
        pub const Result = void;
        s: *Stream,
        /// The reply said the cursor is exhausted (id 0); the caller closes
        /// it once `execute` is done with the borrowed collection name.
        exhausted: bool = false,

        pub fn body(self: *MoreCmd, b: *bson.Builder, _: *Exchange) !void {
            const s = self.s;
            const c = s.cursor.?;
            try b.append("getMore", .{ .int64 = c.id });
            try b.append("collection", .{ .string = c.collection });
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
            self.exhausted = (sdam.intOf(cur.get("id")) orelse 0) == 0;
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
            .code = se.code orelse 0,
            .label = if (se.hasLabel("NonResumableChangeStreamError")) .non_resumable else if (se.hasLabel("ResumableChangeStreamError")) .resumable else .none,
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

    /// The aggregate, with the resume point's option; the reply's
    /// `operationTime`.
    fn run(s: *Stream) Error!?bson.Timestamp {
        s.err = null;
        var cmd: OpenCmd = .{ .s = s };
        const op: Operation = .{
            .name = "aggregate",
            .database = s.databaseName(),
            .collection = s.collectionName(),
            .kind = .read,
            .retry = .read,
            .options = .{},
        };
        client_mod.execute(s.client, &s.cx, op, &cmd) catch |err| return s.mapOpenFailure(err);
        return cmd.time;
    }

    /// One `getMore`, held by the server up to `max_await`.
    fn getMore(s: *Stream) Error!void {
        s.err = null;
        const c = s.cursor.?;
        var cmd: MoreCmd = .{ .s = s };
        const base: std.Io.Duration = internal.callTimeout(null, s.client.options.timeout) orelse .fromSeconds(30);
        const await_ms: i64 = if (s.opts.max_await) |d| d.toMilliseconds() else 1000;
        const op: Operation = .{
            .name = "getMore",
            .database = s.databaseName(),
            .collection = c.collection,
            .kind = .command,
            .server = c.server,
            .lsid = if (c.session) |sess| sess.id else null,
            .session = false,
            // The command carries its own maxTimeMS: the await.
            .max_time = false,
            .options = .{ .timeout = .fromMilliseconds(base.toMilliseconds() + await_ms) },
        };
        client_mod.execute(s.client, &s.cx, op, &cmd) catch |err| {
            // A failed getMore leaves no cursor on the server to kill.
            s.closeCursor(false);
            return err;
        };
        if (cmd.exhausted) s.closeCursor(false);
    }

    /// Ends the cursor: killCursors when `kill` (best effort, whatever the
    /// caller's deadline), then gives its session back and frees it.
    fn closeCursor(s: *Stream, kill: bool) void {
        const c = s.cursor orelse return;
        s.cursor = null;
        if (kill) {
            var cmd: KillCmd = .{ .collection = c.collection, .id = c.id };
            const op: Operation = .{
                .name = "killCursors",
                .database = s.databaseName(),
                .collection = c.collection,
                .kind = .command,
                .server = c.server,
                .lsid = if (c.session) |sess| sess.id else null,
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
        }
        if (c.session) |sess| client_mod.giveSession(s.client, sess, s.cx.io);
        s.client.gpa.free(c.collection);
    }

    // -- errors and resume -----------------------------------------------

    /// The codes servers without error labels (before 4.4) mean by
    /// resumable (the specification's list), and `CursorNotFound`.
    const resumable_codes = [_]i64{ 6, 7, 89, 91, 189, 262, 9001, 10107, 11600, 11602, 13435, 13436, 63, 150, 13388, 234, 133, 43 };

    fn isResumable(s: *const Stream, err: anyerror) bool {
        if (err == error.Canceled or err == error.OutOfMemory) return false;
        const e = s.err orelse
            // No server error: the connection broke, or the server went away.
            return err == error.ServiceUnavailable or err == error.GatewayTimeout;
        return switch (e.label) {
            .non_resumable => false,
            .resumable => true,
            .none => std.mem.indexOfScalar(i64, &resumable_codes, e.code) != null,
        };
    }

    /// A failure of the opening aggregate or a resume: the specification's
    /// fatal cases get a code of their own for `lastError`.
    fn mapOpenFailure(s: *Stream, err: Error) Error {
        const e = s.err orelse return err;
        switch (e.code) {
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
            if (s.err) |e| if (e.code == 286) return s.historyLost();
            return failure;
        }
        s.closeCursor(true);
        _ = try s.run();
    }

    // -- reading ---------------------------------------------------------

    /// The next event, waiting (`getMore` after `getMore`) until one comes;
    /// null once the cursor is closed (after an `invalidate` event). The
    /// document points into the stream's batch: valid until the next call.
    pub fn nextDocument(s: *Stream) Error!?bson.Document {
        while (true) {
            if (try s.tryNextDocument()) |d| return d;
            if (s.cursor == null) return null;
        }
    }

    /// One round: an event from the batch, or one `getMore` (held by the
    /// server up to `max_await`) and then an event, or null when none came
    /// (or the cursor is closed: `nextDocument` tells the two apart).
    pub fn tryNextDocument(s: *Stream) Error!?bson.Document {
        if (try s.fromBatch()) |d| return d;
        if (s.cursor == null) return null;
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
            try s.setToken(.resume_after, id.bytes);
            return v.document;
        }
        // The batch is read through: its post-batch token is the position.
        if (s.pbrt) |p| {
            try s.setToken(if (s.@"resume" == .start_after) .start_after else .resume_after, p);
            s.client.gpa.free(p);
            s.pbrt = null;
        }
        return null;
    }

    fn setToken(s: *Stream, kind: enum { start_after, resume_after }, bytes: []const u8) Error!void {
        const gpa = s.client.gpa;
        const copy = gpa.dupe(u8, bytes) catch return error.OutOfMemory;
        switch (s.@"resume") {
            .start_after, .resume_after => |old| gpa.free(old),
            .none, .at_time => {},
        }
        s.@"resume" = switch (kind) {
            .start_after => .{ .start_after = copy },
            .resume_after => .{ .resume_after = copy },
        };
    }

    /// The token to resume after the last event returned (or the last
    /// batch's `postBatchResumeToken`), copied into `arena`.
    pub fn resumeToken(s: *const Stream, arena: std.mem.Allocator) error{OutOfMemory}!?bson.Document {
        const t = switch (s.@"resume") {
            .start_after, .resume_after => |t| t,
            .none, .at_time => return null,
        };
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
