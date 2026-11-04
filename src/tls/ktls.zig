//! Kernel TLS for the sending side of a TLS 1.3 connection (Linux only;
//! every function says "no" elsewhere). BoringSSL has no kTLS of its own,
//! so the keys come from its current write traffic secret and record
//! number, expanded here as RFC 8446 §7.3 says, and go to the kernel with
//! two setsockopts (docs.kernel.org/networking/tls.html). After that the
//! socket takes plaintext and seals each send as one or more records;
//! BoringSSL keeps the reading side. `dusty_tls.zig` decides when.
//!
//! The same scheme as HAProxy's `ssl_sock_setup_ktls` (AWS-LC/BoringSSL
//! branch) and the rustls `ktls` crate: salt = iv[0..4], iv = iv[4..12],
//! rec_seq big-endian. Nothing copied.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("anole_boringssl_c");

pub const supported = builtin.os.tag == .linux;

const linux = std.os.linux;
const hkdfExpandLabel = std.crypto.tls.hkdfExpandLabel;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const HkdfSha384 = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);

// linux/tls.h and linux/tcp.h.
const sol_tls = 282;
const tls_tx = 1;
const tls_set_record_type = 1;
const tcp_ulp = 31;
const tls_1_3_version = 0x0304;
const cipher_aes_gcm_128 = 51;
const cipher_aes_gcm_256 = 52;
const cipher_chacha20_poly1305 = 54;

const Header = extern struct { version: u16, cipher_type: u16 };

/// `struct tls12_crypto_info_aes_gcm_128` (the name covers TLS 1.3 too).
const AesGcm128 = extern struct { info: Header, iv: [8]u8, key: [16]u8, salt: [4]u8, rec_seq: [8]u8 };
/// `struct tls12_crypto_info_aes_gcm_256`.
const AesGcm256 = extern struct { info: Header, iv: [8]u8, key: [32]u8, salt: [4]u8, rec_seq: [8]u8 };
/// `struct tls12_crypto_info_chacha20_poly1305` (its salt is empty).
const ChaCha20Poly1305 = extern struct { info: Header, iv: [12]u8, key: [32]u8, rec_seq: [8]u8 };

comptime {
    // The kernel checks the option length against these exactly.
    std.debug.assert(@sizeOf(AesGcm128) == 40 and @sizeOf(AesGcm256) == 56 and @sizeOf(ChaCha20Poly1305) == 56);
}

/// The kernel's key material for one direction.
pub const Info = union(enum) {
    aes128: AesGcm128,
    aes256: AesGcm256,
    chacha: ChaCha20Poly1305,

    pub fn bytes(info: *Info) []u8 {
        return switch (info.*) {
            inline else => |*v| std.mem.asBytes(v),
        };
    }
};

extern fn anole_ssl_write_traffic_secret(ssl: *const c.SSL, out: *[*]const u8, out_len: *usize) c_int;
extern fn anole_ssl_ctx_no_aes_hw_for_testing(ctx: *c.SSL_CTX) void;

/// Whether `ssl` is a connection the kernel could take over: TLS 1.3 with
/// one of the three AEADs the kernel has. Under the connection's lock.
pub fn eligible(ssl: *c.SSL) bool {
    if (!supported) return false;
    if (c.SSL_version(ssl) != c.TLS1_3_VERSION) return false;
    const cipher = c.SSL_get_current_cipher(ssl) orelse return false;
    return switch (c.SSL_CIPHER_get_protocol_id(cipher)) {
        0x1301, 0x1302, 0x1303 => true,
        else => false,
    };
}

/// The key material for the next record `ssl` would write, or null. Under
/// the connection's lock, with nothing sealed that has not left (the
/// caller's check): the kernel numbers its first record where BoringSSL
/// stopped. Zero it once used (`installTx` does).
pub fn derive(ssl: *c.SSL) ?Info {
    if (!supported or !eligible(ssl)) return null;
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    if (anole_ssl_write_traffic_secret(ssl, &ptr, &len) != 1) {
        c.ERR_clear_error();
        return null;
    }
    const secret = ptr[0..len];
    const seq = c.SSL_get_write_sequence(ssl);
    return switch (c.SSL_CIPHER_get_protocol_id(c.SSL_get_current_cipher(ssl).?)) {
        0x1301 => .{ .aes128 = fill(AesGcm128, cipher_aes_gcm_128, HkdfSha256, secret, seq) orelse return null },
        0x1302 => .{ .aes256 = fill(AesGcm256, cipher_aes_gcm_256, HkdfSha384, secret, seq) orelse return null },
        0x1303 => .{ .chacha = fill(ChaCha20Poly1305, cipher_chacha20_poly1305, HkdfSha256, secret, seq) orelse return null },
        else => null,
    };
}

/// RFC 8446 §7.3: key = HKDF-Expand-Label(secret, "key", "", key_len),
/// iv = HKDF-Expand-Label(secret, "iv", "", 12).
fn fill(comptime T: type, cipher_type: u16, comptime Hkdf: type, secret: []const u8, seq: u64) ?T {
    if (secret.len != Hkdf.prk_length) return null;
    var prk: [Hkdf.prk_length]u8 = secret[0..Hkdf.prk_length].*;
    defer std.crypto.secureZero(u8, &prk);
    var iv12 = hkdfExpandLabel(Hkdf, prk, "iv", "", 12);
    defer std.crypto.secureZero(u8, &iv12);
    var t: T = undefined;
    t.info = .{ .version = tls_1_3_version, .cipher_type = cipher_type };
    t.key = hkdfExpandLabel(Hkdf, prk, "key", "", @typeInfo(@TypeOf(t.key)).array.len);
    if (comptime @hasField(T, "salt")) {
        t.salt = iv12[0..4].*;
        t.iv = iv12[4..12].*;
    } else {
        t.iv = iv12;
    }
    std.mem.writeInt(u64, &t.rec_seq, seq, .big);
    return t;
}

/// Set once `TCP_ULP` said ENOENT: the `tls` module is not loaded, and
/// this process cannot load it (the kernel autoloads a ULP only for a
/// caller with CAP_NET_ADMIN, net/ipv4/tcp_ulp.c). Later connections skip
/// the syscall. Other errors (a socket that is not TCP) are the
/// connection's own.
var ulp_missing: std.atomic.Value(bool) = .init(false);

pub fn ulpMissing() bool {
    return ulp_missing.load(.monotonic);
}

/// Attaches the kernel's `tls` ULP to `fd`. With no key installed it
/// passes everything through unchanged, so a failure after this is
/// harmless. May wait in the kernel (a module load): never under a lock.
pub fn attachUlp(fd: std.posix.fd_t) bool {
    if (!supported or ulp_missing.load(.monotonic)) return false;
    const rc = linux.setsockopt(fd, linux.IPPROTO.TCP, tcp_ulp, "tls", 3);
    return switch (linux.errno(rc)) {
        .SUCCESS => true,
        .NOENT => {
            ulp_missing.store(true, .monotonic);
            return false;
        },
        else => false,
    };
}

/// Hands `info` to the kernel for everything sent on `fd` from now on,
/// and zeroes it. False on any failure (the AEAD missing, out of memory):
/// the socket then still passes bytes through as they are. A short
/// syscall that does not wait.
pub fn installTx(fd: std.posix.fd_t, info: *Info) bool {
    if (!supported) return false;
    const b = info.bytes();
    defer std.crypto.secureZero(u8, b);
    const rc = linux.setsockopt(fd, sol_tls, tls_tx, b.ptr, @intCast(b.len));
    return linux.errno(rc) == .SUCCESS;
}

/// Sends a close_notify alert as a kernel-sealed record: one `sendmsg`
/// with the record type in a control message (as the `ktls` crate's
/// `send_close_notify`). Best effort and never waiting: a full send
/// buffer loses it.
pub fn sendCloseNotify(fd: std.posix.fd_t) void {
    if (!supported) return;
    const alert = [2]u8{ 1, 0 }; // warning, close_notify
    const iov = [1]std.posix.iovec_const{.{ .base = &alert, .len = alert.len }};
    const hdr_len = comptime std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), linux.cmsg_align);
    var control: [hdr_len + linux.cmsg_align]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const hdr: *linux.cmsghdr = @ptrCast(&control);
    hdr.* = .{ .len = hdr_len + 1, .level = sol_tls, .type = tls_set_record_type };
    control[hdr_len] = 21; // alert
    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    _ = linux.sendmsg(fd, &msg, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL);
}

/// Test checks, run from src/tls/root.zig.
pub const checks = if (builtin.is_test) struct {
    /// See `anole_ssl_ctx_no_aes_hw_for_testing`.
    pub fn noAesHw(ctx: *c.SSL_CTX) void {
        anole_ssl_ctx_no_aes_hw_for_testing(ctx);
    }

    /// `derive` on `server` gives the key, nonce and record number of the
    /// next record it seals: `record` (a whole TLS 1.3 record BoringSSL
    /// wrote after the call) opens with them in Zig's own AEADs, and its
    /// inner plaintext is `plain` followed by the content type 23.
    pub fn expectOpens(info: Info, record: []const u8, plain: []const u8) !void {
        if (record.len < 5 + 16) return error.ShortRecord;
        const ad = record[0..5];
        const body = record[5 .. record.len - 16];
        const tag: [16]u8 = record[record.len - 16 ..][0..16].*;
        const out = try std.testing.allocator.alloc(u8, body.len);
        defer std.testing.allocator.free(out);
        switch (info) {
            inline else => |v| {
                var nonce: [12]u8 = undefined;
                if (comptime @hasField(@TypeOf(v), "salt")) {
                    nonce = v.salt ++ v.iv;
                } else {
                    nonce = v.iv;
                }
                for (nonce[4..], v.rec_seq) |*n, s| n.* ^= s;
                const Aead = switch (@TypeOf(v)) {
                    AesGcm128 => std.crypto.aead.aes_gcm.Aes128Gcm,
                    AesGcm256 => std.crypto.aead.aes_gcm.Aes256Gcm,
                    else => std.crypto.aead.chacha_poly.ChaCha20Poly1305,
                };
                try Aead.decrypt(out, body, tag, ad, nonce, v.key);
            },
        }
        try std.testing.expectEqualSlices(u8, plain, out[0..plain.len]);
        try std.testing.expectEqual(@as(u8, 23), out[plain.len]);
        for (out[plain.len + 1 ..]) |pad| try std.testing.expectEqual(@as(u8, 0), pad);
    }
} else struct {};
