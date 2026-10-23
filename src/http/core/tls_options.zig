//! The TLS settings every part of Anole shares: a certificate (`Cert`), the
//! authorities a peer's certificate must chain to (`Ca`) and mutual TLS on a
//! listener (`ClientAuth`). Listeners, the HTTP clients and the database
//! connectors all take these, so a certificate is described one way.
//!
//! Kept in the core module, free of any TLS library, so it compiles with
//! `-Dtls=none`.
const std = @import("std");

/// A certificate (chain, leaf first) and its private key.
pub const Cert = union(enum) {
    /// PEM files, read at start and by every reload. Relative to the working
    /// directory.
    files: struct { cert_path: []const u8, key_path: []const u8 },
    /// PEM text, copied.
    pem: struct { cert: []const u8, key: []const u8 },
    /// A fresh self-signed certificate for localhost, 127.0.0.1 and ::1, in
    /// memory. Development only: a warning is logged when a listener serves
    /// it off loopback.
    dev_self_signed,

    /// PEM files, read when the server starts (and again by
    /// `reloadCertificates` and SIGHUP).
    pub fn fromFiles(cert_path: []const u8, key_path: []const u8) Cert {
        return .{ .files = .{ .cert_path = cert_path, .key_path = key_path } };
    }

    /// PEM text in memory.
    pub fn fromPem(cert: []const u8, key: []const u8) Cert {
        return .{ .pem = .{ .cert = cert, .key = key } };
    }
};

/// Certificate authorities a peer's certificate must chain to.
pub const Ca = union(enum) {
    /// The platform trust store.
    system,
    /// A single PEM file holding one or more certificates, relative to the
    /// working directory.
    file: []const u8,
    /// A directory of PEM files, each holding one or more certificates.
    dir: []const u8,
    /// One or more PEM certificates in memory: a CA that comes from a secret
    /// store or the environment. Read when the trust store is loaded (a
    /// client's first HTTPS request, a listener's start); it must stay alive
    /// until then.
    pem: []const u8,
    /// Trust nothing. Rejected unless the side using it says otherwise
    /// (`insecure_skip_verify`, for clients).
    none,

    /// The CAs in the PEM file at `path`.
    pub fn fromFile(path: []const u8) Ca {
        return .{ .file = path };
    }

    /// The CAs in PEM text.
    pub fn fromPem(text: []const u8) Ca {
        return .{ .pem = text };
    }

    /// Reads the certificates into a fresh bundle owned by the caller.
    pub fn load(self: Ca, gpa: std.mem.Allocator, io: std.Io) !std.crypto.Certificate.Bundle {
        const now = std.Io.Clock.real.now(io);

        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(gpa);
        switch (self) {
            .system => try bundle.rescan(gpa, io, now),
            .file => |path| try bundle.addCertsFromFilePath(gpa, io, now, std.Io.Dir.cwd(), path),
            .dir => |path| try bundle.addCertsFromDirPath(gpa, io, std.Io.Dir.cwd(), path),
            .pem => |text| try addCertsFromPem(&bundle, gpa, text, now.toSeconds()),
            .none => {},
        }
        return bundle;
    }
};

/// Mutual TLS on a listener: which CAs a client certificate must chain to,
/// and whether one is required.
pub const ClientAuth = struct {
    /// Certificate authorities used to verify client certificates. `.none`
    /// is refused at start.
    ca: Ca,
    /// `.require` rejects a client that sends no certificate; `.request`
    /// asks for one but accepts an empty reply.
    mode: Mode = .require,

    pub const Mode = enum { request, require };
};

/// `std.crypto.Certificate.Bundle.addCertsFromFile` for PEM text in memory:
/// every `BEGIN CERTIFICATE` block, decoded and parsed; expired ones are
/// skipped, as there.
pub fn addCertsFromPem(
    bundle: *std.crypto.Certificate.Bundle,
    allocator: std.mem.Allocator,
    pem: []const u8,
    now_sec: i64,
) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin| {
        const cert_start = begin + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start = std.math.cast(u32, bundle.bytes.items.len) orelse
            return error.CertificateAuthorityBundleTooBig;
        try bundle.bytes.ensureUnusedCapacity(allocator, base64.calcSizeUpperBound(encoded.len));
        bundle.bytes.items.len += try base64.decode(bundle.bytes.unusedCapacitySlice(), encoded);
        try bundle.parseCert(allocator, decoded_start, now_sec);
    }
}

test "Ca: file, dir, pem and system load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // No certificates in the text: an empty bundle, not an error.
    var from_pem = try (Ca{ .pem = "" }).load(gpa, io);
    defer from_pem.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), from_pem.bytes.items.len);
    var none = try Ca.load(.none, gpa, io);
    none.deinit(gpa);
    // A path that is not there fails, for both forms.
    try std.testing.expectError(error.FileNotFound, (Ca{ .file = "no-such-ca.pem" }).load(gpa, io));
    try std.testing.expect(std.meta.isError((Ca{ .dir = "no-such-ca-dir" }).load(gpa, io)));
    // The platform store: loads where the system has one.
    if (Ca.load(.system, gpa, io)) |b| {
        var bundle = b;
        bundle.deinit(gpa);
    } else |_| {}
}
