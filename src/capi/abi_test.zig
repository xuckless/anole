//! `include/anole.h` against `abi.zig`: the header translated by translate-c
//! (`anole_h`), every struct's size, alignment and field offsets, and every
//! constant, compared with the Zig side the library is built from, both
//! ways. Also the allocation table (events, handle kinds), the schema's ABI
//! version and the guide naming every event and function. Run by
//! `zig build test` (and `zig build capi-test`).
const std = @import("std");
const abi = @import("capi_abi");
const c = @import("anole_h");
const gen = @import("capi_abi_json");
const schema_text = @import("anole_schema").text;
const guide_text = @import("anole_guide").text;
const header_text = @import("anole_header_text").text;
const build_version = @import("anole_version").text;

fn expectSameLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    try std.testing.expectEqual(@alignOf(C), @alignOf(Zig));
    const zi = @typeInfo(Zig).@"struct";
    const ci = @typeInfo(C).@"struct";
    try std.testing.expectEqual(ci.field_names.len, zi.field_names.len);
    inline for (zi.field_names, ci.field_names, zi.field_types, ci.field_types) |zn, cn, zt, ct| {
        std.testing.expectEqual(@offsetOf(C, cn), @offsetOf(Zig, zn)) catch |err| {
            std.debug.print("field {s} / {s}\n", .{ zn, cn });
            return err;
        };
        try std.testing.expectEqual(@sizeOf(ct), @sizeOf(zt));
    }
}

test "anole.h: every struct as abi.zig lays it out" {
    @setEvalBranchQuota(1_000_000);
    inline for (abi.records) |r| {
        expectSameLayout(r[1], @field(c, r[0])) catch |err| {
            std.debug.print("record {s}\n", .{r[0]});
            return err;
        };
    }
}

test "anole.h: every struct the header declares is in abi.records" {
    @setEvalBranchQuota(1_000_000);
    const decls = @typeInfo(c).@"struct".decl_names;
    inline for (decls) |name| {
        // Types only: reading a function declaration as a value would make
        // the linker want the C symbol.
        if (comptime std.mem.startsWith(u8, name, "anole_") and @TypeOf(@field(c, name)) == type) {
            const v = @field(c, name);
            if (comptime @typeInfo(v) == .@"struct") {
                const found = comptime blk: {
                    for (abi.records) |r| if (std.mem.eql(u8, r[0], name)) break :blk true;
                    break :blk false;
                };
                if (!found) {
                    std.debug.print("the header's struct {s} is not in abi.records\n", .{name});
                    return error.MissingRecord;
                }
            }
        }
    }
}

test "anole.h: every ANOLE_ constant in the header is in abi.zig, and the reverse" {
    @setEvalBranchQuota(1_000_000);
    const eq = std.testing.expectEqual;
    try eq(abi.version_major, c.ANOLE_ABI_VERSION_MAJOR);
    try eq(abi.version_minor, c.ANOLE_ABI_VERSION_MINOR);
    try eq(abi.version, c.ANOLE_ABI_VERSION);
    // abi.zig -> header
    const ours = comptime gen.constants(abi);
    inline for (ours) |k| {
        if (!@hasDecl(c, k.name)) {
            std.debug.print("{s} is in abi.zig and not in anole.h\n", .{k.name});
            return error.MissingInHeader;
        }
        try eq(@as(i64, k.value), @as(i64, @intCast(@field(c, k.name))));
    }
    // header -> abi.zig
    const decls = @typeInfo(c).@"struct".decl_names;
    inline for (decls) |name| {
        if (comptime std.mem.startsWith(u8, name, "ANOLE_") and !std.mem.startsWith(u8, name, "ANOLE_ABI_") and
            !std.mem.eql(u8, name, "ANOLE_H") and !std.mem.eql(u8, name, "ANOLE_API"))
        {
            switch (comptime @typeInfo(@TypeOf(@field(c, name)))) {
                .int, .comptime_int => {
                    const found = comptime blk: {
                        for (ours) |k| if (std.mem.eql(u8, k.name, name)) break :blk true;
                        break :blk false;
                    };
                    if (!found) {
                        std.debug.print("{s} is in anole.h and not in abi.zig\n", .{name});
                        return error.MissingInZig;
                    }
                },
                else => {},
            }
        }
    }
}

/// The `NAME = value` entries of the C enum whose body starts right after
/// `opening` in the header, comments skipped. The names live in `a` (an
/// arena).
fn headerEnum(a: std.mem.Allocator, opening: []const u8) !std.StringArrayHashMapUnmanaged(i64) {
    const at = std.mem.indexOf(u8, header_text, opening) orelse return error.EnumNotInHeader;
    const body_start = at + opening.len;
    const body_end = std.mem.indexOfPos(u8, header_text, body_start, "};") orelse return error.EnumNotClosed;
    // Drop the comments: they name other constants.
    var text: std.ArrayList(u8) = .empty;
    var rest = header_text[body_start..body_end];
    while (std.mem.indexOf(u8, rest, "/*")) |open| {
        try text.appendSlice(a, rest[0..open]);
        const close = std.mem.indexOfPos(u8, rest, open, "*/") orelse return error.CommentNotClosed;
        rest = rest[close + 2 ..];
    }
    try text.appendSlice(a, rest);
    var out: std.StringArrayHashMapUnmanaged(i64) = .empty;
    var entries = std.mem.splitScalar(u8, text.items, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.EntryWithoutValue;
        const name = std.mem.trim(u8, entry[0..eq], " \t\r\n");
        const value = try std.fmt.parseInt(i64, std.mem.trim(u8, entry[eq + 1 ..], " \t\r\nu"), 0);
        const gop = try out.getOrPut(a, name);
        if (gop.found_existing) return error.DuplicateEntry;
        gop.value_ptr.* = value;
    }
    return out;
}

/// `want` (abi.zig's names and values) and `got` (the header enum's) hold
/// the same entries, both ways.
fn expectSameEntries(comptime what: []const u8, want: []const gen.Constant, got: *const std.StringArrayHashMapUnmanaged(i64)) !void {
    for (want) |k| {
        const v = got.get(k.name) orelse {
            std.debug.print("{s} is in abi.zig and not in anole.h's {s}\n", .{ k.name, what });
            return error.MissingInHeaderEnum;
        };
        if (v != k.value) {
            std.debug.print("{s}: {d} in abi.zig, {d} in anole.h's {s}\n", .{ k.name, k.value, v, what });
            return error.ValueMismatch;
        }
    }
    for (got.keys()) |name| {
        const found = for (want) |k| {
            if (std.mem.eql(u8, k.name, name)) break true;
        } else false;
        if (!found) {
            std.debug.print("{s} is in anole.h's {s} and not in abi.zig\n", .{ name, what });
            return error.MissingInZig;
        }
    }
}

test "anole.h: enum anole_event_type is abi.zig's event types, and the status enum its status codes" {
    @setEvalBranchQuota(1_000_000);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = comptime gen.constants(abi);
    const events = comptime blk: {
        var list: []const gen.Constant = &.{};
        for (all) |k| if (std.mem.startsWith(u8, k.name, "ANOLE_EV_")) {
            list = list ++ &[_]gen.Constant{k};
        };
        break :blk list;
    };
    const statuses = comptime blk: {
        var list: []const gen.Constant = &.{};
        for (all) |k| if (std.mem.eql(u8, k.group, "status")) {
            list = list ++ &[_]gen.Constant{k};
        };
        break :blk list;
    };
    try std.testing.expectEqual(abi.events.len, events.len);

    const ev = try headerEnum(a, "enum anole_event_type {");
    try expectSameEntries("enum anole_event_type", events, &ev);

    const st = try headerEnum(a, "typedef int32_t anole_status;\nenum {");
    try expectSameEntries("status enum (after anole_status)", statuses, &st);
}

test "anole.h: a handle typedef for every handle kind, and no other" {
    // The Kafka handles are the broker kinds under their own C names
    // (abi.handle_kinds).
    const aliases = [_][]const u8{ "anole_kafka_group", "anole_kafka_batch" };
    for (abi.handle_kinds) |k| {
        const decl = try std.fmt.allocPrint(std.testing.allocator, "typedef uint64_t {s};", .{k.c_type});
        defer std.testing.allocator.free(decl);
        if (std.mem.indexOf(u8, header_text, decl) == null) {
            std.debug.print("handle kind {s}: anole.h has no `{s}`\n", .{ k.name, decl });
            return error.MissingHandleType;
        }
    }
    var rest: []const u8 = header_text;
    while (std.mem.indexOf(u8, rest, "typedef uint64_t ")) |at| {
        rest = rest[at + "typedef uint64_t ".len ..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse break;
        const name = rest[0..end];
        const known = for (abi.handle_kinds) |k| {
            if (std.mem.eql(u8, k.c_type, name)) break true;
        } else for (aliases) |al| {
            if (std.mem.eql(u8, al, name)) break true;
        } else false;
        if (!known) {
            std.debug.print("anole.h's handle type {s} is no kind in abi.handle_kinds\n", .{name});
            return error.UnknownHandleType;
        }
    }
}

fn upperOf(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, &out) |ch, *o| o.* = std.ascii.toUpper(ch);
        const final = out;
        return &final;
    }
}

test "abi.zig: the allocation table holds" {
    @setEvalBranchQuota(1_000_000);
    // Every EventType has exactly one entry, named after it.
    const info = @typeInfo(abi.EventType).@"enum";
    inline for (info.field_names, info.field_values) |n, v| {
        var count: usize = 0;
        for (abi.events) |ev| {
            if (ev.type != v) continue;
            count += 1;
            try std.testing.expectEqualStrings("ANOLE_EV_" ++ comptime upperOf(n), ev.name);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    try std.testing.expectEqual(info.field_names.len, abi.events.len);
    for (abi.events) |ev| {
        // In a range for its area; 9 is retired.
        var in_range = false;
        for (abi.event_ranges) |r| if (ev.type >= r.from and ev.type <= r.to) {
            in_range = true;
        };
        try std.testing.expect(in_range);
        try std.testing.expect(ev.type != 9);
        // Every handle it names is a kind.
        for (ev.handles) |h| {
            var known = false;
            for (abi.handle_kinds) |k| if (std.mem.eql(u8, k.name, h)) {
                known = true;
            };
            try std.testing.expect(known);
        }
    }
    // Handle kinds named, ascending, no duplicates (7 is reserved).
    try std.testing.expectEqual(@as(usize, 8), abi.handle_kinds.len);
    for (abi.handle_kinds, 0..) |k, i| {
        try std.testing.expect(k.kind != 7);
        if (i > 0) try std.testing.expect(k.kind > abi.handle_kinds[i - 1].kind);
        for (abi.handle_kinds[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, other.name, k.name));
    }
    // Error tokens are unique and sorted.
    for (abi.error_names[1..], 0..) |name, i| try std.testing.expect(std.mem.lessThan(u8, abi.error_names[i], name));
}

test "anole.schema.json: x-anole-abi is the ABI version, $id names this release" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, schema_text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const want = try std.fmt.allocPrint(a, "{d}.{d}", .{ abi.version_major, abi.version_minor });
    defer a.free(want);
    try std.testing.expectEqualStrings(want, obj.get("x-anole-abi").?.string);
    const id = obj.get("$id").?.string;
    const needle = try std.fmt.allocPrint(a, "/v{s}/", .{build_version});
    defer a.free(needle);
    try std.testing.expect(std.mem.indexOf(u8, id, needle) != null);
}

test "docs/c-abi.md names every event type and every anole_* function" {
    @setEvalBranchQuota(1_000_000);
    for (abi.events) |ev| {
        if (std.mem.indexOf(u8, guide_text, ev.name) == null) {
            std.debug.print("docs/c-abi.md does not mention {s}\n", .{ev.name});
            return error.UndocumentedEvent;
        }
    }
    // The function names come from the header's text: touching a function
    // declaration of the translated header, even through @TypeOf, makes the
    // self-hosted backends link against the C symbol.
    var rest: []const u8 = header_text;
    var count: usize = 0;
    while (std.mem.indexOf(u8, rest, "ANOLE_API ")) |at| {
        rest = rest[at + "ANOLE_API ".len ..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse break;
        var start = paren;
        while (start > 0 and (std.ascii.isAlphanumeric(rest[start - 1]) or rest[start - 1] == '_')) start -= 1;
        const name = rest[start..paren];
        if (!std.mem.startsWith(u8, name, "anole_")) continue;
        count += 1;
        if (std.mem.indexOf(u8, guide_text, name) == null) {
            std.debug.print("docs/c-abi.md does not mention {s}\n", .{name});
            return error.UndocumentedFunction;
        }
    }
    try std.testing.expect(count > 50);
}
