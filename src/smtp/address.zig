//! Mailboxes (RFC 5322): `ada@example.com`, `<ada@example.com>`,
//! `Ada Lovelace <ada@example.com>` and `"Lovelace, Ada" <ada@example.com>`,
//! checked so that nothing in them can break out of a header or an SMTP
//! command.
const std = @import("std");

pub const Mailbox = struct {
    /// The display name, unquoted; null when there is none.
    name: ?[]const u8,
    /// `local@domain`, as it goes into `MAIL FROM` and `RCPT TO`.
    address: []const u8,

    /// Whether the address needs SMTPUTF8 (RFC 6531): a non-ASCII byte.
    pub fn needsUtf8(self: Mailbox) bool {
        for (self.address) |b| if (b > 127) return true;
        return false;
    }

    /// The domain of the address.
    pub fn domain(self: Mailbox) []const u8 {
        const at = std.mem.lastIndexOfScalar(u8, self.address, '@') orelse return "";
        return self.address[at + 1 ..];
    }
};

pub const Error = error{InvalidAddress} || std.mem.Allocator.Error;

/// The longest address RFC 5321 allows (a path is 256 with the brackets).
pub const max_address = 254;
const max_local = 64;

/// Parses one mailbox. The result points into `text` or `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Mailbox {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or t.len > 998) return error.InvalidAddress;
    for (t) |b| if (b < 0x20 and b != '\t' or b == 0x7f) return error.InvalidAddress;

    if (t[t.len - 1] == '>') {
        // The last '<' outside quotes opens the address.
        var in_quote = false;
        var escaped = false;
        var open: ?usize = null;
        for (t, 0..) |b, i| {
            if (escaped) {
                escaped = false;
                continue;
            }
            switch (b) {
                '\\' => if (in_quote) {
                    escaped = true;
                },
                '"' => in_quote = !in_quote,
                '<' => if (!in_quote) {
                    open = i;
                },
                else => {},
            }
        }
        if (in_quote) return error.InvalidAddress;
        const lt = open orelse return error.InvalidAddress;
        const address = t[lt + 1 .. t.len - 1];
        try checkAddress(address);
        const phrase = std.mem.trim(u8, t[0..lt], " \t");
        return .{ .name = try unquote(arena, phrase), .address = address };
    }
    try checkAddress(t);
    return .{ .name = null, .address = t };
}

fn unquote(arena: std.mem.Allocator, phrase: []const u8) Error!?[]const u8 {
    if (phrase.len == 0) return null;
    if (phrase[0] == '"') {
        if (phrase.len < 2 or phrase[phrase.len - 1] != '"') return error.InvalidAddress;
        const inner = phrase[1 .. phrase.len - 1];
        var out = try arena.alloc(u8, inner.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\') {
                i += 1;
                if (i >= inner.len) return error.InvalidAddress;
            } else if (inner[i] == '"') return error.InvalidAddress;
            out[n] = inner[i];
            n += 1;
        }
        return out[0..n];
    }
    // An unquoted phrase: words, no specials that would change the meaning.
    for (phrase) |b| switch (b) {
        '<', '>', '"', '@', ';', ':', '(', ')', '[', ']', '\\' => return error.InvalidAddress,
        else => {},
    };
    return phrase;
}

/// `local@domain` with the checks SMTP needs: one '@', a local part of at
/// most 64 bytes (quoted or dot-atom), a domain of labels or an address
/// literal, no spaces, no control characters.
pub fn checkAddress(address: []const u8) error{InvalidAddress}!void {
    if (address.len < 3 or address.len > max_address) return error.InvalidAddress;
    for (address) |b| if (b < 0x20 or b == 0x7f) return error.InvalidAddress;
    var in_quote = false;
    var escaped = false;
    var at: ?usize = null;
    for (address, 0..) |b, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (b) {
            '\\' => if (in_quote) {
                escaped = true;
            } else return error.InvalidAddress,
            '"' => in_quote = !in_quote,
            '@' => if (!in_quote) {
                if (at != null) return error.InvalidAddress;
                at = i;
            },
            ' ', '\t' => if (!in_quote) return error.InvalidAddress,
            '<', '>', ',', ';', ':', '(', ')' => if (!in_quote) return error.InvalidAddress,
            else => {},
        }
    }
    if (in_quote or escaped) return error.InvalidAddress;
    const split = at orelse return error.InvalidAddress;
    const local = address[0..split];
    const domain = address[split + 1 ..];
    try checkLocal(local);
    try checkDomain(domain);
}

/// RFC 5321's Local-part: a Dot-string (atoms joined by dots, no quote) or
/// one Quoted-string that is the whole part, never a mix (a quote inside a
/// dot-string would hide '>' and spaces from a server that reads it as a
/// dot-string).
fn checkLocal(local: []const u8) error{InvalidAddress}!void {
    if (local.len == 0 or local.len > max_local) return error.InvalidAddress;
    if (local[0] == '"') {
        if (local.len < 3 or local[local.len - 1] != '"') return error.InvalidAddress;
        const inner = local[1 .. local.len - 1];
        var i: usize = 0;
        while (i < inner.len) : (i += 1) switch (inner[i]) {
            '"' => return error.InvalidAddress,
            '\\' => {
                i += 1;
                if (i >= inner.len) return error.InvalidAddress;
            },
            else => {},
        };
        return;
    }
    if (local[0] == '.' or local[local.len - 1] == '.') return error.InvalidAddress;
    var prev_dot = false;
    for (local) |b| {
        if (b == '.') {
            if (prev_dot) return error.InvalidAddress;
            prev_dot = true;
        } else prev_dot = false;
        switch (b) {
            '"', '\\', '[', ']' => return error.InvalidAddress,
            else => {},
        }
    }
}

fn checkDomain(domain: []const u8) error{InvalidAddress}!void {
    if (domain.len == 0 or domain.len > 253) return error.InvalidAddress;
    if (domain[0] == '[') {
        if (domain[domain.len - 1] != ']' or domain.len < 3) return error.InvalidAddress;
        for (domain[1 .. domain.len - 1]) |b| switch (b) {
            '0'...'9', 'a'...'f', 'A'...'F', '.', ':', 'I', 'P', 'v' => {},
            else => return error.InvalidAddress,
        };
        return;
    }
    var label_len: usize = 0;
    var prev: u8 = '.';
    for (domain) |b| {
        if (b == '.') {
            if (label_len == 0 or prev == '-') return error.InvalidAddress;
            label_len = 0;
        } else {
            switch (b) {
                'a'...'z', 'A'...'Z', '0'...'9', 128...255 => {},
                '-' => if (label_len == 0) return error.InvalidAddress,
                else => return error.InvalidAddress,
            }
            label_len += 1;
            if (label_len > 63 and b < 128) return error.InvalidAddress;
        }
        prev = b;
    }
    if (label_len == 0 or prev == '-') return error.InvalidAddress;
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

fn expectMailbox(text: []const u8, name: ?[]const u8, address: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), text);
    if (name) |n| try testing.expectEqualStrings(n, m.name.?) else try testing.expect(m.name == null);
    try testing.expectEqualStrings(address, m.address);
}

fn expectInvalid(text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidAddress, parse(arena.allocator(), text));
}

test "address: the forms of a mailbox" {
    try expectMailbox("ada@example.com", null, "ada@example.com");
    try expectMailbox("  <ada@example.com> ", null, "ada@example.com");
    try expectMailbox("Ada Lovelace <ada@example.com>", "Ada Lovelace", "ada@example.com");
    try expectMailbox("\"Lovelace, Ada\" <ada@example.com>", "Lovelace, Ada", "ada@example.com");
    try expectMailbox("\"Ada \\\"the first\\\"\" <ada@example.com>", "Ada \"the first\"", "ada@example.com");
    try expectMailbox("<\"quoted local\"@example.com>", null, "\"quoted local\"@example.com");
    try expectMailbox("Zoë <zoe@exämple.com>", "Zoë", "zoe@exämple.com");
    try expectMailbox("a.b+tag@mail.example.co.uk", null, "a.b+tag@mail.example.co.uk");
    try expectMailbox("ada@[192.168.0.1]", null, "ada@[192.168.0.1]");
}

test "address: header and command injection, and plain mistakes, are refused" {
    try expectInvalid("");
    try expectInvalid("ada");
    try expectInvalid("ada@");
    try expectInvalid("@example.com");
    try expectInvalid("a@b@example.com");
    try expectInvalid("ada@example.com\r\nBcc: evil@example.com");
    try expectInvalid("ada@example.com\nRCPT TO:<evil@example.com>");
    try expectInvalid("ada@exa mple.com");
    try expectInvalid("ada@example.com>");
    try expectInvalid("Ada <ada@example.com");
    try expectInvalid("Ada <ada@example.com> <b@example.com>");
    try expectInvalid("ada@example..com");
    try expectInvalid("ada@-example.com");
    try expectInvalid(".ada@example.com");
    try expectInvalid("a..da@example.com");
    try expectInvalid("ada,bob@example.com");
    try expectInvalid("a\x00da@example.com");
    try expectInvalid("\"unclosed <ada@example.com>");
    try expectInvalid(repeat("a", 65) ++ "@example.com");
    try expectInvalid("ada@" ++ repeat("a", 64) ++ ".com");
}

test "address: a local part is a dot-string or one quoted string, never a mix" {
    // A quote inside a dot-string hid '>' and a space: the path would end
    // early in MAIL FROM/RCPT TO and the rest read as parameters.
    try expectInvalid("ocal\"@example.com>\xd1 local\"@e");
    try expectInvalid("a\"@x.com> BODY=8BITMIME\"@example.com");
    try expectInvalid("a\"b\"@example.com");
    try expectInvalid("\"a\"x\"b\"@example.com");
    try expectInvalid("\"a\".b@example.com");
    try expectInvalid("\"a\\\"@example.com");
    try expectInvalid("\"\"@example.com");
    try expectInvalid("Ada <a\"b c\"@example.com>");
    try expectMailbox("\"a b\"@example.com", null, "\"a b\"@example.com");
    try expectMailbox("\"a\\\"b\"@example.com", null, "\"a\\\"b\"@example.com");
    try expectMailbox("\"a@b>c\"@example.com", null, "\"a@b>c\"@example.com");
}

test "address: SMTPUTF8 is needed for a non-ASCII address only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(!(try parse(arena.allocator(), "Zoë <zoe@example.com>")).needsUtf8());
    try testing.expect((try parse(arena.allocator(), "zoë@example.com")).needsUtf8());
    try testing.expectEqualStrings("example.com", (try parse(arena.allocator(), "zoe@example.com")).domain());
}
