//! `anole.testing`: an in-memory client for an app's routes and middleware.
//! A request goes through the full router, the global and group middleware
//! and the error answers as over HTTP/1.1, with no socket, no timer and no
//! polling: the call returns once the handler's task has finished and the
//! response has ended.
//!
//!     test "a blank title is a 422 that names the field" {
//!         var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
//!         defer app.deinit();
//!         app.post("/todos", create);
//!         var t = try anole.testing.client(&app);
//!         defer t.deinit();
//!         var res = try t.post("/todos", .{ .json = .{ .title = "   " } });
//!         defer res.deinit();
//!         try res.expectStatus(.unprocessable_entity);
//!         try res.expectViolation("title", "validation.not_blank");
//!     }
//!
//! WebSocket and WebTransport are not here (a memory sink cannot be
//! upgraded); docs/testing.md shows the loopback pattern for those.

const std = @import("std");
const dusty = @import("dusty");
const anole_log = @import("anole_log");
const errors = @import("../errors.zig");
const inmem = @import("../inmem.zig");

pub const RequestError = error{ OutOfMemory, InvalidTarget, WebSocketNotSupported, ConcurrencyUnavailable, Canceled };

pub const Header = struct { name: []const u8, value: []const u8 };

const placement = dusty.placement;
const default_listener: dusty.Listener = .{ .address = .{ .ip = .{ .ip4 = .unspecified(0) } } };

// ------------------------------------------------------------------ the sink

/// Where one response goes: its head, body pieces and trailers, kept in
/// `store` (which the result takes over). Locked, since a stream's reader
/// is another task than the handler.
const MemSink = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    store: std.heap.ArenaAllocator,
    status: dusty.Status = .ok,
    head_seen: bool = false,
    headers: std.ArrayList(Header) = .empty,
    pieces: std.ArrayList([]const u8) = .empty,
    trailers: std.ArrayList(Header) = .empty,
    ended: bool = false,
    /// The client left (`Stream.close`): writes fail.
    gone: bool = false,
    err: ?dusty.Response.SendError = null,
    writer: std.Io.Writer = undefined,

    fn init(self: *MemSink, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .io = io, .store = .init(gpa) };
        self.writer = .{ .vtable = &.{ .drain = drain, .flush = flushFn }, .buffer = &.{} };
    }

    fn sink(self: *MemSink) dusty.Sink {
        return .{ .ptr = self, .vtable = &.{
            .head = head,
            .interim = interim,
            .body = body,
            .end = end,
            .writeError = writeError,
            .peerGone = peerGone,
            .complete = complete,
        } };
    }

    fn fromPtr(ptr: *anyopaque) *MemSink {
        return @ptrCast(@alignCast(ptr));
    }

    fn lock(self: *MemSink) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *MemSink) void {
        self.mutex.unlock(self.io);
    }

    fn fail(self: *MemSink, err: dusty.Response.SendError) std.Io.Writer.Error {
        self.err = err;
        return error.WriteFailed;
    }

    fn hasBody(status: dusty.Status) bool {
        const code = @backingInt(status);
        return code >= 200 and code != 204 and code != 304;
    }

    fn headLocked(self: *MemSink, status: dusty.Status, headers: *const dusty.Headers, content_length: ?usize) std.Io.Writer.Error!void {
        const a = self.store.allocator();
        self.status = status;
        var has_length = false;
        var has_encoding = false;
        var it = headers.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key, "content-length")) has_length = true;
            if (std.ascii.eqlIgnoreCase(e.key, "transfer-encoding")) has_encoding = true;
            const name = a.dupe(u8, e.key) catch return self.fail(error.SystemResources);
            const value = a.dupe(u8, e.value) catch return self.fail(error.SystemResources);
            self.headers.append(a, .{ .name = name, .value = value }) catch return self.fail(error.SystemResources);
        }
        if (!has_length and !has_encoding and hasBody(status)) {
            const extra: Header = if (content_length) |len|
                .{ .name = "Content-Length", .value = std.fmt.allocPrint(a, "{d}", .{len}) catch return self.fail(error.SystemResources) }
            else
                .{ .name = "Transfer-Encoding", .value = "chunked" };
            self.headers.append(a, extra) catch return self.fail(error.SystemResources);
        }
        self.head_seen = true;
    }

    fn head(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, content_length: ?usize) std.Io.Writer.Error!void {
        const self = fromPtr(ptr);
        self.lock();
        defer self.unlock();
        try self.headLocked(status, headers, content_length);
        self.cond.broadcast(self.io);
    }

    fn interim(_: *anyopaque, _: dusty.Status) std.Io.Writer.Error!void {}

    fn body(ptr: *anyopaque) *std.Io.Writer {
        const self = fromPtr(ptr);
        if (self.writer.buffer.len == 0) self.writer.buffer = self.store.allocator().alloc(u8, 4096) catch &.{};
        return &self.writer;
    }

    fn pushLocked(self: *MemSink, parts: []const []const u8) std.Io.Writer.Error!void {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        if (total == 0) return;
        const a = self.store.allocator();
        const piece = a.alloc(u8, total) catch return self.fail(error.SystemResources);
        var at: usize = 0;
        for (parts) |p| {
            @memcpy(piece[at..][0..p.len], p);
            at += p.len;
        }
        self.pieces.append(a, piece) catch return self.fail(error.SystemResources);
    }

    /// One write or flush: the buffered bytes and `data` become one piece.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *MemSink = @alignCast(@fieldParentPtr("writer", w));
        self.lock();
        defer self.unlock();
        if (self.gone) return self.fail(error.ConnectionResetByPeer);
        var consumed: usize = 0;
        for (data) |d| consumed += d.len;
        if (data.len > 0) consumed = consumed - data[data.len - 1].len + data[data.len - 1].len * splat;
        // The buffer first, then the data (the last slice `splat` times).
        var list: std.ArrayList([]const u8) = .empty;
        const a = self.store.allocator();
        list.append(a, w.buffered()) catch return self.fail(error.SystemResources);
        for (data[0 .. data.len -| 1]) |d| list.append(a, d) catch return self.fail(error.SystemResources);
        if (data.len > 0) for (0..splat) |_| list.append(a, data[data.len - 1]) catch return self.fail(error.SystemResources);
        try self.pushLocked(list.items);
        w.end = 0;
        self.cond.broadcast(self.io);
        return consumed;
    }

    fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = try drain(w, &.{}, 1);
    }

    fn end(ptr: *anyopaque, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const self = fromPtr(ptr);
        self.lock();
        defer self.unlock();
        try self.trailersLocked(trailers);
        self.ended = true;
        self.cond.broadcast(self.io);
    }

    fn trailersLocked(self: *MemSink, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const t = trailers orelse return;
        const a = self.store.allocator();
        var it = t.iterator();
        while (it.next()) |e| {
            const name = a.dupe(u8, e.key) catch return self.fail(error.SystemResources);
            const value = a.dupe(u8, e.value) catch return self.fail(error.SystemResources);
            self.trailers.append(a, .{ .name = name, .value = value }) catch return self.fail(error.SystemResources);
        }
    }

    fn complete(
        ptr: *anyopaque,
        status: dusty.Status,
        headers: *const dusty.Headers,
        content_length: ?usize,
        parts: []const []const u8,
        trailers: ?*const dusty.Headers,
    ) std.Io.Writer.Error!void {
        const self = fromPtr(ptr);
        self.lock();
        defer self.unlock();
        if (self.gone) return self.fail(error.ConnectionResetByPeer);
        try self.headLocked(status, headers, content_length);
        try self.pushLocked(parts);
        try self.trailersLocked(trailers);
        self.ended = true;
        self.cond.broadcast(self.io);
    }

    fn writeError(ptr: *anyopaque) ?dusty.Response.SendError {
        return fromPtr(ptr).err;
    }

    fn peerGone(ptr: *anyopaque) bool {
        const self = fromPtr(ptr);
        self.lock();
        defer self.unlock();
        return self.gone;
    }

    /// The handler is done: whatever the response left open is closed.
    fn finish(self: *MemSink) void {
        self.lock();
        defer self.unlock();
        self.ended = true;
        self.head_seen = true;
        self.cond.broadcast(self.io);
    }
};

// ------------------------------------------------------------------ one exchange

fn Run(comptime Ctx: type) type {
    return struct {
        gpa: std.mem.Allocator,
        /// The request's own memory.
        arena: std.heap.ArenaAllocator,
        sink: MemSink,
        exchange: inmem.Exchange(Ctx),
        group: std.Io.Group = .init,
        listener: dusty.Listener = default_listener,
        started: bool = false,

        const Self = @This();

        fn task(core: *dusty.Server(Ctx), self: *Self) void {
            defer self.sink.finish();
            const res = &self.exchange.response;
            defer res.deinit();
            core.dispatch(&self.exchange.request, res) catch |err| {
                // Canceled (the client left) or a head already out: nothing more to say.
                if (err == error.Canceled or res.headersSent()) return;
                res.resetBody() catch {};
                res.status = .internal_server_error;
                res.content_type = .text;
                res.body = "500 Internal Server Error\n";
            };
            res.write() catch {};
        }

        fn destroy(self: *Self) void {
            const gpa = self.gpa;
            self.arena.deinit();
            self.sink.store.deinit();
            gpa.destroy(self);
        }
    };
}

fn parseOptions(comptime Options: type) void {
    comptime {
        if (@typeInfo(Options) != .@"struct") @compileError("anole.testing: the options are a struct literal such as .{ .json = value }");
        for (@typeInfo(Options).@"struct".field_names) |name| {
            const known = [_][]const u8{ "headers", "body", "json", "remote_address", "secure", "listener" };
            const ok = for (known) |k| {
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            if (!ok) @compileError("anole.testing: unknown option ." ++ name ++ "; the options are .headers, .body, .json, .remote_address, .secure and .listener");
        }
        if (@hasField(Options, "body") and @hasField(Options, "json"))
            @compileError("anole.testing: give .body or .json, not both");
    }
}

// ------------------------------------------------------------------ the client

/// An in-memory client for `server` (`*anole.App` or `*anole.Server(Ctx)`).
pub fn client(server: anytype) errors.ServerError!Client(@typeInfo(@TypeOf(server)).pointer.child) {
    return Client(@typeInfo(@TypeOf(server)).pointer.child).init(server);
}

pub fn Client(comptime S: type) type {
    return struct {
        server: *S,

        const Self = @This();
        const Ctx = S.State;
        const RunT = Run(Ctx);

        /// Prepares the server as `run` would before binding (helper routes,
        /// the conflict check, connectors); a route conflict prints its
        /// message to stderr and fails with `error.RouteConflict`.
        pub fn init(server: *S) errors.ServerError!Self {
            try server._prepareInMemory();
            return .{ .server = server };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        fn start(self: *Self, method: dusty.Method, target: []const u8, opts: anytype) RequestError!*RunT {
            comptime parseOptions(@TypeOf(opts));
            if (target.len == 0 or target[0] != '/') return error.InvalidTarget;
            const gpa = self.server.gpa;
            const run = try gpa.create(RunT);
            run.* = .{ .gpa = gpa, .arena = .init(gpa), .sink = undefined, .exchange = undefined };
            errdefer run.destroy();
            run.sink.init(gpa, self.server.rt.io());
            const a = run.arena.allocator();

            var fields: std.ArrayList(inmem.Field) = .empty;
            var upgrade = false;
            if (comptime @hasField(@TypeOf(opts), "headers")) {
                for (opts.headers) |h| {
                    try fields.append(a, .{ .name = h[0], .value = h[1] });
                    if (std.ascii.eqlIgnoreCase(h[0], "upgrade") and std.ascii.eqlIgnoreCase(h[1], "websocket")) upgrade = true;
                }
            }
            if (upgrade) return error.WebSocketNotSupported;
            var body: []const u8 = "";
            if (comptime @hasField(@TypeOf(opts), "body")) body = opts.body;
            if (comptime @hasField(@TypeOf(opts), "json")) {
                body = std.json.Stringify.valueAlloc(a, opts.json, .{}) catch return error.OutOfMemory;
                const has_type = for (fields.items) |f| {
                    if (std.ascii.eqlIgnoreCase(f.name, "content-type")) break true;
                } else false;
                if (!has_type) try fields.append(a, .{ .name = "Content-Type", .value = "application/json" });
            }
            if (comptime @hasField(@TypeOf(opts), "listener")) run.listener = .{ .address = default_listener.address, .name = opts.listener };

            const status = run.exchange.init(self.server.server, a, run.sink.sink(), .{
                .method = method,
                .target = target,
                .headers = fields.items,
                .body = body,
                .client = if (comptime @hasField(@TypeOf(opts), "remote_address")) opts.remote_address else defaultClient(),
                .secure = if (comptime @hasField(@TypeOf(opts), "secure")) opts.secure else false,
                .listener = &run.listener,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            if (status == .answered) {
                run.sink.finish();
                return run;
            }
            const io = self.server.rt.io();
            placement.concurrent(&run.group, io, .local, RunT.task, .{ self.server.server, run }) catch return error.ConcurrencyUnavailable;
            run.started = true;
            return run;
        }

        fn defaultClient() std.Io.net.IpAddress {
            return .{ .ip4 = .loopback(50000) };
        }

        /// One request, answered once the handler has finished.
        /// `options`: a struct literal with any of `.headers`
        /// (`[]const [2][]const u8`), `.body`, `.json` (any value; sets
        /// `Content-Type: application/json` unless given), `.remote_address`
        /// (default 127.0.0.1:50000), `.secure` and `.listener` (a listener
        /// name). An unknown key is a compile error; `.body` with `.json`
        /// too. An `Upgrade: websocket` request is
        /// `error.WebSocketNotSupported`.
        pub fn request(self: *Self, method: dusty.Method, target: []const u8, opts: anytype) RequestError!Response {
            const run = try self.start(method, target, opts);
            defer run.destroy();
            if (run.started) run.group.await(self.server.rt.io()) catch return error.Canceled;
            return Response.fromSink(&run.sink);
        }

        pub fn get(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.get, target, opts);
        }
        pub fn head(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.head, target, opts);
        }
        pub fn post(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.post, target, opts);
        }
        pub fn put(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.put, target, opts);
        }
        pub fn patch(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.patch, target, opts);
        }
        pub fn delete(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.delete, target, opts);
        }
        pub fn options(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.options, target, opts);
        }
        pub fn query(self: *Self, target: []const u8, opts: anytype) RequestError!Response {
            return self.request(.query, target, opts);
        }

        /// For a streamed answer (SSE): returns once the head is out.
        /// Read it with `next` or `nextEvent`; `deinit` it.
        pub fn open(self: *Self, method: dusty.Method, target: []const u8, opts: anytype) RequestError!*Stream {
            const run = try self.start(method, target, opts);
            errdefer run.destroy();
            const io = self.server.rt.io();
            const stream = try self.server.gpa.create(Stream);
            errdefer self.server.gpa.destroy(stream);
            stream.* = .{
                .gpa = self.server.gpa,
                .sink = &run.sink,
                .group = &run.group,
                .started = run.started,
                .io = io,
                .owner = run,
                .destroy_fn = destroyRun,
                .status = .ok,
                .headers = &.{},
                .sse = .empty,
                .events = .init(self.server.gpa),
            };
            // The head is out.
            run.sink.lock();
            while (!run.sink.head_seen and !run.sink.ended) run.sink.cond.wait(io, &run.sink.mutex) catch {
                run.sink.unlock();
                return error.Canceled;
            };
            stream.status = run.sink.status;
            stream.headers = run.sink.headers.items;
            run.sink.unlock();
            return stream;
        }

        fn destroyRun(owner: *anyopaque) void {
            const run: *RunT = @ptrCast(@alignCast(owner));
            run.destroy();
        }
    };
}

// ------------------------------------------------------------------ results

/// A finished response. `deinit` it.
pub const Response = struct {
    status: dusty.Status,
    /// As the app set them, plus `Content-Length` (or `Transfer-Encoding:
    /// chunked` for a streamed body).
    headers: []const Header,
    /// Empty for HEAD, 204 and 304.
    body: []const u8,
    trailers: []const Header,
    arena: std.heap.ArenaAllocator,

    /// Takes over the sink's memory.
    fn fromSink(sink: *MemSink) Response {
        var result: Response = .{
            .status = sink.status,
            .headers = sink.headers.items,
            .body = "",
            .trailers = sink.trailers.items,
            .arena = sink.store,
        };
        // The pieces become one body, in the same memory.
        var total: usize = 0;
        for (sink.pieces.items) |p| total += p.len;
        if (total > 0) {
            const a = result.arena.allocator();
            if (a.alloc(u8, total)) |buf| {
                var at: usize = 0;
                for (sink.pieces.items) |p| {
                    @memcpy(buf[at..][0..p.len], p);
                    at += p.len;
                }
                result.body = buf;
            } else |_| {}
        }
        // The memory is the result's now.
        sink.store = std.heap.ArenaAllocator.init(result.arena.child_allocator);
        return result;
    }

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
    }

    /// The first header called `name` (case-insensitive).
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The body as a `T` (std.json, unknown fields ignored), in the arena.
    pub fn json(self: *Response, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena.allocator(), self.body, .{ .ignore_unknown_fields = true });
    }

    pub fn expectStatus(self: *const Response, status: dusty.Status) !void {
        if (self.status == status) return;
        std.debug.print("\nexpected status {d} {s}, got {d} {s}\n{s}\n", .{ @backingInt(status), status.phrase(), @backingInt(self.status), self.status.phrase(), bodyHead(self.body) });
        return error.TestExpectedEqual;
    }

    pub fn expectHeader(self: *const Response, name: []const u8, value: []const u8) !void {
        const got = self.header(name) orelse {
            std.debug.print("\nexpected header {s}: {s}, but the response has none\n", .{ name, value });
            return error.TestUnexpectedResult;
        };
        if (std.mem.eql(u8, got, value)) return;
        std.debug.print("\nexpected header {s}: {s}, got {s}\n", .{ name, value, got });
        return error.TestExpectedEqual;
    }

    pub fn expectBody(self: *const Response, text: []const u8) !void {
        if (std.mem.eql(u8, self.body, text)) return;
        std.debug.print("\nexpected body:\n{s}\ngot ({d} {s}):\n{s}\n", .{ text, @backingInt(self.status), self.status.phrase(), bodyHead(self.body) });
        return error.TestExpectedEqual;
    }

    /// The body equals `expected` as JSON (key order and whitespace do not
    /// matter).
    pub fn expectJson(self: *Response, expected: anytype) !void {
        const a = self.arena.allocator();
        const want_text = try std.json.Stringify.valueAlloc(a, expected, .{});
        const want = try std.json.parseFromSliceLeaky(std.json.Value, a, want_text, .{});
        const got = std.json.parseFromSliceLeaky(std.json.Value, a, self.body, .{}) catch {
            std.debug.print("\nexpected JSON {s}, but the body is not JSON:\n{s}\n", .{ want_text, bodyHead(self.body) });
            return error.TestUnexpectedResult;
        };
        if (jsonEqual(want, got)) return;
        std.debug.print("\nexpected JSON:\n{s}\ngot:\n{s}\n", .{ want_text, bodyHead(self.body) });
        return error.TestExpectedEqual;
    }

    /// A problem document with a violation at `field` (null: the root
    /// value) with `code`.
    pub fn expectViolation(self: *Response, field: ?[]const u8, code: []const u8) !void {
        const a = self.arena.allocator();
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, self.body, .{}) catch {
            std.debug.print("\nexpected a problem document, but the body is not JSON ({d}):\n{s}\n", .{ @backingInt(self.status), bodyHead(self.body) });
            return error.TestUnexpectedResult;
        };
        if (doc == .object) if (doc.object.get("errors")) |list| if (list == .array) for (list.array.items) |item| {
            if (item != .object) continue;
            const c = item.object.get("code") orelse continue;
            if (c != .string or !std.mem.eql(u8, c.string, code)) continue;
            const f = item.object.get("field");
            if (field) |want| {
                if (f != null and f.? == .string and std.mem.eql(u8, f.?.string, want)) return;
            } else if (f == null) return;
        };
        std.debug.print("\nexpected a violation of {s} at {s}, got ({d}):\n{s}\n", .{ code, field orelse "(root)", @backingInt(self.status), bodyHead(self.body) });
        return error.TestUnexpectedResult;
    }
};

fn bodyHead(body: []const u8) []const u8 {
    return body[0..@min(body.len, 2048)];
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        // 1 and 1.0 are the same number.
        const num = struct {
            fn f(v: std.json.Value) ?f64 {
                return switch (v) {
                    .integer => |i| @floatFromInt(i),
                    .float => |x| x,
                    else => null,
                };
            }
        }.f;
        const x = num(a) orelse return false;
        const y = num(b) orelse return false;
        return x == y;
    }
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |l, r| if (!jsonEqual(l, r)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// A streamed answer (`Client.open`): server-sent events, say.
pub const Stream = struct {
    status: dusty.Status,
    headers: []const Header,

    gpa: std.mem.Allocator,
    sink: *MemSink,
    group: *std.Io.Group,
    started: bool,
    io: std.Io,
    owner: *anyopaque,
    destroy_fn: *const fn (*anyopaque) void,
    next_piece: usize = 0,
    closed: bool = false,
    /// Text read but not yet parsed into events.
    sse: std.ArrayList(u8),
    /// The strings of the events returned.
    events: std.heap.ArenaAllocator,

    pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The next piece the server wrote (one write or flush); null once the
    /// response ended. Waits for it: there is no timeout, so a test that
    /// waits for something that never comes hangs.
    pub fn next(self: *Stream) RequestError!?[]const u8 {
        const sink = self.sink;
        sink.lock();
        defer sink.unlock();
        while (true) {
            if (self.next_piece < sink.pieces.items.len) {
                defer self.next_piece += 1;
                return sink.pieces.items[self.next_piece];
            }
            if (sink.ended) return null;
            sink.cond.wait(self.io, &sink.mutex) catch return error.Canceled;
        }
    }

    pub const Event = struct { event: ?[]const u8, data: []const u8, id: ?[]const u8 };

    /// The next server-sent event (comments and `retry` lines skipped); null
    /// at the end.
    pub fn nextEvent(self: *Stream) RequestError!?Event {
        const a = self.events.allocator();
        while (true) {
            if (try self.parseEvent(a)) |event| return event;
            const piece = (try self.next()) orelse return null;
            self.sse.appendSlice(self.gpa, piece) catch return error.OutOfMemory;
        }
    }

    /// An event from `sse`, or null while it holds no whole one.
    fn parseEvent(self: *Stream, a: std.mem.Allocator) RequestError!?Event {
        while (true) {
            const text = self.sse.items;
            // An event ends at a blank line.
            var end_at: ?usize = null;
            var sep_len: usize = 2;
            var i: usize = 0;
            while (i + 1 < text.len) : (i += 1) {
                if (text[i] == '\n' and text[i + 1] == '\n') {
                    end_at = i;
                    sep_len = 2;
                    break;
                }
                if (i + 3 < text.len and text[i] == '\r' and text[i + 1] == '\n' and text[i + 2] == '\r' and text[i + 3] == '\n') {
                    end_at = i;
                    sep_len = 4;
                    break;
                }
            }
            const stop = end_at orelse return null;
            const block = text[0..stop];
            var event: ?[]const u8 = null;
            var id: ?[]const u8 = null;
            var data: std.ArrayList(u8) = .empty;
            var have_data = false;
            var lines = std.mem.splitScalar(u8, block, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len == 0 or line[0] == ':') continue;
                const colon = std.mem.indexOfScalar(u8, line, ':');
                const name = line[0 .. colon orelse line.len];
                var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
                if (value.len > 0 and value[0] == ' ') value = value[1..];
                if (std.mem.eql(u8, name, "data")) {
                    if (have_data) data.append(a, '\n') catch return error.OutOfMemory;
                    data.appendSlice(a, value) catch return error.OutOfMemory;
                    have_data = true;
                } else if (std.mem.eql(u8, name, "event")) {
                    event = a.dupe(u8, value) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, name, "id")) {
                    id = a.dupe(u8, value) catch return error.OutOfMemory;
                }
            }
            const rest = text[stop + sep_len ..];
            std.mem.copyForwards(u8, self.sse.items[0..rest.len], rest);
            self.sse.shrinkRetainingCapacity(rest.len);
            // Only comments or retry: not an event, read on.
            if (!have_data and event == null and id == null) continue;
            return .{ .event = event, .data = data.items, .id = id };
        }
    }

    /// The client leaves: further writes fail as for a reset stream, the
    /// handler's task is canceled, and it is awaited.
    pub fn close(self: *Stream) void {
        if (self.closed) return;
        self.closed = true;
        const sink = self.sink;
        sink.lock();
        sink.gone = true;
        sink.cond.broadcast(self.io);
        sink.unlock();
        if (self.started) self.group.cancel(self.io);
    }

    /// `close`, then frees everything.
    pub fn deinit(self: *Stream) void {
        self.close();
        self.sse.deinit(self.gpa);
        self.events.deinit();
        const gpa = self.gpa;
        self.destroy_fn(self.owner);
        gpa.destroy(self);
    }
};

// ------------------------------------------------------------------ logs

/// Captures log lines (in the active format: the message in text, the
/// whole record in JSON) in place of stderr, from `start` to `deinit`.
pub const LogCapture = struct {
    gpa: std.mem.Allocator,
    lock_flag: std.atomic.Value(bool) = .init(false),
    list: std.ArrayList([]const u8) = .empty,
    previous: ?*const anole_log.Callback = null,
    callback: anole_log.Callback = undefined,
    active: bool = false,

    pub fn init(gpa: std.mem.Allocator) LogCapture {
        return .{ .gpa = gpa };
    }

    fn lockSpin(self: *LogCapture) void {
        while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlockSpin(self: *LogCapture) void {
        self.lock_flag.store(false, .release);
    }

    fn capture(ud: ?*anyopaque, _: std.log.Level, _: []const u8, line: []const u8) void {
        const self: *LogCapture = @ptrCast(@alignCast(ud.?));
        const copy = self.gpa.dupe(u8, line) catch return;
        self.lockSpin();
        defer self.unlockSpin();
        self.list.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    /// Records go here instead of stderr until `deinit`. `self` must not
    /// move while started.
    pub fn start(self: *LogCapture) void {
        self.previous = anole_log.currentSink();
        self.callback = .{ .func = capture, .ud = self };
        self.active = true;
        anole_log.setSink(&self.callback);
    }

    /// Restores the previous sink and frees the lines.
    pub fn deinit(self: *LogCapture) void {
        if (self.active) anole_log.setSink(self.previous);
        self.active = false;
        for (self.list.items) |l| self.gpa.free(l);
        self.list.deinit(self.gpa);
    }

    pub fn lines(self: *LogCapture) []const []const u8 {
        self.lockSpin();
        defer self.unlockSpin();
        return self.list.items;
    }

    pub fn expectContains(self: *LogCapture, needle: []const u8) !void {
        for (self.lines()) |l| if (std.mem.indexOf(u8, l, needle) != null) return;
        std.debug.print("\nexpected a log line containing \"{s}\"; captured {d}:\n", .{ needle, self.lines().len });
        for (self.lines()) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
};
