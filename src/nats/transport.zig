//! The byte stream under a NATS connection: Anole's `ClientStream` (plain
//! TCP, upgraded to TLS after the server's INFO or TLS from the first
//! byte), read through a buffer big enough for the longest protocol line.
const std = @import("std");
const Io = std.Io;
const ClientStream = @import("../net/client_stream.zig").ClientStream;

/// A reader over `cs.reader()` with its own buffer (the parser needs the
/// longest line contiguous; the stream's own buffers are 16 KiB). The
/// stream is looked up on every fill, so a reader made before `startTls`
/// reads the TLS side afterwards.
pub const Reader = struct {
    cs: *ClientStream,
    interface: Io.Reader,

    pub fn init(cs: *ClientStream, buffer: []u8) Reader {
        return .{
            .cs = cs,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Reader = @fieldParentPtr("interface", r);
        return self.cs.reader().stream(w, limit);
    }
};
