//! Composing a message (RFC 5322 with MIME, RFC 2045-2047, 2183, 2231):
//! the headers, the text and HTML bodies, inline images and attachments,
//! as a list of parts whose total size is known before anything is sent.
//! Every name, value, address and file name is checked for CR, LF and NUL
//! first, so nothing a caller passes can add a header or an SMTP command.
const std = @import("std");
const address = @import("address.zig");
const encode = @import("core/encode.zig");
const date = @import("core/date.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Header = [2][]const u8;

pub const Attachment = struct {
    filename: []const u8,
    /// Null: from the extension, else application/octet-stream.
    content_type: ?[]const u8 = null,
    content: Content,
    /// Set: inline, referenced from the HTML as cid:<content_id>.
    content_id: ?[]const u8 = null,

    pub const Content = union(enum) {
        bytes: []const u8,
        /// A file path, read while sending.
        file: []const u8,
    };
};

pub const Message = struct {
    /// Null: `Options.from`.
    from: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    to: []const []const u8 = &.{},
    cc: []const []const u8 = &.{},
    /// Sent to, never written into the message.
    bcc: []const []const u8 = &.{},
    subject: []const u8 = "",
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
    attachments: []const Attachment = &.{},
    /// Extra headers (List-Unsubscribe, X-Entity-Ref-ID, ...). Date, From,
    /// To, Cc, Bcc, Reply-To, Subject, Message-ID, MIME-Version and
    /// Content-* here are `error.BadRequest` (`invalid_header`).
    headers: []const Header = &.{},
    /// MAIL FROM (bounces); null: the From address.
    envelope_from: ?[]const u8 = null,
    /// Null: "<16 random hex>@<From's domain>".
    message_id: ?[]const u8 = null,
};

/// One piece of the encoded message.
pub const Part = union(enum) {
    bytes: []const u8,
    /// A file attachment's base64 body, read and encoded while sending.
    file: FilePart,
};

pub const FilePart = struct {
    path: []const u8,
    /// Its size when composed; no more than this many bytes are sent.
    size: u64,
};

/// A message ready to send.
pub const Composed = struct {
    parts: []const Part,
    /// The bytes of all the parts, as they will be written (before dot
    /// stuffing): what `SIZE=` says.
    size: u64,
    envelope_from: []const u8,
    /// Every recipient (to, cc, bcc), as bare addresses.
    recipients: []const []const u8,
    /// Without the angle brackets.
    message_id: []const u8,
    /// An address is not ASCII: the server must offer SMTPUTF8.
    utf8: bool,
    /// Line ends are made CRLF as it is sent (a message composed elsewhere).
    normalize: bool = false,
};

pub const Defaults = struct {
    /// `Options.from`.
    from: ?[]const u8 = null,
    max_bytes: u64 = 25 * 1024 * 1024,
    /// The most recipients of one message (RFC 5321 requires 100).
    max_recipients: usize = 100,
};

/// What went wrong, for `anole.db.lastError`.
pub const Failure = struct {
    class: enum { invalid, other } = .invalid,
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

const Builder = struct {
    arena: Allocator,
    aw: Writer.Allocating,
    parts: std.ArrayList(Part) = .empty,
    size: u64 = 0,

    fn init(arena: Allocator) Builder {
        return .{ .arena = arena, .aw = .init(arena) };
    }

    fn w(self: *Builder) *Writer {
        return &self.aw.writer;
    }

    /// Moves what was written into a part.
    fn flush(self: *Builder) Allocator.Error!void {
        const bytes = self.aw.writer.buffered();
        if (bytes.len == 0) return;
        try self.parts.append(self.arena, .{ .bytes = try self.arena.dupe(u8, bytes) });
        self.size += bytes.len;
        self.aw.clearRetainingCapacity();
    }

    fn addFile(self: *Builder, path: []const u8, size: u64) Allocator.Error!void {
        try self.flush();
        try self.parts.append(self.arena, .{ .file = .{ .path = path, .size = size } });
        self.size += encode.base64Size(size);
    }
};

/// What `prepare` found out about a message's addresses.
const Prepared = struct {
    from: address.Mailbox,
    to_boxes: []const address.Mailbox,
    cc_boxes: []const address.Mailbox,
    reply_to: ?address.Mailbox,
    recipients: []const []const u8,
    envelope_from: []const u8,
    utf8: bool,
};

/// Checks everything about `msg` that needs no rendering: the addresses,
/// the header values, the attachments' names. `fail` says what is wrong
/// when this returns `error.Invalid`.
fn prepare(arena: Allocator, msg: Message, defaults: Defaults, fail: *Failure) Error!Prepared {
    // Addresses.
    const from_text = msg.from orelse defaults.from orelse
        return invalid(fail, "invalid_address", "the message has no From address: set Message.from or Options.from (SMTP_FROM)");
    const from = try mailbox(arena, fail, "from", from_text);
    var recipients: std.ArrayList([]const u8) = .empty;
    var to_boxes: std.ArrayList(address.Mailbox) = .empty;
    var cc_boxes: std.ArrayList(address.Mailbox) = .empty;
    var utf8 = from.needsUtf8();
    for (msg.to) |t| {
        const m = try mailbox(arena, fail, "to", t);
        try to_boxes.append(arena, m);
        try recipients.append(arena, m.address);
        utf8 = utf8 or m.needsUtf8();
    }
    for (msg.cc) |t| {
        const m = try mailbox(arena, fail, "cc", t);
        try cc_boxes.append(arena, m);
        try recipients.append(arena, m.address);
        utf8 = utf8 or m.needsUtf8();
    }
    for (msg.bcc) |t| {
        const m = try mailbox(arena, fail, "bcc", t);
        try recipients.append(arena, m.address);
        utf8 = utf8 or m.needsUtf8();
    }
    if (recipients.items.len == 0) return invalid(fail, "invalid_address", "the message has no recipients (to, cc or bcc)");
    if (recipients.items.len > defaults.max_recipients)
        return invalid(fail, "too_many_recipients", try std.fmt.allocPrint(arena, "{d} recipients; at most {d} per message", .{ recipients.items.len, defaults.max_recipients }));
    const reply_to = if (msg.reply_to) |r| try mailbox(arena, fail, "reply_to", r) else null;
    var envelope_from: []const u8 = from.address;
    if (msg.envelope_from) |e| {
        const m = try mailbox(arena, fail, "envelope_from", e);
        envelope_from = m.address;
        utf8 = utf8 or m.needsUtf8();
    }

    // Header values.
    try checkText(fail, msg.subject);
    for (msg.headers) |h| try checkExtraHeader(fail, h);
    if (msg.message_id) |id| try checkMessageId(fail, id);
    for (msg.attachments) |a| try checkAttachment(fail, a);
    return .{
        .from = from,
        .to_boxes = to_boxes.items,
        .cc_boxes = cc_boxes.items,
        .reply_to = reply_to,
        .recipients = recipients.items,
        .envelope_from = envelope_from,
        .utf8 = utf8,
    };
}

/// `prepare` without composing: for a caller that wants to refuse a message
/// at once (the C ABI, on its caller's thread) and compose it later.
pub fn validate(arena: Allocator, msg: Message, defaults: Defaults, fail: *Failure) Error!void {
    _ = try prepare(arena, msg, defaults, fail);
}

/// Composes `msg`. `fail` says what is wrong when this returns
/// `error.Invalid`.
pub fn compose(
    arena: Allocator,
    io: std.Io,
    msg: Message,
    defaults: Defaults,
    random: std.Random,
    now: i64,
    fail: *Failure,
) Error!Composed {
    const p = try prepare(arena, msg, defaults, fail);
    const from = p.from;
    const recipients = p.recipients;
    const utf8 = p.utf8;
    const envelope_from = p.envelope_from;

    var message_id: []const u8 = undefined;
    if (msg.message_id) |id| {
        message_id = std.mem.trim(u8, id, "<>");
    } else {
        var idw: Writer.Allocating = .init(arena);
        encode.writeMessageId(&idw.writer, from.domain(), random) catch return error.OutOfMemory;
        message_id = idw.written();
    }

    var b = Builder.init(arena);
    const w = b.w();

    // The headers.
    try writeMailboxes(arena, w, "From", &.{from});
    try writeMailboxes(arena, w, "To", p.to_boxes);
    try writeMailboxes(arena, w, "Cc", p.cc_boxes);
    if (p.reply_to) |r| try writeMailboxes(arena, w, "Reply-To", &.{r});
    if (msg.subject.len > 0) {
        var ve = encode.ValueEncoder.init(msg.subject, false);
        if (longestWord(msg.subject) > 70) ve.encoder = .base64;
        var vw: Writer.Allocating = .init(arena);
        ve.write(&vw.writer) catch return error.OutOfMemory;
        try writeHeader(w, "Subject", vw.written());
    }
    {
        var dw: Writer.Allocating = .init(arena);
        date.write(&dw.writer, now) catch return error.OutOfMemory;
        try writeHeader(w, "Date", dw.written());
    }
    try writeHeader(w, "Message-ID", try std.fmt.allocPrint(arena, "<{s}>", .{message_id}));
    try writeHeader(w, "MIME-Version", "1.0");
    for (msg.headers) |h| try writeHeader(w, h[0], h[1]);

    // The body: alternative text and html, inside related (with the
    // inline images) inside mixed (with the attachments), each only when
    // needed. The delimiter of a parent comes right before its child.
    var inline_count: usize = 0;
    var attached_count: usize = 0;
    for (msg.attachments) |a| {
        if (a.content_id != null) inline_count += 1 else attached_count += 1;
    }
    const mixed: ?[36]u8 = if (attached_count > 0) encode.createBoundary(random) else null;
    const related: ?[36]u8 = if (inline_count > 0) encode.createBoundary(random) else null;
    if (mixed) |bd| {
        try writeMultipartHead(w, "mixed", &bd);
        try writeDelimiter(w, &bd, false);
    }
    if (related) |bd| {
        try writeMultipartHead(w, "related", &bd);
        try writeDelimiter(w, &bd, false);
    }
    try writeBody(w, msg, random);
    if (related) |bd| {
        for (msg.attachments) |a| if (a.content_id != null) {
            try writeDelimiter(b.w(), &bd, false);
            try writeAttachment(arena, io, &b, a, fail);
        };
        try writeDelimiter(b.w(), &bd, true);
    }
    if (mixed) |bd| {
        for (msg.attachments) |a| if (a.content_id == null) {
            try writeDelimiter(b.w(), &bd, false);
            try writeAttachment(arena, io, &b, a, fail);
        };
        try writeDelimiter(b.w(), &bd, true);
    }
    try b.flush();

    if (b.size > defaults.max_bytes)
        return invalid(fail, "message_too_large", try std.fmt.allocPrint(arena, "the message is {d} bytes; the limit is {d} (Options.max_message_bytes)", .{ b.size, defaults.max_bytes }));

    return .{
        .parts = b.parts.items,
        .size = b.size,
        .envelope_from = envelope_from,
        .recipients = recipients,
        .message_id = message_id,
        .utf8 = utf8,
    };
}

fn invalid(fail: *Failure, code: []const u8, message: []const u8) error{Invalid} {
    fail.* = .{ .class = .invalid, .code = code, .message = message };
    return error.Invalid;
}

fn mailbox(arena: Allocator, fail: *Failure, field: []const u8, text: []const u8) Error!address.Mailbox {
    return address.parse(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAddress => {
            const shown = text[0..@min(text.len, 80)];
            fail.* = .{
                .class = .invalid,
                .code = "invalid_address",
                .message = try std.fmt.allocPrint(arena, "{s}: \"{f}\" is not a mailbox (Name <local@domain> or local@domain)", .{ field, std.zig.fmtString(shown) }),
            };
            return error.Invalid;
        },
    };
}

fn hasControl(text: []const u8) bool {
    for (text) |b| if (b < 0x20 and b != '\t' or b == 0x7f) return true;
    return false;
}

fn checkText(fail: *Failure, text: []const u8) error{Invalid}!void {
    if (hasControl(text)) return invalid(fail, "invalid_header", "the subject holds CR, LF or another control character");
}

const forbidden_headers = [_][]const u8{ "date", "from", "to", "cc", "bcc", "reply-to", "subject", "message-id", "mime-version" };

fn checkExtraHeader(fail: *Failure, h: Header) error{Invalid}!void {
    const name = h[0];
    if (name.len == 0 or name.len > 70) return invalid(fail, "invalid_header", "a header name is empty or longer than 70 bytes");
    for (name) |c| if (c <= 0x20 or c >= 0x7f or c == ':') return invalid(fail, "invalid_header", "a header name holds a space, a colon or a control character");
    for (forbidden_headers) |f| if (std.ascii.eqlIgnoreCase(name, f))
        return invalid(fail, "invalid_header", "this header is set from the Message fields; it cannot be given in headers");
    if (name.len >= 8 and std.ascii.eqlIgnoreCase(name[0..8], "content-"))
        return invalid(fail, "invalid_header", "Content-* headers are set by Anole; they cannot be given in headers");
    if (hasControl(h[1])) return invalid(fail, "invalid_header", "a header value holds CR, LF or another control character");
    if (h[1].len > 900) return invalid(fail, "invalid_header", "a header value is longer than 900 bytes");
}

fn checkMessageId(fail: *Failure, id: []const u8) error{Invalid}!void {
    const inner = std.mem.trim(u8, id, "<>");
    if (inner.len == 0 or inner.len > 200) return invalid(fail, "invalid_header", "message_id is empty or longer than 200 bytes");
    for (inner) |c| if (c <= 0x20 or c >= 0x7f or c == '<' or c == '>') return invalid(fail, "invalid_header", "message_id holds a space, an angle bracket or a control character");
    if (std.mem.indexOfScalar(u8, inner, '@') == null) return invalid(fail, "invalid_header", "message_id needs an '@' (left@domain)");
}

fn checkAttachment(fail: *Failure, a: Attachment) error{Invalid}!void {
    if (a.filename.len == 0 or a.filename.len > 255 or hasControl(a.filename))
        return invalid(fail, "invalid_header", "an attachment's filename is empty, longer than 255 bytes or holds a control character");
    if (a.content_type) |t| {
        const slash = std.mem.indexOfScalar(u8, t, '/') orelse return invalid(fail, "invalid_header", "an attachment's content_type is not type/subtype");
        if (slash == 0 or slash + 1 == t.len or t.len > 100) return invalid(fail, "invalid_header", "an attachment's content_type is not type/subtype");
        for (t) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '+', '-', '_' => {},
            else => return invalid(fail, "invalid_header", "an attachment's content_type holds a character a media type cannot"),
        };
    }
    if (a.content_id) |id| {
        if (id.len == 0 or id.len > 200) return invalid(fail, "invalid_header", "an attachment's content_id is empty or longer than 200 bytes");
        for (id) |c| if (c <= 0x20 or c >= 0x7f or c == '<' or c == '>') return invalid(fail, "invalid_header", "an attachment's content_id holds a space, an angle bracket or a control character");
    }
}

fn longestWord(text: []const u8) usize {
    var longest: usize = 0;
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| longest = @max(longest, word.len);
    return longest;
}

/// `Name: value`, folded at spaces so no line is over 78 bytes (a word
/// longer than that stays whole), ended with CRLF.
pub fn writeHeader(w: *Writer, name: []const u8, value: []const u8) Error!void {
    var col: usize = name.len + 1;
    w.writeAll(name) catch return error.OutOfMemory;
    w.writeByte(':') catch return error.OutOfMemory;
    var it = std.mem.tokenizeScalar(u8, value, ' ');
    var first = true;
    while (it.next()) |word| {
        if (!first and col + 1 + word.len > 78) {
            w.writeAll("\r\n ") catch return error.OutOfMemory;
            col = 1;
        } else {
            w.writeByte(' ') catch return error.OutOfMemory;
            col += 1;
        }
        first = false;
        w.writeAll(word) catch return error.OutOfMemory;
        col += word.len;
    }
    w.writeAll("\r\n") catch return error.OutOfMemory;
}

fn writeMailboxes(arena: Allocator, w: *Writer, name: []const u8, boxes: []const address.Mailbox) Error!void {
    if (boxes.len == 0) return;
    var vw: Writer.Allocating = .init(arena);
    for (boxes, 0..) |m, i| {
        if (i > 0) vw.writer.writeAll(", ") catch return error.OutOfMemory;
        if (m.name) |n| {
            encode.ValueEncoder.init(n, true).write(&vw.writer) catch return error.OutOfMemory;
            vw.writer.print(" <{s}>", .{m.address}) catch return error.OutOfMemory;
        } else {
            vw.writer.writeAll(m.address) catch return error.OutOfMemory;
        }
    }
    try writeHeader(w, name, vw.written());
}

fn writeMultipartHead(w: *Writer, subtype: []const u8, boundary: *const [36]u8) Error!void {
    w.print("Content-Type: multipart/{s};\r\n boundary=\"{s}\"\r\n\r\n", .{ subtype, boundary[2..] }) catch return error.OutOfMemory;
}

/// `boundary` is `--` and the parameter, which is the delimiter line.
fn writeDelimiter(w: *Writer, boundary: *const [36]u8, close: bool) Error!void {
    w.print("{s}{s}\r\n", .{ @as([]const u8, boundary), if (close) "--" else "" }) catch return error.OutOfMemory;
}

/// The text and HTML parts: alternative when both.
fn writeBody(w: *Writer, msg: Message, random: std.Random) Error!void {
    if (msg.text != null and msg.html != null) {
        const bd = encode.createBoundary(random);
        try writeMultipartHead(w, "alternative", &bd);
        try writeDelimiter(w, &bd, false);
        try writeTextPart(w, "text/plain", msg.text.?);
        try writeDelimiter(w, &bd, false);
        try writeTextPart(w, "text/html", msg.html.?);
        try writeDelimiter(w, &bd, true);
    } else if (msg.html) |h| {
        try writeTextPart(w, "text/html", h);
    } else {
        try writeTextPart(w, "text/plain", msg.text orelse "");
    }
}

fn writeTextPart(w: *Writer, content_type: []const u8, text: []const u8) Error!void {
    if (encode.is7bit(text)) {
        w.print("Content-Type: {s}; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n", .{content_type}) catch return error.OutOfMemory;
        encode.write7bit(w, text) catch return error.OutOfMemory;
    } else {
        w.print("Content-Type: {s}; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n", .{content_type}) catch return error.OutOfMemory;
        encode.writeQuotedPrintable(w, text) catch return error.OutOfMemory;
    }
}

fn writeAttachment(arena: Allocator, io: std.Io, b: *Builder, a: Attachment, fail: *Failure) Error!void {
    const w = b.w();
    const ctype = a.content_type orelse typeFor(a.filename);
    w.print("Content-Type: {s}\r\n", .{ctype}) catch return error.OutOfMemory;
    var ascii = true;
    for (a.filename) |c| if (c > 127) {
        ascii = false;
    };
    // The name twice: Content-Type's name (the old way) and
    // Content-Disposition's filename (RFC 6266).
    w.writeAll("Content-Transfer-Encoding: base64\r\n") catch return error.OutOfMemory;
    w.print("Content-Disposition: {s};\r\n", .{if (a.content_id != null) "inline" else "attachment"}) catch return error.OutOfMemory;
    if (ascii) {
        w.writeAll(" filename=\"") catch return error.OutOfMemory;
        for (a.filename) |c| {
            if (c == '"' or c == '\\') w.writeByte('\\') catch return error.OutOfMemory;
            w.writeByte(c) catch return error.OutOfMemory;
        }
        w.writeAll("\"\r\n") catch return error.OutOfMemory;
    } else {
        w.writeAll(" filename*=") catch return error.OutOfMemory;
        encode.writeExtValue(w, a.filename) catch return error.OutOfMemory;
        w.writeAll("\r\n") catch return error.OutOfMemory;
    }
    if (a.content_id) |id| w.print("Content-ID: <{s}>\r\n", .{id}) catch return error.OutOfMemory;
    w.writeAll("\r\n") catch return error.OutOfMemory;
    switch (a.content) {
        .bytes => |data| {
            var col: usize = 0;
            encode.writeBase64(w, &col, data) catch return error.OutOfMemory;
            encode.finishBase64(w, &col) catch return error.OutOfMemory;
        },
        .file => |path| {
            const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
                fail.* = .{
                    .class = .other,
                    .code = "attachment_unreadable",
                    .message = try std.fmt.allocPrint(arena, "attachment \"{f}\": {t}", .{ std.zig.fmtString(a.filename), err }),
                };
                return error.Invalid;
            };
            if (st.kind != .file) {
                fail.* = .{ .class = .other, .code = "attachment_unreadable", .message = try std.fmt.allocPrint(arena, "attachment \"{f}\": {s} is not a file", .{ std.zig.fmtString(a.filename), path }) };
                return error.Invalid;
            }
            try b.addFile(try arena.dupe(u8, path), st.size);
        },
    }
}

/// A media type from the file name's extension.
pub fn typeFor(filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return "application/octet-stream";
    const ext = filename[dot + 1 ..];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "txt", "text/plain" },
        .{ "csv", "text/csv" },
        .{ "html", "text/html" },
        .{ "htm", "text/html" },
        .{ "css", "text/css" },
        .{ "ics", "text/calendar" },
        .{ "json", "application/json" },
        .{ "xml", "application/xml" },
        .{ "pdf", "application/pdf" },
        .{ "zip", "application/zip" },
        .{ "gz", "application/gzip" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },
        .{ "svg", "image/svg+xml" },
        .{ "mp3", "audio/mpeg" },
        .{ "wav", "audio/wav" },
        .{ "mp4", "video/mp4" },
        .{ "doc", "application/msword" },
        .{ "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
        .{ "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}

/// Dot stuffing (RFC 5321 section 4.5.2) for the DATA command, and with
/// `normalize` line ends made CRLF for a message composed elsewhere.
pub const Stuffer = struct {
    bol: bool = true,
    prev_cr: bool = false,
    normalize: bool = false,

    pub fn write(self: *Stuffer, w: *Writer, bytes: []const u8) Writer.Error!void {
        var start: usize = 0;
        for (bytes, 0..) |b, i| {
            if (self.normalize and b == '\n' and !self.prev_cr) {
                try w.writeAll(bytes[start..i]);
                try w.writeByte('\r');
                start = i;
            }
            if (self.bol and b == '.') {
                try w.writeAll(bytes[start..i]);
                try w.writeByte('.');
                start = i;
            }
            self.bol = b == '\n';
            self.prev_cr = b == '\r';
        }
        try w.writeAll(bytes[start..]);
    }

    /// Ends the message: a last line end if the text lacked one, then ".".
    pub fn finish(self: *Stuffer, w: *Writer) Writer.Error!void {
        if (!self.bol) try w.writeAll("\r\n");
        try w.writeAll(".\r\n");
    }
};

pub const WriteError = Writer.Error || error{AttachmentUnreadable};

/// Writes the message into `w`, dot-stuffed through `stuffer`, but not
/// the closing ".": the caller ends it with `stuffer.finish`. A file
/// attachment is read and encoded as it goes; it fails with
/// `error.AttachmentUnreadable` when a file cannot be read whole.
pub fn writeMessage(c: *const Composed, io: std.Io, w: *Writer, stuffer: *Stuffer) WriteError!void {
    for (c.parts) |part| switch (part) {
        .bytes => |bytes| try stuffer.write(w, bytes),
        .file => |f| {
            // Base64 never starts a line with '.', so no stuffing.
            const file = std.Io.Dir.cwd().openFile(io, f.path, .{}) catch return error.AttachmentUnreadable;
            defer file.close(io);
            var rbuf: [3 * 4096]u8 = undefined;
            var fr = file.reader(io, &rbuf);
            var col: usize = 0;
            var left = f.size;
            var chunk: [3 * 4096]u8 = undefined;
            while (left > 0) {
                const want: usize = @intCast(@min(left, chunk.len));
                const got = fr.interface.readSliceShort(chunk[0..want]) catch return error.AttachmentUnreadable;
                // The file shrank since it was composed.
                if (got < want) return error.AttachmentUnreadable;
                // The chunk is a multiple of 3 until the last.
                try encode.writeBase64(w, &col, chunk[0..got]);
                left -= got;
            }
            try encode.finishBase64(w, &col);
            stuffer.bol = true;
            stuffer.prev_cr = false;
        },
    };
}

/// The whole DATA payload: `writeMessage` and the closing ".".
pub fn writeData(c: *const Composed, io: std.Io, w: *Writer) WriteError!void {
    var stuffer: Stuffer = .{};
    try writeMessage(c, io, w, &stuffer);
    try stuffer.finish(w);
}

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

fn composeTest(arena: Allocator, msg: Message, defaults: Defaults) !Composed {
    var prng = std.Random.DefaultPrng.init(42);
    var fail: Failure = .{};
    return compose(arena, testing.io, msg, defaults, prng.random(), 1736737238, &fail);
}

fn rendered(arena: Allocator, c: Composed) ![]u8 {
    var aw: Writer.Allocating = .init(arena);
    for (c.parts) |p| switch (p) {
        .bytes => |bytes| try aw.writer.writeAll(bytes),
        .file => unreachable,
    };
    return aw.written();
}

test "compose: text only is 7bit with the headers in order and Bcc left out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try composeTest(arena, .{
        .from = "Ada <ada@example.com>",
        .to = &.{ "bob@example.com", "Carol <carol@example.org>" },
        .bcc = &.{"secret@example.net"},
        .subject = "Hello",
        .text = "Hi there\n.dot first\n",
    }, .{});
    const out = try rendered(arena, c);
    try testing.expect(std.mem.startsWith(u8, out, "From: Ada <ada@example.com>\r\nTo: bob@example.com, Carol <carol@example.org>\r\nSubject: Hello\r\nDate: Mon, 13 Jan 2025 03:00:38 +0000\r\nMessage-ID: <"));
    try testing.expect(std.mem.indexOf(u8, out, "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\nHi there\r\n.dot first\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "secret") == null);
    try testing.expectEqual(@as(usize, 3), c.recipients.len);
    try testing.expectEqualStrings("secret@example.net", c.recipients[2]);
    try testing.expectEqualStrings("ada@example.com", c.envelope_from);
    try testing.expectEqual(@as(u64, out.len), c.size);
    try testing.expect(std.mem.endsWith(u8, c.message_id, "@example.com"));
}

test "compose: non-ASCII text is quoted-printable, the subject RFC 2047" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try composeTest(arena, .{
        .from = "ada@example.com",
        .to = &.{"bob@example.com"},
        .subject = "Café ✔",
        .text = "Voilà",
    }, .{});
    const out = try rendered(arena, c);
    try testing.expect(std.mem.indexOf(u8, out, "Subject: =?UTF-8?B?") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Transfer-Encoding: quoted-printable\r\n\r\nVoil=C3=A0\r\n") != null);
}

test "compose: text and html are alternative; attachments make mixed; inline makes related" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try composeTest(arena, .{
        .from = "ada@example.com",
        .to = &.{"bob@example.com"},
        .subject = "Mixed",
        .text = "plain",
        .html = "<b>rich</b><img src=\"cid:logo\">",
        .attachments = &.{
            .{ .filename = "logo.png", .content = .{ .bytes = "PNGDATA" }, .content_id = "logo" },
            .{ .filename = "report.pdf", .content = .{ .bytes = "%PDF-1.4" } },
            .{ .filename = "résumé.txt", .content = .{ .bytes = "hi" } },
        },
    }, .{});
    const out = try rendered(arena, c);
    const mixed_at = std.mem.indexOf(u8, out, "Content-Type: multipart/mixed;").?;
    const related_at = std.mem.indexOf(u8, out, "Content-Type: multipart/related;").?;
    const alt_at = std.mem.indexOf(u8, out, "Content-Type: multipart/alternative;").?;
    try testing.expect(mixed_at < related_at and related_at < alt_at);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Disposition: inline;\r\n filename=\"logo.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Content-ID: <logo>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Type: image/png\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Content-Disposition: attachment;\r\n filename=\"report.pdf\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "filename*=UTF-8''r%C3%A9sum%C3%A9.txt") != null);
    // PNGDATA in base64.
    try testing.expect(std.mem.indexOf(u8, out, "UE5HREFUQQ==\r\n") != null);
    // Each boundary closes.
    var closes: usize = 0;
    var it = std.mem.splitSequence(u8, out, "\r\n");
    while (it.next()) |line| {
        try testing.expect(line.len <= 998);
        if (std.mem.startsWith(u8, line, "----") and std.mem.endsWith(u8, line, "--")) closes += 1;
    }
    try testing.expectEqual(@as(usize, 3), closes);
}

test "compose: the computed size equals the bytes, over generated messages" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..200) |_| {
        const arena = arena_state.allocator();
        const text = try arena.alloc(u8, rnd.uintLessThan(usize, 400));
        for (text) |*ch| ch.* = switch (rnd.uintLessThan(u8, 6)) {
            0 => '\n',
            1 => ' ',
            2 => 0xC3,
            3 => '.',
            else => 'a' + rnd.uintLessThan(u8, 26),
        };
        const att = try arena.alloc(u8, rnd.uintLessThan(usize, 300));
        rnd.bytes(att);
        const c = try composeTest(arena, .{
            .from = "ada@example.com",
            .to = &.{"bob@example.com"},
            .subject = "s",
            .text = if (rnd.boolean()) text else null,
            .html = if (rnd.boolean()) text else null,
            .attachments = if (rnd.boolean()) &.{.{ .filename = "a.bin", .content = .{ .bytes = att } }} else &.{},
        }, .{});
        const out = try rendered(arena, c);
        try testing.expectEqual(@as(u64, out.len), c.size);
    }
}

test "compose: injection through any field is invalid_header or invalid_address" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(1);
    const base: Message = .{ .from = "ada@example.com", .to = &.{"bob@example.com"} };
    const bad = [_]Message{
        .{ .from = "ada@example.com\r\nBcc: x@example.com", .to = base.to },
        .{ .from = base.from, .to = &.{"bob@example.com\r\nRCPT TO:<x@example.com>"} },
        .{ .from = base.from, .to = base.to, .subject = "hi\r\nBcc: x@example.com" },
        .{ .from = base.from, .to = base.to, .headers = &.{.{ "X-A", "v\r\nBcc: x@example.com" }} },
        .{ .from = base.from, .to = base.to, .headers = &.{.{ "X-A\r\nBcc", "v" }} },
        .{ .from = base.from, .to = base.to, .headers = &.{.{ "Bcc", "x@example.com" }} },
        .{ .from = base.from, .to = base.to, .headers = &.{.{ "Content-Type", "text/html" }} },
        .{ .from = base.from, .to = base.to, .attachments = &.{.{ .filename = "a\r\nb", .content = .{ .bytes = "" } }} },
        .{ .from = base.from, .to = base.to, .attachments = &.{.{ .filename = "a.txt", .content_type = "text/plain\r\nX: y", .content = .{ .bytes = "" } }} },
        .{ .from = base.from, .to = base.to, .attachments = &.{.{ .filename = "a.txt", .content = .{ .bytes = "" }, .content_id = "a b" }} },
        .{ .from = base.from, .to = base.to, .message_id = "a\r\nb@c" },
        .{ .from = base.from, .to = &.{} },
    };
    for (bad) |m| {
        var fail: Failure = .{};
        try testing.expectError(error.Invalid, compose(arena, testing.io, m, .{}, prng.random(), 0, &fail));
        try testing.expect(std.mem.eql(u8, fail.code, "invalid_header") or std.mem.eql(u8, fail.code, "invalid_address"));
    }
}

test "compose: a message over the limit fails before anything is sent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(1);
    var fail: Failure = .{};
    try testing.expectError(error.Invalid, compose(arena, testing.io, .{
        .from = "ada@example.com",
        .to = &.{"bob@example.com"},
        .text = repeat("x", 5000),
    }, .{ .max_bytes = 1000 }, prng.random(), 0, &fail));
    try testing.expectEqualStrings("message_too_large", fail.code);
}

test "compose: a long subject without spaces is folded as encoded words; no line passes 998" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try composeTest(arena, .{ .from = "ada@example.com", .to = &.{"bob@example.com"}, .subject = repeat("x", 1500), .text = repeat("a", 5000) }, .{});
    const out = try rendered(arena, c);
    var it = std.mem.splitSequence(u8, out, "\r\n");
    while (it.next()) |line| try testing.expect(line.len <= 998);
}

test "writeHeader folds at spaces to 78 columns" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeHeader(&aw.writer, "Subject", "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen");
    var it = std.mem.splitSequence(u8, aw.written(), "\r\n");
    var lines: usize = 0;
    while (it.next()) |line| {
        try testing.expect(line.len <= 78);
        lines += 1;
    }
    try testing.expect(lines >= 3);
}

test "Stuffer: dots at line starts are doubled, LF becomes CRLF when normalizing, the end is added" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var s: Stuffer = .{ .normalize = true };
    try s.write(&aw.writer, "one\n.two\r\n..three\n");
    try s.write(&aw.writer, ".four");
    try s.finish(&aw.writer);
    try testing.expectEqualStrings("one\r\n..two\r\n...three\r\n..four\r\n.\r\n", aw.written());
}

test "writeData: stuffs the parts and streams a file attachment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Larger than the 12 KiB read chunk and the 16 KiB writer buffer.
    const data = try arena.alloc(u8, 50_000);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.bin", .data = data });
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/big.bin", .{tmp.sub_path});
    const c = try composeTest(arena, .{
        .from = "ada@example.com",
        .to = &.{"bob@example.com"},
        .text = ".starts with a dot",
        .attachments = &.{.{ .filename = "big.bin", .content = .{ .file = path } }},
    }, .{});
    var files: usize = 0;
    for (c.parts) |p| if (p == .file) {
        files += 1;
    };
    try testing.expectEqual(@as(usize, 1), files);
    var aw: Writer.Allocating = .init(arena);
    try writeData(&c, testing.io, &aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.endsWith(u8, out, "\r\n.\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\r\n..starts with a dot\r\n") != null);
    // The stuffed length is the size plus the doubled dots plus the end.
    try testing.expectEqual(c.size + 1 + 3, out.len);
    // The base64 decodes to the file.
    const marker = "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment;\r\n filename=\"big.bin\"\r\n\r\n";
    const start = std.mem.indexOf(u8, out, marker).? + marker.len;
    const end = std.mem.lastIndexOf(u8, out, "\r\n------").?;
    var decoded: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitSequence(u8, out[start..end], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const size = try std.base64.standard.Decoder.calcSizeForSlice(line);
        const buf = try arena.alloc(u8, size);
        try std.base64.standard.Decoder.decode(buf, line);
        try decoded.appendSlice(arena, buf);
    }
    try testing.expectEqualSlices(u8, data, decoded.items);
}

test "compose: a missing attachment file is attachment_unreadable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(1);
    var fail: Failure = .{};
    try testing.expectError(error.Invalid, compose(arena, testing.io, .{
        .from = "ada@example.com",
        .to = &.{"bob@example.com"},
        .attachments = &.{.{ .filename = "x.txt", .content = .{ .file = "/definitely/not/here.txt" } }},
    }, .{}, prng.random(), 0, &fail));
    try testing.expectEqualStrings("attachment_unreadable", fail.code);
    try testing.expect(fail.class == .other);
}
