//! OpenAPI 3.1 documents (`-Dopenapi`, on in the web and full profiles).
//!
//! What a document is made of is declared next to the code that has it: the
//! typed `pub const openapi` of a type (`Doc`), of a middleware
//! (`MiddlewareDoc`), and the texts of a route (`RouteDoc`, through
//! `anole.doc`). Constraints (`maxLength`, `minimum`, `required`, ...) are
//! never written there: they come from the types.
//!
//! This is the first part of the module: the declarations, the JSON tree and
//! its writer, schemas of Zig types and of protobuf messages, and operations.
//! The assembler, `Options` and `app.openapi` come with the second part.
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
/// The Scalar page.
pub const page = @import("page.zig");
/// Protobuf services (`-Dgrpc`).
pub const proto = if (features.grpc) @import("proto.zig") else struct {};

test {
    _ = declarations;
    _ = json;
    _ = @import("example.zig");
    _ = schema;
    _ = operation;
    _ = page;
    _ = proto;
}
