//! Anole's log setup. The libraries underneath log under Anole's own scopes
//! (`anole`, `access`, `anole_h2`, `anole_h3`), so a server's terminal reads
//! as one program with std's default log. An executable may also declare,
//! in its root file:
//!
//!     pub const std_options = anole.std_options;
//!
//! which keeps the debug chatter of the runtime (a line per worker thread
//! started and stopped) and of the connection loops out of Debug builds.
//!
//! `logFn` is kept for programs that set it: it renames the scopes older
//! builds of the core used to the current ones (`anole`, `access`,
//! `anole_h2`) and passes everything else through.
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_scope_levels = &.{
        .{ .scope = .zio, .level = .info },
        .{ .scope = .anole, .level = .info },
        .{ .scope = .anole_h2, .level = .info },
        .{ .scope = .anole_h3, .level = .info },
    },
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const renamed = comptime rename(scope);
    std.log.defaultLog(level, renamed, format, args);
}

fn rename(comptime scope: @EnumLiteral()) @EnumLiteral() {
    if (scope == .dusty) return .anole;
    if (scope == .dusty_access) return .access;
    if (scope == .dusty_client) return .anole_client;
    if (scope == .dusty_h2) return .anole_h2;
    return scope;
}

test "older scopes are renamed, others kept" {
    try std.testing.expect(comptime rename(.dusty) == .anole);
    try std.testing.expect(comptime rename(.dusty_access) == .access);
    try std.testing.expect(comptime rename(.dusty_h2) == .anole_h2);
    try std.testing.expect(comptime rename(.anole) == .anole);
    try std.testing.expect(comptime rename(.zio) == .zio);
}

test "std_options: debug from the runtime and the loops quieted, the access log kept" {
    comptime {
        var zio_seen = false;
        for (std_options.log_scope_levels) |l| {
            std.debug.assert(l.level == .info);
            // The access log is info already; nothing here may hide it.
            std.debug.assert(l.scope != .access);
            if (l.scope == .zio) zio_seen = true;
        }
        std.debug.assert(zio_seen);
    }
}
