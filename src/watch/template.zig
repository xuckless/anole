//! Topic and room templates of `anole.watch` targets: literal text with
//! `{channel}`, `{op}`, `{data.<field>}` and, for MongoDB, `{db}`,
//! `{collection}` and `{key}`.
//!
//!     "room:{data.room}"   a PostgreSQL trigger's {"room": "lobby", ...} -> "room:lobby"
//!     "{channel}"          a Redis pattern subscription's channel
//!
//! An event whose template cannot be filled (a missing field) is skipped for
//! that target.

const std = @import("std");

pub const Segment = union(enum) {
    literal: []const u8,
    channel,
    op,
    db,
    collection,
    key,
    data_field: []const u8,
};

pub const ParseError = error{ OutOfMemory, InvalidTemplate };

/// What a template can use.
pub const Vars = struct {
    channel: []const u8 = "",
    op: []const u8 = "",
    db: ?[]const u8 = null,
    collection: ?[]const u8 = null,
    key: ?[]const u8 = null,
    data: []const u8 = "",
};

pub const Template = struct {
    segments: []const Segment,
    /// The literal text before the first placeholder ("" when it starts
    /// with one, or has none and is empty). A gap on a templated topic
    /// goes to every topic with this prefix.
    prefix: []const u8,
    /// No placeholder at all.
    fixed: bool,

    /// Parses `text` into segments owned by `gpa` (and the strings in them).
    /// `mongodb`: `{db}`, `{collection}` and `{key}` are allowed.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, mongodb: bool) ParseError!Template {
        var list: std.ArrayList(Segment) = .empty;
        errdefer {
            for (list.items) |seg| freeSegment(gpa, seg);
            list.deinit(gpa);
        }
        var i: usize = 0;
        var literal_start: usize = 0;
        var fixed = true;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '}') return error.InvalidTemplate;
            if (ch != '{') {
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, text, i, '}') orelse return error.InvalidTemplate;
            if (i > literal_start) try list.append(gpa, .{ .literal = try gpa.dupe(u8, text[literal_start..i]) });
            const name = text[i + 1 .. close];
            const seg: Segment = blk: {
                if (std.mem.eql(u8, name, "channel")) break :blk .channel;
                if (std.mem.eql(u8, name, "op")) break :blk .op;
                if (mongodb and std.mem.eql(u8, name, "db")) break :blk .db;
                if (mongodb and std.mem.eql(u8, name, "collection")) break :blk .collection;
                if (mongodb and std.mem.eql(u8, name, "key")) break :blk .key;
                if (std.mem.startsWith(u8, name, "data.") and name.len > 5) {
                    const field = name[5..];
                    if (std.mem.indexOfAny(u8, field, "{}") != null) return error.InvalidTemplate;
                    break :blk .{ .data_field = try gpa.dupe(u8, field) };
                }
                return error.InvalidTemplate;
            };
            try list.append(gpa, seg);
            fixed = false;
            i = close + 1;
            literal_start = i;
        }
        if (text.len > literal_start) try list.append(gpa, .{ .literal = try gpa.dupe(u8, text[literal_start..]) });
        const segments = try list.toOwnedSlice(gpa);
        const prefix: []const u8 = if (segments.len > 0 and segments[0] == .literal) segments[0].literal else "";
        return .{ .segments = segments, .prefix = prefix, .fixed = fixed };
    }

    pub fn deinit(self: Template, gpa: std.mem.Allocator) void {
        for (self.segments) |seg| freeSegment(gpa, seg);
        gpa.free(self.segments);
    }

    /// The text with the placeholders filled, in `arena`; null when one
    /// cannot be (a `{data.x}` the data lacks, `{key}` on an event without
    /// one).
    pub fn render(self: Template, arena: std.mem.Allocator, vars: Vars) error{OutOfMemory}!?[]const u8 {
        if (self.fixed and self.segments.len == 1) return self.segments[0].literal;
        var out: std.ArrayList(u8) = .empty;
        for (self.segments) |seg| switch (seg) {
            .literal => |l| try out.appendSlice(arena, l),
            .channel => try out.appendSlice(arena, vars.channel),
            .op => try out.appendSlice(arena, vars.op),
            .db => try out.appendSlice(arena, vars.db orelse return null),
            .collection => try out.appendSlice(arena, vars.collection orelse return null),
            .key => try out.appendSlice(arena, vars.key orelse return null),
            .data_field => |name| {
                const v = (try dataField(arena, vars.data, name)) orelse return null;
                try out.appendSlice(arena, v);
            },
        };
        return out.items;
    }
};

fn freeSegment(gpa: std.mem.Allocator, seg: Segment) void {
    switch (seg) {
        .literal => |l| gpa.free(l),
        .data_field => |f| gpa.free(f),
        else => {},
    }
}

/// The top-level member `name` of the JSON object `data`, as text: a
/// string unescaped, a number or boolean as written. Null for any other
/// value, a missing member, or data that is not a JSON object.
pub fn dataField(arena: std.mem.Allocator, data: []const u8, name: []const u8) error{OutOfMemory}!?[]const u8 {
    var sc = std.json.Scanner.initCompleteInput(arena, data);
    defer sc.deinit();
    const first = sc.next() catch |err| return scanFailed(err);
    if (first != .object_begin) return null;
    while (true) {
        const key_tok = sc.nextAlloc(arena, .alloc_if_needed) catch |err| return scanFailed(err);
        const key = switch (key_tok) {
            .string, .allocated_string => |s| s,
            else => return null,
        };
        const match = std.mem.eql(u8, key, name);
        const kind = sc.peekNextTokenType() catch |err| return scanFailed(err);
        switch (kind) {
            .object_begin, .array_begin => {
                if (match) return null;
                sc.skipValue() catch |err| return scanFailed(err);
            },
            else => {
                const tok = sc.nextAlloc(arena, .alloc_if_needed) catch |err| return scanFailed(err);
                if (!match) continue;
                return switch (tok) {
                    .string, .allocated_string => |s| s,
                    .number, .allocated_number => |s| s,
                    .true => "true",
                    .false => "false",
                    else => null,
                };
            },
        }
    }
}

fn scanFailed(err: anyerror) error{OutOfMemory}!?[]const u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return null;
}

test "Template: placeholders, prefix, fixed text" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = try Template.parse(gpa, "room:{data.room}:{op}", false);
    defer t.deinit(gpa);
    try std.testing.expectEqualStrings("room:", t.prefix);
    try std.testing.expect(!t.fixed);
    const got = (try t.render(arena, .{ .data = "{\"room\": \"lobby\", \"n\": 3}", .op = "insert" })).?;
    try std.testing.expectEqualStrings("room:lobby:insert", got);
    // A missing field skips.
    try std.testing.expect((try t.render(arena, .{ .data = "{\"x\": 1}" })) == null);
    try std.testing.expect((try t.render(arena, .{ .data = "not json" })) == null);

    const fixed = try Template.parse(gpa, "orders", false);
    defer fixed.deinit(gpa);
    try std.testing.expect(fixed.fixed);
    try std.testing.expectEqualStrings("orders", (try fixed.render(arena, .{})).?);

    const starts = try Template.parse(gpa, "{channel}", false);
    defer starts.deinit(gpa);
    try std.testing.expectEqualStrings("", starts.prefix);
    try std.testing.expectEqualStrings("a.b", (try starts.render(arena, .{ .channel = "a.b" })).?);

    // MongoDB-only placeholders.
    try std.testing.expectError(error.InvalidTemplate, Template.parse(gpa, "{key}", false));
    const m = try Template.parse(gpa, "{db}.{collection}/{key}", true);
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("app.users/7", (try m.render(arena, .{ .db = "app", .collection = "users", .key = "7" })).?);
    try std.testing.expect((try m.render(arena, .{ .db = "app", .collection = "users" })) == null);
}

test "Template: bad templates" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "{", "a{b", "{nope}", "x}y", "{data.}", "{data.a{b}}", "{}" }) |bad| {
        try std.testing.expectError(error.InvalidTemplate, Template.parse(gpa, bad, true));
    }
}

test "dataField: strings unescaped, numbers and booleans as written, nested skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json = "{\"obj\": {\"room\": \"nested\"}, \"arr\": [1, 2], \"room\": \"a\\\"b\", \"n\": 12.5, \"ok\": true, \"nil\": null}";
    try std.testing.expectEqualStrings("a\"b", (try dataField(a, json, "room")).?);
    try std.testing.expectEqualStrings("12.5", (try dataField(a, json, "n")).?);
    try std.testing.expectEqualStrings("true", (try dataField(a, json, "ok")).?);
    try std.testing.expect((try dataField(a, json, "nil")) == null);
    try std.testing.expect((try dataField(a, json, "obj")) == null);
    try std.testing.expect((try dataField(a, json, "arr")) == null);
    try std.testing.expect((try dataField(a, json, "missing")) == null);
    try std.testing.expect((try dataField(a, "[1]", "x")) == null);
    try std.testing.expect((try dataField(a, "", "x")) == null);
}

test "fuzz: template parser and data scan" {
    try @import("../fuzz.zig").bytes(fuzzCheck, &.{ "room:{data.room}", "{channel}{op}", "{", "}{", "{data.a}{data.b}", "{\"room\": \"x\"}" });
}

fn fuzzCheck(input: []const u8) anyerror!void {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The same bytes as a template and as data.
    if (Template.parse(gpa, input, true)) |t| {
        defer t.deinit(gpa);
        _ = try t.render(arena, .{ .channel = "c", .op = "o", .db = "d", .collection = "x", .key = "k", .data = "{\"room\": \"r\"}" });
        try std.testing.expect(t.prefix.len <= input.len);
    } else |err| switch (err) {
        error.InvalidTemplate => {},
        error.OutOfMemory => return err,
    }
    _ = try dataField(arena, input, "room");
}
