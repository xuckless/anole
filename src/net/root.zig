//! Raw network I/O: the outbound streams the database clients and brokers
//! connect with (`ClientStream`), and with `-Dnet` raw TCP and UDP servers
//! on the server's runtime and listeners (p3/net).
const features = @import("build_options");

/// A connected stream: `connect`, then its reader and writer.
pub const ClientStream = @import("client_stream.zig").ClientStream;
/// Where and how `ClientStream.connect` connects.
pub const ConnectOptions = @import("client_stream.zig").ConnectOptions;

// The server API (design-net.md §2): raw TCP and UDP servers on Anole's
// listeners. The types are always compiled (pure Zig, no C library); the
// server's `tcp`/`udp` methods and its listeners need `-Dnet`.

const tcp_mod = @import("tcp.zig");
const udp_mod = @import("udp_service.zig");

/// How a TCP listener cuts its input into messages: lines, length
/// prefixes or varints.
pub const Framing = tcp_mod.Framing;
pub const FrameIterator = tcp_mod.FrameIterator;
/// A TCP listener's options (`Tcp.Options`).
pub const Tcp = tcp_mod.Tcp;
/// The connection a TCP handler sees.
pub const Conn = tcp_mod.Conn;
pub const CloseReason = tcp_mod.CloseReason;
pub const Input = tcp_mod.Input;
pub const TcpTable = tcp_mod.TcpTable;
pub const TcpService = tcp_mod.TcpService;
/// A TCP service for `Listener.tcp` (what `app.tcp` builds).
pub const tcp = tcp_mod.tcp;
pub const TcpListener = tcp_mod.TcpListener;

/// A UDP listener's options (`Udp.Options`, `Udp.Sessions`).
pub const Udp = udp_mod.Udp;
pub const Datagram = udp_mod.Datagram;
pub const UdpSocket = udp_mod.UdpSocket;
pub const Session = udp_mod.Session;
pub const UdpTable = udp_mod.UdpTable;
pub const UdpService = udp_mod.UdpService;
pub const UdpGroup = udp_mod.UdpGroup;
/// A UDP service for `Listener.udp` (what `app.udp` builds).
pub const udp = udp_mod.udp;

/// Counters over every raw listener (`Server.netStats`).
pub const Stats = struct {
    /// TCP connections open now.
    connections: u64 = 0,
    connections_total: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    datagrams_in: u64 = 0,
    datagrams_out: u64 = 0,
    datagrams_dropped: u64 = 0,
    sessions: u64 = 0,
};

test {
    _ = @import("client_stream.zig");
    _ = @import("scram.zig");
    _ = @import("framing.zig");
    _ = @import("sessions.zig");
    _ = @import("tcp.zig");
    _ = @import("udp_service.zig");
    _ = @import("tcp_test.zig");
    _ = @import("udp_test.zig");
    if (features.http3 or features.net) _ = @import("udp.zig");
}
