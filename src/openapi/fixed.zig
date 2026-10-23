//! The components every document may hold besides the schemas of types:
//! `Error` (the default `{"error": ...}` body) and `Problem` (the 422
//! `application/problem+json` answer of `req.bind` and typed handlers). They
//! are written by hand and match `res.fail` and `res.problem`; the gRPC
//! ones (`ConnectError`, `Status`) are in proto.zig.
const json = @import("json.zig");

const Component = json.Component;

fn m(comptime key: []const u8, comptime value: json.Node) json.Member {
    return .{ .key = key, .value = value };
}
fn obj(comptime members: []const json.Member) json.Node {
    return .{ .object = members };
}
fn str(comptime s: []const u8) json.Node {
    return .{ .string = s };
}
fn typ(comptime t: []const u8) json.Node {
    return obj(&.{m("type", str(t))});
}

pub const error_body: Component = .{
    .name = "Error",
    .type_name = "anole.openapi.Error",
    .schema = obj(&.{
        m("type", str("object")),
        m("required", .{ .array = &.{str("error")} }),
        m("properties", obj(&.{m("error", typ("string"))})),
    }),
    .deps = &.{},
};

pub const problem: Component = .{
    .name = "Problem",
    .type_name = "anole.openapi.Problem",
    .schema = obj(&.{
        m("type", str("object")),
        m("description", str("An RFC 9457 problem document: what was wrong with the request.")),
        m("required", .{ .array = &.{ str("type"), str("title"), str("status") } }),
        m("properties", obj(&.{
            m("type", typ("string")),
            m("title", typ("string")),
            m("status", typ("integer")),
            m("detail", typ("string")),
            m("instance", typ("string")),
            m("errors", obj(&.{
                m("type", str("array")),
                m("items", obj(&.{
                    m("type", str("object")),
                    m("required", .{ .array = &.{ str("in"), str("code"), str("message") } }),
                    m("properties", obj(&.{
                        m("in", obj(&.{ m("type", str("string")), m("enum", .{ .array = &.{ str("body"), str("query"), str("header") } }) })),
                        m("field", typ("string")),
                        m("code", typ("string")),
                        m("message", typ("string")),
                    })),
                })),
            })),
            m("truncated", typ("boolean")),
        })),
    }),
    .deps = &.{},
};

fn errorFn() *const Component {
    return &error_body;
}
fn problemFn() *const Component {
    return &problem;
}

pub const error_ref: json.Node = .{ .ref = &errorFn };
pub const problem_ref: json.Node = .{ .ref = &problemFn };
