//! permessage-deflate (RFC 7692) on zlib-ng: the negotiation of an offer
//! from `Sec-WebSocket-Extensions`, and the per-message compression shared
//! by WebSocket over HTTP/1.1 and over HTTP/2.
//!
//! Each message is a raw deflate stream ended by a sync flush, with the
//! flush's empty stored block (00 00 ff ff) taken off on the wire and put
//! back before inflating. With context takeover, both directions keep their
//! window from message to message.
const std = @import("std");
const c = @import("anole_zlib_c");

pub const Config = struct {
    /// The server (we) resets its compressor after every message.
    server_no_context_takeover: bool = false,
    /// The client resets its compressor after every message, so we may
    /// reset our decompressor.
    client_no_context_takeover: bool = false,
    /// The window our compressor uses: what the client asked for with
    /// server_max_window_bits, else our own choice.
    server_window_bits: u4 = 15,
    /// The response carries server_max_window_bits (the client asked).
    server_window_bits_sent: bool = false,
};

pub const Options = struct {
    /// Our compressor's window when the client leaves it to us. Smaller is
    /// less memory per socket: about 2^(bits+2) + 2^(mem_level+9) bytes.
    window_bits: u4 = 13,
    mem_level: u4 = 6,
    level: c_int = 6,
    /// Messages shorter than this go out uncompressed.
    min_length: usize = 64,
};

/// The first acceptable `permessage-deflate` offer in `header`, and the
/// response header value for it, written into `out`. Null when there is no
/// offer we can accept (RFC 7692 §5: then the extension is not used).
pub fn negotiate(header: []const u8, options: Options, out: []u8) ?struct { config: Config, response: []const u8 } {
    var offers = std.mem.splitScalar(u8, header, ',');
    offers: while (offers.next()) |offer| {
        var params = std.mem.splitScalar(u8, offer, ';');
        const name = std.mem.trim(u8, params.first(), " \t");
        if (!std.ascii.eqlIgnoreCase(name, "permessage-deflate")) continue;
        var config: Config = .{ .server_window_bits = options.window_bits };
        var seen: [4]bool = @splat(false);
        while (params.next()) |raw| {
            const param = std.mem.trim(u8, raw, " \t");
            const eq = std.mem.indexOfScalar(u8, param, '=');
            const key = std.mem.trim(u8, param[0 .. eq orelse param.len], " \t");
            var value: ?[]const u8 = if (eq) |i| std.mem.trim(u8, param[i + 1 ..], " \t") else null;
            if (value) |v| if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
                value = v[1 .. v.len - 1];
            };
            const which: usize = if (std.ascii.eqlIgnoreCase(key, "server_no_context_takeover"))
                0
            else if (std.ascii.eqlIgnoreCase(key, "client_no_context_takeover"))
                1
            else if (std.ascii.eqlIgnoreCase(key, "server_max_window_bits"))
                2
            else if (std.ascii.eqlIgnoreCase(key, "client_max_window_bits"))
                3
            else
                continue :offers; // an unknown parameter declines the offer
            // A parameter given twice declines it too.
            if (seen[which]) continue :offers;
            seen[which] = true;
            switch (which) {
                0 => {
                    if (value != null) continue :offers;
                    config.server_no_context_takeover = true;
                },
                1 => {
                    if (value != null) continue :offers;
                    config.client_no_context_takeover = true;
                },
                2 => {
                    const bits = windowBits(value orelse continue :offers) orelse continue :offers;
                    // zlib cannot deflate with a 256-byte window (it
                    // silently uses 512), so an offer that insists on it
                    // is declined.
                    if (bits == 8) continue :offers;
                    config.server_window_bits = @min(bits, options.window_bits);
                    config.server_window_bits_sent = true;
                },
                3 => {
                    // With or without a value it only says the client can
                    // take a limit; our decompressor takes any window.
                    if (value) |v| _ = windowBits(v) orelse continue :offers;
                },
                else => unreachable,
            }
        }
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("permessage-deflate") catch return null;
        if (config.server_no_context_takeover) w.writeAll("; server_no_context_takeover") catch return null;
        if (config.client_no_context_takeover) w.writeAll("; client_no_context_takeover") catch return null;
        if (config.server_window_bits_sent) w.print("; server_max_window_bits={d}", .{config.server_window_bits}) catch return null;
        return .{ .config = config, .response = w.buffered() };
    }
    return null;
}

fn windowBits(text: []const u8) ?u4 {
    if (text.len == 0 or text.len > 2) return null;
    if (text[0] == '0') return null;
    const n = std.fmt.parseInt(u8, text, 10) catch return null;
    if (n < 8 or n > 15) return null;
    return @intCast(n);
}

/// One socket's compressor and decompressor.
pub const Deflate = struct {
    config: Config,
    options: Options,
    deflater: c.z_stream = std.mem.zeroes(c.z_stream),
    inflater: c.z_stream = std.mem.zeroes(c.z_stream),
    deflater_ready: bool = false,
    inflater_ready: bool = false,
    /// Where messages are deflated and inflated; reused. Apart, since a
    /// message just inflated is often what is sent next (an echo).
    deflated: std.ArrayList(u8) = .empty,
    inflated: std.ArrayList(u8) = .empty,

    pub const Error = error{ OutOfMemory, InvalidCompressedData, MessageTooLarge };

    pub fn init(config: Config, options: Options) Deflate {
        return .{ .config = config, .options = options };
    }

    pub fn deinit(self: *Deflate, allocator: std.mem.Allocator) void {
        if (self.deflater_ready) _ = c.deflateEnd(&self.deflater);
        if (self.inflater_ready) _ = c.inflateEnd(&self.inflater);
        self.deflated.deinit(allocator);
        self.inflated.deinit(allocator);
    }

    const tail = [4]u8{ 0x00, 0x00, 0xff, 0xff };

    /// `data` compressed as one message (the trailing 00 00 ff ff taken
    /// off), valid until the next call.
    pub fn compress(self: *Deflate, allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
        if (!self.deflater_ready) {
            if (c.deflateInit2_(&self.deflater, self.options.level, c.Z_DEFLATED, -@as(c_int, self.config.server_window_bits), self.options.mem_level, c.Z_DEFAULT_STRATEGY, c.zlibVersion(), @sizeOf(c.z_stream)) != c.Z_OK)
                return error.OutOfMemory;
            self.deflater_ready = true;
        }
        self.deflated.clearRetainingCapacity();
        const z = &self.deflater;
        z.next_in = @constCast(data.ptr);
        z.avail_in = @intCast(data.len);
        while (true) {
            try self.deflated.ensureUnusedCapacity(allocator, @max(64, data.len / 2 + 16));
            const room = self.deflated.unusedCapacitySlice();
            z.next_out = room.ptr;
            z.avail_out = @intCast(room.len);
            const rc = c.deflate(z, c.Z_SYNC_FLUSH);
            self.deflated.items.len += room.len - z.avail_out;
            if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.InvalidCompressedData;
            // Done once the input is in and the flush did not fill the room.
            if (z.avail_in == 0 and z.avail_out != 0) break;
        }
        if (self.config.server_no_context_takeover) _ = c.deflateReset(z);
        var bytes = self.deflated.items;
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[bytes.len - 4 ..], &tail)) bytes = bytes[0 .. bytes.len - 4];
        // Nothing to flush (an empty message right after another) still has
        // to be a block: RFC 7692 §7.2.3.6's single 0x00, an empty stored
        // block once the tail is put back.
        if (bytes.len == 0) {
            self.deflated.clearRetainingCapacity();
            try self.deflated.append(allocator, 0x00);
            return self.deflated.items;
        }
        return bytes;
    }

    /// The message `data` inflated, at most `max` bytes, valid until the
    /// next call.
    pub fn decompress(self: *Deflate, allocator: std.mem.Allocator, data: []const u8, max: usize) Error![]const u8 {
        if (!self.inflater_ready) {
            // The client may use any window up to 15 bits.
            if (c.inflateInit2_(&self.inflater, -15, c.zlibVersion(), @sizeOf(c.z_stream)) != c.Z_OK)
                return error.OutOfMemory;
            self.inflater_ready = true;
        }
        self.inflated.clearRetainingCapacity();
        const z = &self.inflater;
        for ([_][]const u8{ data, &tail }, 0..) |input, part| {
            z.next_in = @constCast(input.ptr);
            z.avail_in = @intCast(input.len);
            while (true) {
                if (self.inflated.items.len > max) return error.MessageTooLarge;
                try self.inflated.ensureUnusedCapacity(allocator, @min(@max(1024, data.len * 4), max - self.inflated.items.len + 1));
                const room = self.inflated.unusedCapacitySlice();
                z.next_out = room.ptr;
                z.avail_out = @intCast(room.len);
                const rc = c.inflate(z, c.Z_SYNC_FLUSH);
                self.inflated.items.len += room.len - z.avail_out;
                switch (rc) {
                    c.Z_OK, c.Z_BUF_ERROR => {},
                    // A final block: what follows is a new stream.
                    c.Z_STREAM_END => {
                        _ = c.inflateReset(z);
                        if (part == 1 or z.avail_in == 0) break;
                        continue;
                    },
                    else => return error.InvalidCompressedData,
                }
                // Done with this part once its input is in and zlib had
                // room to spare: nothing is left pending inside it.
                if (z.avail_in == 0 and z.avail_out != 0) break;
                if (rc == c.Z_BUF_ERROR and z.avail_out != 0) break;
            }
        }
        if (self.inflated.items.len > max) return error.MessageTooLarge;
        if (self.config.client_no_context_takeover) _ = c.inflateReset(z);
        return self.inflated.items;
    }
};

test "negotiate: the first acceptable offer, with its parameters" {
    var buf: [128]u8 = undefined;
    const plain = negotiate("permessage-deflate", .{}, &buf).?;
    try std.testing.expectEqualStrings("permessage-deflate", plain.response);
    try std.testing.expectEqual(@as(u4, 13), plain.config.server_window_bits);

    const full = negotiate("permessage-deflate; server_no_context_takeover; client_max_window_bits; server_max_window_bits=10", .{}, &buf).?;
    try std.testing.expectEqualStrings("permessage-deflate; server_no_context_takeover; server_max_window_bits=10", full.response);
    try std.testing.expectEqual(@as(u4, 10), full.config.server_window_bits);

    // 8 bits cannot be honoured: the next offer is taken.
    const fallback = negotiate("permessage-deflate; server_max_window_bits=8, permessage-deflate; client_no_context_takeover", .{}, &buf).?;
    try std.testing.expectEqualStrings("permessage-deflate; client_no_context_takeover", fallback.response);

    try std.testing.expect(negotiate("permessage-deflate; unknown_param", .{}, &buf) == null);
    try std.testing.expect(negotiate("permessage-deflate; server_no_context_takeover; server_no_context_takeover", .{}, &buf) == null);
    try std.testing.expect(negotiate("x-webkit-deflate-frame", .{}, &buf) == null);
}

test "Deflate: messages round-trip, with and without context takeover" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |no_takeover| {
        const config: Config = .{ .server_no_context_takeover = no_takeover, .client_no_context_takeover = no_takeover };
        var tx: Deflate = .init(config, .{});
        defer tx.deinit(gpa);
        var rx: Deflate = .init(config, .{});
        defer rx.deinit(gpa);
        const messages = [_][]const u8{ "Hello", "Hello Hello Hello Hello", "", "a different message altogether" };
        for (messages) |m| {
            const wire = try gpa.dupe(u8, try tx.compress(gpa, m));
            defer gpa.free(wire);
            try std.testing.expectEqualStrings(m, try rx.decompress(gpa, wire, 1 << 20));
        }
    }
    // A large, very compressible message inflates to far more than the first
    // buffer: the output still pending inside zlib must not be lost.
    {
        var tx: Deflate = .init(.{}, .{});
        defer tx.deinit(gpa);
        var rx: Deflate = .init(.{}, .{});
        defer rx.deinit(gpa);
        const big = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = "BAsd7&jh23"[i % 10];
        const wire = try gpa.dupe(u8, try tx.compress(gpa, big));
        defer gpa.free(wire);
        try std.testing.expect(wire.len < 1024);
        try std.testing.expectEqualSlices(u8, big, try rx.decompress(gpa, wire, 1 << 20));
    }
    // An echo: the message just inflated is compressed straight back out.
    {
        var server: Deflate = .init(.{}, .{});
        defer server.deinit(gpa);
        var client: Deflate = .init(.{}, .{});
        defer client.deinit(gpa);
        const text = "an echo of an echo of an echo of an echo of an echo of an echo!!";
        const sent = try gpa.dupe(u8, try client.compress(gpa, text));
        defer gpa.free(sent);
        const got = try server.decompress(gpa, sent, 1 << 20);
        const back = try gpa.dupe(u8, try server.compress(gpa, got));
        defer gpa.free(back);
        try std.testing.expectEqualStrings(text, try client.decompress(gpa, back, 1 << 20));
    }
    // RFC 7692 §7.2.3.1: "Hello" compressed by hand.
    var rx: Deflate = .init(.{}, .{});
    defer rx.deinit(gpa);
    try std.testing.expectEqualStrings("Hello", try rx.decompress(gpa, &.{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 }, 100));
    try std.testing.expectError(error.MessageTooLarge, rx.decompress(gpa, &.{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 }, 3));
}

test "fuzz: permessage-deflate offers" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var out: [256]u8 = undefined;
            const r = negotiate(input, .{}, &out) orelse return;
            try std.testing.expect(r.config.server_window_bits >= 8);
            try std.testing.expect(std.mem.startsWith(u8, r.response, "permessage-deflate"));
        }
    }.check, &.{
        "permessage-deflate",
        "permessage-deflate; client_max_window_bits",
        "x-webkit-deflate-frame, permessage-deflate; server_no_context_takeover; client_max_window_bits=10; server_max_window_bits=9",
        "permessage-deflate; server_max_window_bits=\"8\", permessage-deflate",
    });
}

test "fuzz: inflating messages stays within the limit" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            const gpa = std.testing.allocator;
            var d: Deflate = .init(.{}, .{});
            defer d.deinit(gpa);
            // Two messages through the same context.
            const half = input.len / 2;
            for ([_][]const u8{ input[0..half], input[half..] }) |part| {
                const m = d.decompress(gpa, part, 4096) catch return;
                try std.testing.expect(m.len <= 4096);
            }
        }
    }.check, &.{
        "\xf2\x48\xcd\xc9\xc9\xd7\x51\x28\x48\x2d\xca\x4d\x2d\x2e\x4e\x4c\x4f\xd5\x4d\x49\x4d\xcb\x49\x2c\x49\x55\x54\xf0\xa0\xb6\x14\x00",
        "\x00\x00\xff\xff",
        "\x03\x00",
    });
}
