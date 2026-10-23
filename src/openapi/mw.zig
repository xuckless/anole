//! What a middleware tells the document, in a form the program can keep:
//! `MiddlewareDoc` holds types (`query: type`), which exist only at compile
//! time, so each declaration is turned into an `Info` of plain data (JSON
//! nodes, parameters, responses) and the middleware handle points at it.
const std = @import("std");
const json = @import("json.zig");
const operation = @import("operation.zig");
const declarations = @import("declarations.zig");
const schema = @import("schema.zig");

const MiddlewareDoc = declarations.MiddlewareDoc;

pub const Scheme = struct {
    name: []const u8,
    /// The scheme's definition for `components.securitySchemes`.
    definition: json.Node,
};

pub const Info = struct {
    schemes: []const Scheme = &.{},
    /// What a route behind it requires: null, any scheme declared before it
    /// in the chain, or those named.
    security: ?MiddlewareDoc.Security = null,
    roles: []const []const u8 = &.{},
    params: []const operation.Operation.Param = &.{},
    responses: []const operation.Operation.Response = &.{},
};

fn s(comptime v: []const u8) json.Node {
    return .{ .string = v };
}

fn m(comptime k: []const u8, comptime v: json.Node) json.Member {
    return .{ .key = k, .value = v };
}

fn flowNode(comptime f: MiddlewareDoc.Flow) json.Node {
    var members: []const json.Member = &.{};
    if (f.authorization_url) |u| members = members ++ [_]json.Member{m("authorizationUrl", s(u))};
    if (f.token_url) |u| members = members ++ [_]json.Member{m("tokenUrl", s(u))};
    if (f.refresh_url) |u| members = members ++ [_]json.Member{m("refreshUrl", s(u))};
    var scopes: []const json.Member = &.{};
    for (f.scopes) |sc| scopes = scopes ++ [_]json.Member{m(sc.name, s(sc.description))};
    members = members ++ [_]json.Member{m("scopes", .{ .object = scopes })};
    return .{ .object = members };
}

fn schemeNode(comptime sc: MiddlewareDoc.SecurityScheme) json.Node {
    var members: []const json.Member = &.{};
    switch (sc.kind) {
        .http => |h| {
            members = members ++ [_]json.Member{ m("type", s("http")), m("scheme", s(h.scheme)) };
            if (h.bearer_format) |b| members = members ++ [_]json.Member{m("bearerFormat", s(b))};
        },
        .api_key => |k| members = members ++ [_]json.Member{ m("type", s("apiKey")), m("in", s(@tagName(k.in))), m("name", s(k.param)) },
        .oauth2 => |o| {
            var flows: []const json.Member = &.{};
            if (o.flows.implicit) |f| flows = flows ++ [_]json.Member{m("implicit", flowNode(f))};
            if (o.flows.password) |f| flows = flows ++ [_]json.Member{m("password", flowNode(f))};
            if (o.flows.client_credentials) |f| flows = flows ++ [_]json.Member{m("clientCredentials", flowNode(f))};
            if (o.flows.authorization_code) |f| flows = flows ++ [_]json.Member{m("authorizationCode", flowNode(f))};
            members = members ++ [_]json.Member{ m("type", s("oauth2")), m("flows", .{ .object = flows }) };
        },
        .open_id_connect => |o| members = members ++ [_]json.Member{ m("type", s("openIdConnect")), m("openIdConnectUrl", s(o.url)) },
        .mutual_tls => members = members ++ [_]json.Member{m("type", s("mutualTLS"))},
    }
    if (sc.description) |d| members = members ++ [_]json.Member{m("description", s(d))};
    return .{ .object = members };
}

fn phrase(comptime code: u16) []const u8 {
    const status: std.http.Status = @fromBackingInt(@intCast(code));
    return status.phrase() orelse "Response";
}

/// The `Info` of a declaration, one value per use at compile time.
pub fn infoOf(comptime d: MiddlewareDoc) *const Info {
    const H = struct {
        const value: Info = blk: {
            @setEvalBranchQuota(1_000_000);
            var schemes: []const Scheme = &.{};
            for (d.security_schemes) |sc| schemes = schemes ++ [_]Scheme{.{ .name = sc.name, .definition = schemeNode(sc) }};
            var responses: []const operation.Operation.Response = &.{};
            for (@typeInfo(MiddlewareDoc.Responses).@"struct".field_names) |name| {
                const r = @field(d.responses, name) orelse continue;
                const code: u16 = @backingInt(@field(std.http.Status, name));
                var one: operation.Operation.Response = .{ .status = code, .description = r.description orelse phrase(code) };
                if (r.json != void) {
                    one.contents = &.{.{ .content_type = "application/json", .schema = schema.schemaOf(r.json) }};
                } else if (r.content_type) |ct| {
                    one.contents = &.{.{ .content_type = ct, .schema = .{ .object = &.{m("type", s("string"))} } }};
                }
                responses = responses ++ [_]operation.Operation.Response{one};
            }
            break :blk .{
                .schemes = schemes,
                .security = d.security,
                .roles = d.roles,
                .params = operation.paramsOf(d.query, .query) ++ operation.paramsOf(d.headers, .header) ++ operation.paramsOf(d.cookies, .cookie),
                .responses = responses,
            };
        };
    };
    return &H.value;
}

/// The `Info` of a middleware type that declares `pub const openapi`, or
/// null. A declaration of another type stops the build.
pub fn infoOfType(comptime T: type) ?*const Info {
    if (!@hasDecl(T, "openapi")) return null;
    if (@TypeOf(T.openapi) != MiddlewareDoc)
        @compileError(@typeName(T) ++ ".openapi must be an anole.openapi.MiddlewareDoc");
    return infoOf(T.openapi);
}
