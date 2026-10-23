//! `anole.smtp.testing.FakeServer`: an SMTP server in the test process,
//! scripted from the test, that records what it was sent. A test that
//! sends mail needs no Mailpit and no Docker.
//!
//!     var fake = try anole.smtp.testing.FakeServer.init(gpa, io, .{});
//!     defer fake.deinit();
//!     const mail = try anole.smtp.Client.init(gpa, io, .{ .url = fake.url(&buf), .from = "app@example.com" });
//!     defer mail.deinit();
//!     _ = try mail.send(&ctx, .{ .to = &.{"ada@example.com"}, .subject = "Hi", .text = "Hello" });
//!     try std.testing.expectEqual(@as(usize, 1), fake.messageCount());
//!     const m = fake.message(0).?; // m.envelope_from, m.recipients, m.data (the message as sent)
//!
//! It speaks EHLO (PIPELINING, SIZE, SMTPUTF8, STARTTLS and AUTH PLAIN and
//! LOGIN as `Options` say), checks nothing about the message, and can be
//! told to refuse recipients, answer the final "." with a chosen code, or
//! drop a connection. TLS uses a certificate made for the server: give
//! the client `.tls = .{ .ca = .{ .pem = fake.certPem().? } }`.
const std = @import("std");
const features = @import("build_options");

const has_tls = features.tls == .boringssl;
const tls = if (has_tls) @import("anole_dusty_tls") else struct {};
const tls_root = if (has_tls) @import("../tls/root.zig") else struct {};

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Options = struct {
    pipelining: bool = true,
    /// Announced as SIZE and enforced on MAIL FROM; 0: no SIZE.
    size_limit: u64 = 0,
    smtputf8: bool = true,
    /// Offer STARTTLS (a certificate is made).
    starttls: bool = false,
    /// TLS from the first byte (smtps).
    implicit_tls: bool = false,
    /// AUTH mechanisms offered ("PLAIN", "LOGIN"), only over TLS when
    /// `auth_needs_tls`.
    auth: []const []const u8 = &.{},
    auth_needs_tls: bool = false,
    /// The login accepted; null: any.
    credentials: ?Credentials = null,
    /// 500 to EHLO, so the client falls back to HELO.
    ehlo_fails: bool = false,
    greeting: []const u8 = "220 fake.example ESMTP ready",
    /// Recipients answered 550.
    reject_recipients: []const []const u8 = &.{},
    /// Recipients answered 450.
    defer_recipients: []const []const u8 = &.{},
    /// The code MAIL FROM is answered with.
    mail_code: u16 = 250,
    /// Close the connection after each accepted message, as an idle
    /// timeout would while the client holds it in its pool.
    close_after_message: bool = false,
};

pub const Credentials = struct { user: []const u8, password: []const u8 };

/// One message the server accepted.
pub const Message = struct {
    envelope_from: []u8,
    recipients: [][]u8,
    /// The SIZE the MAIL FROM announced.
    declared_size: ?u64,
    /// The message as sent: dot-unstuffed, lines ended with CRLF, without
    /// the closing ".".
    data: []u8,
};

pub const FakeServer = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    listener: std.Io.net.Server,
    group: std.Io.Group = .init,
    pem: if (has_tls) ?tls_root.Pem else void = if (has_tls) null else {},
    auth_pair: if (has_tls) ?tls.config.CertKeyPair else void = if (has_tls) null else {},
    mutex: std.Io.Mutex = .init,
    messages: std.ArrayList(*Message) = .empty,
    commands: std.ArrayList([]u8) = .empty,
    /// Replies to the next final "." (a code each), then 250.
    final_codes: std.ArrayList(u16) = .empty,
    /// Connections accepted (greetings sent).
    connections: std.atomic.Value(u32) = .init(0),
    /// The most commands that were already waiting when the server read
    /// the next one: above 1, the client pipelined.
    max_batch: std.atomic.Value(u32) = .init(0),
    /// Connections to close right after the final "." arrives, with no
    /// reply.
    drop_after_dot: std.atomic.Value(u32) = .init(0),
    /// The login of the last successful AUTH.
    last_user: ?[]u8 = null,
    last_password: ?[]u8 = null,
    /// AUTH attempts seen.
    auth_attempts: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, io: std.Io, options: Options) !*FakeServer {
        const self = try gpa.create(FakeServer);
        errdefer gpa.destroy(self);
        const listen_at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.* = .{ .gpa = gpa, .io = io, .options = options, .listener = try listen_at.listen(io, .{}) };
        errdefer self.listener.deinit(io);
        if (options.starttls or options.implicit_tls) {
            if (comptime !has_tls) return error.TlsNotBuilt;
            self.pem = try tls_root.selfSigned(gpa, .{});
            errdefer self.pem.?.deinit(gpa);
            self.auth_pair = try tls.config.CertKeyPair.fromSlice(gpa, io, self.pem.?.cert, self.pem.?.key);
        }
        try self.group.concurrent(io, acceptLoop, .{self});
        return self;
    }

    pub fn deinit(self: *FakeServer) void {
        const io = self.io;
        const gpa = self.gpa;
        self.group.cancel(io);
        self.listener.deinit(io);
        for (self.messages.items) |m| {
            gpa.free(m.envelope_from);
            for (m.recipients) |r| gpa.free(r);
            gpa.free(m.recipients);
            gpa.free(m.data);
            gpa.destroy(m);
        }
        self.messages.deinit(gpa);
        for (self.commands.items) |c| gpa.free(c);
        self.commands.deinit(gpa);
        self.final_codes.deinit(gpa);
        if (self.last_user) |u| gpa.free(u);
        if (self.last_password) |p| gpa.free(p);
        if (comptime has_tls) {
            if (self.auth_pair) |*a| a.deinit(gpa);
            if (self.pem) |*p| p.deinit(gpa);
        }
        gpa.destroy(self);
    }

    pub fn port(self: *const FakeServer) u16 {
        return self.listener.socket.address.getPort();
    }

    /// A URL for a client: `smtp://127.0.0.1:port?tls=none`, or without
    /// the parameter when the server offers STARTTLS, `smtps://` when it
    /// is implicit TLS. `credentials` go into it.
    pub fn url(self: *const FakeServer, buf: []u8) []const u8 {
        return self.urlWith(buf, null);
    }

    pub fn urlWith(self: *const FakeServer, buf: []u8, credentials: ?Credentials) []const u8 {
        const scheme = if (self.options.implicit_tls) "smtps" else "smtp";
        const suffix = if (self.options.implicit_tls or self.options.starttls) "" else "?tls=none";
        if (credentials) |c| return std.fmt.bufPrint(buf, "{s}://{s}:{s}@127.0.0.1:{d}{s}", .{ scheme, c.user, c.password, self.port(), suffix }) catch unreachable;
        return std.fmt.bufPrint(buf, "{s}://127.0.0.1:{d}{s}", .{ scheme, self.port(), suffix }) catch unreachable;
    }

    /// The server's certificate (PEM), for the client's `tls.ca`.
    pub fn certPem(self: *const FakeServer) ?[]const u8 {
        if (comptime !has_tls) return null;
        return if (self.pem) |p| p.cert else null;
    }

    pub fn messageCount(self: *FakeServer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.messages.items.len;
    }

    /// The `i`th accepted message, valid until `deinit`.
    pub fn message(self: *FakeServer, i: usize) ?*const Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (i < self.messages.items.len) self.messages.items[i] else null;
    }

    /// How many received commands start with `prefix` (case-insensitive).
    pub fn commandCount(self: *FakeServer, prefix: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.commands.items) |c| {
            if (c.len >= prefix.len and std.ascii.eqlIgnoreCase(c[0..prefix.len], prefix)) n += 1;
        }
        return n;
    }

    /// Answers the next final "." with these codes, one each (451, 554...),
    /// then 250 again.
    pub fn queueFinalCodes(self: *FakeServer, codes: []const u16) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.final_codes.appendSlice(self.gpa, codes);
    }

    // -- serving ----------------------------------------------------------------------

    fn acceptLoop(self: *FakeServer) std.Io.Cancelable!void {
        while (true) {
            const conn = self.listener.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            self.group.concurrent(self.io, serve, .{ self, conn }) catch conn.close(self.io);
        }
    }

    const Conn = struct {
        tls_on: bool = false,
        greeted: bool = false,
        batch: u32 = 0,
        // The transaction.
        from: ?[]u8 = null,
        declared_size: ?u64 = null,
        rcpts: std.ArrayList([]u8) = .empty,
        close_after: bool = false,

        fn reset(c: *Conn, gpa: Allocator) void {
            if (c.from) |f| gpa.free(f);
            c.from = null;
            c.declared_size = null;
            for (c.rcpts.items) |r| gpa.free(r);
            c.rcpts.clearRetainingCapacity();
        }
    };

    const Outcome = enum { done, starttls };

    fn serve(self: *FakeServer, conn: std.Io.net.Stream) std.Io.Cancelable!void {
        defer conn.close(self.io);
        const io = self.io;
        const gpa = self.gpa;
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var tcp_r = conn.reader(io, &rbuf);
        var tcp_w = conn.writer(io, &wbuf);
        var st: Conn = .{};
        defer {
            st.reset(gpa);
            st.rcpts.deinit(gpa);
        }
        if (comptime has_tls) {
            if (self.options.implicit_tls) {
                var rng: std.Random.IoSource = .{ .io = io };
                var t = tls.server(&tcp_r.interface, &tcp_w.interface, .{
                    .auth = &self.auth_pair.?,
                    .now = std.Io.Clock.real.now(io),
                    .rng = rng.interface(),
                }) catch return;
                defer t.deinit();
                var prb: [16384]u8 = undefined;
                var pwb: [4096]u8 = undefined;
                var r = t.reader(&prb);
                var w = t.writer(&pwb);
                st.tls_on = true;
                _ = self.dialogue(&r.interface, &w.interface, &st) catch return;
                return;
            }
        }
        const outcome = self.dialogue(&tcp_r.interface, &tcp_w.interface, &st) catch return;
        if (outcome == .starttls) {
            if (comptime !has_tls) return;
            var rng: std.Random.IoSource = .{ .io = io };
            var t = tls.server(&tcp_r.interface, &tcp_w.interface, .{
                .auth = &self.auth_pair.?,
                .now = std.Io.Clock.real.now(io),
                .rng = rng.interface(),
            }) catch return;
            defer t.deinit();
            var prb: [16384]u8 = undefined;
            var pwb: [4096]u8 = undefined;
            var r = t.reader(&prb);
            var w = t.writer(&pwb);
            // The session starts over after the handshake.
            st.reset(gpa);
            st.tls_on = true;
            _ = self.dialogue(&r.interface, &w.interface, &st) catch return;
        }
    }

    fn record(self: *FakeServer, line: []const u8) void {
        const copy = self.gpa.dupe(u8, line) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.commands.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    fn reply(w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try w.print(fmt ++ "\r\n", args);
        try w.flush();
    }

    /// Reads a command line (without its line end), counting how many were
    /// already buffered.
    fn readLine(self: *FakeServer, r: *Reader, st: *Conn) ![]const u8 {
        if (r.bufferedLen() == 0) st.batch = 0;
        const raw = try r.takeDelimiterInclusive('\n');
        st.batch += 1;
        var seen = self.max_batch.load(.monotonic);
        while (st.batch > seen) seen = self.max_batch.cmpxchgWeak(seen, st.batch, .monotonic, .monotonic) orelse break;
        return std.mem.trimEnd(u8, raw, "\r\n");
    }

    fn dialogue(self: *FakeServer, r: *Reader, w: *Writer, st: *Conn) !Outcome {
        const gpa = self.gpa;
        const o = self.options;
        if (!st.greeted) {
            st.greeted = true;
            _ = self.connections.fetchAdd(1, .acq_rel);
            try reply(w, "{s}", .{o.greeting});
            if (!std.mem.startsWith(u8, o.greeting, "220")) return .done;
        }
        while (true) {
            const line = try self.readLine(r, st);
            self.record(line);
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const verb = line[0..space];
            const rest = std.mem.trim(u8, line[space..], " ");
            if (std.ascii.eqlIgnoreCase(verb, "EHLO")) {
                if (o.ehlo_fails) {
                    try reply(w, "500 5.5.1 EHLO not understood", .{});
                    continue;
                }
                try w.writeAll("250-fake.example\r\n");
                if (o.pipelining) try w.writeAll("250-PIPELINING\r\n");
                if (o.size_limit > 0) try w.print("250-SIZE {d}\r\n", .{o.size_limit});
                if (o.smtputf8) try w.writeAll("250-SMTPUTF8\r\n");
                try w.writeAll("250-ENHANCEDSTATUSCODES\r\n");
                if (o.starttls and !st.tls_on) try w.writeAll("250-STARTTLS\r\n");
                if (o.auth.len > 0 and (st.tls_on or !o.auth_needs_tls)) {
                    try w.writeAll("250-AUTH");
                    for (o.auth) |m| try w.print(" {s}", .{m});
                    try w.writeAll("\r\n");
                }
                try reply(w, "250 8BITMIME", .{});
            } else if (std.ascii.eqlIgnoreCase(verb, "HELO")) {
                try reply(w, "250 fake.example", .{});
            } else if (std.ascii.eqlIgnoreCase(verb, "STARTTLS")) {
                if (!o.starttls or st.tls_on) {
                    try reply(w, "502 5.5.1 STARTTLS not available", .{});
                    continue;
                }
                try reply(w, "220 2.0.0 Ready to start TLS", .{});
                return .starttls;
            } else if (std.ascii.eqlIgnoreCase(verb, "AUTH")) {
                _ = self.auth_attempts.fetchAdd(1, .acq_rel);
                try self.authenticate(r, w, st, rest);
            } else if (std.ascii.eqlIgnoreCase(verb, "MAIL")) {
                if (st.from != null) {
                    try reply(w, "503 5.5.1 nested MAIL command", .{});
                    continue;
                }
                const lt = std.mem.indexOfScalar(u8, rest, '<') orelse {
                    try reply(w, "501 5.5.4 syntax error", .{});
                    continue;
                };
                const gt = std.mem.indexOfScalarPos(u8, rest, lt, '>') orelse {
                    try reply(w, "501 5.5.4 syntax error", .{});
                    continue;
                };
                if (o.mail_code != 250) {
                    try reply(w, "{d} 4.0.0 scripted refusal", .{o.mail_code});
                    continue;
                }
                var declared: ?u64 = null;
                var params = std.mem.tokenizeScalar(u8, rest[gt + 1 ..], ' ');
                while (params.next()) |p| {
                    if (p.len > 5 and std.ascii.eqlIgnoreCase(p[0..5], "SIZE=")) declared = std.fmt.parseInt(u64, p[5..], 10) catch null;
                }
                if (o.size_limit > 0) if (declared) |d| if (d > o.size_limit) {
                    try reply(w, "552 5.3.4 message size exceeds the limit", .{});
                    continue;
                };
                st.from = try gpa.dupe(u8, rest[lt + 1 .. gt]);
                st.declared_size = declared;
                try reply(w, "250 2.1.0 Ok", .{});
            } else if (std.ascii.eqlIgnoreCase(verb, "RCPT")) {
                if (st.from == null) {
                    try reply(w, "503 5.5.1 need MAIL first", .{});
                    continue;
                }
                const lt = std.mem.indexOfScalar(u8, rest, '<') orelse {
                    try reply(w, "501 5.5.4 syntax error", .{});
                    continue;
                };
                const gt = std.mem.indexOfScalarPos(u8, rest, lt, '>') orelse {
                    try reply(w, "501 5.5.4 syntax error", .{});
                    continue;
                };
                const addr = rest[lt + 1 .. gt];
                if (listed(o.reject_recipients, addr)) {
                    try reply(w, "550 5.1.1 <{s}>: Recipient address rejected: User unknown", .{addr});
                } else if (listed(o.defer_recipients, addr)) {
                    try reply(w, "450 4.2.0 <{s}>: Recipient address deferred: try later", .{addr});
                } else {
                    try st.rcpts.append(gpa, try gpa.dupe(u8, addr));
                    try reply(w, "250 2.1.5 Ok", .{});
                }
            } else if (std.ascii.eqlIgnoreCase(verb, "DATA")) {
                if (st.from == null or st.rcpts.items.len == 0) {
                    try reply(w, "503 5.5.1 no valid recipients", .{});
                    continue;
                }
                try reply(w, "354 End data with <CR><LF>.<CR><LF>", .{});
                if (try self.receiveData(r, w, st)) return .done;
                if (st.close_after) return .done;
            } else if (std.ascii.eqlIgnoreCase(verb, "RSET")) {
                st.reset(gpa);
                try reply(w, "250 2.0.0 Ok", .{});
            } else if (std.ascii.eqlIgnoreCase(verb, "NOOP")) {
                try reply(w, "250 2.0.0 Ok", .{});
            } else if (std.ascii.eqlIgnoreCase(verb, "QUIT")) {
                try reply(w, "221 2.0.0 Bye", .{});
                return .done;
            } else {
                try reply(w, "502 5.5.2 command not implemented", .{});
            }
        }
    }

    fn listed(list: []const []const u8, addr: []const u8) bool {
        for (list) |l| if (std.mem.eql(u8, l, addr)) return true;
        return false;
    }

    /// Reads the message up to the lone ".", answers it. True when the
    /// connection was dropped instead.
    fn receiveData(self: *FakeServer, r: *Reader, w: *Writer, st: *Conn) !bool {
        const gpa = self.gpa;
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        while (true) {
            const raw = try r.takeDelimiterInclusive('\n');
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            if (std.mem.eql(u8, line, ".")) break;
            // Dot-unstuffing.
            const body = if (line.len > 0 and line[0] == '.') line[1..] else line;
            try data.appendSlice(gpa, body);
            try data.appendSlice(gpa, "\r\n");
        }
        if (self.drop_after_dot.load(.acquire) > 0) {
            _ = self.drop_after_dot.fetchSub(1, .acq_rel);
            st.reset(gpa);
            return true;
        }
        var code: u16 = 250;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.final_codes.items.len > 0) code = self.final_codes.orderedRemove(0);
        }
        if (code != 250) {
            st.reset(gpa);
            try reply(w, "{d} {s} scripted reply", .{ code, if (code >= 500) "5.0.0" else "4.0.0" });
            return false;
        }
        const m = try gpa.create(Message);
        errdefer gpa.destroy(m);
        const recipients = try gpa.alloc([]u8, st.rcpts.items.len);
        for (st.rcpts.items, recipients) |src, *dst| dst.* = try gpa.dupe(u8, src);
        m.* = .{
            .envelope_from = try gpa.dupe(u8, st.from.?),
            .recipients = recipients,
            .declared_size = st.declared_size,
            .data = try data.toOwnedSlice(gpa),
        };
        var id: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.messages.append(gpa, m);
            id = self.messages.items.len;
        }
        st.reset(gpa);
        st.close_after = self.options.close_after_message;
        try reply(w, "250 2.0.0 Ok: queued as FAKE{d}", .{id});
        return false;
    }

    fn authenticate(self: *FakeServer, r: *Reader, w: *Writer, st: *Conn, rest: []const u8) !void {
        _ = st;
        const gpa = self.gpa;
        const b64 = std.base64.standard.Decoder;
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const mech = it.next() orelse {
            try reply(w, "501 5.5.4 syntax error", .{});
            return;
        };
        var user: []u8 = &.{};
        var pass: []u8 = &.{};
        defer {
            gpa.free(user);
            gpa.free(pass);
        }
        if (std.ascii.eqlIgnoreCase(mech, "PLAIN")) {
            const initial = it.next() orelse {
                try reply(w, "334 ", .{});
                const line = try r.takeDelimiterInclusive('\n');
                return self.finishPlain(w, std.mem.trimEnd(u8, line, "\r\n"));
            };
            return self.finishPlain(w, initial);
        } else if (std.ascii.eqlIgnoreCase(mech, "LOGIN")) {
            try reply(w, "334 VXNlcm5hbWU6", .{});
            const u = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            user = try gpa.alloc(u8, b64.calcSizeForSlice(u) catch 0);
            b64.decode(user, u) catch {
                try reply(w, "501 5.5.2 bad base64", .{});
                return;
            };
            try reply(w, "334 UGFzc3dvcmQ6", .{});
            const p = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            pass = try gpa.alloc(u8, b64.calcSizeForSlice(p) catch 0);
            b64.decode(pass, p) catch {
                try reply(w, "501 5.5.2 bad base64", .{});
                return;
            };
            return self.judgeLogin(w, user, pass);
        }
        try reply(w, "504 5.5.4 mechanism not supported", .{});
    }

    fn finishPlain(self: *FakeServer, w: *Writer, b64text: []const u8) !void {
        const gpa = self.gpa;
        const b64 = std.base64.standard.Decoder;
        const raw = try gpa.alloc(u8, b64.calcSizeForSlice(b64text) catch 0);
        defer gpa.free(raw);
        b64.decode(raw, b64text) catch {
            try reply(w, "501 5.5.2 bad base64", .{});
            return;
        };
        // authzid NUL user NUL password
        var parts = std.mem.splitScalar(u8, raw, 0);
        _ = parts.next();
        const user = parts.next() orelse "";
        const pass = parts.next() orelse "";
        return self.judgeLogin(w, user, pass);
    }

    fn judgeLogin(self: *FakeServer, w: *Writer, user: []const u8, pass: []const u8) !void {
        if (self.options.credentials) |c| {
            if (!std.mem.eql(u8, c.user, user) or !std.mem.eql(u8, c.password, pass)) {
                try reply(w, "535 5.7.8 authentication credentials invalid", .{});
                return;
            }
        }
        const gpa = self.gpa;
        const u = try gpa.dupe(u8, user);
        const p = try gpa.dupe(u8, pass);
        self.mutex.lockUncancelable(self.io);
        if (self.last_user) |old| gpa.free(old);
        if (self.last_password) |old| gpa.free(old);
        self.last_user = u;
        self.last_password = p;
        self.mutex.unlock(self.io);
        try reply(w, "235 2.7.0 Authentication successful", .{});
    }
};
