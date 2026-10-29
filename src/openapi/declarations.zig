// Adapted from vkiryakov/zefir src/openapi/openapi.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.

//! The declarations of an OpenAPI document: the typed `pub const openapi` of
//! types and middleware, and the texts of a route. `anole.openapi` re-exports
//! them (and `off.zig` re-exports the same types in builds without
//! `-Dopenapi`, so declarations compile in every profile).
const std = @import("std");

/// The texts and examples of a DTO, an enum or a `union(enum)`:
/// `pub const openapi: anole.openapi.Doc(@This()) = .{ ... }`.
///
/// - `.name`: the name of its schema in the document, instead of the last
///   part of the type's name (`Page_TodoResponse` for
///   `Page(dto.TodoResponse)`);
/// - `.description`;
/// - `.example`: a value of the type, which the document shows as the
///   server writes it; `.examples`: named values, which a request or a
///   response with a body of the type shows;
/// - `.deprecated`;
/// - `.fields`: the texts of each field of a struct, or of each variant of a
///   union: `.fields = .{ .title = .{ .description = "What to do." } }`.
///   An enum has no `.fields`.
///
/// A type that writes itself, with a `jsonStringify` of its own, says what
/// its JSON looks like in `.as`, a type of the same JSON: `.as = []const u8`.
/// Its JSON exists only at run time, so it has no `.example` and no
/// `.fields`.
pub fn Doc(comptime T: type) type {
    if (writesItself(T)) return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        deprecated: bool = false,
        /// The type whose JSON this type writes: its schema is the
        /// type's.
        as: type,
    };
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (!s.is_tuple) return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
            fields: Fields = .{},

            /// A field for each field of the struct.
            pub const Fields = @Struct(.auto, null, s.field_names, &fieldDocTypes(s.field_types), &noDocs(s.field_types));
        },
        .@"union" => |u| if (u.tag_type != null) return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
            fields: Fields = .{},

            /// A field for each variant of the union.
            pub const Fields = @Struct(.auto, null, u.field_names, &fieldDocTypes(u.field_types), &noDocs(u.field_types));
        },
        .@"enum" => return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            example: ?T = null,
            examples: []const Example(T) = &.{},
            deprecated: bool = false,
        },
        else => {},
    }
    @compileError("anole.openapi: Doc takes a struct, an enum or a union(enum), the types of JSON values; got " ++ @typeName(T));
}

/// The texts of a field of a struct or a variant of a union, of type `F`:
/// `.description`, `.example` (a value of `F`), `.examples` (more values)
/// and `.deprecated`. A field of a type that writes itself has no examples:
/// its JSON exists only at run time.
pub fn FieldDoc(comptime F: type) type {
    if (writesItself(F)) return struct {
        description: ?[]const u8 = null,
        deprecated: bool = false,
    };
    return struct {
        description: ?[]const u8 = null,
        example: ?F = null,
        examples: []const F = &.{},
        deprecated: bool = false,
    };
}

/// A named example of a body of type `T`, which a request or a response
/// shows under `name`.
pub fn Example(comptime T: type) type {
    return struct {
        name: []const u8,
        summary: ?[]const u8 = null,
        value: T,
    };
}

/// A route's texts and, for a plain `(req, res)` handler, its types: pass it
/// to `anole.doc(.{ ... }, handler)`. Every field is optional.
pub const RouteDoc = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Replaces the tag taken from the path (`Options.tags_from_path`).
    tags: []const []const u8 = &.{},
    /// Default: method + path in camel case ("getUsersByIdPosts").
    operation_id: ?[]const u8 = null,
    deprecated: bool = false,
    /// Left out of the document.
    hidden: bool = false,
    // For plain (req, res) handlers only; on a typed handler each of these is
    // a compile error ("the handler's signature already says it").
    body: type = void,
    query: type = void,
    headers: type = void,
    response: type = void,
    status: std.http.Status = .ok,
    errors: type = error{},
    /// More responses, for both handler kinds: a 304, a redirect, a text answer.
    responses: []const ResponseDoc = &.{},
};

/// An extra response of a route (`RouteDoc.responses`).
pub const ResponseDoc = struct {
    status: std.http.Status,
    description: ?[]const u8 = null,
    /// A JSON body type, or void for none.
    json: type = void,
    /// A non-JSON body: its content type (schema: string; binary for non-text).
    content_type: ?[]const u8 = null,
};

/// What a middleware tells the document: `pub const openapi:
/// anole.openapi.MiddlewareDoc = .{ ... }` in its type. A middleware that
/// is a function has no declarations: make it a type with `pub fn run`.
///
/// - `.security_schemes`: how it knows the client, each under its name;
/// - `.security`: a route behind it requires one of the schemes declared
///   before it in its chain, `.any`, or of those named, `.{ .schemes =
///   &.{"bearer"} }`;
/// - `.roles`: the roles it requires, added to each scheme of the
///   requirement;
/// - `.query`, `.headers`, `.cookies`: the DTOs it reads, which become
///   parameters of every route behind it;
/// - `.responses`: the responses it writes itself, with `.handled`, such as
///   a 304 or a 429, in the form of a route's `.responses`.
///
/// The server reads `.query`, `.headers`, `.cookies` and `.responses` by
/// their names for its check in Debug, without importing this module.
pub const MiddlewareDoc = struct {
    security_schemes: []const SecurityScheme = &.{},
    security: ?Security = null,
    roles: []const []const u8 = &.{},
    query: type = void,
    headers: type = void,
    cookies: type = void,
    responses: Responses = .{},

    /// A way of signing in, under `name` in the document's
    /// `securitySchemes`.
    pub const SecurityScheme = struct { name: []const u8, description: ?[]const u8 = null, kind: Kind };
    pub const Kind = union(enum) { http: Http, api_key: ApiKey, oauth2: OAuth2, open_id_connect: OpenIdConnect, mutual_tls };
    /// `Authorization: <scheme> ...`: `.scheme = "bearer"`.
    pub const Http = struct { scheme: []const u8, bearer_format: ?[]const u8 = null };
    /// A key in a header, the query or a cookie of the name `param`.
    pub const ApiKey = struct { in: enum { header, query, cookie }, param: []const u8 };
    pub const OAuth2 = struct { flows: Flows };
    pub const Flows = struct { implicit: ?Flow = null, password: ?Flow = null, client_credentials: ?Flow = null, authorization_code: ?Flow = null };
    pub const Flow = struct { authorization_url: ?[]const u8 = null, token_url: ?[]const u8 = null, refresh_url: ?[]const u8 = null, scopes: []const Scope = &.{} };
    pub const Scope = struct { name: []const u8, description: []const u8 };
    pub const OpenIdConnect = struct { url: []const u8 };
    /// What a route behind the middleware requires: any scheme declared
    /// before it in the chain, or those named.
    pub const Security = union(enum) { any, schemes: []const []const u8 };
    /// A field for each status of `std.http.Status`, null for those the
    /// middleware does not answer with.
    pub const Responses = @Struct(.auto, null, status_names, &@as([status_names.len]type, @splat(?Response)), &noMiddlewareResponses());
    /// A response the middleware writes itself: `.{}` without a body,
    /// `.content_type` of a body it writes, or `.json`, the type of a JSON
    /// one.
    pub const Response = struct { description: ?[]const u8 = null, content_type: ?[]const u8 = null, json: type = void };

    const status_names = @typeInfo(std.http.Status).@"enum".field_names;

    fn noMiddlewareResponses() [status_names.len]std.lang.Type.Struct.FieldAttributes {
        const none: ?Response = null;
        return @splat(.{ .default_value_ptr = &none });
    }
};

/// Whether values of `T`, inside optionals, write themselves with a
/// `jsonStringify` of their own, as `std.json.Value` does.
pub fn writesItself(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| writesItself(o.child),
        .@"struct", .@"union", .@"enum" => std.meta.hasFn(T, "jsonStringify"),
        else => false,
    };
}

/// The `FieldDoc` of each field. Its own quota: the compiler evaluates the
/// declaration of `Fields` with the default one, whoever names `Doc(T)`.
fn fieldDocTypes(comptime types: []const type) [types.len]type {
    @setEvalBranchQuota(1_000 + 100 * types.len);
    var out: [types.len]type = undefined;
    for (types, &out) |F, *Doc_| Doc_.* = FieldDoc(F);
    return out;
}

/// The attributes of the fields of `Fields`: the default of each is its
/// `FieldDoc` with nothing in it, `.{}`.
fn noDocs(comptime types: []const type) [types.len]std.lang.Type.Struct.FieldAttributes {
    @setEvalBranchQuota(1_000 + 100 * types.len);
    var out: [types.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (types, &out) |F, *attrs| {
        const empty: FieldDoc(F) = .{};
        attrs.* = .{ .default_value_ptr = &empty };
    }
    return out;
}

const testing = std.testing;

// Application code of the tests: zefir ships no DTO, controller or
// middleware.
const Priority = enum { low, normal, high };
const Shape = union(enum) { circle: u32, none };
const Todo = struct {
    id: u64,
    title: []const u8,
    priority: Priority = .normal,
    comptime version: u32 = 1,
};
/// A type that writes itself, as a string.
const Money = struct {
    cents: u64,
    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}.{d:0>2}\"", .{ self.cents / 100, self.cents % 100 });
    }
};

test "Doc: a struct's texts, examples and a field doc for each field" {
    const D = Doc(Todo);
    const doc: D = .{
        .description = "A todo.",
        .example = .{ .id = 1, .title = "Buy milk" },
        .examples = &.{.{ .name = "urgent", .value = .{ .id = 2, .title = "Call back", .priority = .high } }},
        .fields = .{ .title = .{ .description = "What to do.", .example = "Buy milk" } },
    };
    try testing.expectEqualStrings("Buy milk", doc.example.?.title);
    try testing.expectEqualStrings("urgent", doc.examples[0].name);
    // A field doc for every field, the comptime one too; .{} for those left out.
    inline for (.{ "id", "title", "priority", "version" }) |name| try testing.expect(@hasField(D.Fields, name));
    try testing.expect(@FieldType(D.Fields, "id") == FieldDoc(u64));
    try testing.expectEqual(null, doc.fields.id.description);
    try testing.expectEqualStrings("What to do.", doc.fields.title.description.?);
    try testing.expect(!doc.deprecated and doc.name == null);
}

/// A struct of `n` fields of u8, `f0` and on: a type of many fields of an
/// application.
fn Wide(comptime n: usize) type {
    @setEvalBranchQuota(10_000 + 1_000 * n);
    var names: [n][:0]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("f{d}", .{i});
    const types: [n]type = @splat(u8);
    const attrs: [n]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, &names, &types, &attrs);
}

test "Doc: a type of many fields has a field doc for each, without a quota of the application's own" {
    const D = Doc(Wide(200));
    try testing.expectEqual(200, @typeInfo(D.Fields).@"struct".field_names.len);
    const doc: D = .{ .fields = .{ .f199 = .{ .description = "The last." } } };
    try testing.expectEqualStrings("The last.", doc.fields.f199.description.?);
    try testing.expectEqual(null, doc.fields.f0.description);
}

test "Doc: a union's fields are its variants; an enum has none; a type that writes itself has .as" {
    try testing.expect(@FieldType(Doc(Shape).Fields, "circle") == FieldDoc(u32));
    try testing.expect(@FieldType(Doc(Shape).Fields, "none") == FieldDoc(void));
    try testing.expect(!@hasField(Doc(Priority), "fields") and @hasField(Doc(Priority), "example"));
    const money: Doc(Money) = .{ .description = "An amount of money.", .as = []const u8 };
    try testing.expect(money.as == []const u8);
    try testing.expect(!@hasField(Doc(Money), "example") and !@hasField(Doc(Money), "fields"));
    // A field of such a type has no examples either.
    try testing.expect(!@hasField(FieldDoc(?Money), "example") and @hasField(FieldDoc(?Money), "description"));
    try testing.expect(@FieldType(FieldDoc(?u8), "example") == ??u8);
}

test "MiddlewareDoc: security, input and a response for each status" {
    const doc: MiddlewareDoc = .{
        .security_schemes = &.{
            .{ .name = "bearer", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "opaque" } } },
            .{ .name = "session", .kind = .{ .api_key = .{ .in = .cookie, .param = "session" } } },
            .{ .name = "mtls", .kind = .mutual_tls },
        },
        .security = .any,
        .roles = &.{"todos"},
        .headers = struct { authorization: ?[]const u8 = null },
        .responses = .{ .not_modified = .{}, .unauthorized = .{ .content_type = "text/html" } },
    };
    try testing.expectEqual(3, doc.security_schemes.len);
    try testing.expect(doc.query == void and doc.cookies == void and doc.headers != void);
    try testing.expectEqualStrings("text/html", doc.responses.unauthorized.?.content_type.?);
    try testing.expect(doc.responses.not_modified.?.json == void);
    try testing.expectEqual(null, doc.responses.ok);
    try testing.expectEqual(@typeInfo(std.http.Status).@"enum".field_names.len, @typeInfo(MiddlewareDoc.Responses).@"struct".field_names.len);
}

test {
    std.testing.refAllDecls(@This());
}
