// Adapted from vkiryakov/zefir src/nats/protocol/subject.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Subject and queue-group checks, run before anything is
//! queued. The server checks almost nothing here: a space would shift the
//! arguments of the protocol line, and a CR or LF would let the caller
//! inject frames of its own.
//!
//! `*` and `>` are wildcards only as whole tokens; `a*b` is an ordinary
//! literal, as on the server. Bytes from 0x80 up (UTF-8) are allowed.

const std = @import("std");

pub const Error = error{InvalidSubject};

/// A subject to publish to, or a reply-to subject: dot-separated tokens,
/// none empty, no whitespace or control bytes, no token that is exactly
/// `*` or `>`.
pub fn validatePublish(subject: []const u8) Error!void {
    return validate(subject, .publish);
}

/// A subject to subscribe to: like `validatePublish`, but any token may be
/// `*` and the last token may be `>`.
pub fn validateSubscribe(subject: []const u8) Error!void {
    return validate(subject, .subscribe);
}

/// A queue group name: not empty, no whitespace or control bytes.
pub fn isValidQueue(queue: []const u8) bool {
    if (queue.len == 0) return false;
    for (queue) |c| {
        if (!isSubjectByte(c)) return false;
    }
    return true;
}

const Kind = enum { publish, subscribe };

fn validate(subject: []const u8, kind: Kind) Error!void {
    if (subject.len == 0) return error.InvalidSubject;
    var tokens = std.mem.splitScalar(u8, subject, '.');
    while (tokens.next()) |token| {
        if (token.len == 0) return error.InvalidSubject;
        for (token) |c| {
            if (!isSubjectByte(c)) return error.InvalidSubject;
        }
        if (std.mem.eql(u8, token, "*")) {
            if (kind == .publish) return error.InvalidSubject;
        } else if (std.mem.eql(u8, token, ">")) {
            if (kind == .publish or tokens.peek() != null) return error.InvalidSubject;
        }
    }
}

/// Space, control bytes and DEL are never part of a subject.
fn isSubjectByte(c: u8) bool {
    return c > ' ' and c != 0x7f;
}

test "publish and reply-to subjects with wildcards, empty tokens, whitespace or control bytes are InvalidSubject" {
    for ([_][]const u8{ "foo", "foo.bar.baz", "a*b", "a>b.c", "$SYS.x", "_INBOX.abc.1", "foo-bar_baz", "ünïcödé.subject" }) |subject| {
        try validatePublish(subject);
    }
    for ([_][]const u8{
        "",               ".",       "foo.",    ".foo", "foo..bar", "foo bar", "foo\tbar",
        "foo\r\nPUB x 1", "foo\x00", "foo\x7f", "*",    "foo.*",    ">",       "foo.>",
        "foo.*.bar",
    }) |subject| {
        try std.testing.expectError(error.InvalidSubject, validatePublish(subject));
    }
}

test "subscribe subjects take * and a final >, and refuse empty tokens, > before the end and whitespace" {
    for ([_][]const u8{ "foo", "*", ">", "foo.*", "foo.>", "*.bar.>", "foo.*.baz", "a*b", "a>b" }) |subject| {
        try validateSubscribe(subject);
    }
    for ([_][]const u8{ "", "foo.", ".foo", "foo..bar", ">.foo", "foo.>.bar", "foo bar", "foo\n", "foo\x01" }) |subject| {
        try std.testing.expectError(error.InvalidSubject, validateSubscribe(subject));
    }
}

test "queue group names with whitespace, control bytes or DEL, or empty, are refused" {
    for ([_][]const u8{ "workers", "a.b", "q-1", "очередь" }) |queue| {
        try std.testing.expect(isValidQueue(queue));
    }
    for ([_][]const u8{ "", "two words", "tab\tq", "cr\r", "nul\x00", "del\x7f" }) |queue| {
        try std.testing.expect(!isValidQueue(queue));
    }
}
