//! The HTTP/2 server engine on Anole's own protocol core (conn.zig;
//! research/h2h3-takeover/PLAN.md §3.3-§3.5, M3), in place of the nghttp2
//! engine (src/http/core/server/h2_nghttp2.zig) once the server switches to
//! it. A connection runs as
//!
//!   * the reader (the connection's own task, which entered `serve`): reads,
//!     feeds `Conn.recv`, runs the `no_wait` requests that came whole in the
//!     read (`runInline`), then writes one batch of output itself;
//!   * one task per other stream (`runStream`): builds a `Request` and a
//!     sink-backed `Response` and runs the router, as the nghttp2 engine's
//!     stream tasks do, so handlers and middleware are unchanged;
//!   * a flusher task, only while output is left over (`flusherRun`).
//!
//! There is no writer task. Output goes out under a **flush token**
//! (`Conn.flushing`): whoever takes it writes `Conn.pending` until it is
//! empty, everyone else only queues and returns, so one task writes at a
//! time (TLS's one reader and one writer hold). The reader and a stream task
//! whose handler is done write one batch and hand the rest to the flusher
//! (Go's x/net/http2 startFrameWrite/writeFrameAsync rule): a reader blocked
//! in a write would stop taking WINDOW_UPDATEs, and a handler task can be
//! canceled (its stream's reset, its request timer), which must never cut a
//! frame in half. A handler that streams a body waits on its own stream's
//! `room` for its blocks to go out, never on a connection-wide signal.
//!
//! **Locking** (`ConnLock`): everything the tasks share (the protocol core,
//! its output queue, the streams' state) is touched only under it, and
//! nothing under it yields. On zio with pinned scheduling a connection's
//! tasks are all on one executor and switch only at a yield, so the lock is
//! no lock at all (a Debug check of the executor); elsewhere (the tests on
//! std.Io.Threaded) a mutex.
//!
//! **Memory** (PLAN §3.4): the read buffer from `RequestBuffers`; the write
//! buffer from the same pool only while the token is held; `out`'s 16 KiB
//! blocks from malloc's slabs, freed at the first read after a trim interval
//! that finds the connection idle (one that reads nothing more keeps them
//! until its keep-alive deadline); the HPACK scratch one per executor (`scratch`); a request body
//! sized as the nghttp2 engine's (`BodyBuf`); a streamed response in at most
//! two 16 KiB blocks. A stream's arena, body and blocks are reused or freed
//! only once `out` no longer borrows them (`retiring`).
//!
//! Not here yet (PLAN §4 M3's other items): detached and parked responses,
//! RFC 8441 tunnels, the sweeper (send deadlines, half-close probes) and the
//! two-phase drain. The drain's flags are here and acted on as the reader
//! next loops.
const std = @import("std");
const builtin = @import("builtin");
const safety = @import("anole_safety");

const conn_mod = @import("conn.zig");
const hpack = @import("hpack.zig");
const http = @import("../http.zig");
const server_mod = @import("../server.zig");
const Connection = server_mod.Connection;
const Listener = @import("../config.zig").Listener;
const ServerConfig = @import("../config.zig").ServerConfig;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Sink = @import("../sink.zig").Sink;
const Transport = @import("../transport.zig").Transport;
const Timer = @import("../deadline.zig").Timer;
const placement = @import("../placement.zig");
const admission = @import("../admission.zig");
const gauges = @import("../gauges.zig");
const block_cache = @import("../block_cache.zig");
const Signal = @import("../signal.zig").Signal;

const log = std.log.scoped(.anole_h2);

/// The client connection preface and its sniffing, shared with the nghttp2
/// engine (server.zig calls them before choosing the engine).
const nghttp2_engine = @import("../server/h2_nghttp2.zig");
pub const preface = nghttp2_engine.preface;
pub const sniffPreface = nghttp2_engine.sniffPreface;

/// A request body up to this long comes from the stream's arena.
const arena_body_max = 4 * 1024;
/// Spare streams a connection keeps for reuse (as the nghttp2 engine).
const max_spare_streams = 128;
const min_spare_streams = 16;
/// What a stream's arena keeps between requests (as the nghttp2 engine:
/// an 8 KiB malloc class with the arena's node header).
const arena_retain_limit = 8 * 1024 - 4 * @sizeOf(usize);
/// A streamed response's block: the body writer's buffer, then borrowed by
/// `out` until written. Two per stream on a task.
const block_len = 16 * 1024;
/// Iovecs per `pending` round. Rounds go into the connection's buffered
/// writer back to back, with one flush at the end (`writeOut`).
const max_vecs = 64;
/// The PING sent with a drain's GOAWAY notice.
const drain_ping: [8]u8 = "anole-go".*;

const is_test = builtin.is_test;

/// Tests only: handler tasks spawned (`spawnTasked`).
pub var test_spawned: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: flusher tasks spawned.
pub var test_flushers: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: tasks inside a write now, and the most ever at once.
pub var test_writers_in: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
pub var test_max_writers: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: `out` released by an idle connection.
pub var test_out_releases: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: streams kept for `out`'s borrowed bytes past their close,
/// then let go once written.
pub var test_retired: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: reads the reader fed to `Conn.recv`.
pub var test_reads: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: response blocks allocated (`StreamSink`).
pub var test_blocks: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: in place of `limits.Limits.out_high`.
pub var test_out_high: if (is_test) ?usize else void = if (is_test) null else {};
/// Tests only: the trim epoch, in place of `Server.trim_epoch`.
pub var test_trim_epoch: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: whether the last connection served ran lock-free.
pub var test_lock_free: if (is_test) std.atomic.Value(bool) else void = if (is_test) .init(false) else {};

/// The HPACK scratch `Conn.recv` decodes into, one per executor (recv never
/// yields), from the block cache and never given back.
threadlocal var scratch_block: []align(16) u8 = &.{};

const Field = struct { name: []const u8, value: []const u8 };

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = server_mod.Server(Ctx);
        const Proto = conn_mod.Conn(.server, Conn);
        const PStream = conn_mod.Stream;

        /// The server's open HTTP/2 connections, for the drain. A
        /// connection registers only once `Server.h2_conns` is this type
        /// (until then it is the nghttp2 engine's). The drain from another
        /// executor only sets a connection's flag (`drain_req`); the reader
        /// acts on it.
        pub const Registry = struct {
            mutex: safety.Mutex(.table) = .init,
            list: std.DoublyLinkedList = .{},

            fn server(r: *Registry) *Server {
                // SAFETY: the registry is the server's `h2_conns` field (`registered` in `serve`).
                return @alignCast(@fieldParentPtr("h2_conns", r));
            }

            fn add(r: *Registry, conn: *Conn) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                r.list.append(&conn.node);
                r.mutex.unlock(io);
                if (r.server().busy.load(.acquire).draining) conn.drain_req.store(drain_notice_req, .release);
            }

            fn remove(r: *Registry, conn: *Conn) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                r.list.remove(&conn.node);
            }

            /// Asks every connection for the drain's GOAWAY notice. Whether
            /// there were any.
            pub fn beginDrain(r: *Registry) bool {
                return r.request(drain_notice_req);
            }

            /// Asks for the final GOAWAY.
            pub fn finishDrain(r: *Registry) void {
                _ = r.request(drain_final_req);
            }

            fn request(r: *Registry, what: u8) bool {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                var it = r.list.first;
                while (it) |node| : (it = node.next) {
                    // SAFETY: every node in the list is a Conn's `node` (`add`).
                    const conn: *Conn = @alignCast(@fieldParentPtr("node", node));
                    _ = conn.drain_req.fetchMax(what, .acq_rel);
                }
                return r.list.first != null;
            }

            /// Tests only: the spare streams the open connections keep.
            pub fn sparesForTest(r: *Registry) usize {
                if (!is_test) @compileError("sparesForTest is for tests");
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                var n: usize = 0;
                var it = r.list.first;
                while (it) |node| : (it = node.next) {
                    // SAFETY: every node in the list is a Conn's `node` (`add`).
                    const conn: *Conn = @alignCast(@fieldParentPtr("node", node));
                    conn.lock();
                    defer conn.unlock();
                    n += conn.spares.items.len;
                }
                return n;
            }
        };

        const drain_notice_req = 1;
        const drain_final_req = 2;

        /// The connection's lock (PLAN §3.3): none when the connection's
        /// tasks share one executor and switch only at a yield
        /// (`placement.single_executor_guarantee` and a zio `Io`), else a
        /// mutex. Nothing under it may yield.
        const ConnLock = struct {
            mutex: safety.Mutex(.protocol) = .init,
            free: bool = false,
            owner: usize = 0,
            held: if (builtin.mode == .debug) bool else void = if (builtin.mode == .debug) false else {},

            fn lock(l: *ConnLock, io: std.Io) void {
                if (l.free) {
                    if (comptime builtin.mode == .debug) {
                        std.debug.assert(placement.currentExecutor(io) == l.owner);
                        std.debug.assert(!l.held);
                        l.held = true;
                    }
                    return;
                }
                l.mutex.lockUncancelable(io);
            }

            fn unlock(l: *ConnLock, io: std.Io) void {
                if (l.free) {
                    if (comptime builtin.mode == .debug) l.held = false;
                    return;
                }
                l.mutex.unlock(io);
            }
        };

        /// One HTTP/2 connection: the protocol core (whose handler this
        /// is), the streams, and what the reader, the stream tasks and the
        /// flusher share, all under `lock_`.
        const Conn = struct {
            server: *Server,
            connection: *Connection,
            listener: *const Listener,
            secure: bool,
            io: std.Io,
            allocator: std.mem.Allocator,
            config: ServerConfig.Http2,
            group: *std.Io.Group,
            task_row: ?*admission.Row = null,
            lock_: ConnLock = .{},
            // SAFETY: set by `serve` before anything reads it.
            proto: Proto = undefined,
            /// A connection's own scratch, when the per-executor one can't
            /// hold `max_header_list_size` (past the block cache's classes).
            own_scratch: []u8 = &.{},

            /// The flush token: a task is writing `proto`'s output.
            flushing: bool = false,
            /// The token holder's: bytes sit in the connection's writer,
            /// not flushed yet (passed on with the token to the flusher).
            unflushed: bool = false,
            /// Nothing more is written: a write failed (both directions
            /// are shut) or the connection is over.
            send_shut: bool = false,
            /// The reader is done.
            closing: bool = false,

            /// Every stream with a hold left (`EStream.holds`).
            live: std.DoublyLinkedList = .{},
            /// Streams kept for reuse with their arenas.
            spares: std.ArrayList(*EStream) = .empty,
            max_spares: usize = min_spare_streams,
            spare_low: usize = 0,
            spare_epoch: u32 = 0,
            /// Closed streams whose bytes `out` may still borrow, oldest
            /// first, each until `out.sent_total` passes its mark.
            retiring: std.DoublyLinkedList = .{},
            /// Streams waiting for a response block to be written
            /// (`EStream.room`).
            room_waiters: std.DoublyLinkedList = .{},

            /// `no_wait` requests that came whole, for the reader to run
            /// after the read; and those whose body is still coming. Only
            /// the reader touches them.
            ready: std.ArrayList(*EStream) = .empty,
            awaiting: std.ArrayList(*EStream) = .empty,
            inline_ok: bool = false,

            /// Streams with a handler that have not let go yet; the
            /// connection holds one count in the server's in-flight
            /// requests while any is (#99).
            open_streams: usize = 0,
            busy_held: bool = false,
            /// What the streams' raised body windows take
            /// (`Http2.reading_window_budget`).
            raised_bytes: usize = 0,

            /// The drain's requests (`Registry`), and what was sent.
            drain_req: std.atomic.Value(u8) = .init(0),
            drain_notice: bool = false,
            goaway_sent: bool = false,
            node: std.DoublyLinkedList.Node = .{},

            fn lock(conn: *Conn) void {
                conn.lock_.lock(conn.io);
            }

            fn unlock(conn: *Conn) void {
                conn.lock_.unlock(conn.io);
            }

            /// Under the lock.
            fn holdBusy(conn: *Conn) void {
                conn.open_streams += 1;
                if (conn.busy_held) return;
                conn.busy_held = true;
                _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            }

            /// Under the lock.
            fn releaseBusyIfIdle(conn: *Conn) void {
                if (!conn.busy_held or conn.open_streams != 0) return;
                conn.busy_held = false;
                conn.server.finishRequest();
            }

            fn trimEpoch(conn: *Conn) u32 {
                if (comptime is_test) return test_trim_epoch.load(.monotonic);
                return conn.server.trim_epoch.load(.monotonic);
            }

            /// Once a trim interval has passed: the spares unused since the
            /// last trim go (as the nghttp2 engine's `trimSpares`), and an
            /// idle connection's output blocks. Under the lock.
            fn trimIdle(conn: *Conn) void {
                const epoch = conn.trimEpoch();
                if (epoch == conn.spare_epoch) return;
                conn.spare_epoch = epoch;
                const n = @min(conn.spare_low, conn.spares.items.len -| min_spare_streams);
                for (0..n) |_| conn.spares.pop().?.destroy(conn.allocator);
                conn.spare_low = conn.spares.items.len;
                if (!conn.flushing and conn.open_streams == 0 and conn.proto.out.idle() and conn.proto.out.blocks.items.len > 0) {
                    conn.proto.out.release();
                    if (comptime is_test) _ = test_out_releases.fetchAdd(1, .monotonic);
                }
            }

            /// The HPACK scratch for `recv`. Under the lock (it never
            /// yields).
            fn scratch(conn: *Conn) error{OutOfMemory}![]u8 {
                const need = @max(conn.proto.opts.max_header_list_size, hpack.table_capacity);
                if (conn.own_scratch.len >= need) return conn.own_scratch;
                if (scratch_block.len >= need) return scratch_block;
                if (block_cache.classFor(need)) |class| {
                    const block = block_cache.take(class) orelse return error.OutOfMemory;
                    if (scratch_block.len > 0) block_cache.give(scratch_block);
                    scratch_block = block;
                    return block;
                }
                conn.own_scratch = try conn.allocator.alloc(u8, need);
                return conn.own_scratch;
            }

            // -- Conn's handler (conn.zig), called inside its calls, under
            // -- the lock.

            pub fn onStreamOpen(conn: *Conn, s: *PStream) conn_mod.Error!void {
                // A draining server takes no new requests: refused, which
                // the client may retry elsewhere. Between the drain's
                // notice and its final GOAWAY they are still taken (the
                // GOAWAY of the refusal and the drain's wake are the
                // lifecycle item's).
                if (conn.server.busy.load(.acquire).draining and !conn.drain_notice) {
                    conn.proto.reset(s, .refused_stream) catch return error.ResetStream;
                    return;
                }
                const es = EStream.create(conn) catch return error.ResetStream;
                es.cs = s;
                es.id = s.id;
                es.protocol_hold = true;
                s.user = es;
                conn.live.append(&es.node);
                gauges.add(conn.io, .h2_streams, 1);
            }

            pub fn onField(conn: *Conn, s: *PStream, name: []const u8, value: []const u8) conn_mod.Error!void {
                _ = conn;
                const es = EStream.of(s) orelse return;
                // Trailers on a request are not passed on (as the nghttp2
                // engine).
                if (s.flags.in_trailers) return;
                const arena = es.arena.allocator();
                const v = arena.dupe(u8, value) catch return error.ResetStream;
                if (name[0] == ':') {
                    if (std.mem.eql(u8, name, ":method")) {
                        es.method = v;
                    } else if (std.mem.eql(u8, name, ":path")) {
                        es.path = v;
                    } else if (std.mem.eql(u8, name, ":authority")) {
                        es.authority = v;
                    } else if (std.mem.eql(u8, name, ":scheme")) {
                        es.scheme = v;
                    } else if (std.mem.eql(u8, name, ":protocol")) {
                        es.protocol = v;
                    }
                    return;
                }
                // fields.zig has checked it (and holds the DATA to it).
                if (std.mem.eql(u8, name, "content-length")) es.content_length = std.fmt.parseInt(u64, v, 10) catch null;
                const n = arena.dupe(u8, name) catch return error.ResetStream;
                es.headers.append(arena, .{ .name = n, .value = v }) catch return error.ResetStream;
            }

            pub fn onHeadersEnd(conn: *Conn, s: *PStream, end_stream: bool) conn_mod.Error!void {
                const es = EStream.of(s) orelse return;
                if (s.flags.in_trailers) {
                    if (end_stream) conn.bodyEnded(es);
                    return;
                }
                es.body_done = end_stream;
                if (conn.inline_ok and conn.noWaitRoute(es)) {
                    conn.holdBusy();
                    es.counted = true;
                    es.handler_hold = true;
                    if (end_stream) {
                        conn.queueInline(es);
                        return;
                    }
                    if (conn.awaiting.append(conn.allocator, es)) |_| {
                        es.await_body = true;
                        return;
                    } else |_| {}
                }
                conn.spawnTasked(es);
            }

            pub fn onData(conn: *Conn, s: *PStream, bytes: []const u8, end_stream: bool) conn_mod.Error!void {
                const es = EStream.of(s) orelse {
                    conn.proto.consumed(s, bytes.len) catch return error.ResetStream;
                    return;
                };
                if (es.reset or es.discarding) {
                    conn.proto.consumed(s, bytes.len) catch return error.ResetStream;
                    if (es.discarding and !es.reset) {
                        es.discard_left -|= bytes.len;
                        // The response is out (our half ended): past a
                        // window of discarded body the stream ends
                        // (RFC 9113 §8.1).
                        if (es.discard_left == 0 and !end_stream and s.state == .half_closed_local) {
                            es.reset = true;
                            conn.proto.reset(s, .no_error) catch return error.ResetStream;
                        }
                    }
                    if (end_stream) conn.closeBody(es);
                    return;
                }
                if (bytes.len > 0) {
                    if (es.body.buf.len == 0) {
                        const size = conn.bodySize(es, if (end_stream) bytes.len else null);
                        es.body_buf = BodyBuf.alloc(es, size) orelse return conn.resetBody(es, s, bytes.len);
                        es.body.buf = es.body_buf.mem;
                    }
                    // Cannot overflow: the ring holds the window, and Conn
                    // takes no DATA past it.
                    if (!es.body.put(bytes)) return conn.resetBody(es, s, bytes.len);
                    // Always: a handler between its look at the ring and
                    // its wait has not counted itself a sleeper yet, and
                    // only the epoch moving tells it (Signal's contract).
                    es.wake.notify(conn.io);
                    if (!es.raise_due and conn.mayRaise(es)) {
                        es.since_raise += bytes.len;
                        if (es.since_raise >= es.windowSize(conn)) es.raise_due = true;
                    }
                }
                if (end_stream) conn.bodyEnded(es);
            }

            pub fn onStreamClose(conn: *Conn, s: *PStream, code: conn_mod.ErrorCode) void {
                const es = EStream.of(s) orelse return;
                es.cs = null;
                s.user = null;
                if (code != .no_error or !es.ended) es.reset = true;
                if (es.reset and es.body.len > 0) {
                    // Never read: the connection's credit goes back.
                    conn.proto.consumed(null, es.body.len) catch {};
                    es.body.clear();
                }
                conn.closeBody(es);
                conn.wakeRoom(es);
                if (es.reset) es.cancelHandler();
                es.protocol_hold = false;
                // The response's bytes may still be borrowed by `out`.
                const mark = conn.proto.out.mark();
                if (conn.proto.out.sent_total < mark) {
                    es.out_hold = true;
                    es.retire_mark = mark;
                    conn.retiring.append(&es.retire_node);
                }
                conn.maybeFree(es);
            }

            pub fn onWindow(conn: *Conn, s: ?*PStream) void {
                // DATA is framed at `pending`: the reader's flush after the
                // read sends what the credit allows.
                _ = conn;
                _ = s;
            }

            pub fn onGoaway(conn: *Conn, last_id: u31, code: conn_mod.ErrorCode) void {
                _ = conn;
                log.debug("HTTP/2: GOAWAY from the peer, last stream {d}, {t}", .{ last_id, code });
            }

            pub fn onPingAck(conn: *Conn, data: [8]u8) void {
                // The answer to the drain notice's PING: everything the
                // peer sent before it saw the notice is in.
                if (std.mem.eql(u8, &data, &drain_ping)) conn.finishDrain();
            }

            // -- Dispatch -------------------------------------------------

            /// Whether the request's route was registered `no_wait`. An
            /// extended CONNECT never is.
            fn noWaitRoute(conn: *Conn, es: *EStream) bool {
                const method = parseMethod(es.method) orelse return false;
                if (method == .connect) return false;
                return conn.server.router.noWait(method, es.path);
            }

            /// Under the lock.
            fn queueInline(conn: *Conn, es: *EStream) void {
                conn.ready.append(conn.allocator, es) catch return conn.spawnTasked(es);
                es.inline_mode = true;
            }

            /// The request body is whole (DATA or trailers with END_STREAM):
            /// a `no_wait` request set aside for it runs inline after all.
            /// Under the lock.
            fn bodyEnded(conn: *Conn, es: *EStream) void {
                conn.closeBody(es);
                if (!es.await_body or es.reset) return;
                es.await_body = false;
                conn.queueInline(es);
            }

            fn closeBody(conn: *Conn, es: *EStream) void {
                es.body_done = true;
                es.wake.notify(conn.io);
            }

            /// A task for the stream's handler; at the task cap the stream
            /// is refused (REFUSED_STREAM, safe for the client to retry; RFC
            /// 9113 §8.7). Under the lock.
            fn spawnTasked(conn: *Conn, es: *EStream) void {
                if (!es.counted) {
                    conn.holdBusy();
                    es.counted = true;
                }
                es.handler_hold = true;
                const slot = if (conn.task_row) |r| conn.server.admission.reserveTask(r, .stream) else true;
                const spawned = if (!slot) error.TaskCap else placement.concurrent(conn.group, conn.io, .local, runStream, .{ conn, es });
                spawned catch |err| {
                    if (slot) if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                    if (err == error.TaskCap)
                        log.debug("HTTP/2: stream {d} refused at the task cap", .{es.id})
                    else
                        log.err("HTTP/2: no task for stream {d}", .{es.id});
                    es.reset = true;
                    conn.closeBody(es);
                    if (es.cs) |s| conn.proto.reset(s, .refused_stream) catch {};
                    es.handler_hold = false;
                    conn.maybeFree(es);
                    return;
                };
                if (comptime is_test) _ = test_spawned.fetchAdd(1, .monotonic);
            }

            /// After a read: the `no_wait` requests whose body did not end
            /// in it get a task, so a body is never held back waiting for a
            /// handler that is not reading it. Under the lock.
            fn startAwaiting(conn: *Conn) void {
                defer conn.awaiting.clearRetainingCapacity();
                for (conn.awaiting.items) |es| {
                    if (!es.await_body) continue;
                    es.await_body = false;
                    if (es.reset) {
                        es.handler_hold = false;
                        conn.maybeFree(es);
                        continue;
                    }
                    conn.spawnTasked(es);
                }
            }

            /// The handler let go of the stream. A body still coming is
            /// read and dropped from now on (`startDiscard`). Under the
            /// lock.
            fn finishHandler(conn: *Conn, es: *EStream) void {
                es.handler_hold = false;
                if (es.cs) |s| {
                    // A handler that returned without ending its response
                    // (it never does: `serveStream` writes it) would leave
                    // the peer waiting.
                    if (!es.ended and !es.reset) {
                        es.reset = true;
                        conn.proto.reset(s, .internal_error) catch {};
                    } else if (!es.body_done and !es.reset) conn.startDiscard(es, s);
                }
                conn.maybeFree(es);
            }

            /// Like the core's HTTP/1.x drain: a window more of the body is
            /// read and dropped, so a peer still sending a small one sees a
            /// clean end; then RST_STREAM(NO_ERROR) (`onData`).
            fn startDiscard(conn: *Conn, es: *EStream, s: *PStream) void {
                es.discarding = true;
                es.discard_left = es.windowSize(conn);
                if (es.body.len > 0) {
                    conn.proto.consumed(s, es.body.len) catch {};
                    es.body.clear();
                }
            }

            /// Frees `es` once nothing holds it: back to the spares with its
            /// arena trimmed, or to the allocator. Under the lock.
            fn maybeFree(conn: *Conn, es: *EStream) void {
                if (es.protocol_hold or es.handler_hold or es.out_hold) return;
                if (es.room_waiting) {
                    conn.room_waiters.remove(&es.room_node);
                    es.room_waiting = false;
                }
                if (es.body.len > 0 and !conn.closing) conn.proto.consumed(null, es.body.len) catch {};
                conn.live.remove(&es.node);
                gauges.add(conn.io, .h2_streams, -1);
                conn.raised_bytes -= es.raised_bytes;
                if (es.counted) {
                    conn.open_streams -= 1;
                    conn.releaseBusyIfIdle();
                }
                es.releaseMemory(conn.allocator);
                if (conn.spares.items.len < conn.max_spares) {
                    _ = safety.resetArena(&es.arena, .{ .retain_with_limit = arena_retain_limit });
                    if (conn.spares.append(conn.allocator, es)) |_| return else |_| {}
                }
                es.destroy(conn.allocator);
            }

            /// The body does not fit its buffer (impossible by its sizing,
            /// but defended) or no buffer could be had: only this stream is
            /// reset, and the credit of what it held goes back. Under the
            /// lock, inside `onData`.
            fn resetBody(conn: *Conn, es: *EStream, s: *PStream, dropped: usize) conn_mod.Error!void {
                es.reset = true;
                conn.proto.consumed(null, dropped + es.body.len) catch return error.ResetStream;
                es.body.clear();
                conn.closeBody(es);
                es.cancelHandler();
                conn.proto.reset(s, .internal_error) catch return error.ResetStream;
            }

            // -- Request bodies (the nghttp2 engine's M0 sizing, ported) --

            /// The body buffer, on the first DATA: the body when its length
            /// is known (content-length, or the frame that ends it, when it
            /// is the first) and within the window, else a whole window.
            fn bodySize(conn: *Conn, es: *const EStream, end_len: ?usize) usize {
                const full: usize = @max(es.windowSize(conn), conn.proto.local.initial_window);
                if (es.content_length) |n| if (n <= full) return @intCast(n);
                if (end_len) |n| return @min(n, full);
                return full;
            }

            fn mayRaise(conn: *Conn, es: *const EStream) bool {
                if (es.protocol.len > 0) return false;
                const current = es.windowSize(conn);
                if (current >= conn.config.stream_window_reading) return false;
                if (es.content_length) |n| if (n <= current) return false;
                return true;
            }

            /// The handler reads and the peer sent a whole window since the
            /// last raise: the window grows a step (x4, up to
            /// `stream_window_reading` and the content-length), and the
            /// body buffer with it, within the connection's
            /// `reading_window_budget` (the nghttp2 engine's `raiseWindow`,
            /// #99). Under the lock.
            fn raiseWindow(conn: *Conn, es: *EStream) void {
                es.raise_due = false;
                const s = es.cs orelse return;
                if (es.body_done or es.reset or es.discarding or !conn.mayRaise(es)) return;
                const current = es.windowSize(conn);
                var next: u31 = @intCast(@min(@as(usize, conn.config.stream_window_reading), @as(usize, current) * 4));
                if (es.content_length) |n| next = @intCast(@min(next, n));
                if (next <= current) return;
                const size: usize = @max(next, conn.proto.local.initial_window);
                const cost = BodyBuf.footprint(size);
                if (cost -| es.raised_bytes > conn.config.reading_window_budget -| conn.raised_bytes) return;
                var buf = BodyBuf.alloc(es, size) orelse return;
                conn.proto.raiseWindow(s, next - current) catch {
                    buf.free(conn.allocator);
                    return;
                };
                const moved = es.body.moveTo(buf.mem);
                es.body_buf.free(conn.allocator);
                es.body_buf = buf;
                es.window = next;
                es.since_raise = moved;
                conn.raised_bytes = conn.raised_bytes - es.raised_bytes + cost;
                es.raised_bytes = cost;
            }

            // -- The drain's flags ----------------------------------------

            /// What the drain asked for since the reader last looked. The
            /// reader, under the lock.
            fn applyDrain(conn: *Conn) void {
                const req = conn.drain_req.load(.acquire);
                if (req >= drain_notice_req and !conn.drain_notice and !conn.goaway_sent) {
                    conn.drain_notice = true;
                    conn.proto.shutdownNotice() catch {};
                    conn.proto.ping(drain_ping) catch {};
                }
                if (req >= drain_final_req) conn.finishDrain();
            }

            fn finishDrain(conn: *Conn) void {
                if (conn.goaway_sent) return;
                conn.goaway_sent = true;
                conn.proto.goaway(.no_error, "") catch {};
            }

            // -- Output: the flush token ----------------------------------

            /// Takes the flush token, unless another task has it (and will
            /// see what was queued: it looks again before letting go) or
            /// nothing more is written.
            fn takeToken(conn: *Conn) bool {
                conn.lock();
                defer conn.unlock();
                if (conn.flushing or conn.send_shut) return false;
                conn.flushing = true;
                return true;
            }

            const FlushMode = enum {
                /// One batch, the rest to the flusher: the reader, which
                /// must get back to reading, and a stream task.
                batch,
                /// Until nothing is left: the flusher, and the teardown.
                all,
            };

            /// Writes what is queued if no other task is writing it.
            /// `error.Canceled` only when the caller itself was canceled
            /// in a write (the connection is then shut).
            fn flush(conn: *Conn, mode: FlushMode) std.Io.Cancelable!void {
                if (!conn.takeToken()) return;
                return conn.writeOut(mode);
            }

            /// Hands what is queued to the flusher task, for a caller that
            /// must not write itself (a handler mid-response, which its
            /// stream's reset may cancel).
            fn kickFlush(conn: *Conn) void {
                if (!conn.takeToken()) return;
                if (conn.spawnFlusher()) return;
                conn.lock();
                conn.flushing = false;
                conn.unlock();
            }

            fn spawnFlusher(conn: *Conn) bool {
                if (conn.task_row) |r| _ = conn.server.admission.reserveTask(r, .forced);
                placement.concurrent(conn.group, conn.io, .local, flusherRun, .{conn}) catch {
                    if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                    log.err("HTTP/2: no task for the connection's output", .{});
                    return false;
                };
                if (comptime is_test) _ = test_flushers.fetchAdd(1, .monotonic);
                return true;
            }

            fn flusherRun(conn: *Conn) std.Io.Cancelable!void {
                defer if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                return conn.writeOut(.all);
            }

            /// With the token: `pending` written into the connection's
            /// buffered writer and `advance`d, round after round, then one
            /// flush, until nothing is left (looked at under the lock, where
            /// the token is let go, so nothing queued meanwhile is
            /// stranded). In `batch` mode, past one write buffer's worth the
            /// rest goes to the flusher (with the token, the write buffer and
            /// what it holds). `advance` right after a round is safe: what
            /// `writeVecAll` returned from is copied or sent. The write
            /// buffer is the pool's only while the token is held.
            fn writeOut(conn: *Conn, mode: FlushMode) std.Io.Cancelable!void {
                var vecs: [max_vecs][]const u8 = undefined;
                // A peer that stops reading must not hold the connection,
                // and with it every stream, for good (until the sweeper):
                // armed again every write buffer's worth.
                var timer: Timer = .init(null);
                defer timer.clear(conn.io);
                const step = @max(1, conn.server.config.response.write_buffer_size);
                var since_arm: ?usize = null;
                var written: usize = 0;
                while (true) {
                    const got: []const []const u8 = got: {
                        conn.lock();
                        defer conn.unlock();
                        const got = if (conn.send_shut) &.{} else conn.proto.pending(&vecs) catch |err| switch (err) {
                            // Whole frames stay queued, but the connection
                            // can't go on.
                            error.OutOfMemory => break :got null,
                        };
                        if (got.len > 0) {
                            if (mode == .batch and written >= step and conn.spawnFlusher()) return;
                            break :got got;
                        }
                        if (conn.unflushed and !conn.send_shut) break :got got;
                        conn.connection.releaseWriteBuffer();
                        conn.unflushed = false;
                        conn.flushing = false;
                        return;
                    } orelse {
                        conn.writeFailed();
                        return;
                    };
                    if (since_arm == null or since_arm.? >= step) {
                        if (conn.server.config.timeout.write) |d| timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
                        since_arm = 0;
                    }
                    if (got.len == 0) {
                        conn.flushWriter(&timer) catch |err| {
                            conn.writeFailed();
                            if (err == error.Canceled) return error.Canceled;
                            return;
                        };
                        conn.unflushed = false;
                        continue;
                    }
                    conn.connection.prepareWrite();
                    var total: usize = 0;
                    for (got) |b| total += b.len;
                    conn.writeVecs(vecs[0..got.len], &timer) catch |err| {
                        conn.writeFailed();
                        if (err == error.Canceled) return error.Canceled;
                        return;
                    };
                    conn.unflushed = true;
                    written += total;
                    since_arm.? += total;
                    conn.lock();
                    defer conn.unlock();
                    conn.proto.advance(total);
                    conn.retire();
                    conn.wakeRooms();
                }
            }

            /// `vecs` into the connection's writer (a syscall only when its
            /// buffer fills). error.WriteFailed for a failure of the
            /// connection, error.Canceled when the calling task was.
            fn writeVecs(conn: *Conn, vecs: [][]const u8, timer: *Timer) (std.Io.Cancelable || error{WriteFailed})!void {
                if (comptime is_test) {
                    const in = test_writers_in.fetchAdd(1, .acq_rel) + 1;
                    _ = test_max_writers.fetchMax(in, .acq_rel);
                }
                defer if (comptime is_test) {
                    _ = test_writers_in.fetchSub(1, .acq_rel);
                };
                conn.connection.writer.writeVecAll(vecs) catch return conn.writeError(timer);
            }

            fn flushWriter(conn: *Conn, timer: *Timer) (std.Io.Cancelable || error{WriteFailed})!void {
                conn.connection.writer.flush() catch return conn.writeError(timer);
            }

            fn writeError(conn: *Conn, timer: *Timer) (std.Io.Cancelable || error{WriteFailed}) {
                const cause = conn.connection.getWriteError() orelse return error.WriteFailed;
                if (cause == error.Canceled and !timer.fired()) return error.Canceled;
                if (!Connection.isPeerGone(cause)) log.info("HTTP/2 write error: {}", .{cause});
                return error.WriteFailed;
            }

            /// Nothing more can go out: both directions are shut, so the
            /// reader stops too, the streams waiting for room are told, and
            /// the token goes (nobody takes it again).
            fn writeFailed(conn: *Conn) void {
                conn.connection.stream.shutdown(conn.io, .both) catch {};
                conn.lock();
                defer conn.unlock();
                conn.send_shut = true;
                conn.flushing = false;
                conn.unflushed = false;
                conn.connection.releaseWriteBuffer();
                while (conn.room_waiters.popFirst()) |node| {
                    const es: *EStream = @fieldParentPtr("room_node", node);
                    es.room_waiting = false;
                    es.room.notify(conn.io);
                }
            }

            /// The closed streams whose marks `out` has passed are let go.
            /// Under the lock.
            fn retire(conn: *Conn) void {
                const sent = conn.proto.out.sent_total;
                while (conn.retiring.first) |node| {
                    const es: *EStream = @fieldParentPtr("retire_node", node);
                    if (es.retire_mark > sent) break;
                    _ = conn.retiring.popFirst();
                    es.out_hold = false;
                    if (comptime is_test) _ = test_retired.fetchAdd(1, .monotonic);
                    conn.maybeFree(es);
                }
            }

            /// Wakes the streams whose block is now free. Under the lock.
            fn wakeRooms(conn: *Conn) void {
                var it = conn.room_waiters.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("room_node", node);
                    if (!conn.roomFree(es)) continue;
                    conn.room_waiters.remove(node);
                    es.room_waiting = false;
                    es.room.notify(conn.io);
                }
            }

            fn wakeRoom(conn: *Conn, es: *EStream) void {
                if (es.room_waiting) {
                    conn.room_waiters.remove(&es.room_node);
                    es.room_waiting = false;
                }
                es.room.notify(conn.io);
            }

            /// Whether the block the writer wants next (`es.cur`) is free:
            /// never submitted, or framed (the stream's queue no longer
            /// holds it: blocks go in order, the other one after it) and
            /// written (`out.sent_total` past a mark taken once it was
            /// framed). True as well when the stream or the connection is
            /// gone (a connection error frames no more DATA), for the
            /// waiter to find out. Under the lock.
            fn roomFree(conn: *Conn, es: *EStream) bool {
                const b = &es.blocks[es.cur];
                if (!b.inflight) return true;
                const s = es.cs orelse return true;
                if (es.reset or conn.send_shut or conn.proto.dead) return true;
                if (b.mark == null) {
                    var queued: usize = 0;
                    var it = s.pending.first;
                    while (it) |n| : (it = n.next) queued += 1;
                    const after: usize = if (es.blocks[es.cur ^ 1].inflight) 1 else 0;
                    if (queued > after) return false;
                    b.mark = conn.proto.out.mark();
                }
                if (conn.proto.out.sent_total < b.mark.?) return false;
                b.inflight = false;
                b.mark = null;
                return true;
            }
        };

        /// A request body buffer: up to `arena_body_max` from the stream's
        /// arena, up to `block_cache.malloc_max` from the allocator
        /// (malloc's slabs), larger from `block_cache` (the nghttp2
        /// engine's `BodyBuf`).
        const BodyBuf = struct {
            mem: []u8 = &.{},
            from: enum { none, arena, heap, block } = .none,

            fn blockFor(size: usize) ?usize {
                if (size <= block_cache.malloc_max) return null;
                return block_cache.classFor(size);
            }

            fn footprint(size: usize) usize {
                return blockFor(size) orelse size;
            }

            fn alloc(es: *EStream, size: usize) ?BodyBuf {
                return if (size <= arena_body_max)
                    .{ .mem = es.arena.allocator().alloc(u8, size) catch return null, .from = .arena }
                else if (blockFor(size)) |class|
                    .{ .mem = block_cache.take(class) orelse return null, .from = .block }
                else
                    .{ .mem = es.conn.allocator.alloc(u8, size) catch return null, .from = .heap };
            }

            fn free(buf: *BodyBuf, gpa: std.mem.Allocator) void {
                switch (buf.from) {
                    .none, .arena => {},
                    .heap => gpa.free(buf.mem),
                    .block => block_cache.give(buf.mem),
                }
                buf.* = .{};
            }
        };

        /// A byte ring: the request body between the reader and the
        /// handler, under the lock.
        const Ring = struct {
            buf: []u8 = &.{},
            head: usize = 0,
            len: usize = 0,

            fn put(r: *Ring, bytes: []const u8) bool {
                if (bytes.len > r.buf.len - r.len) return false;
                var at = (r.head + r.len) % r.buf.len;
                var rest = bytes;
                while (rest.len > 0) {
                    const n = @min(rest.len, r.buf.len - at);
                    @memcpy(r.buf[at..][0..n], rest[0..n]);
                    rest = rest[n..];
                    at = 0;
                }
                r.len += bytes.len;
                return true;
            }

            fn take(r: *Ring, dest: []u8) usize {
                var n: usize = 0;
                while (n < dest.len and r.len > 0) {
                    const k = @min(dest.len - n, r.len, r.buf.len - r.head);
                    @memcpy(dest[n..][0..k], r.buf[r.head..][0..k]);
                    n += k;
                    r.len -= k;
                    r.head = (r.head + k) % r.buf.len;
                }
                if (r.len == 0) r.head = 0;
                return n;
            }

            /// Into `buf` (at least `len` bytes), which becomes the ring.
            fn moveTo(r: *Ring, buf: []u8) usize {
                const n = r.len;
                _ = r.take(buf[0..n]);
                r.* = .{ .buf = buf, .len = n };
                return n;
            }

            fn clear(r: *Ring) void {
                r.head = 0;
                r.len = 0;
            }
        };

        /// One block of a streamed response.
        const Block = struct {
            mem: []u8 = &.{},
            /// Submitted, and maybe still borrowed by `out`.
            inflight: bool = false,
            /// `out.mark()` once framed (`Conn.roomFree`).
            mark: ?u64 = null,
        };

        /// The engine's side of a stream (`conn.Stream.user`). Freed (to
        /// the spares) once nothing holds it: the protocol stream, the
        /// handler, and `out`'s borrowed bytes after the close.
        const EStream = struct {
            conn: *Conn,
            arena: std.heap.ArenaAllocator,
            node: std.DoublyLinkedList.Node = .{},
            /// The protocol stream; null once it closed.
            cs: ?*PStream = null,
            id: u31 = 0,

            protocol_hold: bool = false,
            handler_hold: bool = false,
            out_hold: bool = false,
            retire_node: std.DoublyLinkedList.Node = .{},
            retire_mark: u64 = 0,
            /// Counted in `Conn.open_streams` (a handler was started).
            counted: bool = false,

            // The request head.
            method: []const u8 = "",
            path: []const u8 = "",
            authority: []const u8 = "",
            scheme: []const u8 = "",
            protocol: []const u8 = "",
            headers: std.ArrayList(Field) = .empty,
            content_length: ?u64 = null,

            // The request body.
            body: Ring = .{},
            body_buf: BodyBuf = .{},
            body_done: bool = false,
            /// Reset (by either side), or the connection is gone.
            reset: bool = false,
            /// The handler is done and the response out: the rest of the
            /// body is dropped.
            discarding: bool = false,
            discard_left: usize = 0,
            /// The handler waits on it for body bytes or the end.
            wake: Signal = .{},
            /// The receive window the body buffer holds; 0 for
            /// `stream_window`.
            window: u31 = 0,
            raise_due: bool = false,
            since_raise: usize = 0,
            raised_bytes: usize = 0,

            // Dispatch.
            inline_mode: bool = false,
            await_body: bool = false,
            /// The handler's task, for `cancelHandler`; set and cleared by
            /// the task under the lock.
            task: ?placement.Task = null,
            /// `cancelHandler` canceled it.
            canceled: bool = false,

            // The response.
            /// Its last frame is submitted.
            ended: bool = false,
            head_sent: bool = false,
            status: http.Status = .ok,
            resp_fields: []hpack.Field = &.{},
            /// A streamed body's blocks: the writer fills `blocks[cur]`.
            blocks: [2]Block = .{ .{}, .{} },
            cur: u1 = 0,
            /// An inline stream's submitted blocks, which it never waits
            /// for (the reader can't): freed with the stream.
            spent: std.ArrayList([]u8) = .empty,
            room: Signal = .{},
            room_node: std.DoublyLinkedList.Node = .{},
            room_waiting: bool = false,

            fn of(s: *PStream) ?*EStream {
                // SAFETY: `user` is only ever set to an EStream (`onStreamOpen`).
                return @ptrCast(@alignCast(s.user orelse return null));
            }

            fn windowSize(es: *const EStream, conn: *const Conn) u31 {
                return if (es.window != 0) es.window else conn.config.stream_window;
            }

            /// A spare (its arena trimmed when it was freed), or a new one.
            /// Under the lock.
            fn create(conn: *Conn) !*EStream {
                if (conn.spares.pop()) |es| {
                    conn.spare_low = @min(conn.spare_low, conn.spares.items.len);
                    const arena = es.arena;
                    es.* = .{ .conn = conn, .arena = arena };
                    return es;
                }
                const es = try conn.allocator.create(EStream);
                es.* = .{ .conn = conn, .arena = .init(conn.allocator) };
                // The node every reset keeps, so the first reset does not
                // reallocate it.
                if (es.arena.allocator().alloc(u8, arena_retain_limit)) |_| {
                    _ = safety.resetArena(&es.arena, .{ .retain_with_limit = arena_retain_limit });
                } else |_| {}
                return es;
            }

            fn destroy(es: *EStream, gpa: std.mem.Allocator) void {
                es.arena.deinit();
                gpa.destroy(es);
            }

            /// What is not in the arena.
            fn releaseMemory(es: *EStream, gpa: std.mem.Allocator) void {
                es.body_buf.free(gpa);
                es.body = .{};
                for (&es.blocks) |*b| {
                    if (b.mem.len > 0) gpa.free(b.mem);
                    b.* = .{};
                }
                for (es.spent.items) |m| gpa.free(m);
                es.spent = .empty;
            }

            /// The stream is gone before the handler ended its response:
            /// cancel the handler, so a wait it is in returns
            /// error.Canceled. Under the lock, which the task takes to
            /// clear `task` before it ends.
            fn cancelHandler(es: *EStream) void {
                if (es.ended or !es.handler_hold) return;
                if (es.task) |task| {
                    es.canceled = true;
                    placement.cancelTask(task);
                }
            }
        };

        /// Runs HTTP/2 over an initialized connection. The calling task is
        /// the reader; the streams and the flusher run in a group torn
        /// down before this returns. `busy` is the connection's count in
        /// the server's in-flight requests, given back here: from now on
        /// it counts while streams are open.
        pub fn serve(server: *Server, listener: *const Listener, secure: bool, connection: *Connection, busy: *bool) !void {
            if (busy.*) {
                busy.* = false;
                server.finishRequest();
            }
            const io = server.io;
            // SAFETY: the connection's address only picks a pool shard.
            const buffers = try server.request_buffers.acquire(@intFromPtr(connection));
            defer server.request_buffers.release(buffers);
            // Conn takes a frame other than DATA only once it is whole.
            if (buffers.read_buffer.len < 9 + 16384) {
                log.err("HTTP/2 needs a read buffer of at least 16393 bytes: request.buffer_size is {d}", .{server.config.request.buffer_size});
                return error.Http2ReadBufferTooSmall;
            }
            connection.useReadBuffer(buffers.read_buffer);

            var group: std.Io.Group = .init;
            const h = server.config.http2;
            var conn: Conn = .{
                .server = server,
                .connection = connection,
                .listener = listener,
                .secure = secure or connection.proxied_secure,
                .io = io,
                .allocator = server.allocator,
                .config = h,
                .group = &group,
                .max_spares = @max(1, @min(max_spare_streams, h.max_concurrent_streams)),
                .inline_ok = h.inline_no_wait and server.router.has_no_wait,
                .task_row = server.admission.currentRow(io),
            };
            conn.spare_epoch = conn.trimEpoch();
            if (placement.single_executor_guarantee) if (placement.currentExecutor(io)) |e| {
                conn.lock_.free = true;
                conn.lock_.owner = e;
            };
            if (comptime is_test) test_lock_free.store(conn.lock_.free, .monotonic);
            var opts: conn_mod.Options = .{
                .max_concurrent_streams = h.max_concurrent_streams,
                .initial_window = h.stream_window,
                .connection_window = h.connection_window,
                .max_header_list_size = h.max_header_list_size,
                .max_header_count = server.config.request.max_header_count,
                .max_continuations = std.math.cast(u32, h.max_continuations) orelse std.math.maxInt(u32),
                .enable_connect_protocol = h.enable_connect_protocol,
                .stream_reset_burst = h.stream_reset_burst,
                .stream_reset_rate = h.stream_reset_rate,
                .refused_stream_burst = h.refused_stream_burst,
                .refused_stream_rate = h.refused_stream_rate,
            };
            // The stream table's hash seed (hash flooding).
            io.random(std.mem.asBytes(&opts.seed));
            if (comptime is_test) if (test_out_high) |v| {
                opts.limits.out_high = v;
            };
            conn.proto = try Proto.init(server.allocator, &conn, opts);
            defer {
                // The tasks are joined: nothing else touches the streams.
                conn.closing = true;
                while (conn.live.popFirst()) |node| {
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (es.cs) |s| s.user = null;
                    gauges.add(io, .h2_streams, -1);
                    es.releaseMemory(conn.allocator);
                    es.destroy(conn.allocator);
                }
                conn.open_streams = 0;
                conn.releaseBusyIfIdle();
                for (conn.spares.items) |es| es.destroy(conn.allocator);
                conn.spares.deinit(conn.allocator);
                conn.ready.deinit(conn.allocator);
                conn.awaiting.deinit(conn.allocator);
                if (conn.own_scratch.len > 0) conn.allocator.free(conn.own_scratch);
                conn.proto.deinit();
            }
            // Until the server switches to this engine, its registry is the
            // nghttp2 engine's.
            const registered = comptime @TypeOf(server.h2_conns) == Registry;
            if (registered) server.h2_conns.add(&conn);
            defer if (registered) server.h2_conns.remove(&conn);
            defer group.cancel(io);

            var reader_failed = false;
            var linger = false;
            if (readerLoop(&conn)) |end| {
                linger = end != .eof;
                // A connection error frames no more DATA: no response can
                // finish (the nghttp2 engine's Http2ProtocolError).
                reader_failed = end == .dead;
            } else |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    reader_failed = true;
                    if (Connection.isPeerGone(err)) {
                        log.debug("HTTP/2 connection closed by peer: {}", .{err});
                    } else {
                        linger = true;
                        log.info("HTTP/2 connection error: {}", .{err});
                    }
                },
            }

            // No more request body can arrive: a handler still waiting for
            // one is told the stream is gone and canceled. After a clean
            // end of the peer's side (maybe a half-close) a handler with
            // its whole request keeps running, for a response that may
            // still go out; after a read or protocol error every one is
            // canceled.
            {
                conn.lock();
                defer conn.unlock();
                conn.closing = true;
                var it = conn.live.first;
                while (it) |node| : (it = node.next) {
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (reader_failed or !es.body_done) {
                        es.reset = true;
                        conn.closeBody(es);
                        conn.wakeRoom(es);
                        es.cancelHandler();
                    }
                }
            }
            conn.flush(.all) catch return error.Canceled;
            group.await(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            conn.flush(.all) catch return error.Canceled;
            if (linger) try lingeringClose(&conn);
        }

        /// How the reader ended: the peer ended its side (`eof`), the
        /// connection is over with the peer's side still open (`done`: a
        /// failed write), or a connection error's GOAWAY went out
        /// (`dead`).
        const ReaderEnd = enum { eof, done, dead };

        /// Reads the connection and feeds `Conn.recv` until the peer is
        /// done or the connection is. Holds the keepalive deadline while no
        /// stream is open.
        fn readerLoop(conn: *Conn) !ReaderEnd {
            const reader = conn.connection.reader;
            var timer: Timer = .init(null);
            defer timer.clear(conn.io);
            while (true) {
                const buffered = reader.buffered();
                if (buffered.len > 0) {
                    timer.clear(conn.io);
                    const result = result: {
                        conn.lock();
                        defer conn.unlock();
                        if (conn.send_shut) return .done;
                        const scratch = try conn.scratch();
                        const now = placement.tickNow(conn.io) orelse std.Io.Clock.awake.now(conn.io);
                        const result = conn.proto.recv(buffered, @intCast(@max(0, now.toSeconds())), scratch);
                        if (comptime is_test) _ = test_reads.fetchAdd(1, .monotonic);
                        if (result) |_| {
                            conn.applyDrain();
                            if (conn.awaiting.items.len > 0) conn.startAwaiting();
                        } else |_| {}
                        break :result result;
                    };
                    const taken = result catch |err| switch (err) {
                        // A GOAWAY is queued: out it goes, then the
                        // lingering close.
                        error.ConnectionError => {
                            try conn.flush(.all);
                            return .dead;
                        },
                        error.BadPreface => return error.Http2BadPreface,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    reader.toss(taken);
                    if (conn.ready.items.len > 0) try runInline(conn);
                    try conn.flush(.batch);
                    if (conn.send_shut) return .done;
                    // What is left, if anything, is a frame not yet whole.
                }

                const idle = idle: {
                    conn.lock();
                    defer conn.unlock();
                    conn.trimIdle();
                    break :idle conn.open_streams == 0;
                };
                if (idle) {
                    if (conn.server.config.timeout.keepalive) |d| timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
                } else timer.clear(conn.io);
                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return .eof,
                    error.ReadFailed => return conn.connection.getReadError() orelse error.Unexpected,
                };
            }
        }

        /// Hangs up on a peer whose side is still open once the connection
        /// is over, so it still gets the last frames (the nghttp2 engine's
        /// `lingeringClose`): close_notify under TLS and the send side
        /// shut, then what the peer sends is thrown away until it hangs up,
        /// `linger_timeout` passes, or `linger_limit` bytes. The tasks have
        /// ended: this is the only reader and writer.
        fn lingeringClose(conn: *Conn) std.Io.Cancelable!void {
            var timer: Timer = .init(null);
            if (!timer.canBound()) return;
            if (!conn.send_shut) {
                {
                    var t: Timer = .init(null);
                    t.set(conn.io, .{ .duration = .{ .raw = server_mod.linger_timeout, .clock = .awake } });
                    defer t.clear(conn.io);
                    conn.connection.closeNotify() catch |err| {
                        conn.connection.stream.shutdown(conn.io, .both) catch {};
                        return err;
                    };
                }
                conn.connection.stream.shutdown(conn.io, .send) catch |err| switch (err) {
                    error.SocketUnconnected, error.ConnectionResetByPeer, error.ConnectionAborted => return,
                    error.Canceled => return error.Canceled,
                    else => {},
                };
            }
            timer.set(conn.io, .{ .duration = .{ .raw = server_mod.linger_timeout, .clock = .awake } });
            defer timer.clear(conn.io);
            _ = conn.connection.reader.discardShort(server_mod.linger_limit) catch {
                if (conn.connection.getReadError()) |cause| if (cause == error.Canceled) return error.Canceled;
            };
        }

        // -- One stream: a request in, a response out --------------------

        fn runStream(conn: *Conn, es: *EStream) std.Io.Cancelable!void {
            defer if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
            const gone = gone: {
                conn.lock();
                defer conn.unlock();
                es.task = placement.currentTask(conn.io);
                break :gone es.reset;
            };
            var timer: Timer = .init(null);
            var canceled = false;
            defer {
                const timed_out = timer.fired();
                timer.clear(conn.io);
                conn.lock();
                es.task = null;
                // A cancel that reached this task (its stream's reset, its
                // request timer) may still be pending: the write is the
                // flusher's then.
                const kick = es.canceled or timed_out or canceled;
                conn.finishHandler(es);
                conn.unlock();
                if (kick) conn.kickFlush() else conn.flush(.batch) catch conn.kickFlush();
            }
            if (gone) {
                log.debug("HTTP/2 stream {d} reset before its handler started", .{es.id});
                return;
            }
            if (conn.server.config.timeout.request) |d| timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
            serveStream(conn, es, &timer) catch |err| streamFailed(conn, es, err) catch {
                canceled = true;
                return error.Canceled;
            };
        }

        /// Runs the requests set aside for the reader (`no_wait` routes),
        /// in the order they arrived.
        fn runInline(conn: *Conn) error{Canceled}!void {
            defer conn.ready.clearRetainingCapacity();
            for (conn.ready.items) |es| {
                conn.lock();
                const gone = es.reset;
                conn.unlock();
                var canceled = false;
                if (!gone) serveStream(conn, es, null) catch |err| streamFailed(conn, es, err) catch {
                    canceled = true;
                };
                conn.lock();
                conn.finishHandler(es);
                conn.unlock();
                // The reader itself is canceled: the connection is going.
                if (canceled) return error.Canceled;
            }
        }

        /// What a handler's error means for its stream. `error.Canceled`
        /// when the handler's own task was canceled for another reason
        /// than its stream's reset, to pass on.
        fn streamFailed(conn: *Conn, es: *EStream, err: anyerror) error{Canceled}!void {
            conn.lock();
            const reset = es.reset;
            conn.unlock();
            if (err == error.Canceled) {
                if (reset) {
                    log.debug("HTTP/2 stream {d}: handler canceled, the stream was reset", .{es.id});
                    return;
                }
                resetStream(conn, es, .cancel);
                return error.Canceled;
            }
            if (err == error.ResponseAborted) {
                log.debug("HTTP/2 stream {d}: response aborted", .{es.id});
                return resetStream(conn, es, .cancel);
            }
            if (reset or err == error.ConnectionResetByPeer) {
                log.debug("HTTP/2 stream {d} reset: {}", .{ es.id, err });
            } else {
                log.err("HTTP/2 stream {d}: {}", .{ es.id, err });
                resetStream(conn, es, .internal_error);
            }
        }

        fn resetStream(conn: *Conn, es: *EStream, code: conn_mod.ErrorCode) void {
            conn.lock();
            defer conn.unlock();
            if (es.reset) return;
            es.reset = true;
            if (es.cs) |s| conn.proto.reset(s, code) catch {};
        }

        const Exchange = struct {
            request: Request,
            response: Response,
            sink_state: StreamSink,
            body_reader: BodyReader,
        };

        /// Serves one request: on the reader (`timer` null, a `no_wait`
        /// route, no request timeout, whose timer would cancel the reader)
        /// or on its own task. The nghttp2 engine's `serveStream`, with
        /// the same request build, so the router, handlers and middleware
        /// see the same request.
        fn serveStream(conn: *Conn, es: *EStream, timer: ?*Timer) !void {
            const server = conn.server;
            const arena = es.arena.allocator();
            const io = conn.io;
            // SAFETY: each field is set below before it is read.
            var ex: Exchange = undefined;
            const request = &ex.request;
            request.* = .{
                .arena = arena,
                .io = io,
                // SAFETY: never read on HTTP/2: the body comes from `_body_source`.
                ._parser = undefined,
                // SAFETY: never read on HTTP/2: the body comes from `_body_source`.
                ._transport = undefined,
                ._config = server.config.request,
                .listener = conn.listener,
                .secure = conn.secure,
                .peer_certificate = conn.connection.peerCertificate(),
                .version_major = 2,
                .version_minor = 0,
                .drain = &server.draining,
                ._drain_hooks = &server.drain_hooks,
                ._timeout_context = if (timer) |t| t else null,
                ._set_timeout = if (timer != null) setTimeout else null,
                ._claim_timeout = if (timer != null) claimTimeout else null,
                // SAFETY: its entry table is never read past `len`: not zeroed.
                .session = undefined,
            };
            request.session._empty();
            const body_reader = &ex.body_reader;
            body_reader.* = .init(es);
            request._body_source = .{ .reader = &body_reader.interface, .err = BodyReader.errorOf };

            const sink_state = &ex.sink_state;
            sink_state.* = .{ .es = es };
            const response = &ex.response;
            response.* = try Response._initSink(arena, io, sink_state.sink(), server.config.response.max_header_count);
            server.configureResponse(response);
            defer response.deinit();
            response._request = request;
            request._response = response;

            request.method = parseMethod(es.method) orelse {
                response.status = .not_implemented;
                return response.write();
            };
            // An extended CONNECT (RFC 8441) is routed as the GET that the
            // HTTP/1.1 upgrade it replaces would be.
            if (request.method == .connect and es.protocol.len > 0) {
                request.method = .get;
                request.protocol = es.protocol;
            }
            response.head = request.method == .head;
            request.url = es.path;

            request.headers = http.Headers.init(arena, server.config.request.max_header_count) catch return error.OutOfMemory;
            var too_many = false;
            // Repeated fields stay separate entries, as over HTTP/1.1,
            // except cookie crumbs, joined into one (RFC 9113 §8.2.3).
            var hosts: usize = 0;
            var host_field: []const u8 = "";
            for (es.headers.items) |f| {
                if (std.mem.eql(u8, f.name, "host")) {
                    hosts += 1;
                    host_field = f.value;
                }
                request.headers.addRequestField(arena, f.name, f.value) catch |err| switch (err) {
                    error.TooManyHeaders => {
                        too_many = true;
                        break;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            // One host, from `:authority` when it is there (RFC 9113
            // §8.3.1): a `host` field naming another, or two of them, make
            // the request ambiguous.
            if (!too_many and (hosts > 1 or (hosts == 1 and es.authority.len > 0 and
                !std.ascii.eqlIgnoreCase(host_field, es.authority))))
            {
                response.status = .bad_request;
                return response.write();
            }
            if (!too_many and hosts == 0 and es.authority.len > 0) {
                request.headers.add("Host", es.authority) catch {
                    too_many = true;
                };
            }
            if (too_many) {
                response.status = .request_header_fields_too_large;
                return response.write();
            }
            request._applyEntityHeaders();
            // A body declared longer than allowed is refused unread.
            if (server.config.request.max_content_length) |max| {
                if (request.content_length) |len| if (len > max) {
                    response.status = .payload_too_large;
                    response.content_type = .text;
                    response.body = "413 Content Too Large\n";
                    return response.write();
                };
            }
            server.applyForwarded(request, conn.connection);
            server.applyRequestIdHeader(request);

            if (request.headers.get("Expect")) |expect| {
                if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                    conn.lock();
                    request._expects_continue = !es.body_done;
                    conn.unlock();
                } else {
                    response.status = .expectation_failed;
                    return response.write();
                }
            }

            log.debug("Received (h2 stream {d}): {f} {s}", .{ es.id, request.method, request.url });

            server.dispatch(request, response) catch |err| switch (err) {
                error.ReadFailed => return body_reader.err orelse error.Unexpected,
                error.WriteFailed => return sink_state.err orelse error.Unexpected,
                else => |e| return e,
            };
            try response.write();
        }

        fn setTimeout(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
            // SAFETY: the context is the Timer `serveStream` set it to.
            const timer: *Timer = @ptrCast(@alignCast(context));
            timer.set(io, timeout);
        }

        fn claimTimeout(context: *anyopaque) bool {
            // SAFETY: the context is the Timer `serveStream` set it to.
            const timer: *Timer = @ptrCast(@alignCast(context));
            return timer.fired();
        }

        fn parseMethod(name: []const u8) ?http.Method {
            var lower: [16]u8 = undefined;
            if (name.len == 0 or name.len > lower.len) return null;
            return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&lower, name));
        }

        /// The request body, from the stream's ring. Gives the window
        /// credit back for what the handler takes, so a stream's window is
        /// the handler's pace.
        const BodyReader = struct {
            es: *EStream,
            interface: std.Io.Reader,
            err: ?Transport.ReadError = null,

            fn init(es: *EStream) BodyReader {
                return .{ .es = es, .interface = .{
                    .vtable = &.{ .stream = streamFn },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                } };
            }

            fn errorOf(r: *std.Io.Reader) ?Transport.ReadError {
                // SAFETY: the reader is a BodyReader's `interface`.
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                return self.err;
            }

            fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                // SAFETY: the reader is a BodyReader's `interface`.
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                const es = self.es;
                const conn = es.conn;
                const dest = limit.slice(try w.writableSliceGreedy(1));
                if (dest.len == 0) return 0;
                while (true) {
                    const seen = es.wake.epoch();
                    conn.lock();
                    if (es.raise_due) conn.raiseWindow(es);
                    if (es.reset) {
                        conn.unlock();
                        return self.fail(error.ConnectionResetByPeer);
                    }
                    const n = es.body.take(dest);
                    if (n > 0) {
                        const before = conn.proto.out.mark();
                        conn.proto.consumed(es.cs, n) catch {};
                        // Credit that queued a WINDOW_UPDATE (about once a
                        // half window) is written; on the reader it goes
                        // with the read's output.
                        const queued = conn.proto.out.mark() != before and !es.inline_mode;
                        conn.unlock();
                        if (queued) conn.kickFlush();
                        w.advance(n);
                        return n;
                    }
                    if (es.body_done) {
                        conn.unlock();
                        return error.EndOfStream;
                    }
                    conn.unlock();
                    es.wake.wait(conn.io, seen) catch return self.fail(error.Canceled);
                }
            }

            fn fail(self: *BodyReader, err: Transport.ReadError) std.Io.Reader.StreamError {
                self.err = err;
                return error.ReadFailed;
            }
        };

        /// The response side of a stream, for `Response._initSink`.
        const StreamSink = struct {
            es: *EStream,
            writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flushFn }, .buffer = &.{} },
            err: ?Response.SendError = null,

            fn sink(self: *StreamSink) Sink {
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

            fn fromPtr(ptr: *anyopaque) *StreamSink {
                // SAFETY: the sink's ptr is the StreamSink (`sink`).
                return @ptrCast(@alignCast(ptr));
            }

            fn fail(self: *StreamSink, err: Response.SendError) std.Io.Writer.Error {
                self.err = err;
                return error.WriteFailed;
            }

            /// Whatever the submit refused: the stream is gone.
            fn submitFailed(self: *StreamSink, err: conn_mod.SubmitError) std.Io.Writer.Error {
                return self.fail(switch (err) {
                    error.OutOfMemory => error.SystemResources,
                    error.StreamClosed => error.ConnectionResetByPeer,
                    error.HeadersTooLarge => error.Unexpected,
                });
            }

            /// Output for the connection: a stream on the reader leaves it
            /// to the reader's write after the read; one on a task hands it
            /// to the flusher (the task may be canceled mid-write).
            fn kick(self: *StreamSink) void {
                if (!self.es.inline_mode) self.es.conn.kickFlush();
            }

            /// A whole response in memory: the head and the body submitted
            /// together, with the body borrowed where it lies (the parts
            /// list copied to the arena). The stream ends on the last DATA
            /// frame, on the trailers, or on HEADERS when there is neither.
            /// Written when the handler is done (`runStream`) or after the
            /// reader's batch.
            fn complete(
                ptr: *anyopaque,
                status: http.Status,
                headers: *const http.Headers,
                content_length: ?usize,
                parts: []const []const u8,
                trailers: ?*const http.Headers,
            ) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const es = self.es;
                const conn = es.conn;
                const arena = es.arena.allocator();
                try head(ptr, status, headers, content_length);
                const trailer_fields = try self.trailerFields(trailers);
                var kept: usize = 0;
                for (parts) |part| {
                    if (part.len > 0) kept += 1;
                }
                const list = arena.alloc([]const u8, kept) catch return self.fail(error.SystemResources);
                kept = 0;
                for (parts) |part| {
                    if (part.len == 0) continue;
                    list[kept] = part;
                    kept += 1;
                }
                conn.lock();
                defer conn.unlock();
                const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                if (es.reset) return self.fail(error.ConnectionResetByPeer);
                const bare = list.len == 0 and trailer_fields == null;
                // Before the submit: an END_STREAM on a stream whose peer
                // half is closed closes it inside the call, and
                // `onStreamClose` must see a normal end, not a reset.
                es.head_sent = true;
                es.ended = true;
                conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, bare) catch |err| {
                    es.head_sent = false;
                    es.ended = false;
                    return self.submitFailed(err);
                };
                if (bare) return;
                if (list.len > 0) conn.proto.submitData(s, list, trailer_fields == null) catch |err| return self.submitFailed(err);
                if (trailer_fields) |t| conn.proto.submitTrailers(s, t) catch |err| return self.submitFailed(err);
            }

            /// The trailers as fields in the arena (they are borrowed until
            /// framed); null without any.
            fn trailerFields(self: *StreamSink, trailers: ?*const http.Headers) std.Io.Writer.Error!?[]hpack.Field {
                const t = trailers orelse return null;
                if (t.count() == 0) return null;
                const arena = self.es.arena.allocator();
                const list = arena.alloc(hpack.Field, t.count()) catch return self.fail(error.SystemResources);
                var n: usize = 0;
                var it = t.iterator();
                while (it.next()) |entry| {
                    const name = lowerName(arena, entry.key) catch return self.fail(error.SystemResources);
                    const value = arena.dupe(u8, entry.value) catch return self.fail(error.SystemResources);
                    list[n] = .{ .name = name, .value = value };
                    n += 1;
                }
                return list[0..n];
            }

            /// Records the head. It goes out with the first body bytes, a
            /// flush, or the end, whichever is first, so a response with no
            /// body is one HEADERS frame. HPACK encodes it at the submit,
            /// so it lives in the arena only until then.
            fn head(ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const es = self.es;
                const arena = es.arena.allocator();
                es.status = if (@backingInt(status) < 100 or @backingInt(status) > 999) .internal_server_error else status;
                const list = arena.alloc(hpack.Field, headers.count() + 1) catch return self.fail(error.SystemResources);
                var n: usize = 0;
                var has_length = false;
                var it = headers.iterator();
                while (it.next()) |entry| {
                    // RFC 9113 §8.2.2: connection-specific fields are
                    // malformed.
                    if (isConnectionSpecific(entry.key)) continue;
                    if (std.ascii.eqlIgnoreCase(entry.key, "content-length")) has_length = true;
                    list[n] = .{ .name = lowerName(arena, entry.key) catch return self.fail(error.SystemResources), .value = entry.value };
                    n += 1;
                }
                if (!has_length and statusHasLength(status)) if (content_length) |len| {
                    list[n] = .{ .name = "content-length", .value = std.fmt.allocPrint(arena, "{d}", .{len}) catch return self.fail(error.SystemResources) };
                    n += 1;
                };
                es.resp_fields = list[0..n];
            }

            fn interim(ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const es = self.es;
                const conn = es.conn;
                {
                    conn.lock();
                    defer conn.unlock();
                    const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                    if (es.reset) return self.fail(error.ConnectionResetByPeer);
                    conn.proto.submitHead(s, @intCast(@backingInt(status)), &.{}, false) catch |err| return self.submitFailed(err);
                }
                self.kick();
            }

            /// The writer starts with no buffer: its first write takes a
            /// block (`drain`), so a handler that never writes a body never
            /// pays for one.
            fn body(ptr: *anyopaque) *std.Io.Writer {
                return &fromPtr(ptr).writer;
            }

            /// The head with no END_STREAM, once. Under the lock.
            fn submitHeadOnce(self: *StreamSink, s: *PStream) std.Io.Writer.Error!void {
                const es = self.es;
                if (es.head_sent) return;
                es.conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, false) catch |err| return self.submitFailed(err);
                es.head_sent = true;
            }

            /// Submits what the writer holds as one DATA part (by
            /// reference: the block is borrowed until written), with the
            /// head if it has not gone yet, and hands the output on. The
            /// writer is left with no buffer, so nothing it is asked to
            /// write lands in a borrowed block: the next block is taken
            /// only when more bytes come (`nextBlock`), so a last flush
            /// before the end takes none.
            fn submitBlock(self: *StreamSink) std.Io.Writer.Error!void {
                const es = self.es;
                const conn = es.conn;
                const w = &self.writer;
                const n = w.end;
                {
                    conn.lock();
                    defer conn.unlock();
                    const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                    if (es.reset) return self.fail(error.ConnectionResetByPeer);
                    const head_new = !es.head_sent;
                    try self.submitHeadOnce(s);
                    if (n == 0) {
                        if (!head_new) return;
                    } else {
                        const part = es.arena.allocator().alloc([]const u8, 1) catch return self.fail(error.SystemResources);
                        // Room first: nothing may fail once the block is
                        // borrowed.
                        if (es.inline_mode) es.spent.ensureUnusedCapacity(es.arena.allocator(), 1) catch return self.fail(error.SystemResources);
                        part[0] = w.buffer[0..n];
                        conn.proto.submitData(s, part, false) catch |err| return self.submitFailed(err);
                        if (es.inline_mode) {
                            // The reader can't wait for the writer: the
                            // block is kept until the stream is freed.
                            es.spent.appendAssumeCapacity(es.blocks[es.cur].mem);
                            es.blocks[es.cur] = .{};
                        } else {
                            es.blocks[es.cur].inflight = true;
                            es.cur ^= 1;
                        }
                        w.buffer = &.{};
                        w.end = 0;
                    }
                }
                self.kick();
            }

            /// The writer's next block: on the reader a fresh one; on a
            /// task `blocks[cur]`, once free (waiting on `room` while the
            /// other one is still borrowed by `out`).
            fn nextBlock(self: *StreamSink) std.Io.Writer.Error!void {
                const es = self.es;
                const conn = es.conn;
                while (true) {
                    const seen = es.room.epoch();
                    {
                        conn.lock();
                        defer conn.unlock();
                        if (es.inline_mode or conn.roomFree(es)) {
                            if (es.cs == null or es.reset or conn.send_shut) return self.fail(error.ConnectionResetByPeer);
                            const b = &es.blocks[es.cur];
                            if (b.mem.len == 0) {
                                b.mem = conn.allocator.alloc(u8, block_len) catch return self.fail(error.SystemResources);
                                if (comptime is_test) _ = test_blocks.fetchAdd(1, .monotonic);
                            }
                            self.writer.buffer = b.mem;
                            return;
                        }
                        if (!es.room_waiting) {
                            es.room_waiting = true;
                            conn.room_waiters.append(&es.room_node);
                        }
                    }
                    es.room.wait(conn.io, seen) catch return self.fail(error.Canceled);
                }
            }

            /// Moves what is buffered on, and the head with it, so a stream
            /// that stays open (an event stream) gets its HEADERS out before
            /// its first DATA.
            fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
                // SAFETY: the writer is a StreamSink's `writer`.
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                return self.submitBlock();
            }

            /// Moves what the block holds on, then takes what fits of
            /// `data` into the next.
            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                // SAFETY: the writer is a StreamSink's `writer`.
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                if (w.end > 0) try self.submitBlock();
                if (w.buffer.len == 0) try self.nextBlock();
                var n: usize = 0;
                for (data[0 .. data.len - 1]) |bytes| {
                    const k = @min(bytes.len, w.buffer.len - w.end);
                    @memcpy(w.buffer[w.end..][0..k], bytes[0..k]);
                    w.end += k;
                    n += k;
                    if (k < bytes.len) return n;
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    const k = @min(pattern.len, w.buffer.len - w.end);
                    @memcpy(w.buffer[w.end..][0..k], pattern[0..k]);
                    w.end += k;
                    n += k;
                    if (k < pattern.len) return n;
                }
                return n;
            }

            /// The rest of the body and the end: on the last DATA, on the
            /// trailers, or on HEADERS when nothing else went out. Nothing
            /// waits here (the last block is never reused).
            fn end(ptr: *anyopaque, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const es = self.es;
                const conn = es.conn;
                const trailer_fields = try self.trailerFields(trailers);
                const w = &self.writer;
                var part: []const []const u8 = &.{};
                if (w.end > 0) {
                    const p = es.arena.allocator().alloc([]const u8, 1) catch return self.fail(error.SystemResources);
                    p[0] = w.buffer[0..w.end];
                    part = p;
                }
                conn.lock();
                defer conn.unlock();
                const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                if (es.reset) return self.fail(error.ConnectionResetByPeer);
                // Before the submits, as in `complete`: the last one may
                // close the stream inside the call.
                es.ended = true;
                errdefer es.ended = false;
                if (!es.head_sent and part.len == 0 and trailer_fields == null) {
                    es.head_sent = true;
                    errdefer es.head_sent = false;
                    conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, true) catch |err| return self.submitFailed(err);
                    return;
                }
                try self.submitHeadOnce(s);
                // An empty end joins the DATA still queued (Conn.submitData).
                if (part.len > 0 or trailer_fields == null)
                    conn.proto.submitData(s, part, trailer_fields == null) catch |err| return self.submitFailed(err);
                // The block is borrowed now: no more writes into it.
                w.buffer = &.{};
                w.end = 0;
                if (trailer_fields) |t| conn.proto.submitTrailers(s, t) catch |err| return self.submitFailed(err);
            }

            fn writeError(ptr: *anyopaque) ?Response.SendError {
                return fromPtr(ptr).err;
            }

            fn peerGone(ptr: *anyopaque) bool {
                const es = fromPtr(ptr).es;
                es.conn.lock();
                defer es.conn.unlock();
                return es.reset;
            }
        };

        /// The common response field names, lowercase, so the usual head
        /// takes no allocation for its names.
        const common_names = [_][]const u8{
            "content-type",                "content-length",            "date",        "server",
            "vary",                        "cache-control",             "etag",        "last-modified",
            "content-encoding",            "location",                  "set-cookie",  "x-request-id",
            "accept-ranges",               "content-range",             "expires",     "alt-svc",
            "access-control-allow-origin", "strict-transport-security", "grpc-status", "grpc-message",
            "grpc-encoding",               "content-disposition",       "traceparent", "allow",
        };

        /// `name` in lowercase: a literal for the common names, else a copy
        /// in `arena`.
        fn lowerName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
            for (common_names) |known| {
                if (known.len == name.len and std.ascii.eqlIgnoreCase(known, name)) return known;
            }
            return std.ascii.allocLowerString(arena, name);
        }

        fn isConnectionSpecific(name: []const u8) bool {
            const banned = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
            for (banned) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
            return false;
        }

        fn statusHasLength(status: http.Status) bool {
            const code = @backingInt(status);
            return !(code < 200 or code == 204 or code == 304);
        }
    };
}
