// lint-path: src/example/c3.zig
const std = @import("std");

fn swallowed(io: std.Io) void {
    io.sleep(.fromSeconds(1), .awake) catch |e| switch (e) {
        error.Canceled => {}, // expect: C3
    };
}

fn swallowedAmongOthers(io: std.Io) void {
    read(io) catch |e| switch (e) {
        error.Timeout, error.Canceled => {}, // expect: C3
        else => {},
    };
}

fn ifSwallowed(io: std.Io) void {
    read(io) catch |err| {
        if (err == error.Canceled) { // expect: C3
            log();
        }
    };
}

fn returned(io: std.Io) !void {
    read(io) catch |e| switch (e) {
        error.Canceled => return e,
        else => {},
    };
}

fn handedOn(io: std.Io) !void {
    return read(io) catch |e| switch (e) {
        error.Canceled => error.Canceled,
        else => error.Other,
    };
}

fn handedOnAsCause(io: std.Io) !void {
    return read(io) catch |cause| switch (cause) {
        error.Canceled => cause,
        else => error.Other,
    };
}

fn recanceled(io: std.Io) void {
    read(io) catch |e| switch (e) {
        error.Canceled => io.recancel(),
        else => {},
    };
}

fn ifReturned(io: std.Io) !void {
    read(io) catch |err| {
        if (err == error.Canceled) return err;
    };
}

fn brokeOut(io: std.Io) !void {
    const r = blk: {
        read(io) catch |e| switch (e) {
            error.Canceled => break :blk error.Canceled,
            else => {},
        };
        break :blk {};
    };
    try r;
}

fn tried(io: std.Io) !void {
    read(io) catch |e| switch (e) {
        error.Canceled => {
            try cleanup();
        },
        else => {},
    };
}

fn reasoned(io: std.Io) void {
    read(io) catch |e| switch (e) {
        // SAFETY: the caller's group is being torn down; nothing waits after this.
        error.Canceled => {},
        else => {},
    };
}

fn read(io: std.Io) !void {
    _ = io;
}
fn cleanup() !void {}
fn log() void {}

fn comparedNotHandled(cause: ?anyerror) bool {
    const a = if (cause) |e| e == error.Canceled else false;
    std.debug.assert(a or cause == error.Canceled);
    return cause == error.Canceled;
}

fn compoundCondition(io: std.Io, closing: bool) void {
    read(io) catch |err| {
        if (closing and err == error.Canceled) {} // expect: C3
    };
}
