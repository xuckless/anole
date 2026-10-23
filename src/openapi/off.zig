//! `anole.openapi` in a build without `-Dopenapi`: the declaration types, so
//! `pub const openapi: anole.openapi.Doc(@This()) = ...` in user types and in
//! the built-in middleware compiles in every profile, and `middleware`, which
//! then returns the plain function middleware. Everything that builds a
//! document is absent (`app.openapi` is a compile error).
const declarations = @import("declarations.zig");

pub const Doc = declarations.Doc;
pub const FieldDoc = declarations.FieldDoc;
pub const Example = declarations.Example;
pub const MiddlewareDoc = declarations.MiddlewareDoc;
pub const RouteDoc = declarations.RouteDoc;
pub const ResponseDoc = declarations.ResponseDoc;

/// A function middleware with a `MiddlewareDoc`: in a build without
/// `-Dopenapi` the document is dropped and the function is the middleware.
/// (The tooling lane's second part makes this `anole.func(f)`.)
pub fn middleware(comptime doc: MiddlewareDoc, comptime f: anytype) @TypeOf(f) {
    _ = doc;
    return f;
}

test {
    @import("std").testing.refAllDecls(@This());
}
