//! One SMTP connection: greeting, EHLO (HELO as a fallback), STARTTLS,
//! AUTH, and mail transactions (pipelined when the server offers it), on
//! `anole.net.ClientStream`, so a wait suspends the calling coroutine.
//!
//! Failures the server causes are recorded for `anole.db.lastError`
//! through `Ctx.fail` and come back as `anole.db.Error`; a broken
//! connection comes back as the I/O error that broke it, for the caller to
//! map (`Session.broken` is set).
const std = @import("std");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const net = @import("../net/root.zig");
const auth = @import("core/auth.zig");
const reply_mod = @import("core/reply.zig");
const mime = @import("mime.zig");
const pool_mod = @import("pool.zig");

const ClientStream = net.ClientStream;
const Duration = std.Io.Duration;
const Reply = reply_mod.Reply;

/// The calling context, without its type: what a failure is recorded on.
pub const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    any: *anyopaque,
    record: *const fn (any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error,
    request: ?*const dusty.Request,
    last: *const fn (any: *anyopaque) ?db.ErrorDetail,

    /// The last error recorded on the context it stands for.
    pub fn lastDetail(self: *const Ctx) ?db.ErrorDetail {
        return self.last(self.any);
    }

    /// `internal.fail` on the context it stands for.
    pub fn fail(self: *const Ctx, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
        return self.record(self.any, map, detail);
    }

    pub fn failf(self: *const Ctx, map: db.ErrorMap, class: db.Class, code: []const u8, comptime fmt: []const u8, args: anytype) db.Error {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch "(message lost: out of memory)";
        return self.fail(map, .{ .system = .smtp, .class = class, .code = code, .message = message });
    }
};

/// Where to connect and how to talk.
pub const Settings = struct {
    host: []const u8,
    port: u16,
    tls_mode: TlsMode,
    tls: net.ConnectOptions.Tls,
    username: ?[]const u8,
    password: ?[]const u8,
    helo: []const u8,
    connect_timeout: ?Duration,
    loopback: bool,

    pub const TlsMode = enum {
        /// TLS from the first byte (smtps, port 465).
        implicit,
        /// STARTTLS, and a server that does not offer it is an error.
        starttls_required,
        /// STARTTLS when offered (a local test server).
        starttls_optional,
        none,
    };
};

/// What EHLO said.
pub const Capabilities = struct {
    pipelining: bool = false,
    starttls: bool = false,
    smtputf8: bool = false,
    size_ext: bool = false,
    /// 0: no limit announced.
    size: u64 = 0,
    enhanced: bool = false,
    mechanism: ?auth.Mechanism = null,
    auth_offered: bool = false,
};

/// What an EHLO reply (its first line is the server's name, the rest are
/// extensions) says the server can do.
pub fn parseCapabilities(r: Reply) Capabilities {
    var caps: Capabilities = .{};
    for (r.lines[@min(1, r.lines.len)..]) |line| {
        var it = std.mem.tokenizeAny(u8, line, " ");
        const keyword = it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(keyword, "PIPELINING")) {
            caps.pipelining = true;
        } else if (std.ascii.eqlIgnoreCase(keyword, "STARTTLS")) {
            caps.starttls = true;
        } else if (std.ascii.eqlIgnoreCase(keyword, "SMTPUTF8")) {
            caps.smtputf8 = true;
        } else if (std.ascii.eqlIgnoreCase(keyword, "ENHANCEDSTATUSCODES")) {
            caps.enhanced = true;
        } else if (std.ascii.eqlIgnoreCase(keyword, "SIZE")) {
            caps.size_ext = true;
            if (it.next()) |n| caps.size = std.fmt.parseInt(u64, n, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(keyword, "AUTH")) {
            caps.auth_offered = true;
            caps.mechanism = auth.choose(it.rest());
        }
    }
    return caps;
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    stream: *ClientStream,
    pool: ?*pool_mod.Pool = null,
    caps: Capabilities = .{},
    idle_since: std.Io.Clock.Timestamp = undefined,
    /// Transactions this connection has run.
    messages: u32 = 0,
    /// Out of step with the server, or the connection failed: closed when
    /// given back.
    broken: bool = false,
    /// Taken idle from the pool.
    reused: bool = false,
    /// The final "." of the current message was sent and no answer came:
    /// the server may have kept the message.
    after_dot: bool = false,
    /// MAIL FROM of the current message was accepted.
    mail_accepted: bool = false,

    pub fn close(self: *Session, polite: bool) void {
        if (polite and !self.broken) self.quit();
        self.stream.close();
        self.gpa.destroy(self);
    }

    /// QUIT, best effort: the reply is not waited for beyond one read that
    /// a closed peer ends at once.
    fn quit(self: *Session) void {
        const w = self.stream.writer();
        w.writeAll("QUIT\r\n") catch return;
        w.flush() catch return;
    }

    // -- opening ------------------------------------------------------------

    /// Connects and gets the session ready to send: greeting, EHLO,
    /// STARTTLS and AUTH as the settings say.
    pub fn open(gpa: std.mem.Allocator, ctx: *const Ctx, map: db.ErrorMap, s: *const Settings) anyerror!*Session {
        const stream = try ClientStream.connect(gpa, ctx.io, .{
            .host = s.host,
            .port = s.port,
            .tls = if (s.tls_mode == .implicit) s.tls else null,
            .connect_timeout = s.connect_timeout,
        });
        errdefer stream.close();
        const self = try gpa.create(Session);
        self.* = .{ .gpa = gpa, .stream = stream };
        errdefer gpa.destroy(self);

        const greeting = try self.read(ctx, map);
        if (greeting.code != 220)
            return ctx.failf(map, .unavailable, "greeting_refused", "{s}:{d} refused the connection: {d} {s}", .{ s.host, s.port, greeting.code, greeting.first() });
        try self.hello(ctx, map, s);
        if (s.tls_mode == .starttls_required or s.tls_mode == .starttls_optional) {
            if (self.caps.starttls) {
                try self.command(ctx, "STARTTLS");
                const r = try self.read(ctx, map);
                if (r.code != 220)
                    return ctx.failf(map, .unavailable, "starttls_failed", "{s}:{d} refused STARTTLS: {d} {s}", .{ s.host, s.port, r.code, r.first() });
                try self.stream.startTls(s.tls);
                // What the server said before TLS means nothing now.
                self.caps = .{};
                try self.hello(ctx, map, s);
            } else if (s.tls_mode == .starttls_required) {
                return ctx.failf(map, .unavailable, "starttls_unavailable", "{s}:{d} does not offer STARTTLS; mail and credentials would cross the network in clear text (use smtps://, or ?tls=none on a trusted network)", .{ s.host, s.port });
            }
        }
        if (s.username) |user| try self.login(ctx, map, s, user, s.password orelse "");
        return self;
    }

    fn hello(self: *Session, ctx: *const Ctx, map: db.ErrorMap, s: *const Settings) anyerror!void {
        const w = self.stream.writer();
        try w.print("EHLO {s}\r\n", .{s.helo});
        try w.flush();
        const r = try self.read(ctx, map);
        if (r.code == 250) {
            self.caps = parseCapabilities(r);
            return;
        }
        if (r.code >= 500) {
            // An old server: HELO, with no extensions.
            try w.print("HELO {s}\r\n", .{s.helo});
            try w.flush();
            const h = try self.read(ctx, map);
            if (h.code == 250) return;
            return self.refused(ctx, map, .ehlo, h);
        }
        return self.refused(ctx, map, .ehlo, r);
    }

    fn login(self: *Session, ctx: *const Ctx, map: db.ErrorMap, s: *const Settings, user: []const u8, password: []const u8) anyerror!void {
        if (!self.stream.isTls() and !s.loopback)
            return ctx.failf(map, .other, "insecure_auth", "{s}:{d}: refusing to send the password without TLS", .{ s.host, s.port });
        const mech = self.caps.mechanism orelse
            return ctx.failf(map, .other, "auth_unsupported", "{s}:{d} offers no AUTH PLAIN or LOGIN{s}", .{ s.host, s.port, if (self.caps.auth_offered) " (only mechanisms Anole does not speak)" else " (no AUTH at all: remove the credentials from the URL?)" });
        const w = self.stream.writer();
        switch (mech) {
            .plain => {
                const initial = try auth.plain(ctx.arena, user, password);
                try w.print("AUTH PLAIN {s}\r\n", .{initial});
                try w.flush();
                const r = try self.read(ctx, map);
                if (r.code != 235) return self.refused(ctx, map, .auth, r);
            },
            .login => {
                try w.writeAll("AUTH LOGIN\r\n");
                try w.flush();
                var r = try self.read(ctx, map);
                if (r.code != 334) return self.refused(ctx, map, .auth, r);
                // Some servers want the user name inline, some after
                // "Username:"; the challenge says.
                try w.print("{s}\r\n", .{try auth.base64(ctx.arena, user)});
                try w.flush();
                r = try self.read(ctx, map);
                if (r.code != 334) return self.refused(ctx, map, .auth, r);
                try w.print("{s}\r\n", .{try auth.base64(ctx.arena, password)});
                try w.flush();
                r = try self.read(ctx, map);
                if (r.code != 235) return self.refused(ctx, map, .auth, r);
            },
        }
    }

    // -- one command and its reply -------------------------------------------

    fn command(self: *Session, ctx: *const Ctx, text: []const u8) anyerror!void {
        _ = ctx;
        const w = self.stream.writer();
        try w.writeAll(text);
        try w.writeAll("\r\n");
        try w.flush();
    }

    /// Reads one reply. A malformed one breaks the connection.
    fn read(self: *Session, ctx: *const Ctx, map: db.ErrorMap) anyerror!Reply {
        return reply_mod.read(self.stream.reader(), ctx.arena) catch |err| switch (err) {
            error.MalformedReply => {
                self.broken = true;
                return ctx.failf(map, .unavailable, "protocol_error", "the server sent something that is not an SMTP reply", .{});
            },
            else => |e| return e,
        };
    }

    pub const Stage = enum { ehlo, auth, mail, rcpt, data, body };

    /// A reply the stage did not expect, as the failure it is (M10).
    fn refused(self: *Session, ctx: *const Ctx, map: db.ErrorMap, stage: Stage, r: Reply) db.Error {
        const text = r.joined(ctx.arena) catch r.first();
        const code_text = r.enhanced() orelse std.fmt.allocPrint(ctx.arena, "{d}", .{r.code}) catch "";
        if (r.code == 421) self.broken = true;
        var class: db.Class = .other;
        var code: []const u8 = code_text;
        if (r.code == 421) {
            class = .unavailable;
            code = "service_unavailable";
        } else if (r.code >= 400 and r.code < 500) {
            class = .unavailable;
            if (stage == .auth) code = "auth_temporary";
        } else switch (stage) {
            .auth => code = "authentication_failed",
            .body, .mail, .data => if (r.code == 552 or (r.enhanced() != null and std.mem.startsWith(u8, r.enhanced().?, "5.3.4"))) {
                class = .invalid;
                code = "message_too_large";
            },
            else => {},
        }
        return ctx.failf(map, class, code, "{d} {s}", .{ r.code, text });
    }

    // -- a transaction ---------------------------------------------------------

    pub const Rejected = struct { address: []const u8, code: u16, message: []const u8 };

    pub const Sent = struct {
        accepted: []const []const u8,
        rejected: []const Rejected,
        response: []const u8,
        code: u16,
    };

    /// Sends `c`: MAIL FROM, every RCPT TO, DATA and the body. Returns when
    /// the server has answered the final "." (`after_dot` says it has been
    /// sent, for the caller to know a failure may still have delivered).
    pub fn transact(self: *Session, ctx: *const Ctx, map: db.ErrorMap, io: std.Io, c: *const mime.Composed, max_bytes: u64) anyerror!Sent {
        self.after_dot = false;
        self.mail_accepted = false;
        if (c.utf8 and !self.caps.smtputf8)
            return ctx.failf(map, .invalid, "smtputf8_unsupported", "an address is not ASCII and the server does not offer SMTPUTF8", .{});
        if (self.caps.size > 0 and c.size > self.caps.size)
            return ctx.failf(map, .invalid, "message_too_large", "the message is {d} bytes; the server accepts {d} (its SIZE)", .{ c.size, self.caps.size });
        if (c.size > max_bytes)
            return ctx.failf(map, .invalid, "message_too_large", "the message is {d} bytes; the limit is {d} (Options.max_message_bytes)", .{ c.size, max_bytes });

        const w = self.stream.writer();
        const pipelined = self.caps.pipelining;
        try w.print("MAIL FROM:<{s}>", .{c.envelope_from});
        if (self.caps.size_ext) try w.print(" SIZE={d}", .{c.size});
        if (c.utf8) try w.writeAll(" SMTPUTF8");
        try w.writeAll("\r\n");
        var mail_reply: ?Reply = null;
        if (!pipelined) {
            try w.flush();
            mail_reply = try self.read(ctx, map);
            if (mail_reply.?.code != 250) return self.refused(ctx, map, .mail, mail_reply.?);
            self.mail_accepted = true;
        }
        var accepted: std.ArrayList([]const u8) = .empty;
        var rejected: std.ArrayList(Rejected) = .empty;
        var deferred = false;
        var first_rejection: ?Reply = null;
        var rcpt_replies: std.ArrayList(Reply) = .empty;
        for (c.recipients) |rcpt| {
            try w.print("RCPT TO:<{s}>\r\n", .{rcpt});
            if (!pipelined) {
                try w.flush();
                const r = try self.read(ctx, map);
                try rcpt_replies.append(ctx.arena, r);
            }
        }
        if (!pipelined) {
            // Judge the replies as they came.
            for (c.recipients, rcpt_replies.items) |rcpt, r| {
                try self.judgeRecipient(ctx, &accepted, &rejected, &deferred, &first_rejection, rcpt, r);
            }
            if (accepted.items.len == 0) {
                self.resetTransaction(ctx);
                return self.noRecipients(ctx, map, deferred, first_rejection, rejected.items);
            }
            try w.writeAll("DATA\r\n");
            try w.flush();
            const d = try self.read(ctx, map);
            if (d.code != 354) {
                self.resetTransaction(ctx);
                return self.refused(ctx, map, .data, d);
            }
        } else {
            try w.writeAll("DATA\r\n");
            try w.flush();
            // The replies come in the order of the commands.
            mail_reply = try self.read(ctx, map);
            for (c.recipients) |rcpt| {
                const r = try self.read(ctx, map);
                try rcpt_replies.append(ctx.arena, r);
                try self.judgeRecipient(ctx, &accepted, &rejected, &deferred, &first_rejection, rcpt, r);
            }
            const d = try self.read(ctx, map);
            if (mail_reply.?.code != 250) {
                // The rest were answered "bad sequence".
                return self.refused(ctx, map, .mail, mail_reply.?);
            }
            self.mail_accepted = true;
            if (accepted.items.len == 0) {
                if (d.code == 354) {
                    // The server wants a body after all: end it empty.
                    try w.writeAll("\r\n.\r\n");
                    try w.flush();
                    _ = try self.read(ctx, map);
                } else self.resetTransaction(ctx);
                return self.noRecipients(ctx, map, deferred, first_rejection, rejected.items);
            }
            if (d.code != 354) {
                self.resetTransaction(ctx);
                return self.refused(ctx, map, .data, d);
            }
        }

        // The body, then the final dot.
        var stuffer: mime.Stuffer = .{ .normalize = c.normalize };
        try mime.writeMessage(c, io, w, &stuffer);
        self.after_dot = true;
        try stuffer.finish(w);
        try w.flush();
        const final = try self.read(ctx, map);
        // The server answered: whatever it said, the outcome is known.
        self.after_dot = false;
        if (final.code != 250) return self.refused(ctx, map, .body, final);
        self.messages += 1;
        return .{
            .accepted = accepted.items,
            .rejected = rejected.items,
            .response = final.joined(ctx.arena) catch final.first(),
            .code = final.code,
        };
    }

    fn judgeRecipient(
        self: *Session,
        ctx: *const Ctx,
        accepted: *std.ArrayList([]const u8),
        rejected: *std.ArrayList(Rejected),
        deferred: *bool,
        first_rejection: *?Reply,
        rcpt: []const u8,
        r: Reply,
    ) anyerror!void {
        if (r.code == 250 or r.code == 251) {
            try accepted.append(ctx.arena, rcpt);
            return;
        }
        if (r.code == 421) {
            self.broken = true;
        }
        if (r.code >= 400 and r.code < 500) deferred.* = true;
        if (first_rejection.* == null) first_rejection.* = r;
        try rejected.append(ctx.arena, .{ .address = rcpt, .code = r.code, .message = r.joined(ctx.arena) catch r.first() });
    }

    fn noRecipients(self: *Session, ctx: *const Ctx, map: db.ErrorMap, deferred: bool, first: ?Reply, rejected: []const Rejected) db.Error {
        _ = self;
        const f = first.?;
        const detail = std.fmt.allocPrint(ctx.arena, "{s}: {d} {s}", .{ rejected[0].address, f.code, rejected[0].message }) catch "every recipient was refused";
        if (f.code == 421) return ctx.fail(map, .{ .system = .smtp, .class = .unavailable, .code = "service_unavailable", .message = detail });
        if (deferred) return ctx.fail(map, .{ .system = .smtp, .class = .unavailable, .code = "recipients_deferred", .message = detail });
        return ctx.fail(map, .{ .system = .smtp, .class = .invalid, .code = "recipient_rejected", .message = detail });
    }

    /// RSET after a failure inside a transaction; if it fails the
    /// connection is not used again.
    fn resetTransaction(self: *Session, ctx: *const Ctx) void {
        if (self.broken) return;
        const w = self.stream.writer();
        w.writeAll("RSET\r\n") catch {
            self.broken = true;
            return;
        };
        w.flush() catch {
            self.broken = true;
            return;
        };
        const r = reply_mod.read(self.stream.reader(), ctx.arena) catch {
            self.broken = true;
            return;
        };
        if (r.code != 250) self.broken = true;
    }

    /// EHLO and QUIT on a fresh connection: whether the server answers
    /// (the readiness check). The settings are the client's.
    pub fn probe(gpa: std.mem.Allocator, ctx: *const Ctx, map: db.ErrorMap, s: *const Settings) anyerror!void {
        const self = try open(gpa, ctx, map, &.{
            .host = s.host,
            .port = s.port,
            .tls_mode = s.tls_mode,
            .tls = s.tls,
            .username = null,
            .password = null,
            .helo = s.helo,
            .connect_timeout = s.connect_timeout,
            .loopback = s.loopback,
        });
        self.close(true);
    }
};
