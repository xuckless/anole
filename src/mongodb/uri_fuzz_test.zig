//! The connection-string fuzz target, outside uri.zig so the spec tests
//! (a module rooted in src/mongodb) can import uri.zig without src/fuzz.zig.

const std = @import("std");
const uri = @import("uri.zig");

test "fuzz: connection strings: parsed or refused, never the password in the message" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var diag: uri.Diagnostic = .{};
            // As a whole connection string.
            if (uri.parse(arena, input, &diag)) |cs| {
                _ = uri.credential(arena, cs, &diag) catch {};
            } else |_| {}
            // As the password.
            if (input.len < 6) return;
            const scaffold = "mongodb://app:***@h1:27017,h2/shop?authSource=admin&replicaSet=rs0";
            if (std.mem.indexOf(u8, scaffold, input) != null) return;
            const text = try std.fmt.allocPrint(arena, "mongodb://app:{s}@h1:27017,h2/shop?authSource=admin&replicaSet=rs0", .{input});
            diag = .{};
            if (uri.parse(arena, text, &diag)) |cs| {
                diag = .{};
                _ = uri.credential(arena, cs, &diag) catch {};
            } else |_| {}
            if (std.mem.indexOf(u8, diag.message, input) != null) return error.PasswordShown;
        }
    }.check, &.{ "mongodb://u:p@h/db", "hunter2", "pa/ss?x", "a@b?c", "p:ss/w?rd", "x]y[z", "%zz%41", "mongodb://h/?tls=true&ssl=false" });
}
