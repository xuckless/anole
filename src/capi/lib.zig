//! libanole: the C ABI (`include/anole.h`) over `anole.capi`. The root of
//! `zig build capi`; every exported symbol is `anole_*`. This file only
//! translates: C arguments in, status codes and `anole_last_error` (text,
//! name and errno) out.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("anole");
const capi_options = @import("capi_options");
const engine = anole.capi;
const abi = engine.abi;
const Engine = engine.Engine;
const Consumer = engine.Consumer;
const Handle = engine.Handle;
const Str = abi.Str;
const Header = abi.Header;

pub const zio_options = anole.zio_options;
/// A panic goes to the binding's log callback (when it set one) as one error
/// line with its stack trace, and to standard error as Zig prints it (the
/// callback only queues the line, and the process aborts before a binding
/// could flush it).
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (anole.log.hasSink()) anole.logPanic(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr);
}
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = if (builtin.mode == .debug) .debug else .info,
    .log_scope_levels = &.{
        .{ .scope = .zio, .level = .info },
        .{ .scope = .anole, .level = .info },
        .{ .scope = .anole_h2, .level = .info },
        .{ .scope = .anole_h3, .level = .info },
    },
};

// ---- logging ---------------------------------------------------------------------

/// A server's log callback and its user data, read as one: never a torn
/// pair.
const LogTarget = struct { f: abi.LogFn, ud: ?*anyopaque };

var log_target: std.atomic.Value(?*const LogTarget) = .init(null);

fn levelOf(l: std.log.Level) u32 {
    return switch (l) {
        .err => abi.LOG_ERROR,
        .warn => abi.LOG_WARN,
        .info => abi.LOG_INFO,
        .debug => abi.LOG_DEBUG,
    };
}

fn stdLevel(abi_level: u32) std.log.Level {
    return switch (abi_level) {
        abi.LOG_ERROR => .err,
        abi.LOG_WARN => .warn,
        abi.LOG_DEBUG => .debug,
        else => .info,
    };
}

/// Every log record (a std.log line, `anole.log`, the access log) goes to
/// the binding's callback: in the JSON format the whole record, else the
/// message.
fn logSink(_: ?*anyopaque, level: std.log.Level, scope: []const u8, line: []const u8) void {
    const t = log_target.load(.acquire) orelse return;
    t.f(t.ud, levelOf(level), Str.of(scope), Str.of(line));
}

var log_callback: anole.log.Callback = .{ .func = logSink };

// ---- the last error, per thread --------------------------------------------------

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;
threadlocal var last_error_name: []const u8 = "";
threadlocal var last_errno: i32 = 0;

fn setText(comptime fmt: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&last_error_buf);
    w.print(fmt, args) catch {};
    last_error_len = w.end;
}

fn clearError() void {
    last_error_len = 0;
    last_error_name = "";
    last_errno = 0;
}

/// Sets all three (text, token, errno) and returns `code`.
fn named(code: i32, name: []const u8, errno: i32, comptime fmt: []const u8, args: anytype) i32 {
    setText(fmt, args);
    last_error_name = name;
    last_errno = errno;
    return code;
}

fn genericName(code: i32) []const u8 {
    return switch (code) {
        abi.E_INVALID => "Invalid",
        abi.E_GONE => "Gone",
        abi.E_AGAIN => "Again",
        abi.E_NOMEM => "NoMemory",
        abi.E_CONFIG => "Config",
        abi.E_STATE => "State",
        abi.E_UNSUPPORTED => "Unsupported",
        abi.E_TOOBIG => "TooBig",
        abi.E_SYSTEM => "System",
        abi.E_TIMEOUT => "Timeout",
        abi.E_DB => "Database",
        abi.E_BROKER => "Broker",
        abi.E_SERVICE => "Service",
        else => "Unexpected",
    };
}

/// An error answer with the code's own text and name, so `anole_last_error`
/// never shows what an earlier call left (every non-OK answer sets it).
fn failCode(code: i32) i32 {
    setText("{s}", .{switch (code) {
        abi.E_INVALID => "invalid argument (status, header, flag or size)",
        abi.E_GONE => "stale handle: answered, expired, aborted, closed or never valid",
        abi.E_AGAIN => "nothing now; an event follows",
        abi.E_NOMEM => "out of memory",
        abi.E_CONFIG => "invalid configuration",
        abi.E_STATE => "not allowed in this state",
        abi.E_UNSUPPORTED => "not built in, or not on this OS",
        abi.E_TOOBIG => "too big (the next event does not fit the buffer, or past a size limit)",
        abi.E_SYSTEM => "the OS refused",
        abi.E_TIMEOUT => "the timeout passed",
        abi.E_DB => "the database refused the statement",
        abi.E_BROKER => "the message broker refused the call or could not be reached",
        abi.E_SERVICE => "the object store or mail server refused the call or could not be reached",
        else => "error",
    }});
    last_error_name = genericName(code);
    last_errno = 0;
    return code;
}

/// A failure from a Zig call: the error's token and OS error.
fn fail(code: i32, comptime what: []const u8, err: anyerror) i32 {
    return named(code, engine.errorName(err), engine.errorErrno(err), what ++ ": {t}", .{err});
}

/// The caller's `size` field read against what this library knows: what it
/// covers, the rest zero. Bytes past what the library knows must be zero.
fn readSized(comptime T: type, p: *const T) error{ Small, UnknownField }!T {
    const size = p.size;
    if (size < @sizeOf(usize)) return error.Small;
    var out = std.mem.zeroes(T);
    const bytes_in: [*]const u8 = @ptrCast(p);
    const n = @min(size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&out)[0..n], bytes_in[0..n]);
    if (size > @sizeOf(T)) for (bytes_in[@sizeOf(T)..size]) |b| if (b != 0) return error.UnknownField;
    return out;
}

/// `readSized`'s failure as an answer.
fn sizedFailure(err: error{ Small, UnknownField }) i32 {
    return switch (err) {
        error.Small => named(abi.E_INVALID, "Invalid", 0, "the options struct's size is below sizeof(size_t)", .{}),
        error.UnknownField => named(abi.E_INVALID, "UnknownField", 0, "the options struct is larger than this library knows and has a non-zero field past it", .{}),
    };
}

fn unknownFlag() i32 {
    return named(abi.E_INVALID, "UnknownFlag", 0, "a flag bit this library does not know is set", .{});
}

fn wrongKind() i32 {
    return named(abi.E_INVALID, "WrongHandleKind", 0, "the handle is 0 or of another kind than this call takes", .{});
}

/// The server a pointer names, if it is the process's own: a NULL, a
/// pointer kept past `destroy` and one from before a `fork` are not.
fn engineOf(s: ?*anyopaque) ?*Engine {
    const e: *Engine = @ptrCast(@alignCast(s orelse return null));
    return if (engine.global == e) e else null;
}

fn consumerOf(c: ?*anyopaque) ?*Consumer {
    const consumer: *Consumer = @ptrCast(@alignCast(c orelse return null));
    return if (engine.global == consumer.engine) consumer else null;
}

/// The answer for a pointer `engineOf` or `consumerOf` refused.
fn badPointer(p: ?*anyopaque) i32 {
    if (p == null) return failCode(abi.E_INVALID);
    return named(abi.E_STATE, "State", 0, "this server belongs to a parent process, or was destroyed", .{});
}

fn bytes(p: ?*const anyopaque, len: usize) ?[]const u8 {
    const q: [*]const u8 = @ptrCast(p orelse return if (len == 0) "" else null);
    return q[0..len];
}

fn headersOf(h: ?[*]const Header, n: usize) ?[]const Header {
    if (n == 0) return &.{};
    return (h orelse return null)[0..n];
}

/// An answer or data call's result.
fn answer(e: engine.AnswerError) i32 {
    return switch (e) {
        error.Gone => failCode(abi.E_GONE),
        error.Invalid => failCode(abi.E_INVALID),
        error.OutOfMemory => failCode(abi.E_NOMEM),
        error.Unsupported => failCode(abi.E_UNSUPPORTED),
        error.Timeout => failCode(abi.E_TIMEOUT),
        error.Again => failCode(abi.E_AGAIN),
        error.State => named(abi.E_STATE, "State", 0, "not in this state (a second message for a unary answer, metadata after the first message, OK without a response message, ...)", .{}),
        error.TooBig => failCode(abi.E_TOOBIG),
        error.WrongKind => wrongKind(),
        // A cleanup outcome reaching an answer call: the object is over.
        error.Over => failCode(abi.E_GONE),
        error.System => named(abi.E_SYSTEM, "System", engine.engine_errno, "the OS refused", .{}),
    };
}

/// A cleanup call's result: an object that is already over is success, and
/// leaves `anole_last_error` alone.
fn cleanup(err: engine.AnswerError) i32 {
    return switch (err) {
        error.Over => abi.OK,
        else => answer(err),
    };
}

fn live() ?*Engine {
    return engine.global;
}

/// Whether `h` is no handle of `kind` (0 and other kinds are misuse).
fn badKind(h: u64, kind: Handle.Kind) bool {
    return h == 0 or Handle.decode(h).kind != kind or Handle.decode(h).gen == 0;
}

// ---- basics ------------------------------------------------------------------------

export fn anole_last_error() Str {
    return .{ .ptr = &last_error_buf, .len = last_error_len };
}

export fn anole_last_error_name() Str {
    return Str.of(last_error_name);
}

export fn anole_last_errno() i32 {
    return last_errno;
}

export fn anole_abi_version() u32 {
    return abi.version;
}

export fn anole_version() Str {
    return Str.of(capi_options.version);
}

export fn anole_has_feature(name: Str) i32 {
    const f = anole.features;
    const n = name.slice();
    const table = .{
        .{ "tls", f.tls == .boringssl },
        .{ "http2", f.http2 },
        .{ "http3", f.http3 },
        .{ "webtransport", f.http3 },
        .{ "websocket", f.websocket },
        .{ "compression", f.compression },
        .{ "brotli", f.brotli },
        .{ "auth", f.auth },
        .{ "grpc", f.grpc },
        .{ "sqlite", f.sqlite },
        .{ "postgres", f.postgres },
        .{ "redis", f.redis },
        .{ "mongodb", f.mongodb },
        .{ "nats", f.nats },
        .{ "kafka", f.kafka },
        .{ "console", f.console },
        .{ "net", f.net },
        .{ "jobs", f.jobs },
        .{ "webhooks", f.webhooks },
        .{ "s3", f.s3 },
        .{ "smtp", f.smtp },
        .{ "lambda", f.lambda },
    };
    inline for (table) |entry| if (std.mem.eql(u8, n, entry[0])) return @intFromBool(entry[1]);
    return 0;
}

// ---- lifecycle --------------------------------------------------------------------

var atfork_registered: std.atomic.Value(bool) = .init(false);

/// In a forked child: the parent's server is not the child's. Every call
/// given its pointers answers ANOLE_E_STATE, handle calls answer as for "no
/// server", and a new server may be created (the parent's memory is leaked
/// in the child by design).
fn afterForkInChild() callconv(.c) void {
    engine.global = null;
    anole.log.setSink(null);
    log_target.store(null, .release);
}

fn registerAtFork() void {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) return;
    if (atfork_registered.swap(true, .acq_rel)) return;
    _ = std.c.pthread_atfork(null, null, afterForkInChild);
}

export fn anole_server_create(options: ?*const abi.ServerOptions, out: ?*?*anyopaque) i32 {
    clearError();
    const o = readSized(abi.ServerOptions, options orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const dst = out orelse return failCode(abi.E_INVALID);
    if (engine.global != null) return named(abi.E_STATE, "OneServerPerProcess", 0, "one anole_server per process", .{});
    if (o.log_level > abi.LOG_DEBUG) return named(abi.E_INVALID, "Invalid", 0, "log_level: 0 or ANOLE_LOG_ERROR..ANOLE_LOG_DEBUG", .{});
    if (o.flags & ~abi.SERVER_F_SIGNALS != 0) return unknownFlag();
    registerAtFork();
    const json = o.config_json.slice();
    var why_buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = Engine.create(if (json.len == 0) "{}" else json, o.flags & abi.SERVER_F_SIGNALS != 0, &why) catch |err| switch (err) {
        error.Config => return named(abi.E_CONFIG, engine.config.last_problem, 0, "{s}", .{why.buffered()}),
        error.OutOfMemory => return fail(abi.E_NOMEM, "anole_server_create", err),
        // The modes: ANOLE_ENV, ANOLE_DEPLOYMENT, PORT, ANOLE_PROXY_TRUSTED, "deployment": "lambda".
        else => |other| return named(abi.E_CONFIG, engine.errorName(other), 0, "{s}", .{if (why.buffered().len > 0) why.buffered() else @errorName(other)}),
    };
    anole.log.setLevel(stdLevel(if (o.log_level == 0) abi.LOG_INFO else o.log_level));
    // This server's log callback, or stderr (a later server without one
    // does not inherit an earlier one's).
    if (o.log) |f| {
        if (std.heap.c_allocator.create(LogTarget)) |t| {
            t.* = .{ .f = f, .ud = o.log_ud };
            log_target.store(t, .release);
            anole.log.setSink(&log_callback);
        } else |_| {
            log_target.store(null, .release);
            anole.log.setSink(null);
        }
    } else {
        log_target.store(null, .release);
        anole.log.setSink(null);
    }
    dst.* = e;
    return abi.OK;
}

/// A start or open that failed, as an answer.
fn startFailure(e: *Engine, err: anyerror, comptime what: []const u8) i32 {
    const explained = e.explained[0..e.explained_len];
    // Which listener could not be bound, in the text.
    if (e.failed_listener) |i| if (i < e.listeners.len) {
        const l = &e.listeners[i];
        // The log's own words: what could not be done, why, and the way out.
        if (explained.len > 0) return named(
            if (l.error_errno != 0) abi.E_SYSTEM else abi.E_CONFIG,
            l.error_name,
            l.error_errno,
            "{s}",
            .{explained},
        );
        return named(
            if (l.error_errno != 0) abi.E_SYSTEM else abi.E_CONFIG,
            l.error_name,
            l.error_errno,
            what ++ ": listener \"{s}\" ({s}): {s}",
            .{ l.name, l.cfg_address, l.error_name },
        );
    };
    switch (err) {
        error.State => return named(abi.E_STATE, "State", 0, what ++ ": not allowed in this state", .{}),
        error.NoConsumer => return named(abi.E_STATE, "NoConsumer", 0, "{s}", .{e.start_why[0..e.start_why_len]}),
        error.ConsumerWithoutExecutor => return named(abi.E_STATE, "ConsumerWithoutExecutor", 0, "{s}", .{e.start_why[0..e.start_why_len]}),
        // Two routes of the configuration (or one and a route Anole adds,
        // such as metrics) that the router cannot tell apart.
        error.RouteConflict => return named(abi.E_CONFIG, "RouteConflict", 0, "routes: {s}", .{e.start_why[0..e.start_why_len]}),
        error.OutOfMemory => return fail(abi.E_NOMEM, what, err),
        error.DatabaseUnavailable => {
            if (explained.len > 0) return named(abi.E_SYSTEM, "DatabaseUnavailable", engine.errorErrno(err), "{s}", .{explained});
            return named(abi.E_SYSTEM, "DatabaseUnavailable", engine.errorErrno(err), what ++ ": {t}", .{err});
        },
        else => {},
    }
    const token = engine.errorName(err);
    // A certificate, key or client CA that does not load is a configuration
    // problem; the OS refusing (a port, a file, a thread) is the system's.
    if (std.mem.eql(u8, token, "InvalidCertificate") or std.mem.eql(u8, token, "InvalidKey") or
        std.mem.eql(u8, token, "KeyMismatch") or std.mem.eql(u8, token, "InvalidClientCa"))
        return named(abi.E_CONFIG, token, 0, what ++ ": {t}", .{err});
    return named(abi.E_SYSTEM, token, engine.errorErrno(err), what ++ ": {t}", .{err});
}

export fn anole_server_open(s: ?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    e.open() catch |err| return startFailure(e, err, "anole_server_open");
    return abi.OK;
}

export fn anole_server_start(s: ?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    e.start() catch |err| return startFailure(e, err, "anole_server_start");
    return abi.OK;
}

export fn anole_server_set_ready(s: ?*anyopaque, check: Str, ready: u32) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    e.setReady(check.slice(), ready != 0) catch return named(abi.E_INVALID, "UnknownCheck", 0, "observe.health.checks has no check \"{s}\"", .{check.slice()});
    return abi.OK;
}

fn writeProblem(w: *std.Io.Writer, p: anole.config.Diagnostics.Problem, separator: bool) std.Io.Writer.Error!void {
    if (separator) try w.writeAll("; ");
    if (p.origin) |o| if (o.file) |file| {
        if (o.line != 0) try w.print("{s}:{d}: ", .{ file, o.line }) else try w.print("{s}: ", .{file});
    };
    try w.writeAll(if (p.detail.len > 0) p.detail else "problem");
}

/// One `.env` variable, for `anole_dotenv_read`.
pub const DotenvFn = *const fn (ud: ?*anyopaque, key: Str, value: Str, file: Str, line: u32) callconv(.c) void;

export fn anole_dotenv_read(dir: Str, environment: Str, f: ?DotenvFn, ud: ?*anyopaque) i32 {
    clearError();
    const callback = f orelse return named(abi.E_INVALID, "Invalid", 0, "fn is NULL", .{});
    const env_name = std.meta.stringToEnum(anole.Environment, environment.slice()) orelse
        return named(abi.E_INVALID, "UnknownEnvironment", 0, "environment: \"development\" or \"production\"", .{});
    const paths = anole.env.defaultFilesFor(env_name);
    if (paths.len == 0) return abi.OK;
    const tio = engine.threadedIo();
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var opened: ?std.Io.Dir = null;
    defer if (opened) |d| d.close(tio);
    if (dir.slice().len > 0) {
        opened = std.Io.Dir.cwd().openDir(tio, dir.slice(), .{}) catch |err|
            return named(abi.E_CONFIG, "InvalidEnvFile", 0, "cannot open directory \"{s}\": {t}", .{ dir.slice(), err });
    }
    var diag: anole.config.Diagnostics = .init(a);
    const files = anole.env.Files.load(a, tio, opened, paths, &diag) catch |err| switch (err) {
        error.OutOfMemory => return fail(abi.E_NOMEM, "anole_dotenv_read", err),
        error.InvalidEnvFile => {
            // Every problem that fits, by file and line; never a value.
            var w: std.Io.Writer = .fixed(&last_error_buf);
            const n = diag.problems.items.len;
            var shown: usize = 0;
            for (diag.problems.items) |p| {
                const before = w.end;
                writeProblem(&w, p, shown > 0) catch {
                    w.end = before;
                    break;
                };
                shown += 1;
            }
            if (shown < n) w.print(" (and {d} more)", .{n - shown}) catch {};
            last_error_len = w.end;
            last_error_name = "InvalidEnvFile";
            last_errno = 0;
            return abi.E_CONFIG;
        },
    };
    for (files.entries.keys(), files.entries.values()) |key, entry| {
        callback(ud, Str.of(key), Str.of(entry.value), Str.of(entry.file), entry.line);
    }
    return abi.OK;
}

export fn anole_server_listener_count(s: ?*anyopaque) u32 {
    const e = engineOf(s) orelse return 0;
    return @intCast(e.listeners.len);
}

export fn anole_server_listener(s: ?*anyopaque, i: u32, out: ?*abi.ListenerInfo) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    if (i >= e.listeners.len or dst.size < @sizeOf(usize)) return failCode(abi.E_INVALID);
    const l = &e.listeners[i];
    // The fields are written before the state that publishes them: read
    // again if it moved meanwhile.
    var info: abi.ListenerInfo = undefined;
    while (true) {
        const st = l.state.load(.acquire);
        info = .{
            .size = @sizeOf(abi.ListenerInfo),
            .name = Str.of(l.name),
            .address = Str.of(l.address(st)),
            .port = if (st == abi.LISTENER_PENDING) 0 else l.port,
            .udp_port = if (st == abi.LISTENER_PENDING) 0 else l.udp_port,
            .flags = l.flags,
            .state = st,
            .error_errno = if (st == abi.LISTENER_FAILED) l.error_errno else 0,
            .error_name = if (st == abi.LISTENER_FAILED) Str.of(l.error_name) else .{},
        };
        if (l.state.load(.acquire) == st) break;
    }
    const n = @min(dst.size, @sizeOf(abi.ListenerInfo));
    @memcpy(@as([*]u8, @ptrCast(dst))[@sizeOf(usize)..n], std.mem.asBytes(&info)[@sizeOf(usize)..n]);
    return abi.OK;
}

export fn anole_server_drain(s: ?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    e.drain() catch |err| return named(abi.E_STATE, "State", 0, "anole_server_drain: {t} (before anole_server_start has succeeded)", .{err});
    return abi.OK;
}

export fn anole_server_wait(s: ?*anyopaque, timeout_ms: i32) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    return if (e.wait(timeout_ms)) abi.OK else failCode(abi.E_TIMEOUT);
}

/// A reload that failed, as an answer: `cert_path` and `key_path` name the
/// files when the source is files, so an unreadable one is told apart.
fn reloadFailure(err: anyerror, cert_path: ?[]const u8, key_path: ?[]const u8) i32 {
    switch (err) {
        error.State => return named(abi.E_STATE, "NotRunning", 0, "anole_server_reload_tls: the server is not running", .{}),
        error.NoTlsListener => return named(abi.E_STATE, "NoTlsListener", 0, "anole_server_reload_tls: no listener serves TLS", .{}),
        error.OutOfMemory => return fail(abi.E_NOMEM, "anole_server_reload_tls", err),
        else => {},
    }
    const token = engine.errorName(err);
    if (err == error.FileNotFound or err == error.AccessDenied or err == error.PermissionDenied) {
        var which: []const u8 = token;
        if (cert_path != null and !fileReadable(cert_path.?)) {
            which = "CertificateFileUnreadable";
        } else if (key_path != null and !fileReadable(key_path.?)) which = "KeyFileUnreadable";
        return named(abi.E_SYSTEM, which, engine.errorErrno(err), "anole_server_reload_tls: {t}", .{err});
    }
    // The OS refusing is the system's; anything else did not load.
    if (err == error.SystemResources or err == error.ProcessFdQuotaExceeded or err == error.SystemFdQuotaExceeded)
        return named(abi.E_SYSTEM, token, engine.errorErrno(err), "anole_server_reload_tls: {t}", .{err});
    return named(abi.E_INVALID, token, 0, "anole_server_reload_tls: {t}", .{err});
}

fn fileReadable(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(engine.threadedIo(), path, .{}) catch return false;
    return true;
}

export fn anole_server_reload_tls(s: ?*anyopaque, flags: u32, cert: Str, key: Str) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    if (flags & ~abi.TLS_F_PEM != 0) return unknownFlag();
    const cs = cert.slice();
    const ks = key.slice();
    if (cs.len == 0 and ks.len == 0) {
        e.reloadCertificates() catch |err| return reloadFailure(err, null, null);
        return abi.OK;
    }
    if (cs.len == 0 or ks.len == 0) return named(abi.E_INVALID, "Invalid", 0, "anole_server_reload_tls: cert and key go together", .{});
    const pem = flags & abi.TLS_F_PEM != 0;
    const source: anole.Cert = if (pem)
        .{ .pem = .{ .cert = cs, .key = ks } }
    else
        .{ .files = .{ .cert_path = cs, .key_path = ks } };
    e.setCertificate(source) catch |err| return reloadFailure(err, if (pem) null else cs, if (pem) null else ks);
    return abi.OK;
}

// ---- console -----------------------------------------------------------------------

export fn anole_console_open(s: ?*anyopaque, flags: u32) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    if (flags != 0) return unknownFlag();
    e.consoleOpen() catch |err| return switch (err) {
        error.State => named(abi.E_STATE, "State", 0, "anole_console_open: the server is not running, or a console is open already", .{}),
        error.Disabled => named(abi.E_CONFIG, "ConsoleOff", 0, "anole_console_open: the console is off (the \"console\" configuration group)", .{}),
        error.NotATerminal, error.DumbTerminal, error.Unsupported => named(abi.E_UNSUPPORTED, "NoTerminal", 0, "anole_console_open: no terminal here (TERM=dumb, no /dev/tty, or Windows)", .{}),
        error.OutOfMemory => fail(abi.E_NOMEM, "anole_console_open", err),
        else => fail(abi.E_SYSTEM, "anole_console_open", err),
    };
    return abi.OK;
}

export fn anole_console_close(s: ?*anyopaque) i32 {
    // The cleanup-call rule: ANOLE_OK, no error text, on one that is over.
    const e = engineOf(s) orelse return abi.OK;
    e.consoleClose();
    return abi.OK;
}

export fn anole_console_attached(s: ?*anyopaque) i32 {
    const e = engineOf(s) orelse return 0;
    return e.consoleAttached();
}

export fn anole_console_report(s: ?*anyopaque, m: ?[*]const abi.ConsoleMetric, n: usize) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    if (n > 32) return named(abi.E_INVALID, "Invalid", 0, "anole_console_report: at most 32 metrics", .{});
    if (n > 0 and m == null) return failCode(abi.E_INVALID);
    var items: [32]anole.console.service.Metric = undefined;
    for (0..n) |i| {
        const x = m.?[i];
        const name = x.name.slice();
        if (name.len == 0 or name.len > 48) return named(abi.E_INVALID, "Invalid", 0, "anole_console_report: a name is 1 to 48 bytes of [a-z0-9_.]", .{});
        for (name) |ch| {
            if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.'))
                return named(abi.E_INVALID, "Invalid", 0, "anole_console_report: a name is 1 to 48 bytes of [a-z0-9_.]", .{});
        }
        const unit: []const u8 = switch (x.unit) {
            abi.UNIT_NONE => "",
            abi.UNIT_BYTES => "bytes",
            abi.UNIT_SECONDS => "seconds",
            abi.UNIT_COUNT => "count",
            abi.UNIT_PERCENT => "percent",
            else => return named(abi.E_INVALID, "Invalid", 0, "anole_console_report: unknown unit", .{}),
        };
        items[i] = .{ .name = name, .value = x.value, .unit = unit };
    }
    e.consoleReport(items[0..n]) catch |err| return switch (err) {
        error.State => named(abi.E_STATE, "State", 0, "anole_console_report: the server is not running", .{}),
        else => fail(abi.E_NOMEM, "anole_console_report", err),
    };
    return abi.OK;
}

export fn anole_console_log(s: ?*anyopaque, level: u32, scope: Str, msg: Str, req: u64) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    _ = req;
    const lvl: std.log.Level = switch (level) {
        abi.LOG_ERROR => .err,
        abi.LOG_WARN => .warn,
        abi.LOG_INFO => .info,
        abi.LOG_DEBUG => .debug,
        else => return failCode(abi.E_INVALID),
    };
    e.consoleLog(lvl, scope.slice(), msg.slice());
    return abi.OK;
}

export fn anole_server_destroy(s: ?*anyopaque) void {
    const e = engineOf(s) orelse return;
    e.destroy();
    // No log callback runs again.
    anole.log.setSink(null);
    if (log_target.swap(null, .acq_rel)) |t| std.heap.c_allocator.destroy(@constCast(t));
}

export fn anole_server_stats(s: ?*anyopaque, out: ?*abi.Stats) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    const size = dst.size;
    if (size < @sizeOf(usize)) return failCode(abi.E_INVALID);
    const st = e.stats();
    const n = @min(size, @sizeOf(abi.Stats));
    @memcpy(@as([*]u8, @ptrCast(dst))[@sizeOf(usize)..n], std.mem.asBytes(&st)[@sizeOf(usize)..n]);
    return abi.OK;
}

// ---- consumers ---------------------------------------------------------------------

export fn anole_consumer_attach(s: ?*anyopaque, options: ?*const abi.ConsumerOptions, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const o = readSized(abi.ConsumerOptions, options orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const dst = out orelse return failCode(abi.E_INVALID);
    if (o.flags & ~abi.CONSUMER_F_SHARED != 0) return unknownFlag();
    const shared = o.flags & abi.CONSUMER_F_SHARED != 0;
    if (o.wake == null and !shared and builtin.os.tag == .windows) {
        return named(abi.E_UNSUPPORTED, "Unsupported", 0, "Windows has no doorbell fd: pass a wake callback, or use anole_poll_wait", .{});
    }
    const c = e.attach(o.wake, o.wake_ud, shared) catch |err| return switch (@as(anyerror, err)) {
        error.State => named(abi.E_STATE, "State", 0, "anole_consumer_attach: before anole_server_open/start, 256 at most", .{}),
        error.OutOfMemory => fail(abi.E_NOMEM, "anole_consumer_attach", err),
        else => fail(abi.E_SYSTEM, "anole_consumer_attach", err),
    };
    dst.* = c;
    return abi.OK;
}

export fn anole_consumer_fd(c: ?*anyopaque) isize {
    const consumer = consumerOf(c) orelse return -1;
    return if (consumer.target.load(.acquire).f == null) consumer.fd_read else -1;
}

export fn anole_consumer_set_wake(c: ?*anyopaque, wake: ?abi.WakeFn, ud: ?*anyopaque) i32 {
    clearError();
    const consumer = consumerOf(c) orelse return badPointer(c);
    consumer.setWake(wake, ud) catch |err| return switch (@as(anyerror, err)) {
        error.Unsupported => named(abi.E_UNSUPPORTED, "Unsupported", 0, "this consumer has no doorbell fd (shared, or Windows): pass a callback", .{}),
        error.OutOfMemory => fail(abi.E_NOMEM, "anole_consumer_set_wake", err),
        else => fail(abi.E_SYSTEM, "anole_consumer_set_wake", err),
    };
    return abi.OK;
}

fn pollBuf(buf: ?*anyopaque, cap: usize) ?[]u8 {
    const p: [*]u8 = @ptrCast(buf orelse return null);
    if (@intFromPtr(p) % abi.record_align != 0) return null;
    return p[0..cap];
}

/// ANOLE_E_TOOBIG from a poll: the header says how big the next record is.
fn tooBig(out: []u8, need: u32) i64 {
    if (out.len >= @sizeOf(abi.Event)) {
        const hdr: *abi.Event = @ptrCast(@alignCast(out.ptr));
        hdr.* = .{ .type = @backingInt(abi.EventType.none), .len = need, .handle = 0 };
    }
    return failCode(abi.E_TOOBIG);
}

export fn anole_poll(c: ?*anyopaque, buf: ?*anyopaque, cap: usize, flags: u32) i64 {
    const consumer = consumerOf(c) orelse return badPointer(c);
    const out = pollBuf(buf, cap) orelse return named(abi.E_INVALID, "Invalid", 0, "the poll buffer must be non-NULL and 8-byte aligned", .{});
    if (flags & ~abi.POLL_F_NOARM != 0) return unknownFlag();
    var need: u32 = 0;
    const n = engine.poll(consumer, out, flags & abi.POLL_F_NOARM == 0, &need) catch return tooBig(out, need);
    return @intCast(n);
}

export fn anole_poll_wait(c: ?*anyopaque, buf: ?*anyopaque, cap: usize, timeout_ms: i32) i64 {
    const consumer = consumerOf(c) orelse return badPointer(c);
    const out = pollBuf(buf, cap) orelse return named(abi.E_INVALID, "Invalid", 0, "the poll buffer must be non-NULL and 8-byte aligned", .{});
    var need: u32 = 0;
    const n = engine.pollWait(consumer, out, timeout_ms, &need) catch return tooBig(out, need);
    return @intCast(n);
}

// ---- requests and responses -------------------------------------------------------

export fn anole_req_read(r: u64, buf: ?*anyopaque, cap: usize, timeout_ms: i32) i64 {
    if (badKind(r, .request)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    if (cap == 0) return failCode(abi.E_INVALID);
    const p: [*]u8 = @ptrCast(buf orelse return failCode(abi.E_INVALID));
    const n = engine.reqRead(e, r, p[0..cap], timeout_ms) catch |err| return answer(err);
    return @intCast(n);
}

export fn anole_req_respond(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize, body: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (badKind(r, .request)) return wrongKind();
    if (flags & ~abi.BODY_BORROW != 0) return unknownFlag();
    const hs = headersOf(headers, nheaders) orelse return failCode(abi.E_INVALID);
    const b = bytes(body, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.respond(e, r, status, hs, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_req_respond_fd(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize, fd: isize, offset: u64, len: u64) i32 {
    if (badKind(r, .request)) return wrongKind();
    const hs = headersOf(headers, nheaders) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    if (comptime builtin.os.tag == .windows) return failCode(abi.E_UNSUPPORTED);
    const fd_c = std.math.cast(c_int, fd) orelse return failCode(abi.E_INVALID);
    engine.engine_errno = 0;
    engine.respondFd(e, r, status, hs, fd_c, offset, len) catch |err| {
        if (err == error.Invalid and engine.engine_errno != 0) return named(abi.E_INVALID, "Invalid", engine.engine_errno, "the file descriptor cannot be read", .{});
        return answer(err);
    };
    return abi.OK;
}

export fn anole_req_stream_start(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize) i32 {
    if (badKind(r, .request)) return wrongKind();
    const hs = headersOf(headers, nheaders) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.streamStart(e, r, status, hs) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_req_stream_write(r: u64, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (badKind(r, .request)) return wrongKind();
    if (flags & ~abi.BODY_BORROW != 0) return unknownFlag();
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    const busy = engine.streamWrite(e, r, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_req_stream_write_wait(r: u64, data: ?*const anyopaque, len: usize, timeout_ms: i32) i32 {
    if (badKind(r, .request)) return wrongKind();
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.streamWriteWait(e, r, b, timeout_ms) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_req_stream_end(r: u64, trailers: ?[*]const Header, ntrailers: usize) i32 {
    if (badKind(r, .request)) return wrongKind();
    const ts = headersOf(trailers, ntrailers) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.streamEnd(e, r, ts) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_req_fail(r: u64, status: u16, message: Str) i32 {
    if (badKind(r, .request)) return wrongKind();
    const m = bytes(message.ptr, message.len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.fail(e, r, status, m) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_req_abort(r: u64) i32 {
    if (badKind(r, .request)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.abort(e, r) catch |err| return cleanup(err);
    return abi.OK;
}

export fn anole_handle_release(h: u64) i32 {
    const kind = Handle.decode(h).kind;
    const valid = h != 0 and Handle.decode(h).gen != 0 and switch (kind) {
        .request, .websocket, .grpc_call, .wt_session, .wt_stream, .db_tx, .broker_sub, .broker_msg => true,
        .net_conn, .net_udp, .job_worker, .job, .sse, .watch_sub, .transfer, .kafka_group, .kafka_batch => true,
        else => false,
    };
    if (!valid) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.handleRelease(e, h) catch |err| return cleanup(err);
    return abi.OK;
}

// ---- WebSocket -----------------------------------------------------------------------

const have_ws = anole.features.websocket;

export fn anole_ws_send(w: u64, typ: u32, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .websocket)) return wrongKind();
    if (flags & ~abi.BODY_BORROW != 0) return unknownFlag();
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    const busy = engine.ws.send(e, w, typ, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_ws_close(w: u64, code: u16, reason: Str) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .websocket)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.ws.close(e, w, code, reason.slice()) catch |err| return cleanup(err);
    return abi.OK;
}

export fn anole_ws_accept(r: u64, options: ?*const abi.WsAcceptOptions, out: ?*u64) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    if (badKind(r, .request)) return wrongKind();
    const o = out orelse return failCode(abi.E_INVALID);
    const opts: abi.WsAcceptOptions = if (options) |p| readSized(abi.WsAcceptOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.WsAcceptOptions) };
    if (opts.flags != 0) return unknownFlag();
    if (opts.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_ws_accept_options.reserved must be 0", .{});
    const hs = headersOf(opts.headers, opts.nheaders) orelse return failCode(abi.E_INVALID);
    const sub = bytes(opts.subprotocol.ptr, opts.subprotocol.len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    o.* = 0;
    o.* = engine.wsAccept(e, r, sub, hs) catch |err| return switch (err) {
        error.State => named(abi.E_STATE, "State", 0, "not a WebSocket handshake (anole_ws_accept answers ANOLE_EV_WS_UPGRADE only)", .{}),
        error.Invalid => named(abi.E_INVALID, "Invalid", 0, "a subprotocol the client did not offer, or a header the handshake writes itself (Upgrade, Connection, Sec-WebSocket-*, Content-Length, Transfer-Encoding), or an invalid one", .{}),
        else => answer(err),
    };
    return abi.OK;
}

export fn anole_ws_subscribe(w: u64, topic: Str) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .websocket)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    engine.ws.subscribe(e, w, topic.slice(), true) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_ws_unsubscribe(w: u64, topic: Str) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .websocket)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.ws.subscribe(e, w, topic.slice(), false) catch |err| return cleanup(err);
    return abi.OK;
}

export fn anole_ws_publish(s: ?*anyopaque, topic: Str, typ: u32, data: ?*const anyopaque, len: usize, except: u64) i32 {
    if (comptime !have_ws) return failCode(abi.E_UNSUPPORTED);
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    engine.ws.publish(e, topic.slice(), typ, b, except) catch |err| return switch (err) {
        error.State => named(abi.E_STATE, "NotRunning", 0, "anole_ws_publish: the server is not running", .{}),
        else => answer(err),
    };
    return abi.OK;
}

// ---- gRPC ------------------------------------------------------------------------------

const have_grpc = anole.features.grpc;

export fn anole_grpc_send_headers(c: u64, metadata: ?[*]const Header, n: usize) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    if (badKind(c, .grpc_call)) return wrongKind();
    const md = headersOf(metadata, n) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.grpc.sendHeaders(e, c, md) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_send(c: u64, msg: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    if (badKind(c, .grpc_call)) return wrongKind();
    if (flags & ~(abi.BODY_BORROW | abi.GRPC_F_FINISH) != 0) return unknownFlag();
    const b = bytes(msg, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    const busy = engine.grpc.send(e, c, b, flags & abi.BODY_BORROW != 0, flags & abi.GRPC_F_FINISH != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_grpc_send_wait(c: u64, msg: ?*const anyopaque, len: usize, timeout_ms: i32) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    if (badKind(c, .grpc_call)) return wrongKind();
    const b = bytes(msg, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.grpc.sendWait(e, c, b, timeout_ms) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_finish(c: u64, code: u32, message: Str, trailers: ?[*]const Header, n: usize) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    if (badKind(c, .grpc_call)) return wrongKind();
    const ts = headersOf(trailers, n) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.grpc.finish(e, c, code, message.slice(), ts) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_read(c: u64, n: u32) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    if (badKind(c, .grpc_call)) return wrongKind();
    if (n == 0) return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.grpc.read(e, c, n) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_health_set(s: ?*anyopaque, service: Str, status: u32) i32 {
    if (comptime !have_grpc) return failCode(abi.E_UNSUPPORTED);
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    engine.grpc.healthSet(e, service.slice(), status) catch |err| return switch (err) {
        error.State => named(abi.E_STATE, "State", 0, "anole_grpc_health_set: the configuration has no \"grpc\": {{\"health\": true}}", .{}),
        else => answer(err),
    };
    return abi.OK;
}

// ---- WebTransport ------------------------------------------------------------------

const have_wt = anole.features.http3;

export fn anole_wt_open_stream(w: u64, flags: u32, out: ?*u64) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .wt_session)) return wrongKind();
    const o = out orelse return failCode(abi.E_INVALID);
    if (flags & ~abi.WT_F_UNI != 0) return unknownFlag();
    const e = live() orelse return failCode(abi.E_GONE);
    o.* = engine.wt.openStream(e, w, flags & abi.WT_F_UNI != 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_stream_write(st: u64, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(st, .wt_stream)) return wrongKind();
    if (flags & ~(abi.BODY_BORROW | abi.WT_F_FIN) != 0) return unknownFlag();
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    const busy = engine.wt.write(e, st, b, flags & abi.WT_F_FIN != 0, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_wt_stream_set_priority(st: u64, urgency: u32) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(st, .wt_stream)) return wrongKind();
    if (urgency > 7) return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.wt.setPriority(e, st, @intCast(urgency)) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_stream_reset(st: u64, code: u32) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(st, .wt_stream)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.wt.streamOp(e, st, .reset, code) catch |err| return cleanup(err);
    return abi.OK;
}

export fn anole_wt_stream_stop(st: u64, code: u32) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(st, .wt_stream)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.wt.streamOp(e, st, .stop, code) catch |err| return cleanup(err);
    return abi.OK;
}

export fn anole_wt_send_datagram(w: u64, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .wt_session)) return wrongKind();
    if (flags & ~abi.BODY_BORROW != 0) return unknownFlag();
    const b = bytes(data, len) orelse return failCode(abi.E_INVALID);
    const e = live() orelse return failCode(abi.E_GONE);
    engine.wt.sendDatagram(e, w, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_max_datagram(w: u64) i64 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .wt_session)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    const n = engine.wt.maxDatagram(e, w) catch |err| return answer(err);
    return @intCast(n);
}

export fn anole_wt_close(w: u64, code: u32, reason: Str) i32 {
    if (comptime !have_wt) return failCode(abi.E_UNSUPPORTED);
    if (badKind(w, .wt_session)) return wrongKind();
    const e = live() orelse return abi.OK;
    engine.wt.close(e, w, code, reason.slice()) catch |err| return cleanup(err);
    return abi.OK;
}

// ---- NATS ---------------------------------------------------------------------------

const nats_mod = engine.nats;

fn natsOf(n: ?*const anyopaque) ?*nats_mod.Broker {
    const b: *nats_mod.Broker = @ptrCast(@alignCast(@constCast(n orelse return null)));
    return if (engine.global == b.engine) b else null;
}

fn natsFailure(err: nats_mod.CallError) i32 {
    return switch (err) {
        error.Invalid => named(abi.E_INVALID, "Invalid", 0, "invalid argument (a subject, header, size, flag, or a consumer of another server or other than the request's)", .{}),
        error.State => named(abi.E_STATE, "State", 0, "the server is not open, the broker is not connected, or no executor feeds this consumer", .{}),
        error.Again => failCode(abi.E_AGAIN),
        error.OutOfMemory => failCode(abi.E_NOMEM),
        error.Unsupported => failCode(abi.E_UNSUPPORTED),
        error.Gone => blk: {
            if (live()) |e| _ = e.gone_count.fetchAdd(1, .monotonic);
            break :blk named(abi.E_GONE, "Gone", 0, "the request, message or subscription it served is over", .{});
        },
    };
}

export fn anole_nats_find(s: ?*anyopaque, name: Str, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    const b = nats_mod.find(e, name.slice()) orelse {
        return named(abi.E_INVALID, "Invalid", 0, "no NATS broker \"{s}\" in the configuration", .{name.slice()});
    };
    dst.* = b;
    return abi.OK;
}

export fn anole_nats_index(n: ?*const anyopaque) u32 {
    const b = natsOf(n) orelse return 0;
    return b.index;
}

export fn anole_nats_publish(n: ?*anyopaque, c_: ?*anyopaque, m: ?*const abi.NatsOut, flags: u32) i32 {
    clearError();
    const b = natsOf(n) orelse return badPointer(n);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const out: abi.NatsOut = readSized(abi.NatsOut, m orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const busy = nats_mod.publish(b, c, out, flags) catch |err| return natsFailure(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_nats_request(n: ?*anyopaque, c_: ?*anyopaque, m: ?*const abi.NatsOut, opts: ?*const abi.NatsRequestOptions, user_data: u64) i32 {
    clearError();
    const b = natsOf(n) orelse return badPointer(n);
    const c: ?*Consumer = if (c_ == null) null else (consumerOf(c_) orelse return badPointer(c_));
    const out: abi.NatsOut = readSized(abi.NatsOut, m orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const o: abi.NatsRequestOptions = if (opts) |p| readSized(abi.NatsRequestOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.NatsRequestOptions) };
    nats_mod.request(b, c, out, o, user_data) catch |err| return natsFailure(err);
    return abi.OK;
}

export fn anole_nats_subscribe(n: ?*anyopaque, c_: ?*anyopaque, subject: Str, opts: ?*const abi.NatsSubscribeOptions, user_data: u64, out: ?*u64) i32 {
    clearError();
    const b = natsOf(n) orelse return badPointer(n);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const dst = out orelse return failCode(abi.E_INVALID);
    const o: abi.NatsSubscribeOptions = if (opts) |p| readSized(abi.NatsSubscribeOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.NatsSubscribeOptions) };
    dst.* = nats_mod.subscribe(b, c, subject.slice(), o, user_data) catch |err| return natsFailure(err);
    return abi.OK;
}

export fn anole_nats_unsubscribe(sub: u64) i32 {
    if (badKind(sub, .broker_sub)) return wrongKind();
    const e = live() orelse return abi.OK;
    nats_mod.unsubscribe(e, sub);
    return abi.OK;
}

export fn anole_nats_js_publish(n: ?*anyopaque, c_: ?*anyopaque, m: ?*const abi.NatsOut, opts: ?*const abi.NatsJsPublishOptions, user_data: u64) i32 {
    clearError();
    const b = natsOf(n) orelse return badPointer(n);
    const c: ?*Consumer = if (c_ == null) null else (consumerOf(c_) orelse return badPointer(c_));
    const out: abi.NatsOut = readSized(abi.NatsOut, m orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const o: abi.NatsJsPublishOptions = if (opts) |p| readSized(abi.NatsJsPublishOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.NatsJsPublishOptions) };
    nats_mod.jsPublish(b, c, out, o, user_data) catch |err| return natsFailure(err);
    return abi.OK;
}

export fn anole_nats_js_consume(n: ?*anyopaque, c_: ?*anyopaque, stream: Str, consumer: Str, opts: ?*const abi.NatsJsConsumeOptions, user_data: u64, out: ?*u64) i32 {
    clearError();
    const b = natsOf(n) orelse return badPointer(n);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const dst = out orelse return failCode(abi.E_INVALID);
    const o: abi.NatsJsConsumeOptions = if (opts) |p| readSized(abi.NatsJsConsumeOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.NatsJsConsumeOptions) };
    dst.* = nats_mod.consume(b, c, stream.slice(), consumer.slice(), o, user_data) catch |err| return natsFailure(err);
    return abi.OK;
}

export fn anole_nats_ack(m: u64, kind: u32, delay_ms: u32) i32 {
    clearError();
    if (badKind(m, .broker_msg)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    nats_mod.ack(e, m, kind, delay_ms) catch |err| return natsFailure(err);
    return abi.OK;
}

// ---- Kafka --------------------------------------------------------------------------

const kafka_mod = engine.kafka;

fn kafkaOf(k: ?*const anyopaque) ?*kafka_mod.Broker {
    const b: *kafka_mod.Broker = @ptrCast(@alignCast(@constCast(k orelse return null)));
    return if (engine.global == b.engine) b else null;
}

fn kafkaFailure(err: kafka_mod.CallError) i32 {
    return switch (err) {
        error.Invalid => named(abi.E_INVALID, "Invalid", 0, "invalid argument (a topic, partition, flag, size, group or topic list, or a consumer of another server)", .{}),
        error.State => named(abi.E_STATE, "State", 0, "the server is not open, the broker is not connected, or no executor feeds this consumer", .{}),
        error.Again => failCode(abi.E_AGAIN),
        error.OutOfMemory => failCode(abi.E_NOMEM),
        error.Unsupported => failCode(abi.E_UNSUPPORTED),
        error.Gone => blk: {
            if (live()) |e| _ = e.gone_count.fetchAdd(1, .monotonic);
            break :blk named(abi.E_GONE, "Gone", 0, "the batch it served is over", .{});
        },
    };
}

export fn anole_kafka_find(s: ?*anyopaque, name: Str, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    const b = kafka_mod.find(e, name.slice()) orelse {
        return named(abi.E_INVALID, "Invalid", 0, "no Kafka broker \"{s}\" in the configuration", .{name.slice()});
    };
    dst.* = b;
    return abi.OK;
}

export fn anole_kafka_index(k: ?*const anyopaque) u32 {
    const b = kafkaOf(k) orelse return 0;
    return b.index;
}

export fn anole_kafka_produce(k: ?*anyopaque, c_: ?*anyopaque, m: ?*const abi.KafkaOut, user_data: u64) i32 {
    clearError();
    const b = kafkaOf(k) orelse return badPointer(k);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const out: abi.KafkaOut = readSized(abi.KafkaOut, m orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    const busy = kafka_mod.produce(b, c, out, user_data) catch |err| return kafkaFailure(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_kafka_subscribe(k: ?*anyopaque, c_: ?*anyopaque, opts: ?*const abi.KafkaSubscribeOptions, user_data: u64, out: ?*u64) i32 {
    clearError();
    const b = kafkaOf(k) orelse return badPointer(k);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const dst = out orelse return failCode(abi.E_INVALID);
    const o: abi.KafkaSubscribeOptions = readSized(abi.KafkaSubscribeOptions, opts orelse return failCode(abi.E_INVALID)) catch |err| return sizedFailure(err);
    dst.* = kafka_mod.subscribe(b, c, o, user_data) catch |err| return kafkaFailure(err);
    return abi.OK;
}

export fn anole_kafka_batch_done(b: u64) i32 {
    if (badKind(b, .kafka_batch)) return wrongKind();
    const e = live() orelse return abi.OK;
    kafka_mod.batchDone(e, b);
    return abi.OK;
}

export fn anole_kafka_batch_retry(b: u64, delay_ms: u32) i32 {
    clearError();
    if (badKind(b, .kafka_batch)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    kafka_mod.batchRetry(e, b, delay_ms) catch |err| return kafkaFailure(err);
    return abi.OK;
}

export fn anole_kafka_group_close(g: u64) i32 {
    if (badKind(g, .kafka_group)) return wrongKind();
    const e = live() orelse return abi.OK;
    kafka_mod.groupClose(e, g);
    return abi.OK;
}

export fn anole_kafka_flush(k: ?*anyopaque, c_: ?*anyopaque, user_data: u64) i32 {
    clearError();
    const b = kafkaOf(k) orelse return badPointer(k);
    const c = consumerOf(c_) orelse return badPointer(c_);
    kafka_mod.flush(b, c, user_data) catch |err| return kafkaFailure(err);
    return abi.OK;
}

// ---- databases ---------------------------------------------------------------------

const db_mod = engine.db;

fn dbOf(d: ?*anyopaque) ?*db_mod.Db {
    const db_: *db_mod.Db = @ptrCast(@alignCast(d orelse return null));
    return if (engine.global == db_.engine) db_ else null;
}

export fn anole_db_find(s: ?*anyopaque, name: Str, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    const d = db_mod.find(e, name.slice()) orelse {
        return named(abi.E_INVALID, "Invalid", 0, "no database \"{s}\" in the configuration", .{name.slice()});
    };
    dst.* = d;
    return abi.OK;
}

fn dbSubmit(verb: db_mod.Verb, d_: ?*anyopaque, c_: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    clearError();
    const d = dbOf(d_) orelse return badPointer(d_);
    // NULL only with `opts->req`: the answer goes to that request's consumer.
    const c: ?*Consumer = if (c_ == null) null else (consumerOf(c_) orelse return badPointer(c_));
    const ps: []const abi.DbValue = if (nparams == 0) &.{} else (params orelse return failCode(abi.E_INVALID))[0..nparams];
    for (ps) |p| if (p.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_db_value.reserved must be 0", .{});
    const o: abi.DbOptions = if (opts) |p| readSized(abi.DbOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.DbOptions) };
    if (o.flags & ~(abi.DB_F_WRITE | abi.DB_F_COALESCE | abi.DB_F_NO_PREPARE | abi.DB_F_DROP_EMPTY | abi.DB_F_RETRY) != 0) return unknownFlag();
    if (o.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_db_options.reserved must be 0", .{});
    db_mod.submit(d, c, verb, sql.slice(), ps, o, user_data) catch |err| return dbFailure(err);
    return abi.OK;
}

/// A query or transaction call's refusal as its answer.
fn dbFailure(err: db_mod.QueryError) i32 {
    return switch (err) {
        error.Invalid => named(abi.E_INVALID, "Invalid", 0, "invalid argument (a value type, an option this call does not take, a consumer of another server or other than the request's, or a request handle of another kind)", .{}),
        error.State => named(abi.E_STATE, "State", 0, "the server is not open, or no executor feeds this consumer", .{}),
        error.OutOfMemory => failCode(abi.E_NOMEM),
        error.Unsupported => named(abi.E_UNSUPPORTED, "Unsupported", 0, "this database or build has no transactions (SQLite and PostgreSQL only)", .{}),
        error.Gone => blk: {
            if (live()) |e| _ = e.gone_count.fetchAdd(1, .monotonic);
            break :blk named(abi.E_GONE, "Gone", 0, "the request or transaction it served is over", .{});
        },
    };
}

export fn anole_db_query(d: ?*anyopaque, c: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbSubmit(.query, d, c, sql, params, nparams, opts, user_data);
}

export fn anole_db_exec(d: ?*anyopaque, c: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbSubmit(.exec, d, c, sql, params, nparams, opts, user_data);
}

export fn anole_db_invalidate(d_: ?*anyopaque, tag: Str) i32 {
    clearError();
    const d = dbOf(d_) orelse return badPointer(d_);
    db_mod.invalidate(d, tag.slice()) catch return named(abi.E_STATE, "State", 0, "the database is not open", .{});
    return abi.OK;
}

// ---- database transactions ---------------------------------------------------------

export fn anole_db_begin(d_: ?*anyopaque, c_: ?*anyopaque, opts: ?*const abi.DbTxOptions, user_data: u64) i32 {
    clearError();
    const d = dbOf(d_) orelse return badPointer(d_);
    const c: ?*Consumer = if (c_ == null) null else (consumerOf(c_) orelse return badPointer(c_));
    const o: abi.DbTxOptions = if (opts) |p| readSized(abi.DbTxOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.DbTxOptions) };
    if (o.flags & ~abi.DB_TX_READ_ONLY != 0) return unknownFlag();
    if (o.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_db_tx_options.reserved must be 0", .{});
    if (o.isolation > abi.DB_ISOLATION_SERIALIZABLE) return named(abi.E_INVALID, "Invalid", 0, "anole_db_tx_options.isolation is not an ANOLE_DB_ISOLATION_* value", .{});
    db_mod.begin(d, c, o, user_data) catch |err| return dbFailure(err);
    return abi.OK;
}

fn dbTxCall(what: db_mod.TxWhat, tx: u64, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    clearError();
    if (badKind(tx, .db_tx)) return wrongKind();
    const ps: []const abi.DbValue = if (nparams == 0) &.{} else (params orelse return failCode(abi.E_INVALID))[0..nparams];
    for (ps) |p| if (p.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_db_value.reserved must be 0", .{});
    const o: abi.DbOptions = if (opts) |p| readSized(abi.DbOptions, p) catch |err| return sizedFailure(err) else .{ .size = @sizeOf(abi.DbOptions) };
    if (o.flags & ~abi.DB_F_NO_PREPARE != 0) return named(abi.E_INVALID, "UnknownFlag", 0, "inside a transaction only ANOLE_DB_F_NO_PREPARE applies", .{});
    if (o.reserved != 0) return named(abi.E_INVALID, "ReservedNotZero", 0, "anole_db_options.reserved must be 0", .{});
    const e = live() orelse return failCode(abi.E_GONE);
    db_mod.txSubmit(e, tx, what, sql.slice(), ps, o, user_data) catch |err| return dbFailure(err);
    return abi.OK;
}

export fn anole_db_tx_query(tx: u64, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbTxCall(.query, tx, sql, params, nparams, opts, user_data);
}

export fn anole_db_tx_exec(tx: u64, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbTxCall(.exec, tx, sql, params, nparams, opts, user_data);
}

fn dbTxFinish(what: db_mod.TxWhat, tx: u64, user_data: u64) i32 {
    clearError();
    if (badKind(tx, .db_tx)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    db_mod.txFinish(e, tx, what, user_data) catch |err| return dbFailure(err);
    return abi.OK;
}

export fn anole_db_tx_commit(tx: u64, user_data: u64) i32 {
    return dbTxFinish(.commit, tx, user_data);
}

export fn anole_db_tx_rollback(tx: u64, user_data: u64) i32 {
    return dbTxFinish(.rollback, tx, user_data);
}

export fn anole_db_tx_release(tx: u64) i32 {
    if (badKind(tx, .db_tx)) return wrongKind();
    const e = live() orelse return abi.OK;
    db_mod.txRelease(e, tx);
    return abi.OK;
}

// ---- p3/net ----
// ---- end p3/net ----

// ---- p3/jobs ----
const jobs_mod = engine.jobs;

fn jobsFailure(err: jobs_mod.CallError) i32 {
    return switch (err) {
        error.Invalid => named(abi.E_INVALID, "Invalid", 0, "invalid argument (a job's kind, JSON, size or flag, a queue or kind the configuration or another worker does not allow, a transaction on another database than the jobs store)", .{}),
        error.State => named(abi.E_STATE, "State", 0, "the server is not open (workers: before the start only), or no executor feeds this consumer", .{}),
        error.OutOfMemory => failCode(abi.E_NOMEM),
        error.Unsupported => named(abi.E_UNSUPPORTED, "Unsupported", 0, "the configuration has no \"jobs\", or jobs are not built in (-Djobs)", .{}),
        error.Gone => blk: {
            if (live()) |e| _ = e.gone_count.fetchAdd(1, .monotonic);
            break :blk named(abi.E_GONE, "Gone", 0, "the job, request or transaction it served is over", .{});
        },
    };
}

/// The configuration's job queue (`anole_jobs *`): the engine's own state,
/// valid until `anole_server_destroy`. `ANOLE_E_UNSUPPORTED` when the
/// configuration has no "jobs".
export fn anole_jobs_get(s: ?*anyopaque, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return badPointer(s);
    const dst = out orelse return failCode(abi.E_INVALID);
    if (e.config.jobs == null) return named(abi.E_UNSUPPORTED, "Unsupported", 0, "the configuration has no \"jobs\"", .{});
    dst.* = @ptrCast(&e.jobs_state);
    return abi.OK;
}

fn jobsOf(j: ?*anyopaque) ?*Engine {
    const st: *jobs_mod.State = @ptrCast(@alignCast(j orelse return null));
    const e = live() orelse return null;
    return if (st == &e.jobs_state) e else null;
}

export fn anole_jobs_enqueue(j: ?*anyopaque, c_: ?*anyopaque, jobs: ?[*]const abi.JobOut, njobs: usize, opts: ?*const abi.JobsEnqueueOptions, user_data: u64) i32 {
    clearError();
    const e = jobsOf(j) orelse return badPointer(j);
    const o: abi.JobsEnqueueOptions = if (opts) |p| (readSized(abi.JobsEnqueueOptions, p) catch |err| return sizedFailure(err)) else .{ .size = @sizeOf(abi.JobsEnqueueOptions) };
    const c: ?*Consumer = if (c_ == null) null else (consumerOf(c_) orelse return badPointer(c_));
    if (c == null and o.tx == 0 and o.req == 0) return failCode(abi.E_INVALID);
    const list = (jobs orelse return failCode(abi.E_INVALID))[0..njobs];
    jobs_mod.enqueue(e, c, list, o, user_data) catch |err| return jobsFailure(err);
    return abi.OK;
}

export fn anole_jobs_work(j: ?*anyopaque, c_: ?*anyopaque, o: ?*const abi.JobsWorkOptions, user_data: u64, out: ?*u64) i32 {
    clearError();
    const e = jobsOf(j) orelse return badPointer(j);
    const c = consumerOf(c_) orelse return badPointer(c_);
    const dst = out orelse return failCode(abi.E_INVALID);
    const opt: abi.JobsWorkOptions = if (o) |p| (readSized(abi.JobsWorkOptions, p) catch |err| return sizedFailure(err)) else .{ .size = @sizeOf(abi.JobsWorkOptions) };
    dst.* = jobs_mod.work(e, c, opt, user_data) catch |err| return jobsFailure(err);
    return abi.OK;
}

export fn anole_jobs_stop(w: u64) i32 {
    if (badKind(w, .job_worker)) return wrongKind();
    const e = live() orelse return abi.OK;
    jobs_mod.stop(e, w);
    return abi.OK;
}

export fn anole_job_finish(job: u64, outcome: u32, delay_ms: u32, err_text: Str) i32 {
    clearError();
    if (badKind(job, .job)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    jobs_mod.finish(e, job, outcome, delay_ms, err_text.slice()) catch |err| return jobsFailure(err);
    return abi.OK;
}

export fn anole_job_complete_in(job: u64, tx: u64, user_data: u64) i32 {
    clearError();
    if (badKind(job, .job) or badKind(tx, .db_tx)) return wrongKind();
    const e = live() orelse return failCode(abi.E_GONE);
    jobs_mod.completeIn(e, job, tx, user_data) catch |err| return jobsFailure(err);
    return abi.OK;
}

export fn anole_jobs_admin(j: ?*anyopaque, c_: ?*anyopaque, request: Str, user_data: u64) i32 {
    clearError();
    const e = jobsOf(j) orelse return badPointer(j);
    const c = consumerOf(c_) orelse return badPointer(c_);
    jobs_mod.admin(e, c, request.slice(), user_data) catch |err| return jobsFailure(err);
    return abi.OK;
}
// ---- end p3/jobs ----

// ---- p3/webhooks ----
// ---- end p3/webhooks ----

// ---- p3/realtime ----
// ---- end p3/realtime ----

// ---- p3/s3 ----
// ---- end p3/s3 ----

// ---- p3/smtp ----
// ---- end p3/smtp ----

// ---- p3/lambda ----
// ---- end p3/lambda ----
