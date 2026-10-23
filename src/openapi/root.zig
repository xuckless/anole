//! OpenAPI 3.1 documents (`-Dopenapi`, on in the web and full profiles).
//!
//! What a document is made of is declared next to the code that has it: the
//! typed `pub const openapi` of a type (`Doc`), of a middleware
//! (`MiddlewareDoc`), and the texts of a route (`RouteDoc`, through
//! `anole.doc`). Constraints (`maxLength`, `minimum`, `required`, ...) are
//! never written there: they come from the types and the validator's rules.
//!
//! `app.openapi(.{})` serves the document and a Scalar page; the routes
//! record their comptime-built `Operation` as they are registered, and
//! `document.build` assembles the bytes when serving starts or when
//! `zig build openapi` runs the app.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");

const declarations = @import("declarations.zig");

pub const Doc = declarations.Doc;
pub const FieldDoc = declarations.FieldDoc;
pub const Example = declarations.Example;
pub const MiddlewareDoc = declarations.MiddlewareDoc;
pub const RouteDoc = declarations.RouteDoc;
pub const ResponseDoc = declarations.ResponseDoc;

/// The JSON tree a document is built as, and its writer.
pub const json = @import("json.zig");
/// The schemas of Zig types.
pub const schema = @import("schema.zig");
/// One operation of the document and the helpers around it.
pub const operation = @import("operation.zig");
/// What a middleware tells the document, as data.
pub const mw = @import("mw.zig");
/// The assembler.
pub const document = @import("document.zig");
/// The components written by hand (`Error`, `Problem`).
pub const fixed = @import("fixed.zig");
/// The Scalar page.
pub const page = @import("page.zig");
/// Protobuf services (`-Dgrpc`).
pub const proto = if (features.grpc) @import("proto.zig") else struct {};

pub const ErrorFormat = dusty.ErrorFormat;

/// A function middleware with a `MiddlewareDoc`:
/// `app.use(anole.openapi.middleware(.{ ... }, requireKey))`.
pub fn middleware(comptime d: MiddlewareDoc, comptime f: anytype) MiddlewareFunc(d, f) {
    return .{};
}

/// The type `middleware` returns: the function middleware, with `d` as its
/// `openapi` declaration.
pub fn MiddlewareFunc(comptime d: MiddlewareDoc, comptime f: anytype) type {
    const Base = @import("../handlers.zig").Func(f);
    return struct {
        inner: Base = .{},
        pub const no_wait = Base.no_wait;
        pub const openapi: MiddlewareDoc = d;
        pub fn execute(self: *const @This(), req: *dusty.Request, res: *dusty.Response, chain: anytype) anyerror!void {
            return self.inner.execute(req, res, chain);
        }
    };
}

/// One recorded route (internal): what `Server.register` and `grpcOn` keep.
pub const Entry = struct {
    verb: operation.Verb,
    /// The OpenAPI form of the path (`/users/{id}`).
    path: []const u8,
    op: *const operation.Operation,
    /// The middleware of the route's chain, outermost first.
    middleware: []const *const mw.Info = &.{},
    /// gRPC entries: the method has a `google.api.http` annotation.
    annotated: bool = false,
    /// gRPC entries: the service's comment, the tag's description.
    tag_doc: ?[]const u8 = null,
};

pub const BuildError = error{ OpenApiNameClash, OutOfMemory };

/// `app.openapi`'s settings.
pub const Options = struct {
    info: Info = .{},
    /// `servers`; empty: none, so the page and clients use its own origin.
    servers: []const ServerEntry = &.{},
    /// Where the document is served.
    path: []const u8 = "/openapi.json",
    /// Where the Scalar page is served; null: no page.
    page: ?[]const u8 = "/docs",
    serve: Serve = .development,
    /// Serve only on the listener of this name (`Options.Listener.name`),
    /// 404 on the others; null: every listener.
    listener: ?[]const u8 = null,
    grpc: Grpc = .{},
    /// A route without `tags` is tagged by its first path segment that is
    /// not "api" or a version ("v1", "v2beta"): /api/v1/users/:id -> "users".
    tags_from_path: bool = true,
    /// Descriptions of tags (shown as section intros on the page).
    tags: []const TagEntry = &.{},
    /// Schema names for types you can't annotate (generated protobuf
    /// messages): `.{ .type_name = "billing_pb.Invoice", .name = "BillingInvoice" }`.
    /// `type_name` is `@typeName`, as the clash message prints it.
    rename: []const Rename = &.{},

    pub const Info = struct {
        title: []const u8 = "API",
        version: []const u8 = "0.0.0",
        summary: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };
    pub const ServerEntry = struct { url: []const u8, description: ?[]const u8 = null };
    pub const TagEntry = struct { name: []const u8, description: []const u8 };
    pub const Rename = struct { type_name: []const u8, name: []const u8 };
    pub const Serve = enum {
        /// Served when the server's environment is development.
        development,
        always,
        /// Never served; `zig build openapi` and `openapiDocument` still work.
        never,
    };
    pub const Grpc = struct {
        /// Which unary methods appear in Connect form (POST /pkg.Svc/Method,
        /// GET too for NO_SIDE_EFFECTS): those without a google.api.http
        /// annotation (each method appears once), all, or none.
        connect: enum { unannotated, all, none } = .unannotated,
        /// The REST bindings of google.api.http (when the registration transcodes).
        transcoded: bool = true,
    };
};

test {
    _ = declarations;
    _ = json;
    _ = @import("example.zig");
    _ = schema;
    _ = operation;
    _ = mw;
    _ = document;
    _ = fixed;
    _ = page;
    _ = proto;
}
