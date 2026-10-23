// Adapted from vkiryakov/zefir src/nats/protocol/server_error.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! What a `-ERR` from the server means. The texts are those of
//! nats-server 2.15.1; they are compared without regard to case, since the
//! server's capitalization is not consistent.

const std = @import("std");

pub const Kind = enum {
    /// Wrong, missing, expired or revoked credentials:
    /// `Authorization Violation`, `User Authentication Expired`,
    /// `Account Authentication Expired`, `User Authentication Revoked`.
    authentication_failed,
    /// `Authentication Timeout`: no CONNECT in time.
    authentication_timeout,
    /// `Stale Connection`: the client did not answer the server's PINGs.
    stale_connection,
    /// `maximum connections exceeded`, for the server or the account.
    max_connections,
    /// `Secure Connection - TLS Required`: the server wants TLS, which this
    /// client does not do.
    tls_required,
    /// `Connection throttling is active`.
    refused,
    /// This client sent something the server rejects; a bug here:
    /// `Unknown Protocol Operation`, `Maximum Payload Violation`,
    /// `maximum control line exceeded`, `invalid client protocol`,
    /// `no responders requires headers support`.
    protocol,
    /// `Permissions Violation for ...`: the user may not use a subject.
    permissions_violation,
    /// `maximum subscriptions exceeded`.
    max_subscriptions,
    /// `Invalid Subject`, `Invalid Publish Subject`.
    invalid_subject,
    /// A text this client does not know.
    unknown,

    /// The server closes the connection after this error. After the others
    /// the connection stays, and an unknown text leaves it alone.
    pub fn closesConnection(kind: Kind) bool {
        return switch (kind) {
            .authentication_failed, .authentication_timeout, .stale_connection, .max_connections, .tls_required, .refused, .protocol => true,
            .permissions_violation, .max_subscriptions, .invalid_subject, .unknown => false,
        };
    }
};

/// What a permissions violation refers to. The server quotes the names
/// with Go's %q, which escapes `"`, `\`, control bytes, invalid UTF-8 and
/// runes that do not print: compare them with `quotedEql`.
pub const Permission = struct {
    operation: Operation,
    /// The subject, or the reply-to subject for `.reply`, as quoted.
    subject: []const u8,
    /// The queue group of a denied subscription, when the text names one.
    queue: ?[]const u8 = null,
    /// The SID of a subscription the server revoked, when the text names
    /// one.
    sid: ?u64 = null,

    pub const Operation = enum { publish, subscribe, reply };
};

pub const Classified = struct {
    kind: Kind,
    /// For `.permissions_violation` when the text could be read; slices of
    /// the text.
    permission: ?Permission = null,
};

const Rule = struct { prefix: []const u8, kind: Kind };

const rules = [_]Rule{
    .{ .prefix = "Authorization Violation", .kind = .authentication_failed },
    .{ .prefix = "User Authentication Expired", .kind = .authentication_failed },
    .{ .prefix = "Account Authentication Expired", .kind = .authentication_failed },
    .{ .prefix = "User Authentication Revoked", .kind = .authentication_failed },
    .{ .prefix = "Authentication Timeout", .kind = .authentication_timeout },
    .{ .prefix = "Stale Connection", .kind = .stale_connection },
    .{ .prefix = "maximum connections exceeded", .kind = .max_connections },
    .{ .prefix = "maximum account active connections exceeded", .kind = .max_connections },
    .{ .prefix = "Secure Connection - TLS Required", .kind = .tls_required },
    .{ .prefix = "Connection throttling is active", .kind = .refused },
    .{ .prefix = "Unknown Protocol Operation", .kind = .protocol },
    .{ .prefix = "Maximum Payload Violation", .kind = .protocol },
    .{ .prefix = "maximum control line exceeded", .kind = .protocol },
    .{ .prefix = "invalid client protocol", .kind = .protocol },
    .{ .prefix = "no responders requires headers support", .kind = .protocol },
    .{ .prefix = "Permissions Violation for ", .kind = .permissions_violation },
    .{ .prefix = "maximum subscriptions exceeded", .kind = .max_subscriptions },
    .{ .prefix = "Invalid Subject", .kind = .invalid_subject },
    .{ .prefix = "Invalid Publish Subject", .kind = .invalid_subject },
};

/// Classifies the text of `-ERR`, without its quotes.
pub fn classify(text: []const u8) Classified {
    for (rules) |rule| {
        if (!std.ascii.startsWithIgnoreCase(text, rule.prefix)) continue;
        if (rule.kind != .permissions_violation) return .{ .kind = rule.kind };
        return .{ .kind = .permissions_violation, .permission = permission(text[rule.prefix.len..]) };
    }
    return .{ .kind = .unknown };
}

/// Which refusal of the credentials a text is: a server that refuses them
/// twice the same way in a row is not tried again.
pub const Refusal = enum {
    authorization_violation,
    user_authentication_expired,
    account_authentication_expired,
    user_authentication_revoked,
};

/// The refusal a `-ERR` text is; null for any other text.
pub fn refusal(text: []const u8) ?Refusal {
    const texts = [_]struct { prefix: []const u8, refusal: Refusal }{
        .{ .prefix = "Authorization Violation", .refusal = .authorization_violation },
        .{ .prefix = "User Authentication Expired", .refusal = .user_authentication_expired },
        .{ .prefix = "Account Authentication Expired", .refusal = .account_authentication_expired },
        .{ .prefix = "User Authentication Revoked", .refusal = .user_authentication_revoked },
    };
    for (texts) |t| {
        if (std.ascii.startsWithIgnoreCase(text, t.prefix)) return t.refusal;
    }
    return null;
}

/// Reads `Publish to "s"`, `Publish with Reply of "r"`,
/// `Subscription to "s"`, `Subscription to "s" using queue "q"`,
/// `Subscription to "s", too many tokens` and, after a reload of the
/// server's configuration, either subscription form with `(sid "n")`.
fn permission(rest: []const u8) ?Permission {
    const forms = [_]struct { prefix: []const u8, operation: Permission.Operation }{
        .{ .prefix = "Publish with Reply of \"", .operation = .reply },
        .{ .prefix = "Publish to \"", .operation = .publish },
        .{ .prefix = "Subscription to \"", .operation = .subscribe },
    };
    for (forms) |form| {
        if (!std.ascii.startsWithIgnoreCase(rest, form.prefix)) continue;
        var tail = rest[form.prefix.len..];
        var result: Permission = .{ .operation = form.operation, .subject = quotedPrefix(&tail) orelse return null };
        if (form.operation != .subscribe) return result;
        const queue_marker = " using queue \"";
        if (std.ascii.startsWithIgnoreCase(tail, queue_marker)) {
            tail = tail[queue_marker.len..];
            result.queue = quotedPrefix(&tail) orelse return null;
        }
        const sid_marker = " (sid \"";
        if (std.ascii.startsWithIgnoreCase(tail, sid_marker)) {
            tail = tail[sid_marker.len..];
            const sid = quotedPrefix(&tail) orelse return null;
            result.sid = std.fmt.parseInt(u64, sid, 10) catch null;
        }
        return result;
    }
    return null;
}

/// The text up to the quote that ends it, the first `"` no backslash
/// escapes; `tail` moves past that quote.
fn quotedPrefix(tail: *[]const u8) ?[]const u8 {
    const text = tail.*;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '"' => {
                tail.* = text[i + 1 ..];
                return text[0..i];
            },
            else => {},
        }
    }
    return null;
}

/// Text from the server, for a log line: `log.warn("{f}", .{printable(text)})`.
/// Bytes that do not print, CR, LF, ESC and every byte from 0x80 among
/// them, are written as `\xNN`, so a server cannot start a line of its own
/// or a terminal sequence in the application's log; the text is cut after
/// `max_len` bytes.
pub fn printable(text: []const u8) Printable {
    return .{ .text = text };
}

pub const Printable = struct {
    text: []const u8,

    pub const max_len = 256;

    pub fn format(p: Printable, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (p.text[0..@min(p.text.len, max_len)]) |c| switch (c) {
            ' '...'~' => try w.writeByte(c),
            else => try w.print("\\x{x:0>2}", .{c}),
        };
        if (p.text.len > max_len) try w.print("... ({d} bytes)", .{p.text.len});
    }
};

const testing = std.testing;

test "fatal errors close the connection" {
    for ([_]struct { []const u8, Kind }{
        .{ "Authorization Violation", .authentication_failed },
        .{ "AUTHORIZATION VIOLATION", .authentication_failed },
        .{ "User Authentication Expired", .authentication_failed },
        .{ "Account Authentication Expired", .authentication_failed },
        .{ "User Authentication Revoked", .authentication_failed },
        .{ "Authentication Timeout", .authentication_timeout },
        .{ "Stale Connection", .stale_connection },
        .{ "maximum connections exceeded", .max_connections },
        .{ "maximum account active connections exceeded", .max_connections },
        .{ "Secure Connection - TLS Required", .tls_required },
        .{ "Connection throttling is active. Please try again later.", .refused },
        .{ "Unknown Protocol Operation", .protocol },
        .{ "Maximum Payload Violation", .protocol },
        .{ "maximum control line exceeded", .protocol },
        .{ "invalid client protocol", .protocol },
        .{ "no responders requires headers support", .protocol },
    }) |case| {
        const classified = classify(case[0]);
        try testing.expectEqual(case[1], classified.kind);
        try testing.expect(classified.kind.closesConnection());
    }
}

test "the connection stays after these, and after unknown texts" {
    for ([_]struct { []const u8, Kind }{
        .{ "maximum subscriptions exceeded", .max_subscriptions },
        .{ "Invalid Subject", .invalid_subject },
        .{ "Invalid Publish Subject", .invalid_subject },
        .{ "Something new in a later server", .unknown },
        .{ "", .unknown },
    }) |case| {
        const classified = classify(case[0]);
        try testing.expectEqual(case[1], classified.kind);
        try testing.expect(!classified.kind.closesConnection());
    }
}

test "permissions violations name the subject" {
    const publish = classify("Permissions Violation for Publish to \"secret.x\"");
    try testing.expectEqual(.permissions_violation, publish.kind);
    try testing.expectEqual(.publish, publish.permission.?.operation);
    try testing.expectEqualStrings("secret.x", publish.permission.?.subject);

    const subscribe = classify("permissions violation for subscription to \"forbidden\"");
    try testing.expectEqual(.subscribe, subscribe.permission.?.operation);
    try testing.expectEqualStrings("forbidden", subscribe.permission.?.subject);
    try testing.expect(subscribe.permission.?.queue == null);

    const queue = classify("Permissions Violation for Subscription to \"jobs.>\" using queue \"workers\"");
    try testing.expectEqualStrings("jobs.>", queue.permission.?.subject);
    try testing.expectEqualStrings("workers", queue.permission.?.queue.?);

    const tokens = classify("Permissions Violation for Subscription to \"a.b.c\", too many tokens");
    try testing.expectEqualStrings("a.b.c", tokens.permission.?.subject);

    const reply = classify("Permissions Violation for Publish with Reply of \"_R_.x\"");
    try testing.expectEqual(.reply, reply.permission.?.operation);
    try testing.expectEqualStrings("_R_.x", reply.permission.?.subject);

    const unreadable = classify("Permissions Violation for something else");
    try testing.expectEqual(.permissions_violation, unreadable.kind);
    try testing.expect(unreadable.permission == null);
}

/// Whether `quoted`, the inside of a string that Go's %q quoted, stands for
/// `raw`. It reads the escapes %q writes: `\"`, `\\`, `\a`, `\b`, `\f`,
/// `\n`, `\r`, `\t`, `\v`, `\xHH` (a byte), `\uHHHH` and `\UHHHHHHHH` (a
/// rune, as UTF-8); anything else after a backslash matches nothing.
pub fn quotedEql(quoted: []const u8, raw: []const u8) bool {
    var rest = quoted;
    var expected = raw;
    while (rest.len > 0) {
        var buffer: [4]u8 = undefined;
        const piece = unescapeNext(&rest, &buffer) orelse return false;
        if (!std.mem.startsWith(u8, expected, piece)) return false;
        expected = expected[piece.len..];
    }
    return expected.len == 0;
}

/// The bytes the first character or escape of `rest` stands for, in
/// `buffer` or in `rest`; `rest` moves past it. Null for a broken escape.
fn unescapeNext(rest: *[]const u8, buffer: *[4]u8) ?[]const u8 {
    const text = rest.*;
    if (text[0] != '\\') {
        rest.* = text[1..];
        return text[0..1];
    }
    if (text.len < 2) return null;
    const simple: ?u8 = switch (text[1]) {
        '"' => '"',
        '\\' => '\\',
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0b,
        else => null,
    };
    if (simple) |byte| {
        buffer[0] = byte;
        rest.* = text[2..];
        return buffer[0..1];
    }
    const digits: usize = switch (text[1]) {
        'x' => 2,
        'u' => 4,
        'U' => 8,
        else => return null,
    };
    if (text.len < 2 + digits) return null;
    var value: u32 = 0;
    for (text[2..][0..digits]) |c| value = value * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    rest.* = text[2 + digits ..];
    if (text[1] == 'x') {
        buffer[0] = @intCast(value);
        return buffer[0..1];
    }
    const rune = std.math.cast(u21, value) orelse return null;
    const len = std.unicode.utf8Encode(rune, buffer) catch return null;
    return buffer[0..len];
}

test "permission texts quote subjects as Go's %q does" {
    const p = classify("Permissions Violation for Subscription to \"q\\\"uo\\\\te.\\xff.\\u00a0.ü\" using queue \"w\\\"q\"").permission.?;
    try testing.expectEqual(.subscribe, p.operation);
    try testing.expectEqualStrings("q\\\"uo\\\\te.\\xff.\\u00a0.ü", p.subject);
    try testing.expect(quotedEql(p.subject, "q\"uo\\te.\xff.\u{a0}.ü"));
    try testing.expect(!quotedEql(p.subject, "q\"uo\\te.\xff.\u{a0}.u"));
    try testing.expect(quotedEql(p.queue.?, "w\"q"));
    // An escaped quote does not end the subject.
    const tricky = classify("Permissions Violation for Subscription to \"a\\\" using queue \\\"b\"").permission.?;
    try testing.expect(tricky.queue == null);
    try testing.expect(quotedEql(tricky.subject, "a\" using queue \"b"));
}

test "a subscription revoked by a reload is named by its SID" {
    const plain = classify("Permissions Violation for Subscription to \"foo\" (sid \"12\")").permission.?;
    try testing.expectEqual(12, plain.sid.?);
    try testing.expect(plain.queue == null);
    const grouped = classify("Permissions Violation for Subscription to \"foo\" using queue \"g\" (sid \"7\")").permission.?;
    try testing.expectEqual(7, grouped.sid.?);
    try testing.expect(quotedEql(grouped.queue.?, "g"));
    try testing.expect(classify("Permissions Violation for Subscription to \"foo\"").permission.?.sid == null);
}

test "quotedEql reads every escape %q writes, and nothing else" {
    for ([_][2][]const u8{
        .{ "plain", "plain" },
        .{ "", "" },
        .{ "\\a\\b\\f\\n\\r\\t\\v", "\x07\x08\x0c\n\r\t\x0b" },
        .{ "\\\"\\\\", "\"\\" },
        .{ "\\x00\\x7f\\xff", "\x00\x7f\xff" },
        .{ "\\u00a0\\u2028", "\u{a0}\u{2028}" },
        .{ "\\U0001f600", "\u{1f600}" },
        .{ "ü😀", "ü😀" },
    }) |case| try testing.expect(quotedEql(case[0], case[1]));
    for ([_][2][]const u8{
        .{ "abc", "abd" },       .{ "abc", "ab" },     .{ "ab", "abc" },
        .{ "\\q", "q" },         .{ "\\", "\\" },      .{ "\\x0", "\x00" },
        .{ "\\xzz", "z" },       .{ "\\u12", "\x12" }, .{ "\\ud800", "\xed\xa0\x80" },
        .{ "\\U00110000", "?" },
    }) |case| try testing.expect(!quotedEql(case[0], case[1]));
}

test "refusals of the credentials are told apart" {
    try testing.expectEqual(Refusal.authorization_violation, refusal("Authorization Violation").?);
    try testing.expectEqual(Refusal.authorization_violation, refusal("authorization violation").?);
    try testing.expectEqual(Refusal.user_authentication_expired, refusal("User Authentication Expired").?);
    try testing.expectEqual(Refusal.account_authentication_expired, refusal("Account Authentication Expired").?);
    try testing.expectEqual(Refusal.user_authentication_revoked, refusal("User Authentication Revoked").?);
    try testing.expect(refusal("Stale Connection") == null);
    // Every refusal is an authentication failure.
    for ([_][]const u8{ "Authorization Violation", "User Authentication Expired", "Account Authentication Expired", "User Authentication Revoked" }) |text| {
        try testing.expectEqual(Kind.authentication_failed, classify(text).kind);
    }
}

test "server text in a log line cannot start a line of its own or a terminal sequence" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{printable("x\nerror(nats): FORGED \x1b[31mred\r\xc3\xbc")});
    try testing.expectEqualStrings("x\\x0aerror(nats): FORGED \\x1b[31mred\\x0d\\xc3\\xbc", w.buffered());

    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    var cut: std.Io.Writer = .fixed(&buffer);
    try cut.print("{f}", .{printable(&long)});
    try testing.expect(std.mem.endsWith(u8, cut.buffered(), "a... (300 bytes)"));
    try testing.expectEqual(Printable.max_len + "... (300 bytes)".len, cut.buffered().len);
}
