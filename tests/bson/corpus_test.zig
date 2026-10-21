//! The BSON corpus of mongodb/specifications (source/bson-corpus), run as
//! its README (bson-corpus.md) says for a codec with a native form; here the
//! native form is the validated `Document` and "native to BSON" is
//! `bson.canonicalize`. The JSON files come from the pinned `mongodb_specs`
//! dependency (CC BY-NC-SA 3.0 US, so fetched, not vendored); build.zig
//! copies them next to this file as corpus/*.json.
//!
//! Not asserted: `converted_bson`/`converted_extjson` (deprecated types
//! turned into current ones), which the spec leaves optional; Anole reads
//! and writes the deprecated types as they are.
const std = @import("std");
const bson = @import("bson");

const testing = std.testing;
const gpa = testing.allocator;

const files = [_]struct { []const u8, []const u8 }{
    .{ "array", @embedFile("corpus/array.json") },
    .{ "binary", @embedFile("corpus/binary.json") },
    .{ "boolean", @embedFile("corpus/boolean.json") },
    .{ "code", @embedFile("corpus/code.json") },
    .{ "code_w_scope", @embedFile("corpus/code_w_scope.json") },
    .{ "datetime", @embedFile("corpus/datetime.json") },
    .{ "dbpointer", @embedFile("corpus/dbpointer.json") },
    .{ "dbref", @embedFile("corpus/dbref.json") },
    .{ "decimal128-1", @embedFile("corpus/decimal128-1.json") },
    .{ "decimal128-2", @embedFile("corpus/decimal128-2.json") },
    .{ "decimal128-3", @embedFile("corpus/decimal128-3.json") },
    .{ "decimal128-4", @embedFile("corpus/decimal128-4.json") },
    .{ "decimal128-5", @embedFile("corpus/decimal128-5.json") },
    .{ "decimal128-6", @embedFile("corpus/decimal128-6.json") },
    .{ "decimal128-7", @embedFile("corpus/decimal128-7.json") },
    .{ "document", @embedFile("corpus/document.json") },
    .{ "double", @embedFile("corpus/double.json") },
    .{ "int32", @embedFile("corpus/int32.json") },
    .{ "int64", @embedFile("corpus/int64.json") },
    .{ "maxkey", @embedFile("corpus/maxkey.json") },
    .{ "minkey", @embedFile("corpus/minkey.json") },
    .{ "multi-type", @embedFile("corpus/multi-type.json") },
    .{ "multi-type-deprecated", @embedFile("corpus/multi-type-deprecated.json") },
    .{ "null", @embedFile("corpus/null.json") },
    .{ "oid", @embedFile("corpus/oid.json") },
    .{ "regex", @embedFile("corpus/regex.json") },
    .{ "string", @embedFile("corpus/string.json") },
    .{ "symbol", @embedFile("corpus/symbol.json") },
    .{ "timestamp", @embedFile("corpus/timestamp.json") },
    .{ "top", @embedFile("corpus/top.json") },
    .{ "undefined", @embedFile("corpus/undefined.json") },
};

const Suite = struct {
    description: []const u8,
    bson_type: []const u8,
    valid: []const Valid = &.{},
    decodeErrors: []const DecodeErrorCase = &.{},
    parseErrors: []const ParseErrorCase = &.{},
};

const Valid = struct {
    description: []const u8,
    canonical_bson: []const u8,
    canonical_extjson: []const u8,
    relaxed_extjson: ?[]const u8 = null,
    degenerate_bson: ?[]const u8 = null,
    degenerate_extjson: ?[]const u8 = null,
    lossy: bool = false,
};

const DecodeErrorCase = struct { description: []const u8, bson: []const u8 };
const ParseErrorCase = struct { description: []const u8, string: []const u8 };

/// The pinned corpus's case counts: every case is either run or listed in
/// `skipped`, so a corpus bump that adds cases shows up here.
const expected = struct {
    const valid = 731;
    const decode_errors = 75;
    const parse_errors = 180;
};

/// Cases not run, with the reason. None at this pin.
const skipped = [_]struct { file: []const u8, description: []const u8, reason: []const u8 }{};

const Counts = struct { valid: usize = 0, decode_errors: usize = 0, parse_errors: usize = 0 };

test "bson-corpus: valid, decodeErrors and parseErrors" {
    var run: Counts = .{};
    var skip: Counts = .{};
    var failures: usize = 0;
    for (files) |file| {
        const name, const text = file;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const suite = try std.json.parseFromSliceLeaky(Suite, arena, text, .{ .ignore_unknown_fields = true });

        for (suite.valid) |case| {
            if (isSkipped(name, case.description)) {
                skip.valid += 1;
                continue;
            }
            run.valid += 1;
            runValid(arena, case) catch |err| {
                failures += 1;
                std.debug.print("bson-corpus {s}: valid \"{s}\" failed: {t}\n", .{ name, case.description, err });
            };
        }
        for (suite.decodeErrors) |case| {
            if (isSkipped(name, case.description)) {
                skip.decode_errors += 1;
                continue;
            }
            run.decode_errors += 1;
            if (bson.Document.init(try unhex(arena, case.bson))) |_| {
                failures += 1;
                std.debug.print("bson-corpus {s}: decodeError \"{s}\" was accepted\n", .{ name, case.description });
            } else |_| {}
        }
        for (suite.parseErrors) |case| {
            if (isSkipped(name, case.description)) {
                skip.parse_errors += 1;
                continue;
            }
            run.parse_errors += 1;
            runParseError(arena, suite.bson_type, case) catch |err| {
                failures += 1;
                std.debug.print("bson-corpus {s}: parseError \"{s}\" ({s}) failed: {t}\n", .{ name, case.description, case.string, err });
            };
        }
    }
    try testing.expectEqual(0, failures);
    try testing.expectEqual(expected.valid, run.valid + skip.valid);
    try testing.expectEqual(expected.decode_errors, run.decode_errors + skip.decode_errors);
    try testing.expectEqual(expected.parse_errors, run.parse_errors + skip.parse_errors);
    try testing.expectEqual(skipped.len, skip.valid + skip.decode_errors + skip.parse_errors);
}

fn isSkipped(file: []const u8, description: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, s.file, file) and std.mem.eql(u8, s.description, description)) return true;
    return false;
}

fn unhex(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try arena.alloc(u8, s.len / 2);
    return std.fmt.hexToBytes(out, s);
}

fn runValid(arena: std.mem.Allocator, case: Valid) !void {
    const cb = try unhex(arena, case.canonical_bson);
    const doc = try bson.Document.init(cb);

    // cB: native_to_bson(bson_to_native(cB)) = cB, and both JSON forms.
    try expectBytes(cb, try bson.canonicalize(arena, doc));
    try expectJson(arena, case.canonical_extjson, try bson.extjson.allocPrint(arena, doc, .canonical));
    if (case.relaxed_extjson) |rej| try expectJson(arena, rej, try bson.extjson.allocPrint(arena, doc, .relaxed));

    // cEJ: back to the same canonical JSON, and to cB unless lossy.
    const from_cej = try bson.extjson.parse(arena, case.canonical_extjson);
    try expectJson(arena, case.canonical_extjson, try bson.extjson.allocPrint(arena, try .init(from_cej), .canonical));
    if (!case.lossy) try expectBytes(cb, from_cej);

    // dB: re-encodes to cB.
    if (case.degenerate_bson) |dbh| {
        const db = try bson.Document.init(try unhex(arena, dbh));
        try expectBytes(cb, try bson.canonicalize(arena, db));
        try expectJson(arena, case.canonical_extjson, try bson.extjson.allocPrint(arena, db, .canonical));
    }
    // dEJ: to the canonical JSON, and to cB unless lossy.
    if (case.degenerate_extjson) |dej| {
        const from_dej = try bson.extjson.parse(arena, dej);
        try expectJson(arena, case.canonical_extjson, try bson.extjson.allocPrint(arena, try .init(from_dej), .canonical));
        if (!case.lossy) try expectBytes(cb, from_dej);
    }
    // rEJ: relaxed JSON survives a round trip.
    if (case.relaxed_extjson) |rej| {
        const from_rej = try bson.extjson.parse(arena, rej);
        try expectJson(arena, rej, try bson.extjson.allocPrint(arena, try .init(from_rej), .relaxed));
    }
}

fn runParseError(arena: std.mem.Allocator, bson_type: []const u8, case: ParseErrorCase) !void {
    if (std.mem.eql(u8, bson_type, "0x13")) {
        if (bson.Decimal128.parse(case.string)) |_| return error.Accepted else |_| return;
    }
    // Top-level documents (0x00) and binary (0x05): Extended JSON that is
    // valid JSON but not valid Extended JSON.
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, case.string, .{}) catch return error.NotJson;
    if (bson.extjson.parse(arena, case.string)) |_| return error.Accepted else |_| {}
}

fn expectBytes(expected_bytes: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected_bytes, actual)) {
        std.debug.print("expected {x}\n     got {x}\n", .{ expected_bytes, actual });
        return error.BsonMismatch;
    }
}

/// JSON equality as the corpus README asks: whitespace and escapes do not
/// matter, numbers compare by value (integers exactly, others as doubles),
/// and so do `$numberDouble` strings, whose spelling the spec leaves open.
/// Key order matters: wrappers are written in the spec's order.
fn expectJson(arena: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8) !void {
    const opts: std.json.ParseOptions = .{ .parse_numbers = false };
    const a = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected_text, opts);
    const b = std.json.parseFromSliceLeaky(std.json.Value, arena, actual_text, opts) catch {
        std.debug.print("not JSON: {s}\n", .{actual_text});
        return error.JsonMismatch;
    };
    if (!jsonEqual(a, b, "")) {
        std.debug.print("expected {s}\n     got {s}\n", .{ expected_text, actual_text });
        return error.JsonMismatch;
    }
}

fn jsonEqual(a: std.json.Value, b: std.json.Value, key: []const u8) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .number_string => |x| numbersEqual(x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string) or
            (std.mem.eql(u8, key, "$numberDouble") and doublesEqual(x, b.string)),
        .array => |x| {
            if (x.items.len != b.array.items.len) return false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q, "")) return false;
            return true;
        },
        .object => |x| {
            if (x.count() != b.object.count()) return false;
            for (x.keys(), x.values(), b.object.keys(), b.object.values()) |ka, va, kb, vb| {
                if (!std.mem.eql(u8, ka, kb) or !jsonEqual(va, vb, ka)) return false;
            }
            return true;
        },
        .integer, .float => unreachable,
    };
}

fn isInteger(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, ".eE") == null;
}

fn numbersEqual(a: []const u8, b: []const u8) bool {
    if (isInteger(a) != isInteger(b)) return false;
    if (isInteger(a)) {
        const x = std.fmt.parseInt(i128, a, 10) catch return false;
        const y = std.fmt.parseInt(i128, b, 10) catch return false;
        return x == y;
    }
    return doublesEqual(a, b);
}

fn doublesEqual(a: []const u8, b: []const u8) bool {
    const x = parseDouble(a) orelse return false;
    const y = parseDouble(b) orelse return false;
    if (std.math.isNan(x)) return std.math.isNan(y);
    return @as(u64, @bitCast(x)) == @as(u64, @bitCast(y));
}

fn parseDouble(s: []const u8) ?f64 {
    if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, s) catch null;
}
