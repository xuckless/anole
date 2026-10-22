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

/// Brotli's quality for this middleware's responses.
brotli_quality: ?u4 = null,

/// `init`'s settings.
pub const Options = struct {
    /// Brotli's quality (0 to 11) for responses compressed as `br`. Null:
    /// the server's `response.brotli_quality`.
    brotli_quality: ?u4 = null,
};

/// The middleware: `app.use(anole.middleware.Compress.init(.{}))`.
pub fn init(options: Options) Compress {
    return .{ .brotli_quality = options.brotli_quality };
}

/// Only sets a flag before `next()`: requests behind it can detach
/// (`Detached`).
pub const detach_safe = true;

/// Never waits: no I/O, so `no_wait` routes may sit behind it.
pub const no_wait = true;

pub fn execute(self: *const Compress, req: *Request, res: *Response, next: anytype) !void {
    _ = req;
    res.compress = true;
    if (self.brotli_quality) |q| res._brotli_quality = q;
    return next.call();
}
