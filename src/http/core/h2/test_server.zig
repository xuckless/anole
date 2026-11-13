//! Tests only: a server's connections served by the engine in server.zig,
//! which `Server.run` does not pick yet (it still runs the nghttp2 engine
//! until the switch). A loopback listener whose accept loop hands each
//! connection, as HTTP/2 with prior knowledge, to `Engine(Ctx).serve`, on
//! the runtime's executors in turn, so the suites with their own clients
//! (websocket/h2_test.zig, grpc/server_test.zig) can run on the engine.
const std = @import("std");
const engine = @import("server.zig");
const server_mod = @import("../server.zig");
const Listener = @import("../config.zig").Listener;
const placement = @import("../placement.zig");

pub fn Serving(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const Server = server_mod.Server(Ctx);
        const E = engine.Engine(Ctx);

        server: *Server,
        tcp: std.Io.net.Server,
        /// Where clients connect.
        address: std.Io.net.IpAddress,
        listener: Listener,
        connections: std.Io.Group = .init,
        accepting: std.Io.Group = .init,

        /// Listens on a loopback port and serves what connects. `server`
        /// is initialized and routed, never run.
        pub fn start(self: *Self, server: *Server) !void {
            const io = server.io;
            self.server = server;
            self.tcp = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
            self.address = self.tcp.socket.address;
            self.listener = .{ .address = .{ .ip = self.address } };
            self.connections = .init;
            self.accepting = .init;
            try placement.concurrent(&self.accepting, io, .local, acceptLoop, .{self});
        }

        /// Stops accepting and ends every connection.
        pub fn stop(self: *Self) void {
            const io = self.server.io;
            self.accepting.cancel(io);
            self.connections.cancel(io);
            self.tcp.deinit(io);
        }

        fn acceptLoop(self: *Self) std.Io.Cancelable!void {
            const io = self.server.io;
            var next: usize = 0;
            while (true) {
                const stream = self.tcp.accept(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return,
                };
                placement.concurrent(&self.connections, io, .{ .executor = next }, serveOne, .{ self, stream }) catch {
                    stream.close(io);
                    continue;
                };
                next += 1;
            }
        }

        fn serveOne(self: *Self, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            const io = self.server.io;
            defer stream.close(io);
            // SAFETY: `initPlain` sets it before anything reads it.
            var connection: server_mod.Connection = undefined;
            connection.initPlain(self.server.allocator, io, stream) catch return;
            defer connection.deinit();
            connection.write_pool = &self.server.request_buffers;
            var busy = false;
            E.serve(self.server, &self.listener, false, &connection, &busy) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {},
            };
        }
    };
}
