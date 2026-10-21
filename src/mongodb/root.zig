//! MongoDB for Anole's handlers (`-Dmongodb`, in the full profile): a
//! client of Anole's own on std.Io, following the drivers' specifications.
//! This part: the wire protocol, the connection string, SCRAM, the
//! topology state machine and one connection's handshake.
const std = @import("std");

pub const uri = @import("uri.zig");
pub const scram = @import("scram.zig");
pub const wire = @import("wire.zig");
pub const sdam = @import("sdam.zig");
pub const connection = @import("connection.zig");

test {
    _ = uri;
    _ = scram;
    _ = wire;
    _ = sdam;
    _ = connection;
}
