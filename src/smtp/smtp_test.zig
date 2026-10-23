//! The SMTP client against `anole.smtp.testing.FakeServer` in the test
//! process. No timing assertions: the fake answers when asked, and what
//! the tests count is commands, connections and messages.
const std = @import("std");
const zio = @import("zio");
const features = @import("build_options");
const db = @import("../db/root.zig");
const errors = @import("../errors.zig");
const smtp = @import("root.zig");
const mime = @import("mime.zig");

const FakeServer = smtp.testing.FakeServer;
const testing = std.testing;

/// `s` repeated `n` times, at compile time (Zig 0.17 has no `**`).
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const Storage = struct {
        const data: [s.len * n]u8 = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    };
    return &Storage.data;
}
const gpa = testing.allocator;
const has_tls = features.tls == .boringssl;

/// A runtime, a fake server and a client of it.
const Harness = struct {
    rt: *zio.Runtime,
    io: std.Io,
    fake: *FakeServer,
    client: *smtp.Client,
    arena: std.heap.ArenaAllocator,
    c: db.Ctx,
    url_buf: [160]u8 = undefined,

    fn init(h: *Harness, fake_options: smtp.testing.Options, client_options: smtp.Options) !void {
        h.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
        errdefer h.rt.deinit();
        h.io = h.rt.io();
        h.fake = try FakeServer.init(gpa, h.io, fake_options);
        errdefer h.fake.deinit();
        var o = client_options;
        if (o.url == null) o.url = h.fake.url(&h.url_buf);
        if (o.from == null) o.from = "app@example.com";
        if (o.environment == null) o.environment = .development;
        if (o.tls.ca == null and !o.tls.insecure_skip_verify) if (h.fake.certPem()) |pem| {
            o.tls.ca = .{ .pem = pem };
        };
        h.client = try smtp.Client.init(gpa, h.io, o);
        errdefer h.client.deinit();
        h.arena = .init(gpa);
        h.c = .{ .io = h.io, .arena = h.arena.allocator() };
    }

    fn deinit(h: *Harness) void {
        h.arena.deinit();
        h.client.deinit();
        h.fake.deinit();
        h.rt.deinit();
    }

    fn hello(h: *Harness) !smtp.Sent {
        return h.client.send(&h.c, .{ .to = &.{"ada@example.com"}, .subject = "Hi", .text = "Hello" });
    }
};

fn expectDetail(h: *Harness, class: db.Class, code: []const u8) !void {
    const d = db.lastError(&h.c).?;
    try testing.expectEqual(class, d.class);
    try testing.expectEqualStrings(code, d.code);
}

test "send: a plain message arrives with its envelope and headers" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    const sent = try h.client.send(&h.c, .{
        .from = "Ada <ada@example.com>",
        .to = &.{ "bob@example.com", "Carol <carol@example.org>" },
        .cc = &.{"dan@example.net"},
        .bcc = &.{"eve@example.net"},
        .subject = "Greetings",
        .text = "Hello there\r\n",
    });
    try testing.expectEqual(@as(usize, 4), sent.accepted.len);
    try testing.expectEqual(@as(usize, 0), sent.rejected.len);
    try testing.expect(std.mem.startsWith(u8, sent.response, "2.0.0 Ok: queued as FAKE"));
    try testing.expectEqual(@as(usize, 1), h.fake.messageCount());
    const m = h.fake.message(0).?;
    try testing.expectEqualStrings("ada@example.com", m.envelope_from);
    try testing.expectEqual(@as(usize, 4), m.recipients.len);
    try testing.expectEqualStrings("eve@example.net", m.recipients[3]);
    try testing.expect(std.mem.indexOf(u8, m.data, "Subject: Greetings\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, m.data, "Bcc") == null and std.mem.indexOf(u8, m.data, "eve@") == null);
    try testing.expect(std.mem.endsWith(u8, m.data, "\r\nHello there\r\n"));
    try testing.expect(std.mem.indexOf(u8, m.data, sent.message_id) != null);
    // The SIZE it announced is the size it sent (dot-stuffing aside).
    try testing.expectEqual(@as(u64, m.data.len), m.declared_size.?);
}

test "send: a line starting with a dot survives the stuffing, and so do LF line ends of sendRaw" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    _ = try h.client.send(&h.c, .{ .to = &.{"ada@example.com"}, .text = ".hidden\n..two\nend" });
    try testing.expect(std.mem.endsWith(u8, h.fake.message(0).?.data, "\r\n.hidden\r\n..two\r\nend\r\n"));

    const raw = "From: x@example.com\nTo: ada@example.com\nMessage-ID: <abc@example.com>\nSubject: raw\n\n.dot\nbody\n";
    const sent = try h.client.sendRaw(&h.c, .{ .from = "x@example.com", .to = &.{"Ada <ada@example.com>"} }, raw);
    try testing.expectEqualStrings("abc@example.com", sent.message_id);
    try testing.expectEqualStrings("From: x@example.com\r\nTo: ada@example.com\r\nMessage-ID: <abc@example.com>\r\nSubject: raw\r\n\r\n.dot\r\nbody\r\n", h.fake.message(1).?.data);
    try testing.expectEqualStrings("ada@example.com", h.fake.message(1).?.recipients[0]);
}

test "session: EHLO extensions, HELO after a refused EHLO" {
    var h: Harness = undefined;
    try h.init(.{ .ehlo_fails = true }, .{});
    defer h.deinit();
    _ = try h.hello();
    try testing.expectEqual(@as(usize, 1), h.fake.commandCount("HELO"));
    try testing.expectEqual(@as(usize, 1), h.fake.messageCount());
}

test "pipelining: the commands go out together, or one at a time" {
    {
        var h: Harness = undefined;
        try h.init(.{ .pipelining = true }, .{});
        defer h.deinit();
        _ = try h.client.send(&h.c, .{ .to = &.{ "a@example.com", "b@example.com", "c@example.com" }, .text = "x" });
        try testing.expect(h.fake.max_batch.load(.monotonic) >= 2);
        try testing.expectEqual(@as(usize, 3), h.fake.message(0).?.recipients.len);
    }
    {
        var h: Harness = undefined;
        try h.init(.{ .pipelining = false }, .{});
        defer h.deinit();
        _ = try h.client.send(&h.c, .{ .to = &.{ "a@example.com", "b@example.com", "c@example.com" }, .text = "x" });
        try testing.expectEqual(@as(u32, 1), h.fake.max_batch.load(.monotonic));
        try testing.expectEqual(@as(usize, 3), h.fake.message(0).?.recipients.len);
    }
}

test "recipients: one refused is reported, all refused is a 400 and the session is reset" {
    for ([_]bool{ true, false }) |pipelining| {
        var h: Harness = undefined;
        try h.init(.{ .pipelining = pipelining, .reject_recipients = &.{ "bad@example.com", "worse@example.com" } }, .{});
        defer h.deinit();
        const sent = try h.client.send(&h.c, .{ .to = &.{ "good@example.com", "bad@example.com" }, .text = "x" });
        try testing.expectEqual(@as(usize, 1), sent.accepted.len);
        try testing.expectEqualStrings("bad@example.com", sent.rejected[0].address);
        try testing.expectEqual(@as(u16, 550), sent.rejected[0].code);

        try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{ "bad@example.com", "worse@example.com" }, .text = "x" }));
        try expectDetail(&h, .invalid, "recipient_rejected");
        try testing.expect(h.fake.commandCount("RSET") >= 1);
        // The connection is still good.
        _ = try h.hello();
        try testing.expectEqual(@as(u32, 1), h.fake.connections.load(.monotonic));
    }
}

test "recipients: every one deferred is unavailable, not rejected" {
    var h: Harness = undefined;
    try h.init(.{ .defer_recipients = &.{"busy@example.com"} }, .{});
    defer h.deinit();
    try testing.expectError(error.ServiceUnavailable, h.client.send(&h.c, .{ .to = &.{"busy@example.com"}, .text = "x" }));
    try expectDetail(&h, .unavailable, "recipients_deferred");
}

test "size: a message over the server's SIZE fails before MAIL, and over max_message_bytes too" {
    var h: Harness = undefined;
    try h.init(.{ .size_limit = 1000 }, .{ .max_message_bytes = 100_000 });
    defer h.deinit();
    try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{"a@example.com"}, .text = repeat("x", 3000) }));
    try expectDetail(&h, .invalid, "message_too_large");
    try testing.expectEqual(@as(usize, 0), h.fake.commandCount("MAIL"));
    try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{"a@example.com"}, .text = repeat("x", 200_000) }));
    try expectDetail(&h, .invalid, "message_too_large");
    try testing.expectEqual(@as(usize, 0), h.fake.commandCount("MAIL"));
}

test "send: bad addresses and injected headers fail before anything is sent" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{"not an address"}, .text = "x" }));
    try expectDetail(&h, .invalid, "invalid_address");
    try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{"a@example.com"}, .subject = "s\r\nBcc: x@example.com", .text = "x" }));
    try expectDetail(&h, .invalid, "invalid_header");
    try testing.expectError(error.BadRequest, h.client.send(&h.c, .{ .to = &.{"a@example.com"}, .headers = &.{.{ "Date", "yesterday" }}, .text = "x" }));
    try testing.expectEqual(@as(u32, 0), h.fake.connections.load(.monotonic));
}

test "a file attachment larger than the writer buffer is streamed" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, 70_000);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 13);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.bin", .data = data });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/big.bin", .{tmp.sub_path});
    defer gpa.free(path);
    _ = try h.client.send(&h.c, .{
        .to = &.{"a@example.com"},
        .text = "see attached",
        .attachments = &.{.{ .filename = "big.bin", .content = .{ .file = path } }},
    });
    const m = h.fake.message(0).?;
    try testing.expectEqual(@as(u64, m.data.len), m.declared_size.?);
    const marker = "filename=\"big.bin\"\r\n\r\n";
    const start = std.mem.indexOf(u8, m.data, marker).? + marker.len;
    const end = std.mem.lastIndexOf(u8, m.data, "\r\n------").?;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var lines = std.mem.splitSequence(u8, m.data[start..end], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const size = try std.base64.standard.Decoder.calcSizeForSlice(line);
        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);
        try std.base64.standard.Decoder.decode(buf, line);
        try decoded.appendSlice(gpa, buf);
    }
    try testing.expectEqualSlices(u8, data, decoded.items);
}

test "pool: the connection is reused, and replaced after max_messages_per_connection" {
    var h: Harness = undefined;
    try h.init(.{}, .{ .max_messages_per_connection = 2 });
    defer h.deinit();
    _ = try h.hello();
    _ = try h.hello();
    try testing.expectEqual(@as(u32, 1), h.fake.connections.load(.monotonic));
    _ = try h.hello();
    try testing.expectEqual(@as(u32, 2), h.fake.connections.load(.monotonic));
    try testing.expectEqual(@as(usize, 3), h.fake.messageCount());
    // The first one said goodbye.
    try testing.expect(h.fake.commandCount("QUIT") >= 1);
}

test "pool: a reused connection the server closed is replaced without a failure" {
    var h: Harness = undefined;
    try h.init(.{ .close_after_message = true }, .{});
    defer h.deinit();
    _ = try h.hello();
    _ = try h.hello();
    _ = try h.hello();
    try testing.expectEqual(@as(usize, 3), h.fake.messageCount());
    try testing.expectEqual(@as(u32, 3), h.fake.connections.load(.monotonic));
}

test "closeIdle: idle connections are closed, the next send opens another" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    _ = try h.hello();
    try testing.expectEqual(@as(usize, 1), h.client.closeIdle());
    try testing.expectEqual(@as(usize, 0), h.client.closeIdle());
    _ = try h.hello();
    try testing.expectEqual(@as(u32, 2), h.fake.connections.load(.monotonic));
}

test "retry: a 451 after DATA is tried again with retry, not without" {
    var h: Harness = undefined;
    try h.init(.{}, .{ .retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(2), .jitter = .none } } });
    defer h.deinit();
    try h.fake.queueFinalCodes(&.{451});
    try testing.expectError(error.ServiceUnavailable, h.hello());
    try expectDetail(&h, .unavailable, "4.0.0");
    try h.fake.queueFinalCodes(&.{ 451, 451 });
    const sent = try h.client.with(.{ .retry = true }).send(&h.c, .{ .to = &.{"a@example.com"}, .text = "x" });
    try testing.expectEqual(@as(usize, 1), sent.accepted.len);
    try testing.expectEqual(@as(usize, 1), h.fake.messageCount());
}

test "retry: a drop after the final dot is never tried again" {
    var h: Harness = undefined;
    try h.init(.{}, .{ .retry = .{ .attempts = 5, .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(2), .jitter = .none } } });
    defer h.deinit();
    h.fake.drop_after_dot.store(1, .release);
    try testing.expectError(error.ServiceUnavailable, h.client.with(.{ .retry = true }).send(&h.c, .{ .to = &.{"a@example.com"}, .text = "x" }));
    try expectDetail(&h, .unavailable, "connection_closed");
    try testing.expectEqual(@as(usize, 1), h.fake.commandCount("DATA"));
    try testing.expectEqual(@as(usize, 0), h.fake.messageCount());
}

test "retry: a refused connection is tried again with retry and fails after the attempts" {
    const expected_log = errors.expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const client = try smtp.Client.init(gpa, io, .{
        .url = "smtp://127.0.0.1:1?tls=none",
        .from = "app@example.com",
        .environment = .development,
        .connect_timeout = .fromMilliseconds(500),
        .breaker = null,
        .retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(2), .jitter = .none } },
    });
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    try testing.expectError(error.ServiceUnavailable, client.with(.{ .retry = true }).send(&c, .{ .to = &.{"a@example.com"}, .text = "x" }));
    try testing.expectEqual(db.Class.unavailable, db.lastError(&c).?.class);
    try testing.expectError(error.ServiceUnavailable, client.send(&c, .{ .to = &.{"a@example.com"}, .text = "x" }));
}

test "tls: STARTTLS upgrades, then EHLO again; AUTH PLAIN after it" {
    if (comptime !has_tls) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .starttls = true, .auth = &.{ "PLAIN", "LOGIN" }, .auth_needs_tls = true, .credentials = .{ .user = "ada", .password = "s3cret" } }, .{ .username = "ada", .password = "s3cret" });
    defer h.deinit();
    _ = try h.hello();
    try testing.expectEqual(@as(usize, 2), h.fake.commandCount("EHLO"));
    try testing.expectEqual(@as(usize, 1), h.fake.commandCount("STARTTLS"));
    try testing.expectEqual(@as(usize, 1), h.fake.commandCount("AUTH PLAIN"));
    try testing.expectEqualStrings("ada", h.fake.last_user.?);
    try testing.expectEqualStrings("s3cret", h.fake.last_password.?);
}

test "tls: implicit TLS (smtps)" {
    if (comptime !has_tls) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .implicit_tls = true }, .{});
    defer h.deinit();
    _ = try h.hello();
    try testing.expectEqual(@as(usize, 1), h.fake.messageCount());
}

test "tls: STARTTLS required, and a server that does not offer it fails; loopback without it is plain" {
    if (has_tls) {
        const expected_log = errors.expectLog();
        defer expected_log.deinit();
        var h: Harness = undefined;
        try h.init(.{}, .{ .tls_mode = .starttls });
        defer h.deinit();
        try testing.expectError(error.ServiceUnavailable, h.hello());
        try expectDetail(&h, .unavailable, "starttls_unavailable");
        try testing.expectEqual(@as(usize, 0), h.fake.commandCount("MAIL"));
    }
    {
        var h: Harness = undefined;
        try h.init(.{}, .{ .url = null });
        defer h.deinit();
        // The URL carries ?tls=none; make one without it: loopback, auto.
        var buf: [96]u8 = undefined;
        const url = try std.fmt.bufPrint(&buf, "smtp://127.0.0.1:{d}", .{h.fake.port()});
        const other = try smtp.Client.init(gpa, h.io, .{ .url = url, .from = "app@example.com", .environment = .development });
        defer other.deinit();
        _ = try other.send(&h.c, .{ .to = &.{"a@example.com"}, .text = "x" });
        try testing.expectEqual(@as(usize, 1), h.fake.messageCount());
    }
}

test "auth: LOGIN when PLAIN is absent; a wrong password is authentication_failed" {
    {
        var h: Harness = undefined;
        try h.init(.{ .auth = &.{"LOGIN"}, .credentials = .{ .user = "ada", .password = "pw" } }, .{ .username = "ada", .password = "pw" });
        defer h.deinit();
        _ = try h.hello();
        try testing.expectEqual(@as(usize, 1), h.fake.commandCount("AUTH LOGIN"));
        try testing.expectEqualStrings("pw", h.fake.last_password.?);
    }
    {
        var h: Harness = undefined;
        try h.init(.{ .auth = &.{"PLAIN"}, .credentials = .{ .user = "ada", .password = "pw" } }, .{ .username = "ada", .password = "wrong" });
        defer h.deinit();
        try testing.expectError(error.Database, h.hello());
        try expectDetail(&h, .other, "authentication_failed");
        // The password is not in the error.
        try testing.expect(std.mem.indexOf(u8, db.lastError(&h.c).?.message, "wrong") == null);
    }
    {
        var h: Harness = undefined;
        try h.init(.{}, .{ .username = "ada", .password = "pw" });
        defer h.deinit();
        try testing.expectError(error.Database, h.hello());
        try expectDetail(&h, .other, "auth_unsupported");
    }
}

test "url: smtps means implicit TLS on 465, a public host with credentials and no TLS is refused" {
    const expected_log = errors.expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    if (has_tls) {
        const c = try smtp.Client.init(gpa, io, .{ .url = "smtps://user:p%40ss@smtp.example.com", .environment = .production });
        defer c.deinit();
        try testing.expectEqual(@as(u16, 465), c.settings.port);
        try testing.expect(c.settings.tls_mode == .implicit);
        try testing.expectEqualStrings("p@ss", c.settings.password.?);
        const s = try smtp.Client.init(gpa, io, .{ .url = "smtp://smtp.example.com", .environment = .production });
        defer s.deinit();
        try testing.expectEqual(@as(u16, 587), s.settings.port);
        try testing.expect(s.settings.tls_mode == .starttls_required);
    }
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .url = "smtp://user:pw@smtp.example.com:25?tls=none", .environment = .production }));
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .url = "http://smtp.example.com", .environment = .production }));
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .url = "smtp://127.0.0.1:1025?tls=maybe", .environment = .production }));
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .url = "smtp://127.0.0.1:1025", .from = "not a mailbox", .environment = .production }));
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .url = "smtp://127.0.0.1:1025", .max_connections = 0 }));
    // A local sink accepts credentials without TLS.
    const local = try smtp.Client.init(gpa, io, .{ .url = "smtp://user:pw@127.0.0.1:1025?tls=none", .environment = .production });
    local.deinit();
}

test "start: no SMTP_URL fails in production and goes to Mailpit's port otherwise" {
    const expected_log = errors.expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // The environment is the test process's: no SMTP_URL there.
    if (smtpUrlSet()) return error.SkipZigTest;
    try testing.expectError(error.InvalidOptions, smtp.Client.init(gpa, io, .{ .environment = .production }));
    const dev = try smtp.Client.init(gpa, io, .{ .environment = .development });
    defer dev.deinit();
    try testing.expectEqual(@as(u16, 1025), dev.settings.port);
    try testing.expectEqualStrings("127.0.0.1", dev.settings.host);
}

fn smtpUrlSet() bool {
    return db.env(null, "SMTP_URL") != null;
}

test "timeouts: a body adds its size at the minimum throughput" {
    const t = smtp.Client.boundFor(.fromSeconds(30), 10 * 1024 * 1024, 1024 * 1024).?;
    try testing.expectEqual(@as(i64, 40), t.toSeconds());
    try testing.expect(smtp.Client.boundFor(null, 1 << 30, 1) == null);
}

test "drain: a send after it fails, idle connections are closed" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    _ = try h.hello();
    h.client.drain(std.Io.Clock.Timestamp.now(h.io, .awake));
    try testing.expectError(error.ServiceUnavailable, h.hello());
    try expectDetail(&h, .unavailable, "draining");
    try testing.expect(h.fake.commandCount("QUIT") >= 1);
}

test "errors: ErrorMap moves the invalid class" {
    var h: Harness = undefined;
    try h.init(.{ .reject_recipients = &.{"bad@example.com"} }, .{ .errors = .{ .invalid = .unprocessable_entity } });
    defer h.deinit();
    try testing.expectError(error.UnprocessableEntity, h.client.send(&h.c, .{ .to = &.{"bad@example.com"}, .text = "x" }));
}

test "readiness: the probe connects and says goodbye" {
    var h: Harness = undefined;
    try h.init(.{}, .{});
    defer h.deinit();
    var c: db.Ctx = .{ .io = h.io, .arena = h.arena.allocator() };
    var ctx = smtp.erase(&c);
    try @import("session.zig").Session.probe(gpa, &ctx, h.client.errors, &h.client.settings);
    try testing.expectEqual(@as(usize, 1), h.fake.commandCount("QUIT"));
}

test "concurrent sends share the pool without losing a message" {
    var h: Harness = undefined;
    try h.init(.{}, .{ .max_connections = 2 });
    defer h.deinit();
    const Sender = struct {
        var failures: std.atomic.Value(u32) = .init(0);
        fn run(client: *smtp.Client, io: std.Io, n: u32) std.Io.Cancelable!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                _ = client.send(&c, .{ .to = &.{"a@example.com"}, .text = "x" }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        _ = failures.fetchAdd(1, .monotonic);
                        return;
                    },
                };
            }
        }
    };
    Sender.failures.store(0, .monotonic);
    var group: std.Io.Group = .init;
    defer group.cancel(h.io);
    for (0..4) |_| try group.concurrent(h.io, Sender.run, .{ h.client, h.io, @as(u32, 5) });
    try group.await(h.io);
    try testing.expectEqual(@as(u32, 0), Sender.failures.load(.monotonic));
    try testing.expectEqual(@as(usize, 20), h.fake.messageCount());
    try testing.expect(h.fake.connections.load(.monotonic) <= 2);
}

test {
    // Keeps the compose tests of mime.zig and the harness's imports used.
    _ = mime;
}
