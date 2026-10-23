//! Raw network I/O: the outbound streams the database clients and brokers
//! connect with (`ClientStream`), and with `-Dnet` raw TCP and UDP servers
//! on the server's runtime and listeners (p3/net).
const features = @import("build_options");

/// A connected stream: `connect`, then its reader and writer.
pub const ClientStream = @import("client_stream.zig").ClientStream;
/// Where and how `ClientStream.connect` connects.
pub const ConnectOptions = @import("client_stream.zig").ConnectOptions;

// The server API (design-net.md §2) goes below, each name behind
// `features.net` with a stub without it, as `anole.openapi` does.

test {
    _ = @import("client_stream.zig");
    _ = @import("scram.zig");
    if (features.http3 or features.net) _ = @import("udp.zig");
}
