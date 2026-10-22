//! gRPC services of the C ABI whose methods a consumer implements (Node,
//! Python): Anole serves the protocols (gRPC over HTTP/2, gRPC-Web, Connect,
//! JSON transcoding), framing, compression, deadlines, limits and
//! grpc.health.v1; the consumer gets each call as `ANOLE_EV_GRPC_CALL`,
//! its request messages as protobuf bytes, and answers with
//! `anole_grpc_send` / `anole_grpc_finish` by an `anole_grpc_call` handle.
//!
//! A call takes one of the executor's request slots (handle kind
//! `grpc_call`), so the engine's machinery carries it: the ring hand-off,
//! the done list, detached responses (a unary or server-streaming call
//! that arrived whole over HTTP/2 or HTTP/3 runs with no task), the pipe
//! for streamed answers (one chunk per response message), `ANOLE_BUSY` and
//! `ANOLE_EV_WRITABLE`, `ANOLE_EV_ABORT`. What is gRPC's own lives here:
//!
//! - the routes (`/pkg.Service/Method`, Connect GET, the `google.api.http`
//!   bindings), from the configuration and the descriptors (grpc_schema.zig);
//! - each call's deadline: a task's call is canceled at its deadline, as a
//!   native handler's is; a detached call sits in its executor's deadline
//!   heap, swept by the capi task;
//! - the request messages of client- and bidirectional-streaming calls,
//!   posted by a reader task as `ANOLE_EV_GRPC_MESSAGE` while the consumer
//!   has credit (`read_ahead`, then `anole_grpc_read`), then
//!   `ANOLE_EV_GRPC_HALF_CLOSE`;
//! - the answer: initial metadata, the message(s), the status and trailing
//!   metadata, written through `anole.grpc`'s own call machinery
//!   (`serving.begin`/`writePayload`/`finish`), so every protocol answers
//!   exactly as a native service does.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const config_mod = @import("config.zig");
pub const schema = @import("grpc_schema.zig");
const features = anole.features;
const serving = anole.grpc.serving;
const transcode = anole.grpc.transcode;
const md_keys = anole.grpc.metadata_keys;
const frame = @import("../grpc/frame.zig");
const Code = anole.grpc.Code;
const http = anole.http;
const zio = anole.zio;
const placement = dusty.placement;
const Detached = dusty.Detached;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Slot = engine.Slot;
const Handle = engine.Handle;
const Command = engine.Command;
const CHeader = engine.CHeader;
const AnswerError = engine.AnswerError;
const Chunk = engine.pipe.Chunk;
const Call = serving.Call;
const gpa = engine.gpa;
const pack = engine.pack;
const genOf = engine.genOf;
const stateOf = engine.stateOf;
const no_slot = engine.no_slot;
const log = std.log.scoped(.anole_capi);

// ---------------------------------------------------------------------------
// Services and methods

pub const Service = struct {
    name: []const u8,
    cfg: *const config_mod.Config.GrpcService,
    methods: []Method,
};

pub const Method = struct {
    engine: *Engine,
    service: *const Service,
    /// Its index in the service's method list (`anole_grpc_call_event.method_id`).
    id: u16,
    name: []const u8,
    /// "/package.Service/Method".
    path: []const u8,
    kind: serving.MethodKind,
    /// The message types (upb), with descriptors.
    input: ?*const anyopaque = null,
    output: ?*const anyopaque = null,
    /// Calls may detach (unary and server streaming, `no_wait`, middleware
    /// that never waits).
    detachable: bool = false,
    /// The limits; `data` is this method.
    options: serving.RegisterOptions = .{},

    /// JSON is served (Connect JSON, gRPC-Web JSON, transcoding): Anole
    /// converts with the descriptors.
    fn json(m: *const Method) bool {
        return m.input != null and m.output != null;
    }
};

/// One `google.api.http` binding of a method.
const Binding = struct {
    method: *const Method,
    rule: transcode.Rule,
    template: transcode.Template,
    options: serving.RegisterOptions,
};

pub const EngineState = struct {
    schema: ?schema.Schema = null,
    services: []Service = &.{},
    /// Statuses set before the health service exists (before start).
    health_lock: std.atomic.Mutex = .unlocked,
    health_live: bool = false,
    pending: std.ArrayList(Pending) = .empty,

    const Pending = struct { name: []u8, status: c_int };
};

// ---------------------------------------------------------------------------
// Per slot and per executor

pub const SlotState = struct {
    // Set by the executor before the hand-off; read by `poll`.
    method: *const Method = undefined,
    call: *Call = undefined,
    /// The request message (unary and server streaming), protobuf bytes.
    message: []const u8 = "",
    /// Request metadata, `-bin` values decoded.
    metadata: []const [2][]const u8 = &.{},
    flags: u16 = 0,
    /// The call's deadline (awake clock, ns), or null.
    deadline: ?i96 = null,
    /// A transcoded call's `response_body`.
    response_body: []const u8 = "",

    // Written by the consumer (while `responding`, or under `out`'s lock
    // once streaming); read by the executor once `done`/`streaming`.
    headers_set: bool = false,
    has_message: bool = false,
    code: u8 = 0,
    /// The status message, in `trailer_bytes` after the trailers.
    status_off: u32 = 0,
    status_len: u32 = 0,
    /// MESSAGE events the consumer will take (`read_ahead`, `anole_grpc_read`).
    credit: std.atomic.Value(u32) = .init(0),
    reader_waiting: std.atomic.Value(bool) = .init(false),

    // Executor-local.
    heap_pos: u32 = no_slot,
    timed_out: bool = false,
    read_error: ?anyerror = null,
};

pub const ExecState = struct {
    /// Detached calls with a deadline, a binary min-heap of slot indexes.
    heap: []u32 = &.{},
    len: u32 = 0,

    pub fn deinit(st: *ExecState) void {
        gpa.free(st.heap);
        st.* = .{};
    }
};

fn deadlineOf(x: *Exec, i: u32) i96 {
    return x.slots[i].grpc.deadline.?;
}

fn heapSwap(x: *Exec, a: u32, b: u32) void {
    const h = x.grpc.heap;
    std.mem.swap(u32, &h[a], &h[b]);
    x.slots[h[a]].grpc.heap_pos = a;
    x.slots[h[b]].grpc.heap_pos = b;
}

fn heapUp(x: *Exec, pos: u32) void {
    var i = pos;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (deadlineOf(x, x.grpc.heap[parent]) <= deadlineOf(x, x.grpc.heap[i])) break;
        heapSwap(x, i, parent);
        i = parent;
    }
}

fn heapDown(x: *Exec, pos: u32) void {
    var i = pos;
    const n = x.grpc.len;
    while (true) {
        var m = i;
        const l = 2 * i + 1;
        const r = l + 1;
        if (l < n and deadlineOf(x, x.grpc.heap[l]) < deadlineOf(x, x.grpc.heap[m])) m = l;
        if (r < n and deadlineOf(x, x.grpc.heap[r]) < deadlineOf(x, x.grpc.heap[m])) m = r;
        if (m == i) return;
        heapSwap(x, i, m);
        i = m;
    }
}

/// Watches slot `i`'s deadline (a detached call's). Wakes the capi task
/// when it is the earliest now.
fn heapPush(x: *Exec, i: u32) void {
    const st = &x.grpc;
    const pos = st.len;
    st.heap[pos] = i;
    x.slots[i].grpc.heap_pos = pos;
    st.len += 1;
    heapUp(x, pos);
    if (x.slots[i].grpc.heap_pos == 0) x.kick.set(x.engine.io);
}

fn heapRemove(x: *Exec, i: u32) void {
    const pos = x.slots[i].grpc.heap_pos;
    if (pos == no_slot) return;
    const st = &x.grpc;
    st.len -= 1;
    if (pos != st.len) {
        heapSwap(x, pos, st.len);
        heapDown(x, pos);
        heapUp(x, pos);
    }
    x.slots[i].grpc.heap_pos = no_slot;
}

/// From `Exec.release`: the call's slot is free again.
pub fn onRelease(x: *Exec, i: u32) void {
    heapRemove(x, i);
    const g = &x.slots[i].grpc;
    g.message = "";
    g.metadata = &.{};
    g.read_error = null;
    g.timed_out = false;
    g.deadline = null;
}

// ---------------------------------------------------------------------------
// Configuration (Engine.create)

pub fn init(e: *Engine, why: *std.Io.Writer) config_mod.Problem!void {
    const cfg = &(e.config.grpc orelse return);
    const a = e.arena.allocator();
    const set: ?[]const u8 = if (cfg.descriptor_set) |b64| blk: {
        const decoder = std.base64.standard.Decoder;
        const trimmed = std.mem.trim(u8, b64, " \t\r\n");
        const len = decoder.calcSizeForSlice(trimmed) catch return fail(why, "grpc.descriptor_set: not base64", .{});
        const out = a.alloc(u8, len) catch return fail(why, "grpc.descriptor_set: out of memory", .{});
        decoder.decode(out, trimmed) catch return fail(why, "grpc.descriptor_set: not base64", .{});
        break :blk out;
    } else if (cfg.descriptor_set_file) |path|
        std.Io.Dir.cwd().readFileAlloc(engine.threadedIo(), path, a, .limited(64 << 20)) catch |err|
            return fail(why, "grpc.descriptor_set_file: {s}: {t}", .{ path, err })
    else
        null;
    if (set) |bytes| {
        e.grpc.schema = schema.parse(a, bytes, why) catch |err| switch (err) {
            error.Invalid => return error.Config,
            error.OutOfMemory => return fail(why, "grpc.descriptor_set: out of memory", .{}),
        };
    }
    errdefer deinit(e);
    const services = a.alloc(Service, cfg.services.len) catch return fail(why, "grpc: out of memory", .{});
    for (cfg.services, services, 0..) |*sc, *svc, i| {
        svc.* = .{ .name = sc.name, .cfg = sc, .methods = &.{} };
        const desc: ?*const schema.Service = if (e.grpc.schema) |*sch| sch.service(sc.name) orelse
            return fail(why, "grpc.services[{d}]: {s} is not in the descriptors", .{ i, sc.name })
        else
            null;
        const n = if (sc.methods) |ms| ms.len else desc.?.methods.len;
        const methods = a.alloc(Method, n) catch return fail(why, "grpc: out of memory", .{});
        for (methods, 0..) |*m, j| {
            var dm: ?*const schema.Method = null;
            var name: []const u8 = undefined;
            var kind: ?serving.MethodKind = null;
            if (sc.methods) |ms| {
                name = ms[j].name;
                if (ms[j].kind) |k| kind = @enumFromInt(@intFromEnum(k));
                if (desc) |d| {
                    for (d.methods) |*cand| if (std.mem.eql(u8, cand.name, name)) {
                        dm = cand;
                    };
                    if (dm == null) return fail(why, "grpc.services[{d}]: {s} has no method {s}", .{ i, sc.name, name });
                }
            } else {
                dm = &desc.?.methods[j];
                name = dm.?.name;
            }
            if (dm) |d| {
                if (kind) |k| if (k != d.kind) return fail(why, "grpc.services[{d}].methods[{d}]: kind {t}, the descriptors say {t}", .{ i, j, k, d.kind });
                kind = d.kind;
            }
            m.* = .{
                .engine = e,
                .service = svc,
                .id = @intCast(j),
                .name = name,
                .path = std.fmt.allocPrint(a, "/{s}/{s}", .{ sc.name, name }) catch return fail(why, "grpc: out of memory", .{}),
                .kind = kind.?,
            };
            if (dm) |d| {
                const sch = &e.grpc.schema.?;
                m.input = sch.message(d.input) orelse return fail(why, "grpc: {s}: no message type {s} in the descriptors", .{ m.path, d.input });
                m.output = sch.message(d.output) orelse return fail(why, "grpc: {s}: no message type {s} in the descriptors", .{ m.path, d.output });
            }
            m.options = .{
                .max_message_size = sc.max_message_size,
                .max_received_bytes = std.math.cast(usize, sc.max_received_bytes) orelse std.math.maxInt(usize),
                .read_timeout = if (sc.read_timeout_ms == 0) null else .fromMilliseconds(sc.read_timeout_ms),
                .max_call_duration = if (sc.max_call_duration_ms == 0) null else .fromMilliseconds(sc.max_call_duration_ms),
                .response_compression = switch (sc.response_compression) {
                    .mirror => .mirror,
                    .accepted => .accepted,
                    .never => .never,
                },
                .transcode = sc.transcode,
                .data = m,
            };
        }
        svc.methods = methods;
    }
    e.grpc.services = services;
}

fn fail(why: *std.Io.Writer, comptime fmt: []const u8, args: anytype) config_mod.Problem {
    why.print("config: " ++ fmt, args) catch {};
    return error.Config;
}

pub fn deinit(e: *Engine) void {
    if (e.grpc.schema) |*s| s.deinit();
    e.grpc.schema = null;
    for (e.grpc.pending.items) |p| gpa.free(p.name);
    e.grpc.pending.deinit(gpa);
    e.grpc.pending = .empty;
}

/// Whether a method is served as Connect GET too.
fn noSideEffects(m: *const Method) bool {
    if (m.kind != .unary) return false;
    if (m.service.cfg.methods) |ms| if (ms[m.id].no_side_effects) |v| return v;
    const sch = m.engine.grpc.schema orelse return false;
    const svc = sch.service(m.service.name) orelse return false;
    for (svc.methods) |d| if (std.mem.eql(u8, d.name, m.name)) return d.no_side_effects;
    return false;
}

// ---------------------------------------------------------------------------
// Routes (on the anole main thread, before serving)

pub fn buildRoutes(e: *Engine, app: *anole.App, global_ok: bool) !void {
    const cfg = e.config.grpc orelse return;
    const a = e.arena.allocator();
    for (e.execs) |*x| {
        x.grpc.heap = try gpa.alloc(u32, x.slots.len);
        x.grpc.len = 0;
    }
    var bindings: std.ArrayList(*Binding) = .empty;
    for (e.grpc.services) |*svc| for (svc.methods) |*m| {
        const whole = m.kind == .unary or m.kind == .server_streaming;
        m.detachable = whole and svc.cfg.no_wait and global_ok;
        const route_options: dusty.RouteOptions = .{ .data = m, .no_wait = m.detachable };
        app.router.addRouteWith(.post, m.path, handler, route_options);
        if (noSideEffects(m)) app.router.addRouteWith(.get, m.path, handler, route_options);
        // google.api.http, with descriptors.
        if (!svc.cfg.transcode or m.input == null) continue;
        const sch = e.grpc.schema.?;
        const desc = sch.service(svc.name).?;
        const dm = for (desc.methods) |*d| {
            if (std.mem.eql(u8, d.name, m.name)) break d;
        } else unreachable;
        for (dm.rules) |rule| {
            const b = try a.create(Binding);
            const where = try std.fmt.allocPrint(a, "{s}.{s} ({s})", .{ svc.name, m.name, rule.pattern });
            b.* = .{
                .method = m,
                .rule = rule,
                .template = transcode.Template.parse(rule.pattern) catch {
                    log.err("google.api.http on {s}: invalid path template", .{where});
                    return error.InvalidTemplate;
                },
                .options = m.options,
            };
            b.options.data = b;
            var why_buf: [256]u8 = undefined;
            var why: std.Io.Writer = .fixed(&why_buf);
            schema.checkRule(m.input.?, m.output.?, rule, &b.template, where, &why) catch {
                log.err("{s}", .{why.buffered()});
                return error.InvalidTemplate;
            };
            for (bindings.items) |other| if (other.rule.method == rule.method and other.template.sameShape(&b.template)) {
                log.err("google.api.http on {s}: {t} matches the same paths as {s}.{s} ({s})", .{ where, rule.method, other.method.service.name, other.method.name, other.rule.pattern });
                return error.InvalidTemplate;
            };
            try bindings.append(a, b);
            transcode.addBinding(void, app.router, rule.method, &b.template, serveTranscoded, &b.options, where, m.detachable and m.kind == .unary);
        }
    };
    if (cfg.health) {
        const health = app.grpcHealth();
        for (e.grpc.services) |svc| try health.set(svc.name, .SERVING);
        while (!e.grpc.health_lock.tryLock()) std.atomic.spinLoopHint();
        defer e.grpc.health_lock.unlock();
        for (e.grpc.pending.items) |p| {
            try health.set(p.name, @enumFromInt(p.status));
            gpa.free(p.name);
        }
        e.grpc.pending.clearAndFree(gpa);
        e.grpc.health_live = true;
    }
}

// ---------------------------------------------------------------------------
// Calls (on executors)

fn handler(req: *http.Request, res: *http.Response) anyerror!void {
    const m: *const Method = @ptrCast(@alignCast(req.route.?.data.?));
    const e = m.engine;
    const xi = placement.currentExecutor(req.io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    if (x.consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    const call = try req.arena.create(Call);
    const timeout_ns = serving.begin(call, null, req, res, &m.options, m.kind, m.json()) catch |err| switch (err) {
        error.Answered => return,
        else => |er| return er,
    };
    const detach = m.detachable and call.impl.protocol != .grpc_web_text and res.canDetach();
    var message: []const u8 = "";
    if (m.kind == .unary or m.kind == .server_streaming) {
        message = readUnary(call, m, detach) catch |err| return serving.finish(call, err);
    }
    return start(x, m, call, message, timeout_ns, detach, "");
}

/// A transcoded call (a `google.api.http` binding matched): the request
/// message from the path, the query and the body, as protobuf bytes.
fn serveTranscoded(_: ?*anyopaque, req: *dusty.Request, res: *dusty.Response, captures: []const transcode.Capture, options: *const serving.RegisterOptions) anyerror!void {
    const b: *const Binding = @ptrCast(@alignCast(options.data.?));
    const m = b.method;
    const e = m.engine;
    const xi = placement.currentExecutor(req.io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    if (x.consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    const call = try req.arena.create(Call);
    const timeout_ns = serving.beginTranscoded(call, null, req, res, options, m.kind) catch |err| switch (err) {
        error.Answered => return,
        else => |er| return er,
    };
    const detach = m.detachable and m.kind == .unary and res.canDetach();
    const whole: ?[]const u8 = if (detach) (req.body() catch |err| return serving.transcodeFailed(call, err)) orelse "" else null;
    const body_text = serving.transcodedBody(call, b.rule.body.len > 0, whole) catch |err| return serving.transcodeFailed(call, err);
    const query = if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[q + 1 ..] else "";
    var diag: transcode.Diagnostic = .{};
    const json = transcode.requestJson(call.arena, b.rule.body, body_text, captures, query, &diag, schema.Fields{ .root = m.input.? }) catch |err| switch (err) {
        error.InvalidArgument => return serving.finish(call, call.fail(.invalid_argument, diag.message)),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var why: []const u8 = "";
    const message = schema.jsonToBinary(&e.grpc.schema.?, m.input.?, json, call.arena, &why) catch |err| switch (err) {
        error.DecodeFailed => return serving.finish(call, call.fail(.invalid_argument, why)),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return start(x, m, call, message, timeout_ns, detach, b.rule.response_body);
}

/// The one request message of a unary or server-streaming call, as
/// protobuf bytes in the call's memory. `whole`: the request is all in
/// memory (a detaching call, on the protocol's reader): nothing may wait.
fn readUnary(call: *Call, m: *const Method, whole: bool) ![]const u8 {
    var payload: []const u8 = undefined;
    if (call.impl.get) {
        payload = try serving.getMessage(call);
    } else if (whole) {
        const body = (try call.req.body()) orelse "";
        switch (call.impl.protocol) {
            .connect => {
                if (body.len > call.impl.max_message_size) return error.MessageTooLarge;
                payload = body;
            },
            else => {
                if (body.len == 0) return call.fail(.unimplemented, "a unary call needs one request message");
                if (body.len >= frame.header_size and body[0] == 0) {
                    // Not compressed: the message is read where it lies.
                    const len = std.mem.readInt(u32, body[1..5], .big);
                    if (len > call.impl.max_message_size) return error.MessageTooLarge;
                    if (body.len - frame.header_size < len) return error.TruncatedFrame;
                    if (body.len - frame.header_size > len) return error.ExpectedUnaryMessage;
                    payload = body[frame.header_size..][0..len];
                } else {
                    var r: std.Io.Reader = .fixed(body);
                    const msg = (try frame.readMessage(&r, serving.scratch, call.impl.max_message_size, call.impl.request_compression)).?;
                    defer serving.scratch.free(msg.payload);
                    if (r.bufferedLen() > 0) return error.ExpectedUnaryMessage;
                    payload = try call.arena.dupe(u8, msg.payload);
                }
            },
        }
    } else {
        var in_buf: [16 * 1024]u8 = undefined;
        var body = try call.req.reader(&in_buf);
        const p = (try serving.readPayload(call, &body, false)) orelse
            return call.fail(.unimplemented, "a unary call needs one request message");
        defer p.deinit();
        if (try serving.readPayload(call, &body, false)) |extra| {
            extra.deinit();
            return error.ExpectedUnaryMessage;
        }
        payload = if (p.owned != null) try call.arena.dupe(u8, p.bytes) else p.bytes;
    }
    if (call.impl.codec == .json) return toBinary(call, m, payload);
    return payload;
}

/// A JSON request message (Connect JSON, gRPC-Web JSON) as protobuf bytes.
fn toBinary(call: *Call, m: *const Method, json: []const u8) ![]const u8 {
    var why: []const u8 = "";
    return schema.jsonToBinary(&m.engine.grpc.schema.?, m.input.?, json, call.arena, &why) catch |err| switch (err) {
        error.DecodeFailed => call.fail(.invalid_argument, why),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Hands the call to the consumer; then, unless it detached, waits for its
/// answer on this task.
fn start(x: *Exec, m: *const Method, call: *Call, message: []const u8, timeout_ns: ?u64, detach_wanted: bool, response_body: []const u8) anyerror!void {
    const e = x.engine;
    const req = call.req;
    const res = call.res;
    if (detach_wanted and x.ring.full()) {
        _ = e.busy_count.fetchAdd(1, .monotonic);
        return serving.finish(call, call.fail(.unavailable, "the application is behind"));
    }
    const si = x.alloc() orelse {
        _ = e.busy_count.fetchAdd(1, .monotonic);
        return serving.finish(call, call.fail(.unavailable, "too many calls in flight"));
    };
    const s = &x.slots[si];
    const d: ?*Detached = if (detach_wanted) res.detach(req, .{ .abort = engine.detachedAborted, .ctx = s }) catch |err| {
        x.free_head = si;
        return err;
    } else null;
    if (d) |dd| {
        call.req = dd.request;
        call.res = dd.response;
    }
    const r = call.req;
    _ = e.inflight.fetchAdd(1, .monotonic);
    _ = e.requests.fetchAdd(1, .monotonic);
    const gen = genOf(s.word.load(.monotonic));
    serving.setDeadline(call, timeout_ns, m.options.max_call_duration);
    s.kind.store(@intFromEnum(Handle.Kind.grpc_call), .monotonic);
    s.req = r;
    s.flags = 0;
    s.remote_len = engine.remoteText(r, &s.remote);
    s.claims = engine.claimsOf(r);
    s.detached = d;
    s.body = "";
    s.borrowed = null;
    s.event.reset();
    s.pump_event.reset();
    s.drained.store(true, .monotonic);
    s.headers.clearRetainingCapacity();
    s.bytes.clearRetainingCapacity();
    s.trailers.clearRetainingCapacity();
    s.trailer_bytes.clearRetainingCapacity();
    s.body_off = 0;
    s.body_len = 0;
    const g = &s.grpc;
    var flags: u16 = 0;
    if (m.kind == .unary or m.kind == .server_streaming) flags |= abi.GRPC_CALL_MESSAGE;
    if (r.secure) flags |= abi.GRPC_CALL_SECURE;
    if (anole.early_data.isEarly(r)) flags |= abi.GRPC_CALL_EARLY_DATA;
    if (call.impl.codec == .json) flags |= abi.GRPC_CALL_JSON;
    if (call.impl.request_compression != .identity) flags |= abi.GRPC_CALL_COMPRESSED;
    g.* = .{
        .method = m,
        .call = call,
        .message = message,
        .metadata = try collectMetadata(r),
        .flags = flags,
        .deadline = if (call.deadline) |dl| dl.raw.nanoseconds else null,
        .response_body = response_body,
    };
    g.credit.store(m.service.cfg.read_ahead, .monotonic);
    s.word.store(pack(gen, .queued), .release);
    if (d != null and g.deadline != null) heapPush(x, si);

    var canceled = false;
    while (!x.ring.push(.{ .handle = x.handleOf(si, gen), .rec = null })) {
        std.debug.assert(d == null);
        zio.yield() catch {
            canceled = true;
            break;
        };
    }
    x.consumer.?.wake();
    if (d != null) {
        _ = e.detached_count.fetchAdd(1, .monotonic);
        return;
    }

    // Client and bidirectional streaming: the request messages come
    // through a reader task, beside this one.
    var in_buf: [16 * 1024]u8 = undefined;
    var body: dusty.RequestBodyReader = undefined;
    var reader: std.Io.Group = .init;
    defer reader.cancel(r.io);
    if (m.kind == .client_streaming or m.kind == .bidi_streaming) {
        body = r.reader(&in_buf) catch |err| {
            g.read_error = err;
            return wait(x, si, gen, call, canceled);
        };
        placement.concurrent(&reader, r.io, .local, readMessages, .{ x, si, gen, call, &body }) catch |err| {
            g.read_error = err;
        };
    }
    return wait(x, si, gen, call, canceled);
}

/// Request metadata as the consumer sees it: the headers but the
/// protocols' own, names in lower case, `-bin` values decoded (an
/// undecodable one is left out).
fn collectMetadata(req: *http.Request) ![]const [2][]const u8 {
    const n = req.headers.len;
    const out = try req.arena.alloc([2][]const u8, n);
    var k: usize = 0;
    for (req.headers.keys[0..n], req.headers.values[0..n]) |name_in, value| {
        if (isTransportHeader(name_in)) continue;
        var name = name_in;
        for (name_in) |ch| if (std.ascii.isUpper(ch)) {
            name = try std.ascii.allocLowerString(req.arena, name_in);
            break;
        };
        var v = value;
        if (md_keys.isBinaryKey(name)) {
            const trimmed = std.mem.trimEnd(u8, value, "=");
            const decoder = std.base64.standard_no_pad.Decoder;
            const len = decoder.calcSizeForSlice(trimmed) catch continue;
            const bytes = try req.arena.alloc(u8, len);
            decoder.decode(bytes, trimmed) catch continue;
            v = bytes;
        }
        out[k] = .{ name, v };
        k += 1;
    }
    return out[0..k];
}

/// Headers the protocols use themselves, and hop-by-hop ones: not metadata.
fn isTransportHeader(name: []const u8) bool {
    if (name.len == 0 or name[0] == ':') return true;
    const list = [_][]const u8{
        "content-type",     "te",                       "grpc-timeout",           "grpc-encoding",
        "grpc-accept-encoding", "content-length",       "content-encoding",       "accept-encoding",
        "connect-protocol-version", "connect-timeout-ms", "connect-content-encoding", "connect-accept-encoding",
        "connection",       "keep-alive",               "transfer-encoding",      "upgrade",
        "host",
    };
    for (list) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// The call's task waits for the answer, and writes it.
fn wait(x: *Exec, si: u32, gen: u32, call: *Call, canceled_in: bool) anyerror!void {
    const e = x.engine;
    const io = call.io;
    const s = &x.slots[si];
    var canceled = canceled_in;
    const outcome: enum { done, streaming, expired } = while (true) {
        const w = s.word.load(.acquire);
        std.debug.assert(genOf(w) == gen);
        switch (stateOf(w)) {
            .done => break .done,
            .streaming => break .streaming,
            .polling, .responding => {
                zio.yield() catch {
                    canceled = true;
                };
                continue;
            },
            .queued, .out => {
                if (canceled or s.grpc.read_error != null) {
                    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) == null) {
                        if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, gen));
                        break .expired;
                    }
                    continue;
                }
                s.event.wait(io) catch {
                    canceled = true;
                };
                s.event.reset();
            },
            .free, .expired => unreachable,
        }
    };
    switch (outcome) {
        .expired => {
            const err = s.grpc.read_error orelse error.Canceled;
            x.release(si);
            if (err == error.Canceled) {
                if (call.deadlineExceeded()) {
                    _ = e.expired_count.fetchAdd(1, .monotonic);
                } else _ = e.aborted_count.fetchAdd(1, .monotonic);
            }
            return serving.finish(call, err);
        },
        .done => {
            while (!s.drained.load(.acquire)) zio.yield() catch {
                canceled = true;
            };
            if (canceled) io.recancel();
            defer x.release(si);
            return answerWhole(call, s);
        },
        .streaming => {
            while (!s.drained.load(.acquire)) zio.yield() catch {
                canceled = true;
            };
            if (canceled) io.recancel();
            defer x.release(si);
            return stream(x, si, gen, call);
        },
    }
}

/// The client- or bidirectional-streaming call's request messages, to the
/// consumer while it has credit, then the half-close. A task beside the
/// call's.
fn readMessages(x: *Exec, si: u32, gen: u32, call: *Call, body: *dusty.RequestBodyReader) std.Io.Cancelable!void {
    const e = x.engine;
    const s = &x.slots[si];
    const g = &s.grpc;
    const m = g.method;
    const handle = x.handleOf(si, gen);
    while (true) {
        // Credit first.
        while (true) {
            s.pump_event.reset();
            if (!reading(s, gen)) return;
            if (g.credit.load(.acquire) > 0) break;
            g.reader_waiting.store(true, .seq_cst);
            if (g.credit.load(.seq_cst) > 0) {
                g.reader_waiting.store(false, .monotonic);
                break;
            }
            s.pump_event.wait(e.io) catch |err| {
                g.reader_waiting.store(false, .monotonic);
                return err;
            };
            g.reader_waiting.store(false, .monotonic);
        }
        const p = serving.readPayload(call, body, true) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return readFailed(x, si, gen, err);
        } orelse {
            const rec = newRecord(@sizeOf(abi.Event), .grpc_half_close, handle) catch return readFailed(x, si, gen, error.OutOfMemory);
            if (!reading(s, gen)) return freeRecord(rec);
            x.postRecord(rec, true);
            return;
        };
        defer p.deinit();
        var bytes = p.bytes;
        var converted: ?[]const u8 = null;
        defer if (converted) |cv| gpa.free(cv);
        if (call.impl.codec == .json) {
            var why: []const u8 = "";
            var tmp: std.heap.ArenaAllocator = .init(gpa);
            defer tmp.deinit();
            const bin = schema.jsonToBinary(&e.grpc.schema.?, m.input.?, bytes, tmp.allocator(), &why) catch |err| switch (err) {
                error.DecodeFailed => {
                    call.status = .invalid_argument;
                    call.status_message = call.arena.dupe(u8, why) catch "the request message is not valid JSON for its type";
                    return readFailed(x, si, gen, error.GrpcStatus);
                },
                error.OutOfMemory => return readFailed(x, si, gen, error.OutOfMemory),
            };
            converted = gpa.dupe(u8, bin) catch return readFailed(x, si, gen, error.OutOfMemory);
            bytes = converted.?;
        }
        const rec = newRecord(@sizeOf(abi.GrpcMessageEvent) + bytes.len, .grpc_message, handle) catch return readFailed(x, si, gen, error.OutOfMemory);
        const ev: *abi.GrpcMessageEvent = @ptrCast(rec.ptr);
        ev.route_id = m.service.cfg.handler;
        ev.data = .{ .off = @sizeOf(abi.GrpcMessageEvent), .len = @intCast(bytes.len) };
        @memcpy(rec[@sizeOf(abi.GrpcMessageEvent)..][0..bytes.len], bytes);
        if (!reading(s, gen)) return freeRecord(rec);
        _ = g.credit.fetchSub(1, .acq_rel);
        x.postRecord(rec, true);
    }
}

/// The call still wants request messages: its consumer has not answered
/// whole, nor has it ended.
fn reading(s: *const Slot, gen: u32) bool {
    const w = s.word.load(.acquire);
    if (genOf(w) != gen) return false;
    return switch (stateOf(w)) {
        .queued, .polling, .out, .responding, .streaming => true,
        else => false,
    };
}

/// Reading the request failed (too large, cut short, timed out): the
/// call's task ends the call with the matching status.
fn readFailed(x: *Exec, si: u32, gen: u32, err: anyerror) void {
    const s = &x.slots[si];
    if (genOf(s.word.load(.acquire)) != gen) return;
    s.grpc.read_error = err;
    s.event.set(x.engine.io);
}

fn newRecord(size: usize, typ: abi.EventType, handle: u64) ![]align(8) u8 {
    const n = abi.alignUp(size);
    const rec = try gpa.alignedAlloc(u8, .@"8", n);
    @memset(rec[@sizeOf(abi.Event)..], 0);
    const ev: *abi.Event = @ptrCast(rec.ptr);
    ev.* = .{ .type = @backingInt(typ), .len = @intCast(n), .handle = handle };
    return rec;
}

fn freeRecord(rec: []align(8) u8) void {
    gpa.free(rec);
}

// ---------------------------------------------------------------------------
// Answers (on executors)

/// Sends the answer of a call that is `done`: initial metadata, the
/// message, the status and trailing metadata, as one response (the body
/// collected, not streamed).
fn answerWhole(call: *Call, s: *Slot) !void {
    var buf: std.ArrayList(u8) = .empty;
    call.impl.buffer = &buf;
    defer call.impl.buffer = null;
    const result = applyWhole(call, s);
    return serving.finish(call, result);
}

fn applyWhole(call: *Call, s: *Slot) !void {
    try applyInitial(call, s);
    if (s.grpc.has_message) {
        const bytes = s.replyBody();
        try writeOne(call, s.grpc.method, s.grpc.response_body, bytes, true);
    }
    try applyStatus(call, s);
}

/// One response message (protobuf bytes) in the call's codec: JSON for
/// JSON calls (`response_body` alone for a transcoded call that names
/// one). `keep`: the call keeps it until `finish` (collected), so it is
/// copied into the call's memory; else it is written now (`writeStreamed`).
fn writeOne(call: *Call, m: *const Method, response_body: []const u8, bytes: []const u8, keep: bool) !void {
    if (call.impl.codec == .json) {
        const sch = &m.engine.grpc.schema.?;
        const alloc = if (keep) call.arena else gpa;
        const json = schema.binaryToJson(sch, m.output.?, bytes, alloc, response_body.len > 0) catch |err| switch (err) {
            error.DecodeFailed => return call.fail(.internal, "the response message does not decode as its type"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (!keep) gpa.free(json);
        const out = if (response_body.len > 0) schema.jsonField(call.arena, m.output.?, json, response_body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return call.fail(.internal, "the response message does not decode as its type"),
        } else json;
        return if (keep) serving.writePayload(call, out) else serving.writeStreamed(call, out);
    }
    if (keep) {
        // Connect unary keeps the payload itself; the framed protocols
        // copy it into the collected body.
        const payload = if (call.impl.protocol == .connect) try call.arena.dupe(u8, bytes) else bytes;
        return serving.writePayload(call, payload);
    }
    return serving.writeStreamed(call, bytes);
}

/// The consumer's initial metadata, as response headers.
fn applyInitial(call: *Call, s: *const Slot) !void {
    const bytes = s.bytes.items;
    for (s.headers.items) |h| {
        const name = try call.arena.dupe(u8, bytes[h.name_off..][0..h.name_len]);
        const value = try metadataValue(call, name, bytes[h.value_off..][0..h.value_len]);
        call.res.header(name, value) catch {};
    }
}

/// The consumer's status and trailing metadata, on the call.
fn applyStatus(call: *Call, s: *const Slot) !void {
    const g = &s.grpc;
    const tb = s.trailer_bytes.items;
    if (g.code != 0) {
        call.status = @enumFromInt(g.code);
        call.status_message = try call.arena.dupe(u8, tb[g.status_off..][0..g.status_len]);
    }
    for (s.trailers.items) |t| {
        const name = try call.arena.dupe(u8, tb[t.name_off..][0..t.name_len]);
        const value = try metadataValue(call, name, tb[t.value_off..][0..t.value_len]);
        try call.impl.trailers.append(call.arena, .{ .key = name, .value = value });
    }
    if (g.code != 0) return error.GrpcStatus;
}

/// A metadata value as it goes on the wire: base64 (unpadded) for a
/// `-bin` name, which the consumer gives as bytes.
fn metadataValue(call: *Call, name: []const u8, value: []const u8) ![]const u8 {
    if (!md_keys.isBinaryKey(name)) return call.arena.dupe(u8, value);
    const encoder = std.base64.standard_no_pad.Encoder;
    const out = try call.arena.alloc(u8, encoder.calcSize(value.len));
    return encoder.encode(out, value);
}

/// Streams the answer: the initial metadata, each message as the consumer
/// sends it, then the status. On the call's task (or a detached call's
/// attached one).
fn stream(x: *Exec, si: u32, gen: u32, call: *Call) anyerror!void {
    const s = &x.slots[si];
    const e = x.engine;
    const g = &s.grpc;
    var out_buf: [16 * 1024]u8 = undefined;
    call.impl.out_buf = &out_buf;
    applyInitial(call, s) catch |err| {
        streamGone(x, si, gen);
        return serving.finish(call, err);
    };
    var batch: [16]Chunk = undefined;
    while (true) {
        s.event.reset();
        if (g.timed_out) {
            streamGone(x, si, gen);
            _ = e.expired_count.fetchAdd(1, .monotonic);
            return serving.finish(call, call.fail(.deadline_exceeded, "deadline exceeded"));
        }
        if (g.read_error) |err| {
            streamGone(x, si, gen);
            return serving.finish(call, err);
        }
        var n: usize = 0;
        var ended = false;
        var writable = false;
        {
            s.out.acquire();
            defer s.out.release();
            while (n < batch.len) {
                const ch = s.out.front() orelse break;
                batch[n] = ch.*;
                n += 1;
                _ = s.out.take(ch.data.len - ch.off);
            }
            ended = s.out.ended and s.out.front() == null;
            if (n == 0 and !ended) s.out.exec_waiting = true;
            if (s.out.want_event and s.out.bytes <= e.stream_high_water / 2) {
                s.out.want_event = false;
                writable = true;
            }
        }
        if (writable) x.postEvent(.writable, x.handleOf(si, gen));
        s.out.notifyBlocked();
        for (batch[0..n], 0..) |ch, k| {
            writeOne(call, g.method, g.response_body, ch.data[ch.off..], false) catch |err| {
                for (batch[k..n]) |rest| engine.dropChunk(x, si, gen, rest);
                streamGone(x, si, gen);
                return serving.finish(call, err);
            };
            engine.dropChunk(x, si, gen, ch);
        }
        if (n > 0) continue;
        if (ended) {
            const result = applyStatus(call, s);
            x.closePipe(&s.out, gen, si);
            return serving.finish(call, result);
        }
        s.event.wait(call.io) catch |err| {
            streamGone(x, si, gen);
            return serving.finish(call, err);
        };
    }
}

/// A streamed answer that cannot go on: the consumer hears it is over, and
/// its sends get `ANOLE_E_GONE` from here on.
fn streamGone(x: *Exec, si: u32, gen: u32) void {
    const s = &x.slots[si];
    x.closePipe(&s.out, gen, si);
    x.postEvent(.abort, x.handleOf(si, gen));
}

/// A detached call answered (from the capi task's done list).
pub fn finishDetached(x: *Exec, si: u32) void {
    const s = &x.slots[si];
    const d = s.detached.?;
    const w = s.word.load(.acquire);
    const gen = genOf(w);
    const call = s.grpc.call;
    if (stateOf(w) == .streaming) {
        // A task writes the stream; the deadline stays watched.
        const spawned = if (d.attach()) |group| placement.concurrent(group, x.engine.io, .local, attachedTask, .{ x, si, gen }) else error.ConnectionClosed;
        spawned catch {
            x.postEvent(.abort, x.handleOf(si, gen));
            d.finish(error.ConnectionResetByPeer);
            x.release(si);
        };
        return;
    }
    heapRemove(x, si);
    s.detached = null;
    const result = answerWhole(call, s);
    d.finish(result);
    x.release(si);
}

fn attachedTask(x: *Exec, si: u32, gen: u32) std.Io.Cancelable!void {
    const s = &x.slots[si];
    const d = s.detached.?;
    s.detached = null;
    d.enter();
    const result = stream(x, si, gen, s.grpc.call);
    heapRemove(x, si);
    d.finish(result);
    x.release(si);
    if (result) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
}

/// Detached calls past their deadline: DEADLINE_EXCEEDED, and the consumer
/// hears ABORT. Returns when the next deadline is due, if any.
pub fn sweep(x: *Exec, now: i96) ?i96 {
    const st = &x.grpc;
    while (st.len > 0) {
        const si = st.heap[0];
        const s = &x.slots[si];
        if (s.grpc.deadline.? > now) return s.grpc.deadline.?;
        const w = s.word.load(.acquire);
        switch (stateOf(w)) {
            .queued, .out => {
                if (s.orphan) {
                    heapRemove(x, si);
                    continue;
                }
                expire(x, si, w);
            },
            .streaming => {
                // The task writing it ends it.
                heapRemove(x, si);
                s.grpc.timed_out = true;
                s.event.set(x.engine.io);
            },
            // The consumer is in a call on it: look again shortly.
            .polling, .responding => return now + std.time.ns_per_ms,
            else => heapRemove(x, si),
        }
    }
    return null;
}

fn expire(x: *Exec, si: u32, w: u64) void {
    const s = &x.slots[si];
    const gen = genOf(w);
    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) != null) return;
    if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, gen));
    _ = x.engine.expired_count.fetchAdd(1, .monotonic);
    heapRemove(x, si);
    const call = s.grpc.call;
    if (s.detached) |d| {
        s.detached = null;
        var buf: std.ArrayList(u8) = .empty;
        call.impl.buffer = &buf;
        const result = serving.finish(call, call.fail(.deadline_exceeded, "deadline exceeded"));
        call.impl.buffer = null;
        d.finish(result);
    }
    x.release(si);
}

// ---------------------------------------------------------------------------
// The record (on the consumer's thread, in `poll`)

pub fn recordSize(s: *const Slot) usize {
    const g = &s.grpc;
    const req = s.req;
    var n: usize = @sizeOf(abi.GrpcCallEvent) + g.metadata.len * 2 * @sizeOf(abi.Span);
    n += g.method.path.len + g.message.len + s.remote_len + req.listener.name.len + req.id.len + s.claims.len;
    for (g.metadata) |kv| n += kv[0].len + kv[1].len;
    return abi.alignUp(n);
}

pub fn encodeRecord(s: *const Slot, handle: u64, out: []u8) usize {
    const g = &s.grpc;
    const m = g.method;
    const req = s.req;
    const size = out.len;
    const spans: [*]align(1) abi.Span = @ptrCast(out[@sizeOf(abi.GrpcCallEvent)..].ptr);
    var pos: usize = @sizeOf(abi.GrpcCallEvent) + g.metadata.len * 2 * @sizeOf(abi.Span);
    const put = struct {
        fn f(buf: []u8, p: *usize, bytes: []const u8) abi.Span {
            const at = p.*;
            @memcpy(buf[at..][0..bytes.len], bytes);
            p.* += bytes.len;
            return .{ .off = @intCast(at), .len = @intCast(bytes.len) };
        }
    }.f;
    const method = put(out, &pos, m.path);
    for (g.metadata, 0..) |kv, k| {
        spans[2 * k] = put(out, &pos, kv[0]);
        spans[2 * k + 1] = put(out, &pos, kv[1]);
    }
    const message = put(out, &pos, g.message);
    const remote = put(out, &pos, s.remote[0..s.remote_len]);
    const listener = put(out, &pos, req.listener.name);
    const id = put(out, &pos, req.id);
    const claims = put(out, &pos, s.claims);
    std.debug.assert(abi.alignUp(pos) == size);
    @memset(out[pos..size], 0);
    const timeout_us: i64 = if (g.deadline) |dl| blk: {
        const now = std.Io.Clock.awake.now(m.engine.io).nanoseconds;
        break :blk @intCast(@max(@divTrunc(dl - now, std.time.ns_per_us), 0));
    } else -1;
    const rec: *align(1) abi.GrpcCallEvent = @ptrCast(out.ptr);
    rec.* = .{
        .ev = .{ .type = @backingInt(abi.EventType.grpc_call), .len = @intCast(size), .handle = handle },
        .route_id = m.service.cfg.handler,
        .method_id = m.id,
        .kind = @intFromEnum(m.kind),
        .protocol = @intFromEnum(g.call.impl.protocol),
        .flags = g.flags,
        .version = req.version_major * 10 + req.version_minor,
        .nmetadata = @intCast(g.metadata.len),
        .method = method,
        .message = message,
        .remote_addr = remote,
        .listener = listener,
        .id = id,
        .claims = claims,
        .timeout_us = timeout_us,
    };
    return size;
}

// ---------------------------------------------------------------------------
// The consumer's calls (any thread)

/// Metadata a consumer may send: a lower-case key, not the protocols' own
/// (`grpc-*` but grpc-status-details-bin, `connect-*`, `trailer-*`, HTTP's
/// framing), an ASCII value unless it is `-bin` (bytes, base64-encoded by
/// Anole).
fn checkMetadata(list: []const CHeader) error{Invalid}!void {
    for (list) |hd| {
        const name = hd.name.slice();
        const value = hd.value.slice();
        if (!md_keys.isValidKey(name)) return error.Invalid;
        if (std.mem.startsWith(u8, name, "grpc-") and !std.mem.eql(u8, name, "grpc-status-details-bin")) return error.Invalid;
        if (std.mem.startsWith(u8, name, "connect-") or std.mem.startsWith(u8, name, "trailer-")) return error.Invalid;
        if (isTransportHeader(name)) return error.Invalid;
        if (md_keys.isBinaryKey(name)) continue;
        for (value) |ch| if (ch < 0x20 or ch > 0x7e) return error.Invalid;
    }
}

fn slotOf(e: *Engine, hv: u64) ?struct { *Exec, *Slot, Handle } {
    return engine.slotOfKind(e, hv, .grpc_call);
}

/// `out` to `responding`; `error.Gone` when the call is over (or was never
/// this), `error.State` when its answer is streaming.
fn claim(e: *Engine, hv: u64) AnswerError!struct { *Exec, *Slot, Handle } {
    const x, const s, const h = slotOf(e, hv) orelse return e.gone();
    if (s.word.cmpxchgStrong(pack(h.gen, .out), pack(h.gen, .responding), .acquire, .monotonic)) |w| {
        if (genOf(w) == h.gen and stateOf(w) == .streaming) return error.State;
        return e.gone();
    }
    return .{ x, s, h };
}

fn unclaim(s: *Slot, h: Handle) void {
    s.word.store(pack(h.gen, .out), .release);
}

pub fn sendHeaders(e: *Engine, hv: u64, md: []const CHeader) AnswerError!void {
    try checkMetadata(md);
    _, const s, const h = try claim(e, hv);
    defer unclaim(s, h);
    if (s.grpc.headers_set or s.grpc.has_message) return error.State;
    // The message (stored by `send`) goes after these: none is there yet.
    try engine.storeHeaders(&s.headers, &s.bytes, md, 0);
    s.grpc.headers_set = true;
}

/// `ANOLE_BUSY` is `true`.
pub fn send(e: *Engine, hv: u64, msg: []const u8, borrow: bool, finish_ok: bool) AnswerError!bool {
    _, const s0, const h0 = slotOf(e, hv) orelse return e.gone();
    const kind = s0.grpc.method.kind;
    if (kind == .unary or kind == .client_streaming) {
        const x, const s, const h = try claim(e, hv);
        if (s.grpc.has_message) {
            unclaim(s, h);
            return error.State;
        }
        if (borrow) {
            s.borrowed = msg;
        } else {
            if (msg.len > std.math.maxInt(u32)) {
                unclaim(s, h);
                return error.Invalid;
            }
            s.bytes.appendSlice(gpa, msg) catch |err| {
                unclaim(s, h);
                return err;
            };
            s.body_off = @intCast(s.bytes.items.len - msg.len);
            s.body_len = @intCast(msg.len);
        }
        s.grpc.has_message = true;
        if (finish_ok) {
            s.grpc.code = 0;
            s.trailers.clearRetainingCapacity();
            s.trailer_bytes.clearRetainingCapacity();
            engine.handBack(x, s, h, .done);
        } else unclaim(s, h);
        return false;
    }
    // Server and bidirectional streaming: one pipe chunk per message.
    const s = s0;
    const h = h0;
    const owned: ?[]u8 = if (borrow or msg.len == 0) null else try gpa.dupe(u8, msg);
    errdefer if (owned) |o| gpa.free(o);
    const chunk: Chunk = if (msg.len == 0)
        .{ .data = "", .owner = .request }
    else
        .{ .data = owned orelse msg, .owner = if (borrow) .consumer else .pipe };
    if (s.out.gen != h.gen) {
        // The first message: the answer starts streaming.
        const x, _, _ = try claim(e, hv);
        s.trailers.clearRetainingCapacity();
        s.trailer_bytes.clearRetainingCapacity();
        s.grpc.code = 0;
        s.out.acquire();
        s.out.open(h.gen);
        s.out.push(chunk) catch |err| {
            s.out.gen = 0;
            s.out.release();
            unclaim(s, h);
            return err;
        };
        if (finish_ok) s.out.ended = true;
        s.out.release();
        engine.handBack(x, s, h, .streaming);
        return false;
    }
    s.out.acquire();
    if (!s.out.live(h.gen) or s.out.ended or s.out.failed) {
        s.out.release();
        return e.gone();
    }
    s.out.push(chunk) catch |err| {
        s.out.release();
        return err;
    };
    if (finish_ok) {
        s.grpc.code = 0;
        s.out.ended = true;
    }
    const busy = s.out.bytes > e.stream_high_water;
    if (busy and !finish_ok) s.out.want_event = true;
    const wake = s.out.exec_waiting;
    s.out.exec_waiting = false;
    s.out.release();
    if (wake) s.event.set(e.io);
    return busy and !finish_ok;
}

/// Waits (a blocking consumer thread) until the stream has room, then
/// sends `msg` (copied).
pub fn sendWait(e: *Engine, hv: u64, msg: []const u8, timeout_ms: i32) AnswerError!void {
    _, const s, const h = slotOf(e, hv) orelse return e.gone();
    if (s.grpc.method.kind == .unary or s.grpc.method.kind == .client_streaming or s.out.gen != h.gen) {
        _ = try send(e, hv, msg, false, false);
        return;
    }
    const tio = engine.threadedIo();
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms < 0) null else std.Io.Clock.Timestamp.now(tio, .awake).addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        const seq = s.out.seq.load(.acquire);
        s.out.acquire();
        const live = s.out.live(h.gen) and !s.out.ended and !s.out.failed;
        const room = s.out.bytes <= e.stream_high_water;
        s.out.release();
        if (!live) return e.gone();
        if (room) break;
        _ = s.out.blocked.fetchAdd(1, .acq_rel);
        defer _ = s.out.blocked.fetchSub(1, .acq_rel);
        if (deadline) |d| {
            if (std.Io.Clock.Timestamp.now(tio, .awake).compare(.gte, d)) return error.Timeout;
            tio.futexWaitTimeout(u32, &s.out.seq.raw, seq, .{ .deadline = d }) catch {};
        } else tio.futexWaitUncancelable(u32, &s.out.seq.raw, seq);
    }
    _ = try send(e, hv, msg, false, false);
}

pub fn finish(e: *Engine, hv: u64, code: u32, message: []const u8, trailers: []const CHeader) AnswerError!void {
    if (code > 16) return error.Invalid;
    try checkMetadata(trailers);
    if (message.len > 64 * 1024) return error.Invalid;
    _, const s0, const h0 = slotOf(e, hv) orelse return e.gone();
    if (s0.out.gen == h0.gen) {
        // Streaming: the status goes after the messages.
        const s = s0;
        s.out.acquire();
        if (!s.out.live(h0.gen) or s.out.ended or s.out.failed) {
            s.out.release();
            return e.gone();
        }
        storeStatus(s, code, message, trailers) catch |err| {
            s.out.release();
            return err;
        };
        s.out.ended = true;
        const wake = s.out.exec_waiting;
        s.out.exec_waiting = false;
        s.out.release();
        if (wake) s.event.set(e.io);
        return;
    }
    const x, const s, const h = claim(e, hv) catch |err| {
        // Streaming began between the two looks.
        if (err == error.State) return finish(e, hv, code, message, trailers);
        return err;
    };
    const kind = s.grpc.method.kind;
    if (code == 0 and !s.grpc.has_message and (kind == .unary or kind == .client_streaming)) {
        unclaim(s, h);
        return error.State;
    }
    storeStatus(s, code, message, trailers) catch |err| {
        unclaim(s, h);
        return err;
    };
    engine.handBack(x, s, h, .done);
}

fn storeStatus(s: *Slot, code: u32, message: []const u8, trailers: []const CHeader) !void {
    try engine.storeHeaders(&s.trailers, &s.trailer_bytes, trailers, message.len);
    s.grpc.status_off = @intCast(s.trailer_bytes.items.len);
    s.trailer_bytes.appendSliceAssumeCapacity(message);
    s.grpc.status_len = @intCast(message.len);
    s.grpc.code = @intCast(code);
}

/// The consumer takes `n` more request messages.
pub fn read(e: *Engine, hv: u64, n: u32) AnswerError!void {
    _, const s, const h = slotOf(e, hv) orelse return e.gone();
    const w = s.word.load(.acquire);
    if (genOf(w) != h.gen) return e.gone();
    switch (stateOf(w)) {
        .free, .expired, .done => return e.gone(),
        else => {},
    }
    const kind = s.grpc.method.kind;
    if (kind != .client_streaming and kind != .bidi_streaming) return error.State;
    _ = s.grpc.credit.fetchAdd(n, .acq_rel);
    if (s.grpc.reader_waiting.load(.seq_cst)) s.pump_event.set(e.io);
}

// ---------------------------------------------------------------------------
// Health

pub fn healthSet(e: *Engine, service: []const u8, status: c_int) AnswerError!void {
    const cfg = e.config.grpc orelse return error.State;
    if (!cfg.health) return error.State;
    if (status < abi.GRPC_HEALTH_UNKNOWN or status > abi.GRPC_HEALTH_NOT_SERVING) return error.Invalid;
    if (service.len > 255) return error.Invalid;
    const name = try gpa.dupe(u8, service);
    errdefer gpa.free(name);
    const st = &e.grpc;
    while (!st.health_lock.tryLock()) std.atomic.spinLoopHint();
    if (!st.health_live) {
        defer st.health_lock.unlock();
        for (st.pending.items) |*p| if (std.mem.eql(u8, p.name, name)) {
            p.status = status;
            gpa.free(name);
            return;
        };
        try st.pending.append(gpa, .{ .name = name, .status = status });
        return;
    }
    st.health_lock.unlock();
    if (e.execs.len == 0) return error.State;
    const cmd = try gpa.create(HealthCmd);
    cmd.* = .{ .name = name, .status = status };
    e.execs[0].post(&cmd.cmd);
}

const HealthCmd = struct {
    cmd: Command = .{ .run = run },
    name: []u8,
    status: c_int,

    fn run(c: *Command, x: *Exec) void {
        const self: *HealthCmd = @fieldParentPtr("cmd", c);
        defer {
            gpa.free(self.name);
            gpa.destroy(self);
        }
        const app = x.engine.app orelse return;
        app.grpcHealth().set(self.name, @enumFromInt(self.status)) catch {};
    }
};

test {
    _ = schema;
    _ = @import("grpc_test.zig");
}
