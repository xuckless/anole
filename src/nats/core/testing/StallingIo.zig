//! `std.testing.io` whose socket writes can be stalled on command, for the
//! nats fixtures that need the client's writer blocked on a full socket.
//! Filling the kernel's socket buffers takes megabytes and a guess at when
//! they are full ("no publish went in for 200 ms"), which a writer that is
//! only descheduled for that long passes too (TESTING.md D5, K1). Here the
//! block is certain: once `arm`ed, the next socket write through `io()`
//! sets the `blocked` flag and waits until `release`, a shutdown or close
//! of a socket through `io()` (as a full socket's write fails once it is
//! shut down), or a cancel of the writing task; then it goes to the socket.
//! Only that one write waits: the stall disarms when it ends.
//!
//!     var client: Client = try .init(gpa, StallingIo.io(), ...);
//!     try client.connect();
//!     StallingIo.arm();
//!     defer StallingIo.reset();
//!     ... a publish: the writer takes it and blocks
//!     try test_wait.waitFlag(io, "the writer blocked", StallingIo.blocked());
//!
//! One stall at a time per process: the state is global, as the vtable
//! carries none (the test runner runs one test at a time; shards are
//! processes). The vtable is std.testing.io's with `operate`,
//! `netShutdown` and `netClose` wrapped, as reliability_tests.zig's
//! SlowClose does.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Stage = enum(u8) {
    /// No stall.
    idle,
    /// The next socket write waits.
    armed,
    /// A socket write waits now.
    blocked,
};

const State = struct {
    /// One word, so a shutdown or close always sees an armed or waiting
    /// stall: armed -> blocked is a single compare-and-swap.
    stage: std.atomic.Value(Stage) = .init(.idle),
    /// Mirrors `stage == .blocked`, for `test_wait.waitFlag`.
    blocked: std.atomic.Value(bool) = .init(false),
    /// Set to let the waiting write go on.
    release: Io.Event = .unset,
};

var state: State = .{};

const vtable: Io.VTable = vtable: {
    var v = std.testing.io.vtable.*;
    v.operate = operate;
    v.netShutdown = netShutdown;
    v.netClose = netClose;
    break :vtable v;
};

/// The `std.Io` to give the client.
pub fn io() Io {
    return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
}

/// The next socket write through `io()` waits (see the file's comment).
pub fn arm() void {
    std.debug.assert(state.stage.load(.acquire) == .idle);
    state.release.reset();
    state.stage.store(.armed, .release);
}

/// Set while a socket write waits; for `test_wait.waitFlag`.
pub fn blocked() *const std.atomic.Value(bool) {
    return &state.blocked;
}

/// Lets the waiting write go on (or the next one, if none waits yet: the
/// stall is then over).
pub fn release() void {
    // An armed stall is over; a waiting write clears its own stage.
    _ = state.stage.cmpxchgStrong(.armed, .idle, .acq_rel, .acquire);
    state.release.set(std.testing.io);
}

/// Releases any stall and clears the state for the next test. Call it in
/// the fixture's teardown, after the client is gone.
pub fn reset() void {
    release();
    state.stage.store(.idle, .release);
    state.blocked.store(false, .release);
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    if (operation == .net_write and state.stage.cmpxchgStrong(.armed, .blocked, .acq_rel, .acquire) == null) {
        state.blocked.store(true, .release);
        defer {
            state.blocked.store(false, .release);
            state.stage.store(.idle, .release);
        }
        const inner: Io = .{ .userdata = userdata, .vtable = std.testing.io.vtable };
        try state.release.wait(inner);
    }
    return std.testing.io.vtable.operate(userdata, operation);
}

fn netShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    // A write blocked on a full socket fails once the socket is shut down:
    // the stalled one goes to the socket, and fails there.
    stallEnds();
    return std.testing.io.vtable.netShutdown(userdata, handle, how);
}

fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
    stallEnds();
    std.testing.io.vtable.netClose(userdata, sockets);
}

/// A socket is shut down or closed: a stall, armed or waiting, is over.
fn stallEnds() void {
    if (state.stage.load(.acquire) != .idle) release();
}
