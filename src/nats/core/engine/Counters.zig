// Adapted from vkiryakov/zefir src/nats/engine/Counters.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The client's counters behind `stats()`, each atomic: tasks add to them
//! without a lock.

const std = @import("std");
const Counter = std.atomic.Value(u64);
const Counters = @This();

messages_in: Counter = .init(0),
bytes_in: Counter = .init(0),
messages_out: Counter = .init(0),
bytes_out: Counter = .init(0),
reconnects: Counter = .init(0),
request_timeouts: Counter = .init(0),
no_responders: Counter = .init(0),
/// Incoming messages dropped.
dropped_in: Counter = .init(0),
/// Nanoseconds of the last round trip; `none` before the first.
rtt: Counter = .init(none),

pub const none = std.math.maxInt(u64);

pub fn add(counter: *Counter, n: u64) void {
    _ = counter.fetchAdd(n, .monotonic);
}

pub fn get(counter: *const Counter) u64 {
    return counter.load(.monotonic);
}
