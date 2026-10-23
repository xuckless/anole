//! Login forms: the pieces of a `.creds` file, and the CONNECT fields for
//! NKey and creds logins.
const std = @import("std");
const nkeys = @import("nkeys.zig");

/// The JWT and the seed of a `.creds` file (text, slices into it).
pub const Creds = struct {
    jwt: []const u8,
    seed: []const u8,
};

pub const CredsError = error{InvalidCreds};

/// Finds the user JWT and the NKey seed in a `.creds` file's text.
pub fn parseCreds(text: []const u8) CredsError!Creds {
    var jwt: ?[]const u8 = null;
    var seed: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "-----BEGIN")) continue;
        const want_jwt = std.mem.indexOf(u8, line, "JWT") != null;
        const want_seed = std.mem.indexOf(u8, line, "SEED") != null;
        if (!want_jwt and !want_seed) continue;
        while (it.next()) |body_raw| {
            const body = std.mem.trim(u8, body_raw, " \t\r");
            if (body.len == 0) continue;
            if (std.mem.startsWith(u8, body, "---")) break;
            if (want_jwt and jwt == null) jwt = body;
            if (want_seed and seed == null) seed = body;
            break;
        }
    }
    return .{ .jwt = jwt orelse return error.InvalidCreds, .seed = seed orelse return error.InvalidCreds };
}

/// Checks that `seed` decodes (used by option validation).
pub fn checkSeed(seed: []const u8) bool {
    _ = nkeys.decodeSeed(seed) catch return false;
    return true;
}

const testing = std.testing;

test "creds: the JWT and the seed are found in a .creds file" {
    const text =
        \\-----BEGIN NATS USER JWT-----
        \\eyJhbGciOiJlZDI1NTE5LW5rZXkifQ.payload.sig
        \\------END NATS USER JWT------
        \\
        \\************************* IMPORTANT *************************
        \\NKEY Seed printed below can be used to sign and prove identity.
        \\
        \\-----BEGIN USER NKEY SEED-----
        \\SUAMK2FG4MI6UE3ACF3FK3OIQBCEIEZV7NSWFFEW63UXMRLFM2XLAXK4GY
        \\------END USER NKEY SEED------
        \\
    ;
    const creds = try parseCreds(text);
    try testing.expectEqualStrings("eyJhbGciOiJlZDI1NTE5LW5rZXkifQ.payload.sig", creds.jwt);
    try testing.expectEqualStrings("SUAMK2FG4MI6UE3ACF3FK3OIQBCEIEZV7NSWFFEW63UXMRLFM2XLAXK4GY", creds.seed);
    try testing.expectError(error.InvalidCreds, parseCreds("nothing here"));
}

const fuzz = @import("../fuzz.zig");

test "fuzz: the .creds parse never crashes, and returns slices of its input" {
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            const creds = parseCreds(input) catch return;
            const lo = @intFromPtr(input.ptr);
            const hi = lo + input.len;
            for ([_][]const u8{ creds.jwt, creds.seed }) |s| {
                const p = @intFromPtr(s.ptr);
                if (s.len > 0 and (p < lo or p + s.len > hi)) return error.OutOfBounds;
            }
        }
    }.check, &.{
        "-----BEGIN NATS USER JWT-----\nabc.def.ghi\n------END NATS USER JWT------\n-----BEGIN USER NKEY SEED-----\nSUAAA\n------END USER NKEY SEED------\n",
        "-----BEGIN",
        "",
    });
}
