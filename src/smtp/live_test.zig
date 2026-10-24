//! `anole.smtp` against live Mailpit servers (axllent/mailpit): what was
//! sent is read back from Mailpit's API and checked. tests/smtp/run.sh
//! starts three of them and runs these; without `-Dsmtp-test-url` and
//! `-Dmailpit-api-url` they skip.
//!
//! - `-Dsmtp-test-url=smtp://127.0.0.1:1025?tls=none` and
//!   `-Dmailpit-api-url=http://127.0.0.1:8025`: the plain server.
//! - `ANOLE_SMTP_TEST_STARTTLS_URL` (smtp://user:pw@localhost:1587, STARTTLS
//!   required, any login accepted) with `ANOLE_MAILPIT_STARTTLS_API`, and
//!   `ANOLE_SMTP_TEST_SMTPS_URL` (smtps://localhost:1465) with
//!   `ANOLE_MAILPIT_SMTPS_API`; their certificate's file in
//!   `ANOLE_SMTP_TEST_CA_FILE`. Those tests skip without them.
const std = @import("std");
const features = @import("build_options");
const zio = @import("zio");
const db = @import("../db/root.zig");
const url_mod = @import("../db/url.zig");
const http = @import("../http/root.zig");
const smtp = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;

const plain_url: ?[]const u8 = features.smtp_test_url;
const plain_api: ?[]const u8 = features.mailpit_api_url;

fn real(name: []const u8) ?[]const u8 {
    return url_mod.realEnv(null, name);
}

/// One Mailpit: where to send, where to read.
const Target = struct { smtp_url: []const u8, api: []const u8, ca_file: ?[]const u8 = null };

fn plain() !Target {
    return .{ .smtp_url = plain_url orelse return error.SkipZigTest, .api = plain_api orelse return error.SkipZigTest };
}

fn starttls() !Target {
    return .{
        .smtp_url = real("ANOLE_SMTP_TEST_STARTTLS_URL") orelse return error.SkipZigTest,
        .api = real("ANOLE_MAILPIT_STARTTLS_API") orelse return error.SkipZigTest,
        .ca_file = real("ANOLE_SMTP_TEST_CA_FILE") orelse return error.SkipZigTest,
    };
}

fn smtps() !Target {
    return .{
        .smtp_url = real("ANOLE_SMTP_TEST_SMTPS_URL") orelse return error.SkipZigTest,
        .api = real("ANOLE_MAILPIT_SMTPS_API") orelse return error.SkipZigTest,
        .ca_file = real("ANOLE_SMTP_TEST_CA_FILE") orelse return error.SkipZigTest,
    };
}

fn open(io: std.Io, t: Target, extra: smtp.Options) !*smtp.Client {
    var o = extra;
    o.url = t.smtp_url;
    o.environ = .empty;
    if (o.from == null) o.from = "App <app@example.com>";
    if (o.environment == null) o.environment = .development;
    if (t.ca_file) |f| o.tls.ca = .{ .file = f };
    return smtp.Client.init(gpa, io, o);
}

fn httpDo(io: std.Io, method: http.Method, url: []const u8) ![]u8 {
    var client = http.Client.init(gpa, io, .{});
    defer client.deinit();
    var resp = try client.fetch(url, .{ .method = method });
    defer resp.deinit();
    return gpa.dupe(u8, (try resp.body()) orelse "");
}

fn clear(io: std.Io, t: Target) !void {
    const u = try std.fmt.allocPrint(gpa, "{s}/api/v1/messages", .{t.api});
    defer gpa.free(u);
    gpa.free(try httpDo(io, .delete, u));
}

const Summary = struct { ID: []const u8, Subject: []const u8 = "" };
const Listing = struct { total: u32 = 0, messages: []Summary = &.{} };

/// The raw messages Mailpit holds, newest first; free with `freeRaw`.
fn raws(io: std.Io, t: Target) ![][]u8 {
    const lu = try std.fmt.allocPrint(gpa, "{s}/api/v1/messages", .{t.api});
    defer gpa.free(lu);
    const body = try httpDo(io, .get, lu);
    defer gpa.free(body);
    var parsed = try std.json.parseFromSlice(Listing, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeRaw(&out);
    for (parsed.value.messages) |m| {
        const ru = try std.fmt.allocPrint(gpa, "{s}/api/v1/message/{s}/raw", .{ t.api, m.ID });
        defer gpa.free(ru);
        try out.append(gpa, try httpDo(io, .get, ru));
    }
    return out.toOwnedSlice(gpa);
}

fn freeRawSlice(list: [][]u8) void {
    for (list) |m| gpa.free(m);
    gpa.free(list);
}

fn freeRaw(list: *std.ArrayList([]u8)) void {
    for (list.items) |m| gpa.free(m);
    list.deinit(gpa);
}

fn withRuntime(t: Target, comptime body: anytype) !void {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    try body(rt.io(), t);
}

test "mailpit: text, html, an attachment and an inline image arrive as composed" {
    const target = try plain();
    try withRuntime(target, struct {
        fn run(io: std.Io, t: Target) !void {
            try clear(io, t);
            const client = try open(io, t, .{});
            defer client.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            const sent = try client.send(&c, .{
                .to = &.{"Ada Lovelace <ada@example.com>"},
                .cc = &.{"bob@example.com"},
                .subject = "Café ✔ live",
                .text = "plain version\n.leading dot",
                .html = "<p>rich <img src=\"cid:logo\"></p>",
                .headers = &.{.{ "List-Unsubscribe", "<mailto:unsub@example.com>" }},
                .attachments = &.{
                    .{ .filename = "logo.png", .content = .{ .bytes = "\x89PNG-bytes" }, .content_id = "logo" },
                    .{ .filename = "notes é.txt", .content = .{ .bytes = "attached text" } },
                },
            });
            const list = try raws(io, t);
            defer freeRawSlice(list);
            try testing.expectEqual(@as(usize, 1), list.len);
            const raw = list[0];
            try testing.expect(std.mem.indexOf(u8, raw, "Content-Type: multipart/mixed;") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "Content-Type: multipart/related;") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "Content-Type: multipart/alternative;") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "List-Unsubscribe: <mailto:unsub@example.com>") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "Content-ID: <logo>") != null);
            try testing.expect(std.mem.indexOf(u8, raw, "filename*=UTF-8''notes%20%C3%A9.txt") != null);
            try testing.expect(std.mem.indexOf(u8, raw, sent.message_id) != null);
            // The attachment bytes, decoded.
            const encoded = try arena.allocator().alloc(u8, std.base64.standard.Encoder.calcSize("attached text".len));
            _ = std.base64.standard.Encoder.encode(encoded, "attached text");
            try testing.expect(std.mem.indexOf(u8, raw, encoded) != null);
            try testing.expect(std.mem.indexOf(u8, raw, "\r\n.leading dot") != null);
        }
    }.run);
}

test "mailpit: twenty messages over one connection, pipelined" {
    const target = try plain();
    try withRuntime(target, struct {
        fn run(io: std.Io, t: Target) !void {
            try clear(io, t);
            const client = try open(io, t, .{ .max_connections = 1 });
            defer client.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            for (0..20) |i| {
                const subject = try std.fmt.allocPrint(arena.allocator(), "message {d}", .{i});
                _ = try client.send(&c, .{ .to = &.{ "a@example.com", "b@example.com" }, .subject = subject, .text = "x" });
            }
            const list = try raws(io, t);
            defer freeRawSlice(list);
            try testing.expectEqual(@as(usize, 20), list.len);
        }
    }.run);
}

test "mailpit: a message composed elsewhere goes through sendRaw" {
    const target = try plain();
    try withRuntime(target, struct {
        fn run(io: std.Io, t: Target) !void {
            try clear(io, t);
            const client = try open(io, t, .{});
            defer client.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            const raw = "From: Nodemailer <n@example.com>\nTo: ada@example.com\nSubject: from node\nMessage-ID: <live-raw@example.com>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n\nhello from a message composed elsewhere\n.dot\n";
            const sent = try client.sendRaw(&c, .{ .from = "n@example.com", .to = &.{"ada@example.com"} }, raw);
            try testing.expectEqualStrings("live-raw@example.com", sent.message_id);
            const list = try raws(io, t);
            defer freeRawSlice(list);
            try testing.expectEqual(@as(usize, 1), list.len);
            try testing.expect(std.mem.indexOf(u8, list[0], "Subject: from node") != null);
            try testing.expect(std.mem.indexOf(u8, list[0], "\r\n.dot") != null);
        }
    }.run);
}

test "mailpit: STARTTLS with AUTH PLAIN" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const target = try starttls();
    try withRuntime(target, struct {
        fn run(io: std.Io, t: Target) !void {
            try clear(io, t);
            const client = try open(io, t, .{});
            defer client.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            _ = try client.send(&c, .{ .to = &.{"ada@example.com"}, .subject = "starttls", .text = "x" });
            const list = try raws(io, t);
            defer freeRawSlice(list);
            try testing.expectEqual(@as(usize, 1), list.len);
        }
    }.run);
}

test "mailpit: implicit TLS" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const target = try smtps();
    try withRuntime(target, struct {
        fn run(io: std.Io, t: Target) !void {
            try clear(io, t);
            const client = try open(io, t, .{});
            defer client.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
            _ = try client.send(&c, .{ .to = &.{"ada@example.com"}, .subject = "smtps", .text = "x" });
            const list = try raws(io, t);
            defer freeRawSlice(list);
            try testing.expectEqual(@as(usize, 1), list.len);
        }
    }.run);
}
