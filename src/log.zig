//! Anole's log output: std's default log with the scopes of the libraries
//! underneath renamed to Anole's (`dusty` -> `anole`, `dusty_access` ->
//! `access`, `dusty_h2` -> `anole_h2`), so a server's terminal reads as one
//! program. An executable
//! opts in from its root file:
//!
//!     pub const std_options: std.Options = .{ .logFn = anole.logFn };
const std = @import("std");

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

test "dusty's scopes are renamed, others kept" {
    try std.testing.expect(comptime rename(.dusty) == .anole);
    try std.testing.expect(comptime rename(.dusty_access) == .access);
    try std.testing.expect(comptime rename(.dusty_h2) == .anole_h2);
    try std.testing.expect(comptime rename(.zio) == .zio);
}
