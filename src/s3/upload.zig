//! Uploads: one PutObject, or a multipart upload (design-connectors.md S7, S8).
//!
//! Two forms share one engine. The *pull* form (`put` with a reader, a
//! file or the request) reads at its own pace; not reading is its
//! back-pressure. The *push* form (`Upload.write`) copies into part
//! buffers and returns at once: `.busy` past `concurrency * part_size`
//! buffered, `error.ServiceUnavailable` with code "upload_full" past one
//! part more or when the client's `upload_memory` is used up. A write never
//! waits for the network.
//!
//! One driver task per upload owns the network work: it creates the
//! multipart upload, starts at most `concurrency` part tasks, completes or
//! aborts. Memory per upload is at most `(concurrency + 1) * part_size`.
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const safety = @import("anole_safety");
const root = @import("root.zig");
const endpoint = @import("endpoint.zig");
const xml = @import("xml.zig");
const sigv4 = @import("sigv4.zig");

const placement = dusty.placement;
const Error = root.Error;
const Bucket = root.Bucket;
const Client = root.Client;
const PutOptions = root.PutOptions;
const Stored = root.Stored;
const Duration = std.Io.Duration;
const log = @import("../errors.zig").log;

pub const max_parts = 10_000;
const mib: u64 = 1024 * 1024;

/// A counter waiters sleep on: `ring` wakes everyone, `wait(seen)` returns
/// once the counter has moved past `seen` (or at once if it already has).
pub const Bell = struct {
    n: std.atomic.Value(u32) = .init(0),

    pub fn ring(self: *Bell, io: std.Io) void {
        _ = self.n.fetchAdd(1, .release);
        io.futexWake(u32, &self.n.raw, std.math.maxInt(u32));
    }

    pub fn seen(self: *const Bell) u32 {
        return self.n.load(.acquire);
    }

    pub fn wait(self: *Bell, io: std.Io, was: u32) std.Io.Cancelable!void {
        try io.futexWait(u32, &self.n.raw, was);
    }

    pub fn waitTimeout(self: *Bell, io: std.Io, was: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        try io.futexWaitTimeout(u32, &self.n.raw, was, timeout);
    }
};

const PartBuf = struct {
    data: []u8,
    len: usize,
    number: u16,
};

/// What `copyIn` found.
pub const Taken = enum { ok, busy, full };

/// How a push upload ended badly.
const Fail = struct {
    err: Error,
    class: db.Class,
    code: []const u8,
    message: []const u8,
};

/// owner: whoever opened it (`open`: a `put`, a handler's `Client.upload`,
/// the C ABI's transfer slot), which calls `deinit` once. Lifetime: a child
/// of that owner; its driver and part tasks are its children (T1): `deinit`
/// cancels and joins their groups, then frees.
pub const Upload = struct {
    /// SAFETY.md M5: `deinit` runs once; a use after it panics in debug builds.
    teardown: safety.Teardown = .init,
    client: *Client,
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    bucket: []const u8,
    key: []const u8,
    call: root.CallOptions,
    /// The headers every request of the upload carries (content type,
    /// metadata...), in the upload's arena.
    headers: []const root.Header,
    /// Only for the final request: If-None-Match / If-Match.
    conditional: []const root.Header,
    part_size: usize,
    declared_len: ?u64,

    mutex: std.atomic.Mutex = .unlocked,
    cur: std.ArrayList(u8) = .empty,
    cur_charged: bool = false,
    ready: std.ArrayList(PartBuf) = .empty,
    inflight: u8 = 0,
    next_part: u16 = 1,
    multipart: bool = false,
    etags: std.ArrayList(root.Part) = .empty,
    upload_id: ?[]const u8 = null,
    failure: ?Fail = null,
    finishing: bool = false,
    done: bool = false,
    aborted: bool = false,
    result: ?Stored = null,
    total: u64 = 0,
    buffered: std.atomic.Value(u64) = .init(0),

    group: std.Io.Group = .init,
    parts: std.Io.Group = .init,
    /// Wakes the driver.
    wake: Bell = .{},
    /// Rung when room appears, a part completes or the upload ends.
    progress: Bell = .{},

    // ---- Locking ---------------------------------------------------------

    fn lock(self: *Upload) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Upload) void {
        self.mutex.unlock();
    }

    // ---- The push API ------------------------------------------------------

    pub const Written = enum { ok, busy };

    /// Copies `bytes` into the part buffers; never waits. `.busy`: taken,
    /// but more than `concurrency * part_size` is buffered; wait before
    /// writing more. `error.ServiceUnavailable` (lastError code
    /// "upload_full"): nothing taken. A failed part (after retries) fails
    /// every later call with its error.
    pub fn write(self: *Upload, c: anytype, bytes: []const u8) Error!Written {
        const r = try self.copyIn(c, bytes);
        if (r.rotated) self.wake.ring(self.io);
        return switch (r.taken) {
            .ok => .ok,
            .busy => .busy,
            .full => self.client.failOur(c, .unavailable, "upload_full", "the upload has buffered as much as it may; wait until it is writable"),
        };
    }

    pub const Copied = struct { taken: Taken, rotated: bool };

    /// `write` without waking the driver: the C ABI posts the wake itself
    /// from the upload's executor when `rotated`.
    pub fn copyIn(self: *Upload, c: anytype, bytes: []const u8) Error!Copied {
        self.teardown.assertAlive();
        self.lock();
        defer self.unlock();
        if (self.failure) |f| return self.replay(c, f);
        if (self.finishing or self.aborted or self.done) return self.client.failOur(c, .invalid, "upload_over", "the upload is finished or aborted");
        const busy_at: u64 = @as(u64, self.client.concurrency) * self.part_size;
        const full_at: u64 = busy_at + self.part_size;
        const have = self.buffered.load(.acquire);
        if (bytes.len == 0) return .{ .taken = if (have > busy_at) .busy else .ok, .rotated = false };
        if (have + bytes.len > full_at) return .{ .taken = .full, .rotated = false };
        // Memory for the buffers this write will need, taken up front.
        const room: usize = if (self.cur_charged) self.part_size - self.cur.items.len else 0;
        const fresh: u64 = if (bytes.len <= room) 0 else (bytes.len - room + self.part_size - 1) / self.part_size;
        if (fresh > 0 and !self.client.takeMemory(fresh * self.part_size)) return .{ .taken = .full, .rotated = false };
        var rotated = false;
        var rest = bytes;
        var used: u64 = 0;
        while (rest.len > 0) {
            if (self.cur.items.len == self.part_size) {
                // Full, and more is coming: it is a part. A body that ends
                // exactly here stays the current buffer (one PUT, or the last part).
                if (self.next_part > max_parts) {
                    self.client.giveMemory((fresh - used) * self.part_size);
                    return self.client.failOur(c, .invalid, "too_many_parts", "the upload would need more than 10000 parts; raise part_size");
                }
                try self.ready.append(self.gpa, .{ .data = self.cur.allocatedSlice(), .len = self.cur.items.len, .number = self.next_part });
                self.cur = .empty;
                self.cur_charged = false;
                self.next_part += 1;
                self.multipart = true;
                rotated = true;
            }
            if (!self.cur_charged) {
                self.cur_charged = true;
                used += 1;
            }
            const n = @min(self.part_size - self.cur.items.len, rest.len);
            try self.cur.appendSlice(self.gpa, rest[0..n]);
            rest = rest[n..];
        }
        _ = self.buffered.fetchAdd(bytes.len, .acq_rel);
        self.total += bytes.len;
        return .{ .taken = if (self.buffered.load(.acquire) > busy_at) .busy else .ok, .rotated = rotated };
    }

    /// Whether `write` would answer `.ok` now.
    pub fn writable(self: *const Upload) bool {
        return self.buffered.load(.acquire) < @as(u64, self.client.concurrency) * self.part_size;
    }

    /// Buffered bytes have fallen to half of `concurrency * part_size`: the
    /// C ABI's WRITABLE event.
    pub fn lowWater(self: *const Upload) bool {
        return self.buffered.load(.acquire) <= @as(u64, self.client.concurrency) * self.part_size / 2;
    }

    /// Until `write` would answer `.ok`; `error.GatewayTimeout` past `timeout`.
    pub fn waitWritable(self: *Upload, c: anytype, timeout: ?Duration) Error!void {
        const started: std.Io.Clock.Timestamp = .now(self.io, .awake);
        while (true) {
            const seen = self.progress.seen();
            self.lock();
            const f = self.failure;
            self.unlock();
            if (f) |fl| return self.replay(c, fl);
            if (self.writable()) return;
            if (timeout) |t| {
                const left = t.nanoseconds - started.durationTo(.now(self.io, .awake)).raw.nanoseconds;
                if (left <= 0) return self.client.failOur(c, .timeout, "write_timeout", "the upload did not become writable in time");
                try self.progress.waitTimeout(self.io, seen, .{ .duration = .{ .raw = .{ .nanoseconds = left }, .clock = .awake } });
            } else try self.progress.wait(self.io, seen);
        }
    }

    /// Sends the rest, completes the multipart upload (or does the one PUT).
    pub fn finish(self: *Upload, c: anytype) Error!Stored {
        try self.beginFinish(c);
        self.wake.ring(self.io);
        return self.awaitDone(c);
    }

    /// Marks the upload as ending; the driver does the rest. For the ABI,
    /// which rings the wake itself and answers by event.
    pub fn beginFinish(self: *Upload, c: anytype) Error!void {
        self.teardown.assertAlive();
        self.lock();
        defer self.unlock();
        if (self.failure) |f| return self.replay(c, f);
        if (self.aborted) return self.client.failOur(c, .invalid, "upload_over", "the upload was aborted");
        if (self.finishing) return;
        if (self.multipart and self.cur.items.len > 0) {
            if (self.next_part > max_parts) return self.client.failOur(c, .invalid, "too_many_parts", "the upload would need more than 10000 parts; raise part_size");
            try self.ready.append(self.gpa, .{ .data = self.cur.allocatedSlice(), .len = self.cur.items.len, .number = self.next_part });
            self.cur = .empty;
            self.cur_charged = false;
            self.next_part += 1;
        }
        self.finishing = true;
    }

    /// Waits for the driver to end, then returns its result, its strings
    /// copied into the call's arena: the result outlives the upload, whose
    /// arena `deinit` frees (SAFETY.md M4).
    pub fn awaitDone(self: *Upload, c: anytype) Error!Stored {
        while (true) {
            const seen = self.progress.seen();
            self.lock();
            const done = self.done;
            const f = self.failure;
            const res = self.result;
            self.unlock();
            if (f) |fl| return self.replay(c, fl);
            if (done) {
                const stored = res orelse return self.client.failOur(c, .other, "upload_over", "the upload ended without a result");
                return dupeStored(c.arena, stored);
            }
            try self.progress.wait(self.io, seen);
        }
    }

    fn dupeStored(a: std.mem.Allocator, s: Stored) error{OutOfMemory}!Stored {
        var out = s;
        out.etag = try a.dupe(u8, s.etag);
        if (s.version_id) |v| out.version_id = try a.dupe(u8, v);
        return out;
    }

    /// The result once done, or the failure; null while running. The
    /// result's strings are the upload's: valid until `deinit`.
    pub fn poll(self: *Upload) ?(Error!Stored) {
        self.lock();
        defer self.unlock();
        if (self.failure) |f| return f.err;
        if (self.done) return self.result orelse error.Database;
        return null;
    }

    /// The failure as a detail for the caller's `lastError`.
    pub fn failureDetail(self: *Upload) ?db.ErrorDetail {
        self.lock();
        defer self.unlock();
        const f = self.failure orelse return null;
        return .{ .system = .s3, .class = f.class, .code = f.code, .message = f.message, .table = self.bucket };
    }

    fn replay(self: *Upload, c: anytype, f: Fail) Error {
        internal.keepError(c, .{ .system = .s3, .class = f.class, .code = f.code, .message = f.message, .table = self.bucket });
        return f.err;
    }

    /// Aborts (AbortMultipartUpload when one was started). Cleanup: never fails.
    pub fn abort(self: *Upload) void {
        self.lock();
        const already = self.aborted;
        self.aborted = true;
        self.unlock();
        if (already) return;
        self.wake.ring(self.io);
        self.group.cancel(self.io);
        self.parts.cancel(self.io);
        self.abortRemote();
        self.notify();
    }

    /// Aborts unless finished; frees.
    pub fn deinit(self: *Upload) void {
        self.teardown.begin();
        self.lock();
        const finished = self.done and self.failure == null and !self.aborted;
        self.unlock();
        if (!finished) self.abort() else {
            self.group.cancel(self.io);
            // A part task can still be in its tail (freeing its buffer,
            // ringing the bells) after the driver saw `inflight == 0` and
            // finished: wait for it before the Upload goes away.
            self.parts.cancel(self.io);
        }
        self.freeBuffers();
        const gpa = self.gpa;
        const client = self.client;
        self.cur.deinit(gpa);
        self.ready.deinit(gpa);
        self.etags.deinit(gpa);
        self.arena.deinit();
        _ = client.uploads_live.fetchSub(1, .acq_rel);
        self.teardown.end();
        gpa.destroy(self);
    }

    fn freeBuffers(self: *Upload) void {
        if (self.cur_charged) {
            self.client.giveMemory(self.part_size);
            self.cur_charged = false;
        }
        for (self.ready.items) |p| {
            self.gpa.free(p.data);
            self.client.giveMemory(self.part_size);
        }
        self.ready.clearRetainingCapacity();
    }

    // ---- The driver --------------------------------------------------------

    /// Room appeared, a part completed or the upload ended.
    fn notify(self: *Upload) void {
        self.progress.ring(self.io);
        self.client.bell.ring(self.io);
    }

    fn setFailure(self: *Upload, c: anytype, err: Error) void {
        const detail = internal.lastError(c);
        self.lock();
        defer self.unlock();
        if (self.failure != null) return;
        const a = self.arena.allocator();
        self.failure = .{
            .err = err,
            .class = if (detail) |d| d.class else .other,
            .code = if (detail) |d| a.dupe(u8, d.code) catch "" else "",
            .message = if (detail) |d| a.dupe(u8, d.message) catch "" else @errorName(err),
        };
    }

    fn driver(self: *Upload) std.Io.Cancelable!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        while (true) {
            const seen = self.wake.seen();
            _ = arena.reset(.retain_capacity);
            ctx.last_error = null;
            // Parts to start.
            while (true) {
                self.lock();
                const stop = self.failure != null or self.aborted;
                const can = !stop and self.ready.items.len > 0 and self.inflight < self.client.concurrency;
                var part: ?PartBuf = null;
                if (can) {
                    part = self.ready.orderedRemove(0);
                    self.inflight += 1;
                }
                self.unlock();
                const p = part orelse break;
                if (self.upload_id == null) {
                    self.createRemote(&ctx) catch |err| {
                        if (err == error.Canceled) return error.Canceled;
                        self.setFailure(&ctx, err);
                        self.gpa.free(p.data);
                        self.client.giveMemory(self.part_size);
                        self.lock();
                        self.inflight -= 1;
                        self.unlock();
                        break;
                    };
                }
                placement.concurrent(&self.parts, self.io, .local, partTask, .{ self, p }) catch {
                    self.setFailure(&ctx, error.ServiceUnavailable);
                    self.gpa.free(p.data);
                    self.client.giveMemory(self.part_size);
                    self.lock();
                    self.inflight -= 1;
                    self.unlock();
                    break;
                };
            }
            self.lock();
            const failed = self.failure != null;
            const stop = failed or self.aborted;
            const finish_now = self.finishing and self.ready.items.len == 0 and self.inflight == 0;
            self.unlock();
            if (stop) {
                self.parts.cancel(self.io);
                if (failed) self.abortRemote();
                self.lock();
                self.done = true;
                self.unlock();
                self.notify();
                return;
            }
            if (finish_now) {
                const r = if (self.multipart or self.upload_id != null) self.completeRemote(&ctx) else self.putRemote(&ctx);
                if (r) |stored| {
                    self.lock();
                    self.result = stored;
                    self.done = true;
                    self.unlock();
                } else |err| {
                    if (err == error.Canceled) return error.Canceled;
                    self.setFailure(&ctx, err);
                    self.abortRemote();
                    self.lock();
                    self.done = true;
                    self.unlock();
                }
                self.notify();
                return;
            }
            try self.wake.wait(self.io, seen);
        }
    }

    fn createRemote(self: *Upload, ctx: *db.Ctx) Error!void {
        const id = try createMultipartWith(self.client, ctx, self.bucket, self.key, self.headers, self.call);
        const a = self.arena.allocator();
        self.upload_id = try a.dupe(u8, id);
    }

    fn partTask(self: *Upload, p: PartBuf) std.Io.Cancelable!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        var num_buf: [8]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{p.number}) catch unreachable;
        const reply = self.client.execute(&ctx, .{
            .name = "UploadPart",
            .method = .put,
            .bucket = self.bucket,
            .key = self.key,
            .query = &.{ .{ "partNumber", num }, .{ "uploadId", self.upload_id.? } },
            .body = p.data[0..p.len],
            .has_body = true,
            .want = .buffered,
            .max_bytes = 64 * 1024,
            .bound_bytes = p.len,
        }, self.call);
        const freed = struct {
            fn f(s: *Upload, part: PartBuf) void {
                s.gpa.free(part.data);
                s.client.giveMemory(s.part_size);
            }
        }.f;
        if (reply) |r| {
            self.lock();
            const a = self.arena.allocator();
            if (a.dupe(u8, r.meta.etag)) |etag| {
                self.etags.append(self.gpa, .{ .number = p.number, .etag = etag }) catch {};
            } else |_| {}
            self.inflight -= 1;
            _ = self.buffered.fetchSub(p.len, .acq_rel);
            self.unlock();
            freed(self, p);
        } else |err| {
            freed(self, p);
            self.lock();
            self.inflight -= 1;
            self.unlock();
            if (err == error.Canceled) {
                self.wake.ring(self.io);
                return error.Canceled;
            }
            self.setFailure(&ctx, err);
        }
        self.notify();
        self.wake.ring(self.io);
    }

    fn putRemote(self: *Upload, ctx: *db.Ctx) Error!Stored {
        const cl = self.client;
        var hl: root.Headers = .{};
        for (self.headers) |h| hl.add(h[0], h[1]) catch return error.OutOfMemory;
        for (self.conditional) |h| hl.add(h[0], h[1]) catch return error.OutOfMemory;
        const data = self.cur.items;
        const reply = try cl.execute(ctx, .{
            .name = "PutObject",
            .method = .put,
            .bucket = self.bucket,
            .key = self.key,
            .headers = hl.slice(),
            .body = data,
            .has_body = true,
            .want = .buffered,
            .max_bytes = 64 * 1024,
            .bound_bytes = data.len,
        }, self.call);
        _ = self.buffered.fetchSub(data.len, .acq_rel);
        return .{ .etag = try self.arena.allocator().dupe(u8, reply.meta.etag), .version_id = if (reply.meta.version_id) |v| try self.arena.allocator().dupe(u8, v) else null, .size = data.len, .parts = 0 };
    }

    fn completeRemote(self: *Upload, ctx: *db.Ctx) Error!Stored {
        const cl = self.client;
        const sorted = try ctx.arena.dupe(root.Part, self.etags.items);
        std.mem.sort(root.Part, sorted, {}, struct {
            fn less(_: void, a: root.Part, b: root.Part) bool {
                return a.number < b.number;
            }
        }.less);
        var stored = try completeWith(cl, ctx, self.bucket, self.key, self.upload_id.?, sorted, self.conditional, self.call);
        stored.size = self.total;
        const a = self.arena.allocator();
        stored.etag = try a.dupe(u8, stored.etag);
        if (stored.version_id) |v| stored.version_id = try a.dupe(u8, v);
        return stored;
    }

    fn abortRemote(self: *Upload) void {
        const id = self.upload_id orelse return;
        self.upload_id = null;
        const prev = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(prev);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        abortWith(self.client, &ctx, self.bucket, self.key, id, .{ .timeout = .fromSeconds(10), .retry = false }) catch {
            log.warn("s3 \"{s}\": incomplete multipart upload {s} of {s} left; a bucket lifecycle rule AbortIncompleteMultipartUpload removes it", .{ self.client.label, id, self.key });
        };
    }
};

// ---------------------------------------------------------------------------
// Multipart requests

fn createMultipartWith(cl: *Client, c: anytype, bucket: []const u8, key: []const u8, headers: []const root.Header, call: root.CallOptions) Error![]const u8 {
    var hl: root.Headers = .{};
    for (headers) |h| hl.add(h[0], h[1]) catch return error.OutOfMemory;
    const reply = try cl.execute(c, .{
        .name = "CreateMultipartUpload",
        .method = .post,
        .bucket = bucket,
        .key = key,
        .query = &.{.{ "uploads", "" }},
        .headers = hl.slice(),
        .has_body = true,
        .want = .buffered,
        .max_bytes = 64 * 1024,
    }, call);
    if (xml.parseError(c.arena, reply.body)) |e| return cl.failCode(c, 500, if (e.code.len > 0) e.code else "InternalError", e.message, e.region);
    const id = (xml.firstText(c.arena, reply.body, "UploadId") catch null) orelse
        return cl.failOur(c, .other, "bad_response", "CreateMultipartUpload answered without an UploadId");
    return id;
}

fn completeWith(cl: *Client, c: anytype, bucket: []const u8, key: []const u8, upload_id: []const u8, parts: []const root.Part, conditional: []const root.Header, call: root.CallOptions) Error!Stored {
    var body: std.Io.Writer.Allocating = .init(c.arena);
    const w = &body.writer;
    w.writeAll("<CompleteMultipartUpload>") catch return error.OutOfMemory;
    for (parts) |p| {
        w.print("<Part><PartNumber>{d}</PartNumber><ETag>", .{p.number}) catch return error.OutOfMemory;
        for (p.etag) |ch| switch (ch) {
            '&' => w.writeAll("&amp;") catch return error.OutOfMemory,
            '<' => w.writeAll("&lt;") catch return error.OutOfMemory,
            '>' => w.writeAll("&gt;") catch return error.OutOfMemory,
            else => w.writeByte(ch) catch return error.OutOfMemory,
        };
        w.writeAll("</ETag></Part>") catch return error.OutOfMemory;
    }
    w.writeAll("</CompleteMultipartUpload>") catch return error.OutOfMemory;
    var hl: root.Headers = .{};
    hl.add("Content-Type", "application/xml") catch return error.OutOfMemory;
    for (conditional) |h| hl.add(h[0], h[1]) catch return error.OutOfMemory;
    const reply = try cl.execute(c, .{
        .name = "CompleteMultipartUpload",
        .method = .post,
        .bucket = bucket,
        .key = key,
        .query = &.{.{ "uploadId", upload_id }},
        .headers = hl.slice(),
        .body = body.written(),
        .has_body = true,
        .want = .buffered,
        .max_bytes = 1024 * 1024,
        .bound_bytes = body.written().len,
    }, call);
    // S3 can answer 200 and then fail: the error is in the body.
    if (xml.parseError(c.arena, reply.body)) |e| return cl.failCode(c, 500, if (e.code.len > 0) e.code else "InternalError", e.message, e.region);
    const etag = (xml.firstText(c.arena, reply.body, "ETag") catch null) orelse "";
    return .{ .etag = etag, .version_id = reply.meta.version_id, .parts = @intCast(parts.len) };
}

fn abortWith(cl: *Client, c: anytype, bucket: []const u8, key: []const u8, upload_id: []const u8, call: root.CallOptions) Error!void {
    _ = try cl.execute(c, .{
        .name = "AbortMultipartUpload",
        .method = .delete,
        .bucket = bucket,
        .key = key,
        .query = &.{.{ "uploadId", upload_id }},
        .want = .buffered,
        .max_bytes = 64 * 1024,
    }, call);
}

pub fn createMultipart(b: Bucket, c: anytype, key: []const u8, opts: PutOptions) Error![]const u8 {
    const bucket = try b.bucketName(c);
    var hl: root.Headers = .{};
    try b.client.putHeaders(c, &hl, key, opts, false);
    return createMultipartWith(b.client, c, bucket, key, hl.slice(), b.call);
}

pub fn completeMultipart(b: Bucket, c: anytype, key: []const u8, upload_id: []const u8, parts: []const root.Part) Error!Stored {
    const bucket = try b.bucketName(c);
    const sorted = try c.arena.dupe(root.Part, parts);
    std.mem.sort(root.Part, sorted, {}, struct {
        fn less(_: void, a: root.Part, d: root.Part) bool {
            return a.number < d.number;
        }
    }.less);
    return completeWith(b.client, c, bucket, key, upload_id, sorted, &.{}, b.call);
}

pub fn abortMultipart(b: Bucket, c: anytype, key: []const u8, upload_id: []const u8) Error!void {
    const bucket = try b.bucketName(c);
    return abortWith(b.client, c, bucket, key, upload_id, b.call);
}

// ---------------------------------------------------------------------------
// Opening an upload

/// The part size for a body: `Options.part_size`, raised so that 10,000
/// parts always suffice (all parts have the same size: R2 requires it).
pub fn partSizeFor(configured: u64, total: ?u64) u64 {
    const len = total orelse return configured;
    const need = std.math.divCeil(u64, len, max_parts) catch configured;
    if (need <= configured) return configured;
    return (need + mib - 1) / mib * mib;
}

/// Opens an upload and starts its driver. `declared_len` is the body's
/// length when known.
pub fn open(b: Bucket, c: anytype, key: []const u8, opts: PutOptions, declared_len: ?u64) Error!*Upload {
    const bucket = try b.bucketName(c);
    const cl = b.client;
    if (!endpoint.validKey(key)) return cl.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
    if (cl.draining.load(.acquire)) return cl.failOur(c, .unavailable, "draining", "the server is shutting down; no new uploads start");
    const gpa = cl.gpa;
    const self = try gpa.create(Upload);
    errdefer gpa.destroy(self);
    self.* = .{
        .client = cl,
        .gpa = gpa,
        .io = cl.io,
        .arena = .init(gpa),
        .bucket = "",
        .key = "",
        .call = b.call,
        .headers = &.{},
        .conditional = &.{},
        .part_size = std.math.cast(usize, partSizeFor(cl.part_size, declared_len)) orelse return error.OutOfMemory,
        .declared_len = declared_len,
    };
    errdefer self.arena.deinit();
    const a = self.arena.allocator();
    self.bucket = try a.dupe(u8, bucket);
    self.key = try a.dupe(u8, key);
    // Request headers, kept for every request of the upload.
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    var tctx: db.Ctx = .{ .io = cl.io, .arena = tmp.allocator() };
    var hl: root.Headers = .{};
    cl.putHeaders(&tctx, &hl, key, opts, false) catch |err| {
        if (internal.lastError(&tctx)) |d| internal.keepError(c, d);
        return err;
    };
    const copy = try a.alloc(root.Header, hl.len);
    for (hl.slice(), copy) |h, *out| out.* = .{ try a.dupe(u8, h[0]), try a.dupe(u8, h[1]) };
    self.headers = copy;
    var cond: root.Headers = .{};
    try cl.conditionalHeaders(&cond, opts);
    const cc = try a.alloc(root.Header, cond.len);
    for (cond.slice(), cc) |h, *out| out.* = .{ try a.dupe(u8, h[0]), try a.dupe(u8, h[1]) };
    self.conditional = cc;
    placement.concurrent(&self.group, cl.io, .local, Upload.driver, .{self}) catch
        return cl.failOur(c, .unavailable, "no_task", "no task could be started for the upload");
    _ = cl.uploads_live.fetchAdd(1, .acq_rel);
    return self;
}

// ---------------------------------------------------------------------------
// `put`

pub fn put(b: Bucket, c: anytype, key: []const u8, body: root.Body, opts: PutOptions) root.PutError!Stored {
    const cl = b.client;
    if (!endpoint.validKey(key)) return cl.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
    switch (body) {
        .bytes => |data| {
            if (data.len <= cl.threshold) return singlePut(b, c, key, data, opts);
            return pump(b, c, key, opts, SliceSource{ .bytes = data }, data.len);
        },
        .reader => |r| {
            if (r.len) |len| if (len <= cl.threshold) {
                const data = try readExactly(cl, c, r.reader, len);
                return singlePut(b, c, key, data, opts);
            };
            return pump(b, c, key, opts, ReaderSource{ .reader = r.reader }, r.len);
        },
        .file => |path| {
            const io = cl.io;
            var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.FileNotFound => return cl.failOur(c, .not_found, "file_not_found", "the file to upload does not exist"),
                else => return cl.failOur(c, .invalid, "file_unreadable", @errorName(err)),
            };
            defer f.close(io);
            const stat = f.stat(io) catch |err| return cl.failOur(c, .invalid, "file_unreadable", @errorName(err));
            var fbuf: [16 * 1024]u8 = undefined;
            var fr = f.reader(io, &fbuf);
            if (stat.size <= cl.threshold) {
                const data = try readExactly(cl, c, &fr.interface, stat.size);
                return singlePut(b, c, key, data, opts);
            }
            return pump(b, c, key, opts, ReaderSource{ .reader = &fr.interface }, stat.size);
        },
        .request => {
            if (comptime @TypeOf(c) != *anole.Request) return cl.failOur(c, .invalid, "no_request", "Body.request needs the request as the call's context");
            const req: *anole.Request = c;
            var rbuf: [16 * 1024]u8 = undefined;
            var rr = req.reader(&rbuf) catch |err| return requestErr(cl, c, err);
            const declared: ?u64 = if (req.content_length) |l| l else null;
            if (declared) |len| if (len <= cl.threshold) {
                const data = readExactly(cl, c, &rr.interface, len) catch |err| {
                    if (rr.err) |e| return requestErr(cl, c, e);
                    return err;
                };
                return singlePut(b, c, key, data, opts);
            };
            return pump(b, c, key, opts, ReaderSource{ .reader = &rr.interface }, declared) catch |err| {
                if (rr.err) |e| return requestErr(cl, c, e);
                return err;
            };
        },
    }
}

fn requestErr(cl: *Client, c: anytype, err: anyerror) root.PutError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        // The request's fault, answered as the core answers a body over
        // its limit: 413 (RFC 9110 15.5.14). The core then drains the rest
        // of the body over HTTP/1.1 or closes the connection when it is too
        // long to drain; HTTP/2 and HTTP/3 reset the stream. `lastError`
        // still says why.
        error.BodyTooBig => {
            cl.failOur(c, .invalid, "body_too_big", "the request body is larger than limits.body_max") catch {};
            return error.BodyTooBig;
        },
        else => cl.failOur(c, .invalid, "bad_body", @errorName(err)),
    };
}

const SliceSource = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn read(self: *SliceSource, buf: []u8) usize {
        const n = @min(buf.len, self.bytes.len - self.pos);
        @memcpy(buf[0..n], self.bytes[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const ReaderSource = struct {
    reader: *std.Io.Reader,
    fn read(self: *ReaderSource, buf: []u8) error{ReadFailed}!usize {
        return self.reader.readSliceShort(buf);
    }
};

/// Reads exactly `len` bytes into the call's arena; fewer is "short_body".
fn readExactly(cl: *Client, c: anytype, r: *std.Io.Reader, len: u64) Error![]const u8 {
    const n = std.math.cast(usize, len) orelse return error.OutOfMemory;
    // The memory of every upload together.
    while (!cl.takeMemory(n)) {
        const seen = cl.bell.seen();
        if (cl.takeMemory(n)) break;
        try cl.bell.wait(cl.io, seen);
    }
    defer cl.giveMemory(n);
    const buf = try c.arena.alloc(u8, n);
    r.readSliceAll(buf) catch |err| switch (err) {
        error.EndOfStream => return cl.failOur(c, .invalid, "short_body", "the body ended before its declared length"),
        error.ReadFailed => return cl.failOur(c, .unavailable, "read_failed", "reading the body failed"),
    };
    return buf;
}

fn singlePut(b: Bucket, c: anytype, key: []const u8, data: []const u8, opts: PutOptions) Error!Stored {
    const cl = b.client;
    const bucket = try b.bucketName(c);
    var hl: root.Headers = .{};
    try cl.putHeaders(c, &hl, key, opts, true);
    const reply = try cl.execute(c, .{
        .name = "PutObject",
        .method = .put,
        .bucket = bucket,
        .key = key,
        .headers = hl.slice(),
        .body = data,
        .has_body = true,
        .want = .buffered,
        .max_bytes = 64 * 1024,
        .bound_bytes = data.len,
    }, b.call);
    return .{ .etag = reply.meta.etag, .version_id = reply.meta.version_id, .size = data.len, .parts = 0 };
}

/// The pull form: reads `source` in small chunks and writes them into an
/// upload, waiting (not buffering without bound) when it is full.
fn pump(b: Bucket, c: anytype, key: []const u8, opts: PutOptions, source_in: anytype, len: ?u64) Error!Stored {
    var source = source_in;
    const cl = b.client;
    const up = try open(b, c, key, opts, len);
    defer up.deinit();
    const scratch = try c.arena.alloc(u8, 64 * 1024);
    var sent: u64 = 0;
    while (true) {
        const n = switch (@TypeOf(source)) {
            SliceSource => source.read(scratch),
            ReaderSource => source.read(scratch) catch return cl.failOur(c, .unavailable, "read_failed", "reading the body failed"),
            else => unreachable,
        };
        if (n == 0) break;
        sent += n;
        const chunk = scratch[0..n];
        while (true) {
            const seen = cl.bell.seen();
            const r = try up.copyIn(c, chunk);
            if (r.rotated) up.wake.ring(up.io);
            switch (r.taken) {
                .ok => break,
                .busy => {
                    try up.waitWritable(c, null);
                    break;
                },
                // Room or memory appears when a part completes.
                .full => try cl.bell.wait(cl.io, seen),
            }
        }
    }
    if (len) |declared| if (sent != declared) return cl.failOur(c, .invalid, "short_body", "the body's length differs from the declared one");
    return up.finish(c);
}

test "upload: part size grows so that 10000 parts suffice" {
    try std.testing.expectEqual(@as(u64, 8 * mib), partSizeFor(8 * mib, null));
    try std.testing.expectEqual(@as(u64, 8 * mib), partSizeFor(8 * mib, 8 * mib * 9000));
    // 10001 * 5 MiB
    const big: u64 = 10001 * 5 * mib;
    try std.testing.expect(partSizeFor(5 * mib, big) >= std.math.divCeil(u64, big, max_parts) catch 0);
    try std.testing.expectEqual(@as(u64, 0), partSizeFor(5 * mib, big) % mib);
}
