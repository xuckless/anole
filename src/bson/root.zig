//! BSON (https://bsonspec.org) for the MongoDB client: a validating
//! zero-copy reader, a builder, a compile-time mapping between Zig values
//! and documents, Decimal128 and ObjectId, and Extended JSON v2 in both
//! directions. Pure Zig; no allocation to read, one buffer to write.
//!
//!     // Write: structs and anonymous literals map to documents.
//!     const bytes = try bson.encode(gpa, .{ .name = "Ada", .age = .{ .@"$gte" = 18 } }, .{});
//!
//!     // Read: validate once, then iterate, look up or map onto a struct.
//!     const doc = try bson.Document.init(bytes);
//!     const age = doc.getPath("age.$gte").?.int32;
//!     const user = try bson.decode(User, arena, reply_bytes, .{});
//!
//!     // Log: relaxed Extended JSON by default, canonical on request.
//!     log.info("{f}", .{doc});
//!     log.info("{f}", .{bson.extjson.fmt(doc, .canonical)});
//!
//! Conformance: the bson-corpus of mongodb/specifications runs in
//! `zig build test` (tests/bson/corpus_test.zig).
const std = @import("std");
const document = @import("document.zig");
const mapping = @import("mapping.zig");

pub const Type = document.Type;
pub const Value = document.Value;
pub const Element = document.Element;
pub const Document = document.Document;
pub const Array = document.Array;
pub const Iterator = document.Iterator;
pub const Binary = document.Binary;
pub const Regex = document.Regex;
pub const DbPointer = document.DbPointer;
pub const CodeWithScope = document.CodeWithScope;
pub const Timestamp = document.Timestamp;
pub const Datetime = document.Datetime;
pub const DecodeError = document.DecodeError;
pub const default_max_depth = document.default_max_depth;

pub const ObjectId = @import("ObjectId.zig");
pub const Decimal128 = @import("Decimal128.zig");
pub const Builder = @import("Builder.zig");
pub const extjson = @import("extjson.zig");

pub const EnumRepr = mapping.EnumRepr;
pub const EncodeOptions = mapping.EncodeOptions;
pub const DecodeOptions = mapping.DecodeOptions;
pub const EncodeError = mapping.EncodeError;
pub const MappingError = mapping.MappingError;
pub const encode = mapping.encode;
pub const appendFields = mapping.appendFields;
pub const appendField = mapping.appendField;
pub const decode = mapping.decode;
pub const decodeDocument = mapping.decodeDocument;
pub const decodeValue = mapping.decodeValue;
pub const canonicalize = Builder.canonicalize;

test {
    _ = document;
    _ = mapping;
    _ = ObjectId;
    _ = Decimal128;
    _ = Builder;
    _ = extjson;
    _ = @import("fuzz_test.zig");
}
