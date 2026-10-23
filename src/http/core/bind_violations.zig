// Adapted from vkiryakov/zefir src/http/input/violations.zig and dto.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The violations of mapping the input into a DTO: a
//! value of the wrong type, a field that is missing, a field the DTO does
//! not have. Like the validator's, they name fields by their outside names
//! and stop at `v.max_report_violations`; a request with more still gets
//! 422 with the first ones. Shared by the string sources and JSON.
const std = @import("std");
const v = @import("validate");

const Violation = v.Violation;

/// What happens to a field of the input that the DTO does not have: the
/// request is refused (422, `http.unknown_field`) or the field ignored.
/// A DTO says it with `pub const unknown_fields = .reject;`.
pub const UnknownFields = enum { reject, ignore };

pub const invalid_type = "http.invalid_type";
pub const missing_field = "http.missing_field";
pub const unknown_field = "http.unknown_field";

/// The messages of the mapping, without the field's name.
pub const messages = struct {
    pub const required = "is required";
    pub const unknown = "unknown field";
    pub const integer = "must be an integer";
    pub const number = "must be a number";
    pub const boolean = "must be true, false, 1 or 0";
    pub const once = "must be given once";
    pub const true_or_false = "must be true or false";
    pub const string = "must be a string";
    pub const array = "must be an array";
    pub const object = "must be an object";

    /// "must be one of low, normal, high": the variants of `E`.
    pub fn oneOf(comptime E: type) []const u8 {
        comptime {
            var text: []const u8 = "must be one of ";
            for (@typeInfo(E).@"enum".field_names, 0..) |name, i| {
                text = text ++ (if (i == 0) "" else ", ") ++ name;
            }
            return text;
        }
    }
};

/// Collects violations in a request's arena, at most
/// `v.max_report_violations` of them.
pub const Collector = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Violation) = .empty,
    /// There were more than `v.max_report_violations`: the rest were dropped.
    truncated: bool = false,

    pub fn init(arena: std.mem.Allocator) Collector {
        return .{ .arena = arena };
    }

    /// Adds a violation at `field`, an outside name or a path that lives as
    /// long as the request.
    pub fn add(c: *Collector, code: []const u8, message: []const u8, field: ?[]const u8) std.mem.Allocator.Error!void {
        if (c.full()) return;
        try c.list.append(c.arena, .{ .code = code, .message = message, .field = field });
    }

    /// Adds a violation at a copy of `path`, made only when the violation is
    /// kept; null for the root value.
    pub fn addCopy(c: *Collector, code: []const u8, message: []const u8, path: ?[]const u8) std.mem.Allocator.Error!void {
        if (c.full()) return;
        const field = if (path) |p| try c.arena.dupe(u8, p) else null;
        try c.list.append(c.arena, .{ .code = code, .message = message, .field = field });
    }

    /// Adds a violation at the item `index` of the list `name`: `tags[1]`.
    pub fn addItem(c: *Collector, code: []const u8, message: []const u8, name: []const u8, index: usize) std.mem.Allocator.Error!void {
        if (c.full()) return;
        try c.add(code, message, try std.fmt.allocPrint(c.arena, "{s}[{d}]", .{ name, index }));
    }

    /// Whether a violation of `code` at `field` is there already.
    pub fn has(c: *const Collector, code: []const u8, field: []const u8) bool {
        for (c.list.items) |item| {
            const at = item.field orelse continue;
            if (std.mem.eql(u8, item.code, code) and std.mem.eql(u8, at, field)) return true;
        }
        return false;
    }

    pub fn items(c: *const Collector) []const Violation {
        return c.list.items;
    }

    /// At the limit: what comes next is dropped and marks `truncated`.
    fn full(c: *Collector) bool {
        if (c.list.items.len < v.max_report_violations) return false;
        c.truncated = true;
        return true;
    }
};

const testing = std.testing;

test "violations stop at v.max_report_violations" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var c: Collector = .init(arena_state.allocator());
    for (0..150) |i| {
        if (i % 2 == 0)
            try c.add(invalid_type, messages.integer, "page")
        else
            try c.addItem(invalid_type, messages.integer, "ids", i);
    }
    try testing.expectEqual(v.max_report_violations, c.items().len);
    try testing.expect(c.truncated);
    try testing.expectEqualStrings("ids[1]", c.items()[1].field orelse "");
    try testing.expect(c.has(invalid_type, "page"));
    try testing.expect(!c.has(missing_field, "page"));
    try testing.expectEqualStrings("must be one of low, normal, high", comptime messages.oneOf(enum { low, normal, high }));
}
