//! Reading a server-sent event stream: the client side of `anole.sse`, for
//! a stream fetched from another server (an LLM API, a feed). It follows
//! the WHATWG "event stream interpretation" and reads from any
//! `*std.Io.Reader`, such as a response fetched with `.stream = true`:
//!
//!     var response = try client.fetch(url, .{ .stream = true });
//!     defer response.deinit();
//!     var buf: [16 * 1024]u8 = undefined;
//!     var body = try response.reader(&buf);
//!     var events = anole.sse.Parser.init(gpa, &body.interface, .{});
//!     defer events.deinit();
//!     while (try events.next()) |e| handle(e.event, e.data);
const std = @import("std");

pub const Parser = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_event_size: usize,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    has_id: bool = false,
    has_data: bool = false,
    /// The BOM check is still due.
    at_start: bool = true,
    /// The last line ended in CR: an LF next belongs to it.
    after_cr: bool = false,
    /// The last `retry:` the stream sent, in milliseconds: how long the
    /// server asks a client to wait before it reconnects. Null until one
    /// arrives.
    retry: ?u64 = null,

    pub const Options = struct {
        /// The longest line, and the most data one event may gather.
        /// Past it, `next` fails with `error.EventTooLarge`.
        max_event_size: usize = 16 * 1024 * 1024,
    };

    pub const Error = error{ ReadFailed, OutOfMemory, EventTooLarge };

    /// One dispatched event. Its slices are the parser's, valid until the
    /// next call to `next` or `deinit`.
    pub const Event = struct {
        /// The `event:` field; "message" when the event named none.
        event: []const u8,
        /// The `data:` lines joined with LF.
        data: []const u8,
        /// The last `id:` the stream sent, on this event or an earlier one;
        /// null if it never sent one. What a reconnect sends as
        /// `Last-Event-ID`.
        id: ?[]const u8,
    };

    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: Options) Parser {
        return .{ .gpa = gpa, .reader = reader, .max_event_size = options.max_event_size };
    }

    pub fn deinit(p: *Parser) void {
        p.line.deinit(p.gpa);
        p.data.deinit(p.gpa);
        p.event.deinit(p.gpa);
        p.last_id.deinit(p.gpa);
    }

    /// The next event, or null at the end of the stream. Comments
    /// (keep-alives), unknown fields and blocks without `data:` dispatch
    /// nothing; an event the end of the stream cuts off (no blank line
    /// after it) is dropped. `error.ReadFailed` comes from the reader (an
    /// HTTP client's reader keeps its cause); after any error the parser
    /// is spent.
    pub fn next(p: *Parser) Error!?Event {
        p.data.clearRetainingCapacity();
        p.event.clearRetainingCapacity();
        p.has_data = false;
        while (try p.readLine()) {
            var line = p.line.items;
            if (line.len == 0) {
                if (!p.has_data) {
                    p.event.clearRetainingCapacity();
                    continue;
                }
                return .{
                    .event = if (p.event.items.len == 0) "message" else p.event.items,
                    .data = p.data.items,
                    .id = if (p.has_id) p.last_id.items else null,
                };
            }
            if (line[0] == ':') continue;

            const colon = std.mem.indexOfScalar(u8, line, ':');
            const field = if (colon) |c| line[0..c] else line;
            var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') value = value[1..];

            if (std.mem.eql(u8, field, "data")) {
                const extra = @intFromBool(p.has_data);
                if (p.data.items.len + extra + value.len > p.max_event_size) return error.EventTooLarge;
                if (p.has_data) try p.data.append(p.gpa, '\n');
                try p.data.appendSlice(p.gpa, value);
                p.has_data = true;
            } else if (std.mem.eql(u8, field, "event")) {
                p.event.clearRetainingCapacity();
                try p.event.appendSlice(p.gpa, value);
            } else if (std.mem.eql(u8, field, "id")) {
                if (std.mem.indexOfScalar(u8, value, 0) == null) {
                    p.last_id.clearRetainingCapacity();
                    try p.last_id.appendSlice(p.gpa, value);
                    p.has_id = true;
                }
            } else if (std.mem.eql(u8, field, "retry")) {
                if (value.len > 0 and std.mem.indexOfNone(u8, value, "0123456789") == null) {
                    p.retry = std.fmt.parseInt(u64, value, 10) catch p.retry;
                }
            }
        }
        return null;
    }

    /// Reads one line into `line`, without its CR, LF or CRLF; false at
    /// the end of the stream, where an unterminated line is dropped.
    fn readLine(p: *Parser) Error!bool {
        p.line.clearRetainingCapacity();
        while (true) {
            const buf = p.reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return false,
                error.ReadFailed => return error.ReadFailed,
            };
            var start: usize = 0;
            if (p.after_cr) {
                p.after_cr = false;
                if (buf[0] == '\n') start = 1;
            }
            const end = std.mem.indexOfAnyPos(u8, buf, start, "\r\n");
            const part = buf[start .. end orelse buf.len];
            if (p.line.items.len + part.len > p.max_event_size) return error.EventTooLarge;
            try p.line.appendSlice(p.gpa, part);
            if (end) |i| {
                p.after_cr = buf[i] == '\r';
                p.reader.toss(i + 1);
                break;
            }
            p.reader.toss(buf.len);
        }
        if (p.at_start) {
            p.at_start = false;
            const bom = "\xEF\xBB\xBF";
            if (std.mem.startsWith(u8, p.line.items, bom)) p.line.replaceRangeAssumeCapacity(0, bom.len, "");
        }
        return true;
    }
};

const testing = std.testing;

/// Every event of `input` as "event|data|id" lines, read through a reader
/// whose buffer holds `chunk` bytes, fed `chunk` bytes per read.
fn collect(input: []const u8, chunk: usize, options: Parser.Options) ![]u8 {
    var calls: std.ArrayList(std.testing.Reader.Call) = .empty;
    defer calls.deinit(testing.allocator);
    var i: usize = 0;
    while (i < input.len) : (i += chunk) try calls.append(testing.allocator, .{ .buffer = input[i..@min(i + chunk, input.len)] });
    const buf = try testing.allocator.alloc(u8, chunk);
    defer testing.allocator.free(buf);
    var reader: std.testing.Reader = .init(buf, calls.items);

    var p: Parser = .init(testing.allocator, &reader.interface, options);
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    while (try p.next()) |e| try out.writer.print("{s}|{s}|{s}\n", .{ e.event, e.data, e.id orelse "-" });
    return out.toOwnedSlice();
}

fn expectEvents(expected: []const u8, input: []const u8) !void {
    // Whole, and a byte at a time: line ends split across reads.
    for ([_]usize{ input.len + 1, 1 }) |chunk| {
        const got = try collect(input, chunk, .{});
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }
}

test "sse parser: data lines join with LF, and an event without a name is a message" {
    try expectEvents("message|one\ntwo|-\ndelta|{\"a\":1}|-\nmessage||-\n",
        \\data: one
        \\data:two
        \\
        \\event: delta
        \\data: {"a":1}
        \\
        \\data
        \\
        \\
    );
}

test "sse parser: CRLF, CR and LF each end a line, and a leading BOM is skipped" {
    try expectEvents("message|a|-\nmessage|b\nc|-\nmessage|d|-\n", "\xEF\xBB\xBFdata: a\r\n\r\ndata: b\rdata: c\r\rdata: d\n\n");
}

test "sse parser: comments, unknown fields and blocks without data dispatch nothing" {
    try expectEvents("message|x|-\n", ": keep-alive\n\nevent: lost\n\nfoo: bar\ndata: x\n\n");
}

test "sse parser: the last id carries over to later events, and an id holding NUL is ignored" {
    try expectEvents("message|a|7\nmessage|b|7\nmessage|c|\n", "id: 7\ndata: a\n\ndata: b\nid: 8\x009\n\nid\ndata: c\n\n");
}

test "sse parser: retry takes only digits" {
    var r: std.Io.Reader = .fixed("retry: 2500\n\nretry: 12x\n\nretry: -1\n\n");
    var p: Parser = .init(testing.allocator, &r, .{});
    defer p.deinit();
    try testing.expect(try p.next() == null);
    try testing.expectEqual(@as(?u64, 2500), p.retry);
}

test "sse parser: an event the end of the stream cuts off is dropped" {
    try expectEvents("message|kept|-\n", "data: kept\n\ndata: cut off\n");
    try expectEvents("", "data: no line end");
}

test "sse parser: a line longer than the reader's buffer arrives whole" {
    const big: [70_000]u8 = @splat('x');
    const input = "data: " ++ big ++ "\n\n";
    const got = try collect(input, 4096, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("message|" ++ big ++ "|-\n", got);
}

test "sse parser: a line or an event past max_event_size is error.EventTooLarge" {
    const limit: Parser.Options = .{ .max_event_size = 10 };
    // A line of 11 bytes.
    try testing.expectError(error.EventTooLarge, collect("data:123456\n\n", 64, limit));
    // Lines of 10, data of 5 + 1 + 5.
    try testing.expectError(error.EventTooLarge, collect("data:12345\ndata:12345\n\n", 64, limit));
    const fits = try collect("data:1234\ndata:12345\n\n", 64, limit);
    defer testing.allocator.free(fits);
    try testing.expectEqualStrings("message|1234\n12345|-\n", fits);
}

test "fuzz: SSE parser" {
    try @import("../fuzz.zig").bytes(fuzzParser, &.{
        "data: a\n\n",
        "event: x\r\ndata: 1\r\ndata: 2\r\n\r\n",
        "\xEF\xBB\xBFid: 3\rdata\r\r: c\n\nretry: 10\n\n",
        "data: cut",
    });
}

fn fuzzParser(input: []const u8) anyerror!void {
    // How the stream is split into reads never changes the events.
    const whole = try collect(input, input.len + 1, .{});
    defer testing.allocator.free(whole);
    const bytes = try collect(input, 1, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(whole, bytes);
}
