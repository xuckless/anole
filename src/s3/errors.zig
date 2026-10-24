//! S3's error codes as `anole.db` classes, and which failures are transient
//! (design-connectors.md S9, S10).
const std = @import("std");
const db = @import("../db/root.zig");

/// The class of an error answer. `status` is the HTTP status, `code` S3's
/// `<Code>` (empty for a HEAD answer, which has no body).
pub fn classify(status: u16, code: []const u8) db.Class {
    const is = struct {
        fn any(c: []const u8, names: []const []const u8) bool {
            for (names) |n| if (std.mem.eql(u8, c, n)) return true;
            return false;
        }
    }.any;
    if (is(code, &.{ "SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout", "ThrottlingException", "RequestLimitExceeded", "Throttling" })) return .unavailable;
    if (is(code, &.{ "NoSuchKey", "NoSuchBucket", "NoSuchUpload", "NoSuchVersion" })) return .not_found;
    if (is(code, &.{ "PreconditionFailed", "ConditionalRequestConflict" })) return .precondition;
    if (is(code, &.{ "InvalidRange", "KeyTooLongError", "InvalidArgument", "EntityTooSmall", "EntityTooLarge", "InvalidPart", "InvalidPartOrder", "InvalidBucketName", "MissingContentLength" })) return .invalid;
    switch (status) {
        500, 502, 503, 504 => return .unavailable,
        404 => return if (code.len == 0) .not_found else .other,
        412 => return .precondition,
        416 => return .invalid,
        else => return .other,
    }
}

/// Whether the failure may pass on a second try (the S9 list); the
/// connector's guard reads the class `unavailable` for this.
pub fn transientStatus(status: u16, code: []const u8) bool {
    return classify(status, code) == .unavailable;
}

/// The message to log and to show a developer for an error answer.
pub fn explain(buf: []u8, code: []const u8, message: []const u8, region: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "PermanentRedirect") or std.mem.eql(u8, code, "AuthorizationHeaderMalformed") or std.mem.eql(u8, code, "IllegalLocationConstraintException")) {
        if (region.len > 0) return std.fmt.bufPrint(buf, "{s} (the bucket is in region {s}; set AWS_REGION or Options.region)", .{ message, region }) catch message;
    }
    return message;
}

const testing = std.testing;

test "errors: S3 codes to classes, every row" {
    const Case = struct { u16, []const u8, db.Class };
    for ([_]Case{
        .{ 404, "NoSuchKey", .not_found },
        .{ 404, "NoSuchBucket", .not_found },
        .{ 404, "NoSuchUpload", .not_found },
        .{ 404, "NoSuchVersion", .not_found },
        .{ 404, "", .not_found },
        .{ 412, "PreconditionFailed", .precondition },
        .{ 409, "ConditionalRequestConflict", .precondition },
        .{ 416, "InvalidRange", .invalid },
        .{ 400, "KeyTooLongError", .invalid },
        .{ 400, "InvalidArgument", .invalid },
        .{ 400, "EntityTooSmall", .invalid },
        .{ 400, "InvalidPart", .invalid },
        .{ 400, "InvalidPartOrder", .invalid },
        .{ 500, "InternalError", .unavailable },
        .{ 502, "", .unavailable },
        .{ 503, "SlowDown", .unavailable },
        .{ 503, "ServiceUnavailable", .unavailable },
        .{ 504, "", .unavailable },
        .{ 400, "RequestTimeout", .unavailable },
        .{ 403, "AccessDenied", .other },
        .{ 403, "SignatureDoesNotMatch", .other },
        .{ 403, "InvalidAccessKeyId", .other },
        .{ 301, "PermanentRedirect", .other },
        .{ 409, "BucketAlreadyOwnedByYou", .other },
    }) |c| try testing.expectEqual(c[2], classify(c[0], c[1]));
}

test "errors: 503 SlowDown and 500 are transient; 404 and 412 are not; 403 fails" {
    try testing.expect(transientStatus(503, "SlowDown"));
    try testing.expect(transientStatus(500, "InternalError"));
    try testing.expect(!transientStatus(404, "NoSuchKey"));
    try testing.expect(!transientStatus(412, "PreconditionFailed"));
    try testing.expect(!transientStatus(403, "AccessDenied"));
}

test "errors: a redirect names the region" {
    var buf: [200]u8 = undefined;
    try testing.expectEqualStrings("The bucket you are attempting to access must be addressed using the specified endpoint. (the bucket is in region eu-west-1; set AWS_REGION or Options.region)", explain(&buf, "PermanentRedirect", "The bucket you are attempting to access must be addressed using the specified endpoint.", "eu-west-1"));
}
