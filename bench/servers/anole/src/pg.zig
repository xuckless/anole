//! A small Postgres client for the $12 benchmark, on `std.Io` sockets like
//! anole.redis: waiting for Postgres suspends the calling coroutine, not its
//! executor's thread. Anole has no Postgres client yet, so this stays here,
//! in the bench, and does only what the benchmark needs:
//!
//! - startup with trust auth (the bench database has no password),
//! - the extended protocol with text parameters and text results,
//! - one prepared statement per (connection, query), as pgx, sqlx and
//!   asyncpg do by default,
//! - a pool per executor (`Pools`): pinned executors never share a
//!   connection, so no wakeup crosses threads.
const std = @import("std");

pub const Error = error{ ConnectionClosed, ProtocolError, ServerError, AuthUnsupported, OutOfMemory };

/// A row's columns as text, null for SQL NULL. Lives in the arena given.
pub const Row = []const ?[]const u8;

pub const Result = struct {
    rows: []Row,
    /// The server's message for an ErrorResponse, else null.
    err: ?[]const u8 = null,
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8 = "bench",
    database: []const u8 = "postgres",

    /// postgres://user@host:port/db (no password, no options).
    pub fn parseUrl(url: []const u8) !Config {
        var cfg: Config = .{};
        var rest = url;
        inline for (.{ "postgres://", "postgresql://" }) |scheme| {
            if (std.mem.startsWith(u8, rest, scheme)) rest = rest[scheme.len..];
        }
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            cfg.database = rest[slash + 1 ..];
            rest = rest[0..slash];
        }
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            cfg.user = rest[0..at];
            rest = rest[at + 1 ..];
        }
        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
            cfg.port = try std.fmt.parseInt(u16, rest[colon + 1 ..], 10);
            rest = rest[0..colon];
        }
        if (rest.len > 0) cfg.host = rest;
        return cfg;
    }
};

/// The statements a connection may prepare: an index into this list names
/// the statement ("s<index>") on every connection.
pub const Statements = []const []const u8;

pub const Conn = struct {
    io: std.Io,
    socket: std.Io.net.Stream,
    read_buf: [32 * 1024]u8 = undefined,
    write_buf: [8 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    /// Bit i set: statement i is prepared on this connection.
    prepared: u64 = 0,
    broken: bool = false,

    pub fn connect(self: *Conn, io: std.Io, cfg: Config) !void {
        const addr = try std.Io.net.IpAddress.parse(cfg.host, cfg.port);
        self.* = .{ .io = io, .socket = try addr.connect(io, .{ .mode = .stream }) };
        errdefer self.socket.close(io);
        self.reader = self.socket.reader(io, &self.read_buf);
        self.writer = self.socket.writer(io, &self.write_buf);

        // StartupMessage: length, protocol 3.0, then name/value pairs.
        const w = &self.writer.interface;
        const params_len = "user".len + 1 + cfg.user.len + 1 + "database".len + 1 + cfg.database.len + 1 + 1;
        try w.writeInt(u32, @intCast(4 + 4 + params_len), .big);
        try w.writeInt(u32, 196608, .big);
        for ([_][]const u8{ "user", cfg.user, "database", cfg.database }) |s| {
            try w.writeAll(s);
            try w.writeByte(0);
        }
        try w.writeByte(0);
        try w.flush();

        while (true) {
            const msg = try self.readMessage();
            switch (msg.tag) {
                'R' => if (std.mem.readInt(u32, msg.body[0..4], .big) != 0) return error.AuthUnsupported,
                'E' => return error.ServerError,
                'Z' => return,
                else => {}, // ParameterStatus, BackendKeyData, notices
            }
        }
    }

    pub fn close(self: *Conn) void {
        self.socket.close(self.io);
    }

    const Message = struct { tag: u8, body: []const u8 };

    /// The next backend message. Its body points into the read buffer and
    /// is valid until the next read.
    fn readMessage(self: *Conn) Error!Message {
        const r = &self.reader.interface;
        const head = r.takeArray(5) catch return error.ConnectionClosed;
        const len = std.mem.readInt(u32, head[1..5], .big);
        if (len < 4 or len - 4 > self.read_buf.len) return error.ProtocolError;
        const body = r.take(len - 4) catch return error.ConnectionClosed;
        return .{ .tag = head[0], .body = body };
    }

    /// Runs statement `index` of `statements` with text parameters and
    /// returns its rows as text. A server-side error is `Result.err`, and the
    /// connection stays usable; a broken connection is a Zig error.
    pub fn query(self: *Conn, arena: std.mem.Allocator, statements: Statements, index: u6, params: []const ?[]const u8) Error!Result {
        if (self.broken) return error.ConnectionClosed;
        errdefer self.broken = true;
        self.send(statements[index], index, params) catch return error.ConnectionClosed;

        var rows: std.ArrayList(Row) = .empty;
        var err_msg: ?[]const u8 = null;
        while (true) {
            const msg = try self.readMessage();
            switch (msg.tag) {
                '1' => self.prepared |= @as(u64, 1) << index, // ParseComplete
                '2', 'C', 'n', 'I', 'N', 'S' => {},
                'D' => try rows.append(arena, try parseRow(arena, msg.body)),
                'E' => err_msg = try errorMessage(arena, msg.body),
                'Z' => return .{ .rows = rows.items, .err = err_msg },
                else => return error.ProtocolError,
            }
        }
    }

    fn send(self: *Conn, sql: []const u8, index: u6, params: []const ?[]const u8) !void {
        const w = &self.writer.interface;
        var name_buf: [4]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "s{d}", .{index});

        if (self.prepared & (@as(u64, 1) << index) == 0) {
            // Parse: name, query, no parameter types (the server infers them).
            try w.writeByte('P');
            try w.writeInt(u32, @intCast(4 + name.len + 1 + sql.len + 1 + 2), .big);
            try w.writeAll(name);
            try w.writeByte(0);
            try w.writeAll(sql);
            try w.writeByte(0);
            try w.writeInt(u16, 0, .big);
        }

        // Bind: unnamed portal, the statement, text parameters, text results.
        var len: usize = 4 + 1 + name.len + 1 + 2 + 2 + 2;
        for (params) |p| len += 4 + if (p) |v| v.len else 0;
        try w.writeByte('B');
        try w.writeInt(u32, @intCast(len), .big);
        try w.writeByte(0);
        try w.writeAll(name);
        try w.writeByte(0);
        try w.writeInt(u16, 0, .big);
        try w.writeInt(u16, @intCast(params.len), .big);
        for (params) |p| {
            if (p) |v| {
                try w.writeInt(i32, @intCast(v.len), .big);
                try w.writeAll(v);
            } else try w.writeInt(i32, -1, .big);
        }
        try w.writeInt(u16, 0, .big);

        // Execute the unnamed portal (all rows), then Sync.
        try w.writeAll(&.{ 'E', 0, 0, 0, 9, 0, 0, 0, 0, 0 });
        try w.writeAll(&.{ 'S', 0, 0, 0, 4 });
        try w.flush();
    }

    fn parseRow(arena: std.mem.Allocator, body: []const u8) Error!Row {
        if (body.len < 2) return error.ProtocolError;
        const n = std.mem.readInt(u16, body[0..2], .big);
        const cols = try arena.alloc(?[]const u8, n);
        var at: usize = 2;
        for (cols) |*col| {
            if (at + 4 > body.len) return error.ProtocolError;
            const len = std.mem.readInt(i32, body[at..][0..4], .big);
            at += 4;
            if (len < 0) {
                col.* = null;
                continue;
            }
            const end = at + @as(usize, @intCast(len));
            if (end > body.len) return error.ProtocolError;
            col.* = try arena.dupe(u8, body[at..end]);
            at = end;
        }
        return cols;
    }

    /// The 'M' (message) field of an ErrorResponse.
    fn errorMessage(arena: std.mem.Allocator, body: []const u8) Error![]const u8 {
        var it = std.mem.splitScalar(u8, body, 0);
        while (it.next()) |field| {
            if (field.len > 1 and field[0] == 'M') return arena.dupe(u8, field[1..]);
        }
        return "server error";
    }
};

/// Up to `size` connections, opened as they are needed and kept.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    free: std.ArrayList(*Conn) = .empty,
    opened: usize = 0,
    size: usize,
    mutex: std.Io.Mutex = .init,
    permits: std.Io.Semaphore,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, size: usize) Pool {
        return .{ .gpa = gpa, .cfg = cfg, .size = size, .permits = .{ .permits = size } };
    }

    pub fn acquire(self: *Pool, io: std.Io) !*Conn {
        try self.permits.wait(io);
        errdefer self.permits.post(io);
        {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.free.pop()) |c| return c;
            self.opened += 1;
        }
        const c = self.gpa.create(Conn) catch |e| {
            self.forget(io);
            return e;
        };
        c.connect(io, self.cfg) catch |e| {
            self.gpa.destroy(c);
            self.forget(io);
            return e;
        };
        return c;
    }

    /// Returns `c` to the pool, or closes it if it broke.
    pub fn release(self: *Pool, io: std.Io, c: *Conn) void {
        defer self.permits.post(io);
        if (c.broken) {
            c.close();
            self.gpa.destroy(c);
            self.forget(io);
            return;
        }
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.free.append(self.gpa, c) catch {
            c.close();
            self.gpa.destroy(c);
            self.opened -= 1;
        };
    }

    fn forget(self: *Pool, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.opened -= 1;
    }
};

/// One `Pool` per executor thread, made on first use there. Pinned
/// executors are threads that never trade tasks, so a thread-local slot
/// finds the pool without a lock.
pub const Pools = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    per_pool: usize,

    threadlocal var mine: ?*Pool = null;

    pub fn get(self: *Pools) !*Pool {
        if (mine) |p| return p;
        const p = try self.gpa.create(Pool);
        p.* = .init(self.gpa, self.cfg, self.per_pool);
        mine = p;
        return p;
    }
};
