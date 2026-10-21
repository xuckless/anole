//! Test helpers the TLS, HTTP/2, HTTP/3 and server tests share. Internal:
//! not reachable from `anole.tls`.
const std = @import("std");

/// Full-duplex check of `dusty_tls`, run on one executor and on four by
/// the tests in root.zig.
pub const duplex = @import("duplex_check.zig");

/// A CA bundle holding the first PEM certificate in `pem` (for a client
/// to trust a `selfSigned` server).
pub fn bundleFromPem(gpa: std.mem.Allocator, now_sec: i64, pem: []const u8) !std.crypto.Certificate.Bundle {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(gpa);
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const start = (std.mem.indexOf(u8, pem, begin) orelse return error.NoCertificate) + begin.len;
    const stop = std.mem.indexOfPos(u8, pem, start, end) orelse return error.NoCertificate;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (pem[start..stop]) |ch| if (ch != '\n' and ch != '\r') try text.append(gpa, ch);
    const len = try std.base64.standard.Decoder.calcSizeForSlice(text.items);
    const decoded_start: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.ensureUnusedCapacity(gpa, len);
    try std.base64.standard.Decoder.decode(bundle.bytes.unusedCapacitySlice()[0..len], text.items);
    bundle.bytes.items.len += len;
    try bundle.parseCert(gpa, decoded_start, now_sec);
    return bundle;
}
