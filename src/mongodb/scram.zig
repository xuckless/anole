//! SCRAM-SHA-1 (RFC 5802) and SCRAM-SHA-256 (RFC 7677) for MongoDB, as
//! auth.md specifies them: no channel binding ("n,,"), usernames never
//! prepared, SCRAM-SHA-1 over MongoDB's hashed password
//! (`hex(md5(user ":mongo:" password))`), SCRAM-SHA-256 over the
//! SASLprep'd password, at least 4096 iterations.
//!
//! A `Conversation` holds one exchange; the PBKDF2 work (thousands of
//! HMACs) is done once per salt and iteration count and kept in a `Cache`
//! the client shares between its connections.
//!
//! SASLprep here maps what RFC 4013 maps (non-ASCII spaces to a space,
//! "commonly mapped to nothing" characters removed) and refuses control
//! characters; a password still holding non-ASCII text after that would
//! need NFKC normalization, which is not built (`error.SaslPrepUnsupported`).
const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.standard;

pub const Mechanism = enum {
    sha1,
    sha256,

    pub fn name(m: Mechanism) []const u8 {
        return switch (m) {
            .sha1 => "SCRAM-SHA-1",
            .sha256 => "SCRAM-SHA-256",
        };
    }

    fn digestLen(m: Mechanism) usize {
        return switch (m) {
            .sha1 => Sha1.digest_length,
            .sha256 => Sha256.digest_length,
        };
    }
};

pub const Error = error{
    OutOfMemory,
    /// The server's message is not what SCRAM sends at that step.
    InvalidServerMessage,
    /// The server's nonce does not extend ours.
    InvalidNonce,
    /// Fewer than 4096 iterations: a downgrade the spec forbids.
    IterationCountTooLow,
    /// The server could not prove it knows the password.
    ServerSignatureMismatch,
    /// The server said why it refused ("e=...").
    AuthenticationFailed,
    /// A control character in the password.
    InvalidPassword,
    /// A password that needs NFKC normalization (see the file comment).
    SaslPrepUnsupported,
};

const max_digest = Sha256.digest_length;

/// ClientKey and ServerKey for one (mechanism, salt, iterations).
pub const Keys = struct {
    client: [max_digest]u8 = undefined,
    server: [max_digest]u8 = undefined,
};

/// The keys derived so far, so a pool's new connections skip PBKDF2
/// (auth.md, "Caching credentials in SCRAM"). One per credential, so the
/// password is implied. Safe from any task (`std.Io.Mutex`).
pub const Cache = struct {
    mutex: std.Io.Mutex = .init,
    entries: [4]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    const Entry = struct {
        mechanism: Mechanism,
        salt: [64]u8,
        salt_len: u8,
        iterations: u32,
        keys: Keys,
    };

    fn get(c: *Cache, io: std.Io, m: Mechanism, salt: []const u8, iterations: u32) ?Keys {
        if (salt.len > 64) return null;
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        for (c.entries[0..c.len]) |e| {
            if (e.mechanism == m and e.iterations == iterations and std.mem.eql(u8, e.salt[0..e.salt_len], salt)) return e.keys;
        }
        return null;
    }

    fn put(c: *Cache, io: std.Io, m: Mechanism, salt: []const u8, iterations: u32, keys: Keys) void {
        if (salt.len > 64) return;
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        var e: Entry = .{ .mechanism = m, .salt = undefined, .salt_len = @intCast(salt.len), .iterations = iterations, .keys = keys };
        @memcpy(e.salt[0..salt.len], salt);
        if (c.len < c.entries.len) {
            c.entries[c.len] = e;
            c.len += 1;
        } else {
            c.entries[c.next] = e;
            c.next = (c.next + 1) % c.entries.len;
        }
    }
};

/// One SCRAM exchange: `clientFirst`, then `clientFinal` with the
/// server's first message, then `verifyServerFinal` with its last.
pub const Conversation = struct {
    mechanism: Mechanism,
    /// What PBKDF2 runs over: SASLprep'd (SHA-256) or MongoDB's hashed
    /// password (SHA-1).
    password: []const u8,
    /// Ours: 24 random bytes in base64.
    nonce: []const u8,
    /// "n=<user>,r=<nonce>", kept for the AuthMessage.
    first_bare: []const u8,
    server_signature: [max_digest]u8 = undefined,

    /// Starts an exchange for `username` (sent as given, '=' and ','
    /// escaped). `random` supplies the nonce's 24 bytes.
    pub fn init(arena: std.mem.Allocator, mechanism: Mechanism, username: []const u8, password: []const u8, random: [24]u8) Error!Conversation {
        var nonce: [32]u8 = undefined;
        _ = base64.Encoder.encode(&nonce, &random);
        return initNonce(arena, mechanism, username, password, &nonce);
    }

    /// `init` with the nonce given as text (the RFCs' examples fix it).
    pub fn initNonce(arena: std.mem.Allocator, mechanism: Mechanism, username: []const u8, password: []const u8, nonce: []const u8) Error!Conversation {
        var bare: std.Io.Writer.Allocating = .init(arena);
        bare.writer.writeAll("n=") catch return error.OutOfMemory;
        for (username) |ch| switch (ch) {
            '=' => bare.writer.writeAll("=3D") catch return error.OutOfMemory,
            ',' => bare.writer.writeAll("=2C") catch return error.OutOfMemory,
            else => bare.writer.writeByte(ch) catch return error.OutOfMemory,
        };
        bare.writer.print(",r={s}", .{nonce}) catch return error.OutOfMemory;
        return .{
            .mechanism = mechanism,
            .password = switch (mechanism) {
                .sha1 => try mongoHashedPassword(arena, username, password),
                .sha256 => try saslPrep(arena, password),
            },
            .nonce = try arena.dupe(u8, nonce),
            .first_bare = bare.written(),
        };
    }

    /// The client-first message: "n,," and `first_bare`.
    pub fn clientFirst(self: *const Conversation, arena: std.mem.Allocator) Error![]const u8 {
        return std.fmt.allocPrint(arena, "n,,{s}", .{self.first_bare});
    }

    /// The client-final message for `server_first` ("r=..,s=..,i=.."),
    /// with the proof; derives the keys, or takes them from `cache`.
    pub fn clientFinal(self: *Conversation, arena: std.mem.Allocator, io: std.Io, cache: ?*Cache, server_first: []const u8) Error![]const u8 {
        var nonce: ?[]const u8 = null;
        var salt_text: ?[]const u8 = null;
        var iterations: ?u32 = null;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') return error.InvalidServerMessage;
            const v = attr[2..];
            switch (attr[0]) {
                'r' => nonce = v,
                's' => salt_text = v,
                'i' => iterations = std.fmt.parseInt(u32, v, 10) catch return error.InvalidServerMessage,
                // A mandatory extension we do not know.
                'm' => return error.InvalidServerMessage,
                else => {},
            }
        }
        const server_nonce = nonce orelse return error.InvalidServerMessage;
        if (!std.mem.startsWith(u8, server_nonce, self.nonce) or server_nonce.len == self.nonce.len) return error.InvalidNonce;
        const rounds = iterations orelse return error.InvalidServerMessage;
        if (rounds < 4096) return error.IterationCountTooLow;
        const salt_b64 = salt_text orelse return error.InvalidServerMessage;
        const salt = try arena.alloc(u8, base64.Decoder.calcSizeForSlice(salt_b64) catch return error.InvalidServerMessage);
        base64.Decoder.decode(salt, salt_b64) catch return error.InvalidServerMessage;

        const keys = if (cache) |c| c.get(io, self.mechanism, salt, rounds) orelse blk: {
            const k = deriveKeys(self.mechanism, self.password, salt, rounds);
            c.put(io, self.mechanism, salt, rounds, k);
            break :blk k;
        } else deriveKeys(self.mechanism, self.password, salt, rounds);

        // "c=biws" is base64("n,,"): no channel binding.
        const without_proof = try std.fmt.allocPrint(arena, "c=biws,r={s}", .{server_nonce});
        const auth_message = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ self.first_bare, server_first, without_proof });
        const n = self.mechanism.digestLen();
        var stored: [max_digest]u8 = undefined;
        hash(self.mechanism, keys.client[0..n], stored[0..n]);
        var signature: [max_digest]u8 = undefined;
        hmac(self.mechanism, signature[0..n], auth_message, stored[0..n]);
        var proof: [max_digest]u8 = undefined;
        for (proof[0..n], keys.client[0..n], signature[0..n]) |*p, k, s| p.* = k ^ s;
        hmac(self.mechanism, self.server_signature[0..n], auth_message, keys.server[0..n]);

        var proof_b64: [base64.Encoder.calcSize(max_digest)]u8 = undefined;
        const encoded = base64.Encoder.encode(&proof_b64, proof[0..n]);
        return std.fmt.allocPrint(arena, "{s},p={s}", .{ without_proof, encoded });
    }

    /// Checks the server-final message ("v=<signature>"): proof that the
    /// server knows the password too.
    pub fn verifyServerFinal(self: *const Conversation, server_final: []const u8) Error!void {
        if (std.mem.startsWith(u8, server_final, "e=")) return error.AuthenticationFailed;
        if (!std.mem.startsWith(u8, server_final, "v=")) return error.InvalidServerMessage;
        const text = std.mem.sliceTo(server_final[2..], ',');
        const n = self.mechanism.digestLen();
        var got: [max_digest]u8 = undefined;
        const len = base64.Decoder.calcSizeForSlice(text) catch return error.InvalidServerMessage;
        if (len != n) return error.ServerSignatureMismatch;
        base64.Decoder.decode(got[0..n], text) catch return error.InvalidServerMessage;
        var diff: u8 = 0;
        for (got[0..n], self.server_signature[0..n]) |a, b| diff |= a ^ b;
        if (diff != 0) return error.ServerSignatureMismatch;
    }
};

/// SaltedPassword through PBKDF2, then ClientKey and ServerKey.
pub fn deriveKeys(m: Mechanism, password: []const u8, salt: []const u8, iterations: u32) Keys {
    var keys: Keys = .{};
    var salted: [max_digest]u8 = undefined;
    const n = m.digestLen();
    switch (m) {
        .sha1 => std.crypto.pwhash.pbkdf2(salted[0..n], password, salt, iterations, HmacSha1) catch unreachable,
        .sha256 => std.crypto.pwhash.pbkdf2(salted[0..n], password, salt, iterations, HmacSha256) catch unreachable,
    }
    hmac(m, keys.client[0..n], "Client Key", salted[0..n]);
    hmac(m, keys.server[0..n], "Server Key", salted[0..n]);
    std.crypto.secureZero(u8, &salted);
    return keys;
}

fn hmac(m: Mechanism, out: []u8, msg: []const u8, key: []const u8) void {
    switch (m) {
        .sha1 => HmacSha1.create(out[0..HmacSha1.mac_length], msg, key),
        .sha256 => HmacSha256.create(out[0..HmacSha256.mac_length], msg, key),
    }
}

fn hash(m: Mechanism, in: []const u8, out: []u8) void {
    switch (m) {
        .sha1 => Sha1.hash(in, out[0..Sha1.digest_length], .{}),
        .sha256 => Sha256.hash(in, out[0..Sha256.digest_length], .{}),
    }
}

/// SCRAM-SHA-1's password: `hex(md5(username ":mongo:" password))`.
pub fn mongoHashedPassword(arena: std.mem.Allocator, username: []const u8, password: []const u8) error{OutOfMemory}![]const u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(username);
    md5.update(":mongo:");
    md5.update(password);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, &hex);
}

/// RFC 4013 SASLprep, without NFKC (see the file comment).
pub fn saslPrep(arena: std.mem.Allocator, password: []const u8) Error![]const u8 {
    var ascii = true;
    for (password) |ch| {
        if (ch >= 0x80) ascii = false else if (ch < 0x20 or ch == 0x7f) return error.InvalidPassword;
    }
    if (ascii) return password;
    var out: std.ArrayList(u8) = .empty;
    const view = std.unicode.Utf8View.init(password) catch return error.InvalidPassword;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // B.1: commonly mapped to nothing.
        switch (cp) {
            0xAD, 0x34F, 0x1806, 0x180B...0x180D, 0x200B...0x200D, 0x2060, 0xFE00...0xFE0F, 0xFEFF => continue,
            else => {},
        }
        // C.1.2: non-ASCII spaces become U+0020.
        const mapped: u21 = switch (cp) {
            0xA0, 0x1680, 0x2000...0x200B, 0x202F, 0x205F, 0x3000 => ' ',
            else => cp,
        };
        if (mapped < 0x20 or mapped == 0x7f or (mapped >= 0x80 and mapped < 0xA0)) return error.InvalidPassword;
        if (mapped >= 0x80) return error.SaslPrepUnsupported;
        try out.append(arena, @intCast(mapped));
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests: the RFCs' examples and auth.md's.

const testing = std.testing;

/// One exchange with the client nonce fixed, as the examples give it;
/// returns the client-final message, checked against `server_final`.
fn exchange(arena: std.mem.Allocator, m: Mechanism, password: []const u8, nonce: []const u8, server_first: []const u8, server_final: []const u8) ![]const u8 {
    var conv = try Conversation.initNonce(arena, m, "user", password, nonce);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "n,,n=user,r={s}", .{nonce}), try conv.clientFirst(arena));
    const final = try conv.clientFinal(arena, testing.io, null, server_first);
    try conv.verifyServerFinal(server_final);
    return final;
}

test "SCRAM-SHA-1: RFC 5802's example (plain password) and auth.md's (MongoDB's hashed one)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // RFC 5802 section 5 runs over the password itself; MongoDB hashes it
    // first, so put "pencil" back in place of the hash.
    var rfc = try Conversation.initNonce(arena, .sha1, "user", "pencil", "fyko+d2lbbFgONRv9qkxdawL");
    rfc.password = "pencil";
    try testing.expectEqualStrings(
        "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=",
        try rfc.clientFinal(arena, testing.io, null, "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"),
    );
    try rfc.verifyServerFinal("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=");

    try testing.expectEqualStrings(
        "c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=",
        try exchange(arena, .sha1, "pencil", "fyko+d2lbbFgONRv9qkxdawL", "r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000", "v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0="),
    );
}

test "SCRAM-SHA-256: RFC 7677's example (also auth.md's)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        try exchange(arena_state.allocator(), .sha256, "pencil", "rOprNGfwEbeRWgbNEkqO", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="),
    );
}

test "Conversation: messages, checks on the server's, and the key cache" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conv = try Conversation.init(arena, .sha256, "us=er,x", "pencil", @splat(7));
    const first = try conv.clientFirst(arena);
    try testing.expect(std.mem.startsWith(u8, first, "n,,n=us=3Der=2Cx,r="));
    const ours = conv.nonce;
    try testing.expectEqual(@as(usize, 32), ours.len);

    const sf = try std.fmt.allocPrint(arena, "r={s}SERVER,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", .{ours});
    var cache: Cache = .{};
    const final = try conv.clientFinal(arena, testing.io, &cache, sf);
    try testing.expect(std.mem.startsWith(u8, final, "c=biws,r="));
    try testing.expectEqual(@as(usize, 1), cache.len);
    // A second conversation over the same salt takes the cached keys and
    // computes the same proof.
    var again = conv;
    try testing.expectEqualStrings(final, try again.clientFinal(arena, testing.io, &cache, sf));
    try testing.expectEqual(@as(usize, 1), cache.len);

    try testing.expectError(error.ServerSignatureMismatch, conv.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    try testing.expectError(error.AuthenticationFailed, conv.verifyServerFinal("e=invalid-proof"));
    try testing.expectError(error.InvalidNonce, conv.clientFinal(arena, testing.io, null, "r=someone-else,s=QSXCR+Q6sek8bf92,i=4096"));
    const low = try std.fmt.allocPrint(arena, "r={s}X,s=QSXCR+Q6sek8bf92,i=1000", .{ours});
    try testing.expectError(error.IterationCountTooLow, conv.clientFinal(arena, testing.io, null, low));
    const ext = try std.fmt.allocPrint(arena, "m=x,r={s}X,s=QSXCR+Q6sek8bf92,i=4096", .{ours});
    try testing.expectError(error.InvalidServerMessage, conv.clientFinal(arena, testing.io, null, ext));
}

test "saslPrep: ASCII as it is, RFC 4013's mappings, the rest refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("pencil", try saslPrep(arena, "pencil"));
    // Soft hyphen: mapped to nothing (auth.md's "I­X" case).
    try testing.expectEqualStrings("IX", try saslPrep(arena, "I\u{AD}X"));
    try testing.expectEqualStrings("a b", try saslPrep(arena, "a\u{A0}b"));
    try testing.expectError(error.InvalidPassword, saslPrep(arena, "a\x07b"));
    // U+2168 ROMAN NUMERAL NINE needs NFKC.
    try testing.expectError(error.SaslPrepUnsupported, saslPrep(arena, "\u{2168}"));
    try testing.expectEqualStrings("1c33006ec1ffd90f9cadcbcc0e118200", try mongoHashedPassword(arena, "user", "pencil"));
}
