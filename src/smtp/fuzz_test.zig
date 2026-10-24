//! Fuzz targets for what the SMTP client parses or builds from bytes it
//! does not control: the server's replies and EHLO lines, and the
//! mailboxes a caller passes (`src/fuzz.zig`).
const std = @import("std");
const fuzz = @import("../fuzz.zig");
const reply_mod = @import("core/reply.zig");
const session = @import("session.zig");
const address = @import("address.zig");
const mime = @import("mime.zig");

/// Replies: any bytes read as replies never crash or leak, and what comes
/// back respects the bounds.
fn checkReplies(input: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed(input);
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const rep = reply_mod.read(&r, arena.allocator()) catch return;
        if (rep.code < 200 or rep.code > 599) return error.CodeOutOfRange;
        if (rep.lines.len == 0 or rep.lines.len > reply_mod.max_lines) return error.TooManyLines;
        for (rep.lines) |line| if (line.len > reply_mod.max_line_bytes) return error.LineTooLong;
        _ = rep.enhanced();
        // The extensions of whatever it said.
        const caps = session.parseCapabilities(rep);
        _ = caps;
    }
}

/// EHLO lines: any text as the lines of an EHLO reply.
fn checkEhlo(input: []const u8) anyerror!void {
    var lines: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (n == lines.len) break;
        lines[n] = std.mem.trimEnd(u8, line, "\r");
        n += 1;
    }
    const caps = session.parseCapabilities(.{ .code = 250, .lines = lines[0..n] });
    // An announced SIZE is a flag and a number, whatever the text.
    if (!caps.size_ext and caps.size != 0) return error.SizeWithoutExtension;
}

/// Mailboxes: whatever parses is safe to put into a header and a command.
fn checkMailbox(input: []const u8) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = address.parse(arena.allocator(), input) catch return;
    if (m.address.len > address.max_address or m.address.len < 3) return error.BadLength;
    for (m.address) |b| {
        if (b < 0x20 or b == 0x7f) return error.ControlInAddress;
        if (b == '>' or b == ',') {
            // Only inside a quoted local part.
            if (m.address[0] != '"') return error.SpecialInAddress;
        }
    }
    if (m.name) |n| for (n) |b| if (b < 0x20 and b != '\t' or b == 0x7f) return error.ControlInName;
    // Composed into a message, nothing breaks out of its header line.
    var fail: mime.Failure = .{};
    var prng = std.Random.DefaultPrng.init(0);
    const c = mime.compose(arena.allocator(), std.testing.io, .{
        .from = input,
        .to = &.{input},
        .subject = "s",
        .text = "t",
    }, .{}, prng.random(), 0, &fail) catch return;
    const head = c.parts[0].bytes;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    var in_headers = true;
    while (lines.next()) |line| {
        if (line.len == 0) {
            in_headers = false;
            continue;
        }
        if (!in_headers) break;
        if (line.len > 998) return error.LineTooLong;
        // Every header line is a field or a fold.
        const folded = line[0] == ' ' or line[0] == '\t';
        if (!folded and std.mem.indexOfScalar(u8, line, ':') == null) return error.NotAHeader;
    }
}

test "fuzz: smtp replies" {
    try fuzz.bytes(checkReplies, &.{
        "220 mail.example.com ESMTP\r\n",
        "250-mail.example.com\r\n250-PIPELINING\r\n250-SIZE 35882577\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n",
        "354 End data with <CR><LF>.<CR><LF>\r\n",
        "550 5.1.1 <nobody@example.com>: Recipient address rejected\r\n",
        "250-a\r\n251 b\r\n",
        "99",
        "",
    });
}

test "fuzz: smtp ehlo lines" {
    try fuzz.bytes(checkEhlo, &.{
        "fake.example\nPIPELINING\nSIZE 1000\nAUTH PLAIN LOGIN\nSTARTTLS\nSMTPUTF8",
        "x\nSIZE 99999999999999999999999\nAUTH=PLAIN\nauth login",
        "x\nAUTH\nSIZE\n\n  \nENHANCEDSTATUSCODES",
    });
}

test "fuzz: smtp mailbox" {
    try fuzz.bytes(checkMailbox, &.{
        "ada@example.com",
        "Ada Lovelace <ada@example.com>",
        "\"Lovelace, Ada\" <ada@example.com>",
        "<\"quoted local\"@example.com>",
        "ada@example.com\r\nBcc: evil@example.com",
        "Zoë <zoe@exämple.com>",
        "a@b@c",
        "\"unclosed",
    });
}
