//! pg.zig's `tls` module (`-Dpostgres` with `-Dtls=boringssl`): its TLS
//! connections on Anole's BoringSSL client (src/tls/dusty_tls.zig), so
//! PostgreSQL, HTTPS and QUIC share one TLS stack, and a handshake waits
//! through `std.Io` like every other read. pg.zig's `TlsHandshake` (its
//! src/stream.zig) describes what it calls; build.zig injects this file as
//! the `tls` import of xuckless/pg.zig built with `.tls = .injected`.
const std = @import("std");
const dusty_tls = @import("anole_dusty_tls");

pub const Connection = dusty_tls.Connection;
pub const input_buffer_len = dusty_tls.input_buffer_len;
pub const output_buffer_len = dusty_tls.output_buffer_len;

/// A trust store from `dusty_tls.clientStore`.
pub const Store = @typeInfo(@FieldType(dusty_tls.config.Client, "store")).optional.child;
pub const CertKeyPair = dusty_tls.config.CertKeyPair;

/// `pg.Conn.Opts.tls_config`: what `anole.pg` resolved from the URL and
/// its options. Both pointers belong to the connector and outlive its
/// connections.
pub const Config = struct {
    /// What verify-ca and verify-full check the server's chain against;
    /// null: the system's store, or the handshake's `root_cert` file.
    store: ?Store = null,
    /// The client certificate (`sslcert`, `sslkey`), for servers that ask.
    auth: ?*CertKeyPair = null,
};

pub fn client(input: *std.Io.Reader, output: *std.Io.Writer, handshake: anytype) !Connection {
    const io = handshake.io;
    const verify = handshake.mode != .require;
    const config: *const Config = handshake.config;

    var owned: ?Store = null;
    defer if (owned) |s| dusty_tls.releaseStore(s);
    const store: ?Store = if (!verify) null else config.store orelse blk: {
        owned = if (handshake.root_cert) |path|
            try dusty_tls.clientStore(handshake.allocator, io, Ca{ .file = path })
        else
            try dusty_tls.clientStore(handshake.allocator, io, @as(Ca, .system));
        break :blk owned orelse return error.NoCertificateAuthority;
    };

    var rng: std.Random.IoSource = .{ .io = io };
    return dusty_tls.client(input, output, .{
        .host = handshake.host,
        .root_ca = .empty,
        .store = store,
        .insecure_skip_verify = !verify,
        .skip_host_check = handshake.mode == .verify_ca,
        .auth = config.auth,
        .now = std.Io.Clock.real.now(io),
        .rng = rng.interface(),
        .alpn_protocols = handshake.alpn,
    });
}

/// The two sources `clientStore` is asked for here (it takes any union
/// with `.none`, `.system`, and a `load` for the rest).
const Ca = union(enum) {
    none,
    system,
    /// A PEM file (`sslrootcert`).
    file: []const u8,

    pub fn load(self: Ca, gpa: std.mem.Allocator, io: std.Io) !std.crypto.Certificate.Bundle {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(gpa);
        try bundle.addCertsFromFilePath(gpa, io, std.Io.Clock.real.now(io), std.Io.Dir.cwd(), self.file);
        return bundle;
    }
};
