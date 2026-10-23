// Adapted from vkiryakov/zefir src/nats/Stats.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! What the client has done so far: `client.stats()` returns a snapshot.
//! The counts cover the client's whole life, across connections.

const std = @import("std");
const Io = std.Io;

/// Messages and their bytes, headers included, that came from the server,
/// those dropped too.
messages_in: u64,
bytes_in: u64,
/// Messages and their bytes, headers included, accepted for sending:
/// publishes, responses and requests.
messages_out: u64,
bytes_out: u64,
/// Subscriptions that take messages now.
active_subscriptions: usize,
/// Requests waiting for replies, the streams of requestMany included.
pending_requests: usize,
/// Frames waiting to be written, or to be sent on the next connection.
pending_outbound_bytes: usize,
/// What the subscriptions hold for `next()`.
pending_subscription_bytes: usize,
/// Connections made again after one was lost.
reconnects: u64,
/// Requests that ended with Timeout.
request_timeouts: u64,
/// Requests that ended with NoResponders.
no_responders: u64,
/// Messages lost: incoming ones dropped (too large, no memory, no room in
/// their subscription) and publishes never sent.
dropped_messages: u64,
/// Publishes, responses and requests written to a connection that was
/// lost, or closed by `close()` or by giving up, before the server
/// confirmed them: they may or may not have arrived, and are never sent
/// again.
uncertain_outbound_frames: u64,
/// Replies that came after their request ended.
late_responses: u64,
/// Events dropped because the queue of events was full, or there was no
/// memory for one.
dropped_events: u64,
/// The round trip of the last `flush` or `rtt`; null before the first.
rtt: ?Io.Duration,
/// How long the current connection has been up; null without one.
connected_for: ?Io.Duration,
