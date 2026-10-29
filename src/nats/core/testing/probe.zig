//! What the client tests read of a client to order their steps, in place
//! of a sleep (TESTING.md D1, D5): the tasks waiting for a change of its
//! state. Shared by the fixture files.

const nats = @import("../root.zig");
const Client = nats.Client;

/// The tasks waiting for a change of the client's state: callers of
/// `connect()` while it connects, of `wait()`, and the like.
pub fn stateWaiters(client: *Client) u32 {
    client.mutex.lockUncancelable(client.io);
    defer client.mutex.unlock(client.io);
    return client.changed.waiters;
}

/// For `test_wait.waitUntil`: at least one task waits for a change.
pub fn stateWaitersAtLeastOne(client: *Client) bool {
    return stateWaiters(client) >= 1;
}

/// For `test_wait.waitUntil`: at least two tasks wait for a change.
pub fn stateWaitersAtLeastTwo(client: *Client) bool {
    return stateWaiters(client) >= 2;
}
