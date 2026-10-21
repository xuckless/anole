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

/// The element type byte.
pub const Type = document.Type;
/// One BSON value, tagged by its `Type`.
pub const Value = document.Value;
/// A key and its value, as a document's iterator returns them.
pub const Element = document.Element;
/// A validated, read-only document over its bytes: `Document.init(bytes)`,
/// then `get`, `getPath` or `iterator`.
pub const Document = document.Document;
/// A BSON array (a document keyed "0", "1", ...): `at`, `iterator`.
pub const Array = document.Array;
/// Walks a document's elements in order.
pub const Iterator = document.Iterator;
/// Binary data with its subtype.
pub const Binary = document.Binary;
/// A regular expression value.
pub const Regex = document.Regex;
/// Deprecated reference type: a namespace and an ObjectId.
pub const DbPointer = document.DbPointer;
/// JavaScript code with a scope (deprecated, still readable).
pub const CodeWithScope = document.CodeWithScope;
/// MongoDB's internal timestamp (seconds and an ordinal), not a date:
/// dates are `Datetime`.
pub const Timestamp = document.Timestamp;
/// A UTC date, milliseconds since the Unix epoch (MongoDB's `Date`).
pub const Datetime = document.Datetime;
/// Why `Document.init` refused bytes.
pub const DecodeError = document.DecodeError;
/// The nesting limit `Document.init` applies (200, MongoDB's own).
pub const default_max_depth = document.default_max_depth;

/// A 12-byte MongoDB ObjectId: `generate`, `parse` from hex, `toHex`.
pub const ObjectId = @import("ObjectId.zig");
/// IEEE 754 decimal128, as BSON stores it: `parse`, `toString`.
pub const Decimal128 = @import("Decimal128.zig");
/// Writes BSON into a growing buffer, document by document.
pub const Builder = @import("Builder.zig");
/// MongoDB Extended JSON v2: `fmt` and `allocPrint` to write it (relaxed
/// or canonical), `parse` to read it back to BSON.
pub const extjson = @import("extjson.zig");

/// How an enum is written (`EncodeOptions.enums`, or an enum's own
/// `pub const bson_enum`).
pub const EnumRepr = mapping.EnumRepr;
/// How `encode` writes: null optionals left out or written, enums by
/// name or value.
pub const EncodeOptions = mapping.EncodeOptions;
/// How `decode` reads: strings copied into the arena or not, unknown
/// fields skipped or refused.
pub const DecodeOptions = mapping.DecodeOptions;
/// What encoding fails with.
pub const EncodeError = mapping.EncodeError;
/// Why a document does not map onto a Zig type.
pub const MappingError = mapping.MappingError;
/// A Zig value (a struct or anonymous literal) as a BSON document, owned
/// by the caller: `bson.encode(gpa, .{ .name = "Ada" }, .{})`.
pub const encode = mapping.encode;
/// Appends a value's fields to the document a `Builder` has open.
pub const appendFields = mapping.appendFields;
/// Appends one element named `name` to the document a `Builder` has open.
pub const appendField = mapping.appendField;
/// Validates bytes and maps the document onto `T`, strings copied into
/// the arena: `bson.decode(User, arena, bytes, .{})`.
pub const decode = mapping.decode;
/// `decode` from a `Document` already validated.
pub const decodeDocument = mapping.decodeDocument;
/// One `Value` as a `T`.
pub const decodeValue = mapping.decodeValue;
/// A document re-encoded in the spec's canonical form (array keys "0",
/// "1", ..., regex flags sorted), owned by the caller.
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
