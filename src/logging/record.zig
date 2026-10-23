//! Renders one log record into a caller's buffer: a JSON object (the
//! shared record shape) or a text line (message, then ` key=value` fields).

const std = @import("std");
const escape = @import("escape.zig");
const timestamp = @import("timestamp.zig");
const value = @import("value.zig");

const Writer = std.Io.Writer;

/// The request a record belongs to; empty strings are left out.
pub const Context = struct { request_id: []const u8 = "", trace_id: []const u8 = "", span_id: []const u8 = "" };

/// A record's fixed parts.
pub const Head = struct {
    now: std.Io.Timestamp,
    level: std.log.Level,
    /// "default" is left out of the record.
    scope: []const u8,
    message: []const u8,
    service: []const u8 = "",
    context: Context = .{},
};

pub fn levelName(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn writeStr(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    try escape.write(w, s);
    try w.writeByte('"');
}

fn writeHead(w: *Writer, head: Head, message: []const u8) Writer.Error!void {
    var ts: [timestamp.len]u8 = undefined;
    timestamp.format(head.now, &ts);
    try w.writeAll("{\"time\":\"");
    try w.writeAll(&ts);
    try w.writeAll("\",\"level\":\"");
    try w.writeAll(levelName(head.level));
    try w.writeByte('"');
    if (!std.mem.eql(u8, head.scope, "default")) {
        try w.writeAll(",\"scope\":");
        try writeStr(w, head.scope);
    }
    try w.writeAll(",\"message\":");
    try writeStr(w, message);
    if (head.service.len > 0) {
        try w.writeAll(",\"service\":");
        try writeStr(w, head.service);
    }
    if (head.context.request_id.len > 0) {
        try w.writeAll(",\"request_id\":");
        try writeStr(w, head.context.request_id);
    }
    if (head.context.trace_id.len > 0) {
        try w.writeAll(",\"trace_id\":");
        try writeStr(w, head.context.trace_id);
    }
    if (head.context.span_id.len > 0) {
        try w.writeAll(",\"span_id\":");
        try writeStr(w, head.context.span_id);
    }
}

fn writeJsonFull(w: *Writer, head: Head, fields: anytype, fragment: []const u8) Writer.Error!void {
    try writeHead(w, head, head.message);
    try value.writeFields(.json, w, fields);
    try w.writeAll(fragment);
    try w.writeByte('}');
}

/// The JSON record for `head`, then `fields`, then `fragment` (already
/// rendered members, each starting with a comma), without a newline. A
/// record that does not fit `buf` is rewritten with the message cut at a
/// character boundary, no fields, and `"truncated":true`.
pub fn json(buf: []u8, head: Head, fields: anytype, fragment: []const u8) []const u8 {
    var w: Writer = .fixed(buf);
    writeJsonFull(&w, head, fields, fragment) catch {
        w = .fixed(buf);
        const budget = buf.len / 2;
        const keep = escape.fittingPrefix(head.message, budget);
        writeHead(&w, head, head.message[0..keep]) catch {};
        w.writeAll(",\"truncated\":true}") catch {
            // Not even the head fits (a pathological scope or service): nothing sensible to write.
            w = .fixed(buf);
            w.writeAll("{\"truncated\":true}") catch {};
        };
    };
    return w.buffered();
}

/// The text form: the message, ` key=value` for each field, then the
/// request context. Cut when it does not fit.
pub fn text(buf: []u8, message: []const u8, context: Context, fields: anytype) []const u8 {
    var w: Writer = .fixed(buf);
    textInto(&w, message, context, fields) catch {};
    return w.buffered();
}

fn textInto(w: *Writer, message: []const u8, context: Context, fields: anytype) Writer.Error!void {
    try w.writeAll(message);
    try value.writeFields(.text, w, fields);
    if (context.request_id.len > 0) try value.writeFields(.text, w, .{ .request_id = context.request_id });
    if (context.trace_id.len > 0) try value.writeFields(.text, w, .{ .trace_id = context.trace_id });
    if (context.span_id.len > 0) try value.writeFields(.text, w, .{ .span_id = context.span_id });
}

test "json record: key order, time format, scope left out for default" {
    var buf: [1024]u8 = undefined;
    const head: Head = .{
        .now = .{ .nanoseconds = 1_700_000_000_123 * std.time.ns_per_ms },
        .level = .info,
        .scope = "default",
        .message = "hello",
    };
    try std.testing.expectEqualStrings(
        "{\"time\":\"2023-11-14T22:13:20.123Z\",\"level\":\"info\",\"message\":\"hello\",\"n\":1}",
        json(&buf, head, .{ .n = 1 }, ""),
    );
    var h2 = head;
    h2.scope = "billing";
    h2.service = "api";
    h2.context = .{ .request_id = "r1", .trace_id = "t1", .span_id = "s1" };
    try std.testing.expectEqualStrings(
        "{\"time\":\"2023-11-14T22:13:20.123Z\",\"level\":\"info\",\"scope\":\"billing\",\"message\":\"hello\",\"service\":\"api\",\"request_id\":\"r1\",\"trace_id\":\"t1\",\"span_id\":\"s1\"}",
        json(&buf, h2, .{}, ""),
    );
}

test "json record: a fragment follows the fields" {
    var buf: [1024]u8 = undefined;
    const head: Head = .{ .now = .{ .nanoseconds = 0 }, .level = .warn, .scope = "access", .message = "m" };
    try std.testing.expectEqualStrings(
        "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"warn\",\"scope\":\"access\",\"message\":\"m\",\"a\":1,\"b\":2}",
        json(&buf, head, .{ .a = 1 }, ",\"b\":2"),
    );
}

test "json record: over the buffer is cut with truncated:true" {
    var buf: [256]u8 = undefined;
    var long: [1000]u8 = undefined;
    @memset(&long, 'x');
    const head: Head = .{ .now = .{ .nanoseconds = 0 }, .level = .err, .scope = "default", .message = &long };
    const line = json(&buf, head, .{ .k = 1 }, "");
    try std.testing.expect(std.mem.endsWith(u8, line, ",\"truncated\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"k\"") == null);
    try std.testing.expect(line.len <= buf.len);
}

test "json record: invalid UTF-8 and control bytes" {
    var buf: [256]u8 = undefined;
    const head: Head = .{ .now = .{ .nanoseconds = 0 }, .level = .info, .scope = "default", .message = "a\tb\xff" };
    try std.testing.expect(std.mem.indexOf(u8, json(&buf, head, .{}, ""), "\"a\\tb\u{fffd}\"") != null);
}

test "json record: redaction by name and by marker" {
    const Key = struct {
        v: []const u8,
        pub const anole_sensitive = true;
    };
    var buf: [256]u8 = undefined;
    const head: Head = .{ .now = .{ .nanoseconds = 0 }, .level = .info, .scope = "default", .message = "m" };
    const line = json(&buf, head, .{ .password = "p", .k = Key{ .v = "z" } }, "");
    try std.testing.expect(std.mem.indexOf(u8, line, "\"password\":\"[REDACTED]\",\"k\":\"[REDACTED]\"") != null);
}

test "text: message then key=value, context last, strings quoted when needed" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "todo created id=7 title=\"Buy milk\" request_id=r1",
        text(&buf, "todo created", .{ .request_id = "r1" }, .{ .id = 7, .title = "Buy milk" }),
    );
}
