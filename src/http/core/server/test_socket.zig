//! Test-only: a socket reader for the hand-written clients in h2_test.zig
//! and static_test.zig whose every read has a deadline (TESTING.md D2).
//! A read that gets nothing for `wait.deadline()` (10 s times
//! `ANOLE_TEST_TIMEOUT_FACTOR`) logs what it waited for and fails with
//! `error.ReadFailed` (`err` = `error.ReadTimedOut`), so a server that
//! never answers fails the test instead of hanging the binary.
//!
//! The deadline is per read, a hang guard and never a latency bound (D6).
//! Windows: std's threaded `Io` has no timed socket read there yet
//! (`operateTimeout` reports `error.ConcurrencyUnavailable` for `net_read`),
//! so a read waits without one, as `std.Io.net.Stream.Reader` does, and
//! the CI job's timeout is the guard.
const std = @import("std");
const wait = @import("anole_test_wait");

comptime {
    if (!@import("builtin").is_test) @compileError("test_socket.zig is for tests only");
}

const log = std.log.scoped(.anole_test);

pub const DeadlineReader = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    interface: std.Io.Reader,
    /// What failed the last read: the socket's error, `error.ReadTimedOut`
    /// or `error.Canceled`.
    err: ?Error = null,
    /// The deadline of each read: `wait.deadline()` unless set (the
    /// reader's own test).
    limit: ?std.Io.Duration = null,

    pub const Error = std.Io.Operation.NetRead.Error || std.Io.Cancelable || error{ReadTimedOut};

    pub fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8) DeadlineReader {
        return .{
            .io = io,
            .stream = stream,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *DeadlineReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
        const dest = iovecs[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const n = r.read(dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn read(r: *DeadlineReader, dest: [][]u8) Error!usize {
        const op: std.Io.Operation = .{ .net_read = .{ .socket_handle = r.stream.socket.handle, .data = dest } };
        const limit = r.limit orelse wait.deadline();
        const result = r.io.operateTimeout(op, .{ .duration = .{ .raw = limit, .clock = .awake } }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => {
                log.warn("timed out after {d}s waiting for: the server's next bytes", .{limit.toSeconds()});
                return error.ReadTimedOut;
            },
            // Windows: no timed socket read (see the file comment).
            error.ConcurrencyUnavailable => try r.io.operate(op),
        };
        const got = try result.net_read;
        return got.data_len;
    }
};

test "test_socket: a read that gets nothing fails at its deadline" {
    // Windows: not supported (no timed socket read in std there; see the
    // file comment), so this read would wait for good.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const peer = try listener.accept(io);
    defer peer.close(io);

    var buf: [64]u8 = undefined;
    var reader: DeadlineReader = .init(stream, io, &buf);
    reader.limit = .fromMilliseconds(20);
    try std.testing.expectError(error.ReadFailed, reader.interface.peekGreedy(1));
    try std.testing.expectEqual(error.ReadTimedOut, reader.err.?);
}
