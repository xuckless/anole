// Adapted from vkiryakov/zefir src/nats/engine/manager.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The client's tasks. The manager opens the connection, starts its reader
//! and writer and sends heartbeat PINGs. When the connection must end, it
//! takes it down in order: the queues stop and wake their waiters, the
//! socket is shut down, the reader and writer are canceled and awaited, and
//! only then does the socket close. Then it connects again, as the
//! reconnect options say, going round the pool of servers, and a new
//! connection first subscribes to everything the old one had; or the client
//! closes.
//!
//! A task blocked on a socket is never left to cancellation alone: code a
//! task calls may swallow `error.Canceled` (std's stack capture in a Debug
//! allocator does), and on `std.Io.Threaded` the task's later syscalls then
//! cannot be interrupted. A shutdown of the socket wakes it either way.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("../Client.zig");
const ServerAddress = @import("../ServerAddress.zig");
const Options = @import("../Options.zig");
const ServerInfo = @import("../ServerInfo.zig");
const Message = @import("../Message.zig");
const Parser = @import("../protocol/Parser.zig");
const server_error = @import("../protocol/server_error.zig");
const Connection = @import("Connection.zig");
const Registry = @import("Registry.zig");
const Pool = @import("Pool.zig");
const Outbound = @import("Outbound.zig");
const Counters = @import("Counters.zig");
const Inbox = @import("Inbox.zig");
const backoff = @import("backoff.zig");
const events = @import("../events.zig");
const incoming = @import("incoming.zig");
const dialer = @import("connect.zig");
const time = @import("time.zig");
const log = std.log.scoped(.nats);

/// Why a connection ends.
pub const Exit = union(enum) {
    /// `close()`.
    closed,
    /// The server closed the connection.
    end_of_stream,
    /// The server left PINGs unanswered.
    stale,
    /// The server sent a `-ERR` after which it closes the connection.
    server_error: server_error.Kind,
    /// The server broke the protocol.
    protocol,
    /// Reading from the socket failed.
    read: Connection.ReadError,
    /// Writing to the socket failed.
    write: Connection.WriteError,
    /// The server is about to go away, and another one is in the pool.
    lame_duck,
    /// The reader or writer could not start: the `io` had no room for it.
    no_tasks,
};

/// The manager task: from `connect()` until the client closes.
pub fn run(client: *Client) void {
    var pacing: Pacing = .{};
    var next: ?Opened = if (client.options.options.retry_initial_connect)
        reconnect(client, &pacing, false)
    else
        openFirst(client) catch |err| {
            connectFailed(client, err);
            return;
        };
    while (next) |opened| {
        const server = opened.server;
        pacing.up_since = Io.Clock.awake.now(client.io);
        const exit = serve(client, opened);
        // Its life ends when its exit is known: the teardown, slow on a
        // busy host, is no part of it for the pacing.
        pacing.down_at = Io.Clock.awake.now(client.io);
        next = if (teardown(client, server, exit)) reconnect(client, &pacing, exit == .lame_duck) else null;
    }
}

/// How fast the client reconnects. A connection that lasted at least
/// `reconnect.max_delay` was a good one: the next reconnect starts at once.
/// One that did not counts as a failed attempt for the waits, so a server
/// that drops every connection right after the handshake is tried again
/// only after growing waits, never in a tight loop.
const Pacing = struct {
    /// Failed attempts and short connections in a row.
    level: u32 = 0,
    /// When the last connection came up.
    up_since: ?Io.Timestamp = null,
    /// When the exit of the last connection was known, before its teardown.
    down_at: ?Io.Timestamp = null,

    /// The connection is lost: was it a good one? Leaving a server in lame
    /// duck mode is no failure, and the move is immediate, once the
    /// connection lasted `min_delay`: servers that announce lame duck mode
    /// as soon as a client connects are paced like any that drop it.
    fn lost(p: *Pacing, io: Io, options: Options.ReconnectOptions, lame_duck: bool) void {
        const since = p.up_since orelse return;
        p.up_since = null;
        const until = p.down_at orelse Io.Clock.awake.now(io);
        p.down_at = null;
        const stable = if (lame_duck) options.min_delay else options.max_delay;
        if (since.durationTo(until).nanoseconds >= stable.nanoseconds) {
            p.level = 0;
        } else {
            p.level +|= 1;
        }
    }
};

/// Makes `opened` the client's connection and keeps it until it must end;
/// then says why. A reader or writer that cannot start ends it like a
/// loss, and the client reconnects as for any.
fn serve(client: *Client, opened: Opened) Exit {
    const io = client.io;
    client.connection = opened.connection;
    // Before the reader starts: an INFO it reads is newer than this one.
    const lame_duck = adopt(client, opened.server, opened.greeting);
    // Connected before the reader starts: who gets a reply from this
    // connection finds the client connected. A client that closed
    // meanwhile takes the connection down at once.
    _ = connected(client, opened.server) orelse return .closed;
    client.connection_tasks.concurrent(io, readLoop, .{client}) catch return .no_tasks;
    client.connection_tasks.concurrent(io, writeLoop, .{client}) catch return .no_tasks;
    log.debug("connected to {f}", .{opened.server});
    // A server already going away when the handshake ended.
    if (lame_duck) lameDuck(client);
    return heartbeat(client);
}

/// Connects again after the connection was lost, or for the first time
/// with `retry_initial_connect`: the first attempt at once, then after
/// growing waits, going round the pool. Null when the client closed, or
/// gave up after `max_attempts` failures in a row and closed.
fn reconnect(client: *Client, pacing: *Pacing, lame_duck: bool) ?Opened {
    const io = client.io;
    const options = &client.options.options;
    if (!beginReconnecting(client)) return null;
    pacing.lost(io, options.reconnect, lame_duck);
    // Failed attempts in a row, for `max_attempts`; a connection resets it.
    var failures: u32 = 0;
    while (true) {
        if (pacing.level > 0) {
            const wait = backoff.delay(options.reconnect, pacing.level, randomNumber(io));
            if (awaitExit(client, time.after(io, wait)) != null) return null;
        }
        const server = client.pool.next(io);
        var state: AttemptState = .{};
        if (!track(client, &state)) return null;
        defer untrack(client);
        log.debug("reconnecting to {f}", .{server});
        client.events.push(io, .{ .reconnecting = .{ .server = server, .attempt = failures +| 1 } });
        const deadline = time.after(io, options.connect_timeout);
        const abort: dialer.Abort = .{ .context = &state, .function = AttemptState.abort };
        if (dialer.race(io, deadline, attempt, .{ client, &server, &state }, Opened.release, abort)) |opened| {
            _ = client.pool.noteAttempt(io, null);
            if (restored(client, opened)) return opened;
        } else |err| switch (err) {
            // close() stops the attempts.
            error.Canceled => return null,
            // A server that refuses the credentials twice the same way in
            // a row does not change its mind: the client stops.
            error.AuthenticationFailed => {
                log.debug("{f} refused the credentials", .{server});
                client.events.push(io, .{ .auth_error = server });
                if (client.pool.noteAttempt(io, state.refused) and options.reconnect.abort_on_auth_error) {
                    log.debug("{f} refused the credentials twice: closing", .{server});
                    giveUp(client, .auth_failed);
                    return null;
                }
            },
            // An io out of room for the attempt's tasks fails this attempt
            // like any other: the next one may find room.
            else => {
                log.debug("could not reconnect to {f}: {t}", .{ server, err });
                _ = client.pool.noteAttempt(io, null);
            },
        }
        failures +|= 1;
        pacing.level +|= 1;
        if (options.reconnect.max_attempts) |max| {
            if (failures >= max) {
                log.debug("no connection after {d} attempts: closing", .{failures});
                giveUp(client, .reconnect_failed);
                return null;
            }
        }
    }
}

/// The new connection first subscribes to everything the subscriptions
/// and the inbox had, before any frame that waits; false, and the
/// connection is dropped, when there is no memory for that or the client
/// closed.
fn restored(client: *Client, opened: Opened) bool {
    // What waited for this connection is checked against this server.
    const server: Outbound.ServerLimits = .{ .max_payload = maxPayload(opened.greeting.max_payload), .headers = opened.greeting.headers };
    const dropped = client.outbound.restore(client.io, client, restoreFrames, requestWaits, requestRefused, server) catch |err| {
        if (err == error.OutOfMemory) log.warn("no memory to subscribe again on {f}: connection dropped", .{opened.server});
        Opened.release(client.io, opened);
        return false;
    };
    if (dropped > 0) log.debug("{d} publishes waiting for {f} are more than it takes", .{ dropped, opened.server });
    noteDropped(client, .{ .dropped = dropped });
    return true;
}

/// SUB of every subscription that still takes messages and of the inbox,
/// with the SIDs they had, and `UNSUB sid n` for those that end after a
/// number of messages. It runs under the outbound queue's mutex.
fn restoreFrames(client: *Client, gpa: Allocator) Allocator.Error![]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    var subject: [Inbox.prefix_len + 1]u8 = undefined;
    const inbox: ?Registry.Resubscribe = if (client.inbox.restoreSub(client.io, &subject)) |sid| .{ .subject = &subject, .sid = sid } else null;
    client.subscriptions.writeRestore(client.io, &w.writer, inbox) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

/// A request whose frame waited for this connection is still waiting for
/// its reply; it runs under the outbound queue's mutex.
pub fn requestWaits(client: *Client, id: u64) bool {
    return client.inbox.awaitsReply(client.io, id);
}

/// The new server would refuse the frame of request `id`: the request
/// fails with Disconnected. It runs under the outbound queue's mutex.
fn requestRefused(client: *Client, id: u64) void {
    client.inbox.refuse(client.io, id);
}

fn randomNumber(io: Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

/// A connection that passed the handshake.
const Opened = struct {
    connection: Connection,
    greeting: Connection.Greeting,
    server: ServerAddress,
    gpa: Allocator,

    fn release(io: Io, opened: Opened) void {
        opened.connection.stream.close(io);
        opened.gpa.free(opened.greeting.info_json);
    }
};

/// Tries the servers of the pool in its order, one attempt each; the first
/// that takes the connection wins.
fn openFirst(client: *Client) Client.ConnectError!Opened {
    const io = client.io;
    var last_error: Client.ConnectError = error.ConnectionClosed;
    for (0..client.pool.count(io)) |_| {
        const server = client.pool.next(io);
        var state: AttemptState = .{};
        if (!track(client, &state)) return error.Canceled;
        defer untrack(client);
        log.debug("connecting to {f}", .{server});
        const deadline = time.after(io, client.options.options.connect_timeout);
        const abort: dialer.Abort = .{ .context = &state, .function = AttemptState.abort };
        if (dialer.race(io, deadline, attempt, .{ client, &server, &state }, Opened.release, abort)) |opened| {
            _ = client.pool.noteAttempt(io, null);
            if (restored(client, opened)) return opened;
            last_error = error.OutOfMemory;
        } else |err| switch (err) {
            // close() stops the attempts, and a server that refuses the
            // credentials ends them.
            error.Canceled, error.ConcurrencyUnavailable, error.AuthenticationFailed => return err,
            else => {
                log.debug("could not connect to {f}: {t}", .{ server, err });
                last_error = err;
            },
        }
    }
    return last_error;
}

/// The socket of an attempt in progress, for the manager or `close()` to
/// shut down: the attempt may have lost its cancellation and would wait on
/// the socket for good. The mutex keeps shutdown off a closed socket.
pub const AttemptState = struct {
    mutex: Io.Mutex = .init,
    stream: ?Io.net.Stream = null,
    aborted: bool = false,
    /// How the server refused the credentials, when it did.
    refused: ?server_error.Refusal = null,

    /// Makes the attempt end soon: now, or as soon as it has a socket.
    pub fn stop(state: *AttemptState, io: Io) void {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        state.aborted = true;
        if (state.stream) |stream| shutdown(io, stream);
    }

    fn abort(context: *anyopaque, io: Io) void {
        const state: *AttemptState = @ptrCast(@alignCast(context));
        state.stop(io);
    }

    /// Registers the attempt's stream; false when the attempt was aborted
    /// already.
    fn hold(state: *AttemptState, io: Io, stream: Io.net.Stream) bool {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.aborted) return false;
        state.stream = stream;
        return true;
    }

    /// From here on the attempt's stream is no longer the manager's to touch.
    fn release(state: *AttemptState, io: Io) void {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        state.stream = null;
    }
};

/// DNS, TCP and the handshake with one server.
fn attempt(client: *Client, server: *const ServerAddress, state: *AttemptState) (dialer.DialError || Connection.HandshakeError)!Opened {
    const io = client.io;
    const stream = try dialer.dial(io, server);
    if (!state.hold(io, stream)) {
        stream.close(io);
        return error.Timeout;
    }
    var connection: Connection = .init(stream, io, client.read_buffer, client.parser_limits);
    const greeting = connection.handshake(io, client.gpa, .init(&client.options.options)) catch |err| {
        state.refused = connection.refused;
        state.release(io);
        stream.close(io);
        return err;
    };
    state.release(io);
    return .{ .connection = connection, .greeting = greeting, .server = server.*, .gpa = client.gpa };
}

/// Shuts `stream` down both ways: a read blocked on it returns the end of
/// the stream and a blocked write fails, whether or not their tasks still
/// see cancellation. The socket stays open for its owner to close.
fn shutdown(io: Io, stream: Io.net.Stream) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    stream.shutdown(io, .both) catch {};
}

/// Sends a PING every `ping_interval` until the connection must end. After
/// `max_outstanding_pings` PINGs written without a PONG the connection is
/// dead; a PING still waiting behind a slow link's backlog does not count,
/// since the server cannot have seen it. A server that stops reading never
/// sees the PINGs at all: when the writer sent nothing for as many
/// intervals while frames waited, the connection is dead too.
fn heartbeat(client: *Client) Exit {
    const io = client.io;
    const options = &client.options.options;
    var last_sent: u64 = 0;
    var stuck: u32 = 0;
    while (true) {
        if (awaitExit(client, time.after(io, options.ping_interval))) |exit| return exit;
        const health = client.outbound.health(io);
        if (health.pings_out >= options.max_outstanding_pings) return .stale;
        const sent = client.connection.sent.load(.monotonic);
        stuck = if (health.waiting and sent == last_sent) stuck + 1 else 0;
        if (stuck >= options.max_outstanding_pings) return .stale;
        last_sent = sent;
        _ = client.outbound.putPing(io, .heartbeat) catch |err| switch (err) {
            error.Closed => return .closed,
            // The connection is being taken down: the exit comes next.
            error.Disconnected => {},
            error.OutOfMemory => log.warn("no memory for a heartbeat PING", .{}),
        };
    }
}

/// Takes the connection down: the queues stop and wake their waiters, the
/// socket is shut down so that no read or write blocks any more, the reader
/// and writer are canceled and awaited, and only then does the socket
/// close. True when the client goes on to reconnect; otherwise it is
/// closed. Nothing here can be canceled.
fn teardown(client: *Client, server: ServerAddress, exit: Exit) bool {
    const io = client.io;
    switch (exit) {
        .closed => log.debug("connection to {f} closed", .{server}),
        .end_of_stream => log.debug("{f} closed the connection", .{server}),
        .stale => log.debug("{f} did not answer PING: connection dropped", .{server}),
        .server_error => |kind| log.debug("{f} ends the connection after {t}", .{ server, kind }),
        .protocol => log.warn("{f} broke the protocol: connection dropped", .{server}),
        .read => |err| log.debug("reading from {f} failed: {t}", .{ server, err }),
        .write => |err| log.debug("writing to {f} failed: {t}", .{ server, err }),
        .lame_duck => log.debug("{f} goes away: moving to another server", .{server}),
        .no_tasks => log.warn("no room in the io for the reader and writer of {f}: connection dropped", .{server}),
    }
    const again = lost(client, exit);
    // After the state changed: who takes the event sees the new state.
    if (disconnectReason(exit)) |reason| {
        switch (exit) {
            .protocol => client.events.push(io, .{ .protocol_error = server }),
            .server_error => |kind| switch (kind) {
                .authentication_failed => client.events.push(io, .{ .auth_error = server }),
                .protocol => client.events.push(io, .{ .protocol_error = server }),
                else => {},
            },
            else => {},
        }
        client.events.push(io, .{ .disconnected = .{ .server = server, .reason = reason } });
    }
    if (again) {
        // No frame goes to the lost connection any more; then its requests
        // fail at once, and those whose frames wait for the next one go
        // on. A request and its frame share a fate (Outbound.putRequest).
        const next = client.outbound.halt(io);
        client.inbox.disconnect(io, next);
    } else {
        // Before the outbound queue wakes them, requests learn why. After a
        // drain, the streams of requestMany keep what they received, whether
        // this or the drain's close ends the inbox first.
        if (closeReason(client) == .drained) client.inbox.endDrained(io) else client.inbox.end(io, if (exit == .closed) .closed else .disconnected);
        client.outbound.close(io);
    }
    shutdown(io, client.connection.stream);
    client.connection_tasks.cancel(io);
    client.connection.stream.close(io);
    if (!again) {
        disconnected(client);
        noteDropped(client, client.outbound.discard(io));
        announceClosed(client);
        return false;
    }
    // Nothing the connection left is sent again: publishes it never wrote
    // wait in the reconnect buffer.
    noteDropped(client, client.outbound.settle(io));
    return true;
}

/// What the `disconnected` event says of an exit; null for `close()`.
fn disconnectReason(exit: Exit) ?events.Event.Disconnected.Reason {
    return switch (exit) {
        .closed => null,
        .end_of_stream => .closed_by_server,
        .stale => .stale,
        .server_error => .server_error,
        .protocol => .protocol_error,
        .read, .write, .no_tasks => .io_error,
        .lame_duck => .lame_duck,
    };
}

/// Publishes that never went out are dropped: an event says how many.
pub fn noteDropped(client: *Client, settled: Outbound.Settled) void {
    if (settled.dropped == 0) return;
    log.warn("{d} publishes never sent: dropped", .{settled.dropped});
    client.events.push(client.io, .{ .message_dropped = .{ .reason = .unsent, .count = settled.dropped } });
}

/// The client closed: the last event says why.
pub fn announceClosed(client: *Client) void {
    const reason = reason: {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        break :reason client.close_reason orelse .closed;
    };
    client.events.push(client.io, .{ .closed = reason });
}

/// The connection is gone: true when the client reconnects, and it is
/// reconnecting from now on. Not after `close()`, during drain, or with
/// reconnect off.
fn lost(client: *Client, exit: Exit) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.server = null;
    client.connected_at = null;
    if (client.info_json) |json| client.gpa.free(json);
    client.info_json = null;
    const again = exit != .closed and client.status == .connected and client.options.options.reconnect.enabled;
    if (again) {
        client.status = .reconnecting;
    } else {
        // Closed before the queues wake their waiters: a drain learns why.
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = .connection_lost;
    }
    client.changed.wake(client.io);
    return again;
}

/// Why the client closed; null while it is open.
fn closeReason(client: *Client) ?Client.CloseReason {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return client.close_reason;
}

/// Reconnecting starts: false when the client closed meanwhile.
fn beginReconnecting(client: *Client) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.status == .closed) return false;
    client.exit = null;
    client.exit_taken = false;
    return true;
}

/// The client gives up reconnecting and closes: every task waiting in it
/// gets ConnectionClosed.
fn giveUp(client: *Client, reason: Client.CloseReason) void {
    const io = client.io;
    {
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = reason;
        if (client.exit == null) client.exit = .closed;
        client.changed.wake(io);
    }
    endAll(client);
}

/// The client closed without a connection: requests, the outbound queue
/// and the subscriptions end, what never went out is counted, and the last
/// event says why.
fn endAll(client: *Client) void {
    const io = client.io;
    client.inbox.end(io, .closed);
    client.outbound.close(io);
    client.subscriptions.closeAll(io);
    noteDropped(client, client.outbound.discard(io));
    announceClosed(client);
}

/// The reader task of a connection: frames from the server.
fn readLoop(client: *Client) void {
    const io = client.io;
    // The message being read; freed if the reader stops half way.
    var current: ?Incoming = null;
    defer if (current) |*c| c.abandon();
    // Messages are being dropped (too large, no memory) since the last one
    // kept: one warning per run of drops, the others at debug.
    var losing = false;
    while (true) {
        const frame = client.connection.next() catch |err| {
            if (readExit(err)) |exit| lose(client, exit);
            return;
        };
        switch (frame) {
            .ping => client.outbound.queuePong(io),
            .pong => client.outbound.pongReceived(io),
            .ok => {},
            .info => |json| updateInfo(client, json) catch |err| switch (err) {
                error.ProtocolError => {
                    lose(client, .protocol);
                    return;
                },
                error.OutOfMemory => log.warn("no memory to keep the server's INFO", .{}),
            },
            .err => |text| {
                log.warn("server error: {f}", .{server_error.printable(text)});
                const classified = server_error.classify(text);
                // It counts as the server's first refusal for reconnecting.
                if (classified.kind == .authentication_failed) _ = client.pool.noteAttempt(io, server_error.refusal(text));
                if (classified.kind.closesConnection()) {
                    lose(client, .{ .server_error = classified.kind });
                    return;
                }
                // A refused publish only costs that message; a refused
                // subscription ends, and a refused inbox fails the requests.
                if (classified.permission) |permission| {
                    var sid = permission.sid;
                    if (permission.operation == .subscribe) {
                        if (client.inbox.deny(io, permission)) {
                            log.debug("the inbox subscription was refused: requests fail with PermissionDenied", .{});
                            sid = client.inbox.sid.load(.acquire);
                        } else if (client.subscriptions.deny(io, permission)) |denied| {
                            log.debug("subscription {d} refused", .{denied});
                            sid = denied;
                        }
                    }
                    client.events.push(io, .{ .permission_denied = .{
                        .operation = switch (permission.operation) {
                            .publish => .publish,
                            .subscribe => .subscribe,
                            .reply => .reply,
                        },
                        .subject = .init(permission.subject),
                        .sid = sid,
                    } });
                } else {
                    client.events.push(io, .{ .server_error = .init(text) });
                }
            },
            .msg => |msg| {
                // The parser ends every message before the next; even so,
                // nothing half read may leak.
                if (current) |*c| c.abandon();
                current = .begin(client, msg);
            },
            .body => |bytes| if (current) |*c| c.append(bytes),
            .msg_end => if (current) |*c| {
                c.finish(client, &losing);
                current = null;
            },
        }
    }
}

/// Why a failed read ends the connection; null when the reader was
/// canceled. A read after this client shut the socket down fails too: on
/// Windows with Unexpected, which std prints in Debug builds (it does not
/// map the status PIPE_DISCONNECTED). That is the end of the connection,
/// logged at debug like any read error, and the reason given first stays.
fn readExit(err: Connection.ReadError) ?Exit {
    return switch (err) {
        error.Canceled => null,
        error.EndOfStream => .end_of_stream,
        error.LineTooLong, error.UnknownOperation, error.InvalidArguments, error.MissingTerminator => .protocol,
        else => |e| .{ .read = e },
    };
}

/// A message the reader is in the middle of. It is kept only when a
/// subscription or a waiting request takes it and it is within the limits;
/// otherwise its bytes are read past without an allocation.
const Incoming = struct {
    sid: u64,
    /// Bytes of the header block and payload, as announced.
    total_len: u32,
    assembly: ?incoming.Assembly,
    skipped: Skipped,
    /// The request a reply on the inbox names; null for a subscription's
    /// message.
    request: ?u64,

    const Skipped = enum {
        /// Kept.
        no,
        /// No subscription takes it, or it came to the inbox under a
        /// subject that names no request: dropped without a word.
        unrouted,
        /// A reply no request waits for: counted as late.
        late,
        /// Over `max_inbound_frame_bytes` or `max_header_bytes`, or more
        /// than its subscription holds even when empty.
        too_large,
        no_memory,
    };

    fn begin(client: *Client, msg: Parser.Msg) Incoming {
        Counters.add(&client.counters.messages_in, 1);
        Counters.add(&client.counters.bytes_in, msg.total_len);
        var in: Incoming = .{ .sid = msg.sid, .total_len = msg.total_len, .assembly = null, .skipped = .no, .request = null };
        const limits = &client.options.options.limits;
        const holds = if (client.inbox.owns(msg.sid)) reply: {
            const id = client.inbox.requestId(msg.subject) orelse {
                in.skipped = .unrouted;
                return in;
            };
            in.request = id;
            break :reply client.inbox.accepts(client.io, id) orelse {
                in.skipped = .late;
                return in;
            };
        } else client.subscriptions.accepts(client.io, msg.sid) orelse {
            in.skipped = .unrouted;
            return in;
        };
        if (msg.total_len > limits.max_inbound_frame_bytes or msg.header_len > limits.max_header_bytes or
            incoming.Assembly.size(msg) > holds)
        {
            in.skipped = .too_large;
        } else if (incoming.Assembly.begin(client.gpa, msg)) |assembly| {
            in.assembly = assembly;
        } else |_| {
            in.skipped = .no_memory;
        }
        return in;
    }

    fn append(in: *Incoming, bytes: []const u8) void {
        if (in.assembly) |*assembly| assembly.append(bytes);
    }

    /// The message is complete: to its subscription, which counts it even
    /// when it could not be kept.
    fn finish(in: *Incoming, client: *Client, losing: *bool) void {
        if (in.skipped == .unrouted) return;
        if (in.request) |id| return in.finishReply(client, id, losing);
        const message: ?Message = if (in.assembly) |*assembly| assembly.finish() else null;
        const pushed = client.subscriptions.deliver(client.io, in.sid, message) orelse return;
        Counters.add(&client.counters.dropped_in, pushed.dropped);
        in.noteDropped(client, in.sid, losing);
        if (in.skipped == .no and pushed.dropped == 0) losing.* = false;
        if (pushed.no_memory) {
            log.debug("no memory to queue a message for subscription {d}: dropped", .{in.sid});
            client.events.push(client.io, .{ .message_dropped = .{ .reason = .no_memory, .count = 1, .sid = in.sid } });
        }
        // One warning and one event per run of drops.
        if (pushed.overflow_began) {
            log.warn("subscription {d} is a slow consumer: messages dropped", .{in.sid});
            client.events.push(client.io, .{ .slow_consumer = in.sid });
        }
        if (pushed.ended == .slow_consumer) {
            log.debug("subscription {d} is a slow consumer: closed", .{in.sid});
            // The reader cannot wait for room: the UNSUB goes in at once.
            Registry.queueUnsub(&client.outbound, client.io, in.sid) catch |err| {
                log.debug("no UNSUB for subscription {d}: {t}", .{ in.sid, err });
            };
        }
    }

    /// A message read past: its event, and a warning for the first of a
    /// run of drops. `sid` is null for a reply to a request.
    fn noteDropped(in: *const Incoming, client: *Client, sid: ?u64, losing: *bool) void {
        const reason: events.Event.MessageDropped.Reason = switch (in.skipped) {
            .no, .unrouted, .late => return,
            .too_large => .too_large,
            .no_memory => .no_memory,
        };
        if (losing.*) {
            if (sid) |s| {
                log.debug("a message of {d} bytes for subscription {d} dropped: {t}", .{ in.total_len, s, reason });
            } else {
                log.debug("a reply of {d} bytes dropped: {t}", .{ in.total_len, reason });
            }
        } else {
            if (sid) |s| {
                log.warn("a message of {d} bytes for subscription {d} dropped: {t}; more drops before a message is kept go to debug", .{ in.total_len, s, reason });
            } else {
                log.warn("a reply of {d} bytes dropped: {t}; more drops before a message is kept go to debug", .{ in.total_len, reason });
            }
        }
        losing.* = true;
        client.events.push(client.io, .{ .message_dropped = .{ .reason = reason, .count = 1, .sid = sid } });
    }

    /// The reply to request `id` is complete: to the request, or late.
    fn finishReply(in: *Incoming, client: *Client, id: u64, losing: *bool) void {
        if (in.skipped == .late) return client.inbox.noteLate(client.io);
        const message: ?Message = if (in.assembly) |*assembly| assembly.finish() else null;
        const delivery = client.inbox.deliver(client.io, id, message);
        if (delivery == .dropped) Counters.add(&client.counters.dropped_in, 1);
        in.noteDropped(client, null, losing);
        if (in.skipped == .no and delivery == .taken) losing.* = false;
    }

    fn abandon(in: *Incoming) void {
        if (in.assembly) |*assembly| assembly.discard();
    }
};

/// The writer task of a connection: batches from the outbound queue.
fn writeLoop(client: *Client) void {
    const io = client.io;
    var slices: [16][]const u8 = undefined;
    while (true) {
        const batch = (client.outbound.take(io, &slices) catch return) orelse return;
        var sent: usize = 0;
        client.connection.writeAll(io, batch.slices, &sent) catch |err| {
            client.outbound.written(io, sent);
            if (err != error.Canceled) lose(client, .{ .write = err });
            return;
        };
        client.outbound.written(io, batch.len);
    }
}

/// The first connection failed, or the manager could not start: the
/// client closes, and with it what was made meanwhile, as subscriptions
/// and publishes are while `retry_initial_connect` waits.
pub fn connectFailed(client: *Client, err: Client.ConnectError) void {
    const io = client.io;
    {
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        if (client.status == .connecting) client.connect_error = err;
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = .connect_failed;
        if (client.exit == null) client.exit = .closed;
        client.changed.wake(io);
    }
    endAll(client);
}

/// The connection passed its handshake with `server`; the INFO of
/// `greeting` is now the client's, and the servers it announces join the
/// pool. True when that INFO says the server is in lame duck mode.
fn adopt(client: *Client, server: ServerAddress, greeting: Connection.Greeting) bool {
    var lame_duck = false;
    if (ServerInfo.parse(client.gpa, greeting.info_json)) |info| {
        defer info.deinit();
        discover(client, info.value);
        lame_duck = info.value.ldm;
    } else |err| log.debug("the INFO of the handshake is unreadable now: {t}", .{err});
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.server = server;
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = greeting.info_json;
    client.server_headers = greeting.headers;
    client.max_payload = maxPayload(greeting.max_payload);
    return lame_duck;
}

/// The server is about to go away: the client moves to another one at once
/// when the pool has one and reconnecting is on; otherwise it stays until
/// the server closes the connection.
fn lameDuck(client: *Client) void {
    log.debug("the server is entering lame duck mode", .{});
    if (client.pool.currentServer(client.io)) |server| client.events.push(client.io, .{ .lame_duck = server });
    if (!client.options.options.reconnect.enabled or client.pool.count(client.io) < 2) return;
    // A drain finishes on this server: only a connected client moves, and
    // the check and the move are one step against drain().
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.status != .connected) return;
    if (client.exit == null) client.exit = .lame_duck;
    client.changed.wake(client.io);
}

/// The servers an INFO announces join the pool, and the discovered ones it
/// no longer names leave it.
fn discover(client: *Client, info: ServerInfo) void {
    if (client.options.options.ignore_discovered_servers) return;
    client.pool.update(client.io, info.connect_urls, PoolEvents{ .client = client });
}

/// Turns the changes of the pool into events.
const PoolEvents = struct {
    client: *Client,

    pub fn discovered(e: PoolEvents, server: ServerAddress) void {
        e.client.events.push(e.client.io, .{ .server_discovered = server });
    }

    pub fn removed(e: PoolEvents, server: ServerAddress) void {
        e.client.events.push(e.client.io, .{ .server_removed = server });
    }
};

/// The `max_payload` of an INFO; 0 when the server gave none, or one that
/// cannot be a size.
fn maxPayload(announced: i64) u64 {
    return if (announced > 0) @intCast(announced) else 0;
}

/// The connection to `server` is up; true when it is the first, null when
/// the client closed meanwhile: no event then, and nothing counted.
fn connected(client: *Client, server: ServerAddress) ?bool {
    const first = first: {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        if (client.status != .connecting and client.status != .reconnecting) return null;
        client.status = .connected;
        client.connected_at = Io.Clock.awake.now(client.io);
        client.changed.wake(client.io);
        defer client.ever_connected = true;
        break :first !client.ever_connected;
    };
    if (!first) Counters.add(&client.counters.reconnects, 1);
    client.events.push(client.io, if (first) .{ .connected = server } else .{ .reconnected = server });
    return first;
}

/// The connection is gone, and with it the client and its subscriptions.
fn disconnected(client: *Client) void {
    {
        client.mutex.lockUncancelable(client.io);
        defer client.mutex.unlock(client.io);
        client.status = .closed;
        if (client.close_reason == null) client.close_reason = .connection_lost;
        client.server = null;
        client.connected_at = null;
        if (client.info_json) |json| client.gpa.free(json);
        client.info_json = null;
        client.changed.wake(client.io);
    }
    client.subscriptions.closeAll(client.io);
}

/// Lets `close()` stop the attempt; false when the client is closing.
fn track(client: *Client, state: *AttemptState) bool {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.exit != null) return false;
    client.attempt = state;
    return true;
}

fn untrack(client: *Client) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.attempt = null;
}

/// Asks the manager to end the connection; the first reason given stays.
fn lose(client: *Client, exit: Exit) void {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    if (client.exit == null) client.exit = exit;
    client.changed.wake(client.io);
}

/// Waits until the connection must end, or until `deadline`: null then.
fn awaitExit(client: *Client, deadline: Io.Clock.Timestamp) ?Exit {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    while (true) {
        if (client.exit) |exit| {
            client.exit_taken = true;
            return exit;
        }
        // A wait may end early: the deadline decides.
        if (time.expired(client.io, deadline)) return null;
        // Only close() and deinit() cancel the manager.
        client.changed.wait(client.io, &client.mutex, deadline) catch return .closed;
    }
}

/// Keeps the server's latest INFO. Its `max_payload` applies from now on,
/// such as the limit of the user's account in the INFO after CONNECT, even
/// when there is no memory to keep the INFO itself. Headers stay as CONNECT
/// settled them.
fn updateInfo(client: *Client, json: []const u8) ServerInfo.ParseError!void {
    const info = try ServerInfo.parse(client.gpa, json);
    defer info.deinit();
    discover(client, info.value);
    if (info.value.ldm) lameDuck(client);
    const copy = client.gpa.dupe(u8, json) catch null;
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    client.max_payload = maxPayload(info.value.max_payload);
    const kept = copy orelse return error.OutOfMemory;
    if (client.info_json) |old| client.gpa.free(old);
    client.info_json = kept;
}

const testing = std.testing;

test "a failed read ends the connection as a read error, not as broken protocol" {
    // Windows reports a read after our own shutdown so.
    try testing.expectEqual(Exit{ .read = error.Unexpected }, readExit(error.Unexpected).?);
    try testing.expectEqual(Exit{ .read = error.ConnectionResetByPeer }, readExit(error.ConnectionResetByPeer).?);
    try testing.expectEqual(Exit.end_of_stream, readExit(error.EndOfStream).?);
    try testing.expectEqual(Exit.protocol, readExit(error.MissingTerminator).?);
    try testing.expect(readExit(error.Canceled) == null);
}

test "a connection made after the client closed changes nothing: no event, no reconnect counted" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    client.close();
    _ = try client.nextEvent(.{});
    client.ever_connected = true;
    try testing.expect(connected(&client, client.options.servers[0]) == null);
    try testing.expectEqual(0, client.stats().reconnects);
    try testing.expect(client.stats().connected_for == null);
}
