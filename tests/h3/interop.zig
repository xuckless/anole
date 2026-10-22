//! The server side of the QUIC interop runner's endpoint
//! (tests/interop/run_endpoint.sh): the files under a directory, over
//! HTTP/3 and over hq-interop (HTTP/0.9), on one port, with 0-RTT on (the
//! `zerortt` case; GETs only, which run from early data at once).
//!
//!   h3-interop-server CERT KEY WWW PORT [retry]
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
/// Lets `http3.hq_interop_root` through: this program is the interop
/// runner's endpoint, never a production server.
pub const anole_hq_interop = true;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const cert = args.next() orelse return error.Usage;
    const key = args.next() orelse return error.Usage;
    const www = args.next() orelse return error.Usage;
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);
    var retry = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "retry")) retry = true else return error.Usage;
    }

    var app = try anole.Server(void).init(init.gpa, .{
        .http = null,
        .https = .{ .address = "0.0.0.0", .port = port, .cert = .{ .files = .{ .cert_path = cert, .key_path = key } } },
        .http3 = .{ .validate_address = retry, .hq_interop_root = www, .max_streams_bidi = 1000, .early_data = true },
    }, {});
    defer app.deinit();
    const dir = try std.Io.Dir.cwd().openDir(app.io(), www, .{});
    defer dir.close(app.io());
    app.router.static("/", dir, .{});
    std.log.info("interop server on port {d}, serving {s}", .{ port, www });
    try app.run();
}
