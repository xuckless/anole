//! The errors `init`, `listen`, `listenTls`, `run`, `waitReady` and the
//! certificate reloads can end with: named sets you can switch on, and
//! stable names the C ABI reports.
const std = @import("std");

/// Every way `init`, `listen`, `listenTls`, `run` and `waitReady` fail.
/// The names are stable: the C ABI reports them as `anole_last_error_name`.
pub const ServerError = error{
    // The options
    InvalidListenAddress,
    ListenersAlreadySet,
    InvalidListenerName,
    DuplicateListenerName,
    InvalidProxyNetwork,
    NoProtocols,
    SeveralHttp3Listeners,
    Http3NeedsTls,
    Http3NeedsHttps,
    TooManyListeners,
    RouteConflict,
    HqInteropNotAllowed,
    // Left out of this build
    TlsNotBuilt,
    Http2NotBuilt,
    Http3NotBuilt,
    // Binding
    AddressInUse,
    AddressNotAvailable,
    AccessDenied,
    InheritedSocketMismatch,
    // Certificates (also TlsLoadError)
    NoTlsListener,
    FileNotFound,
    InvalidCertificate,
    InvalidKey,
    KeyMismatch,
    // Connectors opened at start (`connect_at_start`)
    DatabaseUnavailable,
    // The process
    ServerAlreadyOnThread,
    SystemResources,
    OutOfMemory,
    Canceled,
    Unexpected,
};

/// `reloadCertificates` and `setCertificate`: a subset of `ServerError`.
pub const TlsLoadError = error{
    NoTlsListener,
    TlsNotBuilt,
    FileNotFound,
    AccessDenied,
    InvalidCertificate,
    InvalidKey,
    KeyMismatch,
    SystemResources,
    OutOfMemory,
    Unexpected,
};

/// The names of `ServerError`'s members, for documentation and tests.
pub const server_error_names: []const []const u8 = blk: {
    const members = @typeInfo(ServerError).error_set.?;
    var names: [members.len][]const u8 = undefined;
    for (members, 0..) |m, i| names[i] = m.name;
    const final = names;
    break :blk &final;
};

/// Names other layers use for the same thing, and what they become.
const aliases = [_][2][]const u8{
    .{ "AddressUnavailable", "AddressNotAvailable" },
    .{ "PermissionDenied", "AccessDenied" },
    .{ "TlsInvalidCertificate", "InvalidCertificate" },
    .{ "TlsFailure", "InvalidCertificate" },
    .{ "TlsInvalidPrivateKey", "InvalidKey" },
    .{ "TlsKeyMismatch", "KeyMismatch" },
    .{ "ProcessFdQuotaExceeded", "SystemResources" },
    .{ "SystemFdQuotaExceeded", "SystemResources" },
    .{ "NoSpaceLeft", "SystemResources" },
    .{ "ConcurrencyUnavailable", "SystemResources" },
};

fn toSet(comptime Set: type, err: anyerror) Set {
    const name = @errorName(err);
    const members = @typeInfo(Set).error_set.?;
    inline for (members) |m| if (std.mem.eql(u8, name, m.name)) return @field(Set, m.name);
    inline for (aliases) |alias| if (std.mem.eql(u8, name, alias[0])) {
        inline for (members) |m| if (comptime std.mem.eql(u8, alias[1], m.name)) return @field(Set, m.name);
    };
    // (A test that maps an unknown name on purpose must not fail on the log.)
    if (!@import("builtin").is_test) std.log.scoped(.anole).err("unexpected error while starting: {s}", .{name});
    return error.Unexpected;
}

/// Maps what the layers below return onto `ServerError`, logging the
/// original name at `err` when it becomes `Unexpected`.
pub fn toServerError(err: anyerror) ServerError {
    return toSet(ServerError, err);
}

/// As `toServerError`, for the certificate reloads.
pub fn toTlsLoadError(err: anyerror) TlsLoadError {
    return toSet(TlsLoadError, err);
}

/// The OS errno a name stands for (POSIX values), for the C ABI's
/// `anole_last_errno`; 0 when it is not an OS error.
pub fn posixErrno(name: anyerror) i32 {
    const E = std.posix.E;
    const n = @errorName(name);
    const pairs = .{
        .{ "AddressInUse", E.ADDRINUSE },
        .{ "AddressNotAvailable", E.ADDRNOTAVAIL },
        .{ "AccessDenied", E.ACCES },
        .{ "FileNotFound", E.NOENT },
        .{ "OutOfMemory", E.NOMEM },
        .{ "SystemResources", E.MFILE },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, n, p[0])) return @intFromEnum(p[1]);
    return 0;
}

test "errors: TlsLoadError is a subset of ServerError" {
    inline for (@typeInfo(TlsLoadError).error_set.?) |m| {
        comptime var found = false;
        inline for (@typeInfo(ServerError).error_set.?) |s| {
            if (comptime std.mem.eql(u8, m.name, s.name)) found = true;
        }
        if (!found) @compileError("TlsLoadError." ++ m.name ++ " is not in ServerError");
    }
}

test "errors: every member maps to itself; unknown names become Unexpected" {
    inline for (@typeInfo(ServerError).error_set.?) |m| {
        try std.testing.expectEqual(@field(ServerError, m.name), toServerError(@field(anyerror, m.name)));
    }
    try std.testing.expectEqual(error.AddressNotAvailable, toServerError(error.AddressUnavailable));
    try std.testing.expectEqual(error.KeyMismatch, toServerError(error.TlsKeyMismatch));
    try std.testing.expectEqual(error.Unexpected, toServerError(error.SomethingElseEntirely));
    try std.testing.expectEqual(error.InvalidKey, toTlsLoadError(error.TlsInvalidPrivateKey));
    try std.testing.expectEqual(error.Unexpected, toTlsLoadError(error.AddressInUse));
    try std.testing.expectEqual(@as(usize, @typeInfo(ServerError).error_set.?.len), server_error_names.len);
    try std.testing.expectEqual(@as(i32, @intFromEnum(std.posix.E.ADDRINUSE)), posixErrno(error.AddressInUse));
    try std.testing.expectEqual(@as(i32, 0), posixErrno(error.KeyMismatch));
}
