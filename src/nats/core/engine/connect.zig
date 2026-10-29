// Adapted from vkiryakov/zefir src/nats/engine/connect.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Opening a TCP connection to a server, and running an attempt against a
//! deadline. `std.Io` has no portable connect timeout (Io.Threaded panics
//! on `ConnectOptions.timeout`), so a whole attempt, DNS, TCP and the
//! handshake, runs in a task of its own and races a timer.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ServerAddress = @import("../ServerAddress.zig");
const time = @import("time.zig");

const ClientStream = @import("../../../net/client_stream.zig").ClientStream;
const ConnectOptions = @import("../../../net/client_stream.zig").ConnectOptions;

pub const DialError = net.IpAddress.ConnectError || net.HostName.ConnectError ||
    net.HostName.ValidateError || net.Ip6Address.ResolveError || error{OutOfMemory};

/// Resolves `address` and opens a TCP connection to it (TLS from the first
/// byte when `tls` is given). It has no time limit of its own: run it
/// under `race`.
pub fn dial(io: Io, gpa: std.mem.Allocator, address: *const ServerAddress) DialError!*ClientStream {
    return dialWith(io, gpa, address, null);
}

pub fn dialWith(io: Io, gpa: std.mem.Allocator, address: *const ServerAddress, tls: ?ConnectOptions.Tls) DialError!*ClientStream {
    return ClientStream.connect(gpa, io, .{
        .host = address.host(),
        .port = address.port,
        .tls = tls,
        .connect_timeout = null,
    }) catch |err| return narrow(err);
}

fn narrow(err: anyerror) DialError {
    inline for (@typeInfo(DialError).error_set.error_names.?) |name| {
        if (err == @field(DialError, name)) return @field(DialError, name);
    }
    std.log.scoped(.nats).debug("dial failed: {t}", .{err});
    return error.NetworkDown;
}

/// The errors of `race(function, ...)`: those of `function`, plus Timeout
/// when the deadline came first.
pub fn RaceError(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.error_set ||
        error{ Timeout, Canceled, ConcurrencyUnavailable };
}

/// What `function` returns when it succeeds.
pub fn Payload(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.payload;
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// How `race` stops a task that ran out of time besides canceling it: the
/// task may lose the cancellation (code it calls can swallow
/// `error.Canceled`), so `function(context, io)` must make it return soon,
/// for instance by shutting its socket down.
pub const Abort = struct {
    context: *anyopaque,
    function: *const fn (context: *anyopaque, io: Io) void,
};

/// Runs `function(args)` in a task of its own and waits for it until
/// `deadline`. When the deadline comes first, the task is aborted, canceled
/// and awaited, a value it returned anyway goes to `release`, and the
/// caller gets Timeout. Canceling the caller stops the task the same way.
pub fn race(
    io: Io,
    deadline: Io.Clock.Timestamp,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: fn (Io, Payload(@TypeOf(function))) void,
    abort: ?Abort,
) RaceError(@TypeOf(function))!Payload(@TypeOf(function)) {
    const Race = union(enum) {
        done: Result(@TypeOf(function)),
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, sleepUntil, .{ io, deadline }) catch |err| {
        if (abort) |a| a.function(a.context, io);
        settle(Race, &select, io, release);
        return err;
    };
    const first = select.await() catch |err| {
        if (abort) |a| a.function(a.context, io);
        settle(Race, &select, io, release);
        return err;
    };
    if (first == .timer) if (abort) |a| a.function(a.context, io);
    settle(Race, &select, io, release);
    return switch (first) {
        .done => |result| result,
        .timer => error.Timeout,
    };
}

fn sleepUntil(io: Io, deadline: Io.Clock.Timestamp) Io.Cancelable!void {
    // A sleep may end a little early: Io.Threaded on Windows turns the
    // deadline into an interval, and the system counts it in timer ticks.
    while (!time.expired(io, deadline)) try deadline.wait(io);
}

/// Cancels and awaits what is still running; a value that arrives anyway
/// goes to `release`.
fn settle(comptime Race: type, select: *Io.Select(Race), io: Io, comptime release: anytype) void {
    while (select.cancel()) |left| switch (left) {
        .done => |result| if (result) |value| release(io, value) else |_| {},
        .timer => {},
    };
}

const testing = std.testing;

fn listen(io: Io) !net.Server {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return loopback.listen(io, .{ .reuse_address = true });
}

fn addressOf(server: *const net.Server, host: []const u8) !ServerAddress {
    var buffer: [300]u8 = undefined;
    return ServerAddress.parse(try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ host, server.socket.address.getPort() }));
}

fn acceptOne(io: Io, server: *net.Server) net.Server.AcceptError!net.Stream {
    return server.accept(io);
}

test "dial reaches a listener by IP address and by name" {
    const io = testing.io;
    var server = try listen(io);
    defer server.deinit(io);
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
        var peer = try io.concurrent(acceptOne, .{ io, &server });
        defer if (peer.cancel(io)) |stream| stream.close(io) else |_| {};
        const address = try addressOf(&server, host);
        const stream = try dial(io, testing.allocator, &address);
        stream.close();
    }
}

test "dial to a closed port is refused" {
    const io = testing.io;
    var server = try listen(io);
    const address = try addressOf(&server, "127.0.0.1");
    server.deinit(io);
    try testing.expectError(error.ConnectionRefused, dial(io, testing.allocator, &address));
}

fn sleepThenAnswer(io: Io, duration: Io.Duration) error{Canceled}!u32 {
    try io.sleep(duration, .awake);
    return 7;
}

fn fail() error{Broken}!u32 {
    return error.Broken;
}

fn keep(io: Io, value: u32) void {
    _ = io;
    _ = value;
}

test "race returns what comes in time" {
    const io = testing.io;
    try testing.expectEqual(7, try race(io, time.after(io, .fromSeconds(30)), sleepThenAnswer, .{ io, .fromMilliseconds(1) }, keep, null));
    try testing.expectError(error.Broken, race(io, time.after(io, .fromSeconds(30)), fail, .{}, keep, null));
}

test "race gives up at the deadline and cancels the slower task" {
    const io = testing.io;
    const start = Io.Clock.awake.now(io);
    const deadline = time.after(io, .fromMilliseconds(30));
    try testing.expectError(error.Timeout, race(io, deadline, sleepThenAnswer, .{ io, .fromSeconds(30) }, keep, null));
    // Not before the deadline, on the clock the deadline is on: Windows
    // counts sleeps in timer ticks, and they may end a little early.
    try testing.expect(time.expired(io, deadline));
    const waited = start.durationTo(Io.Clock.awake.now(io));
    if (@import("anole_test_wait").timing()) try testing.expect(waited.toSeconds() < 10);
}

/// Allocates after 30 ms and cannot be canceled before that.
fn allocateLate(io: Io, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    io.sleep(.fromMilliseconds(30), .awake) catch {};
    return gpa.alloc(u8, 16);
}

fn free(io: Io, bytes: []u8) void {
    _ = io;
    testing.allocator.free(bytes);
}

test "a value that comes after the deadline is released" {
    // testing.allocator reports a leak if `free` is not called.
    const io = testing.io;
    try testing.expectError(error.Timeout, race(io, time.after(io, .zero), allocateLate, .{ io, testing.allocator }, free, null));
}

/// Waits for `event` and ignores cancellation, like code that swallows
/// error.Canceled; gives up after 5 s.
fn waitDeaf(io: Io, event: *Io.Event) error{Abandoned}!u32 {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (!event.isSet()) {
        event.waitTimeout(io, .{ .deadline = give_up }) catch {};
        if (time.expired(io, give_up)) return error.Abandoned;
    }
    return 1;
}

fn setEvent(context: *anyopaque, io: Io) void {
    const event: *Io.Event = @ptrCast(@alignCast(context));
    event.set(io);
}

test "a task that ignores cancellation is stopped through the abort hook" {
    const io = testing.io;
    var event: Io.Event = .unset;
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, race(io, time.after(io, .fromMilliseconds(20)), waitDeaf, .{ io, &event }, keep, .{
        .context = &event,
        .function = setEvent,
    }));
    try testing.expect(event.isSet());
    if (@import("anole_test_wait").timing()) try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toSeconds() < 3);
}

test "a race whose timer cannot start still stops its task through the abort hook" {
    // One task at most: the timer of the race cannot start.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var event: Io.Event = .unset;
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.ConcurrencyUnavailable, race(io, time.after(io, .fromSeconds(30)), waitDeaf, .{ io, &event }, keep, .{
        .context = &event,
        .function = setEvent,
    }));
    try testing.expect(event.isSet());
    if (@import("anole_test_wait").timing()) try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toSeconds() < 3);
}
