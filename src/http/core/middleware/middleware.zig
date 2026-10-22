// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

/// Cross-origin requests and preflights.
pub const Cors = @import("Cors.zig");
/// Response compression (zstd, Brotli, gzip) as the client accepts.
pub const Compress = @import("Compress.zig");
/// An ID per request, in `req.id` and a response header.
pub const RequestId = @import("RequestId.zig");
/// A log line per request, in scope `access`.
pub const Logger = @import("Logger.zig");
/// Sessions in a signed cookie (`req.session`).
pub const Session = @import("Session.zig");
