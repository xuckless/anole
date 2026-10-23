//! Writes a SHA256SUMS file: `sums <out> <file>...` hashes each file and
//! writes `<hex>  <basename>` lines in the order given (for `zig build
//! cli-dist`).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (args[2..]) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
        defer gpa.free(bytes);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        try text.writer.print("{x}  {s}\n", .{ &digest, std.fs.path.basename(path) });
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = text.written() });
}
