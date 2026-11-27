//! Every public name the anole-zig skill mentions (skills/anole-zig/apis.txt,
//! one `anole.X.Y` per line) resolves: each part is a public declaration or a
//! field of what the part before it names. `zig build skill-test`, with every
//! feature on (the default profile).
const std = @import("std");
const anole = @import("anole");
const apis = @import("skills").apis;

/// The container a part leads into: a type itself, else a value's type, with
/// optionals and pointers taken off (`?*Options` leads into `Options`).
fn container(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| container(o.child),
        .pointer => |p| container(p.child),
        else => T,
    };
}

/// What `part` of `T` leads into, or null when `T` has no such public
/// declaration or field.
fn step(comptime T: type, comptime part: []const u8) ?type {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return null,
    }
    if (@hasDecl(T, part)) {
        const V = @TypeOf(@field(T, part));
        if (V == type) return container(@field(T, part));
        // A type function such as `Server(Ctx)` leads into an instance.
        if (@typeInfo(V) == .@"fn") {
            const f = @typeInfo(V).@"fn";
            if (f.return_type == type and f.param_types.len == 1 and f.param_types[0] == type) return @field(T, part)(struct {});
        }
        return container(V);
    }
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => if (@hasField(T, part)) return container(@FieldType(T, part)),
        .@"enum" => if (@hasField(T, part)) return T,
        else => {},
    }
    return null;
}

fn resolves(comptime name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    if (!std.mem.eql(u8, parts.first(), "anole")) return false;
    var T: type = anole;
    while (parts.next()) |part| T = step(T, part) orelse return false;
    return true;
}

/// The names that do not resolve, one per line.
const missing = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, apis, "\r\n");
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t");
        if (name.len == 0 or name[0] == '#') continue;
        if (!resolves(name)) out = out ++ name ++ "\n";
    }
    break :blk out;
};

test "every name in skills/anole-zig/apis.txt resolves" {
    if (missing.len != 0) {
        std.debug.print("skills/anole-zig/apis.txt names what this build does not have:\n{s}", .{missing});
        return error.UnresolvedName;
    }
}
