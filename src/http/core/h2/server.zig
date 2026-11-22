//! The HTTP/2 server engine on Anole's own protocol core (conn.zig;
//! research/h2h3-takeover/PLAN.md §3.3-§3.5).
//! A connection runs as
//!
//!   * the reader (the connection's own task, which entered `serve`): reads,
//!     feeds `Conn.recv`, runs the `no_wait` requests that came whole in the
//!     read (`runInline`), then writes one batch of output itself;
//!   * one task per other stream (`runStream`): builds a `Request` and a
//!     sink-backed `Response` and runs the router, so handlers and middleware are unchanged;
//!   * a flusher task, only while output is left over (`flusherRun`).
//!
//! There is no writer task. Output goes out under a **flush token**
//! (`Conn.writer`): whoever takes it writes `Conn.pending` until it is
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
//! sized by `BodyBuf`; a streamed response in at most
//! two 16 KiB blocks. A stream's arena, body and blocks are reused or freed
//! only once `out` no longer borrows them (`retiring`).
//!
//! **Seams** (PLAN §3.5): detached
//! responses (the C ABI's; `detach_engine`), parked ones (SSE; `H2Parked`)
//! and RFC 8441 tunnels (WebSocket over HTTP/2). Tunnel and parked output is
//! copied into a chain of blocks on the stream (`ChainBlock`), each let go
//! once written. Output from outside the connection's tasks (a detached
//! answer from the C ABI's task, a burst, a tunnel send from another task)
//! is only queued and handed to the flusher (`kickFlush`), never written on
//! the caller, which serves other requests (h2o's request_gathered_write, Go
//! x/net/http2's writeFrameFromHandler).
//!
//! **Lifecycle** (PLAN §3.3 "Timers", §3.5 "Drain"): a
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

const conn_mod = @import("conn.zig");
const fields = @import("fields.zig");
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
const LocalArena = @import("../arena.zig").LocalArena;
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

/// A request body up to this long comes from the stream's arena.
const arena_body_max = 4 * 1024;
/// Request header entries a stream's table starts with (h2load sends one,
/// a browser a dozen); it grows up to `max_header_count`.
const initial_header_room = 8;
/// Spare streams a connection keeps for reuse.
const max_spare_streams = 128;
const min_spare_streams = 16;
/// What a stream's arena keeps between requests (an 8 KiB malloc class with the arena's node header). Not a smaller
/// first node grown on demand: SmpAllocator resizes only within a class,
/// so every stream that grew would leave its old node on a free list that
/// nothing in steady state reuses (research/s2/h2-m4/heap.md).
pub const arena_retain_limit = 8 * 1024 - 4 * @sizeOf(usize);
/// A streamed response's block: the body writer's buffer, then borrowed by
/// `out` until written. Two per stream on a task.
const block_len = 16 * 1024;
/// Iovecs per `pending` round. Rounds go into the connection's buffered
/// writer back to back, with one flush at the end (`writeOut`).
const max_vecs = 64;
/// The PING sent with a drain's GOAWAY notice.
const drain_ping: [8]u8 = "anole-go".*;
/// After the peer's side of the connection ended cleanly, while handlers
/// still run, how often a PING asks whether the peer only half-closed (it
/// may still read their responses) or is gone (the write after its reset
/// fails, and the handlers are canceled).
const half_close_probe_interval: std.Io.Duration = .fromMilliseconds(500);
const probe_ping: [8]u8 = "anole-hc".*;
/// The most bytes a tunnel or a parked response may have queued for the
/// peer before its send waits, when the caller names no limit.
const tunnel_outbox_max = 1024 * 1024;

const is_test = builtin.is_test;

/// What a test counts or hooks in the engine. Process-global, shared by every
/// test as the old `test_*` variables were (tests compare deltas).
pub const Counter = enum {
    /// Handler tasks spawned (`spawnTasked`).
    spawned,
    /// Flusher tasks spawned.
    flushers,
    /// Tasks inside a write now, and the most ever at once.
    writers_in,
    max_writers,
    /// `out` released by an idle connection.
    out_releases,
    /// Reads the reader fed to `Conn.recv`.
    reads,
    /// Response blocks allocated (`StreamSink`).
    blocks,
    /// The trim epoch, in place of `Server.trim_epoch`.
    trim_epoch,
    /// Streaming body writers handed out (`StreamSink.body`).
    sink_bodies,
    /// Chain blocks alive (tunnels, parked responses).
    chain_blocks,
    /// Sends that hopped to the connection's executor.
    hops,
    /// Writes cut at `timeout.write`.
    write_timeouts,
    /// Finished responses reset at their send deadline.
    send_resets,
    /// Idle waits that could not park for a partial frame.
    park_refused_partial,
    /// Connections parked, and read buffers held now.
    parks,
    read_buffers,
    /// Connections closed at their keep-alive deadline.
    keepalive_closes,
    /// Flushers asked for after the connection's group was joined.
    late_flushers,
    /// Send-deadline waiters started (`waitSends`), and send sides shut at a
    /// connection's end (`shutDrained`, `lingeringClose`).
    send_waiters,
    send_shuts,
    /// The most arena one stream's exchange used, read before its reset.
    arena_high,
    /// Streams let go (`maybeFree`), to the spares or freed.
    freed,
    /// The arena the last stream put back to the spares kept.
    arena_kept,
};

/// Tests only: the counters and the hooks tests set. A release build has
/// `NoProbe`, whose methods compile to nothing.
pub const Probe = struct {
    counts: std.EnumArray(Counter, std.atomic.Value(usize)) = .initFill(.init(0)),
    /// Called once the connection's group is joined for the last time
    /// (`closeRun`'s join, the teardown's cancel), where nothing may join it
    /// any more.
    after_join: ?*const fn () void = null,
    /// Called on the reader once a read ended in a connection error, with
    /// the lock let go and before the GOAWAY's flush, with the connection
    /// (`Engine.testWakeRooms` takes it).
    on_conn_error: ?*const fn (*anyopaque) void = null,
    /// In place of `limits.Limits.out_high`.
    out_high: ?usize = null,
    /// When set, a hopped send waits on it (cancelably) on the connection's
    /// executor before it runs, to hold the hop open.
    hop_hold: std.atomic.Value(?*std.Io.Event) = .init(null),
    /// Whether the last connection served ran lock-free.
    lock_free: std.atomic.Value(bool) = .init(false),

    pub fn at(p: *Probe, c: Counter) *std.atomic.Value(usize) {
        return p.counts.getPtr(c);
    }
    pub inline fn bump(p: *Probe, c: Counter) void {
        _ = p.add(c, 1);
    }
    /// The new value.
    pub inline fn add(p: *Probe, c: Counter, n: usize) usize {
        return p.at(c).fetchAdd(n, .acq_rel) + n;
    }
    pub inline fn sub(p: *Probe, c: Counter, n: usize) void {
        _ = p.at(c).fetchSub(n, .acq_rel);
    }
    pub inline fn max(p: *Probe, c: Counter, n: usize) void {
        _ = p.at(c).fetchMax(n, .acq_rel);
    }
    pub inline fn store(p: *Probe, c: Counter, n: usize) void {
        p.at(c).store(n, .release);
    }
    /// `conn` is past its last join: marks it, then runs the hook.
    pub inline fn afterJoin(p: *Probe, conn: anytype) void {
        conn.test_joined = true;
        if (p.after_join) |hook| hook();
    }
    pub inline fn onConnError(p: *Probe, conn: anytype) void {
        if (p.on_conn_error) |hook| hook(conn);
    }
    pub inline fn outHigh(p: *Probe, limits: anytype) void {
        if (p.out_high) |v| limits.out_high = v;
    }
    pub inline fn holdHop(p: *Probe, io: std.Io) std.Io.Cancelable!void {
        if (p.hop_hold.load(.acquire)) |ev| try ev.wait(io);
    }
    pub inline fn setLockFree(p: *Probe, free: bool) void {
        p.lock_free.store(free, .monotonic);
    }
};

const NoProbe = struct {
    pub inline fn bump(_: NoProbe, _: Counter) void {}
    pub inline fn add(_: NoProbe, _: Counter, _: usize) usize {
        return 0;
    }
    pub inline fn sub(_: NoProbe, _: Counter, _: usize) void {}
    pub inline fn max(_: NoProbe, _: Counter, _: usize) void {}
    pub inline fn store(_: NoProbe, _: Counter, _: usize) void {}
    pub inline fn afterJoin(_: NoProbe, _: anytype) void {}
    pub inline fn onConnError(_: NoProbe, _: anytype) void {}
    pub inline fn outHigh(_: NoProbe, _: anytype) void {}
    pub inline fn holdHop(_: NoProbe, _: std.Io) std.Io.Cancelable!void {}
    pub inline fn setLockFree(_: NoProbe, _: bool) void {}
};

pub var probe: if (is_test) Probe else NoProbe = .{};

comptime {
    if (!is_test) std.debug.assert(@sizeOf(@TypeOf(probe)) == 0);
}

/// The HPACK scratch `Conn.recv` decodes into, one per executor (recv never
/// yields), from the block cache and never given back.
threadlocal var scratch_block: []align(16) u8 = &.{};

const Field = struct { name: []const u8, value: []const u8 };

/// An `EStream`'s response side, one value. Every change is a row here:
/// add a phase or an event as a row of `next`, never as a flag beside it.
///
///   state      head        end      wait        drained
///   none       head_sent   ended    none        none
///   head_sent  head_sent   ended    head_sent   head_sent
///   ended      ended       ended    waiting     ended
///   waiting    waiting     waiting  waiting     ended
///
/// head:    the final head (no END_STREAM) is in `proto` (`submitHeadOnce`;
///          a 1xx `interim` is no event).
/// end:     the last frame is about to be submitted (`complete`, `end`,
///          `endChain`). Before the submit: END_STREAM on a stream whose
///          peer half is closed closes it inside the call, and
///          `onStreamClose` must see a normal end.
/// wait:    the handler is done, the end is whole, but its last frames may
///          wait for the peer's credit: counted in `Conn.send_waits`, with
///          a send deadline (`finishHandler`).
/// drained: those frames are out, or never will be (`Conn.sendDone`).
///
/// `head` and `end` in ended/waiting are not reached (a response ends
/// once, before its handler is done); a late one keeps `waiting`, so
/// `send_waits` stays right. `wait` outside `ended` is a no-op (a handler
/// that returned without ending is reset, not waited for), and so is
/// `drained` outside `waiting`. A submit that fails is no event: the value
/// saved before it is put back. A reset is no phase either: the
/// stream-level `EStream.reset` is read by the request side too, and an
/// ended response that is reset must still read as ended (`cancelHandler`,
/// `onStreamClose`). The values make `isEnded` one compare.
pub const Resp = enum(u8) {
    none = 0,
    head_sent = 1,
    ended = 2,
    waiting = 3,

    pub const Event = enum { head, end, wait, drained };

    /// The table above, state by event: every cell is listed, every change
    /// is a row.
    const table = std.EnumArray(Resp, std.EnumArray(Event, Resp)).init(.{
        .none = .init(.{ .head = .head_sent, .end = .ended, .wait = .none, .drained = .none }),
        .head_sent = .init(.{ .head = .head_sent, .end = .ended, .wait = .head_sent, .drained = .head_sent }),
        .ended = .init(.{ .head = .ended, .end = .ended, .wait = .waiting, .drained = .ended }),
        .waiting = .init(.{ .head = .waiting, .end = .waiting, .wait = .waiting, .drained = .ended }),
    });

    pub fn next(r: Resp, ev: Event) Resp {
        return table.get(r).get(ev);
    }

    /// The last frame is submitted (or being submitted).
    pub fn isEnded(r: Resp) bool {
        return @backingInt(r) >= @backingInt(Resp.ended);
    }

    /// The final head went to `proto`.
    pub fn headOut(r: Resp) bool {
        return r != .none;
    }
};

/// An `EStream`'s request body, one value (nghttp2's SHUT_RD, as a phase).
/// Every change is a row here: add a state or an event as a row of `next`,
/// never as a flag beside it.
///
///   state           end        discard     discard_tunnel
///   receiving       complete   discarding  tunnel_closing
///   discarding      dropped    =           =
///   tunnel_closing  dropped    =           =
///   dropped         =          =           =
///   complete        =          =           =
///
/// (`=`: no change.)
///
/// end:            the body's END_STREAM came (DATA or trailers), or the
///                 stream is reset or gone (`Conn.closeBody`).
/// discard:        the handler is done first: a window more of the body is
///                 read and dropped, then RST_STREAM(NO_ERROR) (RFC 9113
///                 §8.1; `Conn.startDiscard`).
/// discard_tunnel: the same for an RFC 8441 tunnel, which reads nothing
///                 more: RST_STREAM(NO_ERROR) once our END_STREAM is framed.
///
/// The head sets `receiving` or `complete` (an init, not an event). The
/// discards outside `receiving` are not reached (`finishHandler` checks
/// `done` first) and change nothing. A tunnel whose reset went out, or
/// whose peer ended first, is `dropped`: its reset can't be due once the
/// peer's half is closed.
pub const ReqBody = enum(u8) {
    receiving,
    discarding,
    tunnel_closing,
    dropped,
    complete,

    pub const Event = enum { end, discard, discard_tunnel };

    /// The table above, state by event: every cell is listed, every change
    /// is a row.
    const table = std.EnumArray(ReqBody, std.EnumArray(Event, ReqBody)).init(.{
        .receiving = .init(.{ .end = .complete, .discard = .discarding, .discard_tunnel = .tunnel_closing }),
        .discarding = .init(.{ .end = .dropped, .discard = .discarding, .discard_tunnel = .discarding }),
        .tunnel_closing = .init(.{ .end = .dropped, .discard = .tunnel_closing, .discard_tunnel = .tunnel_closing }),
        .dropped = .init(.{ .end = .dropped, .discard = .dropped, .discard_tunnel = .dropped }),
        .complete = .init(.{ .end = .complete, .discard = .complete, .discard_tunnel = .complete }),
    });

    /// No more body comes.
    const is_done = std.EnumArray(ReqBody, bool).init(.{
        .receiving = false,
        .discarding = false,
        .tunnel_closing = false,
        .dropped = true,
        .complete = true,
    });

    /// The handler is done with the body: what comes is dropped.
    const is_dropping = std.EnumArray(ReqBody, bool).init(.{
        .receiving = false,
        .discarding = true,
        .tunnel_closing = true,
        .dropped = true,
        .complete = false,
    });

    pub fn next(b: ReqBody, ev: Event) ReqBody {
        return table.get(b).get(ev);
    }

    pub fn done(b: ReqBody) bool {
        return is_done.get(b);
    }

    pub fn dropping(b: ReqBody) bool {
        return is_dropping.get(b);
    }
};

/// A connection's output, one value under its lock: who may write (the
/// flush token), whether bytes sit in the connection's buffered writer not
/// flushed yet, and whether anything is written again. Every change is a
/// row of `next`: add behaviour as a state or a row, never as a flag
/// beside it.
///
///   state \ event       take      wrote               flushed   release  shut_drained  fail
///   idle                flushing  =                   =         =        shut          shut
///   flushing            =         flushing_unflushed  =         idle     =             shut
///   flushing_unflushed  =         =                   flushing  =        =             shut
///   shut                =         =                   =         =        =             shut
///
/// (`=`: no change.)
///
/// take:         a task takes the token (`takeToken`, `kickFlush`). Only
///               from `idle`; elsewhere it is refused: the holder looks
///               again before it lets go, and once `shut` nothing more is
///               written.
/// wrote:        the holder wrote into the buffered writer (`writeOut`).
/// flushed:      the holder, finding nothing more to write, takes the flush
///               on (under the lock, right before it flushes; a flush that
///               fails is `fail`).
/// release:      the holder lets go, nothing being left. Not from
///               `flushing_unflushed`: the holder flushes first.
/// shut_drained: the holder, right after `release`, ends a drained
///               connection's side (`shutDrained`).
/// fail:         a write failed (`writeFailed`): both directions are shut.
///
/// `wrote`, `flushed` and `release` come only from the holder, so their
/// cells in `idle` and `shut` do not occur and change nothing, as does
/// `shut_drained` outside `idle`. Only the holder moves the state out of a
/// token state, so a holder never finds `shut`.
pub const Writer = enum {
    idle,
    flushing,
    flushing_unflushed,
    shut,

    pub const Event = enum { take, wrote, flushed, release, shut_drained, fail };

    /// The table above, state by event: every cell is listed, every change
    /// is a row.
    const table = std.EnumArray(Writer, std.EnumArray(Event, Writer)).init(.{
        .idle = .init(.{ .take = .flushing, .wrote = .idle, .flushed = .idle, .release = .idle, .shut_drained = .shut, .fail = .shut }),
        .flushing = .init(.{ .take = .flushing, .wrote = .flushing_unflushed, .flushed = .flushing, .release = .idle, .shut_drained = .flushing, .fail = .shut }),
        .flushing_unflushed = .init(.{ .take = .flushing_unflushed, .wrote = .flushing_unflushed, .flushed = .flushing, .release = .flushing_unflushed, .shut_drained = .flushing_unflushed, .fail = .shut }),
        .shut = .init(.{ .take = .shut, .wrote = .shut, .flushed = .shut, .release = .shut, .shut_drained = .shut, .fail = .shut }),
    });

    /// A task holds the token.
    const is_held = std.EnumArray(Writer, bool).init(.{
        .idle = false,
        .flushing = true,
        .flushing_unflushed = true,
        .shut = false,
    });

    pub fn next(w: Writer, ev: Event) Writer {
        return table.get(w).get(ev);
    }

    /// `take`: whether it was granted (the state moved).
    pub fn take(w: *Writer) bool {
        const was = w.*;
        w.* = was.next(.take);
        return w.* != was;
    }

    pub fn held(w: Writer) bool {
        return is_held.get(w);
    }
};

/// How far a connection is from its end, under its lock. Only forward,
/// each step a store at its site:
///
///   running      -> closing       the reader is done (`closeRun`)
///   closing      -> tasks_closed  the tasks' last flush is done: no task
///                                 joins the group from here (`closeRun`)
///   running      -> tasks_closed  the teardown of a connection that never
///                                 ran `closeRun` (a parked one, released
///                                 by the shelf's driver)
///   tasks_closed -> tasks_closed  the teardown after `closeRun`
///
/// "The reader is done" is `life != .running`; "no flusher starts, no
/// detached response attaches" is `life == .tasks_closed`.
pub const Life = enum { running, closing, tasks_closed };

/// The drain's two phases (RFC 9113 §6.8), one ladder for what the drain
/// asks (`Ask`, the Registry's word) and what a connection sent
/// (`Conn.drain`):
///
///   none   -> notice  `beginDrain`: GOAWAY with the largest stream ID and
///                     a PING, and one count in the server's in-flight
///                     requests, given back at the teardown, so the drain
///                     waits for the final GOAWAY and the lingering close
///                     too (#135)
///   notice -> final   `finishDrain`: GOAWAY with the last stream taken
///                     (none written once the connection is closing or sent
///                     a GOAWAY of its own; the state moves all the same)
///   none   -> none    the notice asked while the connection is closing or
///                     after a GOAWAY of its own: none goes out; or the
///                     final asked with no notice sent
///   notice -> notice  the notice asked again: only the resets of answered
///                     streams run
///   final  -> final   anything asked after the final
///
/// As a request (`Ask`): `none` nothing asked, `notice` the notice, `final`
/// both. Requests only rise: a notice asked after a final is a no-op. The
/// peer's GOAWAY is a fact of its own (`Conn.peer_goaway`), with any of the
/// three.
pub const Drain = enum(u8) {
    none,
    notice,
    final,

    /// The Registry's request word, raised from any thread (`fetchMax`:
    /// the ladder's order is its backing int's).
    pub const Ask = struct {
        word: std.atomic.Value(u8) = .init(@backingInt(Drain.none)),

        pub fn raise(a: *Ask, to: Drain) void {
            _ = a.word.fetchMax(@backingInt(to), .acq_rel);
        }

        pub fn get(a: *const Ask) Drain {
            return @fromBackingInt(a.word.load(.acquire));
        }
    };

    /// The notice went out (the final may have too).
    pub fn begun(d: Drain) bool {
        return d != .none;
    }
};

pub fn Engine(comptime Ctx: type) type {
    return struct {
        const Server = server_mod.Server(Ctx);
        const Proto = conn_mod.Conn(.server, Conn);
        const PStream = conn_mod.Stream;

        /// The server's open HTTP/2 connections, for the drain, in the
        /// server's field `field`.
        /// The drain asks each connection for its GOAWAYs (`Conn.ask`)
        /// and gets them sent: where the connection has a mutex, now,
        /// under it; on a pinned executor, whose lock is no lock, by
        /// waking the readers that wait for input there (each shelf's
        /// drain bell), which act on it themselves, as every reader does
        /// at its next read. A parked connection is not woken: it begins
        /// its drain if its socket wakes it, and the stop closes it.
        pub const Registry = struct {
            /// Held across the drain's walk, which waits for each
            /// connection's lock where it has a mutex (`request`), so
            /// no other lock may be held while waiting for one.
            /// Taken with no lock held.
            mutex: std.Io.Mutex = .init,
            list: std.DoublyLinkedList = .{},

            pub const field = "h2_conns";

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
                return r.request(.notice);
            }

            /// Asks for the final GOAWAY.
            pub fn finishDrain(r: *Registry) void {
                _ = r.request(.final);
            }

            fn request(r: *Registry, what: Drain) bool {
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
                        conn.ask.raise(what);
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

        /// The connection's lock (PLAN §3.3): none when the connection's
        /// tasks share one executor and switch only at a yield
        /// (`placement.single_executor_guarantee` and a zio `Io`), else a
        /// mutex. Nothing under it may yield.
        const ConnLock = struct {
            mutex: std.Io.Mutex = .init,
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

            /// The output: the flush token, and whether anything more is
            /// written (`Writer`).
            writer: Writer = .idle,
            /// How far the connection is from its end (`Life`).
            life: Life = .running,
            /// Parked responses not released yet; the teardown waits for
            /// them (`parked_idle`), as their owners still touch them.
            parked_open: usize = 0,
            parked_idle: Signal = .{},
            /// Notified as a handler lets go of its stream once the
            /// reader is done (`life`; `probeHalfClose` waits on it).
            handler_done: Signal = .{},

            /// Every stream with a hold left (`EStream.held`).
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
            /// Streams counted in and waiting for their task, which the
            /// reader spawns once the read is processed (`startTasks`).
            /// Only the reader touches it.
            to_start: std.DoublyLinkedList = .{},
            inline_ok: bool = false,

            /// Streams with a handler that have not let go yet; the
            /// connection holds one count in the server's in-flight
            /// requests while any is (#99): taken at the first, given back
            /// at the last.
            open_streams: usize = 0,
            /// What the streams' raised body windows take
            /// (`Http2.reading_window_budget`).
            raised_bytes: usize = 0,

            /// What the drain asked for (`Registry`).
            ask: Drain.Ask = .{},
            /// The reader's: `ask` as it last acted on it.
            drain_seen: Drain = .none,
            /// What of the drain went out; from the notice to the teardown
            /// it holds a count in the server's in-flight requests (#135).
            drain: Drain = .none,
            /// The peer's GOAWAY came: once nothing is open the connection
            /// is over (`drained`), as nghttp2's want_read is 0 then.
            peer_goaway: bool = false,
            /// The reader's deadline while it waits for input on a pinned
            /// executor (`waitInput`), for a token holder to end that wait
            /// (`wakeReader`): when it closes a drained connection, or lets
            /// go of the last stream of one whose reader waits for that to
            /// park (`park_on_free`).
            reader_wait: if (have_auto_cancel) ?*park.Lazy else void = if (have_auto_cancel) null else {},
            /// The reader's last idle wait found streams open, so it waits
            /// with no park delay (no wake per `idle_park` for a
            /// long-lived stream) until the last one is let go, which
            /// wakes it (`maybeFree`). Pinned executors only.
            park_on_free: bool = false,
            node: std.DoublyLinkedList.Node = .{},

            /// Finished responses whose last frames wait for the peer's
            /// credit (`Resp.waiting`), and whether a task waits for
            /// their send deadlines (`waitSends`), woken on `send_wake`.
            send_waits: usize = 0,
            send_waiter: bool = false,
            send_wake: Signal = .{},
            /// Tests only: the group was joined for the last time.
            test_joined: if (is_test) bool else void = if (is_test) false else {},

            fn lock(conn: *Conn) void {
                conn.lock_.lock(conn.io);
            }

            fn unlock(conn: *Conn) void {
                conn.lock_.unlock(conn.io);
            }

            fn trimEpoch(conn: *Conn) u32 {
                if (comptime is_test) return @truncate(probe.at(.trim_epoch).load(.monotonic));
                return conn.server.trim_epoch.load(.monotonic);
            }

            /// Once a trim interval has passed: the spares unused since the
            /// last trim go, and an
            /// idle connection's output blocks. Under the lock.
            fn trimIdle(conn: *Conn) void {
                const epoch = conn.trimEpoch();
                if (epoch == conn.spare_epoch) return;
                conn.spare_epoch = epoch;
                const n = @min(conn.spare_low, conn.spares.items.len -| min_spare_streams);
                for (0..n) |_| conn.spares.pop().?.destroy(conn.allocator);
                conn.spare_low = conn.spares.items.len;
                conn.proto.trimSpares(min_spare_streams);
                if (!conn.writer.held() and conn.open_streams == 0 and conn.proto.out.idle() and conn.proto.out.blocks.items.len > 0) {
                    conn.proto.out.release();
                    probe.bump(.out_releases);
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
                if (conn.server.busy.load(.acquire).draining and !conn.drain.begun()) {
                    conn.proto.reset(s, .refused_stream) catch return error.ResetStream;
                    return;
                }
                const es = EStream.create(conn) catch return error.ResetStream;
                es.cs = s;
                es.id = s.id;
                s.user = es;
                conn.live.append(&es.node);
                gauges.add(conn.io, .h2_streams, 1);
            }

            pub fn onField(conn: *Conn, s: *PStream, name: []const u8, value: []const u8) conn_mod.Error!void {
                _ = conn;
                const es = EStream.of(s) orelse return;
                // Trailers on a request are not passed on .
                if (s.flags.in_trailers) return;
                const arena = es.arena.allocator();
                const v = arena.dupe(u8, value) catch return error.ResetStream;
                // The token names are the EStream field names.
                if (fields.token(name)) |t| switch (t) {
                    inline .method, .path, .authority, .scheme, .protocol => |p| {
                        @field(es, @tagName(p)) = v;
                        return;
                    },
                    // fields.zig has checked it (and holds the DATA to it).
                    .content_length => es.content_length = std.fmt.parseInt(u64, v, 10) catch null,
                    else => {},
                };
                // `:status` or an unknown pseudo-header (the core rejects both).
                if (name[0] == ':') return;
                const n = arena.dupe(u8, name) catch return error.ResetStream;
                es.headers.append(arena, .{ .name = n, .value = v }) catch return error.ResetStream;
            }

            pub fn onHeadersEnd(conn: *Conn, s: *PStream, end_stream: bool) conn_mod.Error!void {
                const es = EStream.of(s) orelse return;
                if (s.flags.in_trailers) {
                    if (end_stream) conn.bodyEnded(es);
                    return;
                }
                if (end_stream) es.recv = .complete;
                if (es.protocol.len > 0) {
                    // A tunnel's output is copied to its chain
                    // (`StreamSink.appendParts`).
                    es.chain_mode = true;
                    if (!end_stream) conn.setTunnelWindow(es, s);
                }
                // The handler's first state (`Dispatch`): counted in once,
                // whichever way it runs.
                conn.open_streams += 1;
                if (conn.open_streams == 1) _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
                if (conn.inline_ok and conn.noWaitRoute(es)) {
                    if (end_stream) return conn.queueInline(es);
                    if (conn.awaiting.append(conn.allocator, es)) |_| {
                        es.dispatch = .inline_awaiting_body;
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
                if (es.reset or es.recv.dropping()) {
                    conn.proto.consumed(s, bytes.len) catch return error.ResetStream;
                    if (!es.reset) {
                        es.discard_left -|= bytes.len;
                        // The response is out (our half ended): past a
                        // window of discarded body the stream ends
                        // (RFC 9113 §8.1).
                        if (es.discard_left == 0 and !end_stream and s.state == .half_closed_local) {
                            try conn.sendReset(es, .no_error);
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
                if (code != .no_error or !es.resp.isEnded()) conn.streamGone(es) else conn.wakeWaiters(es);
                if (es.reset) {
                    if (es.body.len > 0) {
                        // Never read: the connection's credit goes back.
                        conn.proto.consumed(null, es.body.len) catch {};
                        es.body.clear();
                    }
                    es.cancelHandler();
                    // Reset with its response detached: the owner lets go
                    // now (a parked one's hears `gone`). Neither waits nor
                    // calls back into `proto` (we are inside its call).
                    conn.abortDetached(es);
                }
                // The response's bytes may still be borrowed by `out`.
                const mark = conn.proto.out.mark();
                if (conn.proto.out.sent_total < mark) {
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
                conn.peer_goaway = true;
                // As a number: the peer may send any code (RFC 9113 §7),
                // and a name only exists for the ones we know.
                log.debug("HTTP/2: GOAWAY from the peer, last stream {d}, code {d}", .{ last_id, @backingInt(code) });
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
                es.dispatch = switch (es.dispatch) {
                    .head, .inline_awaiting_body => .inline_ready,
                    .queued_task, .inline_ready, .running_inline, .running_tasked, .running_parked, .running_ended, .detached_inline, .detached_tasked, .parked, .done => unreachable,
                };
            }

            /// The request body is whole (DATA or trailers with END_STREAM):
            /// a `no_wait` request set aside for it runs inline after all.
            /// Under the lock.
            fn bodyEnded(conn: *Conn, es: *EStream) void {
                conn.closeBody(es);
                if (es.dispatch != .inline_awaiting_body or es.reset) return;
                conn.queueInline(es);
            }

            /// The body's end (`ReqBody`), then its reader is woken.
            fn closeBody(conn: *Conn, es: *EStream) void {
                es.recv = es.recv.next(.end);
                es.wake.notify(conn.io);
            }

            /// Whoever waits on the stream (its body reader, its writer
            /// waiting for room) is woken. Under the lock.
            fn wakeWaiters(conn: *Conn, es: *EStream) void {
                conn.closeBody(es);
                conn.wakeRoom(es);
            }

            /// The stream is gone, or reset by us: the latch, then its
            /// waiters are woken. The only writer of `reset`. Under the
            /// lock.
            fn streamGone(conn: *Conn, es: *EStream) void {
                es.reset = true;
                conn.wakeWaiters(es);
            }

            /// `streamGone`, and RST_STREAM(`code`) while the protocol
            /// stream is open. May free `es` through its close (`held`
            /// permitting): the caller does not touch it after unless it
            /// still holds it. Under the lock.
            fn sendReset(conn: *Conn, es: *EStream, code: conn_mod.ErrorCode) conn_mod.Error!void {
                conn.streamGone(es);
                const s = es.cs orelse return;
                conn.proto.reset(s, code) catch return error.ResetStream;
            }

            /// The stream's handler gets a task once the read is processed
            /// (`startTasks`): a spawn may yield, which must not happen in
            /// the middle of `recv`. Under the lock.
            fn spawnTasked(conn: *Conn, es: *EStream) void {
                es.dispatch = switch (es.dispatch) {
                    .head, .inline_awaiting_body => .queued_task,
                    .queued_task, .inline_ready, .running_inline, .running_tasked, .running_parked, .running_ended, .detached_inline, .detached_tasked, .parked, .done => unreachable,
                };
                conn.to_start.append(&es.start_node);
            }

            /// A task for each handler `spawnTasked` queued; at the task
            /// cap the stream is refused (REFUSED_STREAM, safe for the
            /// client to retry; RFC 9113 §8.7). The reader, after `recv`,
            /// under the lock (which `spawn` may let go meanwhile).
            fn startTasks(conn: *Conn) void {
                while (conn.to_start.popFirst()) |node| {
                    const es: *EStream = @fieldParentPtr("start_node", node);
                    conn.startTask(es);
                }
            }

            fn startTask(conn: *Conn, es: *EStream) void {
                const slot = if (conn.task_row) |r| conn.server.admission.reserveTask(r, .stream) else true;
                const spawned = if (!slot) error.TaskCap else conn.spawn(runStream, .{ conn, es });
                spawned catch |err| {
                    if (slot) if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                    if (err == error.TaskCap)
                        log.debug("HTTP/2: stream {d} refused at the task cap", .{es.id})
                    else
                        log.err("HTTP/2: no task for stream {d}", .{es.id});
                    // Held by `dispatch` through the close the reset runs.
                    conn.sendReset(es, .refused_stream) catch {};
                    conn.handlerNeverRan(es);
                    return;
                };
                probe.bump(.spawned);
            }

            /// `placement.concurrent` into the connection's group, under
            /// the lock, at a point where other tasks may run. On a pinned
            /// executor, whose lock is no lock, a spawn may yield (zio's
            /// spawn back-pressure, once its run queue is long), so the
            /// lock is let go around it: the spawn takes the group before
            /// any suspension, so `Life.tasks_closed`, checked under it, still
            /// holds. With a mutex nothing yields (zio steals, or
            /// std.Io.Threaded) and it stays held.
            fn spawn(conn: *Conn, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) std.Io.ConcurrentError!void {
                const Direct = struct {
                    args: @TypeOf(args),
                    fn into(t: @This(), group: *std.Io.Group, io: std.Io) std.Io.ConcurrentError!void {
                        return placement.concurrent(group, io, .local, func, t.args);
                    }
                };
                return conn.spawnWith(Direct{ .args = args });
            }

            /// `spawn`'s lock rule for any `spawner` with `into(group,
            /// io)`: a direct one (`spawn`) or a detached owner's
            /// (`detachedAttach`).
            inline fn spawnWith(conn: *Conn, spawner: anytype) std.Io.ConcurrentError!void {
                if (!conn.lock_.free) return spawner.into(conn.group, conn.io);
                conn.unlock();
                defer conn.lock();
                return spawner.into(conn.group, conn.io);
            }

            /// After a read: the `no_wait` requests whose body did not end
            /// in it get a task, so a body is never held back waiting for a
            /// handler that is not reading it. Under the lock.
            fn startAwaiting(conn: *Conn) void {
                defer conn.awaiting.clearRetainingCapacity();
                for (conn.awaiting.items) |es| {
                    if (es.dispatch != .inline_awaiting_body) continue;
                    if (es.reset) {
                        conn.handlerNeverRan(es);
                        continue;
                    }
                    conn.spawnTasked(es);
                }
            }

            /// A stream counted in whose handler will never run lets go.
            /// Under the lock.
            fn handlerNeverRan(conn: *Conn, es: *EStream) void {
                es.dispatch = switch (es.dispatch) {
                    .queued_task, .inline_awaiting_body => .done,
                    .head, .inline_ready, .running_inline, .running_tasked, .running_parked, .running_ended, .detached_inline, .detached_tasked, .parked, .done => unreachable,
                };
                conn.maybeFree(es);
            }

            /// A detached response is finished, or a parked one released,
            /// by its owner: from inside the handler `serveStream`'s caller
            /// lets go once it returns (`handlerReturned`), else this does.
            /// Under the lock; may free `es`.
            fn ownerDone(conn: *Conn, es: *EStream) void {
                switch (es.dispatch) {
                    .running_inline, .running_tasked, .running_parked => es.dispatch = .running_ended,
                    .detached_inline, .detached_tasked, .parked => {
                        es.task = null;
                        conn.finishHandler(es);
                    },
                    .head, .queued_task, .inline_awaiting_body, .inline_ready, .running_ended, .done => unreachable,
                }
            }

            /// The handler let go of the stream. A body still coming is
            /// read and dropped from now on (`startDiscard`). Under the
            /// lock.
            /// The hold goes last: a reset or a discard here may close the
            /// stream (`onStreamClose`), which must not free it under us.
            fn finishHandler(conn: *Conn, es: *EStream) void {
                if (es.cs) |s| {
                    // A handler that returned without ending its response
                    // (it never does: `serveStream` writes it) would leave
                    // the peer waiting.
                    if (!es.resp.isEnded() and !es.reset) {
                        conn.sendReset(es, .internal_error) catch {};
                    } else if (!es.recv.done() and !es.reset) conn.startDiscard(es, s);
                    // Its last frames may wait for the peer's credit: they
                    // get a send deadline (`waitSends`) unless they go out
                    // with this write.
                    if (es.resp == .ended and !es.reset and es.cs != null and s.canSend()) {
                        es.resp = es.resp.next(.wait);
                        conn.send_waits += 1;
                    }
                }
                es.dispatch = switch (es.dispatch) {
                    .running_inline, .running_tasked, .running_ended, .detached_inline, .detached_tasked, .parked => .done,
                    .head, .queued_task, .inline_awaiting_body, .inline_ready, .running_parked, .done => unreachable,
                };
                if (conn.life != .running) conn.handler_done.notify(conn.io);
                conn.maybeFree(es);
            }

            /// The reader is done: no more request body can arrive. Every
            /// stream still waiting for one, and every parked response,
            /// is reset and its handler canceled; with `all`, every stream
            /// (nobody left to answer). Under the lock.
            fn cancelStreams(conn: *Conn, all: bool) void {
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    // A parked response has nobody to send to once the
                    // peer closed its side of the connection.
                    if (all or !es.recv.done() or es.dispatch.isParked()) {
                        conn.streamGone(es);
                        es.cancelHandler();
                        // Detached with nobody left to send to: let go now
                        // rather than at its deadline.
                        conn.abortDetached(es);
                        conn.maybeFree(es);
                    }
                }
            }

            /// Whether a handler still holds a stream (on its task, or a
            /// detached response's owner), parked ones aside (reset at the
            /// EOF; the teardown waits for their release). Under the lock.
            fn handlersRunning(conn: *Conn) bool {
                var it = conn.live.first;
                while (it) |node| : (it = node.next) {
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (es.dispatch.holdsStream() and !es.dispatch.isParked()) return true;
                }
                return false;
            }

            /// `es`'s last frames are out (or never will be). Under the
            /// lock.
            fn sendDone(conn: *Conn, es: *EStream) void {
                if (es.resp != .waiting) return;
                es.resp = es.resp.next(.drained);
                conn.send_waits -= 1;
                if (conn.send_waits == 0 and conn.send_waiter) conn.send_wake.notify(conn.io);
            }

            /// Like the core's HTTP/1.x drain: a window more of the body is
            /// read and dropped, so a peer still sending a small one sees a
            /// clean end; then RST_STREAM(NO_ERROR) (`onData`). A tunnel
            /// (RFC 8441) whose handler is done has nothing left to read: it
            /// ends with RST_STREAM(NO_ERROR) as soon as its END_STREAM is
            /// framed (a reset before would drop it), rather than wait for a
            /// peer that may keep its side open.
            fn startDiscard(conn: *Conn, es: *EStream, s: *PStream) void {
                const tunnel = es.protocol.len > 0;
                es.discard_left = if (tunnel) 0 else es.windowSize(conn);
                es.recv = es.recv.next(if (tunnel) .discard_tunnel else .discard);
                if (tunnel) {
                    conn.tunnelReset(es, s);
                    if (es.recv == .tunnel_closing) conn.watchRoom(es);
                }
                if (es.body.len > 0) {
                    conn.proto.consumed(s, es.body.len) catch {};
                    es.body.clear();
                }
            }

            /// Frees `es` once nothing holds it: back to the spares with its
            /// arena trimmed, or to the allocator. Under the lock.
            fn maybeFree(conn: *Conn, es: *EStream) void {
                if (es.held()) return;
                defer probe.bump(.freed);
                if (es.room_waiting) conn.unwatchRoom(es);
                if (es.body.len > 0 and conn.life == .running) conn.proto.consumed(null, es.body.len) catch {};
                conn.sendDone(es);
                conn.live.remove(&es.node);
                if (conn.park_on_free and conn.live.first == null) {
                    conn.park_on_free = false;
                    conn.wakeReader();
                }
                gauges.add(conn.io, .h2_streams, -1);
                conn.raised_bytes -= es.raised_bytes;
                if (es.dispatch.counted()) {
                    conn.open_streams -= 1;
                    if (conn.open_streams == 0) conn.server.finishRequest();
                }
                es.releaseMemory(conn.allocator);
                if (is_test) {
                    var used: usize = 0;
                    var it = es.arena.used;
                    while (it) |n| : (it = n.next) used += n.end_index;
                    probe.max(.arena_high, used);
                }
                if (conn.spares.items.len < conn.max_spares) {
                    _ = es.arena.reset(.{ .retain_with_limit = arena_retain_limit });
                    if (is_test) probe.store(.arena_kept, es.arena.queryCapacity());
                    if (conn.spares.append(conn.allocator, es)) |_| return else |_| {}
                }
                es.destroy(conn.allocator);
            }

            /// The body does not fit its buffer (impossible by its sizing,
            /// but defended) or no buffer could be had: only this stream is
            /// reset, and the credit of what it held goes back. Under the
            /// lock, inside `onData`.
            fn resetBody(conn: *Conn, es: *EStream, s: *PStream, dropped: usize) conn_mod.Error!void {
                conn.streamGone(es);
                conn.proto.consumed(null, dropped + es.body.len) catch return error.ResetStream;
                es.body.clear();
                es.cancelHandler();
                conn.proto.reset(s, .internal_error) catch return error.ResetStream;
            }

            // -- Request bodies (sized from the declared length) --

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
            /// `reading_window_budget` (#99). Under the lock.
            fn raiseWindow(conn: *Conn, es: *EStream) void {
                es.raise_due = false;
                const s = es.cs orelse return;
                if (es.recv != .receiving or es.reset or !conn.mayRaise(es)) return;
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
                switch (conn.ask.get()) {
                    .none => if (conn.server.busy.load(.acquire).draining) conn.beginDrain(),
                    .notice => conn.beginDrain(),
                    .final => {
                        conn.beginDrain();
                        conn.finishDrain();
                    },
                }
            }

            /// Phase one: GOAWAY with the largest stream ID, which streams
            /// already on the way still fit under, and a PING whose answer
            /// says they have arrived.
            /// Answered streams whose peer keeps its request side open would
            /// hold the drain until its deadline: they end now. Under the
            /// lock; out of line (cold).
            noinline fn beginDrain(conn: *Conn) void {
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (!es.recv.dropping() or es.reset or es.cs == null) continue;
                    conn.sendReset(es, .no_error) catch {};
                }
                if (conn.drain.begun() or conn.life != .running or conn.proto.goaway_sent != null) return;
                conn.proto.shutdownNotice() catch return;
                conn.proto.ping(drain_ping) catch {};
                conn.drain = .notice;
                _ = conn.server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            }

            /// Phase two, at the PING's ACK or when the drain asks a round
            /// trip later: GOAWAY with the last stream taken. The drain's
            /// count stays until the teardown; the connection closes once
            /// nothing is open (`drained`). Under the lock.
            noinline fn finishDrain(conn: *Conn) void {
                if (conn.drain != .notice) return;
                conn.drain = .final;
                if (conn.life != .running or conn.proto.goaway_sent != null) return;
                conn.proto.goaway(.no_error, "") catch {};
            }

            /// The final GOAWAY is out, or the peer's came in, and no
            /// stream is open: nothing more is coming for this connection
            /// (nghttp2's `nghttp2_session_want_read` is 0 for either;
            /// RFC 9113 §6.8: the peer opens no more
            /// streams). Under the lock.
            fn drained(conn: *Conn) bool {
                return (conn.drain == .final or conn.peer_goaway) and conn.live.first == null;
            }

            /// Idle past `timeout.keepalive`.
            fn keepaliveDue(conn: *const Conn) bool {
                const at = conn.keepalive_at orelse return false;
                return park.now(conn.io).nanoseconds >= at.raw.nanoseconds;
            }

            // -- Output: the flush token ----------------------------------

            /// Takes the flush token, unless another task has it (and will
            /// see what was queued: it looks again before letting go) or
            /// nothing more is written.
            fn takeToken(conn: *Conn) bool {
                conn.lock();
                defer conn.unlock();
                return conn.writer.take();
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
                conn.lock();
                defer conn.unlock();
                if (conn.life == .tasks_closed or !conn.writer.take()) return;
                if (!conn.spawnFlusher(true)) conn.writer = conn.writer.next(.release);
            }

            /// The flusher, with the token (`with_token`) or to wait for
            /// send deadlines only (`waitSends`). Under the lock, so that
            /// `life` can't reach `tasks_closed` between its check and the
            /// spawn: nothing joins the group once it is joined for the
            /// last time (`closeRun`, `teardown`).
            fn spawnFlusher(conn: *Conn, with_token: bool) bool {
                if (conn.life == .tasks_closed) return false;
                if (comptime is_test) if (conn.test_joined) {
                    probe.bump(.late_flushers);
                    return false;
                };
                // One with the token runs on the slot its run holds
                // (`adopterServe`); a send-deadline waiter, which may run
                // beside it, takes one of its own.
                if (!with_token) if (conn.task_row) |r| {
                    _ = conn.server.admission.reserveTask(r, .forced);
                };
                conn.spawn(flusherRun, .{ conn, with_token }) catch {
                    if (!with_token) if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
                    log.err("HTTP/2: no task for the connection's output", .{});
                    return false;
                };
                probe.bump(.flushers);
                if (!with_token) probe.bump(.send_waiters);
                return true;
            }

            /// Writes until nothing is left, then, while finished responses
            /// wait for the peer's credit, waits for their send deadlines.
            /// Its writes have a deadline of their own, on the shelf's
            /// sweep where there is one.
            fn flusherRun(conn: *Conn, with_token: bool) std.Io.Cancelable!void {
                defer if (!with_token) if (conn.task_row) |r| conn.server.admission.releaseTask(conn.io, r);
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
                if (conn.send_waits == 0 or conn.send_waiter or conn.writer == .shut or conn.life != .running) return false;
                if (conn.sendTimeout() == null) return false;
                // Those whose END_STREAM went out with this write, on a
                // stream the peer keeps open (an early answer to an upload,
                // a bidi stream the server ends first): nothing to wait
                // for, and no task for it. Only while some are marked.
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (es.resp != .waiting) continue;
                    const s = es.cs orelse {
                        conn.sendDone(es);
                        continue;
                    };
                    if (!s.canSend()) conn.sendDone(es);
                }
                if (conn.send_waits == 0) return false;
                conn.send_waiter = true;
                return true;
            }

            /// How long a finished response may wait for the peer's credit
            /// before it is reset.
            fn sendTimeout(conn: *const Conn) ?std.Io.Duration {
                return conn.server.config.timeout.request orelse conn.server.config.timeout.keepalive;
            }

            /// Finished responses the peer gives no credit for are reset
            /// with CANCEL at their send deadline, so they don't hold the connection
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
                        if (conn.send_waits == 0 or conn.writer == .shut or conn.life != .running) {
                            conn.send_waiter = false;
                            return;
                        }
                        const now: i64 = @intCast(park.now(conn.io).nanoseconds);
                        var it = conn.live.first;
                        while (it) |node| {
                            it = node.next;
                            const es: *EStream = @fieldParentPtr("node", node);
                            if (es.resp != .waiting) continue;
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
                                reset += 1;
                                // May free `es` (its close): not touched after.
                                conn.sendReset(es, .cancel) catch {};
                                continue;
                            }
                            earliest = if (earliest) |e| @min(e, es.send_deadline) else es.send_deadline;
                        }
                    }
                    if (reset > 0) {
                        log.debug("HTTP/2: {d} finished response(s) the peer took no credit for, reset at their send deadline", .{reset});
                        _ = probe.add(.send_resets, reset);
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
                        const got = conn.proto.pending(&vecs) catch |err| switch (err) {
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
                        if (conn.writer == .flushing_unflushed) {
                            conn.writer = conn.writer.next(.flushed);
                            conn.unlock();
                            break :got got;
                        }
                        conn.connection.releaseWriteBuffer();
                        conn.writer = conn.writer.next(.release);
                        // The final GOAWAY is out and nothing is open:
                        // nothing more is written (`shutDrained`).
                        const close_drained = conn.drained() and conn.life == .running;
                        if (close_drained) conn.writer = conn.writer.next(.shut_drained);
                        // Last: its spawn may let the lock go.
                        if (conn.claimSendWaiter() and !conn.spawnFlusher(false)) conn.send_waiter = false;
                        conn.unlock();
                        if (close_drained) try conn.shutDrained();
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
                    written += total;
                    since_arm.? += total;
                    conn.lock();
                    defer conn.unlock();
                    conn.writer = conn.writer.next(.wrote);
                    conn.proto.advance(total);
                    conn.retire();
                    conn.wakeRooms();
                }
            }

            /// `vecs` into the connection's writer (a syscall only when its
            /// buffer fills). error.WriteFailed for a failure of the
            /// connection, error.Canceled when the calling task was.
            fn writeVecs(conn: *Conn, vecs: [][]const u8, timer: *Timer) (std.Io.Cancelable || error{WriteFailed})!void {
                probe.max(.max_writers, probe.add(.writers_in, 1));
                defer probe.sub(.writers_in, 1);
                conn.connection.writer.writeVecAll(vecs) catch return conn.writeError(timer);
            }

            fn flushWriter(conn: *Conn, timer: *Timer) (std.Io.Cancelable || error{WriteFailed})!void {
                conn.connection.writer.flush() catch return conn.writeError(timer);
            }

            fn writeError(conn: *Conn, timer: *Timer) (std.Io.Cancelable || error{WriteFailed}) {
                const cause = conn.connection.getWriteError() orelse return error.WriteFailed;
                if (cause == error.Canceled) {
                    if (!timer.fired()) return error.Canceled;
                    probe.bump(.write_timeouts);
                    log.debug("HTTP/2: no write progress for timeout.write, closing the connection", .{});
                    return error.WriteFailed;
                }
                if (!Connection.isPeerGone(cause)) log.info("HTTP/2 write error: {}", .{cause});
                return error.WriteFailed;
            }

            /// A drained connection's end of our side, once: close_notify under TLS, bounded by
            /// `linger_timeout`, then the send side shut, so the peer reads
            /// a clean end after the final GOAWAY. The receive side stays
            /// open: what the peer still sends (a WINDOW_UPDATE, the PING's
            /// answer) is read and thrown away by the lingering close, as
            /// data arriving at a socket shut for reading, or unread at its
            /// close, draws a reset, with which the peer may throw away
            /// what it has not read yet. The reader's wait ends here where
            /// it can (`wakeReader`, a pinned executor), for that close;
            /// elsewhere at the peer's hang-up or the keep-alive.
            noinline fn shutDrained(conn: *Conn) std.Io.Cancelable!void {
                defer conn.wakeReader();
                {
                    var t: Timer = .init(null);
                    if (t.canBound()) t.set(conn.io, .{ .duration = .{ .raw = server_mod.linger_timeout, .clock = .awake } });
                    defer t.clear(conn.io);
                    conn.connection.closeNotify() catch |err| {
                        conn.connection.stream.shutdown(conn.io, .both) catch {};
                        return err;
                    };
                }
                conn.connection.stream.shutdown(conn.io, .send) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {},
                };
                probe.bump(.send_shuts);
            }

            /// Ends the reader's wait for input, as its deadline would, if
            /// it waits on this executor (`reader_wait`); it then looks at
            /// the connection again at the top of its loop.
            fn wakeReader(conn: *Conn) void {
                if (comptime !have_auto_cancel) return;
                if (conn.reader_wait) |l| l.wakeWait();
            }

            /// Nothing more can go out: both directions are shut, so the
            /// reader stops too, the streams waiting for room are told, and
            /// the token goes (nobody takes it again).
            fn writeFailed(conn: *Conn) void {
                conn.connection.stream.shutdown(conn.io, .both) catch {};
                conn.lock();
                defer conn.unlock();
                conn.writer = conn.writer.next(.fail);
                conn.connection.releaseWriteBuffer();
                while (conn.room_waiters.first) |node| {
                    const es: *EStream = @fieldParentPtr("room_node", node);
                    conn.unwatchRoom(es);
                    es.room.notify(conn.io);
                }
            }

            /// The closed streams whose marks `out` has passed are let go.
            /// Under the lock.
            fn retire(conn: *Conn) void {
                const sent = conn.proto.out.sent_total;
                while (conn.retiring.first) |node| {
                    const es: *EStream = @fieldParentPtr("retire_node", node);
                    if (es.retire_mark.? > sent) break;
                    _ = conn.retiring.popFirst();
                    es.retire_mark = null;
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
                    conn.unwatchRoom(es);
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

            /// Takes `es` out of `room_waiters`; it is in. With
            /// `watchRoom`, the only writers of `room_waiting`. Under the
            /// lock.
            fn unwatchRoom(conn: *Conn, es: *EStream) void {
                conn.room_waiters.remove(&es.room_node);
                es.room_waiting = false;
            }

            fn wakeRoom(conn: *Conn, es: *EStream) void {
                if (es.room_waiting) conn.unwatchRoom(es);
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
                if (es.reset or conn.writer == .shut or conn.proto.in == .dead) return true;
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
            /// either way. A
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
                conn.sendReset(es, .no_error) catch {};
            }

            /// The stream ended with its response still detached (not
            /// attached): the owner hears of it, and the handler's hold
            /// goes (the caller frees `es` with `maybeFree`). A parked one's
            /// owner hears `gone` instead, and keeps the hold until
            /// `Parked.release`. Under the lock; never waits.
            fn abortDetached(conn: *Conn, es: *EStream) void {
                _ = conn;
                switch (es.dispatch) {
                    .running_parked, .parked => |p| p.peerGone(),
                    .detached_inline, .detached_tasked => |ex| {
                        // Attached or finished: its task or its end lets go.
                        const d = ex.response.detached.?;
                        if (d.state != .detached) return;
                        d.abort();
                        ex.request._body_held.release();
                        ex.response.deinit();
                        es.dispatch = .done;
                    },
                    .head, .queued_task, .inline_awaiting_body, .inline_ready, .running_inline, .running_tasked, .running_ended, .done => {},
                }
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
            /// faster than the flushes go out as one DATA run per block.
            /// Under the lock.
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
                if (es.reset or conn.writer == .shut or conn.proto.in == .dead or conn.chainReclaim(es)) es.room.notify(conn.io);
                const idle = es.chain.first == null;
                // A reset stream is never `tunnel_closing` (`streamGone`
                // ends its body).
                if (es.recv != .tunnel_closing) {
                    if (idle or es.reset) conn.unwatchRoom(es);
                    return;
                }
                // Last: the reset may free `es`, list node and all.
                if (s.state == .half_closed_local) {
                    conn.unwatchRoom(es);
                    conn.tunnelReset(es, s);
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
                probe.bump(.chain_blocks);
                return b;
            }

            fn destroy(b: *ChainBlock, gpa: std.mem.Allocator) void {
                // SAFETY: `b` heads the allocation `create` made, `size` bytes.
                const base: [*]align(@alignOf(ChainBlock)) u8 = @ptrCast(b);
                gpa.free(base[0..b.size]);
                probe.sub(.chain_blocks, 1);
            }

            fn data(b: *ChainBlock) []u8 {
                // SAFETY: `b` heads its allocation; its bytes follow the header.
                const base: [*]u8 = @ptrCast(b);
                return base[@sizeOf(ChainBlock)..b.size];
            }
        };

        /// A request body buffer: up to `arena_body_max` from the stream's
        /// arena, up to `block_cache.malloc_max` from the allocator
        /// (malloc's slabs), larger from `block_cache`.
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

            /// The arena only when the connection's tasks share one
            /// executor (`ConnLock.free`): the reader takes a body buffer
            /// while the handler may be allocating from the same arena,
            /// which is one owner's at a time (`LocalArena`).
            fn alloc(es: *EStream, size: usize) ?BodyBuf {
                return if (size <= arena_body_max and es.conn.lock_.free)
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

        /// Who runs a stream's handler, and who owns its response
        /// (`EStream.dispatch`), one value (h2o's
        /// `h2o_http2_stream_set_state`, hyperium/h2's `state.rs`). Every
        /// change is a cell here, made in the function the row names; add
        /// a state or a row, never a flag beside it.
        ///
        ///   head                  no handler yet (the head is coming, or never routed)
        ///   queued_task           counted; in `Conn.to_start`, or spawned and not entered
        ///   inline_awaiting_body  `no_wait`, body still coming; in `Conn.awaiting`
        ///   inline_ready          `no_wait`, whole; in `Conn.ready`
        ///   running_inline        `serveStream` in the handler, on the reader
        ///   running_tasked        ... on its own task, or attached from inside the handler
        ///   running_parked(p)     parked from inside the handler
        ///   running_ended         finished or released from inside the handler
        ///   detached_inline(ex)   returned detached; its writes never wait
        ///   detached_tasked(ex)   detached and attached to a task
        ///   parked(p)             returned parked; held until `Parked.release`
        ///   done                  the handler let go
        ///
        /// Rows: event (function): from -> to. `=`: no change. A state a
        /// row does not name is not reached there (`unreachable` in the
        /// function), unless the row says `others =`.
        ///
        ///   head complete (onHeadersEnd): head -> inline_ready (whole,
        ///       `queueInline`) | inline_awaiting_body (body coming) |
        ///       queued_task (`spawnTasked`); counted here, once.
        ///   body ends (bodyEnded): inline_awaiting_body, not reset ->
        ///       `queueInline`; others = (a reset one: `startAwaiting`).
        ///   queueInline: head, inline_awaiting_body -> inline_ready, or
        ///       `spawnTasked` when the ready list is full.
        ///   spawnTasked: head, inline_awaiting_body -> queued_task.
        ///   read done (startAwaiting): inline_awaiting_body -> queued_task,
        ///       reset -> done (`handlerNeverRan`); others = (moved on).
        ///   spawn failed (startTask): queued_task -> done
        ///       (`handlerNeverRan`, after RST_STREAM(REFUSED_STREAM)).
        ///   handler starts (enterHandler): queued_task -> running_tasked;
        ///       inline_ready -> running_inline.
        ///   attach (detachedAttach): running_inline -> running_tasked;
        ///       detached_inline -> detached_tasked; running_tasked,
        ///       detached_tasked, running_parked, parked =. Refused once
        ///       the tasks are closed: =.
        ///   park (detachedPark): running_inline, running_tasked ->
        ///       running_parked. Refused when reset: =.
        ///   handler returned detached (handlerReturned): running_inline ->
        ///       detached_inline; running_tasked -> detached_tasked;
        ///       running_parked -> parked; running_ended = (`.done`: the
        ///       caller lets go).
        ///   owner done (ownerDone: a detached end, `Parked.release`):
        ///       running_inline, running_tasked, running_parked ->
        ///       running_ended; detached_*, parked -> done (`finishHandler`).
        ///       A parked response's end (its last DATA) is no event.
        ///   let go (finishHandler): running_inline, running_tasked,
        ///       running_ended, detached_*, parked -> done, last.
        ///   abort (abortDetached): detached_* never finished -> done (the
        ///       caller frees); running_parked, parked = (the owner hears
        ///       `gone`); others =.
        ///   reset, gone (streamGone): = everywhere: `reset` is the
        ///       stream's; `cancelHandler` acts while `holdsStream`.
        pub const Dispatch = union(enum) {
            head,
            queued_task,
            inline_awaiting_body,
            inline_ready,
            running_inline,
            running_tasked,
            running_parked: *H2Parked,
            running_ended,
            detached_inline: *Exchange,
            detached_tasked: *Exchange,
            parked: *H2Parked,
            done,

            const Tag = std.meta.Tag(Dispatch);

            /// What each state is, one row per state (add a state as a row).
            ///   holds:     the handler (or the owner it handed the response
            ///              to) holds the stream.
            ///   on_reader: the response is written on the reader, which
            ///              never waits for the peer (`StreamSink`). The two
            ///              `inline_` states write nothing yet; in the set,
            ///              it stays one mask.
            ///   parked:    parked from inside the handler or returned parked.
            ///   owned:     the response has an owner past the handler,
            ///              whom the teardown lets go.
            const Traits = struct { holds: bool, on_reader: bool, parked: bool, owned: bool };
            const traits = std.EnumArray(Tag, Traits).init(.{
                .head = .{ .holds = false, .on_reader = false, .parked = false, .owned = false },
                .queued_task = .{ .holds = true, .on_reader = false, .parked = false, .owned = false },
                .inline_awaiting_body = .{ .holds = true, .on_reader = true, .parked = false, .owned = false },
                .inline_ready = .{ .holds = true, .on_reader = true, .parked = false, .owned = false },
                .running_inline = .{ .holds = true, .on_reader = true, .parked = false, .owned = false },
                .running_tasked = .{ .holds = true, .on_reader = false, .parked = false, .owned = false },
                .running_parked = .{ .holds = true, .on_reader = false, .parked = true, .owned = true },
                .running_ended = .{ .holds = true, .on_reader = false, .parked = false, .owned = false },
                .detached_inline = .{ .holds = true, .on_reader = true, .parked = false, .owned = true },
                .detached_tasked = .{ .holds = true, .on_reader = false, .parked = false, .owned = true },
                .parked = .{ .holds = true, .on_reader = false, .parked = true, .owned = true },
                .done = .{ .holds = false, .on_reader = false, .parked = false, .owned = false },
            });

            fn row(d: Dispatch) Traits {
                return traits.get(std.meta.activeTag(d));
            }

            pub fn holdsStream(d: Dispatch) bool {
                return row(d).holds;
            }

            /// Counted in `Conn.open_streams` (a handler was assigned).
            pub fn counted(d: Dispatch) bool {
                return d != .head;
            }

            pub fn onReader(d: Dispatch) bool {
                return row(d).on_reader;
            }

            pub fn isParked(d: Dispatch) bool {
                return row(d).parked;
            }

            pub fn owned(d: Dispatch) bool {
                return row(d).owned;
            }
        };

        /// The engine's side of a stream (`conn.Stream.user`). Freed (to
        /// the spares) once nothing holds it (`held`): the protocol stream
        /// (`cs`), the handler (`dispatch`), and `out`'s borrowed bytes
        /// after the close (`retire_mark`).
        const EStream = struct {
            conn: *Conn,
            arena: LocalArena,
            node: std.DoublyLinkedList.Node = .{},
            /// The protocol stream; null once it closed.
            cs: ?*PStream = null,
            id: u31 = 0,

            /// In `Conn.retiring` while `out` may still borrow its bytes,
            /// until `out.sent_total` passes this mark.
            retire_mark: ?u64 = null,
            retire_node: std.DoublyLinkedList.Node = .{},
            /// In `Conn.to_start` until its task is spawned.
            start_node: std.DoublyLinkedList.Node = .{},
            dispatch: Dispatch = .head,
            /// When a `.waiting` response is reset if its last frames are
            /// still not framed (awake clock, ns; 0 until the flusher sets
            /// it).
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
            recv: ReqBody = .receiving,
            /// Reset (by either side), or the connection is gone: a latch,
            /// set only by `Conn.streamGone`.
            reset: bool = false,
            /// What is left of the window `discarding` drops.
            discard_left: usize = 0,
            /// The handler waits on it for body bytes or the end.
            wake: Signal = .{},
            /// The receive window the body buffer holds; 0 for
            /// `stream_window`.
            window: u31 = 0,
            raise_due: bool = false,
            since_raise: usize = 0,
            raised_bytes: usize = 0,

            /// The task running the handler, an attached response or a
            /// parked burst, for `cancelHandler`; set and cleared by that
            /// task under the lock (a handle, not a phase).
            task: ?placement.Task = null,
            /// `cancelHandler` canceled it.
            canceled: bool = false,

            // The response.
            resp: Resp = .none,
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

            fn of(s: *PStream) ?*EStream {
                // SAFETY: `user` is only ever set to an EStream (`onStreamOpen`).
                return @ptrCast(@alignCast(s.user orelse return null));
            }

            fn held(es: *const EStream) bool {
                return es.cs != null or es.dispatch.holdsStream() or es.retire_mark != null;
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
                    _ = es.arena.reset(.{ .retain_with_limit = arena_retain_limit });
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
                if (es.resp.isEnded() or !es.dispatch.holdsStream()) return;
                if (es.task) |task| {
                    es.canceled = true;
                    placement.cancelTask(task);
                }
            }

            /// The handler's task, or the reader for an inline one, enters
            /// it. Under the lock.
            fn enterHandler(es: *EStream) void {
                es.dispatch = switch (es.dispatch) {
                    .queued_task => .running_tasked,
                    .inline_ready => .running_inline,
                    .head, .inline_awaiting_body, .running_inline, .running_tasked, .running_parked, .running_ended, .detached_inline, .detached_tasked, .parked, .done => unreachable,
                };
            }

            /// The handler returned with its response detached (`d`): the
            /// owner holds the stream from here, unless it already let go
            /// from inside the handler (`.done`: the caller does). Under
            /// the lock; out of `serveStream`, the rare path.
            fn handlerReturned(es: *EStream, d: *Detached) Served {
                switch (es.dispatch) {
                    .running_inline => es.dispatch = .{ .detached_inline = exchangeOf(d) },
                    .running_tasked => es.dispatch = .{ .detached_tasked = exchangeOf(d) },
                    .running_parked => |p| es.dispatch = .{ .parked = p },
                    // `d` may be gone with the exchange.
                    .running_ended => return .done,
                    .head, .queued_task, .inline_awaiting_body, .inline_ready, .detached_inline, .detached_tasked, .parked, .done => unreachable,
                }
                return .detached;
            }
        };

        /// Tests only: what a write that completes does for the streams
        /// waiting for room (`Conn.wakeRooms`), on `Probe.on_conn_error`'s
        /// connection.
        pub fn testWakeRooms(ptr: *anyopaque) void {
            // SAFETY: `Probe.on_conn_error` passes the Conn it was called for.
            const conn: *Conn = @ptrCast(@alignCast(ptr));
            conn.lock();
            defer conn.unlock();
            conn.wakeRooms();
        }

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
            probe.setLockFree(conn.lock_.free);
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
            probe.outHigh(&opts.limits);
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
            // The flusher's task slot, held while the run lasts (the
            // reader's is the accept's or the wake's): a connection on its
            // task counts as the two tasks it may run, so `max_tasks` bounds them;
            // a parked one counts none. A run ends with its flushers done
            // (a park needs the token let go, their last step; a close
            // joins them).
            if (conn.task_row) |r| _ = server.admission.reserveTask(r, .forced);
            defer if (conn.task_row) |r| server.admission.releaseTask(conn.io, r);
            // SAFETY: the connection's address only picks a pool shard.
            const buffers = try server.request_buffers.acquire(@intFromPtr(connection));
            conn.buffers = buffers;
            probe.bump(.read_buffers);
            defer {
                // A park leaves nothing in it (`prepPark`).
                connection.replaceReadBuffer(&.{});
                conn.buffers = null;
                server.request_buffers.release(buffers);
                probe.sub(.read_buffers, 1);
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
        /// once their bursts are over, so they are waited for (the
        /// teardown order: parked told, the group canceled,
        /// detached aborted, then the wait). Also from the shelf's driver,
        /// for a parked connection, which has no stream.
        fn adopterRelease(a: *server_mod.Adopter) void {
            teardown(@fieldParentPtr("adopter", a));
        }

        noinline fn teardown(conn: *Conn) void {
            const io = conn.io;
            const server = conn.server;
            // Out of the drain's reach, and no task joins the group from
            // here (`spawnFlusher`), before the group is canceled: a
            // flusher started after that would outlive the connection.
            if (comptime registered()) @field(server, Registry.field).remove(conn);
            {
                conn.lock();
                defer conn.unlock();
                conn.life = .tasks_closed;
            }
            conn.group.cancel(io);
            probe.afterJoin(conn);
            {
                conn.lock();
                defer conn.unlock();
                var it = conn.live.first;
                while (it) |node| {
                    it = node.next;
                    const es: *EStream = @fieldParentPtr("node", node);
                    if (!es.dispatch.owned()) continue;
                    conn.streamGone(es);
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
            // The streams' count (#99), if one was still open.
            if (conn.open_streams != 0) {
                conn.open_streams = 0;
                server.finishRequest();
            }
            // The drain's count, kept until here so the drain waits for the
            // lingering close too (#135). Out of the Registry (above),
            // nothing raises `drain` now.
            if (conn.drain.begun()) server.finishRequest();
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
                // finish.
                .dead => {
                    linger = true;
                    reader_failed = true;
                },
                // Idle past `timeout.keepalive`: a GOAWAY first, as nginx,
                // Go and h2o send on an idle close.
                .keepalive => {
                    probe.bump(.keepalive_closes);
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
                conn.life = .closing;
                // A send-deadline waiter has nothing left to wait for.
                if (conn.send_waiter) conn.send_wake.notify(conn.io);
                conn.cancelStreams(reader_failed);
            }
            conn.flush(.all, timer) catch return error.Canceled;
            if (result) |end| if (end == .eof) try probeHalfClose(conn, timer) else {} else |_| {}
            // No flusher joins the group from here (`spawnFlusher`, under
            // the lock), before the join: a spawn from outside the group
            // (the drain's thread, where the connection has a mutex) must
            // not race the join's end (`std.Io.Group.await`). What the
            // tasks still queue goes out with the flush below, and then the
            // lingering close is the only writer. A detached owner's
            // `attach` is checked and spawned under the same lock
            // (`detachedAttach`), so it is refused from here.
            {
                conn.lock();
                defer conn.unlock();
                conn.life = .tasks_closed;
            }
            conn.group.await(conn.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            probe.afterJoin(conn);
            conn.flush(.all, timer) catch return error.Canceled;
            if (linger) try lingeringClose(conn);
        }

        /// After a clean EOF, while handlers still run: a PING now and
        /// every `half_close_probe_interval` until they are done (their
        /// tasks, and the flushers they kick, still join the group
        /// meanwhile). A peer
        /// that closed the whole connection answers the first with a TCP
        /// reset, so a later write fails (`Writer.shut`), and the handlers
        /// are canceled, with nobody left to answer; one that only
        /// half-closed reads it and is still served. A handler's end wakes
        /// the wait to look again, and only a whole interval without one
        /// sends the next PING.
        fn probeHalfClose(conn: *Conn, timer: *Timer) error{Canceled}!void {
            var ping = true;
            while (true) {
                const seen = conn.handler_done.epoch();
                {
                    conn.lock();
                    defer conn.unlock();
                    if (!conn.handlersRunning()) return;
                    if (conn.writer == .shut) return conn.cancelStreams(true);
                    if (ping) conn.proto.ping(probe_ping) catch {};
                }
                if (ping) conn.flush(.all, timer) catch return error.Canceled;
                conn.handler_done.waitTimeout(conn.io, seen, .{ .duration = .{ .raw = half_close_probe_interval, .clock = .awake } }) catch
                    return error.Canceled;
                ping = conn.handler_done.epoch() == seen;
            }
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
        /// streams are still open waits with no park delay until the last
        /// is let go (`park_on_free`), where that can wake it, and with
        /// one (a wake per `idle_park`) elsewhere.
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
                        if (conn.writer == .shut) return .done;
                        const scratch = try conn.scratch();
                        const now = placement.tickNow(conn.io) orelse std.Io.Clock.awake.now(conn.io);
                        const result = conn.proto.recv(buffered, @intCast(@max(0, now.toSeconds())), scratch);
                        probe.bump(.reads);
                        if (result) |_| {
                            if (conn.awaiting.items.len > 0) conn.startAwaiting();
                        } else |_| {}
                        // Also after a connection error: those handlers
                        // see their streams reset.
                        if (conn.to_start.first != null) conn.startTasks();
                        // A connection error frames no more DATA: every
                        // stream is reset now, under the lock that saw it,
                        // not at `closeRun`. Until then a stream task woken
                        // by a write would find room (`roomFree` is true
                        // for a dead connection), take a block `out` still
                        // borrows, and write on as if its response could
                        // finish.
                        if (result) |_| {} else |_| conn.cancelStreams(true);
                        break :result result;
                    };
                    const taken = result catch |err| switch (err) {
                        // A GOAWAY is queued: out it goes, then the
                        // lingering close.
                        error.ConnectionError => {
                            probe.onConnError(conn);
                            try conn.flush(.all, timer);
                            return .dead;
                        },
                        error.BadPreface => return error.Http2BadPreface,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    reader.toss(taken);
                    // Input: the keep-alive counts from the next idle wait.
                    if (taken > 0) conn.keepalive_at = null;
                    if (conn.ready.items.len > 0) try runInline(conn);
                    try conn.flush(.batch, timer);
                    if (conn.writer == .shut) return .done;
                    // What is left, if anything, is a frame not yet whole.
                }

                if (conn.ask.get() != conn.drain_seen) try drainNow(conn, timer);
                const idle, const drained, const may_park = state: {
                    conn.lock();
                    defer conn.unlock();
                    conn.trimIdle();
                    if (conn.live.first == null) conn.park_on_free = false;
                    break :state .{
                        conn.open_streams == 0,
                        conn.drained(),
                        conn.proto.atFrameBoundary() and !conn.drain.begun() and !conn.park_on_free,
                    };
                };
                if (drained) return .drained;
                if (idle) {
                    // From when the connection went idle (or last read
                    // something), not from each wait: a wake that brought
                    // nothing (the park delay, a TLS record half read, the
                    // drain's bell) does not move it.
                    if (conn.keepalive_at == null) conn.keepalive_at = if (conn.server.config.timeout.keepalive) |d|
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
                        continue;
                    },
                    else => |e| return e,
                };
                if (input == .idle) {
                    if (prepPark(conn)) return .park;
                    // Busy after all (a write, a flusher): the park delay
                    // again from here, not at once (`Burst.repark`). With
                    // streams open, no park delay until the last one is
                    // let go (`park_on_free`), where that can wake us.
                    burst.repark = false;
                    if (comptime have_auto_cancel) if (conn.lock_.free and burst.timer.shelf != null) {
                        conn.lock();
                        defer conn.unlock();
                        if (conn.live.first != null) conn.park_on_free = true;
                    };
                }
            }
        }

        /// The drain's requests now, with their GOAWAY written (the reader,
        /// which may write).
        noinline fn drainNow(conn: *Conn, timer: *Timer) std.Io.Cancelable!void {
            {
                conn.lock();
                defer conn.unlock();
                conn.drain_seen = conn.ask.get();
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
            if (comptime have_auto_cancel) {
                lazy.wake_on_drain = true;
                // Registered with this executor's shelf: a task of the
                // connection may end the wait (`wakeReader`).
                if (conn.lock_.free and burst.timer.shelf != null) conn.reader_wait = lazy;
            }
            defer if (comptime have_auto_cancel) {
                lazy.wake_on_drain = false;
                conn.reader_wait = null;
            };
            if (reader.bufferedLen() == 0) return burst.waitInput();
            if (may_park) probe.bump(.park_refused_partial);
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
                probe.bump(.park_refused_partial);
                return false;
            }
            if (conn.live.first != null or conn.writer.held() or conn.send_waiter or conn.ready.items.len != 0 or conn.awaiting.items.len != 0) return false;
            if (conn.drain.begun() or conn.proto.in == .dead or conn.ask.get() != .none) return false;
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
            probe.bump(.parks);
            return true;
        }

        /// Hangs up on a peer whose side is still open once the connection
        /// is over, so it still gets the last frames: close_notify under TLS and the send side
        /// shut, then what the peer sends is thrown away until it hangs up,
        /// `linger_timeout` passes, or `linger_limit` bytes. Where the timer
        /// cannot bound the reads only the send side is shut, as HTTP/1.x's
        /// `lingeringClose` does: the peer still reads the end now, not at
        /// the socket's close, which the caller may hold (`Engine.serve`).
        /// The tasks have ended: this is the only reader and writer. Out of
        /// line (cold).
        noinline fn lingeringClose(conn: *Conn) std.Io.Cancelable!void {
            var timer: Timer = .init(null);
            if (conn.writer != .shut) {
                {
                    var t: Timer = .init(null);
                    if (t.canBound()) t.set(conn.io, .{ .duration = .{ .raw = server_mod.linger_timeout, .clock = .awake } });
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
                probe.bump(.send_shuts);
            }
            if (!timer.canBound()) return;
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
                es.enterHandler();
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
                es.enterHandler();
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
            conn.sendReset(es, code) catch {};
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
        /// or on its own task. The router, handlers and middleware
        /// see the same request on either. On the reader the response may be
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

            // Room for an ordinary request's fields, grown up to the limit
            // for one with more, as over HTTP/1.1: most of a spare stream's
            // arena otherwise (#179).
            const max_headers = server.config.request.max_header_count;
            request.headers = http.Headers.init(arena, @min(max_headers, initial_header_room)) catch return error.OutOfMemory;
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
                request.headers.addRequestFieldUpTo(arena, f.name, f.value, max_headers) catch |err| switch (err) {
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
                request.headers.addUpTo(arena, "Host", es.authority, max_headers) catch |err| switch (err) {
                    error.TooManyHeaders => too_many = true,
                    error.OutOfMemory => return error.OutOfMemory,
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
                    request._expects_continue = !es.recv.done();
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
                // From here an end lets go itself. Already over (a park
                // that failed, or a finish or release from inside the
                // handler): the hold is the caller's to let go, as for a
                // response written in place.
                return es.handlerReturned(d);
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

        // -- Detached and parked responses --

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
            // Set by the park, before, on this task or the handler's.
            if (es.dispatch.isParked()) {
                // The end of a parked response: the last DATA (or the
                // failure's reset). The hold on the stream stays until the
                // owner's `Parked.release`.
                if (result) |_| {
                    ex.sink_state.sink().end(if (ex.response.trailers) |*t| t else null) catch {};
                } else |err| {
                    streamFailed(conn, es, err) catch {};
                }
                ex.response.deinit();
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
                conn.ownerDone(es);
            }
            conn.kickFlush();
        }

        /// The response goes on from a task: its body writes may now wait
        /// for the peer, as a handler task's do.
        fn detachedAttach(d: *Detached, spawn: Detached.Spawn) Detached.AttachError!void {
            const es = exchangeOf(d).sink_state.es;
            const conn = es.conn;
            conn.lock();
            defer conn.unlock();
            if (conn.life == .tasks_closed) return error.ConnectionClosed;
            es.dispatch = switch (es.dispatch) {
                .running_inline => .running_tasked,
                .detached_inline => |ex| .{ .detached_tasked = ex },
                .running_tasked, .detached_tasked, .running_parked, .parked => es.dispatch,
                .head, .queued_task, .inline_awaiting_body, .inline_ready, .running_ended, .done => unreachable,
            };
            return conn.spawnWith(spawn);
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
                    if (!es.resp.isEnded() and !es.reset) conn.sendReset(es, .cancel) catch {};
                }
                // Before the count drops: once it is 0 the teardown
                // (`waitParked`) may free `conn`, so the hold below that
                // drops it is the last touch of `conn`.
                conn.kickFlush();
                conn.lock();
                defer conn.unlock();
                // The stream may be freed here, with `self` in its arena.
                conn.ownerDone(es);
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
            es.dispatch = switch (es.dispatch) {
                .running_inline, .running_tasked => .{ .running_parked = p },
                .head, .queued_task, .inline_awaiting_body, .inline_ready, .running_parked, .running_ended, .detached_inline, .detached_tasked, .parked, .done => unreachable,
            };
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
                    // Before the raise: its WINDOW_UPDATE is credit too, and
                    // may be the only thing the peer waits for (a handler
                    // that reads without writing, or waits for room behind
                    // it, as an echo over TLS on a slow machine did).
                    const before = conn.proto.out.mark();
                    if (es.raise_due) conn.raiseWindow(es);
                    if (es.reset) {
                        conn.unlock();
                        return self.fail(error.ConnectionResetByPeer);
                    }
                    const n = es.body.take(dest);
                    if (n > 0) conn.proto.consumed(es.cs, n) catch {};
                    // Credit that queued a WINDOW_UPDATE (a raise, or about
                    // once a half window) is written; on the reader it goes
                    // with the read's output.
                    const queued = conn.proto.out.mark() != before and !es.dispatch.onReader();
                    if (n > 0) {
                        conn.unlock();
                        if (queued) conn.kickFlush();
                        w.advance(n);
                        return n;
                    }
                    if (es.recv.done()) {
                        conn.unlock();
                        return error.EndOfStream;
                    }
                    conn.unlock();
                    if (queued) conn.kickFlush();
                    es.wake.wait(conn.io, seen) catch {
                        conn.io.recancel();
                        return self.fail(error.Canceled);
                    };
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
            writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flushFn, .rebase = rebaseFn }, .buffer = &.{} },
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
                if (!self.es.dispatch.onReader()) self.es.conn.kickFlush();
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
                const before = es.resp;
                es.resp = before.next(.end);
                conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, bare) catch |err| {
                    es.resp = before;
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
                    const name = lowerName(arena, entry.key) catch return self.fail(error.SystemResources);
                    if (fields.token(name)) |t| {
                        // RFC 9113 §8.2.2: connection-specific fields are
                        // malformed.
                        if (fields.connectionSpecific(t)) continue;
                        has_length = has_length or t == .content_length;
                    }
                    list[n] = .{ .name = name, .value = entry.value };
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
                probe.bump(.sink_bodies);
                return &fromPtr(ptr).writer;
            }

            /// The head with no END_STREAM, once. Under the lock.
            fn submitHeadOnce(self: *StreamSink, s: *PStream) std.Io.Writer.Error!void {
                const es = self.es;
                if (es.resp.headOut()) return;
                es.conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, false) catch |err| return self.submitFailed(err);
                es.resp = es.resp.next(.head);
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
                    const head_new = !es.resp.headOut();
                    try self.submitHeadOnce(s);
                    if (n == 0) {
                        if (!head_new) return;
                    } else {
                        const part = es.arena.allocator().alloc([]const u8, 1) catch return self.fail(error.SystemResources);
                        // Room first: nothing may fail once the block is
                        // borrowed.
                        if (es.dispatch.onReader()) es.spent.ensureUnusedCapacity(es.arena.allocator(), 1) catch return self.fail(error.SystemResources);
                        part[0] = w.buffer[0..n];
                        conn.proto.submitData(s, part, false) catch |err| return self.submitFailed(err);
                        if (es.dispatch.onReader()) {
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
                        if (es.dispatch.onReader() or conn.roomFree(es)) {
                            if (es.cs == null or es.reset or conn.writer == .shut) return self.fail(error.ConnectionResetByPeer);
                            const b = &es.blocks[es.cur];
                            if (b.mem.len == 0) {
                                b.mem = conn.allocator.alloc(u8, block_len) catch return self.fail(error.SystemResources);
                                probe.bump(.blocks);
                            }
                            self.writer.buffer = b.mem;
                            return;
                        }
                        conn.watchRoom(es);
                    }
                    es.room.wait(conn.io, seen) catch {
                        conn.io.recancel();
                        return self.fail(error.Canceled);
                    };
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

            /// Room in the writer's buffer (`Response.sendFileBody`, for
            /// `sendFileAll`): the next block, as `drain` takes it. A
            /// chain's writer keeps no buffer (its bytes are copied to the
            /// chain), so it refuses there, and the caller copies through
            /// a buffer of its own.
            fn rebaseFn(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
                // SAFETY: the writer is a StreamSink's `writer`.
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                if (self.es.chain_mode) return error.WriteFailed;
                return std.Io.Writer.defaultRebase(w, preserve, capacity);
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
                // The head first (no END_STREAM: it cannot close the
                // stream), then `.ended` before the submits, as in
                // `complete`: the last one may close the stream inside the
                // call. A failure puts the phase from before the end back.
                const bare = !es.resp.headOut() and part.len == 0 and trailer_fields == null;
                if (!bare) try self.submitHeadOnce(s);
                const before = es.resp;
                es.resp = before.next(.end);
                errdefer es.resp = before;
                if (bare) {
                    conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, true) catch |err| return self.submitFailed(err);
                    return;
                }
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

            /// Appends `parts` to the body in one copy (waits while more than `max_pending`
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
            /// The await also keeps the stream's arena to one user at a
            /// time (`LocalArena`): `appendParts` allocates from it there.
            fn onOwner(self: *StreamSink, parts: ?[]const []const u8, max_pending: usize, now: bool) std.Io.Writer.Error!void {
                const conn = self.es.conn;
                probe.bump(.hops);
                var group: std.Io.Group = .init;
                var result: std.Io.Writer.Error!void = {};
                placement.concurrent(&group, conn.io, .{ .executor = conn.lock_.owner }, ownerRun, .{ self, parts, max_pending, now, &result }) catch
                    return self.fail(error.SystemResources);
                group.await(conn.io) catch {
                    // The sender's cancel stays pending for its next wait.
                    conn.io.recancel();
                    group.cancel(conn.io);
                    return self.fail(error.Canceled);
                };
                return result;
            }

            fn ownerRun(self: *StreamSink, parts: ?[]const []const u8, max_pending: usize, now: bool, result: *std.Io.Writer.Error!void) std.Io.Cancelable!void {
                try probe.holdHop(self.es.conn.io);
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
                        if (es.reset or conn.writer == .shut) return self.fail(error.ConnectionResetByPeer);
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
                    es.room.wait(conn.io, seen) catch {
                        conn.io.recancel();
                        return self.fail(error.Canceled);
                    };
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
                // As in `end`: the head first, then `.ended`.
                const bare = !es.resp.headOut() and trailer_fields == null;
                if (!bare) try self.submitHeadOnce(s);
                const before = es.resp;
                es.resp = before.next(.end);
                errdefer es.resp = before;
                if (bare) {
                    conn.proto.submitHead(s, @intCast(@backingInt(es.status)), es.resp_fields, true) catch |err| return self.submitFailed(err);
                    return;
                }
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

        fn statusHasLength(status: http.Status) bool {
            const code = @backingInt(status);
            return !(code < 200 or code == 204 or code == 304);
        }
    };
}
