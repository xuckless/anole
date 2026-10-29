// Adapted from vkiryakov/zefir src/nats/protocol/fuzz.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Fuzzing of the parser. `zig build test` runs each corpus entry
//! once, as a regression test; `zig build test --fuzz=1M` runs the fuzzer.
//! The property: any input, parsed at once or cut into random pieces, gives
//! the same frames and ends the same way, nothing panics, and the parser
//! never asks for more input while a buffer of `Parser.bufferLen` bytes is
//! full, which the connection's reader relies on.

const std = @import("std");
const Parser = @import("Parser.zig");
const golden = @import("golden.zig");

/// Small limits, so that the fuzzer also reaches LineTooLong.
const limits: Parser.Limits = .{ .max_control_line = 256, .max_info_line = 1024 };

const End = union(enum) { complete, incomplete, failed: Parser.Error };

const Outcome = struct {
    digest: u64,
    end: End,
};

/// Parses `input` through a window as large as the reader's buffer:
/// everything that fits at once when `smith` is null, otherwise in pieces
/// of 1 to 64 bytes it chooses. Hashes every frame; body bytes are hashed
/// without separators, so how a body is cut does not change the digest.
fn run(input: []const u8, smith: ?*std.testing.Smith) !Outcome {
    var parser: Parser = .init(limits);
    var hasher: std.hash.Wyhash = .init(0);
    var window: [Parser.bufferLen(limits)]u8 = undefined;
    var len: usize = 0;
    var fed: usize = 0;
    while (true) {
        while (true) {
            const step = parser.next(window[0..len]) catch |err| return .{ .digest = hasher.final(), .end = .{ .failed = err } };
            const frame = step.frame orelse break;
            hashFrame(&hasher, frame);
            if (step.consumed == 0) return error.FrameWithoutBytes;
            std.mem.copyForwards(u8, window[0 .. len - step.consumed], window[step.consumed..len]);
            len -= step.consumed;
        }
        // The reader could not read more into a full buffer.
        if (len == window.len) return error.NeedMoreWithFullBuffer;
        if (fed == input.len) {
            const complete = len == 0 and parser.state == .line;
            return .{ .digest = hasher.final(), .end = if (complete) .complete else .incomplete };
        }
        const piece: usize = if (smith) |s| s.valueRangeAtMost(u8, 1, 64) else input.len;
        const n = @min(piece, input.len - fed, window.len - len);
        @memcpy(window[len..][0..n], input[fed..][0..n]);
        len += n;
        fed += n;
    }
}

fn hashFrame(hasher: *std.hash.Wyhash, frame: Parser.Frame) void {
    switch (frame) {
        .body => |bytes| hasher.update(bytes),
        .info => |json| hashTagged(hasher, "INFO", json),
        .err => |text| hashTagged(hasher, "-ERR", text),
        .msg => |m| {
            hashTagged(hasher, "MSG", m.subject);
            hasher.update(std.mem.asBytes(&m.sid));
            hashTagged(hasher, "REPLY", m.reply_to orelse "");
            hasher.update(std.mem.asBytes(&m.header_len));
            hasher.update(std.mem.asBytes(&m.total_len));
        },
        .msg_end => hasher.update("END"),
        .ping => hasher.update("PING"),
        .pong => hasher.update("PONG"),
        .ok => hasher.update("+OK"),
    }
}

fn hashTagged(hasher: *std.hash.Wyhash, tag: []const u8, bytes: []const u8) void {
    hasher.update(tag);
    hasher.update(std.mem.asBytes(&bytes.len));
    hasher.update(bytes);
}

fn fuzzParser(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    const whole = try run(input, null);
    const pieces = try run(input, smith);
    try std.testing.expectEqual(whole.digest, pieces.digest);
    try std.testing.expectEqualDeep(whole.end, pieces.end);
}

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first.
fn sample(comptime raw: []const u8) []const u8 {
    return comptime std.mem.toBytes(std.mem.nativeToLittle(u32, raw.len)) ++ raw;
}

/// A MSG line longer than the reader's buffer: LineTooLong, never a wait.
const too_long_line = "MSG " ++ @as([Parser.bufferLen(limits)]u8, @splat('s')) ++ " 1 0\r\n\r\n";

const corpus = make: {
    var entries: [golden.frames.len + 5][]const u8 = undefined;
    for (golden.frames, 0..) |frame, i| entries[i] = sample(frame);
    entries[golden.frames.len] = sample(golden.session[0..1024]);
    entries[golden.frames.len + 1] = sample("MSG a 1 15\r\n\r\nMSG foo 1 5\r\n\r\nPONG\r\n");
    entries[golden.frames.len + 2] = sample("msg\tfoo  1 \t5 \r\nhello\r\nping\n");
    entries[golden.frames.len + 3] = sample("HMSG foo 1 10 5\r\n");
    entries[golden.frames.len + 4] = sample(too_long_line);
    break :make entries;
};

test "fuzz: the parser gives the same frames whole or cut into pieces, and never waits on a full buffer" {
    try std.testing.fuzz({}, fuzzParser, .{ .corpus = &corpus });
}
