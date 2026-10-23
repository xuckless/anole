//! One operation of the document (a route's method + path): a static tree of
//! JSON nodes the assembler reads at run time. This file holds the types the
//! gRPC mapper (`proto.zig`) and the typed-handler mapper fill, and the small
//! helpers both share. `forHandler` over `anole.routeInfo` comes with the
//! tooling lane's second part.
const std = @import("std");
const json = @import("json.zig");

/// The HTTP methods an OpenAPI path item can hold, in the order the document
/// lists them (QUERY has no place in 3.1).
pub const Verb = enum { get, put, post, delete, options, head, patch, trace };

pub const Operation = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Empty: from the path (`Options.tags_from_path`).
    tags: []const []const u8 = &.{},
    /// Null: generated from the method and path (`operationId`).
    operation_id: ?[]const u8 = null,
    deprecated: bool = false,
    /// Path, query and header parameters.
    params: []const Param = &.{},
    body: ?Body = null,
    responses: []const Response = &.{},
    /// Path parameters in the path but not in `params` are plain strings
    /// (plain handlers): the assembler adds them from the path.
    kind: Kind = .rest,
    /// gRPC entries only: the full service name (the tag) and the id base
    /// ("Greeter_SayHello").
    grpc_service: ?[]const u8 = null,

    pub const Kind = enum { rest, connect, transcoded };

    pub const In = enum { path, query, header };

    pub const Param = struct {
        name: []const u8,
        in: In,
        required: bool,
        schema: json.Node,
        description: ?[]const u8 = null,
        deprecated: bool = false,
        /// `style: form, explode: true` is the OpenAPI default for query
        /// arrays; set when a query array must say it explicitly.
        explode: bool = false,
        /// An `x-anole-rest-of-path` marker (transcoding's `**`).
        rest_of_path: bool = false,
    };

    pub const Body = struct { required: bool, content_type: []const u8, schema: json.Node };

    pub const Response = struct {
        /// 0: the `default` response.
        status: u16,
        description: []const u8,
        contents: []const Content = &.{},
        headers: []const Header = &.{},
    };

    pub const Content = struct { content_type: []const u8, schema: json.Node };
    pub const Header = struct { name: []const u8, description: []const u8, schema: json.Node };
};

/// The OpenAPI form of a router path: `:name` and `*name` segments become
/// `{name}`. `/users/:id/files/*path` -> `/users/{id}/files/{path}`.
pub fn openApiPath(comptime path: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (!first) out = out ++ "/";
            first = false;
            if (seg.len > 1 and (seg[0] == ':' or seg[0] == '*')) {
                out = out ++ "{" ++ seg[1..] ++ "}";
            } else if (seg.len == 1 and seg[0] == '*') {
                out = out ++ "{wildcard}";
            } else out = out ++ seg;
        }
        return out;
    }
}

/// The default `operationId` of a route: the method in lower case and the
/// path's segments in camel case, parameters as `By<Name>`:
/// `GET /users/:id/posts` -> `getUsersByIdPosts`.
pub fn operationId(comptime method: []const u8, comptime path: []const u8) []const u8 {
    comptime {
        var out: []const u8 = method;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| {
            var name = seg;
            var prefix: []const u8 = "";
            if (name.len > 0 and (name[0] == ':' or name[0] == '*' or name[0] == '{')) {
                prefix = "By";
                name = std.mem.trim(u8, name, ":*{}");
            }
            out = out ++ prefix ++ camel(name);
        }
        return out;
    }
}

/// `name` with each word (split at non-alphanumerics) capitalised.
fn camel(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                upper = true;
                continue;
            }
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

/// The tag a route gets from its path (`Options.tags_from_path`): its first
/// segment that is not "api" or a version ("v1", "v2beta").
/// `/api/v1/users/:id` -> "users". Null when there is none.
pub fn tagFromPath(path: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == '{' or seg[0] == ':' or seg[0] == '*') return null;
        if (std.mem.eql(u8, seg, "api")) continue;
        if (isVersion(seg)) continue;
        return seg;
    }
    return null;
}

fn isVersion(seg: []const u8) bool {
    if (seg.len < 2 or seg[0] != 'v') return false;
    var i: usize = 1;
    while (i < seg.len and std.ascii.isDigit(seg[i])) i += 1;
    if (i == 1) return false;
    for (seg[i..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

test "openApiPath: params and wildcards" {
    try std.testing.expectEqualStrings("/users/{id}/files/{path}", comptime openApiPath("/users/:id/files/*path"));
    try std.testing.expectEqualStrings("/", comptime openApiPath("/"));
    try std.testing.expectEqualStrings("/a/{wildcard}", comptime openApiPath("/a/*"));
}

test "operationId: method and camel-case path, parameters as By<Name>" {
    try std.testing.expectEqualStrings("getUsersByIdPosts", comptime operationId("get", "/users/:id/posts"));
    try std.testing.expectEqualStrings("postApiV1TodoItems", comptime operationId("post", "/api/v1/todo-items"));
    try std.testing.expectEqualStrings("getFilesByPath", comptime operationId("get", "/files/{path}"));
    try std.testing.expectEqualStrings("get", comptime operationId("get", "/"));
}

test "tagFromPath: the first segment that is not api or a version" {
    try std.testing.expectEqualStrings("users", tagFromPath("/api/v1/users/{id}").?);
    try std.testing.expectEqualStrings("users", tagFromPath("/users").?);
    try std.testing.expectEqualStrings("health", tagFromPath("/v2beta/health").?);
    try std.testing.expectEqualStrings("videos", tagFromPath("/videos").?);
    try std.testing.expectEqual(null, tagFromPath("/"));
    try std.testing.expectEqual(null, tagFromPath("/{id}"));
    try std.testing.expectEqual(null, tagFromPath("/api/v1"));
}
