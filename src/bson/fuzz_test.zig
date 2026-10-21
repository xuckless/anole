//! Fuzz targets for the BSON reader, the Extended JSON parser and
//! Decimal128 strings (src/fuzz.zig, imported as "fuzz" by the bson test
//! build).
const std = @import("std");
const fuzz = @import("fuzz");
const document = @import("document.zig");
const mapping = @import("mapping.zig");
const extjson = @import("extjson.zig");
const Builder = @import("Builder.zig");
const Decimal128 = @import("Decimal128.zig");
const Document = document.Document;

const gpa = std.testing.allocator;

fn hex(comptime s: []const u8) *const [s.len / 2]u8 {
    return comptime blk: {
        var out: [s.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, s) catch unreachable;
        const final = out;
        break :blk &final;
    };
}

/// Touches every value, recursively: a validation gap would read out of
/// bounds here.
fn walk(doc: Document, depth: u32) !void {
    try std.testing.expect(depth <= document.default_max_depth);
    var it = doc.iterator();
    while (it.next()) |e| switch (e.value) {
        .document => |d| try walk(d, depth + 1),
        .array => |a| try walk(a.doc, depth + 1),
        .javascript_with_scope => |c| try walk(c.scope, depth + 1),
        .decimal128 => |d| {
            var buf: [Decimal128.max_string_len]u8 = undefined;
            _ = d.toString(&buf);
        },
        else => {},
    };
}

/// Extended JSON out, parsed back, out again: from the second round the
/// text must not change (the first may, when `$`-keyed documents read
/// back as typed values).
fn extJsonFixpoint(doc: Document, mode: extjson.Mode) !void {
    const j1 = try extjson.allocPrint(gpa, doc, mode);
    defer gpa.free(j1);
    const b2 = extjson.parse(gpa, j1) catch |err| return switch (err) {
        error.InvalidExtJson, error.DuplicateKey, error.TooDeep => {},
        else => err,
    };
    defer gpa.free(b2);
    const j2 = try extjson.allocPrint(gpa, try Document.init(b2), mode);
    defer gpa.free(j2);
    const b3 = extjson.parse(gpa, j2) catch |err| return switch (err) {
        error.TooDeep => {},
        else => err,
    };
    defer gpa.free(b3);
    const j3 = try extjson.allocPrint(gpa, try Document.init(b3), mode);
    defer gpa.free(j3);
    try std.testing.expectEqualStrings(j2, j3);
}

const Probe = struct {
    _id: ?document.Value = null,
    a: ?i64 = null,
    b: ?[]const u8 = null,
    c: ?struct { d: ?f64 = null } = null,
    e: ?[]const ?i32 = null,
    f: ?enum { x, y } = null,
};

test "fuzz: BSON documents: validate, walk, re-encode, Extended JSON" {
    try fuzz.bytes(struct {
        fn check(input: []const u8) !void {
            const doc = Document.init(input) catch return;
            try walk(doc, 0);

            // Canonical re-encoding is valid BSON and stable.
            const canon = try Builder.canonicalize(gpa, doc);
            defer gpa.free(canon);
            const again = try Builder.canonicalize(gpa, try Document.init(canon));
            defer gpa.free(again);
            try std.testing.expectEqualSlices(u8, canon, again);

            try extJsonFixpoint(doc, .canonical);
            try extJsonFixpoint(doc, .relaxed);

            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = mapping.decodeDocument(Probe, arena.allocator(), doc, .{}) catch {};
        }
    }.check, &.{
        hex("0500000000"),
        hex("2C00000010610001000000026200020000007800036300090000000864000100046500080000000A30000000"),
        hex("1D000000057800100000000473FFD26444B34C6990E8E7D1DFC035D400"),
        hex("13000000057800060000000202000000FFFF00"),
        hex("210000000F6100190000000500000061626364000C000000107800010000000000"),
        hex("1A0000000C610002000000620056E1FC72E0C917E9C471416100"),
        hex("100000000B6100616263006D69780000"),
        hex("100000001161002A00000015CD5B0700"),
        hex("18000000136400F2AF967ED05C82DE3297FF6FDE3CF22F00"),
        hex("1000000009610000DC1FD277E6000000"),
        hex("10000000016400000000000000F87F00"),
        hex("1b000000046100130000001030000a000000103000140000000000"),
        hex("08000000FF610000"),
    });
}

test "fuzz: Extended JSON parser" {
    try fuzz.bytes(struct {
        fn check(input: []const u8) !void {
            const bytes = extjson.parse(gpa, input) catch |err| return switch (err) {
                error.OutOfMemory => err,
                else => {},
            };
            defer gpa.free(bytes);
            // Whatever the parser accepts is valid BSON.
            const doc = try Document.init(bytes);
            try walk(doc, 0);
            try extJsonFixpoint(doc, .canonical);
        }
    }.check, &.{
        "{}",
        "{\"a\": 1, \"b\": [1.5, \"x\", null, true], \"c\": {\"d\": -9223372036854775808}}",
        "{\"o\": {\"$oid\": \"56e1fc72e0c917e9c4714161\"}, \"n\": {\"$numberLong\": \"42\"}}",
        "{\"d\": {\"$date\": \"2012-12-24T12:15:30.501Z\"}, \"t\": {\"$timestamp\": {\"t\": 1, \"i\": 2}}}",
        "{\"b\": {\"$binary\": {\"base64\": \"//8=\", \"subType\": \"02\"}}, \"u\": {\"$uuid\": \"73ffd264-44b3-4c69-90e8-e7d1dfc035d4\"}}",
        "{\"r\": {\"$regularExpression\": {\"pattern\": \"a\", \"options\": \"mix\"}}, \"m\": {\"$minKey\": 1}}",
        "{\"c\": {\"$code\": \"f\", \"$scope\": {\"x\": {\"$numberDecimal\": \"1.5E+3\"}}}}",
        "{\"p\": {\"$dbPointer\": {\"$ref\": \"b\", \"$id\": {\"$oid\": \"56e1fc72e0c917e9c4714161\"}}}}",
        "{\"x\": {\"$numberDouble\": \"-0.0\"}, \"y\": {\"$numberDouble\": \"NaN\"}, \"z\": {\"$undefined\": true}}",
        "{\"$regex\": {\"$regularExpression\": {\"pattern\": \"p\", \"options\": \"\"}}, \"$options\": \"ix\"}",
    });
}

test "fuzz: Decimal128 strings and raw values" {
    try fuzz.bytes(struct {
        fn check(input: []const u8) !void {
            var b1: [Decimal128.max_string_len]u8 = undefined;
            var b2: [Decimal128.max_string_len]u8 = undefined;
            var b3: [Decimal128.max_string_len]u8 = undefined;
            // Any string: parsing then printing is stable.
            if (Decimal128.parse(input)) |d| {
                const s1 = d.toString(&b1);
                const s2 = (try Decimal128.parse(s1)).toString(&b2);
                try std.testing.expectEqualStrings(s1, s2);
            } else |_| {}
            // Any 16 bytes print as something that parses, and settles.
            if (input.len >= 16) {
                const s1 = Decimal128.fromBytes(input[0..16].*).toString(&b1);
                const s2 = (try Decimal128.parse(s1)).toString(&b2);
                const s3 = (try Decimal128.parse(s2)).toString(&b3);
                try std.testing.expectEqualStrings(s2, s3);
            }
        }
    }.check, &.{
        "0",
        "-0.0",
        "1.23E+5",
        "0.000001234567890123456789012345678901234",
        "1E6112",
        "0E-2147483647",
        "-Infinity",
        "NaN",
        "1.1111111111111111111111111111123450",
        "9.999999999999999999999999999999999E+6144",
        hex("F2AF967ED05C82DE3297FF6FDE3CF22F"),
        hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFF116C"),
    });
}
