//! The syntax of a route pattern, as a pure check that runs at compile time
//! (the route methods of `anole.Server`) and at run time (`addRoute`, static
//! prefixes, the C ABI's routes, the router's registration).
//!
//! A pattern starts with '/', and its segments are literals, `:name`
//! parameters and a final `*name` wildcard. It is refused when it has no
//! leading '/', an empty parameter name, a name holding ':' or '*', a
//! wildcard that is not the last segment, a parameter name twice, or a '?'
//! or '#'.

const std = @import("std");

pub const Problem = union(enum) {
    no_leading_slash,
    /// ":" or "*" alone.
    empty_name,
    /// A name holding ':' or '*'.
    bad_name: []const u8,
    /// The wildcard's name.
    wildcard_not_last: []const u8,
    duplicate_name: []const u8,
    /// '?' or '#'.
    query_or_fragment,

    /// "a wildcard (*rest) must be the last segment".
    pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .no_leading_slash => try w.writeAll("must start with '/'"),
            .empty_name => try w.writeAll("has an empty parameter name (':' or '*' alone)"),
            .bad_name => |n| try w.print("parameter name \"{s}\" holds ':' or '*'", .{n}),
            .wildcard_not_last => |n| try w.print("a wildcard (*{s}) must be the last segment", .{n}),
            .duplicate_name => |n| try w.print("names the parameter \"{s}\" twice", .{n}),
            .query_or_fragment => try w.writeAll("has '?' or '#': a route matches the path only (read the query with req.query, req.bindQuery or anole.In(.{ .query = T }))"),
        }
    }
};

/// Why `path` is not a valid pattern, or null.
pub fn problem(path: []const u8) ?Problem {
    if (path.len == 0 or path[0] != '/') return .no_leading_slash;
    if (std.mem.findAny(u8, path, "?#") != null) return .query_or_fragment;
    var segments = std.mem.splitScalar(u8, path, '/');
    var wildcard: ?[]const u8 = null;
    var index: usize = 0;
    while (segments.next()) |segment| : (index += 1) {
        if (segment.len == 0) continue;
        if (wildcard) |w| return .{ .wildcard_not_last = w };
        const marker = segment[0];
        if (marker != ':' and marker != '*') continue;
        const name = segment[1..];
        if (name.len == 0) return .empty_name;
        if (std.mem.findAny(u8, name, ":*") != null) return .{ .bad_name = name };
        if (marker == '*') wildcard = name;
        // A name seen before in this path.
        var earlier = std.mem.splitScalar(u8, path, '/');
        var j: usize = 0;
        while (earlier.next()) |other| : (j += 1) {
            if (j >= index) break;
            if (other.len > 1 and (other[0] == ':' or other[0] == '*') and std.mem.eql(u8, other[1..], name))
                return .{ .duplicate_name = name };
        }
    }
    return null;
}

/// The parameter and wildcard names of a valid pattern, in order.
pub fn paramNames(comptime path: []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            if (segment.len > 1 and (segment[0] == ':' or segment[0] == '*')) names = names ++ [_][]const u8{segment[1..]};
        }
        return names;
    }
}

/// Run-time `paramNames` into `out` (names beyond its length are counted but
/// not stored); the count.
pub fn collectParamNames(path: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len > 1 and (segment[0] == ':' or segment[0] == '*')) {
            if (n < out.len) out[n] = segment[1..];
            n += 1;
        }
    }
    return n;
}

/// The problem's text, at compile time.
pub fn comptimeMessage(comptime p: Problem) []const u8 {
    return switch (p) {
        .no_leading_slash => "must start with '/'",
        .empty_name => "has an empty parameter name (':' or '*' alone)",
        .bad_name => |n| "parameter name \"" ++ n ++ "\" holds ':' or '*'",
        .wildcard_not_last => |n| "a wildcard (*" ++ n ++ ") must be the last segment",
        .duplicate_name => |n| "names the parameter \"" ++ n ++ "\" twice",
        .query_or_fragment => "has '?' or '#': a route matches the path only (read the query with req.query, req.bindQuery or anole.In(.{ .query = T }))",
    };
}

const testing = std.testing;

fn expectProblem(path: []const u8, expected: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    if (problem(path)) |p| {
        var w: std.Io.Writer = .fixed(&buf);
        try p.format(&w);
        try testing.expectEqualStrings(expected orelse return error.TestUnexpectedResult, w.buffered());
    } else try testing.expectEqual(@as(?[]const u8, null), expected);
}

test "problem: a table of good and bad patterns with their messages" {
    try expectProblem("/", null);
    try expectProblem("/users/:id", null);
    try expectProblem("/users/:id/posts/:post", null);
    try expectProblem("/static/*path", null);
    try expectProblem("/a//b", null);
    try expectProblem("/a:b/c*d", null);
    try expectProblem("users", "must start with '/'");
    try expectProblem("", "must start with '/'");
    try expectProblem("/a/:", "has an empty parameter name (':' or '*' alone)");
    try expectProblem("/a/*", "has an empty parameter name (':' or '*' alone)");
    try expectProblem("/a/:x:y", "parameter name \"x:y\" holds ':' or '*'");
    try expectProblem("/a/*x/b", "a wildcard (*x) must be the last segment");
    try expectProblem("/a/:id/b/:id", "names the parameter \"id\" twice");
    try expectProblem("/a/:id/*id", "names the parameter \"id\" twice");
    try expectProblem("/a?x=1", "has '?' or '#': a route matches the path only (read the query with req.query, req.bindQuery or anole.In(.{ .query = T }))");
    try expectProblem("/a#top", "has '?' or '#': a route matches the path only (read the query with req.query, req.bindQuery or anole.In(.{ .query = T }))");
}

test "problem runs at comptime" {
    comptime std.debug.assert(problem("/a/*x/b") != null);
    comptime std.debug.assert(problem("/a/:x") == null);
    try testing.expectEqualStrings("a wildcard (*x) must be the last segment", comptime comptimeMessage(problem("/a/*x/b").?));
}

test "paramNames in order" {
    const names = comptime paramNames("/a/:x/b/*rest");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("x", names[0]);
    try testing.expectEqualStrings("rest", names[1]);
    try testing.expectEqual(@as(usize, 0), (comptime paramNames("/plain")).len);
}

test "collectParamNames matches paramNames" {
    var out: [4][]const u8 = undefined;
    const n = collectParamNames("/a/:x/b/*rest", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("x", out[0]);
    try testing.expectEqualStrings("rest", out[1]);
}

fn fuzzPattern(bytes: []const u8) !void {
    if (problem(bytes)) |p| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        p.format(&w) catch {};
    } else {
        var out: [64][]const u8 = undefined;
        const n = collectParamNames(bytes, &out);
        // A valid pattern has distinct names.
        for (0..@min(n, out.len)) |i| for (0..i) |j| try testing.expect(!std.mem.eql(u8, out[i], out[j]));
    }
}

test "fuzz: route_pattern.problem" {
    try @import("fuzz.zig").bytes(fuzzPattern, &.{ "/", "/a/:id", "/a/*x/b", "/a/:id/:id", "/x?y" });
}
