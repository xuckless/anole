// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Compresses every response that passes through it (sets `res.compress`),
//! as Fiber's compress middleware does: zstd, Brotli or gzip as the client
//! accepts and the build has, for compressible content types only, skipping
//! bodies too short to gain and responses that set their own
//! Content-Encoding, Content-Length or Content-Range. See `Response.compress`.
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const Compress = @This();

pub fn init() Compress {
    return .{};
}

pub fn execute(_: *const Compress, req: *Request, res: *Response, executor: anytype) !void {
    _ = req;
    res.compress = true;
    return executor.next();
}
