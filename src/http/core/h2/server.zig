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
//! **Seams** (PLAN §3.5), with the nghttp2 engine's semantics: detached
//! responses (the C ABI's; `detach_engine`), parked ones (SSE; `H2Parked`)
//! and RFC 8441 tunnels (WebSocket over HTTP/2). Tunnel and parked output is
//! copied into a chain of blocks on the stream (`ChainBlock`), each let go
//! once written. Output from outside the connection's tasks (a detached
//! answer from the C ABI's task, a burst, a tunnel send from another task)
//! is only queued and handed to the flusher (`kickFlush`), never written on
//! the caller, which serves other requests (h2o's request_gathered_write, Go
//! x/net/http2's writeFrameFromHandler).
//!
//! **Lifecycle** (PLAN §3.3 "Timers", §3.5 "Drain"; M3 item lifecycle): a
//! connection is the server's `Adopter` from its first byte (`start`), so it
//! parks like an adopted HTTP/1.1 connection (D16, #97): once nothing is
//! open, queued or half read, the reader gives its read buffer, the output
//! blocks, the stream slab and the spare streams back and ends its task;
//! the shelf's poll starts a new one at the next byte. No timer per flush or
//! per connection: the reader's deadlines (keep-alive, a write's "no
//! progress" bound) are its task's registered `Timer`, kept to the shelf's
//! sweep (K10); the flusher has one of its own; a finished response the
//! peer gives no credit for is reset by the flusher at its send deadline
//! (`waitSends`). The drain's two-phase GOAWAY (notice + PING, the final
//! one at the ACK or when `Server.drainConnections` asks a second later)
//! reaches a reader waiting for input through its shelf's drain bell
//! (`park.Shelf.drainWake`), or under the lock where the connection has a
//! mutex.
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
const have_auto_cancel = @import("../deadline.zig").have_auto_cancel;
const RequestBuffers = @import("../server/request_buffers.zig").RequestBuffers;
const park = @import("../server/park.zig");
const placement = @import("../placement.zig");
const admission = @import("../admission.zig");
const gauges = @import("../gauges.zig");
const block_cache = @import("../block_cache.zig");
const Signal = @import("../signal.zig").Signal;
const Detached = @import("../detach.zig").Detached;
const parked_mod = @import("../parked.zig");
const Parked = parked_mod.Parked;

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
/// The most bytes a tunnel or a parked response may have queued for the
/// peer before its send waits, when the caller names no limit (the nghttp2
/// engine's `tunnel_outbox_max`).
const tunnel_outbox_max = 1024 * 1024;

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
/// Tests only: streaming body writers handed out (`StreamSink.body`), as
/// the nghttp2 engine counts them (grpc/server_test.zig reads it).
pub var test_sink_bodies: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: chain blocks alive (tunnels, parked responses).
pub var test_chain_blocks: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: sends that hopped to the connection's executor.
pub var test_hops: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: writes cut at `timeout.write`.
pub var test_write_timeouts: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: finished responses reset at their send deadline.
pub var test_send_resets: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: idle waits that could not park for a partial frame.
pub var test_park_refused_partial: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
/// Tests only: connections parked, and read buffers held now.
pub var test_parks: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
pub var test_read_buffers: if (is_test) std.atomic.Value(i32) else void = if (is_test) .init(0) else {};
/// Tests only: readers the drain bell woke, and connections closed at
/// their keep-alive deadline.
pub var test_drain_wakes: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};
pub var test_keepalive_closes: if (is_test) std.atomic.Value(u32) else void = if (is_test) .init(0) else {};

/// The HPACK scratch `Conn.recv` decodes into, one per executor (recv never
/// yields), from the block cache and never given back.
threadlocal var scratch_block: []align(16) u8 = &.{};

const Field = struct { name: []const u8, value: []const u8 };

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = server_mod.Server(Ctx);
        const Proto = conn_mod.Conn(.server, Conn);
        const PStream = conn_mod.Stream;

        /// The server's open HTTP/2 connections, for the drain, in the
        /// server's field `field` (the switch renames it `h2_conns`).
        /// The drain asks each connection for its GOAWAYs (`drain_req`)
        /// and gets them sent: where the connection has a mutex, now,
        /// under it; on a pinned executor, whose lock is no lock, by
        /// waking the readers that wait for input there (each shelf's
        /// drain bell), which act on it themselves, as every reader does
        /// at its next read. A parked connection is not woken: it begins
        /// its drain if its socket wakes it, and the stop closes it.
        pub const Registry = struct {
            mutex: safety.Mutex(.table) = .init,
            list: std.DoublyLinkedList = .{},

            pub const field = "h2_conns_anole";

            fn server(r: *Registry) *Server {
                // SAFETY: the registry is the server's `field` (`registered` in `start`).
                return @alignCast(@fieldParentPtr(field, r));
            }

            fn add(r: *Registry, conn: *Conn) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                r.list.append(&conn.node);
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
                const srv = r.server();
                const io = srv.io;
                var ring = false;
                const any = any: {
                    r.mutex.lockUncancelable(io);
                    defer r.mutex.unlock(io);
                    var it = r.list.first;
                    while (it) |node| : (it = node.next) {
                        // SAFETY: every node in the list is a Conn's `node` (`add`).
                        const conn: *Conn = @alignCast(@fieldParentPtr("node", node));
                        _ = conn.drain_req.fetchMax(what, .acq_rel);
                        if (conn.lock_.free) {
                            ring = true;
                            continue;
                        }
                        conn.lock();
                        conn.applyDrain();
                        conn.unlock();
                        conn.kickFlush();
                    }
                    break :any r.list.first != null;
                };
                if (ring) for (srv.shelves) |*shelf| shelf.drainWake();
                return any;
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
            /// The streams' tasks and the flusher (`group_`).
            group: *std.Io.Group,
            group_: std.Io.Group = .init,
            task_row: ?*admission.Row = null,
            /// What the server runs (`start`): `serve` once per run of the
            /// reader, between parks; `release` at the close.
            adopter: server_mod.Adopter = .{ .serve = adopterServe, .release = adopterRelease },
            /// The read buffer, while a run of the reader holds one.
            buffers: ?*RequestBuffers = null,
            /// The keep-alive deadline while nothing is open (awake clock).
            keepalive_at: ?std.Io.Clock.Timestamp = null,
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
            /// The connection's group takes no more tasks (the teardown,
            /// once the tasks are joined): no flusher is spawned, and a
            /// detached response can't be attached.
            tasks_closed: bool = false,
            /// Parked responses not released yet; the teardown waits for
            /// them (`parked_idle`), as their owners still touch them.
            parked_open: usize = 0,
            parked_idle: Signal = .{},

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
            /// The reader's: `drain_req` as it last acted on it.
            drain_seen: u8 = 0,
            drain_notice: bool = false,
            goaway_sent: bool = false,
            /// A second count in the server's in-flight requests, from the
            /// drain's notice to the teardown, so the drain also waits for
            /// the final GOAWAY and the lingering close (#135).
            drain_hold: bool = false,
            /// The final GOAWAY is out and nothing is open: the reader's
            /// side was shut down (`closeDrained`), so its read ends.
            drain_closed: bool = false,
            node: std.DoublyLinkedList.Node = .{},

            /// Finished responses whose last frames wait for the peer's
            /// credit (`EStream.send_wait`), and whether a task waits for
            /// their send deadlines (`waitSends`), woken on `send_wake`.
            send_waits: usize = 0,
            send_waiter: bool = false,
            send_wake: Signal = .{},

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
                // notice and its final GOAWAY they are still taken.
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
                if (es.protocol.len > 0) {
                    // A tunnel's output is copied to its chain
                    // (`StreamSink.appendParts`).
                    es.chain_mode = true;
                    if (!end_stream) conn.setTunnelWindow(es, s);
                }
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
                conn.sendDone(es);
                if (code != .no_error or !es.ended) es.reset = true;
                if (es.reset and es.body.len > 0) {
                    // Never read: the connection's credit goes back.
                    conn.proto.consumed(null, es.body.len) catch {};
                    es.body.clear();
                }
                conn.closeBody(es);
                conn.wakeRoom(es);
                if (es.reset) {
                    es.cancelHandler();
                    // Reset with its response detached: the owner lets go
                    // now (a parked one's hears `gone`). Neither waits nor
                    // calls back into `proto` (we are inside its call).
                    conn.abortDetached(es);
                }
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
                    // Its last frames may wait for the peer's credit: they
                    // get a send deadline (`waitSends`) unless they go out
                    // with this write.
                    if (es.ended and !es.reset and !es.send_wait and es.cs != null and s.canSend()) {
                        es.send_wait = true;
                        conn.send_waits += 1;
                    }
                }
                conn.maybeFree(es);
            }

            /// `es`'s last frames are out (or never will be). Under the
            /// lock.
            fn sendDone(conn: *Conn, es: *EStream) void {
                if (!es.send_wait) return;
                es.send_wait = false;
                conn.send_waits -= 1;
                if (conn.send_waits == 0 and conn.send_waiter) conn.send_wake.notify(conn.io);
            }

            /// Like the core's HTTP/1.x drain: a window more of the body is
            /// read and dropped, so a peer still sending a small one sees a
            /// clean end; then RST_STREAM(NO_ERROR) (`onData`). A tunnel
            /// (RFC 8441) whose handler is done has nothing left to read: it
            /// ends with RST_STREAM(NO_ERROR) as soon as its END_STREAM is
            /// framed (a reset before would drop it), rather than wait for a
            /// peer that may keep its side open (the nghttp2 engine's
            /// `startDiscard`).
            fn startDiscard(conn: *Conn, es: *EStream, s: *PStream) void {
                es.discarding = true;
                es.discard_left = if (es.protocol.len > 0) 0 else es.windowSize(conn);
                if (es.protocol.len > 0) {
                    es.reset_due = true;
                    conn.tunnelReset(es, s);
                    if (es.reset_due) conn.watchRoom(es);
                }
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
                conn.sendDone(es);
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

            // -- The drain (two-phase GOAWAY, RFC 9113 §6.8) -------------

            /// What the drain asked for (`Registry`), and the drain a
            /// connection that starts or wakes while the server drains
            /// begins itself. Under the lock.
            fn applyDrain(conn: *Conn) void {
                var req = conn.drain_req.load(.acquire);
                if (req == 0 and conn.server.busy.load(.acquire).draining) req = drain_notice_req;
                if (req >= drain_notice_req) conn.beginDrain();
                if (req >= drain_final_req) conn.finishDrain();
            }

            /// Phase one: GOAWAY with the largest stream ID, which streams
            /// already on the way still fit under, and a PING whose answer
            /// says they have arrived (the nghttp2 engine's `beginDrain`).
            /// Answered streams whose peer keeps its request side open would
            /// hold the drain until its deadline: they end now. Under the
            /// lock; out of line (cold).
            noinline fn beginDrain(conn: *Conn) void {
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (!es.discarding or es.reset) continue;
                    const s = es.cs orelse continue;
                    es.reset = true;
                    conn.proto.reset(s, .no_error) catch {};
                }
                if (conn.drain_notice or conn.goaway_sent or conn.closing or conn.proto.goaway_sent != null) return;
                conn.proto.shutdownNotice() catch return;
                conn.proto.ping(drain_ping) catch {};
                conn.drain_notice = true;
                conn.drain_hold = true;
                _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            }

            /// Phase two, at the PING's ACK or when the drain asks a round
            /// trip later: GOAWAY with the last stream taken. The drain
            /// hold stays until the teardown; the connection closes once
            /// nothing is open (`drained`). Under the lock.
            noinline fn finishDrain(conn: *Conn) void {
                if (!conn.drain_notice or conn.goaway_sent) return;
                conn.goaway_sent = true;
                if (conn.closing or conn.proto.goaway_sent != null) return;
                conn.proto.goaway(.no_error, "") catch {};
            }

            /// The final GOAWAY is out and no stream is open: nothing more
            /// is coming for this connection. Under the lock.
            fn drained(conn: *Conn) bool {
                return conn.goaway_sent and conn.live.first == null;
            }

            /// Idle past `timeout.keepalive`.
            fn keepaliveDue(conn: *const Conn) bool {
                const at = conn.keepalive_at orelse return false;
                return park.now(conn.io).nanoseconds >= at.raw.nanoseconds;
            }

            /// Gives back the drain's count. Under the lock.
            fn releaseDrainHold(conn: *Conn) void {
                if (!conn.drain_hold) return;
                conn.drain_hold = false;
                conn.server.finishRequest();
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

            /// Writes what is queued if no other task is writing it, each
            /// write bounded by `timer` (the caller's: `timeout.write`
            /// without progress). `error.Canceled` only when the caller
            /// itself was canceled in a write (the connection is then
            /// shut).
            fn flush(conn: *Conn, mode: FlushMode, timer: *Timer) std.Io.Cancelable!void {
                if (!conn.takeToken()) return;
                return conn.writeOut(mode, timer);
            }

            /// Hands what is queued to the flusher task, for a caller that
            /// must not write itself (a handler mid-response, which its
            /// stream's reset may cancel).
            /// Also the one way output from outside the connection's tasks
            /// goes out (a detached answer, a burst, a tunnel send from
            /// another task): never a write on the caller, which may serve
            /// other connections' requests (the C ABI's one task per
            /// executor). Once the tasks are closed the teardown's flush
            /// writes it.
            fn kickFlush(conn: *Conn) void {
                {
                    conn.lock();
                    defer conn.unlock();
                    if (conn.flushing or conn.send_shut or conn.tasks_closed) return;
                    conn.flushing = true;
                }
                if (conn.spawnFlusher(true)) return;
                conn.lock();
                conn.flushing = false;
                conn.unlock();
            }

            /// The flusher, with the token (`with_token`) or to wait for
            /// send deadlines only (`waitSends`).
            fn spawnFlusher(conn: *Conn, with_token: bool) bool {
                if (conn.tasks_closed) return false;
                if (conn.task_row) |r| _ = conn.server.admission.reserveTask(r, .forced);
                placement.concurrent(conn.group, conn.io, .local, flusherRun, .{ conn, with_token }) catch {
                    if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                    log.err("HTTP/2: no task for the connection's output", .{});
                    return false;
                };
                if (comptime is_test) _ = test_flushers.fetchAdd(1, .monotonic);
                return true;
            }

            /// Writes until nothing is left, then, while finished responses
            /// wait for the peer's credit, waits for their send deadlines.
            /// Its writes have a deadline of their own, on the shelf's
            /// sweep where there is one.
            fn flusherRun(conn: *Conn, with_token: bool) std.Io.Cancelable!void {
                defer if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                var timer: Timer = .init(null);
                timer.register(conn.server.shelfHere());
                defer {
                    timer.clear(conn.io);
                    timer.unregister();
                }
                if (with_token) return conn.writeOut(.all, &timer);
                return conn.waitSends(&timer);
            }

            /// After a token holder lets go: whether a send-deadline waiter
            /// should start (it is claimed here). Under the lock.
            fn claimSendWaiter(conn: *Conn) bool {
                if (conn.send_waits == 0 or conn.send_waiter or conn.send_shut or conn.tasks_closed or conn.closing) return false;
                if (conn.sendTimeout() == null) return false;
                conn.send_waiter = true;
                return true;
            }

            /// How long a finished response may wait for the peer's credit
            /// before it is reset (the nghttp2 engine's `sendTimeout`).
            fn sendTimeout(conn: *const Conn) ?std.Io.Duration {
                return conn.server.config.timeout.request orelse conn.server.config.timeout.keepalive;
            }

            /// Finished responses the peer gives no credit for are reset
            /// with CANCEL at their send deadline (the nghttp2 engine's
            /// writer `sweepSends`), so they don't hold the connection
            /// (and its count in the server's in-flight requests) for
            /// good. A futex wait with a timeout, so it works with no
            /// shelf too (std.Io.Threaded). Only while some wait, on the
            /// waiter `claimSendWaiter` claimed; cold.
            noinline fn waitSends(conn: *Conn, timer: *Timer) std.Io.Cancelable!void {
                errdefer {
                    conn.lock();
                    conn.send_waiter = false;
                    conn.unlock();
                }
                const step = conn.sendTimeout().?;
                while (true) {
                    const seen = conn.send_wake.epoch();
                    var earliest: ?i64 = null;
                    var reset: u32 = 0;
                    {
                        conn.lock();
                        defer conn.unlock();
                        if (conn.send_waits == 0 or conn.send_shut or conn.tasks_closed or conn.closing) {
                            conn.send_waiter = false;
                            return;
                        }
                        const now: i64 = @intCast(park.now(conn.io).nanoseconds);
                        var it = conn.live.first;
                        while (it) |node| {
                            it = node.next;
                            const es: *EStream = @fieldParentPtr("node", node);
                            if (!es.send_wait) continue;
                            const s = es.cs orelse {
                                conn.sendDone(es);
                                continue;
                            };
                            if (!s.canSend() or es.reset) {
                                conn.sendDone(es);
                                continue;
                            }
                            if (es.send_deadline == 0) es.send_deadline = now + @as(i64, @intCast(step.nanoseconds));
                            if (es.send_deadline <= now) {
                                conn.sendDone(es);
                                es.reset = true;
                                reset += 1;
                                // May free `es` (its close): not touched after.
                                conn.proto.reset(s, .cancel) catch {};
                                continue;
                            }
                            earliest = if (earliest) |e| @min(e, es.send_deadline) else es.send_deadline;
                        }
                    }
                    if (reset > 0) {
                        log.debug("HTTP/2: {d} finished response(s) the peer took no credit for, reset at their send deadline", .{reset});
                        if (comptime is_test) _ = test_send_resets.fetchAdd(reset, .monotonic);
                        try conn.flush(.all, timer);
                    }
                    const until = earliest orelse continue;
                    conn.send_wake.waitTimeout(conn.io, seen, .{ .deadline = .{ .raw = .{ .nanoseconds = until }, .clock = .awake } }) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                    };
                }
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
            ///
            /// A peer that stops reading must not hold the connection, and
            /// with it every stream, for good: `timeout.write` bounds each
            /// write buffer's worth (Go's WriteByteTimeout: no progress for
            /// that long), on `timer` (a deadline kept to the shelf's sweep
            /// where `timer` is registered with one).
            fn writeOut(conn: *Conn, mode: FlushMode, timer: *Timer) std.Io.Cancelable!void {
                var vecs: [max_vecs][]const u8 = undefined;
                const write_timeout = conn.server.config.timeout.write;
                var armed = false;
                defer if (armed) timer.clear(conn.io);
                const step = @max(1, conn.server.config.response.write_buffer_size);
                var since_arm: ?usize = null;
                var written: usize = 0;
                while (true) {
                    const got: []const []const u8 = got: {
                        conn.lock();
                        const got = if (conn.send_shut) &.{} else conn.proto.pending(&vecs) catch |err| switch (err) {
                            // Whole frames stay queued, but the connection
                            // can't go on.
                            error.OutOfMemory => {
                                conn.unlock();
                                break :got null;
                            },
                        };
                        if (got.len > 0) {
                            if (mode == .batch and written >= step and conn.spawnFlusher(true)) {
                                conn.unlock();
                                return;
                            }
                            conn.unlock();
                            break :got got;
                        }
                        if (conn.unflushed and !conn.send_shut) {
                            conn.unlock();
                            break :got got;
                        }
                        conn.connection.releaseWriteBuffer();
                        conn.unflushed = false;
                        conn.flushing = false;
                        const waiter = conn.claimSendWaiter();
                        const close_drained = conn.drained() and !conn.drain_closed and !conn.closing;
                        if (close_drained) conn.drain_closed = true;
                        conn.unlock();
                        if (waiter and !conn.spawnFlusher(false)) {
                            conn.lock();
                            conn.send_waiter = false;
                            conn.unlock();
                        }
                        // Nothing more will come: the reader's wait ends.
                        if (close_drained) conn.connection.stream.shutdown(conn.io, .recv) catch {};
                        return;
                    } orelse {
                        conn.writeFailed();
                        return;
                    };
                    if (since_arm == null or since_arm.? >= step) {
                        if (write_timeout) |d| {
                            const now: std.Io.Clock.Timestamp = .{ .raw = park.now(conn.io), .clock = .awake };
                            timer.setLazy(conn.io, now.addDuration(.{ .raw = d, .clock = .awake }));
                            armed = true;
                        }
                        since_arm = 0;
                    }
                    if (got.len == 0) {
                        conn.flushWriter(timer) catch |err| {
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
                    conn.writeVecs(vecs[0..got.len], timer) catch |err| {
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
                if (cause == error.Canceled) {
                    if (!timer.fired()) return error.Canceled;
                    if (comptime is_test) _ = test_write_timeouts.fetchAdd(1, .monotonic);
                    log.debug("HTTP/2: no write progress for timeout.write, closing the connection", .{});
                    return error.WriteFailed;
                }
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
                    if (es.chain_mode) {
                        conn.chainWritten(es);
                        continue;
                    }
                    if (!conn.roomFree(es)) continue;
                    conn.room_waiters.remove(node);
                    es.room_waiting = false;
                    es.room.notify(conn.io);
                }
            }

            /// Keeps `es` in `room_waiters` (a chain's blocks are let go,
            /// and a tunnel's due reset sent, after writes). Under the lock.
            fn watchRoom(conn: *Conn, es: *EStream) void {
                if (es.room_waiting) return;
                es.room_waiting = true;
                conn.room_waiters.append(&es.room_node);
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

            // -- Seams: tunnels, chains, detached streams -----------------

            /// Whether the caller runs on another executor than the
            /// connection's tasks, where the lock is no lock: it must hop
            /// (`StreamSink.onOwner`). Never off zio (the lock is a mutex).
            fn foreign(conn: *Conn) bool {
                if (!conn.lock_.free) return false;
                return placement.currentExecutor(conn.io) != conn.lock_.owner;
            }

            /// A tunnel (an extended CONNECT) reads at `tunnel_window`,
            /// fixed: its body buffer is that big from the first DATA, and
            /// its window is raised to it now. Raised by its distance from
            /// `stream_window`, which the peer's ACK of our SETTINGS adds
            /// to a window opened before it, so it lands on `tunnel_window`
            /// either way (the nghttp2 engine's `setTunnelWindow`). A
            /// `tunnel_window` below `stream_window` is left at the latter
            /// (INTENTIONAL.md). Under the lock.
            fn setTunnelWindow(conn: *Conn, es: *EStream, s: *PStream) void {
                const want = conn.config.tunnel_window;
                if (want <= conn.config.stream_window) return;
                conn.proto.raiseWindow(s, want - conn.config.stream_window) catch return;
                es.window = want;
            }

            /// A finished tunnel's RST_STREAM(NO_ERROR), once its END_STREAM
            /// is framed (`startDiscard`). Under the lock; may free `es`
            /// (its close), so the caller does not touch it after.
            fn tunnelReset(conn: *Conn, es: *EStream, s: *PStream) void {
                if (es.reset or s.state != .half_closed_local) return;
                es.reset_due = false;
                es.reset = true;
                conn.proto.reset(s, .no_error) catch {};
            }

            /// The stream ended with its response still detached (not
            /// attached): the owner hears of it, and the handler's hold
            /// goes (the caller frees `es` with `maybeFree`). A parked one's
            /// owner hears `gone` instead, and keeps the hold until
            /// `Parked.release`. Under the lock; never waits.
            fn abortDetached(conn: *Conn, es: *EStream) void {
                _ = conn;
                if (es.parked) |p| return p.peerGone();
                const ex = es.detached orelse return;
                const d = ex.response.detached.?;
                if (d.state != .detached) return;
                es.detached = null;
                d.abort();
                ex.request._body_held.release();
                ex.response.deinit();
                es.handler_hold = false;
            }

            /// Copies `parts` to the chain's tail, new blocks sized to what
            /// is left (`ChainBlock.create`). Under the lock.
            fn chainAppend(conn: *Conn, es: *EStream, parts: []const []const u8) error{OutOfMemory}!void {
                var left: usize = 0;
                for (parts) |part| left += part.len;
                for (parts) |part| {
                    var rest = part;
                    while (rest.len > 0) {
                        const prev: ?*ChainBlock = if (es.chain.last) |node| .of(node) else null;
                        const tail: *ChainBlock = tail: {
                            if (prev) |b| if (b.len < b.data().len) break :tail b;
                            const b: *ChainBlock = try .create(conn.allocator, left, if (prev) |p| p.size else 0);
                            es.chain.append(&b.node);
                            break :tail b;
                        };
                        const data = tail.data();
                        const n = @min(rest.len, data.len - tail.len);
                        @memcpy(data[tail.len..][0..n], rest[0..n]);
                        tail.len += n;
                        es.chain_bytes += n;
                        left -= n;
                        rest = rest[n..];
                    }
                }
            }

            /// Submits what the chain holds past its last cut, one DATA
            /// part per block (borrowed until written), and watches the
            /// stream for its blocks to be written. A block's cut still
            /// queued takes the new bytes (`Proto.growData`), so sends
            /// faster than the flushes go out as one DATA run per block,
            /// as the nghttp2 engine's outbox did. Under the lock.
            fn chainSubmit(conn: *Conn, es: *EStream, s: *PStream) conn_mod.SubmitError!void {
                var it = es.chain.first;
                while (it) |node| : (it = node.next) {
                    const b: *ChainBlock = .of(node);
                    if (b.cut == b.len) continue;
                    const more = b.len - b.cut;
                    if (b.cut > 0 and try conn.proto.growData(s, &b.part, more)) {
                        b.part[0] = b.part[0].ptr[0 .. b.part[0].len + more];
                    } else {
                        // Its previous cut, if any, is framed whole: the
                        // queue holds a block's cut only while it is the
                        // last one (bytes go to the tail only).
                        b.part[0] = b.data()[b.cut..b.len];
                        try conn.proto.submitData(s, &b.part, false);
                    }
                    b.cut = b.len;
                    // Written once the new cut is, not the old one.
                    b.mark = null;
                }
                conn.watchRoom(es);
            }

            /// Lets go of the blocks at the chain's front that are cut,
            /// framed (the stream's queue no longer holds their part: the
            /// front block's is the queue's first if queued) and written
            /// (`out.sent_total` past a mark taken once framed). An idle
            /// chain keeps none. Whether any went. Under the lock.
            fn chainReclaim(conn: *Conn, es: *EStream) bool {
                const s = es.cs orelse return false;
                var freed = false;
                while (es.chain.first) |node| {
                    const b: *ChainBlock = .of(node);
                    if (b.cut != b.len or conn.proto.queuedFirst(s, &b.part)) break;
                    if (b.mark == null) b.mark = conn.proto.out.mark();
                    if (conn.proto.out.sent_total < b.mark.?) break;
                    freed = true;
                    es.chain.remove(node);
                    es.chain_bytes -= b.len;
                    b.destroy(conn.allocator);
                }
                return freed;
            }

            /// After a write: a chain's written blocks go and a sender
            /// waiting for room is woken; a tunnel's due reset goes out;
            /// a stream with nothing left to watch leaves the list. Under
            /// the lock; may free `es`.
            fn chainWritten(conn: *Conn, es: *EStream) void {
                const s = es.cs orelse {
                    conn.wakeRoom(es);
                    return;
                };
                if (es.reset or conn.send_shut or conn.proto.dead or conn.chainReclaim(es)) es.room.notify(conn.io);
                const idle = es.chain.first == null;
                if ((idle or es.reset) and !es.reset_due) {
                    es.room_waiting = false;
                    conn.room_waiters.remove(&es.room_node);
                }
                if (es.reset_due) {
                    if (es.reset) {
                        es.reset_due = false;
                        es.room_waiting = false;
                        conn.room_waiters.remove(&es.room_node);
                        return;
                    }
                    // Last: the reset may free `es`, list node and all.
                    if (s.state == .half_closed_local) {
                        es.room_waiting = false;
                        conn.room_waiters.remove(&es.room_node);
                        conn.tunnelReset(es, s);
                    }
                }
            }
        };

        /// One block of a tunnel's or a parked response's output
        /// (`EStream.chain`): sends are copied in, and cut into a DATA part
        /// at each kick (`Conn.chainSubmit`), borrowed by `out` until
        /// written. The header, then its bytes, in one allocation sized
        /// like an ArrayList's growth: a power of two fitting what is left
        /// to copy, at least twice the block before, from `min_size` up to
        /// 16 KiB (malloc's slabs, as a streamed response's block), so a
        /// small message holds a small block.
        const ChainBlock = struct {
            node: std.DoublyLinkedList.Node = .{},
            /// The allocation's size, the header included.
            size: usize,
            len: usize = 0,
            /// Up to here submitted.
            cut: usize = 0,
            /// Its newest cut's one-part list, borrowed with it: grown
            /// while that cut is still queued, reused once it is framed.
            part: [1][]const u8 = .{&.{}},
            /// `out.mark()` once its newest cut is framed.
            mark: ?u64 = null,

            const min_size = 256;
            const max_size = block_len;

            fn of(node: *std.DoublyLinkedList.Node) *ChainBlock {
                return @fieldParentPtr("node", node);
            }

            fn create(gpa: std.mem.Allocator, want: usize, prev_size: usize) error{OutOfMemory}!*ChainBlock {
                const fit = std.math.ceilPowerOfTwoAssert(usize, @min(@sizeOf(ChainBlock) + want, max_size));
                const size = @min(max_size, @max(min_size, fit, prev_size * 2));
                const mem = try gpa.alignedAlloc(u8, .of(ChainBlock), size);
                // SAFETY: `mem` is aligned for and larger than a ChainBlock.
                const b: *ChainBlock = @ptrCast(mem.ptr);
                b.* = .{ .size = size };
                if (comptime is_test) _ = test_chain_blocks.fetchAdd(1, .monotonic);
                return b;
            }

            fn destroy(b: *ChainBlock, gpa: std.mem.Allocator) void {
                // SAFETY: `b` heads the allocation `create` made, `size` bytes.
                const base: [*]align(@alignOf(ChainBlock)) u8 = @ptrCast(b);
                gpa.free(base[0..b.size]);
                if (comptime is_test) _ = test_chain_blocks.fetchSub(1, .monotonic);
            }

            fn data(b: *ChainBlock) []u8 {
                // SAFETY: `b` heads its allocation; its bytes follow the header.
                const base: [*]u8 = @ptrCast(b);
                return base[@sizeOf(ChainBlock)..b.size];
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
            /// Its response is whole but its last frames are not framed
            /// yet (`Conn.send_waits`), and when it is reset if they still
            /// aren't (awake clock, ns; 0 until the flusher sets it).
            send_wait: bool = false,
            send_deadline: i64 = 0,

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

            // Seams.
            /// The body goes to `chain` (a tunnel, a parked response), not
            /// through the writer's blocks.
            chain_mode: bool = false,
            chain: std.DoublyLinkedList = .{},
            /// Bytes `chain` holds, against its cap (`appendChain`).
            chain_bytes: usize = 0,
            /// A finished tunnel's RST_STREAM(NO_ERROR) waits for its
            /// END_STREAM to be framed (`Conn.startDiscard`).
            reset_due: bool = false,
            /// `serveStream` is in the handler: a detached response ended
            /// meanwhile (`ended_in_handler`) is let go by its caller.
            in_handler: bool = false,
            ended_in_handler: bool = false,
            /// The response, detached and not finished yet; its exchange
            /// lives in the arena (`detachedRelocate`).
            detached: ?*Exchange = null,
            parked: ?*H2Parked = null,

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
                while (es.chain.popFirst()) |node| ChainBlock.of(node).destroy(gpa);
                es.chain_bytes = 0;
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

        /// Whether the server registers this engine's connections for the
        /// drain (`Registry.field`).
        fn registered() bool {
            return comptime @hasField(Server, Registry.field) and @FieldType(Server, Registry.field) == Registry;
        }

        /// Takes `connection`, initialized, over for HTTP/2: it becomes the
        /// server's `Adopter` (`connection.adopter`), which the caller then
        /// serves (`Server.serveAdopted`) until it closes or parks, and
        /// releases once (`Adopter.release`). `busy` is the connection's
        /// count in the server's in-flight requests, given back here: from
        /// now on it counts while streams are open.
        pub fn start(server: *Server, listener: *const Listener, secure: bool, connection: *Connection, busy: *bool) !void {
            if (busy.*) {
                busy.* = false;
                server.finishRequest();
            }
            const io = server.io;
            const h = server.config.http2;
            const conn = try server.allocator.create(Conn);
            errdefer server.allocator.destroy(conn);
            conn.* = .{
                .server = server,
                .connection = connection,
                .listener = listener,
                .secure = secure or connection.proxied_secure,
                .io = io,
                .allocator = server.allocator,
                .config = h,
                // SAFETY: set to `group_` right below.
                .group = undefined,
                .max_spares = @max(1, @min(max_spare_streams, h.max_concurrent_streams)),
                .inline_ok = h.inline_no_wait and server.router.has_no_wait,
                .task_row = server.admission.currentRow(io),
            };
            conn.group = &conn.group_;
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
            try conn.proto.initAt(server.allocator, conn, opts);
            if (comptime registered()) @field(server, Registry.field).add(conn);
            connection.adopter = &conn.adopter;
        }

        /// `start`, then the connection served on the calling task as a
        /// server with no shelves serves an adopted one (it never parks),
        /// then released: for the tests and the test listener
        /// (`test_server.zig`), which run the engine on a connection of
        /// their own.
        pub fn serve(server: *Server, listener: *const Listener, secure: bool, connection: *Connection, busy: *bool) !void {
            try start(server, listener, secure, connection, busy);
            const a = connection.adopter.?;
            defer {
                connection.adopter = null;
                a.release(a);
            }
            var timer: Timer = .init(null);
            defer timer.clear(server.io);
            var burst: server_mod.Burst = .{ .connection = connection, .io = server.io, .timer = &timer, .park_after = null, .deadline = null };
            _ = try a.serve(a, &burst);
        }

        /// `Adopter.serve`: a run of the reader, from the connection's
        /// start or its wake from a park, with a read buffer from the pool
        /// for as long as it runs. Parks (`.park`) once idle, else serves
        /// the connection to its end (`.close`): everything written and
        /// every task of the connection's ended.
        fn adopterServe(a: *server_mod.Adopter, burst: *server_mod.Burst) anyerror!server_mod.Burst.End {
            const conn: *Conn = @fieldParentPtr("adopter", a);
            a.deadline = null;
            const server = conn.server;
            const connection = conn.connection;
            // SAFETY: the connection's address only picks a pool shard.
            const buffers = try server.request_buffers.acquire(@intFromPtr(connection));
            conn.buffers = buffers;
            if (comptime is_test) _ = test_read_buffers.fetchAdd(1, .monotonic);
            defer {
                // A park leaves nothing in it (`prepPark`).
                connection.replaceReadBuffer(&.{});
                conn.buffers = null;
                server.request_buffers.release(buffers);
                if (comptime is_test) _ = test_read_buffers.fetchSub(1, .monotonic);
            }
            // Conn takes a frame other than DATA only once it is whole.
            if (buffers.read_buffer.len < 9 + 16384) {
                log.err("HTTP/2 needs a read buffer of at least 16393 bytes: request.buffer_size is {d}", .{server.config.request.buffer_size});
                return error.Http2ReadBufferTooSmall;
            }
            connection.useReadBuffer(buffers.read_buffer);
            const result = readerLoop(conn, burst);
            if (result) |end| if (end == .park) return .park else {} else |_| {}
            try closeRun(conn, burst.timer, result);
            return .close;
        }

        /// The connection is over, after its last run (`closeRun`) or an
        /// error, and `Adopter.release` frees it: the tasks canceled and
        /// joined; detached responses nobody finished: their owners hear of
        /// it; parked ones: their owners hear the peer is gone and release
        /// once their bursts are over, so they are waited for (the nghttp2
        /// engine's teardown order: parked told, the group canceled,
        /// detached aborted, then the wait). Also from the shelf's driver,
        /// for a parked connection, which has no stream.
        fn adopterRelease(a: *server_mod.Adopter) void {
            teardown(@fieldParentPtr("adopter", a));
        }

        noinline fn teardown(conn: *Conn) void {
            const io = conn.io;
            const server = conn.server;
            conn.group.cancel(io);
            if (comptime registered()) @field(server, Registry.field).remove(conn);
            {
                conn.lock();
                defer conn.unlock();
                conn.closing = true;
                conn.tasks_closed = true;
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (es.detached == null and es.parked == null) continue;
                    es.reset = true;
                    conn.closeBody(es);
                    conn.wakeRoom(es);
                    conn.abortDetached(es);
                    conn.maybeFree(es);
                }
            }
            waitParked(conn);
            // Nothing else touches the streams now.
            while (conn.live.popFirst()) |node| {
                const es: *EStream = @fieldParentPtr("node", node);
                if (es.cs) |s| s.user = null;
                gauges.add(io, .h2_streams, -1);
                es.releaseMemory(conn.allocator);
                es.destroy(conn.allocator);
            }
            conn.open_streams = 0;
            conn.releaseBusyIfIdle();
            // The drain's hold, kept until here so the drain waits for the
            // lingering close too (#135).
            conn.releaseDrainHold();
            for (conn.spares.items) |es| es.destroy(conn.allocator);
            conn.spares.deinit(conn.allocator);
            conn.ready.deinit(conn.allocator);
            conn.awaiting.deinit(conn.allocator);
            if (conn.own_scratch.len > 0) conn.allocator.free(conn.own_scratch);
            conn.proto.deinit();
            server.allocator.destroy(conn);
        }

        /// After the reader's last loop: no more request body can arrive,
        /// so a handler still waiting for one is told the stream is gone
        /// and canceled. After a clean end of the peer's side (maybe a
        /// half-close) a handler with its whole request keeps running, for
        /// a response that may still go out; after a read or protocol
        /// error every one is canceled. Then what is left is written, the
        /// tasks are joined, and a peer whose side is still open gets a
        /// lingering close. Out of line (cold).
        noinline fn closeRun(conn: *Conn, timer: *Timer, result: anyerror!ReaderEnd) !void {
            var reader_failed = false;
            var linger = false;
            if (result) |end| switch (end) {
                .eof => {},
                .done, .drained => linger = true,
                // A connection error frames no more DATA: no response can
                // finish (the nghttp2 engine's Http2ProtocolError).
                .dead => {
                    linger = true;
                    reader_failed = true;
                },
                // Idle past `timeout.keepalive`: a GOAWAY first, as nginx,
                // Go and h2o send on an idle close.
                .keepalive => {
                    if (comptime is_test) _ = test_keepalive_closes.fetchAdd(1, .monotonic);
                    conn.lock();
                    defer conn.unlock();
                    if (conn.proto.goaway_sent == null) conn.proto.goaway(.no_error, "") catch {};
                },
                .park => unreachable,
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
            {
                conn.lock();
                defer conn.unlock();
                conn.closing = true;
                // A send-deadline waiter has nothing left to wait for.
                if (conn.send_waiter) conn.send_wake.notify(conn.io);
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    // A parked response has nobody to send to once the
                    // peer closed its side of the connection.
                    if (reader_failed or !es.body_done or es.parked != null) {
                        es.reset = true;
                        conn.closeBody(es);
                        conn.wakeRoom(es);
                        es.cancelHandler();
                        // Detached with nobody left to send to: let go now
                        // rather than at its deadline.
                        conn.abortDetached(es);
                        conn.maybeFree(es);
                    }
                }
            }
            conn.flush(.all, timer) catch return error.Canceled;
            conn.group.await(conn.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            conn.flush(.all, timer) catch return error.Canceled;
            if (linger) try lingeringClose(conn);
        }

        /// Waits, uncancelably, until every parked response is released.
        fn waitParked(conn: *Conn) void {
            const protection = conn.io.swapCancelProtection(.blocked);
            defer _ = conn.io.swapCancelProtection(protection);
            while (true) {
                const seen = conn.parked_idle.epoch();
                conn.lock();
                const open = conn.parked_open;
                conn.unlock();
                if (open == 0) return;
                conn.parked_idle.wait(conn.io, seen) catch {};
            }
        }

        /// How the reader ended: the peer ended its side (`eof`), the
        /// connection is over with the peer's side still open (`done`: a
        /// failed write), a connection error's GOAWAY went out (`dead`),
        /// idle past its keep-alive deadline (`keepalive`), drained (the
        /// final GOAWAY out and nothing open: `drained`), or idle with
        /// nothing in flight, to park (`park`).
        const ReaderEnd = enum { eof, done, dead, keepalive, drained, park };

        /// Reads the connection and feeds `Conn.recv` until the peer is
        /// done, the connection is, or it parks. Before each wait for
        /// input: the drain's requests, and the keep-alive deadline while
        /// no stream is open, on the run's timer (`burst.timer`: kept to
        /// the shelf's sweep, which also ends the wait for the drain's
        /// bell). With nothing half read, the wait ends at the park delay
        /// (`burst.park_after`, `Burst.waitInput`), and the connection
        /// parks if nothing is open or in flight by then; one whose
        /// streams are still open waits another park delay (a wake per
        /// `idle_park`, as an adopted WebSocket's `Watch`).
        fn readerLoop(conn: *Conn, burst: *server_mod.Burst) !ReaderEnd {
            const reader = conn.connection.reader;
            const timer = burst.timer;
            const park_after = burst.park_after;
            // Started or woken while the server drains: the drain first.
            if (conn.server.busy.load(.acquire).draining) try drainNow(conn, timer);
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
                            if (conn.awaiting.items.len > 0) conn.startAwaiting();
                        } else |_| {}
                        break :result result;
                    };
                    const taken = result catch |err| switch (err) {
                        // A GOAWAY is queued: out it goes, then the
                        // lingering close.
                        error.ConnectionError => {
                            try conn.flush(.all, timer);
                            return .dead;
                        },
                        error.BadPreface => return error.Http2BadPreface,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    reader.toss(taken);
                    if (conn.ready.items.len > 0) try runInline(conn);
                    try conn.flush(.batch, timer);
                    if (conn.send_shut) return .done;
                    // What is left, if anything, is a frame not yet whole.
                }

                if (conn.drain_req.load(.acquire) != conn.drain_seen) try drainNow(conn, timer);
                const idle, const drained, const may_park = state: {
                    conn.lock();
                    defer conn.unlock();
                    conn.trimIdle();
                    break :state .{
                        conn.open_streams == 0,
                        conn.drained(),
                        conn.proto.atFrameBoundary() and !conn.drain_notice and !conn.goaway_sent,
                    };
                };
                if (drained) return .drained;
                if (idle) {
                    conn.keepalive_at = if (conn.server.config.timeout.keepalive) |d|
                        (std.Io.Clock.Timestamp{ .raw = park.now(conn.io), .clock = .awake }).addDuration(.{ .raw = d, .clock = .awake })
                    else
                        null;
                    timer.setLazy(conn.io, conn.keepalive_at);
                } else {
                    conn.keepalive_at = null;
                    timer.clear(conn.io);
                }
                burst.park_after = if (may_park) park_after else null;
                const input = waitInput(conn, burst, may_park) catch |err| switch (err) {
                    error.EndOfStream => return .eof,
                    error.Canceled => {
                        // Not this run's deadline or the drain's bell: the
                        // server stops.
                        if (!timer.fired()) return error.Canceled;
                        // A canceled TLS read resumes (`Burst.waitInput`).
                        conn.connection.clearReadError();
                        if (conn.keepaliveDue()) return .keepalive;
                        // The drain's bell: its requests at the top.
                        if (comptime is_test) _ = test_drain_wakes.fetchAdd(1, .monotonic);
                        continue;
                    },
                    else => |e| {
                        // The final GOAWAY's shutdown of our read side
                        // (`writeOut`): over TLS a read error, not an end.
                        if (conn.drain_closed) return .eof;
                        return e;
                    },
                };
                if (input == .idle) {
                    if (prepPark(conn)) return .park;
                    // Busy after all (a stream open, a write): the park
                    // delay again from here, not at once (`Burst.repark`).
                    burst.repark = false;
                }
            }
        }

        /// The drain's requests now, with their GOAWAY written (the reader,
        /// which may write).
        noinline fn drainNow(conn: *Conn, timer: *Timer) std.Io.Cancelable!void {
            {
                conn.lock();
                defer conn.unlock();
                conn.drain_seen = conn.drain_req.load(.acquire);
                conn.applyDrain();
            }
            try conn.flush(.batch, timer);
        }

        /// One wait for input: through `Burst.waitInput` (the park delay)
        /// unless a partial frame is buffered, whose rest is read on this
        /// task (a partial frame never parks). While it waits, the drain's
        /// bell may end it (`park.Lazy.wake_on_drain`).
        fn waitInput(conn: *Conn, burst: *server_mod.Burst, may_park: bool) !server_mod.Burst.Input {
            const reader = conn.connection.reader;
            const lazy = if (comptime have_auto_cancel) &burst.timer.lazy else {};
            if (comptime have_auto_cancel) lazy.wake_on_drain = true;
            defer if (comptime have_auto_cancel) {
                lazy.wake_on_drain = false;
            };
            if (reader.bufferedLen() == 0) return burst.waitInput();
            if (comptime is_test) if (may_park) {
                _ = test_park_refused_partial.fetchAdd(1, .monotonic);
            };
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return conn.connection.getReadError() orelse error.Unexpected,
            };
            return .ready;
        }

        /// The connection waited the park delay with nothing open, queued
        /// or half read: it parks, unless something is in flight after all
        /// (a write, a flusher, the drain, a TLS record half read), and
        /// gives back its memory first (PLAN §3.4, D16): the output
        /// blocks, the stream slab and table, the spare streams; the read
        /// buffer goes when the run ends (`adopterServe`). It keeps its
        /// keep-alive deadline on the shelf (`Adopter.deadline`).
        noinline fn prepPark(conn: *Conn) bool {
            const connection = conn.connection;
            conn.lock();
            defer conn.unlock();
            if (connection.reader.bufferedLen() != 0 or !conn.proto.atFrameBoundary()) {
                if (comptime is_test) _ = test_park_refused_partial.fetchAdd(1, .monotonic);
                return false;
            }
            if (conn.live.first != null or conn.flushing or conn.send_waiter or conn.ready.items.len != 0 or conn.awaiting.items.len != 0) return false;
            if (conn.drain_notice or conn.goaway_sent or conn.proto.dead or conn.drain_req.load(.acquire) != 0) return false;
            if (conn.server.busy.load(.acquire).draining) return false;
            if (!connection.parkable()) return false;
            const shelf = conn.server.shelfHere() orelse return false;
            if (shelf.closed) return false;
            if (!conn.proto.releaseIdle()) return false;
            for (conn.spares.items) |es| es.destroy(conn.allocator);
            conn.spares.clearAndFree(conn.allocator);
            conn.spare_low = 0;
            conn.ready.clearAndFree(conn.allocator);
            conn.awaiting.clearAndFree(conn.allocator);
            conn.adopter.deadline = conn.keepalive_at;
            if (comptime is_test) _ = test_parks.fetchAdd(1, .monotonic);
            return true;
        }

        /// Hangs up on a peer whose side is still open once the connection
        /// is over, so it still gets the last frames (the nghttp2 engine's
        /// `lingeringClose`): close_notify under TLS and the send side
        /// shut, then what the peer sends is thrown away until it hangs up,
        /// `linger_timeout` passes, or `linger_limit` bytes. The tasks have
        /// ended: this is the only reader and writer. Out of line (cold).
        noinline fn lingeringClose(conn: *Conn) std.Io.Cancelable!void {
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
            // A handler that parked the response (`Response._park`) hands
            // its hold on the stream to the park: `Parked.release` lets go.
            var parked = false;
            defer {
                const timed_out = timer.fired();
                timer.clear(conn.io);
                conn.lock();
                es.task = null;
                // A cancel that reached this task (its stream's reset, its
                // request timer) may still be pending: the write is the
                // flusher's then.
                const kick = es.canceled or timed_out or canceled;
                if (!parked) conn.finishHandler(es);
                conn.unlock();
                if (kick) conn.kickFlush() else conn.flush(.batch, &timer) catch conn.kickFlush();
            }
            if (gone) {
                log.debug("HTTP/2 stream {d} reset before its handler started", .{es.id});
                return;
            }
            if (conn.server.config.timeout.request) |d| timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
            const served = serveStream(conn, es, &timer) catch |err| return streamFailed(conn, es, err) catch {
                canceled = true;
                return error.Canceled;
            };
            parked = served == .detached;
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
                var detached = false;
                if (!gone) {
                    if (serveStream(conn, es, null)) |served| {
                        detached = served == .detached;
                    } else |err| streamFailed(conn, es, err) catch {
                        canceled = true;
                    };
                }
                // A detached response keeps the stream until it is
                // finished (`detach_engine`).
                if (!detached) {
                    conn.lock();
                    conn.finishHandler(es);
                    conn.unlock();
                }
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

        /// One request and its response, with what they point at: on the
        /// handler's stack, or in the stream's arena once detached
        /// (`detachedRelocate`).
        const Exchange = struct {
            request: Request,
            response: Response,
            sink_state: StreamSink,
            body_reader: BodyReader,
        };

        const Served = enum { done, detached };

        /// Serves one request: on the reader (`timer` null, a `no_wait`
        /// route, no request timeout, whose timer would cancel the reader)
        /// or on its own task. The nghttp2 engine's `serveStream`, with
        /// the same request build, so the router, handlers and middleware
        /// see the same request. On the reader the response may be
        /// detached (`Detached`); on a task only to be parked. `.detached`:
        /// the stream's handler hold went to the detached response.
        fn serveStream(conn: *Conn, es: *EStream, timer: ?*Timer) !Served {
            const server = conn.server;
            const arena = es.arena.allocator();
            const io = conn.io;
            // On the stack (warm, no allocation); `detachedRelocate` moves
            // it to the stream's arena if the handler detaches.
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
            var detached = false;
            defer if (!detached) response.deinit();
            response._request = request;
            request._response = response;
            response._detach_engine = &detach_engine;
            response._detach_ctx = &ex;
            // On its own task the response may detach only to be parked.
            response._detach_park_only = timer != null;
            conn.lock();
            es.in_handler = true;
            conn.unlock();
            defer {
                conn.lock();
                es.in_handler = false;
                conn.unlock();
            }

            request.method = parseMethod(es.method) orelse {
                response.status = .not_implemented;
                try response.write();
                return .done;
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
                try response.write();
                return .done;
            }
            if (!too_many and hosts == 0 and es.authority.len > 0) {
                request.headers.add("Host", es.authority) catch {
                    too_many = true;
                };
            }
            if (too_many) {
                response.status = .request_header_fields_too_large;
                try response.write();
                return .done;
            }
            request._applyEntityHeaders();
            // A body declared longer than allowed is refused unread.
            if (server.config.request.max_content_length) |max| {
                if (request.content_length) |len| if (len > max) {
                    response.status = .payload_too_large;
                    response.content_type = .text;
                    response.body = "413 Content Too Large\n";
                    try response.write();
                    return .done;
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
                    try response.write();
                    return .done;
                }
            }

            log.debug("Received (h2 stream {d}): {f} {s}", .{ es.id, request.method, request.url });

            const dispatched = server.dispatch(request, response);
            // A detached response is its owner's (or over already, a park
            // that failed having handled the error), whatever the handler
            // returned: the stack copy is not written or freed here.
            if (response.detached) |d| {
                detached = true;
                conn.lock();
                defer conn.unlock();
                // From here an end lets go itself.
                es.in_handler = false;
                // Already over (a park that failed, or a finish or release
                // from inside the handler): `d` may be gone with the
                // exchange, and the handler's hold is the caller's to let
                // go, as for a response written in place.
                if (es.ended_in_handler) return .done;
                es.detached = exchangeOf(d);
                return .detached;
            }
            dispatched catch |err| switch (err) {
                error.ReadFailed => return body_reader.err orelse error.Unexpected,
                error.WriteFailed => return sink_state.err orelse error.Unexpected,
                else => |e| return e,
            };
            try response.write();
            return .done;
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

        // -- Detached and parked responses (the nghttp2 engine's, ported) -

        /// How a detached response is finished, attached to a task, or let
        /// go (`Detached`).
        const detach_engine: Detached.Engine = .{ .relocate = detachedRelocate, .end = detachedEnd, .attach = detachedAttach, .enter = detachedEnter, .park = detachedPark };

        /// The exchange, from the reader's stack into the stream's arena,
        /// its pointers into itself moved along.
        fn detachedRelocate(d: *Detached) error{OutOfMemory}!*anyopaque {
            const old = exchangeOf(d);
            const ex = try old.response.arena.create(Exchange);
            ex.* = old.*;
            // The body's share of the buffer budget moves with the request:
            // `Server.dispatch` then gives back nothing of the old one, and
            // the end of the exchange gives back what the copy holds (a body
            // read after the handler returned included).
            old.request._body_held = .{};
            ex.request._response = &ex.response;
            ex.response._request = &ex.request;
            ex.request._body_source = .{ .reader = &ex.body_reader.interface, .err = BodyReader.errorOf };
            ex.response._sink = ex.sink_state.sink();
            ex.response._detach_ctx = ex;
            // A task's request timer lives on the task's stack.
            ex.request._timeout_context = null;
            ex.request._set_timeout = null;
            ex.request._claim_timeout = null;
            d.request = &ex.request;
            d.response = &ex.response;
            return ex;
        }

        fn exchangeOf(d: *Detached) *Exchange {
            // SAFETY: `engine_ctx` is the Exchange (`serveStream`, `detachedRelocate`).
            return @ptrCast(@alignCast(d.engine_ctx));
        }

        /// Writes the response (or handles `result`'s error as a
        /// handler's), then lets go of the stream. On the connection's
        /// executor: the owner's task (which serves other requests, so the
        /// output only goes to the flusher), or the task `detachedAttach`
        /// was for.
        fn detachedEnd(d: *Detached, result: anyerror!void) void {
            const ex = exchangeOf(d);
            ex.request._body_held.release();
            const es = ex.sink_state.es;
            const conn = es.conn;
            if (es.parked != null) {
                // The end of a parked response: the last DATA (or the
                // failure's reset). The hold on the stream stays until the
                // owner's `Parked.release`.
                if (result) |_| {
                    ex.sink_state.sink().end(if (ex.response.trailers) |*t| t else null) catch {};
                } else |err| {
                    streamFailed(conn, es, err) catch {};
                }
                ex.response.deinit();
                conn.lock();
                es.detached = null;
                conn.unlock();
                conn.kickFlush();
                return;
            }
            if (result) |_| {
                ex.response.write() catch |err| {
                    streamFailed(conn, es, err) catch {};
                };
            } else |err| {
                streamFailed(conn, es, err) catch {};
            }
            ex.response.deinit();
            {
                conn.lock();
                defer conn.unlock();
                es.detached = null;
                if (es.in_handler) {
                    // `serveStream` is still in the handler (a park that
                    // failed, or a finish from inside it): it lets go when
                    // it returns.
                    es.ended_in_handler = true;
                } else {
                    es.task = null;
                    conn.finishHandler(es);
                }
            }
            conn.kickFlush();
        }

        /// The response goes on from a task: its body writes may now wait
        /// for the peer, as a handler task's do.
        fn detachedAttach(d: *Detached) ?*std.Io.Group {
            const es = exchangeOf(d).sink_state.es;
            const conn = es.conn;
            conn.lock();
            defer conn.unlock();
            if (conn.tasks_closed) return null;
            es.inline_mode = false;
            return conn.group;
        }

        fn detachedEnter(d: *Detached) void {
            const es = exchangeOf(d).sink_state.es;
            const conn = es.conn;
            conn.lock();
            defer conn.unlock();
            es.task = placement.currentTask(conn.io);
        }

        /// A parked response (`Response._park`): bursts of DATA from
        /// whichever task has something to send, no task in between,
        /// copied to the stream's chain (H3's `H3Parked`, on `parked.zig`'s
        /// `Notice`). Its owner hears of the peer leaving through
        /// `owner.gone`, and the stream lives until the owner's `release`,
        /// which also lets go of the handler's hold (the park took it, on
        /// the reader or a task alike).
        const H2Parked = struct {
            parked: Parked = .{ .vtable = &vtable },
            es: *EStream,
            ex: *Exchange,
            d: *Detached,
            owner: Parked.Owner,
            /// Under the connection's lock; the stream's own `reset` is
            /// checked next to it.
            notice: parked_mod.Notice = .idle,

            const vtable: Parked.VTable = .{
                .begin = begin,
                .write = write,
                .endBurst = endBurst,
                .end = end,
                .abort = abort,
                .release = release,
            };

            fn of(p: *Parked) *H2Parked {
                // SAFETY: every `Parked` this engine hands out is an H2Parked's (`detachedPark`).
                return @alignCast(@fieldParentPtr("parked", p));
            }

            fn begin(p: *Parked) bool {
                const self = of(p);
                const conn = self.es.conn;
                conn.lock();
                defer conn.unlock();
                if (self.es.reset or !self.notice.begin()) return false;
                // A reset cancels the burst's task (`cancelHandler`).
                self.es.task = placement.currentTask(conn.io);
                return true;
            }

            /// Copied to the stream's chain (waiting past its cap for
            /// room); out at `endBurst`.
            fn write(p: *Parked, parts: []const []const u8) Parked.WriteError!void {
                const self = of(p);
                const conn = self.es.conn;
                conn.lock();
                const over = self.notice == .over or self.es.reset;
                conn.unlock();
                if (over) return error.Gone;
                const sink_state = &self.ex.sink_state;
                sink_state.appendChain(parts, tunnel_outbox_max, false) catch {
                    if (sink_state.err) |e| switch (e) {
                        error.Canceled => return error.Canceled,
                        error.SystemResources => return error.SystemResources,
                        else => {},
                    };
                    return error.Gone;
                };
            }

            /// Ends the burst `begin` started; a `gone` that came during
            /// it is delivered now.
            fn finishBurst(self: *H2Parked) void {
                const conn = self.es.conn;
                conn.lock();
                self.es.task = null;
                const deliver = self.notice.endBurst();
                conn.unlock();
                if (deliver) self.owner.gone(self.owner.ctx);
            }

            fn endBurst(p: *Parked) void {
                const self = of(p);
                self.ex.sink_state.sink().kickOut();
                self.finishBurst();
            }

            fn end(p: *Parked) void {
                const self = of(p);
                const conn = self.es.conn;
                conn.lock();
                const already = self.notice.finish();
                const reset = self.es.reset;
                conn.unlock();
                // The middleware finishers, then the end (`detachedEnd`).
                if (!already and !reset) self.d.finish({});
                self.finishBurst();
            }

            fn abort(p: *Parked) void {
                const self = of(p);
                const conn = self.es.conn;
                conn.lock();
                _ = self.notice.finish();
                conn.unlock();
                resetStream(conn, self.es, .cancel);
                conn.kickFlush();
                self.finishBurst();
            }

            /// The stream was reset or the connection is gone. Under the
            /// lock; never waits.
            fn peerGone(self: *H2Parked) void {
                // A burst running was canceled with the stream
                // (`cancelHandler`): `endBurst` tells the owner.
                if (self.notice.peerGone() == .tell) self.owner.gone(self.owner.ctx);
            }

            fn release(p: *Parked) void {
                const self = of(p);
                const es = self.es;
                const conn = es.conn;
                self.ex.request._body_held.release();
                self.ex.response.deinit();
                {
                    conn.lock();
                    defer conn.unlock();
                    // Let go before it ended (the owner gave up on a stream
                    // the peer still has open): reset it.
                    if (!es.ended and !es.reset) {
                        es.reset = true;
                        if (es.cs) |s| conn.proto.reset(s, .cancel) catch {};
                    }
                }
                // Before the count drops: once it is 0 the teardown
                // (`waitParked`) may free `conn`, so the hold below that
                // drops it is the last touch of `conn`.
                conn.kickFlush();
                conn.lock();
                defer conn.unlock();
                es.parked = null;
                es.detached = null;
                // Released from inside the handler: `serveStream`'s caller
                // lets go when it returns. Otherwise the stream may be
                // freed here, with `self` in its arena.
                if (es.in_handler) es.ended_in_handler = true else conn.finishHandler(es);
                conn.parked_open -= 1;
                if (conn.parked_open == 0) conn.parked_idle.notify(conn.io);
            }
        };

        /// `Detached.Engine.park`: the exchange is relocated and the head
        /// recorded by the caller next; the body goes to the stream's chain
        /// in bursts from now on.
        fn detachedPark(d: *Detached, owner: Parked.Owner) error{ OutOfMemory, WriteFailed }!*Parked {
            const ex = exchangeOf(d);
            const es = ex.sink_state.es;
            const conn = es.conn;
            const p = try ex.response.arena.create(H2Parked);
            p.* = .{ .es = es, .ex = ex, .d = d, .owner = owner };
            conn.lock();
            defer conn.unlock();
            if (es.reset) return error.WriteFailed;
            es.chain_mode = true;
            // Bursts run on tasks, which may wait for the peer.
            es.inline_mode = false;
            es.parked = p;
            conn.parked_open += 1;
            return &p.parked;
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
                    .appendParts = appendParts,
                    .kickOut = kickOut,
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
                if (comptime is_test) _ = test_sink_bodies.fetchAdd(1, .monotonic);
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
                if (self.es.chain_mode) return self.kickChain();
                return self.submitBlock();
            }

            /// Moves what the block holds on, then takes what fits of
            /// `data` into the next.
            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                // SAFETY: the writer is a StreamSink's `writer`.
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                // A chain's writer has no buffer: the bytes are copied to
                // the chain, out at the next flush.
                if (self.es.chain_mode) {
                    var n: usize = 0;
                    const last = data.len - 1;
                    try self.appendChain(data[0..last], tunnel_outbox_max, false);
                    for (data[0..last]) |bytes| n += bytes.len;
                    for (0..splat) |_| try self.appendChain(data[last..], tunnel_outbox_max, false);
                    return n + data[last].len * splat;
                }
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
                if (es.chain_mode) return self.endChain(trailer_fields);
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

            // -- A tunnel's or a parked response's chain (`ChainBlock`) ---

            /// Appends `parts` to the body in one copy (the nghttp2 engine's
            /// `appendOutbox` rule: waits while more than `max_pending`
            /// bytes are queued, and always takes a message when nothing
            /// is). With `now` they go out now; without, at `kickOut`.
            /// From any task: one on another executor hops to the
            /// connection's (`onOwner`). Not a tunnel or parked: through the
            /// body writer.
            fn appendParts(ptr: *anyopaque, parts: []const []const u8, max_pending: usize, now: bool) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                if (self.es.conn.foreign()) return self.onOwner(parts, max_pending, now);
                if (!self.es.chain_mode) {
                    for (parts) |part| try self.writer.writeAll(part);
                    if (now) try self.writer.flush();
                    return;
                }
                return self.appendChain(parts, max_pending, now);
            }

            /// Sends what `appendParts` left without a kick.
            fn kickOut(ptr: *anyopaque) void {
                const self = fromPtr(ptr);
                if (self.es.conn.foreign()) {
                    self.onOwner(null, 0, true) catch {};
                    return;
                }
                if (!self.es.chain_mode) {
                    self.writer.flush() catch {};
                    return;
                }
                self.kickChain() catch {};
            }

            /// `appendParts` (or `kickOut`, `parts` null) on the
            /// connection's executor, where its lock is (a WebSocket's
            /// `send` "from any task", websocket/root.zig): a task placed
            /// there, awaited (the pattern Rooms and SSE use to reach a
            /// socket's executor). `parts` are the caller's, alive till then.
            fn onOwner(self: *StreamSink, parts: ?[]const []const u8, max_pending: usize, now: bool) std.Io.Writer.Error!void {
                const conn = self.es.conn;
                if (comptime is_test) _ = test_hops.fetchAdd(1, .monotonic);
                var group: std.Io.Group = .init;
                var result: std.Io.Writer.Error!void = {};
                placement.concurrent(&group, conn.io, .{ .executor = conn.lock_.owner }, ownerRun, .{ self, parts, max_pending, now, &result }) catch
                    return self.fail(error.SystemResources);
                group.await(conn.io) catch {
                    group.cancel(conn.io);
                    return self.fail(error.Canceled);
                };
                return result;
            }

            fn ownerRun(self: *StreamSink, parts: ?[]const []const u8, max_pending: usize, now: bool, result: *std.Io.Writer.Error!void) std.Io.Cancelable!void {
                const p = parts orelse return kickOut(self);
                result.* = appendParts(self, p, max_pending, now);
            }

            fn appendChain(self: *StreamSink, parts: []const []const u8, max_pending: usize, now: bool) std.Io.Writer.Error!void {
                const es = self.es;
                const conn = es.conn;
                var total: usize = 0;
                for (parts) |part| total += part.len;
                if (total == 0) return;
                while (true) {
                    const seen = es.room.epoch();
                    {
                        conn.lock();
                        defer conn.unlock();
                        const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                        if (es.reset or conn.send_shut) return self.fail(error.ConnectionResetByPeer);
                        try self.submitHeadOnce(s);
                        _ = conn.chainReclaim(es);
                        const held = es.chain_bytes;
                        if (held == 0 or held + total <= max_pending) {
                            conn.chainAppend(es, parts) catch return self.fail(error.SystemResources);
                            if (now) conn.chainSubmit(es, s) catch |err| return self.submitFailed(err);
                            break;
                        }
                        // Full: what is queued goes out first, then the
                        // wait for its blocks to be written.
                        conn.chainSubmit(es, s) catch |err| return self.submitFailed(err);
                    }
                    conn.kickFlush();
                    es.room.wait(conn.io, seen) catch return self.fail(error.Canceled);
                }
                if (now) conn.kickFlush();
            }

            /// The head if not out yet, and what the chain holds past its
            /// last cut, out. On the connection's executor.
            fn kickChain(self: *StreamSink) std.Io.Writer.Error!void {
                const es = self.es;
                const conn = es.conn;
                {
                    conn.lock();
                    defer conn.unlock();
                    const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                    if (es.reset) return self.fail(error.ConnectionResetByPeer);
                    try self.submitHeadOnce(s);
                    conn.chainSubmit(es, s) catch |err| return self.submitFailed(err);
                }
                conn.kickFlush();
            }

            /// The end of a chain's body: the rest submitted, then END_STREAM
            /// on its last DATA (or an empty one), on the trailers, or on
            /// HEADERS when nothing went out. Output for the caller to flush.
            fn endChain(self: *StreamSink, trailer_fields: ?[]hpack.Field) std.Io.Writer.Error!void {
                const es = self.es;
                const conn = es.conn;
                conn.lock();
                defer conn.unlock();
                const s = es.cs orelse return self.fail(error.ConnectionResetByPeer);
                if (es.reset) return self.fail(error.ConnectionResetByPeer);
                es.ended = true;
                errdefer es.ended = false;
                if (!es.head_sent and trailer_fields == null) {
                    es.head_sent = true;
                    errdefer es.head_sent = false;
                    conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, true) catch |err| return self.submitFailed(err);
                    return;
                }
                try self.submitHeadOnce(s);
                conn.chainSubmit(es, s) catch |err| return self.submitFailed(err);
                if (trailer_fields) |t| {
                    conn.proto.submitTrailers(s, t) catch |err| return self.submitFailed(err);
                } else {
                    conn.proto.submitData(s, &.{}, true) catch |err| return self.submitFailed(err);
                }
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
