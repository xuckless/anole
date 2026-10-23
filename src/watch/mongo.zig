//! MongoDB change streams for `anole.watch` (§4.5): one task per watch reads
//! a change stream (`anole.mongodb.change_stream`), turns each event into
//! a `Raw`, and reopens the stream after an `invalidate` event (following a
//! collection that is dropped and made again) or a failure. The stream
//! resumes by itself from its token; a gap is only for history the oplog no
//! longer holds.

const std = @import("std");
const dusty = @import("dusty");
const bson = @import("bson");
const placement = dusty.placement;
const mongodb = @import("../mongodb/root.zig");
const cs = mongodb.change_stream;
const db = @import("../db/root.zig");
const root = @import("root.zig");

const Watch = root.Watch;
const log = @import("../errors.zig").log;

pub fn startStream(w: *Watch) !void {
    try placement.concurrent(&w.group, w.io, .local, streamTask, .{w});
}

fn opOf(name: []const u8) root.Op {
    const map = std.StaticStringMap(root.Op).initComptime(.{
        .{ "insert", .insert },
        .{ "update", .update },
        .{ "replace", .replace },
        .{ "delete", .delete },
        .{ "drop", .drop },
        .{ "rename", .rename },
        .{ "dropDatabase", .drop_database },
        .{ "invalidate", .invalidate },
    });
    return map.get(name) orelse .other;
}

/// The key of an event's document as text: a string as it is, an ObjectId
/// as hex, a number as written; anything else as relaxed Extended JSON.
fn keyText(arena: std.mem.Allocator, v: bson.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .object_id => |o| try std.fmt.allocPrint(arena, "{f}", .{o}),
        .int32 => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .int64 => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        else => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try bson.extjson.writeValue(&aw.writer, v, .relaxed);
            break :blk aw.written();
        },
    };
}

fn streamTask(w: *Watch) std.Io.Cancelable!void {
    const cfg = w.source.mongodb;
    const gpa = w.gpa;
    w.reader_task = placement.currentTask(w.io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var ctx: db.Ctx = .{ .io = w.io, .arena = arena_state.allocator() };
    var attempt: u32 = 0;
    var first = true;
    // Where to open: from the saved start on the first open, then from
    // the last position.
    var from_now = false;
    while (!w.isStopped()) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        var opts: cs.ChangeStreamOptions = .{
            .full_document = cfg.full_document,
            .full_document_before_change = cfg.full_document_before_change,
            .max_await = cfg.max_await,
            .batch_size = cfg.batch_size,
            .show_expanded_events = cfg.show_expanded_events,
        };
        // Resume point.
        const saved = w.position(a) catch null;
        if (saved != null and !from_now) {
            const bytes = bson.extjson.parse(a, saved.?) catch null;
            if (bytes) |b| opts.resume_after = bson.Document.init(b) catch null;
        } else if (first) switch (cfg.start) {
            .now => {},
            .resume_after => |t| {
                const bytes = bson.extjson.parse(a, t) catch {
                    w.fail("the resume token is not Extended JSON: use a saved position() as it was", .{});
                    return;
                };
                opts.resume_after = bson.Document.init(bytes) catch null;
            },
            .start_after => |t| {
                const bytes = bson.extjson.parse(a, t) catch {
                    w.fail("the resume token is not Extended JSON: use a saved position() as it was", .{});
                    return;
                };
                opts.start_after = bson.Document.init(bytes) catch null;
            },
            .at => |ts| opts.start_at_operation_time = ts,
        };
        from_now = false;

        const scope: cs.Scope = if (cfg.collection) |c|
            .{ .collection = .{ .database = cfg.database orelse cfg.client.default_database, .name = c } }
        else if (cfg.database) |d| .{ .database = d } else .cluster;

        var stream = cs.openJson(cfg.client, &ctx, scope, cfg.pipeline, opts) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (w.isStopped()) return;
            if (handleFailure(w, &ctx, err, &attempt, &from_now)) continue else return;
        };
        var have = true;
        defer if (have) stream.deinit();
        attempt = 0;
        first = false;
        w.setStatus(.connected);
        log.info("watch \"{s}\": reading the change stream", .{w.name});

        // The events.
        var failed: ?anyerror = null;
        while (!w.isStopped()) {
            _ = arena_state.reset(.retain_capacity);
            const doc = stream.nextDocument() catch |err| {
                failed = err;
                break;
            } orelse {
                // Closed by an invalidate: follow the collection from its token.
                const token = stream.resumeToken(arena_state.allocator()) catch null;
                if (token) |t| {
                    stream.deinit();
                    have = false;
                    var reopen: cs.ChangeStreamOptions = opts;
                    reopen.resume_after = null;
                    reopen.start_after = t;
                    stream = cs.openJson(cfg.client, &ctx, scope, cfg.pipeline, reopen) catch |err| {
                        failed = err;
                        break;
                    };
                    have = true;
                    continue;
                }
                break;
            };
            deliverEvent(w, cfg, arena_state.allocator(), doc);
        }
        if (failed) |err| {
            if (err == error.Canceled) return error.Canceled;
            if (w.isStopped()) return;
            if (!handleFailure(w, &ctx, err, &attempt, &from_now)) return;
        }
    }
}

/// What to do after a failure of the stream: true to reconnect (after the
/// backoff), false when the watch has failed for good.
fn handleFailure(w: *Watch, ctx: *db.Ctx, err: anyerror, attempt: *u32, from_now: *bool) bool {
    if (db.lastError(ctx)) |d| {
        if (std.mem.eql(u8, d.code, "change_streams_need_replica_set")) {
            w.fail("MongoDB change streams need a replica set or a sharded cluster: start mongod with --replSet rs0 and run rs.initiate() once (a single-node replica set works)", .{});
            return false;
        }
        if (std.mem.eql(u8, d.code, "change_stream_history_lost")) {
            w.gapped("the oplog no longer holds the events after the stream's resume token");
            from_now.* = true;
            return pause(w, attempt);
        }
        if (std.mem.eql(u8, d.code, "change_stream_missing_id")) {
            w.fail("{s}", .{d.message});
            return false;
        }
    }
    attempt.* += 1;
    if (attempt.* == 1) {
        log.warn("watch \"{s}\": the change stream failed ({t}); trying again", .{ w.name, err });
    } else log.debug("watch \"{s}\": change stream attempt {d} failed: {t}", .{ w.name, attempt.*, err });
    w.setStatus(.reconnecting);
    return pause(w, attempt);
}

fn pause(w: *Watch, attempt: *u32) bool {
    attempt.* = @max(attempt.*, 1);
    var rnd: [8]u8 = undefined;
    w.io.random(&rnd);
    w.io.sleep(w.reconnect.delay(attempt.*, std.mem.readInt(u64, &rnd, .little)), .awake) catch return false;
    return !w.isStopped();
}

/// One event into the watch.
fn deliverEvent(w: *Watch, cfg: root.MongoDb, a: std.mem.Allocator, doc: bson.Document) void {
    const op_name = if (doc.get("operationType")) |v| (if (v == .string) v.string else "other") else "other";
    var db_name: ?[]const u8 = null;
    var coll_name: ?[]const u8 = null;
    if (doc.get("ns")) |v| if (v == .document) {
        if (v.document.get("db")) |d| if (d == .string) {
            db_name = d.string;
        };
        if (v.document.get("coll")) |c| if (c == .string) {
            coll_name = c.string;
        };
    };
    const channel = if (db_name) |d| (if (coll_name) |c| std.fmt.allocPrint(a, "{s}.{s}", .{ d, c }) catch "" else d) else "";
    var key: ?[]const u8 = null;
    if (doc.get("documentKey")) |v| if (v == .document) {
        if (v.document.get("_id")) |id| key = keyText(a, id) catch null;
    };
    const position: ?[]const u8 = if (doc.get("_id")) |v| (if (v == .document) bson.extjson.allocPrint(a, v.document, .canonical) catch null else null) else null;
    const data: []const u8 = switch (w.data_mode) {
        .auto => bson.extjson.allocPrint(a, doc, .relaxed) catch "{}",
        .document => document(a, doc) catch "{}",
    };
    _ = cfg;
    _ = w.deliver(.{
        .op = opOf(op_name),
        .op_name = op_name,
        .channel = channel,
        .data = data,
        .position = position,
        .change = doc,
        .db = db_name,
        .collection = coll_name,
        .key = key,
    });
}

/// `fullDocument` as relaxed Extended JSON, or `{"_id": ...}` from the
/// document key when the event has none (a delete).
fn document(a: std.mem.Allocator, doc: bson.Document) ![]const u8 {
    if (doc.get("fullDocument")) |v| if (v == .document) return bson.extjson.allocPrint(a, v.document, .relaxed);
    var aw: std.Io.Writer.Allocating = .init(a);
    try aw.writer.writeAll("{\"_id\":");
    if (doc.get("documentKey")) |k| if (k == .document) if (k.document.get("_id")) |id| {
        try bson.extjson.writeValue(&aw.writer, id, .relaxed);
        try aw.writer.writeAll("}");
        return aw.written();
    };
    try aw.writer.writeAll("null}");
    return aw.written();
}
