//! Outbound HTTPS from dusty's client on Anole's BoringSSL module, against
//! public hosts and the system trust store: the good ones must answer, and
//! badssl.com's broken certificates must fail with the error naming why.
//! Needs the network, so it is not part of `zig build test`; CI runs it
//! weekly (.github/workflows/network.yml).
//!
//!   zig build tls-public-check
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

const Expect = union(enum) { ok, fails: anyerror };

const checks = [_]struct { url: []const u8, expect: Expect }{
    .{ .url = "https://example.com/", .expect = .ok },
    .{ .url = "https://www.google.com/", .expect = .ok },
    .{ .url = "https://github.com/", .expect = .ok },
    .{ .url = "https://expired.badssl.com/", .expect = .{ .fails = error.CertificateExpired } },
    .{ .url = "https://wrong.host.badssl.com/", .expect = .{ .fails = error.CertificateHostMismatch } },
    .{ .url = "https://self-signed.badssl.com/", .expect = .{ .fails = error.CertificateIssuerNotFound } },
    .{ .url = "https://untrusted-root.badssl.com/", .expect = .{ .fails = error.CertificateIssuerNotFound } },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const rt = try anole.zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var client = anole.http.Client.init(gpa, io, .{ .tls = .{ .ca = .system } });
    defer client.deinit();

    var failed: usize = 0;
    for (checks) |check| {
        const result = client.fetch(check.url, .{});
        const pass = switch (check.expect) {
            .ok => if (result) |r| blk: {
                var response = r;
                defer response.deinit();
                std.debug.print("{s}: {d}\n", .{ check.url, @backingInt(response.status()) });
                break :blk true;
            } else |err| blk: {
                std.debug.print("{s}: {t} (expected a response)\n", .{ check.url, err });
                break :blk false;
            },
            .fails => |want| if (result) |r| blk: {
                var response = r;
                response.deinit();
                std.debug.print("{s}: answered (expected {t})\n", .{ check.url, want });
                break :blk false;
            } else |err| blk: {
                std.debug.print("{s}: {t}\n", .{ check.url, err });
                break :blk err == want;
            },
        };
        if (!pass) failed += 1;
    }
    if (failed > 0) {
        std.debug.print("{d} of {d} checks failed\n", .{ failed, checks.len });
        std.process.exit(1);
    }
    std.debug.print("all {d} checks passed\n", .{checks.len});
}
