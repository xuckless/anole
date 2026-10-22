// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The HTTP/2 server engine, on nghttp2. A connection runs as
//!
//!   * the reader task (the connection's own task, which entered `serve`):
//!     reads the connection and feeds the nghttp2 session,
//!   * a writer task: waits until the session has output, takes it and
//!     writes it to the connection,
//!   * one task per stream: builds a `Request` and a sink-backed `Response`
//!     and runs the router (`Server.dispatch`), so HTTP/2 serves the same
//!     handlers and middleware as HTTP/1.x.
//!
//! The session is not reentrant, so one mutex serializes every `nghttp2_*`
//! call. Under it the session only computes (HPACK, framing, callbacks); the
//! socket I/O and the handlers run outside it. Over TLS the reader decrypts
//! and the writer encrypts through one `tls.Connection`, which must support
//! one concurrent reader plus one writer (tls.zig does).
//!
//! Request bodies: a per-stream queue sized to the stream window, allocated
//! on the first DATA frame. The session side can always put into it without
//! blocking (a peer past its window is a protocol error nghttp2 rejects
//! first), and the handler returns window credit as it reads.
//!
//! Response bodies: the handler writes into a per-stream queue and blocks
//! when it is full; the data provider takes from it without blocking and
//! defers the stream when it is empty. Trailers go out from the provider at
//! the end of the body (`nghttp2_submit_trailer`).
//!
//! The shape follows the h2-engine sketch on this repository (#137); the
//! data provider with deferred data and trailers follows grpc-lite's server
//! (MIT, github.com/fanyang89/grpc-lite, db3c400, src/server.zig).
const std = @import("std");
const build_options = @import("build_options");

const c = @import("nghttp2");
const http = @import("../http.zig");
const Connection = @import("../server.zig").Connection;
const linger_limit = @import("../server.zig").linger_limit;
const linger_timeout = @import("../server.zig").linger_timeout;
const Listener = @import("../config.zig").Listener;
const ServerConfig = @import("../config.zig").ServerConfig;
const Request = @import("../request.zig").Request;
const BodySource = @import("../request.zig").BodySource;
const Response = @import("../response.zig").Response;
const Detached = @import("../detach.zig").Detached;
const Sink = @import("../sink.zig").Sink;
const Transport = @import("../transport.zig").Transport;
const Timer = @import("../deadline.zig").Timer;
const placement = @import("../placement.zig");

const log = std.log.scoped(.anole_h2);

/// Tests only: runs between the round that takes frames from the session
/// and their write, so a test can hold frames there (h2_test.zig). Nothing
/// outside tests.
pub var test_before_flush: if (@import("builtin").is_test) ?*const fn (std.Io) std.Io.Cancelable!void else void =
    if (@import("builtin").is_test) null else {};

/// The client connection preface (RFC 9113 §3.4).
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// True when the connection opens with the HTTP/2 preface. Reads only while
/// what is buffered is still a prefix of it, so an HTTP/1.x request (which
/// cannot start with "PRI * HTTP/2.0") is never delayed past its first byte
/// that differs. The preface stays buffered; the session reads it.
pub fn sniffPreface(r: *std.Io.Reader) error{ReadFailed}!bool {
    while (true) {
        const have = r.buffered();
        const n = @min(have.len, preface.len);
        if (!std.mem.eql(u8, have[0..n], preface[0..n])) return false;
        if (n == preface.len) return true;
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

/// Spare streams a connection keeps for reuse.
const max_spare_streams = 16;
/// What a reused stream's arena keeps between requests: the queues and
/// buffers of an ordinary request with a body fit.
const arena_retain_limit = 128 * 1024;

/// Response body bytes queued per stream between the handler and the data
/// provider; a handler that gets this far ahead of the peer waits.
const out_queue_len = 32 * 1024;
/// The handler-side buffer in front of that queue.
const body_writer_len = 16 * 1024;

/// The PING sent with a drain's GOAWAY notice.
const drain_ping: [8]u8 = "dusty-go".*;

/// After the peer's side of the connection ended cleanly, while handlers
/// still run, how often the writer sends a PING to learn whether the peer
/// only half-closed (it may still read their responses) or is gone (the
/// write after its reset fails, and the handlers are canceled).
const half_close_probe_interval: std.Io.Duration = .fromMilliseconds(500);

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = @import("../server.zig").Server(Ctx);

        /// The server's open HTTP/2 connections, for the drain.
        pub const Registry = struct {
            mutex: std.Io.Mutex = .init,
            list: std.DoublyLinkedList = .{},

            fn server(r: *Registry) *Server {
                return @alignCast(@fieldParentPtr("h2_conns", r));
            }

            fn add(r: *Registry, conn: *Conn) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                r.list.append(&conn.node);
                r.mutex.unlock(io);
                // A drain that started before the append missed this one.
                // The flag was set before the drain took the registry, so
                // either it sees the connection or this sees the flag.
                if (r.server().busy.load(.acquire).draining) conn.beginDrain();
            }

            fn remove(r: *Registry, conn: *Conn) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                r.list.remove(&conn.node);
            }

            /// Sends every connection the drain's GOAWAY notice. Whether
            /// there were any.
            pub fn beginDrain(r: *Registry) bool {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                var it = r.list.first;
                while (it) |node| : (it = node.next) {
                    const conn: *Conn = @fieldParentPtr("node", node);
                    conn.beginDrain();
                }
                return r.list.first != null;
            }

            /// Sends the final GOAWAY to connections whose peer has not
            /// answered the notice's PING.
            pub fn finishDrain(r: *Registry) void {
                const io = r.server().io;
                r.mutex.lockUncancelable(io);
                defer r.mutex.unlock(io);
                var it = r.list.first;
                while (it) |node| : (it = node.next) {
                    const conn: *Conn = @fieldParentPtr("node", node);
                    conn.lock();
                    defer conn.unlock();
                    conn.finishDrainLocked();
                }
            }
        };

        /// One HTTP/2 connection: the session, its streams, and what the
        /// reader, writer and stream tasks share.
        const Conn = struct {
            server: *Server,
            connection: *Connection,
            listener: *const Listener,
            secure: bool,
            io: std.Io,
            allocator: std.mem.Allocator,
            config: ServerConfig.Http2,

            /// Serializes every nghttp2_* call, and guards everything below.
            /// Held only for computation, never across I/O.
            mutex: std.Io.Mutex = .init,
            session: ?*c.nghttp2_session = null,
            streams: std.AutoHashMapUnmanaged(i32, *Stream) = .empty,
            /// Finished streams kept for reuse with their arenas, so a
            /// connection's requests stop allocating once it is warm.
            spare_streams: std.ArrayList(*Stream) = .empty,
            /// Streams with a handler still running or a response still
            /// going out, each counted in the server's in-flight requests.
            open_streams: usize = 0,
            /// Set while the reader runs the session, so a stream whose head
            /// completes can be handed to a task in the connection's group.
            group: ?*std.Io.Group = null,
            /// The connection's group for its whole life: where a detached
            /// response that needs a task after all gets one
            /// (`Detached.attach`).
            tasks: ?*std.Io.Group = null,
            /// Requests of `no_wait` routes that arrived whole, for the
            /// reader to run once the session has taken the read. Only the
            /// reader touches it.
            ready: std.ArrayList(*Stream) = .empty,
            /// Requests of `no_wait` routes whose body is still coming: if
            /// it ends within the same read they run inline too, else they
            /// get a task once the session has taken the read, so a body is
            /// never held back waiting for a handler that is not reading it.
            awaiting: std.ArrayList(*Stream) = .empty,
            /// The server has `no_wait` routes and runs them inline.
            inline_ok: bool = false,
            /// The reader is done; the writer sends what is left and exits.
            closing: bool = false,
            /// The session is over and the writer has shut the send side
            /// (`shutSend`): what the peer still sends is not for the
            /// session, only for the lingering close to throw away.
            send_shut: bool = false,
            /// A GOAWAY went out because the server is draining.
            goaway_sent: bool = false,
            /// The drain's GOAWAY notice went out and the final one is not
            /// submitted yet.
            drain_notice: bool = false,
            /// The connection holds one count in the server's in-flight
            /// requests from the drain's notice until its final GOAWAY is
            /// written, so the drain's cancel cannot cut that off.
            drain_hold: bool = false,
            /// The final GOAWAY was handed to the writer; the hold goes
            /// once the writer has flushed it.
            drain_flush: bool = false,
            /// Streams that are done but whose last frames the writer may
            /// not have flushed yet. Each keeps its count in the server's
            /// in-flight requests until the writer has flushed everything it
            /// took before the stream finished (`settleFinished`): nghttp2
            /// closes a stream when the writer takes its last frame, before
            /// the write, and a drain that saw the count reach zero there
            /// would cancel the connection with the response still unsent.
            unflushed_finishes: usize = 0,
            /// The writer has ended: a stream that finishes gives its count
            /// back at once.
            writer_gone: bool = false,
            /// In `Registry`.
            node: std.DoublyLinkedList.Node = .{},

            /// Bumped (under the mutex) whenever the session may have output.
            /// The writer waits on it.
            write_gen: std.atomic.Value(u32) = .init(0),

            /// Drain, phase one: GOAWAY with the largest stream ID, which
            /// streams already on the way still fit under, and a PING whose
            /// answer says they have arrived. Takes the mutex.
            fn beginDrain(conn: *Conn) void {
                conn.lock();
                defer conn.unlock();
                if (conn.goaway_sent or conn.drain_notice or conn.closing) return;
                if (c.nghttp2_submit_shutdown_notice(conn.session) != 0) return;
                _ = c.nghttp2_submit_ping(conn.session, c.NGHTTP2_FLAG_NONE, &drain_ping);
                conn.drain_notice = true;
                conn.drain_hold = true;
                _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
                conn.kickWriter();
            }

            /// Drain, phase two: GOAWAY with the last stream taken. Once
            /// the open streams finish the session is done and the writer
            /// closes the connection. Under the mutex.
            fn finishDrainLocked(conn: *Conn) void {
                if (!conn.drain_notice) return;
                conn.drain_notice = false;
                if (!conn.goaway_sent and !conn.closing and
                    c.nghttp2_submit_goaway(conn.session, c.NGHTTP2_FLAG_NONE, c.nghttp2_session_get_last_proc_stream_id(conn.session), c.NGHTTP2_NO_ERROR, null, 0) == 0)
                {
                    conn.goaway_sent = true;
                    conn.kickWriter();
                    return; // the hold goes when the writer has flushed it
                }
                conn.releaseDrainHold();
            }

            /// Under the mutex.
            fn releaseDrainHold(conn: *Conn) void {
                if (!conn.drain_hold) return;
                conn.drain_hold = false;
                conn.drain_flush = false;
                conn.server.finishRequest();
            }

            /// SETTINGS_INITIAL_WINDOW_SIZE as the peer has acknowledged
            /// it. Until its ACK, streams open with the default window
            /// (65535), and the ACK then moves every open stream's window
            /// by the difference to `stream_window` (RFC 9113 §6.9.2), a
            /// raised one too. Under the mutex.
            fn ackedStreamWindow(conn: *Conn) u31 {
                return @intCast(c.nghttp2_session_get_local_settings(conn.session, c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE));
            }

            /// Gives back the counts of `n` finished streams, once the writer
            /// has flushed what it took up to their finish. Takes the mutex.
            fn settleFinished(conn: *Conn, n: usize) void {
                if (n == 0) return;
                conn.lock();
                conn.unflushed_finishes -= n;
                conn.unlock();
                for (0..n) |_| conn.server.finishRequest();
            }

            /// The writer has ended (or never started): what it still held
            /// is given back, and from now on a stream's count at once.
            /// Under the mutex.
            fn writerGone(conn: *Conn) void {
                conn.writer_gone = true;
                for (0..conn.unflushed_finishes) |_| conn.server.finishRequest();
                conn.unflushed_finishes = 0;
            }

            fn kickWriter(conn: *Conn) void {
                _ = conn.write_gen.fetchAdd(1, .release);
                conn.io.futexWake(u32, &conn.write_gen.raw, 1);
            }

            fn lock(conn: *Conn) void {
                conn.mutex.lockUncancelable(conn.io);
            }

            fn unlock(conn: *Conn) void {
                conn.mutex.unlock(conn.io);
            }

            fn initSession(conn: *Conn) !void {
                var callbacks: ?*c.nghttp2_session_callbacks = null;
                if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
                defer c.nghttp2_session_callbacks_del(callbacks);
                c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
                c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
                c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
                c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
                c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
                c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, onFrameSend);

                var option: ?*c.nghttp2_option = null;
                if (c.nghttp2_option_new(&option) != 0) return error.OutOfMemory;
                defer c.nghttp2_option_del(option);
                // Window credit is returned as handlers read (BodyReader).
                c.nghttp2_option_set_no_auto_window_update(option, 1);
                // The limits nghttp2 enforces itself, set here rather than
                // left to its defaults. The header list size is checked in
                // onHeader, against what SETTINGS advertised.
                c.nghttp2_option_set_stream_reset_rate_limit(option, conn.config.stream_reset_burst, conn.config.stream_reset_rate);
                c.nghttp2_option_set_max_continuations(option, conn.config.max_continuations);

                if (c.nghttp2_session_server_new2(&conn.session, callbacks, conn, option) != 0) return error.OutOfMemory;
                errdefer {
                    c.nghttp2_session_del(conn.session);
                    conn.session = null;
                }

                const iv = [_]c.nghttp2_settings_entry{
                    .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = conn.config.max_concurrent_streams },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = conn.config.stream_window },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = conn.config.max_header_list_size },
                    .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL, .value = 1 },
                };
                const count: usize = if (conn.config.enable_connect_protocol) iv.len else iv.len - 1;
                if (c.nghttp2_submit_settings(conn.session, c.NGHTTP2_FLAG_NONE, &iv, count) != 0) return error.OutOfMemory;
                if (conn.config.connection_window > 65535) {
                    _ = c.nghttp2_session_set_local_window_size(conn.session, c.NGHTTP2_FLAG_NONE, 0, conn.config.connection_window);
                }
            }
        };

        /// Who still needs a stream. Whichever lets go second frees it: the
        /// handler can outlive the protocol stream (a reset), and the
        /// protocol stream outlives the handler while the response drains.
        const Side = enum { handler, protocol };

        const Stream = struct {
            conn: *Conn,
            id: i32,
            /// Everything of the request's lives here; reset, keeping what
            /// it grew to, when the stream is reused.
            arena: std.heap.ArenaAllocator,

            // The request head, filled by the header callbacks before the
            // handler task starts.
            method: []const u8 = "",
            path: []const u8 = "",
            authority: []const u8 = "",
            scheme: []const u8 = "",
            /// `:protocol`, on an extended CONNECT (RFC 8441).
            connect_protocol: []const u8 = "",
            headers: std.ArrayList(Field) = .empty,
            /// Decoded header block size so far (RFC 9113 §6.5.2).
            header_list_size: usize = 0,

            /// Request body: DATA in, the handler out. Allocated on the
            /// first DATA frame; a request without a body never has one.
            body: ?std.Io.Queue(u8) = null,
            /// The stream's receive window, which the body queue holds:
            /// `stream_window`, raised to `stream_window_reading` once the
            /// handler reads. Zero until set (`window`).
            recv_window: u31 = 0,
            /// The request had no body at all (END_STREAM on its HEADERS),
            /// or its body has ended.
            body_done: bool = false,
            /// The peer reset the stream, or the connection went away.
            reset: bool = false,
            /// The handler's task while it runs, to cancel it when `reset`
            /// comes before the response is complete. Set and cleared by
            /// the task itself, under the mutex; null off zio.
            task: ?placement.Task = null,

            /// Response: what the handler's head was, and whether it has
            /// been submitted to the session.
            status: http.Status = .ok,
            response_nv: []c.nghttp2_nv = &.{},
            submitted: bool = false,
            /// A `no_wait` route's request with its body still coming, in
            /// `Conn.awaiting`.
            await_body: bool = false,
            /// The handler runs on the connection's reader (a `no_wait`
            /// route), which must never wait for the writer: its body goes
            /// to `backlog`, which grows as needed, instead of the queue.
            inline_mode: bool = false,
            backlog: std.ArrayList(u8) = .empty,
            backlog_pos: usize = 0,
            /// The handler detached the response (`Response.detach`): the
            /// request and response live on in the stream's arena, and the
            /// handler's hold on the stream goes when it is finished or
            /// aborted.
            detached: ?*Exchange = null,

            /// Response body: the handler in, the data provider out.
            out: ?std.Io.Queue(u8) = null,
            /// Or a whole body in memory (`StreamSink.complete`), which the
            /// provider takes in order: `parts[part][part_offset..]` is next.
            parts: []const []const u8 = &.{},
            part: usize = 0,
            part_offset: usize = 0,
            /// Trailers for the provider to send after the body.
            trailer_nv: []c.nghttp2_nv = &.{},
            /// The handler ended the response.
            ended: bool = false,

            handler_done: bool = false,
            protocol_done: bool = false,
            /// Counted in the server's in-flight requests (by `startStream`)
            /// until it is freed.
            counted: bool = false,
            /// The frame that ends the response went out.
            response_sent: bool = false,
            /// The handler is done and the response is out, but the peer is
            /// still sending a body: what arrives is consumed and dropped,
            /// up to `discard_left` bytes, then the stream is reset.
            discarding: bool = false,
            discard_left: usize = 0,

            const Field = struct { name: []const u8, value: []const u8 };

            fn window(stream: *const Stream) u31 {
                return if (stream.recv_window != 0) stream.recv_window else stream.conn.config.stream_window;
            }

            /// The handler reads the body: the stream's window grows to
            /// `stream_window_reading`, and the body queue with it, so the
            /// session can still always put a whole window. Under the
            /// mutex.
            fn raiseWindow(stream: *Stream) void {
                const conn = stream.conn;
                const want = conn.config.stream_window_reading;
                if (stream.recv_window != 0 or want <= conn.config.stream_window) return;
                stream.recv_window = conn.config.stream_window;
                if (stream.body_done or stream.reset or stream.discarding) return;
                // Until the peer's ACK of SETTINGS, what is queued may be up
                // to the default window, and the ACK still moves this one.
                const acked = conn.ackedStreamWindow();
                const buf = stream.arena.allocator().alloc(u8, @max(want, acked)) catch return;
                var bigger: std.Io.Queue(u8) = .init(buf);
                if (stream.body) |*q| {
                    // What is queued moves over, in order; nobody else gets
                    // from it (this is the handler), and the session puts
                    // only under the mutex.
                    var scratch: [4096]u8 = undefined;
                    while (true) {
                        const n = q.getUncancelable(conn.io, &scratch, 0) catch break;
                        if (n == 0) break;
                        _ = bigger.putUncancelable(conn.io, scratch[0..n], 0) catch unreachable;
                    }
                }
                // Less by what that ACK will add, so the window lands on
                // `want` and never holds more than the queue.
                const pending = if (conn.config.stream_window > acked) conn.config.stream_window - acked else 0;
                if (c.nghttp2_session_set_local_window_size(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, want - pending) != 0) return;
                stream.body = bigger;
                stream.recv_window = want;
                conn.kickWriter();
            }

            /// A stream from the connection's spares (its arena reset, with
            /// what it grew to kept), or a new one. Under the mutex.
            fn create(conn: *Conn, id: i32) !*Stream {
                if (conn.spare_streams.pop()) |stream| {
                    var arena = stream.arena;
                    _ = arena.reset(.{ .retain_with_limit = arena_retain_limit });
                    stream.* = .{ .conn = conn, .id = id, .arena = arena };
                    return stream;
                }
                const stream = try conn.allocator.create(Stream);
                stream.* = .{ .conn = conn, .id = id, .arena = .init(conn.allocator) };
                return stream;
            }

            /// Frees the stream and its arena for good.
            fn destroy(stream: *Stream, allocator: std.mem.Allocator) void {
                var arena = stream.arena;
                arena.deinit();
                allocator.destroy(stream);
            }

            /// Drops one side's hold, under the mutex. The second frees it.
            fn release(stream: *Stream, side: Side) void {
                switch (side) {
                    .handler => stream.handler_done = true,
                    .protocol => stream.protocol_done = true,
                }
                if (!(stream.handler_done and stream.protocol_done)) return;
                const conn = stream.conn;
                _ = conn.streams.remove(stream.id);
                if (stream.counted) {
                    conn.open_streams -= 1;
                    if (conn.writer_gone) {
                        conn.server.finishRequest();
                    } else {
                        conn.unflushed_finishes += 1;
                        conn.kickWriter();
                    }
                }
                if (conn.spare_streams.items.len < max_spare_streams) {
                    if (conn.spare_streams.append(conn.allocator, stream)) |_| return else |_| {}
                }
                stream.destroy(conn.allocator);
            }

            /// No more request body: the stream ended or was reset.
            fn closeBody(stream: *Stream) void {
                stream.body_done = true;
                if (stream.body) |*q| q.close(stream.conn.io);
            }

            /// The stream is reset or the connection gone before the
            /// handler ended its response: cancel the handler, so a wait it
            /// is in (a timer, a database call, a full queue) returns
            /// `error.Canceled` instead of running on for nobody. Under the
            /// mutex, which the task takes to clear `task` before it ends.
            fn cancelHandler(stream: *Stream) void {
                if (stream.ended or stream.handler_done) return;
                if (stream.task) |task| placement.cancelTask(task);
            }
        };

        /// Runs HTTP/2 over an initialized connection. The calling task is
        /// the reader; the writer and the streams run in a group torn down
        /// before this returns. `busy` is the connection's count in the
        /// server's in-flight requests, given back here: from now on each
        /// open stream is counted instead.
        pub fn serve(server: *Server, listener: *const Listener, secure: bool, connection: *Connection, busy: *bool) !void {
            if (busy.*) {
                busy.* = false;
                server.finishRequest();
            }

            // The connection's buffers for its whole life: the reader's must
            // hold what the session has not consumed yet, the writer's
            // batches frames into one write.
            const buffers = try server.request_buffers.acquire(@intFromPtr(connection));
            defer server.request_buffers.release(buffers);
            connection.useReadBuffer(buffers.read_buffer);
            connection.prepareWrite();
            if (connection.writer.buffer.len == 0) return error.OutOfMemory;
            defer connection.releaseWriteBuffer();

            var conn: Conn = .{
                .server = server,
                .connection = connection,
                .listener = listener,
                .secure = secure or connection.proxied_secure,
                .io = server.io,
                .allocator = server.allocator,
                .config = server.config.http2,
                .inline_ok = server.config.http2.inline_no_wait and server.router.has_no_wait,
            };
            defer conn.ready.deinit(conn.allocator);
            defer conn.awaiting.deinit(conn.allocator);
            try conn.initSession();
            server.h2_conns.add(&conn);
            defer {
                server.h2_conns.remove(&conn);
                conn.lock();
                defer conn.unlock();
                // A drain still holding the server: give back its count.
                conn.drain_notice = false;
                conn.releaseDrainHold();
                conn.writerGone();
                // The tasks are joined (the group's cancel runs first), so
                // each release here is the freeing one.
                while (true) {
                    var it = conn.streams.valueIterator();
                    const stream = (it.next() orelse break).*;
                    stream.reset = true;
                    stream.closeBody();
                    // A detached response nobody finished: its owner hears
                    // of it and lets go of the request, which may free the
                    // stream; the loop looks again.
                    if (stream.detached != null) {
                        abortDetached(stream);
                        continue;
                    }
                    // No handler task is left (a stream whose head never
                    // completed never had one), so this frees it.
                    stream.handler_done = true;
                    stream.release(.protocol);
                }
                conn.streams.deinit(conn.allocator);
                for (conn.spare_streams.items) |stream| stream.destroy(conn.allocator);
                conn.spare_streams.deinit(conn.allocator);
                c.nghttp2_session_del(conn.session);
                conn.session = null;
            }

            var group: std.Io.Group = .init;
            defer group.cancel(conn.io);
            conn.tasks = &group;
            // The writer and the streams stay on the connection's executor.
            try placement.concurrent(&group, conn.io, .local, writerLoop, .{&conn});

            var reader_failed = false;
            // Whether the peer's side may still be open, with input the
            // session will not read: the session ended first (a GOAWAY
            // either way, or a protocol error).
            var linger = false;
            if (readerLoop(&conn, &group)) |end| {
                linger = end == .done;
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

            // Let the writer send what the session still has (a GOAWAY after
            // a protocol error, the last responses), then stop. No more
            // request body can arrive, so a handler waiting for one is told
            // the stream is gone rather than left to its timeout, and is
            // canceled. After a clean end of the peer's side (which may be
            // a half-close) a handler with its whole request keeps running,
            // for a response that may still go out; after a read error the
            // connection is gone, and every handler is canceled.
            {
                conn.lock();
                defer conn.unlock();
                conn.closing = true;
                var it = conn.streams.valueIterator();
                var gone: std.ArrayList(*Stream) = .empty;
                defer gone.deinit(conn.allocator);
                while (it.next()) |stream| {
                    if (reader_failed or !stream.*.body_done) {
                        stream.*.reset = true;
                        stream.*.closeBody();
                        stream.*.cancelHandler();
                        if (stream.*.detached != null) gone.append(conn.allocator, stream.*) catch {};
                    }
                }
                // Detached responses with nobody left to send them to: let
                // go of them now rather than at their deadline. (Out of the
                // iteration: the abort may free the stream.)
                for (gone.items) |stream| abortDetached(stream);
            }
            conn.kickWriter();
            group.await(conn.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            if (linger) try lingeringClose(&conn);
        }

        /// Hangs up on a peer whose side is still open once the session is
        /// over, so the peer still gets the last frames. Closing with input
        /// unread makes the kernel send a reset instead of a FIN, and a
        /// reset can make the peer throw away the GOAWAY it has not read
        /// yet; a peer that sent a GOAWAY may also still send a PING
        /// (h2spec 3.8, 7). So, as HTTP/1.x's `lingeringClose`: close_notify
        /// under TLS and the send side shut (the writer did both if it saw
        /// the session end), then what the peer sends is thrown away until
        /// it hangs up, `linger_timeout` passes, or `linger_limit` bytes.
        /// Skipped where the timer cannot bound the reads. The engine's
        /// tasks have ended, so this is the only reader and writer.
        fn lingeringClose(conn: *Conn) std.Io.Cancelable!void {
            var timer: Timer = .init(null);
            if (!timer.canBound()) return;
            if (!try shutSend(conn)) return;
            timer.set(conn.io, .{ .duration = .{ .raw = linger_timeout, .clock = .awake } });
            defer timer.clear(conn.io);
            _ = conn.connection.reader.discardShort(linger_limit) catch {
                // The peer hanging up is the end this waits for, and any
                // other failure has been reported by the reader already.
                // The deadline arrives as a cancel, and stays one.
                if (conn.connection.getReadError()) |cause| if (cause == error.Canceled) return error.Canceled;
            };
        }

        /// Ends the server's side of the connection, once: close_notify
        /// under TLS (bounded by `linger_timeout`: a peer that stopped
        /// reading must not hold the task on it), then the send side shut,
        /// so the peer reads a clean end after the last frame. Only from
        /// the side that writes: the writer while it runs, the connection's
        /// task after. Whether the peer may still be there to read from.
        ///
        /// A cancel that arrives here is passed on, never dropped. The drain
        /// cancels the connection as soon as its final GOAWAY is flushed,
        /// which can land just before the shutdown below; a cancel taken
        /// there and dropped left the send side open and the writer's wait
        /// in `awaitReader` no longer cancelable, so the peer saw the end
        /// only `linger_timeout` later.
        fn shutSend(conn: *Conn) std.Io.Cancelable!bool {
            {
                conn.lock();
                defer conn.unlock();
                if (conn.send_shut) return true;
                conn.send_shut = true;
            }
            {
                var timer: Timer = .init(null);
                if (timer.canBound()) timer.set(conn.io, .{ .duration = .{ .raw = linger_timeout, .clock = .awake } });
                defer timer.clear(conn.io);
                // A cancel in close_notify's write (the teardown's, or the
                // bound here for a peer that stopped reading): end both
                // directions, so the reader stops too, and pass it on.
                conn.connection.closeNotify() catch |err| {
                    conn.connection.stream.shutdown(conn.io, .both) catch {};
                    return err;
                };
            }
            conn.connection.stream.shutdown(conn.io, .send) catch |err| switch (err) {
                // Already gone: nothing left to throw away.
                error.SocketUnconnected, error.ConnectionResetByPeer, error.ConnectionAborted => return false,
                error.Canceled => return error.Canceled,
                else => {},
            };
            return true;
        }

        /// How the reader ended: the peer ended its side (`eof`), or the
        /// session did, with the peer's side still open (`done`).
        const ReaderEnd = enum { eof, done };

        /// Reads the connection and feeds the session until the peer is
        /// done or the session wants nothing more. Holds the keepalive
        /// deadline while no stream is open.
        fn readerLoop(conn: *Conn, group: *std.Io.Group) !ReaderEnd {
            const reader = conn.connection.reader;
            var timer: Timer = .init(null);
            defer timer.clear(conn.io);
            while (true) {
                const buffered = reader.buffered();
                if (buffered.len > 0) {
                    const consumed = consumed: {
                        conn.lock();
                        defer conn.unlock();
                        // The writer closed the session's side already.
                        if (conn.send_shut) return .done;
                        conn.group = group;
                        defer conn.group = null;
                        const rv = c.nghttp2_session_mem_recv2(conn.session, buffered.ptr, buffered.len);
                        if (conn.awaiting.items.len > 0) startAwaiting(conn);
                        if (rv < 0) {
                            log.debug("HTTP/2 session: {s}", .{c.nghttp2_strerror(@intCast(rv))});
                            // nghttp2 queued a GOAWAY for a protocol error;
                            // the writer sends it on the way out.
                            return error.Http2ProtocolError;
                        }
                        break :consumed @as(usize, @intCast(rv));
                    };
                    reader.toss(consumed);
                    // The requests that run inline answer before the one
                    // kick, so their responses share the next write.
                    if (conn.ready.items.len > 0) try runInline(conn);
                    conn.kickWriter();

                    conn.lock();
                    const done = conn.send_shut or (c.nghttp2_session_want_read(conn.session) == 0 and
                        c.nghttp2_session_want_write(conn.session) == 0);
                    conn.unlock();
                    if (done) return .done;
                    continue;
                }

                conn.lock();
                const idle = conn.open_streams == 0;
                conn.unlock();
                if (idle) {
                    if (conn.server.config.timeout.keepalive) |d| {
                        timer.set(conn.io, .{ .duration = .{ .raw = d, .clock = .awake } });
                    } else timer.clear(conn.io);
                } else timer.clear(conn.io);

                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return .eof,
                    error.ReadFailed => return conn.connection.getReadError() orelse error.Unexpected,
                };
            }
        }

        fn writerLoop(conn: *Conn) std.Io.Cancelable!void {
            // Nothing goes out once the writer is gone, so a handler blocked
            // on a full response queue is let go, and any handler still
            // working on a response is canceled.
            defer {
                conn.lock();
                defer conn.unlock();
                conn.writerGone();
                var it = conn.streams.valueIterator();
                while (it.next()) |stream| {
                    stream.*.reset = true;
                    if (stream.*.out) |*q| q.close(conn.io);
                    stream.*.cancelHandler();
                }
            }
            runWriter(conn) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (!Connection.isPeerGone(err)) log.info("HTTP/2 write error: {}", .{err});
                    // Nothing more can go out; stop the reader too.
                    conn.connection.stream.shutdown(conn.io, .both) catch {};
                },
            };
        }

        /// Takes the session's output under the mutex, a frame at a time,
        /// and writes it outside. A frame from `mem_send2` is valid only
        /// until the next call, so it is copied straight into the
        /// connection's write buffer, where it waits for the one write of
        /// this round. A frame that does not fit there (a full DATA frame,
        /// or the buffer filled up) goes to `spill`, which the writer frees
        /// whenever it runs out of output, so an idle connection holds none.
        fn runWriter(conn: *Conn) !void {
            var spill: std.ArrayList(u8) = .empty;
            defer spill.deinit(conn.allocator);
            const writer = conn.connection.writer;
            var probed = false;
            while (true) {
                const gen = conn.write_gen.load(.acquire);
                var closing = false;
                // Streams finished by the time this round's frames were
                // taken: their counts go back once those frames are flushed.
                var settled: usize = 0;
                {
                    conn.lock();
                    defer conn.unlock();
                    defer settled = conn.unflushed_finishes;
                    closing = conn.closing;
                    while (true) {
                        var data: [*c]const u8 = undefined;
                        const n = c.nghttp2_session_mem_send2(conn.session, &data);
                        if (n < 0) return error.Http2ProtocolError;
                        if (n == 0) break;
                        const frame = data[0..@intCast(n)];
                        const room = writer.unusedCapacitySlice();
                        if (spill.items.len == 0 and frame.len <= room.len) {
                            @memcpy(room[0..frame.len], frame);
                            writer.advance(frame.len);
                            continue;
                        }
                        try spill.appendSlice(conn.allocator, frame);
                        if (spill.items.len >= 64 * 1024) break;
                    }
                }
                if (writer.end > 0 or spill.items.len > 0) {
                    if (comptime @import("builtin").is_test) if (test_before_flush) |hook| try hook(conn.io);
                    if (spill.items.len > 0) {
                        writer.writeAll(spill.items) catch return conn.connection.getWriteError() orelse error.Unexpected;
                        spill.clearRetainingCapacity();
                    }
                    writer.flush() catch return conn.connection.getWriteError() orelse error.Unexpected;
                    conn.settleFinished(settled);
                    // The drain's final GOAWAY is on the wire now.
                    if (@atomicLoad(bool, &conn.drain_flush, .acquire)) {
                        conn.lock();
                        defer conn.unlock();
                        if (conn.drain_flush) conn.releaseDrainHold();
                    }
                    continue;
                }
                // Nothing taken this round: whatever came before is flushed.
                conn.settleFinished(settled);
                // The session is over (a GOAWAY went out, for a protocol
                // error or after the last stream of a closing session, or
                // came in with no stream open) and wants neither to read
                // nor to write: close the connection (RFC 9113 §5.4.1).
                conn.lock();
                const finished = c.nghttp2_session_want_read(conn.session) == 0 and
                    c.nghttp2_session_want_write(conn.session) == 0;
                // With the reader gone (the peer closed, or only half-closed
                // its side), a handler still running may yet have a response
                // to send: stay for it rather than drop it. A stream whose
                // head never completed has no handler (`counted` is set
                // when one starts), so nothing is coming from it.
                var handlers_running = false;
                if (closing) {
                    var it = conn.streams.valueIterator();
                    while (it.next()) |stream| {
                        if (stream.*.counted and !stream.*.handler_done) handlers_running = true;
                    }
                }
                conn.unlock();
                if (finished) {
                    _ = try shutSend(conn);
                    return awaitReader(conn);
                }
                if (closing and !handlers_running) return;
                // Nothing to send: the spill's memory goes back while the
                // connection waits.
                spill.clearAndFree(conn.allocator);
                if (closing) {
                    // A peer that closed the whole connection answers the
                    // probe with a TCP reset, so the next write fails;
                    // one that half-closed reads it and stays served.
                    if (probed) {
                        try conn.io.futexWaitTimeout(u32, &conn.write_gen.raw, gen, .{ .duration = .{ .raw = half_close_probe_interval, .clock = .awake } });
                        if (conn.write_gen.load(.acquire) != gen) continue;
                    }
                    probed = true;
                    conn.lock();
                    _ = c.nghttp2_submit_ping(conn.session, c.NGHTTP2_FLAG_NONE, null);
                    conn.unlock();
                    continue;
                }
                try conn.io.futexWait(u32, &conn.write_gen.raw, gen);
            }
        }

        /// After the writer shut the send side: the peer, seeing the end,
        /// hangs up, which ends the reader's wait; then the lingering close
        /// takes over. A peer that stays has `linger_timeout`, then the
        /// receive side is shut too, which ends the wait regardless.
        fn awaitReader(conn: *Conn) std.Io.Cancelable!void {
            const deadline = (std.Io.Timeout{ .duration = .{ .raw = linger_timeout, .clock = .awake } }).toDeadline(conn.io);
            const at = deadline.toTimestamp(conn.io).?;
            while (true) {
                const gen = conn.write_gen.load(.acquire);
                conn.lock();
                const closing = conn.closing;
                conn.unlock();
                if (closing) return;
                if (std.Io.Clock.Timestamp.now(conn.io, at.clock).compare(.gte, at)) {
                    conn.connection.stream.shutdown(conn.io, .both) catch {};
                    return;
                }
                try conn.io.futexWaitTimeout(u32, &conn.write_gen.raw, gen, deadline);
            }
        }

        // -- One stream: a request in, a response out --------------------

        fn runStream(conn: *Conn, stream: *Stream) std.Io.Cancelable!void {
            // Published for `cancelHandler`, and taken back under the mutex
            // before the task ends, so a cancel never reaches a task that
            // is gone.
            const task = placement.currentTask(conn.io);
            const gone = gone: {
                conn.lock();
                defer conn.unlock();
                stream.task = task;
                break :gone stream.reset;
            };
            defer {
                conn.lock();
                defer conn.unlock();
                stream.task = null;
                if (stream.response_sent and !stream.body_done and !stream.reset) startDiscard(conn, stream);
                stream.release(.handler);
                conn.kickWriter();
            }
            // Reset before its task got to run: nobody wants the response.
            if (gone) {
                log.debug("HTTP/2 stream {d} reset before its handler started", .{stream.id});
                return;
            }
            _ = serveStream(conn, stream, false) catch |err| return streamFailed(conn, stream, err);
        }

        /// Runs the requests `onFrameRecv` set aside for the reader
        /// (`no_wait` routes), in the order they arrived.
        fn runInline(conn: *Conn) error{Canceled}!void {
            defer conn.ready.clearRetainingCapacity();
            for (conn.ready.items) |stream| {
                conn.lock();
                const gone = stream.reset;
                conn.unlock();
                var canceled = false;
                var detached = false;
                if (!gone) {
                    if (serveStream(conn, stream, true)) |served| {
                        detached = served == .detached;
                    } else |err| {
                        streamFailed(conn, stream, err) catch {
                            canceled = true;
                        };
                    }
                }
                // A detached response keeps the stream until it is finished.
                if (!detached) {
                    conn.lock();
                    stream.release(.handler);
                    conn.unlock();
                }
                // The reader itself is canceled: the connection is going.
                if (canceled) return error.Canceled;
            }
        }

        /// What a handler's error means for its stream. `error.Canceled`
        /// when the handler's own task was canceled for another reason
        /// than the stream's reset, to pass on.
        fn streamFailed(conn: *Conn, stream: *Stream, err: anyerror) error{Canceled}!void {
            if (err == error.Canceled) {
                conn.lock();
                const reset = stream.reset;
                conn.unlock();
                // Canceled because the peer reset the stream or the
                // connection went away: the stream is over already.
                if (reset) {
                    log.debug("HTTP/2 stream {d}: handler canceled, the stream was reset", .{stream.id});
                    return;
                }
                resetStream(conn, stream, c.NGHTTP2_CANCEL);
                return error.Canceled;
            }
            // `Response.abort`: the reset is the abort.
            if (err == error.ResponseAborted) {
                log.debug("HTTP/2 stream {d}: response aborted", .{stream.id});
                resetStream(conn, stream, c.NGHTTP2_CANCEL);
                return;
            }
            if (stream.reset or err == error.ConnectionResetByPeer) {
                log.debug("HTTP/2 stream {d} reset: {}", .{ stream.id, err });
            } else {
                log.err("HTTP/2 stream {d}: {}", .{ stream.id, err });
                resetStream(conn, stream, c.NGHTTP2_INTERNAL_ERROR);
            }
        }

        fn resetStream(conn: *Conn, stream: *Stream, code: u32) void {
            conn.lock();
            defer conn.unlock();
            if (stream.reset) return;
            stream.reset = true;
            _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, code);
            conn.kickWriter();
        }

        /// One request and its response, with what they point at: on the
        /// handler's stack, or in the stream's arena for a request that
        /// runs on the reader, whose response may be detached.
        const Exchange = struct {
            request: Request,
            response: Response,
            sink_state: StreamSink,
            body_reader: BodyReader,
        };

        const Served = enum { done, detached };

        /// Serves one request. `inline_mode`: on the connection's reader
        /// (a `no_wait` route), with no request timeout, whose timer would
        /// cancel the reader; its response may be detached (`Detached`),
        /// and then the stream is held until it is finished.
        fn serveStream(conn: *Conn, stream: *Stream, inline_mode: bool) !Served {
            const server = conn.server;
            const arena = stream.arena.allocator();
            const io = conn.io;

            var timer: Timer = .init(null);
            defer timer.clear(io);
            if (!inline_mode) if (server.config.timeout.request) |d| timer.set(io, .{ .duration = .{ .raw = d, .clock = .awake } });

            // On the stack (warm, no allocation); `detachedRelocate` moves
            // it to the stream's arena if the handler detaches.
            var on_stack: Exchange = undefined;
            const ex: *Exchange = &on_stack;
            const request = &ex.request;
            request.* = .{
                .arena = arena,
                .io = io,
                .parser = undefined,
                .transport = undefined,
                .config = server.config.request,
                .listener = conn.listener,
                .secure = conn.secure,
                .peer_certificate = conn.connection.peerCertificate(),
                .version_major = 2,
                .version_minor = 0,
                .drain = &server.draining,
                .drain_hooks = &server.drain_hooks,
                ._timeout_context = if (inline_mode) null else &timer,
                ._set_timeout = if (inline_mode) null else setTimeout,
            };
            const body_reader = &ex.body_reader;
            body_reader.* = .init(stream);
            request.body_source = .{ .reader = &body_reader.interface, .err = BodyReader.errorOf };

            const sink_state = &ex.sink_state;
            sink_state.* = .{ .stream = stream };
            const response = &ex.response;
            response.* = try Response.initSink(arena, io, sink_state.sink(), server.config.response.max_header_count);
            server.configureResponse(response);
            var detached = false;
            defer if (!detached) response.deinit();
            response.request = request;
            request.response = response;
            if (inline_mode) {
                response.detach_engine = &detach_engine;
                response.detach_ctx = ex;
            }

            request.method = parseMethod(stream.method) orelse {
                response.status = .not_implemented;
                {
                    try response.write();
                    return .done;
                }
            };
            // An extended CONNECT (RFC 8441; nghttp2 has checked its pseudo
            // headers) is routed as the GET that the HTTP/1.1 upgrade it
            // replaces would be.
            if (request.method == .connect and stream.connect_protocol.len > 0) {
                request.method = .get;
                request.protocol = stream.connect_protocol;
            }
            response.head = request.method == .head;
            request.url = stream.path;

            request.headers = http.Headers.init(arena, server.config.request.max_header_count) catch return error.OutOfMemory;
            var too_many = false;
            // Repeated fields stay separate entries, as over HTTP/1.1,
            // except cookie crumbs, joined into one (RFC 9113 §8.2.3).
            var hosts: usize = 0;
            var host_field: []const u8 = "";
            for (stream.headers.items) |f| {
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
            if (!too_many and (hosts > 1 or (hosts == 1 and stream.authority.len > 0 and
                !std.ascii.eqlIgnoreCase(host_field, stream.authority))))
            {
                response.status = .bad_request;
                {
                    try response.write();
                    return .done;
                }
            }
            if (!too_many and hosts == 0 and stream.authority.len > 0) {
                request.headers.add("Host", stream.authority) catch {
                    too_many = true;
                };
            }
            if (too_many) {
                response.status = .request_header_fields_too_large;
                {
                    try response.write();
                    return .done;
                }
            }
            request.applyEntityHeaders();
            // A body declared longer than allowed is refused unread; the
            // engine drops or resets the rest of the stream.
            if (server.config.request.max_content_length) |max| {
                if (request.content_length) |len| if (len > max) {
                    response.status = .payload_too_large;
                    response.content_type = .text;
                    response.body = "413 Content Too Large\n";
                    {
                    try response.write();
                    return .done;
                }
                };
            }
            server.applyForwarded(request, conn.connection);

            if (request.headers.get("Expect")) |expect| {
                if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                    request.expects_continue = !stream.body_done;
                } else {
                    response.status = .expectation_failed;
                    {
                    try response.write();
                    return .done;
                }
                }
            }

            log.debug("Received (h2 stream {d}): {f} {s}", .{ stream.id, request.method, request.url });

            server.dispatch(request, response) catch |err| switch (err) {
                error.ReadFailed => return body_reader.err orelse error.Unexpected,
                error.WriteFailed => return sink_state.writeErr() orelse error.Unexpected,
                else => |e| return e,
            };
            if (response.detached) |d| {
                // Finished later (`detach_engine`), from the moved copy;
                // the stream is held till then.
                detached = true;
                conn.lock();
                stream.detached = exchangeOf(d);
                conn.unlock();
                return .detached;
            }
            try response.write();
            return .done;
        }

        /// How a detached response is finished, attached to a task, or let
        /// go (`Detached`).
        const detach_engine: Detached.Engine = .{ .relocate = detachedRelocate, .end = detachedEnd, .attach = detachedAttach, .enter = detachedEnter };

        /// The exchange, from the reader's stack into the stream's arena,
        /// its pointers into itself moved along.
        fn detachedRelocate(d: *Detached) error{OutOfMemory}!*anyopaque {
            const old = exchangeOf(d);
            const ex = try old.response.arena.create(Exchange);
            ex.* = old.*;
            ex.request.response = &ex.response;
            ex.response.request = &ex.request;
            ex.request.body_source = .{ .reader = &ex.body_reader.interface, .err = BodyReader.errorOf };
            ex.response.sink = ex.sink_state.sink();
            ex.response.detach_ctx = ex;
            d.request = &ex.request;
            d.response = &ex.response;
            return ex;
        }

        fn exchangeOf(d: *Detached) *Exchange {
            return @ptrCast(@alignCast(d.engine_ctx));
        }

        /// Writes the response (or handles `result`'s error as a handler's),
        /// then lets go of the stream. On the connection's executor: the
        /// owner's task, or the task `detachedAttach` was for.
        fn detachedEnd(d: *Detached, result: anyerror!void) void {
            const ex = exchangeOf(d);
            const stream = ex.sink_state.stream;
            const conn = stream.conn;
            if (result) |_| {
                ex.response.write() catch |err| {
                    streamFailed(conn, stream, err) catch {};
                };
            } else |err| {
                streamFailed(conn, stream, err) catch {};
            }
            ex.response.deinit();
            conn.lock();
            defer conn.unlock();
            stream.detached = null;
            stream.task = null;
            stream.release(.handler);
            conn.kickWriter();
        }

        /// The response goes on from a task: its body writes may now wait
        /// for the peer, as a handler task's do.
        fn detachedAttach(d: *Detached) *std.Io.Group {
            const ex = exchangeOf(d);
            const stream = ex.sink_state.stream;
            const conn = stream.conn;
            conn.lock();
            defer conn.unlock();
            stream.inline_mode = false;
            return conn.tasks.?;
        }

        fn detachedEnter(d: *Detached) void {
            const ex = exchangeOf(d);
            const stream = ex.sink_state.stream;
            const conn = stream.conn;
            conn.lock();
            defer conn.unlock();
            stream.task = placement.currentTask(conn.io);
        }

        /// The stream ended with its response still detached (not
        /// attached): the owner hears of it, and the stream is let go.
        /// Under the mutex.
        fn abortDetached(stream: *Stream) void {
            const ex = stream.detached orelse return;
            const d = ex.response.detached.?;
            if (d.state != .detached) return;
            stream.detached = null;
            d.abort();
            ex.response.deinit();
            stream.release(.handler);
        }

        fn setTimeout(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
            const timer: *Timer = @ptrCast(@alignCast(context));
            timer.set(io, timeout);
        }

        fn parseMethod(name: []const u8) ?http.Method {
            var lower: [16]u8 = undefined;
            if (name.len == 0 or name.len > lower.len) return null;
            return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&lower, name));
        }

        /// The request body, read from the stream's queue. Returns window
        /// credit for what the handler takes, so a stream's flow-control
        /// window is the handler's pace.
        const BodyReader = struct {
            stream: *Stream,
            interface: std.Io.Reader,
            err: ?Transport.ReadError = null,

            fn init(stream: *Stream) BodyReader {
                return .{ .stream = stream, .interface = .{
                    .vtable = &.{ .stream = streamFn },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                } };
            }

            fn errorOf(r: *std.Io.Reader) ?Transport.ReadError {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                return self.err;
            }

            fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                const stream = self.stream;
                const conn = stream.conn;
                // The body queue appears with the first DATA frame; until
                // then, or for a request with no body, wait for one or the end.
                const queue = blk: {
                    while (true) {
                        conn.lock();
                        stream.raiseWindow();
                        const q = if (stream.body) |*q| q else null;
                        const done = stream.body_done;
                        const reset = stream.reset;
                        conn.unlock();
                        if (reset) return self.fail(error.ConnectionResetByPeer);
                        if (q) |queue| break :blk queue;
                        if (done) return error.EndOfStream;
                        // A DATA frame or the end wakes the writer generation.
                        const gen = conn.write_gen.load(.acquire);
                        conn.lock();
                        const ready = stream.body != null or stream.body_done or stream.reset;
                        conn.unlock();
                        if (ready) continue;
                        conn.io.futexWait(u32, &conn.write_gen.raw, gen) catch return self.fail(error.Canceled);
                    }
                };
                const dest = limit.slice(try w.writableSliceGreedy(1));
                if (dest.len == 0) return 0;
                const n = queue.get(conn.io, dest, 1) catch |err| switch (err) {
                    error.Closed => {
                        conn.lock();
                        const reset = stream.reset;
                        conn.unlock();
                        if (reset) return self.fail(error.ConnectionResetByPeer);
                        return error.EndOfStream;
                    },
                    error.Canceled => return self.fail(error.Canceled),
                };
                w.advance(n);
                conn.lock();
                _ = c.nghttp2_session_consume(conn.session, stream.id, n);
                conn.unlock();
                conn.kickWriter();
                return n;
            }

            fn fail(self: *BodyReader, err: Transport.ReadError) std.Io.Reader.StreamError {
                self.err = err;
                return error.ReadFailed;
            }
        };

        /// The response side of a stream, for `Response.initSink`.
        const StreamSink = struct {
            stream: *Stream,
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

            /// A whole response in memory: the head and the body submitted
            /// together, with the body read straight from where it lies. The
            /// stream ends on the last DATA frame, or on HEADERS when there
            /// is no body.
            fn complete(
                ptr: *anyopaque,
                status: http.Status,
                headers: *const http.Headers,
                content_length: ?usize,
                parts: []const []const u8,
                trailers: ?*const http.Headers,
            ) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const conn = stream.conn;
                const arena = stream.arena.allocator();
                try head(ptr, status, headers, content_length);
                const trailer_nv = try self.trailerFields(trailers);
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
                stream.parts = list;
                stream.trailer_nv = trailer_nv;
                stream.ended = true;
                try self.submit(list.len > 0 or trailer_nv.len > 0);
            }

            /// The trailers as nghttp2 fields, in the stream's arena.
            fn trailerFields(self: *StreamSink, trailers: ?*const http.Headers) std.Io.Writer.Error![]c.nghttp2_nv {
                const t = trailers orelse return &.{};
                const arena = self.stream.arena.allocator();
                var trailer_nv: std.ArrayList(c.nghttp2_nv) = .empty;
                var it = t.iterator();
                while (it.next()) |entry| {
                    const name = lowerName(arena, entry.key) catch return self.fail(error.SystemResources);
                    trailer_nv.append(arena, ownedField(name, entry.value, false)) catch return self.fail(error.SystemResources);
                }
                return trailer_nv.items;
            }

            fn fromPtr(ptr: *anyopaque) *StreamSink {
                return @ptrCast(@alignCast(ptr));
            }

            fn writeErr(self: *StreamSink) ?Response.SendError {
                return self.err;
            }

            fn fail(self: *StreamSink, err: Response.SendError) std.Io.Writer.Error {
                self.err = err;
                return error.WriteFailed;
            }

            /// Records the head. It goes out with the first body bytes, a
            /// flush (a streamed response), or the end, whichever is first,
            /// so a response with no body is one HEADERS frame.
            fn head(ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const arena = stream.arena.allocator();
                stream.status = status;
                // Sized once: the status, every header, and a length.
                const nv = arena.alloc(c.nghttp2_nv, headers.count() + 2) catch return self.fail(error.SystemResources);
                var count: usize = 0;
                nv[count] = ownedField(":status", statusText(status), true);
                count += 1;
                var has_length = false;
                var it = headers.iterator();
                while (it.next()) |entry| {
                    // RFC 9113 §8.2.2: connection-specific fields are malformed.
                    if (isConnectionSpecific(entry.key)) continue;
                    if (std.ascii.eqlIgnoreCase(entry.key, "content-length")) has_length = true;
                    const name = lowerName(arena, entry.key) catch return self.fail(error.SystemResources);
                    // The value may be the handler's, and the head can be
                    // submitted while the handler runs on: nghttp2 copies it.
                    nv[count] = ownedField(name, entry.value, false);
                    count += 1;
                }
                if (!has_length and statusHasLength(status)) {
                    if (content_length) |len| {
                        const text = std.fmt.allocPrint(arena, "{d}", .{len}) catch return self.fail(error.SystemResources);
                        nv[count] = ownedField("content-length", text, true);
                        count += 1;
                    }
                }
                stream.response_nv = nv[0..count];
            }

            fn interim(ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const conn = stream.conn;
                var status_buf: [3]u8 = undefined;
                const text = std.fmt.bufPrint(&status_buf, "{d}", .{@backingInt(status)}) catch unreachable;
                const nva = [_]c.nghttp2_nv{field(":status", text)};
                conn.lock();
                defer conn.unlock();
                if (stream.reset) return self.fail(error.ConnectionResetByPeer);
                if (c.nghttp2_submit_headers(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, null, &nva, nva.len, null) != 0)
                    return self.fail(error.Unexpected);
                conn.kickWriter();
            }

            fn body(ptr: *anyopaque) *std.Io.Writer {
                const self = fromPtr(ptr);
                if (self.writer.buffer.len == 0) {
                    // A handler that never writes a body never pays for it.
                    self.writer.buffer = self.stream.arena.allocator().alloc(u8, body_writer_len) catch &.{};
                }
                return &self.writer;
            }

            /// Submits the head with a data provider, once. Under the mutex.
            fn submit(self: *StreamSink, with_body: bool) std.Io.Writer.Error!void {
                const stream = self.stream;
                const conn = stream.conn;
                if (stream.submitted) return;
                if (stream.reset) return self.fail(error.ConnectionResetByPeer);
                var provider: c.nghttp2_data_provider2 = .{
                    .source = .{ .ptr = stream },
                    .read_callback = provideData,
                };
                const rv = c.nghttp2_submit_response2(
                    conn.session,
                    stream.id,
                    stream.response_nv.ptr,
                    stream.response_nv.len,
                    if (with_body) &provider else null,
                );
                if (rv != 0) {
                    log.debug("HTTP/2 submit_response2: {s}", .{c.nghttp2_strerror(rv)});
                    return self.fail(error.ConnectionResetByPeer);
                }
                stream.submitted = true;
                conn.kickWriter();
            }

            /// Sends the head now even with no body bytes yet, so a stream
            /// that stays open (an RFC 8441 tunnel, event stream) gets its
            /// HEADERS out before the first DATA. `std.Io.Writer`'s default
            /// flush only drains buffered bytes.
            fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                const stream = self.stream;
                const conn = stream.conn;
                {
                    conn.lock();
                    defer conn.unlock();
                    if (stream.out == null and !stream.inline_mode) {
                        const buf = stream.arena.allocator().alloc(u8, out_queue_len) catch return self.fail(error.SystemResources);
                        stream.out = .init(buf);
                    }
                    try self.submit(true);
                }
                try self.put(w.buffered());
                w.end = 0;
            }

            /// Moves body bytes into the stream's queue, blocking while it
            /// is full: the peer is behind, or out of window.
            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                const stream = self.stream;
                const conn = stream.conn;
                {
                    conn.lock();
                    defer conn.unlock();
                    if (stream.out == null and !stream.inline_mode) {
                        const buf = stream.arena.allocator().alloc(u8, out_queue_len) catch return self.fail(error.SystemResources);
                        stream.out = .init(buf);
                    }
                    try self.submit(true);
                }
                try self.put(w.buffered());
                w.end = 0;
                var n: usize = 0;
                if (data.len > 0) {
                    for (data[0 .. data.len - 1]) |bytes| {
                        try self.put(bytes);
                        n += bytes.len;
                    }
                    const pattern = data[data.len - 1];
                    for (0..splat) |_| {
                        try self.put(pattern);
                        n += pattern.len;
                    }
                }
                return n;
            }

            fn put(self: *StreamSink, bytes: []const u8) std.Io.Writer.Error!void {
                if (bytes.len == 0) return;
                const stream = self.stream;
                const conn = stream.conn;
                if (stream.inline_mode) {
                    // On the reader: never wait for the writer, which may
                    // need the reader to take a WINDOW_UPDATE first. The
                    // reader kicks the writer when its inline requests are
                    // done.
                    conn.lock();
                    defer conn.unlock();
                    if (stream.reset) return self.fail(error.ConnectionResetByPeer);
                    stream.backlog.appendSlice(stream.arena.allocator(), bytes) catch return self.fail(error.SystemResources);
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    return;
                }
                var rest = bytes;
                while (rest.len > 0) {
                    // At most a queue's worth at a time, so the provider is
                    // resumed while the rest waits.
                    const n = stream.out.?.put(conn.io, rest, 1) catch |err| switch (err) {
                        error.Closed => return self.fail(error.ConnectionResetByPeer),
                        error.Canceled => return self.fail(error.Canceled),
                    };
                    rest = rest[n..];
                    conn.lock();
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    conn.unlock();
                    conn.kickWriter();
                }
            }

            fn end(ptr: *anyopaque, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const stream = self.stream;
                const conn = stream.conn;
                const trailer_nv = try self.trailerFields(trailers);
                conn.lock();
                defer conn.unlock();
                stream.trailer_nv = trailer_nv;
                stream.ended = true;
                if (stream.out) |*q| {
                    q.close(conn.io);
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    conn.kickWriter();
                    return;
                }
                // An inline stream's body went out through its backlog.
                if (stream.submitted) {
                    _ = c.nghttp2_session_resume_data(conn.session, stream.id);
                    conn.kickWriter();
                    return;
                }
                // No body went out: one HEADERS frame, or HEADERS then
                // trailers through a provider that has nothing to send.
                try self.submit(stream.trailer_nv.len > 0);
            }

            fn writeError(ptr: *anyopaque) ?Response.SendError {
                return fromPtr(ptr).err;
            }

            fn peerGone(ptr: *anyopaque) bool {
                const stream = fromPtr(ptr).stream;
                stream.conn.lock();
                defer stream.conn.unlock();
                return stream.reset;
            }
        };

        fn field(name: []const u8, value: []const u8) c.nghttp2_nv {
            return .{
                .name = @constCast(name.ptr),
                .namelen = name.len,
                .value = @constCast(value.ptr),
                .valuelen = value.len,
                .flags = c.NGHTTP2_NV_FLAG_NONE,
            };
        }

        /// A field whose name is lowercase and lives as long as the stream
        /// (a literal, or in the stream's arena), so nghttp2 neither copies
        /// nor lowercases it; the value too, when `value_owned`.
        fn ownedField(name: []const u8, value: []const u8, value_owned: bool) c.nghttp2_nv {
            return .{
                .name = @constCast(name.ptr),
                .namelen = name.len,
                .value = @constCast(value.ptr),
                .valuelen = value.len,
                .flags = @intCast(c.NGHTTP2_NV_FLAG_NO_COPY_NAME |
                    if (value_owned) c.NGHTTP2_NV_FLAG_NO_COPY_VALUE else c.NGHTTP2_NV_FLAG_NONE),
            };
        }

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

        /// The three digits of a status code, as a literal.
        fn statusText(status: http.Status) []const u8 {
            const code: usize = @backingInt(status);
            if (code < 100 or code > 999) return "500";
            const table = comptime blk: {
                @setEvalBranchQuota(10_000);
                var t: [900][3]u8 = undefined;
                for (&t, 100..) |*digits, n| {
                    digits.* = .{ '0' + n / 100, '0' + n / 10 % 10, '0' + n % 10 };
                }
                break :blk t;
            };
            return &table[code - 100];
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

        // -- nghttp2 callbacks. Each runs inside an nghttp2_* call, with the
        // -- connection's mutex held by the calling task.

        fn connFrom(user_data: ?*anyopaque) *Conn {
            return @ptrCast(@alignCast(user_data.?));
        }

        fn streamFor(session: ?*c.nghttp2_session, id: i32) ?*Stream {
            const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        fn onBeginHeaders(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            if (frame.*.hd.type != c.NGHTTP2_HEADERS or frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
            const id = frame.*.hd.stream_id;

            // A draining server takes no new requests: refuse the stream,
            // which the client can safely retry elsewhere, and say so once
            // with GOAWAY. Between the drain's notice and its final GOAWAY
            // streams are still taken: the peer may have sent them before
            // it saw the notice.
            if (conn.server.busy.load(.acquire).draining and !conn.drain_notice) {
                if (!conn.goaway_sent) {
                    conn.goaway_sent = true;
                    _ = c.nghttp2_submit_goaway(session, c.NGHTTP2_FLAG_NONE, c.nghttp2_session_get_last_proc_stream_id(session), c.NGHTTP2_NO_ERROR, null, 0);
                }
                _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_REFUSED_STREAM);
                return 0;
            }

            const stream = Stream.create(conn, id) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            conn.streams.put(conn.allocator, id, stream) catch {
                stream.destroy(conn.allocator);
                return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            };
            _ = c.nghttp2_session_set_stream_user_data(session, id, stream);
            return 0;
        }

        fn onHeader(
            session: ?*c.nghttp2_session,
            frame: [*c]const c.nghttp2_frame,
            name_ptr: [*c]const u8,
            name_len: usize,
            value_ptr: [*c]const u8,
            value_len: usize,
            flags: u8,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            _ = user_data;
            const stream = streamFor(session, frame.*.hd.stream_id) orelse return 0;
            // Trailers on a request are not passed on.
            if (frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
            stream.header_list_size += name_len + value_len + 32;
            if (stream.header_list_size > stream.conn.config.max_header_list_size) {
                // Past what SETTINGS_MAX_HEADER_LIST_SIZE allowed: the stream
                // is reset and never reaches a handler.
                return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            const arena = stream.arena.allocator();
            const name = name_ptr[0..name_len];
            const value = arena.dupe(u8, value_ptr[0..value_len]) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            if (std.mem.eql(u8, name, ":method")) {
                stream.method = value;
            } else if (std.mem.eql(u8, name, ":path")) {
                stream.path = value;
            } else if (std.mem.eql(u8, name, ":authority")) {
                stream.authority = value;
            } else if (std.mem.eql(u8, name, ":scheme")) {
                stream.scheme = value;
            } else if (std.mem.eql(u8, name, ":protocol")) {
                stream.connect_protocol = value;
            } else if (name.len > 0 and name[0] != ':') {
                const name_copy = arena.dupe(u8, name) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
                stream.headers.append(arena, .{ .name = name_copy, .value = value }) catch return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            return 0;
        }

        fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            const hd = frame.*.hd;
            // The answer to the drain notice's PING: everything the peer
            // sent before it saw the notice is in.
            if (hd.type == c.NGHTTP2_PING and hd.flags & c.NGHTTP2_FLAG_ACK != 0) {
                const data: [8]u8 = frame.*.ping.opaque_data;
                if (std.mem.eql(u8, &data, &drain_ping)) conn.finishDrainLocked();
                return 0;
            }
            const stream = streamFor(session, hd.stream_id) orelse return 0;
            const end_stream = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
            switch (hd.type) {
                c.NGHTTP2_HEADERS => {
                    if (frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
                        if (end_stream) stream.closeBody();
                        if (conn.inline_ok and noWaitRoute(conn, stream)) {
                            if (end_stream) {
                                queueInline(conn, stream);
                            } else if (conn.awaiting.append(conn.allocator, stream)) |_| {
                                stream.await_body = true;
                            } else |_| startStream(conn, stream);
                        } else startStream(conn, stream);
                    } else if (end_stream) {
                        stream.closeBody(); // trailers end the body
                        bodyEnded(conn, stream);
                    }
                },
                c.NGHTTP2_DATA => if (end_stream) {
                    stream.closeBody();
                    bodyEnded(conn, stream);
                },
                else => {},
            }
            conn.kickWriter(); // also wakes a body reader waiting for its queue
            return 0;
        }

        /// The head is complete: count the stream in flight and give it a
        /// task.
        fn startStream(conn: *Conn, stream: *Stream) void {
            const group = conn.group orelse return;
            _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            conn.open_streams += 1;
            stream.counted = true;
            placement.concurrent(group, conn.io, .local, runStream, .{ conn, stream }) catch {
                log.err("HTTP/2: no task for stream {d}", .{stream.id});
                stream.reset = true;
                stream.closeBody();
                stream.release(.handler);
                _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, c.NGHTTP2_REFUSED_STREAM);
            };
        }

        /// Whether the request's route was registered `no_wait`. An
        /// extended CONNECT never is: it is a tunnel, whatever it routes as.
        fn noWaitRoute(conn: *Conn, stream: *Stream) bool {
            const method = parseMethod(stream.method) orelse return false;
            if (method == .connect) return false;
            return conn.server.router.noWait(method, stream.path);
        }

        /// The head is complete, the request whole and its route `no_wait`:
        /// count the stream in flight and leave it for the reader to run
        /// (`runInline`) once the session has taken the read.
        fn queueInline(conn: *Conn, stream: *Stream) void {
            conn.ready.append(conn.allocator, stream) catch return startStream(conn, stream);
            _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            conn.open_streams += 1;
            stream.counted = true;
            stream.inline_mode = true;
        }

        /// The body of a request set aside in `awaiting` is whole: it runs
        /// inline after all.
        fn bodyEnded(conn: *Conn, stream: *Stream) void {
            if (!stream.await_body) return;
            stream.await_body = false;
            queueInline(conn, stream);
        }

        /// After a read: the `no_wait` requests whose body did not end in
        /// it get a task, as any other request; one reset meanwhile is let
        /// go. Under the mutex, with the group set.
        fn startAwaiting(conn: *Conn) void {
            defer conn.awaiting.clearRetainingCapacity();
            for (conn.awaiting.items) |stream| {
                if (!stream.await_body) continue;
                stream.await_body = false;
                if (stream.reset) {
                    stream.release(.handler);
                    continue;
                }
                startStream(conn, stream);
            }
        }

        /// Notes when the frame that ends a response is out. If the handler
        /// is done and the request body is still coming, the rest of it is
        /// discarded (`startDiscard`). Done here rather than when the handler
        /// returns, since nghttp2 sends RST_STREAM ahead of a response still
        /// queued, which would cut it off.
        fn onFrameSend(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            const hd = frame.*.hd;
            // The drain's final GOAWAY (not its notice) left the session.
            if (hd.type == c.NGHTTP2_GOAWAY and conn.drain_hold and !conn.drain_notice and
                frame.*.goaway.last_stream_id != std.math.maxInt(i32))
            {
                @atomicStore(bool, &conn.drain_flush, true, .release);
                return 0;
            }
            if (hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0) return 0;
            if (hd.type != c.NGHTTP2_HEADERS and hd.type != c.NGHTTP2_DATA) return 0;
            const stream = streamFor(session, hd.stream_id) orelse return 0;
            stream.response_sent = true;
            if (stream.handler_done and !stream.body_done and !stream.reset) startDiscard(conn, stream);
            return 0;
        }

        /// The response is complete and nobody will read the rest of the
        /// request body. Like dusty's HTTP/1.x drain, a little more of it is
        /// read and dropped, so a peer still sending a small body sees a
        /// clean end and its later frames are still checked; past one stream
        /// window the stream ends with RST_STREAM(NO_ERROR) (RFC 9113 §8.1).
        /// Under the mutex.
        fn startDiscard(conn: *Conn, stream: *Stream) void {
            if (stream.discarding) return;
            // A tunnel (RFC 8441) whose handler is done has nothing left to
            // read: end it now rather than wait for a peer that may keep its
            // side open, and the stream (and a drain) with it.
            if (stream.connect_protocol.len > 0) {
                if (stream.reset) return;
                stream.reset = true;
                _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, stream.id, c.NGHTTP2_NO_ERROR);
                stream.closeBody();
                conn.kickWriter();
                return;
            }
            stream.discarding = true;
            stream.discard_left = stream.window();
            // What is queued was never credited back: credit it now.
            if (stream.body) |*q| {
                var scratch: [4096]u8 = undefined;
                while (true) {
                    const n = q.getUncancelable(conn.io, &scratch, 0) catch break;
                    if (n == 0) break;
                    _ = c.nghttp2_session_consume(conn.session, stream.id, n);
                }
            }
            conn.kickWriter();
        }

        fn onDataChunk(
            session: ?*c.nghttp2_session,
            flags: u8,
            stream_id: i32,
            data: [*c]const u8,
            len: usize,
            user_data: ?*anyopaque,
        ) callconv(.c) c_int {
            _ = flags;
            const conn = connFrom(user_data);
            const stream = streamFor(session, stream_id) orelse return 0;
            if (stream.body_done) return 0;
            if (stream.discarding) {
                _ = c.nghttp2_session_consume(session, stream_id, len);
                if (len >= stream.discard_left) {
                    stream.discard_left = 0;
                    _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, stream_id, c.NGHTTP2_NO_ERROR);
                } else stream.discard_left -= len;
                return 0;
            }
            if (stream.body == null) {
                // A whole window: before the peer's ACK of SETTINGS that is
                // still the default one, which may be the larger.
                const size = @max(stream.window(), conn.ackedStreamWindow());
                const buf = stream.arena.allocator().alloc(u8, size) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
                stream.body = .init(buf);
            }
            // Cannot block: the queue holds a whole window, and the peer may
            // not send past it.
            const put = stream.body.?.putUncancelable(conn.io, data[0..len], 0) catch |err| switch (err) {
                // The handler is gone; the bytes are dropped with the stream.
                error.Closed => return 0,
            };
            if (put != len) return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onStreamClose(session: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connFrom(user_data);
            const stream = streamFor(session, stream_id) orelse return 0;
            if (error_code != c.NGHTTP2_NO_ERROR or !stream.ended) stream.reset = true;
            stream.closeBody();
            if (stream.out) |*q| q.close(conn.io);
            if (stream.reset) stream.cancelHandler();
            // Reset with its response detached: the owner lets go now.
            if (stream.reset) abortDetached(stream);
            stream.release(.protocol);
            conn.kickWriter();
            return 0;
        }

        /// Data provider: takes what the handler queued without waiting.
        /// Empty and not ended defers the stream until the handler resumes
        /// it; ended sends the end, with the trailers if there are any. The
        /// end goes on the frame with the last bytes, not on an empty one
        /// after them.
        fn provideData(
            session: ?*c.nghttp2_session,
            stream_id: i32,
            buf: [*c]u8,
            length: usize,
            data_flags: [*c]u32,
            source: [*c]c.nghttp2_data_source,
            user_data: ?*anyopaque,
        ) callconv(.c) c.nghttp2_ssize {
            const conn = connFrom(user_data);
            const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
            if (stream.out) |*q| {
                const n = q.getUncancelable(conn.io, buf[0..length], 0) catch |err| switch (err) {
                    error.Closed => return finish(session, stream_id, stream, data_flags, 0),
                };
                // Once the handler has ended the response nothing more is
                // put (the queue is closed and nobody waits to put), so an
                // empty queue is the end of the body.
                if (n > 0) {
                    if (stream.ended and q.type_erased.len == 0) return finish(session, stream_id, stream, data_flags, n);
                    return @intCast(n);
                }
                if (!stream.ended) return c.NGHTTP2_ERR_DEFERRED;
                return finish(session, stream_id, stream, data_flags, 0);
            }
            if (stream.inline_mode and stream.parts.len == 0) {
                const pending = stream.backlog.items[stream.backlog_pos..];
                const n = @min(pending.len, length);
                @memcpy(buf[0..n], pending[0..n]);
                stream.backlog_pos += n;
                if (stream.backlog_pos == stream.backlog.items.len) {
                    stream.backlog.clearRetainingCapacity();
                    stream.backlog_pos = 0;
                }
                if (n > 0) {
                    if (stream.ended and stream.backlog.items.len == 0) return finish(session, stream_id, stream, data_flags, n);
                    return @intCast(n);
                }
                if (!stream.ended) return c.NGHTTP2_ERR_DEFERRED;
                return finish(session, stream_id, stream, data_flags, 0);
            }
            var n: usize = 0;
            while (n < length and stream.part < stream.parts.len) {
                const rest = stream.parts[stream.part][stream.part_offset..];
                const take = @min(rest.len, length - n);
                @memcpy(buf[n..][0..take], rest[0..take]);
                n += take;
                if (take == rest.len) {
                    stream.part += 1;
                    stream.part_offset = 0;
                } else stream.part_offset += take;
            }
            if (stream.part < stream.parts.len) return @intCast(n);
            return finish(session, stream_id, stream, data_flags, n);
        }

        fn finish(session: ?*c.nghttp2_session, stream_id: i32, stream: *Stream, data_flags: [*c]u32, n: usize) c.nghttp2_ssize {
            data_flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
            if (stream.trailer_nv.len > 0) {
                data_flags.* |= c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
                if (c.nghttp2_submit_trailer(session, stream_id, stream.trailer_nv.ptr, stream.trailer_nv.len) != 0)
                    return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            }
            return @intCast(n);
        }
    };
}
