//! Writes a fresh self-signed certificate and key (`anole.tls.selfSigned`)
//! to `<dir>/cert.pem` and `<dir>/key.pem` for the HTTP core's TLS tests,
//! so no key is ever committed. Run by `zig build test` at build time.
const std = @import("std");
const anole = @import("anole");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path = args.next() orelse return error.MissingOutputDirectory;

    var pem = try anole.tls.selfSigned(init.gpa, .{});
    defer pem.deinit(init.gpa);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = "cert.pem", .data = pem.cert });
    try dir.writeFile(init.io, .{ .sub_path = "key.pem", .data = pem.key });
}
