//! One operation of the document (a route's method + path): a static tree of
//! JSON nodes the assembler reads at run time. This file holds the types the
//! gRPC mapper (`proto.zig`) and the typed-handler mapper fill, and the small
//! helpers both share, and `forHandler`, which builds the operation of a
//! route handler from `anole.routeInfo` and the handler's `anole.doc`.
const std = @import("std");
const dusty = @import("dusty");
const json = @import("json.zig");
const schema = @import("schema.zig");
const example = @import("example.zig");
const fixed = @import("fixed.zig");
const declarations = @import("declarations.zig");
const typed = @import("../typed.zig");
const handlers = @import("../handlers.zig");

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

    pub const In = enum { path, query, header, cookie };

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
        /// The server's default error body (`{"error": ...}` and/or text,
        /// by `ServerOptions.errors`); the assembler fills the contents.
        error_body: bool = false,
    };

    pub const Content = struct { content_type: []const u8, schema: json.Node };
    pub const Header = struct { name: []const u8, description: []const u8, schema: json.Node };
};

// ------------------------------------------------------------------ handlers

fn typeOnly(comptime t: []const u8) json.Node {
    return .{ .object = &.{.{ .key = "type", .value = .{ .string = t } }} };
}

fn phrase(comptime code: u16) []const u8 {
    const status: std.http.Status = @fromBackingInt(@intCast(code));
    return status.phrase() orelse "Response";
}

fn hasStatus(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "anole_status");
}

fn paramName(comptime Dto: type, comptime field: []const u8, comptime in: Operation.In) []const u8 {
    return switch (in) {
        .path, .cookie => field,
        .query => example.outsideName(Dto, field),
        .header => if (dusty.input.strings.hasRename(Dto, field)) example.outsideName(Dto, field) else dusty.input.strings.headerName(field),
    };
}

/// The parameters of the fields of `Dto`, read from `in`.
pub fn paramsOf(comptime Dto: type, comptime in: Operation.In) []const Operation.Param {
    comptime {
        if (Dto == void) return &.{};
        var out: []const Operation.Param = &.{};
        for (@typeInfo(Dto).@"struct".field_names) |name| {
            const pi = schema.paramOf(Dto, name);
            out = out ++ [_]Operation.Param{.{
                .name = paramName(Dto, name, in),
                .in = in,
                .required = in == .path or pi.required,
                .schema = pi.schema,
                .description = pi.description,
                .deprecated = pi.deprecated,
                .explode = pi.is_list and in == .query,
            }};
        }
        return out;
    }
}

fn pushResponse(comptime list: []const Operation.Response, comptime r: Operation.Response) []const Operation.Response {
    for (list) |have| if (have.status == r.status) return list;
    return list ++ [_]Operation.Response{r};
}

fn sortByStatus(comptime list: []const Operation.Response) []const Operation.Response {
    var out: [list.len]Operation.Response = undefined;
    @memcpy(&out, list);
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        var j = i;
        while (j > 0 and out[j - 1].status > out[j].status) : (j -= 1) {
            const t = out[j];
            out[j] = out[j - 1];
            out[j - 1] = t;
        }
    }
    const final = out;
    return &final;
}

/// The operation of the route handler `handler` (as `app.get` takes it,
/// markers included), built at compile time.
pub fn forHandler(comptime handler: anytype) Operation {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const info = typed.routeInfo(handler);
        const texts = handlers.routeDoc(handler);
        const F = handlers.Unwrapped(@TypeOf(handler));
        const sh = typed.shapeOf(F);
        if (info.typed and (texts.body != void or texts.query != void or texts.headers != void or texts.response != void or texts.errors != error{}))
            @compileError("anole.doc: this handler's signature already says its inputs, output and errors (" ++ @typeName(F) ++ "); " ++
                "leave .body, .query, .headers, .response and .errors out and keep the texts");
        const query_t = if (info.typed) info.query else texts.query;
        const headers_t = if (info.typed) info.headers else texts.headers;
        const body_t = if (info.typed) info.body else texts.body;
        const out_t = if (info.typed) info.output else texts.response;
        const errors_t: ?type = if (info.typed) info.errors else texts.errors;

        const success: u16 = if (info.typed) blk: {
            if (hasStatus(sh.Out)) break :blk @backingInt(sh.Out.anole_status);
            if (sh.Out == void and !sh.takes_res) break :blk 204;
            break :blk 200;
        } else @backingInt(texts.status);

        var responses: []const Operation.Response = &.{};
        var ok: Operation.Response = .{ .status = success, .description = if (success == 200) "OK" else phrase(success) };
        if (out_t != void) ok.contents = &.{.{ .content_type = "application/json", .schema = schema.schemaOf(out_t) }};
        if (info.typed and hasStatus(sh.Out) and success == 201)
            ok.headers = &.{.{ .name = "Location", .description = "The new resource.", .schema = typeOnly("string") }};
        responses = pushResponse(responses, ok);
        if (body_t != void) responses = pushResponse(responses, .{ .status = 400, .description = "Malformed request body", .error_body = true });
        if (info.path != void) responses = pushResponse(responses, .{ .status = 404, .description = "Not Found", .error_body = true });
        if (body_t != void or query_t != void or headers_t != void)
            responses = pushResponse(responses, .{
                .status = 422,
                .description = "Unprocessable Entity",
                .contents = &.{.{ .content_type = "application/problem+json", .schema = fixed.problem_ref }},
            });
        if (errors_t) |E| {
            if (@typeInfo(E) == .error_set) {
                if (@typeInfo(E).error_set.error_names) |names| for (names) |name| {
                    const code = dusty.comptimeErrorStatus(name) orelse continue;
                    responses = pushResponse(responses, .{ .status = code, .description = phrase(code), .error_body = true });
                };
            }
        }
        for (texts.responses) |r| {
            const code: u16 = @backingInt(r.status);
            var one: Operation.Response = .{ .status = code, .description = r.description orelse phrase(code) };
            if (r.json != void) {
                one.contents = &.{.{ .content_type = "application/json", .schema = schema.schemaOf(r.json) }};
            } else if (r.content_type) |ct| {
                const binary = !(std.mem.startsWith(u8, ct, "text/") or std.mem.indexOf(u8, ct, "json") != null or std.mem.indexOf(u8, ct, "xml") != null);
                one.contents = &.{.{ .content_type = ct, .schema = if (binary)
                    .{ .object = &.{ .{ .key = "type", .value = .{ .string = "string" } }, .{ .key = "format", .value = .{ .string = "binary" } } } }
                else
                    typeOnly("string") }};
            }
            responses = pushResponse(responses, one);
        }

        const params = paramsOf(info.path, .path) ++ paramsOf(query_t, .query) ++ paramsOf(headers_t, .header);
        return .{
            .summary = texts.summary,
            .description = texts.description,
            .tags = texts.tags,
            .operation_id = texts.operation_id,
            .deprecated = texts.deprecated,
            .params = params,
            .body = if (body_t != void) .{ .required = true, .content_type = "application/json", .schema = schema.schemaOf(body_t) } else null,
            .responses = sortByStatus(responses),
        };
    }
}

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

/// `openApiPath` at run time (a group's prefix is only known then), in `a`.
pub fn openApiPathAlloc(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(a, '/');
        first = false;
        if (seg.len > 1 and (seg[0] == ':' or seg[0] == '*')) {
            try out.append(a, '{');
            try out.appendSlice(a, seg[1..]);
            try out.append(a, '}');
        } else if (seg.len == 1 and seg[0] == '*') {
            try out.appendSlice(a, "{wildcard}");
        } else try out.appendSlice(a, seg);
    }
    return out.items;
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
