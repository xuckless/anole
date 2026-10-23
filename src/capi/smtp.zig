//! `anole_smtp_*`: the configuration's mail servers ("mail"), used without
//! blocking the caller. A send copies the message into a command for an
//! executor (the one that serves the request it names, or the consumer's
//! next), whose task composes it and runs it on the `anole.smtp` client,
//! then queues `ANOLE_EV_SMTP_RESULT` on the ring that feeds the consumer.
//!
//! Addresses, header values and attachment names are checked on the
//! caller's thread (`mime.validate`), so a mistake is `ANOLE_E_INVALID` at
//! the call, with `anole_last_error` saying which; everything else, a
//! refused recipient, a server that is down, is in the result.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const db_cap = @import("db.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;
const db = anole.db;

const smtp = if (features.smtp) anole.smtp else struct {
    pub const Client = void;
};

const ms = std.Io.Duration.fromMilliseconds;

/// One configured mail server (`anole_smtp *` in C).
pub const Mail = struct {
    engine: *Engine,
    config: config_mod.Config.Mail,
    index: u32,
    client: ?*smtp.Client = null,
    open: std.atomic.Value(bool) = .init(false),
};

/// Engine-wide state (`Engine.smtp_state`).
pub const State = struct {
    lock: std.atomic.Mutex = .unlocked,
    mails: []Mail = &.{},
    made: bool = false,

    pub fn init(s: *State, first_gen: u32) void {
        _ = s;
        _ = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`): none, a mail
    /// server has no handles.
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        if (s.mails.len > 0) gpa.free(s.mails);
        s.mails = &.{};
    }

    /// The `Mail`s, made once from the configuration (`find` may come
    /// before the server starts).
    fn ensure(s: *State, e: *Engine) ![]Mail {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
        defer s.lock.unlock();
        if (s.made) return s.mails;
        const list = e.config.mail;
        if (list.len > 0) {
            const mails = try gpa.alloc(Mail, list.len);
            for (list, mails, 0..) |c, *m, i| m.* = .{ .engine = e, .config = c, .index = @intCast(i) };
            s.mails = mails;
        }
        s.made = true;
        return s.mails;
    }
};

/// Per executor (`Exec.smtp`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        _ = st;
        return 0;
    }

    pub fn deinit(st: *ExecState) void {
        _ = st;
    }
};

// ---------------------------------------------------------------------------
// Opening

fn optMs(n: u32) ?std.Io.Duration {
    return if (n > 0) ms(n) else null;
}

fn optionsOf(m: *const Mail) anole.smtp.Options {
    const c = m.config;
    const sm = c.smtp;
    return .{
        .url = sm.url,
        .from = sm.from,
        .username = sm.username,
        .password = sm.password,
        .tls_mode = std.meta.stringToEnum(anole.smtp.Options.TlsMode, sm.tls_mode).?,
        .tls = .{
            .ca = if (sm.ca_file) |f| .{ .file = f } else if (sm.ca_pem) |pem| .{ .pem = pem } else null,
            .client_certificate = if (sm.client_cert_file) |f|
                dusty.Cert.fromFiles(f, sm.client_key_file.?)
            else if (sm.client_cert_pem) |pem|
                dusty.Cert.fromPem(pem, sm.client_key_pem.?)
            else
                null,
            .insecure_skip_verify = sm.insecure_skip_verify,
        },
        .helo_name = sm.helo_name,
        .name = c.name,
        .max_connections = sm.max_connections,
        .max_messages_per_connection = sm.max_messages_per_connection,
        .idle_timeout = ms(sm.idle_timeout_ms),
        .acquire_timeout = ms(sm.acquire_timeout_ms),
        .connect_timeout = ms(sm.connect_timeout_ms),
        .timeout = optMs(c.timeout_ms),
        .min_throughput = sm.min_throughput,
        .max_message_bytes = sm.max_message_bytes,
        .errors = c.errors,
        .retry = .{
            .attempts = c.retry.attempts,
            .backoff = .{ .base = ms(c.retry.base_ms), .max = ms(c.retry.max_ms), .multiplier = c.retry.multiplier },
            .attempt_timeout = optMs(c.retry.attempt_timeout_ms),
            .max_retry_after = ms(c.retry.max_retry_after_ms),
        },
        .breaker = if (c.breaker) |b| .{
            .consecutive_failures = b.consecutive_failures,
            .failure_ratio = b.failure_ratio,
            .min_calls = b.min_calls,
            .window = ms(b.window_ms),
            .open_for = ms(b.open_ms),
            .max_open_for = ms(b.max_open_ms),
            .half_open_calls = b.half_open_calls,
        } else null,
        .readiness = sm.readiness,
    };
}

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    const mails = try e.smtp_state.ensure(e);
    for (mails) |*m| {
        if (comptime !features.smtp) unreachable;
        // A missing SMTP_URL in production is a configuration error; the
        // text is the one the log gets.
        const production = app.environment() == .production;
        const sm = m.config.smtp;
        if (production and sm.url == null and anole.db.env(null, "SMTP_URL") == null) {
            var w: std.Io.Writer = .fixed(&e.explained);
            w.print("mail[{d}] \"{s}\": SMTP_URL is not set; mail would go to a local test server. Set smtp.url or the SMTP_URL environment variable", .{ m.index, m.config.name }) catch {};
            e.explained_len = w.end;
            return error.InvalidOptions;
        }
        m.client = app.smtp(optionsOf(m)) catch |err| {
            if (e.explained_len == 0) {
                var w: std.Io.Writer = .fixed(&e.explained);
                w.print("mail[{d}] \"{s}\": the SMTP settings are not valid ({t}); the log says which", .{ m.index, m.config.name, err }) catch {};
                e.explained_len = w.end;
            }
            return err;
        };
        m.open.store(true, .release);
    }
}

/// The drain started (`anole_server_drain`, once): no new send is taken;
/// those in flight finish, and the client closes with the server.
pub fn draining(e: *Engine) void {
    if (comptime !features.smtp) return;
    for (e.smtp_state.mails) |*m| if (m.client) |c| c.stopAccepting();
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    for (e.smtp_state.mails) |*m| m.open.store(false, .release);
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    _ = e;
}

pub fn find(e: *Engine, name: []const u8) ?*Mail {
    const mails = e.smtp_state.ensure(e) catch return null;
    for (mails) |*m| if (std.mem.eql(u8, m.config.name, name)) return m;
    return null;
}

// ---------------------------------------------------------------------------
// Sending

pub const CallError = error{ Invalid, State, OutOfMemory, Unsupported, Gone };

/// Why a call is `Invalid`, for `anole_last_error`.
pub const Why = struct {
    buf: [320]u8 = undefined,
    len: usize = 0,

    fn set(w: *Why, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&w.buf, fmt, args) catch w.buf[0..w.buf.len];
        w.len = out.len;
    }

    pub fn text(w: *const Why) []const u8 {
        return w.buf[0..w.len];
    }
};

fn checkOpen(m: *Mail) CallError!void {
    if (comptime !features.smtp) return error.Unsupported;
    switch (m.engine.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!m.open.load(.acquire) or m.client == null) return error.State;
}

const Raw = struct {
    envelope_from: []const u8,
    to: []const []const u8,
    bytes: []const u8,
};

const Body = union(enum) {
    message: if (features.smtp) anole.smtp.Message else void,
    raw: Raw,
};

/// A send in flight: one arena holding the command and a copy of
/// everything the call passed.
const Req = struct {
    cmd: Command = .{ .run = run },
    mail: *Mail,
    user_data: u64,
    flags: u32,
    timeout_ms: u32,
    /// The request or gRPC call this serves (0: none), and what ties it to
    /// that request's end.
    req: u64,
    tied: db_cap.Tied = .{ .cut = cutReq },
    end_request: bool = false,
    task: ?placement.Task = null,
    arena: std.heap.ArenaAllocator,
    body: Body,

    /// The request ended unanswered (on its executor).
    fn cutReq(t: *db_cap.Tied) void {
        const q: *Req = @fieldParentPtr("tied", t);
        q.end_request = true;
        if (q.task) |tk| placement.cancelTask(tk);
    }

    fn free(q: *Req) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn run(cmd: *Command, x: *Exec) void {
        const q: *Req = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        if (q.req != 0) {
            const h = Handle.decode(q.req);
            if (!db_cap.slotLive(x, h)) {
                postGone(x, q);
                return q.free();
            }
            db_cap.linkTied(x, h.slot, &q.tied);
        }
        placement.concurrent(&x.smtp.work, x.engine.io, .local, task, .{ x, q }) catch {
            if (q.req != 0) db_cap.unlinkTied(x, Handle.decode(q.req).slot, &q.tied);
            q.free();
        };
    }
};

/// The executor that serves a call: the request's, or the consumer's next.
fn pickExec(m: *Mail, c: ?*Consumer, req: u64) CallError!*Exec {
    const e = m.engine;
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    if (req != 0) return db_cap.resolveReq(e, req, c) catch |err| switch (err) {
        error.Gone => error.Gone,
        error.State => error.State,
        else => error.Invalid,
    };
    const cc = c orelse return error.Invalid;
    if (cc.execs.items.len == 0) return error.State;
    const i = cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len;
    return cc.execs.items[i];
}

const max_list = 1000;
const max_headers = 128;
const max_attachments = 256;

fn dupeStr(a: std.mem.Allocator, s: abi.Str) std.mem.Allocator.Error![]const u8 {
    return a.dupe(u8, s.slice());
}

/// `null` for `{NULL,0}`, else a copy (possibly empty).
fn dupeOpt(a: std.mem.Allocator, s: abi.Str) std.mem.Allocator.Error!?[]const u8 {
    if (s.ptr == null) return null;
    return try a.dupe(u8, s.slice());
}

fn dupeList(a: std.mem.Allocator, list: ?[*]const abi.Str, n: usize, why: *Why, what: []const u8) CallError![]const []const u8 {
    if (n == 0) return &.{};
    if (n > max_list) {
        why.set("{s}: {d} entries; at most {d}", .{ what, n, max_list });
        return error.Invalid;
    }
    const src = (list orelse return error.Invalid)[0..n];
    const out = try a.alloc([]const u8, n);
    for (src, out) |s, *o| o.* = try dupeStr(a, s);
    return out;
}

/// The message in `a`, ready for `anole.smtp`.
fn copyMessage(a: std.mem.Allocator, m: abi.SmtpMessage, why: *Why) CallError!anole.smtp.Message {
    var out: anole.smtp.Message = .{
        .from = try dupeOpt(a, m.from),
        .reply_to = try dupeOpt(a, m.reply_to),
        .to = try dupeList(a, m.to, m.nto, why, "to"),
        .cc = try dupeList(a, m.cc, m.ncc, why, "cc"),
        .bcc = try dupeList(a, m.bcc, m.nbcc, why, "bcc"),
        .subject = try dupeStr(a, m.subject),
        .text = try dupeOpt(a, m.text),
        .html = try dupeOpt(a, m.html),
        .envelope_from = try dupeOpt(a, m.envelope_from),
        .message_id = try dupeOpt(a, m.message_id),
    };
    if (m.nheaders > 0) {
        if (m.nheaders > max_headers) {
            why.set("headers: {d} entries; at most {d}", .{ m.nheaders, max_headers });
            return error.Invalid;
        }
        const src = (m.headers orelse return error.Invalid)[0..m.nheaders];
        const hs = try a.alloc(anole.smtp.Header, src.len);
        for (src, hs) |h, *o| o.* = .{ try dupeStr(a, h.name), try dupeStr(a, h.value) };
        out.headers = hs;
    }
    if (m.nattachments > 0) {
        if (m.nattachments > max_attachments) {
            why.set("attachments: {d} entries; at most {d}", .{ m.nattachments, max_attachments });
            return error.Invalid;
        }
        const src = (m.attachments orelse return error.Invalid)[0..m.nattachments];
        const atts = try a.alloc(anole.smtp.Attachment, src.len);
        for (src, atts, 0..) |s, *o, i| {
            if (s.size != @sizeOf(abi.SmtpAttachment)) {
                why.set("attachments[{d}].size must be sizeof(anole_smtp_attachment)", .{i});
                return error.Invalid;
            }
            if (s.flags & ~abi.SMTP_ATTACH_F_INLINE != 0 or s.reserved != 0) {
                why.set("attachments[{d}]: an unknown flag", .{i});
                return error.Invalid;
            }
            const has_path = s.path.len > 0;
            if (has_path and (s.len > 0 or s.data != null)) {
                why.set("attachments[{d}]: data or path, not both", .{i});
                return error.Invalid;
            }
            if (s.flags & abi.SMTP_ATTACH_F_INLINE != 0 and s.content_id.len == 0) {
                why.set("attachments[{d}]: INLINE needs a content_id", .{i});
                return error.Invalid;
            }
            o.* = .{
                .filename = try dupeStr(a, s.filename),
                .content_type = try dupeOpt(a, s.content_type),
                .content = if (has_path)
                    .{ .file = try dupeStr(a, s.path) }
                else if (s.len == 0)
                    .{ .bytes = "" }
                else
                    .{ .bytes = try a.dupe(u8, (s.data orelse return error.Invalid)[0..s.len]) },
                .content_id = if (s.content_id.len > 0) try dupeStr(a, s.content_id) else null,
            };
        }
        out.attachments = atts;
    }
    return out;
}

fn newReq(m: *Mail, user_data: u64, opts: abi.SmtpOptions) CallError!*Req {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const q = try arena.allocator().create(Req);
    q.* = .{
        .mail = m,
        .user_data = user_data,
        .flags = opts.flags,
        .timeout_ms = opts.timeout_ms,
        .req = opts.req,
        .arena = arena,
        .body = undefined,
    };
    return q;
}

/// `anole_smtp_send`.
pub fn send(m: *Mail, c: ?*Consumer, msg: abi.SmtpMessage, opts: abi.SmtpOptions, user_data: u64, why: *Why) CallError!void {
    if (comptime !features.smtp) return error.Unsupported;
    try checkOpen(m);
    if (opts.flags & ~abi.SMTP_F_RETRY != 0) {
        why.set("flags: a bit this library does not know", .{});
        return error.Invalid;
    }
    const x = try pickExec(m, c, opts.req);
    const q = try newReq(m, user_data, opts);
    errdefer q.free();
    const message = try copyMessage(q.arena.allocator(), msg, why);
    // Refuse what can be refused now; the rest is composed on the executor.
    {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var failure: anole.smtp.mime.Failure = .{};
        anole.smtp.mime.validate(scratch.allocator(), message, .{ .from = m.client.?.from }, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                why.set("{s}", .{failure.message});
                return error.Invalid;
            },
        };
    }
    q.body = .{ .message = message };
    x.post(&q.cmd);
}

/// `anole_smtp_send_raw`.
pub fn sendRaw(m: *Mail, c: ?*Consumer, envelope_from: abi.Str, recipients: ?[*]const abi.Str, n: usize, bytes: []const u8, opts: abi.SmtpOptions, user_data: u64, why: *Why) CallError!void {
    if (comptime !features.smtp) return error.Unsupported;
    try checkOpen(m);
    if (opts.flags & ~abi.SMTP_F_RETRY != 0) {
        why.set("flags: a bit this library does not know", .{});
        return error.Invalid;
    }
    if (n == 0) {
        why.set("the envelope has no recipients", .{});
        return error.Invalid;
    }
    const x = try pickExec(m, c, opts.req);
    const q = try newReq(m, user_data, opts);
    errdefer q.free();
    const a = q.arena.allocator();
    const to = try dupeList(a, recipients, n, why, "recipients");
    for (to) |t| {
        _ = anole.smtp.address.parse(a, t) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAddress => {
                why.set("recipients: \"{s}\" is not a mailbox", .{t[0..@min(t.len, 80)]});
                return error.Invalid;
            },
        };
    }
    if (envelope_from.len > 0) {
        _ = anole.smtp.address.parse(a, envelope_from.slice()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAddress => {
                why.set("envelope_from is not a mailbox", .{});
                return error.Invalid;
            },
        };
    }
    q.body = .{ .raw = .{
        .envelope_from = try dupeStr(a, envelope_from),
        .to = to,
        .bytes = try a.dupe(u8, bytes),
    } };
    x.post(&q.cmd);
}

/// The answer of a send whose `req` ended first: `ANOLE_E_GONE`.
fn postGone(x: *Exec, q: *const Req) void {
    const rec = resultRecord(.{
        .user_data = q.user_data,
        .status = abi.E_GONE,
        .message = "the request it served ended (aborted or past its deadline)",
    }) catch return;
    x.postRecord(rec, false);
}

fn httpStatusOf(err: anyerror) u16 {
    return switch (err) {
        error.BadRequest => 400,
        error.NotFound => 404,
        error.Conflict => 409,
        error.UnprocessableEntity => 422,
        error.ServiceUnavailable => 503,
        error.GatewayTimeout => 504,
        else => 500,
    };
}

/// The reply code a failure message starts with ("550 5.1.1 ..."), or 0.
fn codeOf(message: []const u8) u16 {
    if (message.len < 3) return 0;
    return std.fmt.parseInt(u16, message[0..3], 10) catch 0;
}

fn task(x: *Exec, q: *Req) std.Io.Cancelable!void {
    defer {
        if (q.req != 0) db_cap.unlinkTied(x, Handle.decode(q.req).slot, &q.tied);
        q.free();
    }
    q.task = placement.currentTask(x.engine.io);
    if (q.end_request) return postGone(x, q);
    if (comptime !features.smtp) return;
    const m = q.mail;
    if (!m.open.load(.acquire)) return;
    const cl = m.client orelse return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = x.engine.io, .arena = arena.allocator() };
    const timeout: ?std.Io.Duration = if (q.timeout_ms == abi.DB_TIMEOUT_NONE) .max else if (q.timeout_ms > 0) ms(q.timeout_ms) else null;
    const call = cl.with(.{ .timeout = timeout, .retry = q.flags & abi.SMTP_F_RETRY != 0 });
    const out = switch (q.body) {
        .message => |msg| call.send(&ctx, msg),
        .raw => |r| call.sendRaw(&ctx, .{ .from = r.envelope_from, .to = r.to }, r.bytes),
    };
    var data: ResultData = .{ .user_data = q.user_data };
    if (out) |sent| {
        data.message_id = sent.message_id;
        data.response = sent.response;
        data.smtp_code = sent.code;
        data.rejected = sent.rejected;
    } else |err| {
        if (err == error.Canceled) {
            // Cut with its request: the answer is GONE. Canceled at the
            // stop, it answers nothing.
            if (q.end_request) return postGone(x, q);
            return error.Canceled;
        }
        data.status = if (err == error.GatewayTimeout) abi.E_TIMEOUT else abi.E_SERVICE;
        data.http_status = httpStatusOf(err);
        if (db.lastError(&ctx)) |detail| {
            data.error_class = std.meta.stringToEnum(abi.DbErrorClass, @tagName(detail.class)) orelse .other;
            data.message = detail.message;
            data.code = detail.code;
            data.smtp_code = codeOf(detail.message);
        } else {
            data.error_class = .other;
            data.message = @errorName(err);
        }
    }
    const rec = resultRecord(data) catch return;
    x.postRecord(rec, true);
}

// ---------------------------------------------------------------------------
// Records

const Writer = struct {
    rec: []u8,
    at: usize,

    fn put(w: *Writer, bytes: []const u8) abi.Span {
        if (bytes.len == 0) return .{};
        @memcpy(w.rec[w.at..][0..bytes.len], bytes);
        defer w.at += bytes.len;
        return .{ .off = @intCast(w.at), .len = @intCast(bytes.len) };
    }
};

const Rejected = if (features.smtp) anole.smtp.Rejected else struct {
    address: []const u8,
    code: u16,
    message: []const u8,
};

const ResultData = struct {
    user_data: u64,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: abi.DbErrorClass = .none,
    smtp_code: u16 = 0,
    message_id: []const u8 = "",
    response: []const u8 = "",
    rejected: []const Rejected = &.{},
    message: []const u8 = "",
    code: []const u8 = "",
};

fn resultRecord(r: ResultData) ![]align(8) u8 {
    const Ev = abi.SmtpResultEvent;
    var bytes: usize = r.message_id.len + r.response.len + r.message.len + r.code.len;
    for (r.rejected) |j| bytes += j.address.len + j.message.len;
    const rejected_off = @sizeOf(Ev);
    const bytes_off = rejected_off + r.rejected.len * @sizeOf(abi.SmtpRejected);
    const rec = try engine.newRecord(bytes_off + bytes, .smtp_result, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = bytes_off };
    ev.user_data = r.user_data;
    ev.status = r.status;
    ev.http_status = r.http_status;
    ev.error_class = @backingInt(r.error_class);
    ev.smtp_code = r.smtp_code;
    ev.nrejected = @intCast(r.rejected.len);
    ev.message_id = w.put(r.message_id);
    ev.response = w.put(r.response);
    ev.rejected_off = @intCast(rejected_off);
    ev.@"error" = w.put(r.message);
    ev.error_code = w.put(r.code);
    const items: [*]abi.SmtpRejected = @ptrCast(@alignCast(rec.ptr + rejected_off));
    for (r.rejected, 0..) |j, i| {
        items[i] = .{
            .address = w.put(j.address),
            .code = j.code,
            .reserved = 0,
            .reserved2 = 0,
            .message = w.put(j.message),
        };
    }
    return rec;
}
