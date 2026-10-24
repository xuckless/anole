//! C ABI tests for p3/smtp, imported from engine_test.zig: `anole_smtp_*`
//! through the engine against `anole.smtp.testing.FakeServer`, driven
//! through its Zig entry points as in engine_test.zig. Waits poll the
//! consumer with generous bounds; no assertion is about time.
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const config = @import("config.zig");
const abi = engine.abi;
const features = anole.features;

const alloc = std.testing.allocator;
const Io = std.Io;

/// The consumer's records, kept as they are polled.
const Events = struct {
    c: *engine.Consumer,
    list: std.ArrayList(struct { typ: u32, bytes: []align(8) u8 }) = .empty,

    fn pump(ev: *Events, ms: i32) !void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        const n = try engine.pollWait(ev.c, &buf, ms, &need);
        var off: usize = 0;
        while (off < n) {
            const head: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            const copy = try alloc.alignedAlloc(u8, .@"8", head.len);
            @memcpy(copy, buf[off..][0..head.len]);
            try ev.list.append(alloc, .{ .typ = head.type, .bytes = copy });
            off += head.len;
        }
    }

    fn waitFor(ev: *Events, typ: abi.EventType, from: usize, ms: u32) !usize {
        var waited: u32 = 0;
        while (true) {
            for (ev.list.items[from..], from..) |r, i| if (r.typ == @backingInt(typ)) return i;
            if (waited >= ms) return error.TimedOut;
            try ev.pump(50);
            waited += 50;
        }
    }

    fn result(ev: *const Events, i: usize) *const abi.SmtpResultEvent {
        return @ptrCast(@alignCast(ev.list.items[i].bytes.ptr));
    }

    fn span(ev: *const Events, i: usize, s: abi.Span) []const u8 {
        return ev.list.items[i].bytes[s.off..][0..s.len];
    }

    fn deinit(ev: *Events) void {
        for (ev.list.items) |r| alloc.free(r.bytes);
        ev.list.deinit(alloc);
    }
};

const Rig = struct {
    fake: *anole.smtp.testing.FakeServer,
    e: *engine.Engine,
    c: *engine.Consumer,
    ev: Events,
    json: []u8,

    fn start(r: *Rig, fake_options: anole.smtp.testing.Options) !void {
        r.fake = try anole.smtp.testing.FakeServer.init(alloc, std.testing.io, fake_options);
        errdefer r.fake.deinit();
        var url_buf: [96]u8 = undefined;
        const url = r.fake.url(&url_buf);
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 1, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "mail": [{{"name": "mail", "retry": {{"base_ms": 1, "max_ms": 2}}, "smtp": {{"url": "{s}", "from": "App <app@example.com>"}}}}]}}
        , .{url});
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        try r.e.start();
        r.ev = .{ .c = r.c };
    }

    fn mail(r: *Rig) *engine.smtp.Mail {
        return engine.smtp.find(r.e, "mail").?;
    }

    fn deinit(r: *Rig) void {
        r.ev.deinit();
        r.e.drain() catch {};
        _ = r.e.wait(5000);
        r.e.destroy();
        r.fake.deinit();
        alloc.free(r.json);
    }
};

fn strs(comptime list: []const []const u8) [list.len]abi.Str {
    var out: [list.len]abi.Str = undefined;
    for (list, &out) |s, *o| o.* = .of(s);
    return out;
}

fn message(to: []const abi.Str, subject: []const u8, text: []const u8) abi.SmtpMessage {
    return .{ .size = @sizeOf(abi.SmtpMessage), .to = to.ptr, .nto = to.len, .subject = .of(subject), .text = .of(text) };
}

test "capi smtp: send answers SMTP_RESULT with the message id, the rejected and the server's words" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{ .reject_recipients = &.{"bad@example.com"} });
    defer r.deinit();
    const to = strs(&.{ "ada@example.com", "bad@example.com" });
    var why: engine.smtp.Why = .{};
    try engine.smtp.send(r.mail(), r.c, message(&to, "Hello", "Hi there"), .{ .size = @sizeOf(abi.SmtpOptions) }, 41, &why);
    const i = try r.ev.waitFor(.smtp_result, 0, 10_000);
    const res = r.ev.result(i);
    try std.testing.expectEqual(@as(u64, 41), res.user_data);
    try std.testing.expectEqual(abi.OK, res.status);
    try std.testing.expectEqual(@as(u16, 250), res.smtp_code);
    try std.testing.expectEqual(@as(u32, 1), res.nrejected);
    try std.testing.expect(r.ev.span(i, res.message_id).len > 0);
    try std.testing.expect(std.mem.startsWith(u8, r.ev.span(i, res.response), "2.0.0 Ok: queued as FAKE"));
    const rej: *const abi.SmtpRejected = @ptrCast(@alignCast(r.ev.list.items[i].bytes.ptr + res.rejected_off));
    try std.testing.expectEqualStrings("bad@example.com", r.ev.span(i, rej.address));
    try std.testing.expectEqual(@as(u16, 550), rej.code);
    try std.testing.expectEqual(@as(usize, 1), r.fake.messageCount());
    const m = r.fake.message(0).?;
    try std.testing.expect(std.mem.indexOf(u8, m.data, "Subject: Hello\r\n") != null);
}

test "capi smtp: every recipient refused is E_SERVICE with class INVALID, 400 and recipient_rejected" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{ .reject_recipients = &.{"bad@example.com"} });
    defer r.deinit();
    const to = strs(&.{"bad@example.com"});
    var why: engine.smtp.Why = .{};
    try engine.smtp.send(r.mail(), r.c, message(&to, "x", "x"), .{ .size = @sizeOf(abi.SmtpOptions) }, 1, &why);
    const i = try r.ev.waitFor(.smtp_result, 0, 10_000);
    const res = r.ev.result(i);
    try std.testing.expectEqual(abi.E_SERVICE, res.status);
    try std.testing.expectEqual(@as(u16, 400), res.http_status);
    try std.testing.expectEqual(@as(u8, @backingInt(abi.DbErrorClass.invalid)), res.error_class);
    try std.testing.expectEqualStrings("recipient_rejected", r.ev.span(i, res.error_code));
    try std.testing.expectEqual(@as(u16, 550), res.smtp_code);
}

test "capi smtp: a 451 to the dot is E_SERVICE 503, and tried again only with the flag" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{});
    defer r.deinit();
    try r.fake.queueFinalCodes(&.{451});
    const to = strs(&.{"ada@example.com"});
    var why: engine.smtp.Why = .{};
    try engine.smtp.send(r.mail(), r.c, message(&to, "x", "x"), .{ .size = @sizeOf(abi.SmtpOptions) }, 1, &why);
    var i = try r.ev.waitFor(.smtp_result, 0, 10_000);
    try std.testing.expectEqual(abi.E_SERVICE, r.ev.result(i).status);
    try std.testing.expectEqual(@as(u16, 503), r.ev.result(i).http_status);
    try std.testing.expectEqual(@as(u16, 451), r.ev.result(i).smtp_code);
    try r.fake.queueFinalCodes(&.{451});
    try engine.smtp.send(r.mail(), r.c, message(&to, "x", "x"), .{ .size = @sizeOf(abi.SmtpOptions), .flags = abi.SMTP_F_RETRY }, 2, &why);
    i = try r.ev.waitFor(.smtp_result, i + 1, 10_000);
    try std.testing.expectEqual(abi.OK, r.ev.result(i).status);
    try std.testing.expectEqual(@as(u64, 2), r.ev.result(i).user_data);
}

test "capi smtp: a mistake in an address, a header or a flag is refused at the call" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{});
    defer r.deinit();
    var why: engine.smtp.Why = .{};
    const opts: abi.SmtpOptions = .{ .size = @sizeOf(abi.SmtpOptions) };
    const bad_to = strs(&.{"ada@example.com\r\nBcc: evil@example.com"});
    try std.testing.expectError(error.Invalid, engine.smtp.send(r.mail(), r.c, message(&bad_to, "x", "x"), opts, 1, &why));
    try std.testing.expect(std.mem.indexOf(u8, why.text(), "not a mailbox") != null);
    const ok_to = strs(&.{"ada@example.com"});
    try std.testing.expectError(error.Invalid, engine.smtp.send(r.mail(), r.c, message(&ok_to, "s\r\nBcc: x@example.com", "x"), opts, 1, &why));
    try std.testing.expect(std.mem.indexOf(u8, why.text(), "subject") != null);
    try std.testing.expectError(error.Invalid, engine.smtp.send(r.mail(), r.c, message(&ok_to, "x", "x"), .{ .size = @sizeOf(abi.SmtpOptions), .flags = 0x80 }, 1, &why));
    var empty: [0]abi.Str = .{};
    try std.testing.expectError(error.Invalid, engine.smtp.send(r.mail(), r.c, message(&empty, "x", "x"), opts, 1, &why));
    try std.testing.expect(std.mem.indexOf(u8, why.text(), "no recipients") != null);
    // Nothing was queued.
    try std.testing.expectEqual(@as(usize, 0), r.fake.messageCount());
}

test "capi smtp: attachments, an inline image and extra headers are composed" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{});
    defer r.deinit();
    const to = strs(&.{"ada@example.com"});
    const headers = [_]abi.Header{.{ .name = .of("List-Unsubscribe"), .value = .of("<mailto:u@example.com>") }};
    const atts = [_]abi.SmtpAttachment{
        .{ .size = @sizeOf(abi.SmtpAttachment), .filename = .of("logo.png"), .data = "PNG", .len = 3, .content_id = .of("logo"), .flags = abi.SMTP_ATTACH_F_INLINE },
        .{ .size = @sizeOf(abi.SmtpAttachment), .filename = .of("notes.txt"), .data = "notes", .len = 5 },
    };
    var m = message(&to, "Mixed", "text");
    m.html = .of("<img src=\"cid:logo\">");
    m.headers = &headers;
    m.nheaders = headers.len;
    m.attachments = &atts;
    m.nattachments = atts.len;
    var why: engine.smtp.Why = .{};
    try engine.smtp.send(r.mail(), r.c, m, .{ .size = @sizeOf(abi.SmtpOptions) }, 1, &why);
    const i = try r.ev.waitFor(.smtp_result, 0, 10_000);
    try std.testing.expectEqual(abi.OK, r.ev.result(i).status);
    const data = r.fake.message(0).?.data;
    try std.testing.expect(std.mem.indexOf(u8, data, "multipart/mixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "multipart/related") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "List-Unsubscribe: <mailto:u@example.com>") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "Content-ID: <logo>") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "filename=\"notes.txt\"") != null);
}

test "capi smtp: send_raw passes the bytes through, dot-stuffed with CRLF line ends" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{});
    defer r.deinit();
    const to = strs(&.{"Ada <ada@example.com>"});
    const raw = "From: n@example.com\nTo: ada@example.com\nMessage-ID: <raw-1@example.com>\nSubject: raw\n\n.dot line\nbody\n";
    var why: engine.smtp.Why = .{};
    try engine.smtp.sendRaw(r.mail(), r.c, .of("n@example.com"), &to, to.len, raw, .{ .size = @sizeOf(abi.SmtpOptions) }, 9, &why);
    const i = try r.ev.waitFor(.smtp_result, 0, 10_000);
    const res = r.ev.result(i);
    try std.testing.expectEqual(abi.OK, res.status);
    try std.testing.expectEqualStrings("raw-1@example.com", r.ev.span(i, res.message_id));
    const m = r.fake.message(0).?;
    try std.testing.expectEqualStrings("n@example.com", m.envelope_from);
    try std.testing.expectEqualStrings("ada@example.com", m.recipients[0]);
    try std.testing.expectEqualStrings("From: n@example.com\r\nTo: ada@example.com\r\nMessage-ID: <raw-1@example.com>\r\nSubject: raw\r\n\r\n.dot line\r\nbody\r\n", m.data);
    // Bad recipient and no recipients.
    const bad = strs(&.{"not an address"});
    try std.testing.expectError(error.Invalid, engine.smtp.sendRaw(r.mail(), r.c, .of("n@example.com"), &bad, bad.len, raw, .{ .size = @sizeOf(abi.SmtpOptions) }, 1, &why));
    try std.testing.expectError(error.Invalid, engine.smtp.sendRaw(r.mail(), r.c, .of("n@example.com"), null, 0, raw, .{ .size = @sizeOf(abi.SmtpOptions) }, 1, &why));
}

test "capi smtp: find by name; an unknown name is none" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(.{});
    defer r.deinit();
    try std.testing.expect(engine.smtp.find(r.e, "mail") != null);
    try std.testing.expect(engine.smtp.find(r.e, "other") == null);
    try std.testing.expectEqual(@as(u32, 0), r.mail().index);
}

test "capi config: mail parses with its defaults; bad entries say which key" {
    if (comptime !features.smtp) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var buf: [400]u8 = undefined;
    var why: Io.Writer = .fixed(&buf);
    const c = try config.parse(arena.allocator(),
        \\{"mail": [{"name": "m", "smtp": {"url": "smtps://u:p@smtp.example.com"}},
        \\           {"name": "n", "smtp": {"tls_mode": "none"}, "timeout_ms": 5000, "retry": {"attempts": 2}}]}
    , &why);
    try std.testing.expectEqual(@as(usize, 2), c.mail.len);
    try std.testing.expectEqualStrings("auto", c.mail[0].smtp.tls_mode);
    try std.testing.expectEqual(@as(u32, 100), c.mail[0].smtp.max_messages_per_connection);
    try std.testing.expectEqual(@as(u32, 30_000), c.mail[0].timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), c.mail[1].retry.attempts);
    try std.testing.expectEqual(@as(u32, 500), c.mail[1].retry.base_ms);

    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"mail\": [{\"name\": \"\", \"smtp\": {}}]}", .needle = "mail[0].name" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {}}, {\"name\": \"a\", \"smtp\": {}}]}", .needle = "is taken" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {\"tls_mode\": \"maybe\"}}]}", .needle = "tls_mode" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {\"max_connections\": 0}}]}", .needle = "max_connections" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {\"ca_file\": \"a\", \"insecure_skip_verify\": true}}]}", .needle = "insecure_skip_verify" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {\"client_cert_file\": \"a\"}}]}", .needle = "go together" },
        .{ .json = "{\"mail\": [{\"name\": \"a\", \"smtp\": {\"nope\": 1}}]}", .needle = "" },
    };
    for (cases) |case| {
        var w: Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), case.json, &w));
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), case.needle) != null);
    }
}
