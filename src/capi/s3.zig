//! `anole_s3_*`: the configuration's S3-compatible object stores
//! ("storage"), used without blocking the caller (p3/s3,
//! design-connectors.md section 5). Handle kind 16 (`anole_s3_transfer`);
//! events 124-125.
//!
//! A one-shot call (get, head, put, delete, list, copy, multipart) copies
//! its arguments into a command for one of the consumer's executors; a task
//! there runs the call through `anole.s3` and queues one
//! `ANOLE_EV_S3_RESULT`. A transfer (a push upload, a streamed download) is
//! a slot in the executor's table with a task beside it. `serve` and
//! `put_body` use the request's slot as a consumer would (`streamStart`,
//! `streamWrite`, the body pipe), so the bytes never enter the language.
//! A write returns once its bytes are buffered; back-pressure is
//! `ANOLE_BUSY`, `ANOLE_E_AGAIN` and `ANOLE_EV_WRITABLE`, never a wait.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;
const AnswerError = engine.AnswerError;
const db = anole.db;
const log = @import("../errors.zig").log;

const s3 = if (features.s3) anole.s3 else struct {
    pub const Client = void;
    pub const Upload = void;
    pub const Download = void;
    pub const Bucket = void;
    pub const Meta = void;
    pub const Entry = void;
    pub const Failure = void;
    pub const Part = void;
    pub const Stored = void;
    pub const PutOptions = void;
    pub const GetOptions = void;
    pub const Source = void;
    pub const Provider = void;
    pub const Addressing = void;
    pub const Options = struct {
        pub const PayloadSigning = void;
    };
    pub const upload_ = struct {};
    pub const download_ = struct {};
};

const ms = std.Io.Duration.fromMilliseconds;

// ---------------------------------------------------------------------------
// Stores

/// One configured object store (`anole_s3 *` in C).
pub const Store = struct {
    engine: *Engine,
    config: config_mod.Config.Storage,
    index: u32,
    client: ?*s3.Client = null,
    /// Whether calls may be queued: from the start until the stop.
    open: std.atomic.Value(bool) = .init(false),
};

/// Engine-wide state (`Engine.s3_state`).
pub const State = struct {
    stores: []Store = &.{},
    lock: std.atomic.Mutex = .unlocked,
    first_gen: u32 = 1,

    pub fn init(s: *State, first_gen: u32) void {
        s.* = .{ .first_gen = first_gen };
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        if (s.stores.len > 0) gpa.free(s.stores);
        s.stores = &.{};
    }

    /// The stores, made from the configuration on first use.
    fn ensure(s: *State, e: *Engine) []Store {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
        defer s.lock.unlock();
        if (s.stores.len == 0 and e.config.storage.len > 0) {
            const list = gpa.alloc(Store, e.config.storage.len) catch return &.{};
            for (list, e.config.storage, 0..) |*st, c, i| st.* = .{ .engine = e, .config = c, .index = @intCast(i) };
            s.stores = list;
        }
        return s.stores;
    }
};

pub fn find(e: *Engine, name: []const u8) ?*Store {
    for (e.s3_state.ensure(e)) |*st| if (std.mem.eql(u8, st.config.name, name)) return st;
    return null;
}

// ---------------------------------------------------------------------------
// Transfers: the slot table of an executor

const TState = enum(u32) { free, open, closing };

fn packT(gen: u32, state: TState) u64 {
    return (@as(u64, gen) << 32) | @backingInt(state);
}

const chunk_len = 64;
const max_chunks = 1024;
comptime {
    std.debug.assert(chunk_len * max_chunks <= engine.max_slots);
}

const Kind = enum(u8) { upload, download };

pub const TSlot = struct {
    /// Generation and state; read by any thread.
    word: std.atomic.Value(u64) = .init(packT(1, .free)),
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,
    /// Taken by a consumer call for as long as it acts on the transfer
    /// (`lockLive`); the executor fills the slot and moves `word` out of
    /// `open` only under it, so under it a live word names the same
    /// transfer throughout. Never held across I/O.
    lock: std.atomic.Mutex = .unlocked,
    kind: Kind = .upload,
    up: ?*s3.Upload = null,
    /// The user_data of the call that opened it.
    open_user_data: u64 = 0,
    finish_user_data: std.atomic.Value(u64) = .init(0),
    finish_requested: std.atomic.Value(bool) = .init(false),
    wants_writable: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    /// Downloads: bytes the consumer allows beyond what was sent.
    credit: std.atomic.Value(u64) = .init(0),
    /// Wakes a download task (credit, release).
    event: std.Io.Event = .unset,
    stopped: bool = false,

    fn gen(t: *const TSlot) u32 {
        return @intCast(t.word.load(.acquire) >> 32);
    }

    fn handle(t: *const TSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .transfer, .slot = @intCast(t.index), .exec = t.exec.index });
    }
};

const Chunk = [chunk_len]TSlot;

pub const TransferTable = struct {
    chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
    nchunks: std.atomic.Value(u32) = .init(0),
    free_head: u32 = engine.no_slot,

    fn slot(t: *TransferTable, i: u32) ?*TSlot {
        if (i / chunk_len >= max_chunks) return null;
        const c = t.chunks[i / chunk_len].load(.acquire) orelse return null;
        return &c[i % chunk_len];
    }

    fn alloc(t: *TransferTable, x: *Exec) !*TSlot {
        if (t.free_head == engine.no_slot) {
            const n = t.nchunks.load(.monotonic);
            if (n == max_chunks) return error.TooManyTransfers;
            const c = try gpa.create(Chunk);
            const base = n * chunk_len;
            for (c, 0..) |*s, j| s.* = .{
                .word = .init(packT(x.engine.first_gen, .free)),
                .exec = x,
                .index = @intCast(base + j),
                .next_free = if (j + 1 < chunk_len) @intCast(base + j + 1) else engine.no_slot,
            };
            t.chunks[n].store(c, .release);
            t.nchunks.store(n + 1, .release);
            t.free_head = base;
        }
        const s = t.slot(t.free_head).?;
        t.free_head = s.next_free;
        return s;
    }

    fn markStopped(t: *TransferTable) void {
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
            for (cv.load(.acquire).?) |*s| s.stopped = true;
        }
    }

    fn maxGen(t: *const TransferTable) u32 {
        var max: u32 = 0;
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
            for (cv.load(.acquire).?) |*s| max = @max(max, s.gen());
        }
        return max;
    }

    fn deinit(t: *TransferTable) void {
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| gpa.destroy(cv.load(.acquire).?);
        t.nchunks.store(0, .release);
    }
};

/// Per executor (`Exec.s3`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,
    transfers: TransferTable = .{},

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.transfers.markStopped();
        st.work.cancel(io);
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        return @constCast(&st.transfers).maxGen();
    }

    pub fn deinit(st: *ExecState) void {
        st.transfers.deinit();
    }
};

fn freeSlot(x: *Exec, t: *TSlot, g: u32) void {
    t.up = null;
    t.released.store(false, .monotonic);
    t.wants_writable.store(false, .monotonic);
    t.finish_requested.store(false, .monotonic);
    t.event.reset();
    t.word.store(packT(engine.nextGen(g), .free), .release);
    t.next_free = x.s3.transfers.free_head;
    x.s3.transfers.free_head = t.index;
}

const Found = struct { *TSlot, Handle };

/// The transfer a handle names, with its generation and state checked.
fn transferOf(e: *Engine, hv: u64) ?Found {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .transfer) return null;
    if (h.exec >= e.execs.len) return null;
    const t = e.execs[h.exec].s3.transfers.slot(h.slot) orelse return null;
    const w = t.word.load(.acquire);
    if (@as(u32, @intCast(w >> 32)) != h.gen) return null;
    if (@as(TState, @fromBackingInt(@intCast(w & 0xFFFFFFFF))) != .open) return null;
    return .{ t, h };
}

/// A test hook (test builds only): while set, the next transfer call
/// (`uploadWrite`, `uploadFinish`, `readMore`, `release`) takes it and,
/// once it has found its transfer, holds before the slot's lock until the
/// test sets `release`, so a test can end that transfer on the executor
/// and open another in its slot meanwhile.
pub var test_transfer_hold: if (builtin.is_test) std.atomic.Value(?*engine.TestPin) else void = if (builtin.is_test) .init(null) else {};

fn testTransferHold() void {
    if (comptime !builtin.is_test) return;
    const p = test_transfer_hold.swap(null, .acq_rel) orelse return;
    p.held.store(true, .release);
    while (!p.release.load(.acquire)) std.Thread.yield() catch {};
}

/// Takes `t.lock` if the slot still holds the transfer `h` names (its
/// generation, open): `transferOf` checked it before the lock, when the
/// executor could still end it and reuse the slot for another transfer.
/// False: the lock is not held.
fn lockLive(t: *TSlot, h: Handle) bool {
    while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    if (t.word.load(.acquire) == packT(h.gen, .open)) return true;
    t.lock.unlock();
    return false;
}

// ---------------------------------------------------------------------------
// Lifecycle

fn optMs(n: u32) ?std.Io.Duration {
    return if (n > 0) ms(n) else null;
}

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    if (comptime !features.s3) return;
    for (e.s3_state.ensure(e)) |*st| {
        const c = st.config;
        const sc = c.s3;
        const client = try app.s3(.{
            .endpoint = sc.endpoint,
            .region = sc.region,
            .bucket = sc.bucket,
            .credentials = if (sc.anonymous) .anonymous else if (sc.access_key_id) |k| .{ .static = .{
                .access_key_id = k,
                .secret_access_key = sc.secret_access_key.?,
                .session_token = sc.session_token,
            } } else .chain,
            .provider = std.meta.stringToEnum(s3.Provider, sc.provider) orelse .auto,
            .addressing = std.meta.stringToEnum(s3.Addressing, sc.addressing) orelse .auto,
            .payload_signing = std.meta.stringToEnum(s3.Options.PayloadSigning, sc.payload_signing) orelse .auto,
            .name = c.name,
            .tls = tlsOf(sc),
            .timeout = optMs(c.timeout_ms),
            .min_throughput = sc.min_throughput,
            .connect_timeout = ms(sc.connect_timeout_ms),
            .max_idle_connections = sc.max_idle_connections,
            .part_size = sc.part_size,
            .multipart_threshold = sc.multipart_threshold,
            .concurrency = sc.concurrency,
            .upload_memory = sc.upload_memory,
            .max_object_bytes = sc.max_object_bytes,
            .errors = c.errors,
            .retry = if (c.retry) |r| .{
                .attempts = r.attempts,
                .backoff = .{ .base = ms(r.base_ms), .max = ms(r.max_ms), .multiplier = r.multiplier },
                .attempt_timeout = if (r.attempt_timeout_ms > 0) ms(r.attempt_timeout_ms) else null,
                .max_retry_after = ms(r.max_retry_after_ms),
            } else null,
            .breaker = if (c.breaker) |b| .{
                .consecutive_failures = b.consecutive_failures,
                .failure_ratio = b.failure_ratio,
                .min_calls = b.min_calls,
                .window = ms(b.window_ms),
                .open_for = ms(b.open_ms),
                .max_open_for = ms(b.max_open_ms),
                .half_open_calls = b.half_open_calls,
            } else null,
            .readiness = sc.readiness,
        });
        // The credential chain runs now, so a start without any fails here
        // naming every source it tried (the C ABI's "NoCredentials").
        if (!sc.anonymous and sc.access_key_id == null) {
            client.creds.resolve(@import("../s3/util.zig").nowSeconds(app.io())) catch |err| switch (err) {
                error.NoCredentials => {
                    log.err("storage \"{s}\": no credentials ({s})", .{ c.name, client.creds.report.items });
                    return error.NoCredentials;
                },
                else => |other| return other,
            };
        }
        st.client = client;
        st.open.store(true, .release);
    }
}

fn tlsOf(c: anytype) db.Tls {
    return .{
        .ca = if (c.ca_file) |f| .{ .file = f } else if (c.ca_pem) |pem| .{ .pem = pem } else null,
        .client_certificate = if (c.client_cert_file) |f|
            dusty.Cert.fromFiles(f, c.client_key_file.?)
        else if (c.client_cert_pem) |pem|
            dusty.Cert.fromPem(pem, c.client_key_pem.?)
        else
            null,
        .insecure_skip_verify = c.insecure_skip_verify,
    };
}

/// The drain started (`anole_server_drain`, once): no new upload starts;
/// those in flight finish.
pub fn draining(e: *Engine) void {
    if (comptime !features.s3) return;
    for (e.s3_state.stores) |*st| if (st.client) |c| c.draining.store(true, .release);
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    for (e.s3_state.stores) |*st| st.open.store(false, .release);
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    for (e.s3_state.stores) |*st| st.client = null;
}

// ---------------------------------------------------------------------------
// Results

pub const QueryError = error{ Invalid, State, OutOfMemory, Gone, Unsupported };

/// What goes into an `ANOLE_EV_S3_RESULT`.
const Res = struct {
    user_data: u64,
    op: u8,
    handle: u64 = 0,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: u8 = 0,
    s3_status: u16 = 0,
    flags: u16 = 0,
    content_length: u64 = 0,
    object_size: u64 = 0,
    range_start: u64 = 0,
    last_modified_ms: i64 = 0,
    meta: ?s3.Meta = null,
    body: []const u8 = "",
    entries: []const s3.Entry = &.{},
    failures: []const s3.Failure = &.{},
    prefixes: []const []const u8 = &.{},
    next: []const u8 = "",
    upload_id: []const u8 = "",
    etag: []const u8 = "",
    version_id: []const u8 = "",
    parts: u32 = 0,
    message: []const u8 = "",
    code: []const u8 = "",
    request_id: []const u8 = "",
    canceled: bool = false,

    fn fromMeta(r: *Res, m: s3.Meta) void {
        r.meta = m;
        r.s3_status = m.status;
        r.content_length = m.content_length;
        r.object_size = m.size;
        r.range_start = m.range_start;
        r.etag = m.etag;
        r.version_id = m.version_id orelse "";
        r.request_id = m.request_id;
        if (m.last_modified) |t| r.last_modified_ms = t.toMillis();
        if (m.delete_marker) r.flags |= abi.S3_RES_F_DELETE_MARKER;
    }

    fn fromStored(r: *Res, st: s3.Stored) void {
        r.etag = st.etag;
        r.version_id = st.version_id orelse "";
        r.content_length = st.size;
        r.parts = st.parts;
        r.s3_status = 200;
    }

    fn setClass(r: *Res, c: db.Class) void {
        r.error_class = @backingInt(std.meta.stringToEnum(abi.DbErrorClass, @tagName(c)) orelse .other);
    }

    fn failed(r: *Res, ctx: *db.Ctx, err: anyerror) void {
        if (err == error.Canceled) {
            r.canceled = true;
            return;
        }
        r.status = abi.E_SERVICE;
        r.http_status = httpStatus(err);
        if (db.lastError(ctx)) |d| {
            r.setClass(d.class);
            r.message = d.message;
            r.code = d.code;
            if (std.mem.eql(u8, d.code, "object_too_large")) r.status = abi.E_TOOBIG;
        } else {
            r.error_class = @backingInt(if (err == error.GatewayTimeout) abi.DbErrorClass.timeout else abi.DbErrorClass.other);
            r.message = @errorName(err);
        }
        if (err == error.OutOfMemory) r.status = abi.E_NOMEM;
        if (err == error.GatewayTimeout or r.error_class == @backingInt(abi.DbErrorClass.timeout)) r.status = abi.E_TIMEOUT;
    }

    /// The record: header, then the arrays, then the bytes.
    fn record(r: *const Res, max: u32) error{ TooBig, OutOfMemory }![]align(8) u8 {
        const Ev = abi.S3ResultEvent;
        const nmeta: usize = if (r.meta) |m| m.metadata.len else 0;
        var bytes: usize = r.body.len + r.next.len + r.upload_id.len + r.etag.len + r.version_id.len + r.message.len + r.code.len + r.request_id.len;
        if (r.meta) |m| {
            bytes += str(m.content_type).len + str(m.cache_control).len + str(m.content_disposition).len + str(m.content_encoding).len;
            for (m.metadata) |kv| bytes += kv[0].len + kv[1].len;
        }
        for (r.entries) |en| bytes += en.key.len + en.etag.len + str(en.storage_class).len;
        for (r.failures) |f| bytes += f.key.len + f.code.len + f.message.len;
        for (r.prefixes) |p| bytes += p.len;
        const meta_off = @sizeOf(Ev);
        const entries_off = meta_off + nmeta * 2 * @sizeOf(abi.Span);
        const nentries = if (r.failures.len > 0) r.failures.len else r.entries.len;
        const entry_size: usize = if (r.failures.len > 0) @sizeOf(abi.S3Failure) else @sizeOf(abi.S3Entry);
        const prefixes_off = abi.alignUp(entries_off + nentries * entry_size);
        const bytes_off = prefixes_off + r.prefixes.len * @sizeOf(abi.Span);
        const total = bytes_off + bytes;
        if (total > max) return error.TooBig;
        const rec = engine.newRecord(total, .s3_result, r.handle) catch return error.OutOfMemory;
        const ev: *Ev = @ptrCast(rec.ptr);
        var w: Writer = .{ .rec = rec, .at = bytes_off };
        ev.user_data = r.user_data;
        ev.status = r.status;
        ev.http_status = r.http_status;
        ev.error_class = r.error_class;
        ev.op = r.op;
        ev.s3_status = r.s3_status;
        ev.flags = r.flags;
        ev.nentries = @intCast(nentries);
        ev.content_length = r.content_length;
        ev.object_size = r.object_size;
        ev.range_start = r.range_start;
        ev.last_modified_ms = r.last_modified_ms;
        ev.etag = w.put(r.etag);
        ev.version_id = w.put(r.version_id);
        if (r.meta) |m| {
            ev.content_type = w.put(str(m.content_type));
            ev.cache_control = w.put(str(m.cache_control));
            ev.content_disposition = w.put(str(m.content_disposition));
            ev.content_encoding = w.put(str(m.content_encoding));
            ev.metadata_off = @intCast(meta_off);
            ev.nmetadata = @intCast(nmeta);
            const spans: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + meta_off));
            for (m.metadata, 0..) |kv, i| {
                spans[2 * i] = w.put(kv[0]);
                spans[2 * i + 1] = w.put(kv[1]);
            }
        }
        ev.body = w.put(r.body);
        ev.entries_off = @intCast(entries_off);
        if (r.failures.len > 0) {
            const fs: [*]abi.S3Failure = @ptrCast(@alignCast(rec.ptr + entries_off));
            for (r.failures, 0..) |f, i| fs[i] = .{ .key = w.put(f.key), .code = w.put(f.code), .message = w.put(f.message) };
        } else {
            const es: [*]abi.S3Entry = @ptrCast(@alignCast(rec.ptr + entries_off));
            for (r.entries, 0..) |en, i| es[i] = .{
                .key = w.put(en.key),
                .etag = w.put(en.etag),
                .storage_class = w.put(str(en.storage_class)),
                .size = en.size,
                .last_modified_ms = if (en.last_modified) |t| t.toMillis() else 0,
            };
        }
        ev.prefixes_off = @intCast(prefixes_off);
        ev.nprefixes = @intCast(r.prefixes.len);
        const ps: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + prefixes_off));
        for (r.prefixes, 0..) |p, i| ps[i] = w.put(p);
        ev.parts = r.parts;
        ev.next = w.put(r.next);
        ev.upload_id = w.put(r.upload_id);
        ev.@"error" = w.put(r.message);
        ev.error_code = w.put(r.code);
        ev.request_id = w.put(r.request_id);
        return rec;
    }
};

fn str(o: ?[]const u8) []const u8 {
    return o orelse "";
}

fn httpStatus(err: anyerror) u16 {
    return switch (err) {
        error.NotFound => 404,
        error.Conflict => 409,
        error.ServiceUnavailable => 503,
        error.GatewayTimeout => 504,
        error.BadRequest => 400,
        error.UnprocessableEntity => 422,
        else => 500,
    };
}

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

/// Queues `r` as a record, waiting for room in the ring: an answer must arrive.
fn post(x: *Exec, r: *const Res) void {
    const rec = r.record(x.engine.config.limits.db_result_max) catch |err| switch (err) {
        error.TooBig => (Res{ .user_data = r.user_data, .op = r.op, .handle = r.handle, .status = abi.E_TOOBIG, .http_status = 500, .error_class = @backingInt(abi.DbErrorClass.other), .message = "the answer is larger than limits.db_result_max" }).record(std.math.maxInt(u32)) catch return,
        error.OutOfMemory => (Res{ .user_data = r.user_data, .op = r.op, .handle = r.handle, .status = abi.E_NOMEM, .http_status = 500, .error_class = @backingInt(abi.DbErrorClass.other) }).record(std.math.maxInt(u32)) catch return,
    };
    x.postRecord(rec, true);
}

fn postGone(x: *Exec, user_data: u64, op: u8, message: []const u8) void {
    post(x, &.{ .user_data = user_data, .op = op, .status = abi.E_GONE, .message = message });
}

fn postNoMemory(x: *Exec, user_data: u64, op: u8) void {
    post(x, &.{ .user_data = user_data, .op = op, .status = abi.E_NOMEM, .message = "out of memory" });
}

fn postWritable(x: *Exec, handle: u64) void {
    const rec = engine.newRecord(@sizeOf(abi.Event), .writable, handle) catch return;
    x.postRecord(rec, true);
}

// ---------------------------------------------------------------------------
// One-shot calls

pub const Op = enum { get, head, put, delete, delete_many, list, copy, upload_open, multipart_create, multipart_complete, multipart_abort, serve, put_body };

fn opCode(op: Op) u8 {
    return switch (op) {
        .get => abi.S3_OP_GET,
        .head => abi.S3_OP_HEAD,
        .put => abi.S3_OP_PUT,
        .delete => abi.S3_OP_DELETE,
        .delete_many => abi.S3_OP_DELETE_MANY,
        .list => abi.S3_OP_LIST,
        .copy => abi.S3_OP_COPY,
        .upload_open => abi.S3_OP_UPLOAD_OPEN,
        .multipart_create => abi.S3_OP_MULTIPART_CREATE,
        .multipart_complete => abi.S3_OP_MULTIPART_COMPLETE,
        .multipart_abort => abi.S3_OP_MULTIPART_ABORT,
        .serve => abi.S3_OP_SERVE,
        .put_body => abi.S3_OP_PUT_BODY,
    };
}

/// A call in flight: one allocation holding the command and every copied argument.
const Call = struct {
    cmd: Command = .{ .run = run },
    store: *Store,
    op: Op,
    user_data: u64,
    flags: u32 = 0,
    timeout_ms: u32 = 0,
    req: u64 = 0,
    bucket: []const u8 = "",
    version_id: []const u8 = "",
    key: []const u8 = "",
    /// copy: the source key and bucket.
    src_key: []const u8 = "",
    src_bucket: []const u8 = "",
    // get
    range_start: u64 = 0,
    range_end: u64 = std.math.maxInt(u64),
    if_none_match: []const u8 = "",
    if_match: []const u8 = "",
    if_modified_since_ms: i64 = 0,
    max_bytes: u32 = 0,
    window: u32 = 0,
    response_content_type: []const u8 = "",
    response_cache_control: []const u8 = "",
    response_content_disposition: []const u8 = "",
    // put
    data: []const u8 = "",
    content_type: []const u8 = "",
    cache_control: []const u8 = "",
    content_disposition: []const u8 = "",
    content_encoding: []const u8 = "",
    metadata: []const [2][]const u8 = &.{},
    storage_class: []const u8 = "",
    content_length: u64 = 0,
    // list
    prefix: []const u8 = "",
    delimiter: []const u8 = "",
    start_after: []const u8 = "",
    continuation: []const u8 = "",
    max_keys: u32 = 0,
    // delete_many, multipart_complete
    keys: []const []const u8 = &.{},
    parts: []const s3.Part = &.{},
    upload_id: []const u8 = "",
    tied: db_mod.Tied = .{ .cut = cut },
    task: ?placement.Task = null,
    ended: bool = false,
    arena: std.heap.ArenaAllocator,

    fn free(c: *Call) void {
        var arena = c.arena;
        arena.deinit();
    }

    fn tracked(c: *const Call) bool {
        return c.req != 0 and c.op != .serve and c.op != .put_body;
    }

    fn cut(t: *db_mod.Tied) void {
        const c: *Call = @alignCast(@fieldParentPtr("tied", t));
        c.ended = true;
        if (c.task) |tk| placement.cancelTask(tk);
    }

    fn run(cmd: *Command, x: *Exec) void {
        const c: *Call = @alignCast(@fieldParentPtr("cmd", cmd));
        if (x.engine.phase.load(.acquire) == .stopped) return c.free();
        if (c.tracked()) {
            const h = Handle.decode(c.req);
            if (!db_mod.slotLive(x, h)) {
                postGone(x, c.user_data, opCode(c.op), "the request it served ended first");
                return c.free();
            }
            db_mod.linkTied(x, h.slot, &c.tied);
        }
        placement.concurrent(&x.s3.work, x.engine.io, .local, task, .{ x, c }) catch {
            if (c.tracked()) db_mod.unlinkTied(x, Handle.decode(c.req).slot, &c.tied);
            c.free();
        };
    }

    fn bucketFor(c: *const Call) s3.Bucket {
        const cl = c.store.client.?;
        var b = if (c.bucket.len > 0) cl.bucket(c.bucket) else cl.with(.{});
        b.call = .{
            .timeout = if (c.timeout_ms == abi.DB_TIMEOUT_NONE) .max else if (c.timeout_ms > 0) ms(c.timeout_ms) else null,
            .retry = if (c.flags & abi.S3_F_NO_RETRY != 0) false else null,
        };
        return b;
    }

    fn getOptions(c: *const Call) s3.GetOptions {
        return .{
            .range = if (c.flags & abi.S3_F_RANGE != 0) .{ .start = c.range_start, .end = if (c.range_end == std.math.maxInt(u64)) null else c.range_end } else null,
            .version_id = if (c.version_id.len > 0) c.version_id else null,
            .if_none_match = if (c.if_none_match.len > 0) c.if_none_match else null,
            .if_match = if (c.if_match.len > 0) c.if_match else null,
            .if_modified_since = if (c.if_modified_since_ms != 0) db.Time.fromMillis(c.if_modified_since_ms) else null,
            .max_bytes = if (c.max_bytes > 0) c.max_bytes else null,
        };
    }

    fn putOptions(c: *const Call) s3.PutOptions {
        return .{
            .content_type = if (c.content_type.len > 0) c.content_type else null,
            .cache_control = if (c.cache_control.len > 0) c.cache_control else null,
            .content_disposition = if (c.content_disposition.len > 0) c.content_disposition else null,
            .content_encoding = if (c.content_encoding.len > 0) c.content_encoding else null,
            .metadata = c.metadata,
            .storage_class = if (c.storage_class.len > 0) c.storage_class else null,
            .if_absent = c.flags & abi.S3_F_IF_ABSENT != 0,
            .if_match = if (c.if_match.len > 0) c.if_match else null,
            .replace_metadata = c.flags & abi.S3_F_REPLACE_METADATA != 0,
        };
    }
};

/// A call for `st`, and the executor that runs it.
fn startCall(st: *Store, c: ?*Consumer, req: u64, op: Op, user_data: u64) QueryError!struct { *Call, *Exec } {
    const e = st.engine;
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    switch (e.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!st.open.load(.acquire)) return error.State;
    const x: *Exec = if (req != 0) try db_mod.resolveReq(e, req, c) else blk: {
        const cc = c orelse return error.Invalid;
        if (cc.execs.items.len == 0) return error.State;
        const i = cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len;
        break :blk cc.execs.items[i];
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const call = try arena.allocator().create(Call);
    call.* = .{ .store = st, .op = op, .user_data = user_data, .req = req, .arena = undefined };
    call.arena = arena;
    return .{ call, x };
}

fn dupe(a: std.mem.Allocator, s: abi.Str) std.mem.Allocator.Error![]const u8 {
    return if (s.len == 0) "" else try a.dupe(u8, s.slice());
}

fn checkKey(key: abi.Str) QueryError!void {
    if (key.len == 0 or key.len > 1024) return error.Invalid;
}

fn commonOptions(c: *Call, flags: u32, timeout_ms: u32, bucket: abi.Str) std.mem.Allocator.Error!void {
    c.flags = flags;
    c.timeout_ms = timeout_ms;
    c.bucket = try dupe(c.arena.allocator(), bucket);
}

/// `anole_s3_get` and `anole_s3_head`.
pub fn get(st: *Store, c: ?*Consumer, key: abi.Str, o: abi.S3GetOptions, user_data: u64, head: bool) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, c, o.req, if (head) .head else .get, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.version_id = try dupe(a, o.version_id);
    call.range_start = o.range_start;
    call.range_end = o.range_end;
    call.if_none_match = try dupe(a, o.if_none_match);
    call.if_match = try dupe(a, o.if_match);
    call.if_modified_since_ms = o.if_modified_since_ms;
    call.max_bytes = o.max_bytes;
    call.window = if (o.window == 0) 262144 else o.window;
    x.post(&call.cmd);
}

/// `anole_s3_put`: `data` is copied.
pub fn put(st: *Store, c: ?*Consumer, key: abi.Str, data: []const u8, o: abi.S3PutOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, c, o.req, .put, user_data);
    errdefer call.free();
    try fillPut(call, key, o);
    call.data = try call.arena.allocator().dupe(u8, data);
    x.post(&call.cmd);
}

fn fillPut(call: *Call, key: abi.Str, o: abi.S3PutOptions) QueryError!void {
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.content_type = try dupe(a, o.content_type);
    call.cache_control = try dupe(a, o.cache_control);
    call.content_disposition = try dupe(a, o.content_disposition);
    call.content_encoding = try dupe(a, o.content_encoding);
    call.storage_class = try dupe(a, o.storage_class);
    call.if_match = try dupe(a, o.if_match);
    call.content_length = o.content_length;
    if (o.nmetadata > 0) {
        const list_ = (o.metadata orelse return error.Invalid)[0..o.nmetadata];
        const out = try a.alloc([2][]const u8, list_.len);
        for (list_, out) |h, *dst| dst.* = .{ try dupe(a, h.name), try dupe(a, h.value) };
        call.metadata = out;
    }
}

pub fn uploadOpen(st: *Store, c: ?*Consumer, key: abi.Str, o: abi.S3PutOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, c, o.req, .upload_open, user_data);
    errdefer call.free();
    try fillPut(call, key, o);
    x.post(&call.cmd);
}

pub fn multipartCreate(st: *Store, c: ?*Consumer, key: abi.Str, o: abi.S3PutOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, c, o.req, .multipart_create, user_data);
    errdefer call.free();
    try fillPut(call, key, o);
    x.post(&call.cmd);
}

pub fn delete(st: *Store, c: ?*Consumer, key: abi.Str, o: abi.S3Options, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, c, o.req, .delete, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.version_id = try dupe(a, o.version_id);
    x.post(&call.cmd);
}

pub fn deleteMany(st: *Store, c: ?*Consumer, keys: []const abi.Str, o: abi.S3Options, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    for (keys) |k| try checkKey(k);
    const call, const x = try startCall(st, c, o.req, .delete_many, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    const names = try a.alloc([]const u8, keys.len);
    for (keys, names) |k, *dst| dst.* = try dupe(a, k);
    call.keys = names;
    x.post(&call.cmd);
}

pub fn listObjects(st: *Store, c: ?*Consumer, o: abi.S3ListOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    if (o.max_keys > 1000) return error.Invalid;
    const call, const x = try startCall(st, c, o.req, .list, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.prefix = try dupe(a, o.prefix);
    call.delimiter = try dupe(a, o.delimiter);
    call.start_after = try dupe(a, o.start_after);
    call.continuation = try dupe(a, o.continuation);
    call.max_keys = o.max_keys;
    x.post(&call.cmd);
}

pub fn copy(st: *Store, c: ?*Consumer, src_bucket: abi.Str, src_key: abi.Str, dst_key: abi.Str, o: abi.S3PutOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(src_key);
    try checkKey(dst_key);
    const call, const x = try startCall(st, c, o.req, .copy, user_data);
    errdefer call.free();
    try fillPut(call, dst_key, o);
    const a = call.arena.allocator();
    call.src_key = try dupe(a, src_key);
    call.src_bucket = try dupe(a, src_bucket);
    x.post(&call.cmd);
}

pub fn multipartComplete(st: *Store, c: ?*Consumer, key: abi.Str, upload_id: abi.Str, parts: []const abi.S3Part, o: abi.S3Options, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    if (upload_id.len == 0 or parts.len == 0 or parts.len > 10000) return error.Invalid;
    const call, const x = try startCall(st, c, o.req, .multipart_complete, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.upload_id = try dupe(a, upload_id);
    const list_ = try a.alloc(s3.Part, parts.len);
    for (parts, list_) |p, *dst| {
        if (p.number < 1 or p.number > 10000 or p.reserved != 0) return error.Invalid;
        dst.* = .{ .number = @intCast(p.number), .etag = try dupe(a, p.etag) };
    }
    call.parts = list_;
    x.post(&call.cmd);
}

pub fn multipartAbort(st: *Store, c: ?*Consumer, key: abi.Str, upload_id: abi.Str, o: abi.S3Options, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    if (upload_id.len == 0) return error.Invalid;
    const call, const x = try startCall(st, c, o.req, .multipart_abort, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.upload_id = try dupe(a, upload_id);
    x.post(&call.cmd);
}

/// `anole_s3_serve`.
pub fn serve(st: *Store, req: u64, key: abi.Str, o: abi.S3GetOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, null, req, .serve, user_data);
    errdefer call.free();
    const a = call.arena.allocator();
    try commonOptions(call, o.flags, o.timeout_ms, o.bucket);
    call.key = try dupe(a, key);
    call.version_id = try dupe(a, o.version_id);
    call.range_start = o.range_start;
    call.range_end = o.range_end;
    call.if_none_match = try dupe(a, o.if_none_match);
    call.if_match = try dupe(a, o.if_match);
    call.response_content_type = try dupe(a, o.response_content_type);
    call.response_cache_control = try dupe(a, o.response_cache_control);
    call.response_content_disposition = try dupe(a, o.response_content_disposition);
    x.post(&call.cmd);
}

/// `anole_s3_put_body`.
pub fn putBody(st: *Store, req: u64, key: abi.Str, o: abi.S3PutOptions, user_data: u64) QueryError!void {
    if (comptime !features.s3) return error.Unsupported;
    try checkKey(key);
    const call, const x = try startCall(st, null, req, .put_body, user_data);
    errdefer call.free();
    try fillPut(call, key, o);
    x.post(&call.cmd);
}

/// On the executor: runs the call and queues the answer.
fn task(x: *Exec, c: *Call) std.Io.Cancelable!void {
    defer {
        if (c.tracked()) db_mod.unlinkTied(x, Handle.decode(c.req).slot, &c.tied);
        c.free();
    }
    const e = x.engine;
    c.task = placement.currentTask(e.io);
    const opc = opCode(c.op);
    if (c.ended) return postGone(x, c.user_data, opc, "the request it served ended (aborted or past its deadline)");
    if (!c.store.open.load(.acquire) or c.store.client == null) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = e.io, .arena = arena.allocator() };
    var r: Res = .{ .user_data = c.user_data, .op = opc };
    const b = c.bucketFor();
    switch (c.op) {
        .get => {
            if (c.flags & abi.S3_F_STREAM != 0) return streamGet(x, c, &ctx, b);
            if (b.get(&ctx, c.key, c.getOptions())) |obj| {
                r.fromMeta(obj.meta);
                r.body = obj.body;
            } else |err| r.failed(&ctx, err);
        },
        .head => {
            if (b.head(&ctx, c.key, c.getOptions())) |m| r.fromMeta(m) else |err| r.failed(&ctx, err);
        },
        .put => {
            if (b.put(&ctx, c.key, .{ .bytes = c.data }, c.putOptions())) |st| r.fromStored(st) else |err| r.failed(&ctx, err);
        },
        .delete => {
            if (b.delete(&ctx, c.key, .{ .version_id = if (c.version_id.len > 0) c.version_id else null })) {
                r.s3_status = 204;
            } else |err| r.failed(&ctx, err);
        },
        .delete_many => {
            if (b.deleteMany(&ctx, c.keys)) |dr| {
                r.s3_status = 200;
                r.failures = dr.failed;
                r.parts = dr.deleted;
            } else |err| r.failed(&ctx, err);
        },
        .list => {
            if (b.list(&ctx, .{
                .prefix = if (c.prefix.len > 0) c.prefix else null,
                .delimiter = if (c.delimiter.len > 0) c.delimiter else null,
                .start_after = if (c.start_after.len > 0) c.start_after else null,
                .continuation = if (c.continuation.len > 0) c.continuation else null,
                .max_keys = if (c.max_keys == 0) 1000 else @intCast(c.max_keys),
            })) |page| {
                r.s3_status = 200;
                r.entries = page.entries;
                r.prefixes = page.prefixes;
                if (page.next) |n| {
                    r.next = n;
                    r.flags |= abi.S3_RES_F_TRUNCATED;
                }
            } else |err| r.failed(&ctx, err);
        },
        .copy => {
            const from: s3.Source = .{ .key = c.src_key, .bucket = if (c.src_bucket.len > 0) c.src_bucket else null };
            if (b.copy(&ctx, from, c.key, c.putOptions())) |st| r.fromStored(st) else |err| r.failed(&ctx, err);
        },
        .upload_open => return openUpload(x, c, &ctx, b),
        .multipart_create => {
            if (b.multipart().create(&ctx, c.key, c.putOptions())) |id| {
                r.upload_id = id;
                r.s3_status = 200;
            } else |err| r.failed(&ctx, err);
        },
        .multipart_complete => {
            if (b.multipart().complete(&ctx, c.key, c.upload_id, c.parts)) |st| r.fromStored(st) else |err| r.failed(&ctx, err);
        },
        .multipart_abort => {
            if (b.multipart().abort(&ctx, c.key, c.upload_id)) {
                r.s3_status = 204;
            } else |err| r.failed(&ctx, err);
        },
        .serve => return serveTask(x, c, &ctx, b),
        .put_body => try putBodyTask(x, c, &ctx, b, &r),
    }
    if (r.canceled) {
        if (c.ended) return postGone(x, c.user_data, opc, "the request it served ended (aborted or past its deadline)");
        return error.Canceled;
    }
    post(x, &r);
}

// ---------------------------------------------------------------------------
// Transfers: uploads

const KickCmd = struct {
    cmd: Command = .{ .run = run },
    slot: u32,
    gen: u32,

    fn run(cmd: *Command, x: *Exec) void {
        const k: *KickCmd = @alignCast(@fieldParentPtr("cmd", cmd));
        defer gpa.destroy(k);
        if (x.engine.phase.load(.acquire) == .stopped) return;
        const t = x.s3.transfers.slot(k.slot) orelse return;
        if (t.gen() != k.gen) return;
        wakeTransfer(x, t);
    }
};

/// On the executor: wakes whatever task serves the transfer.
fn wakeTransfer(x: *Exec, t: *TSlot) void {
    const io = x.engine.io;
    t.event.set(io);
    while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    const up = t.up;
    t.lock.unlock();
    if (up) |u| {
        u.wake.ring(io);
        u.progress.ring(io);
    }
}

fn kick(t: *TSlot, h: Handle) void {
    const k = gpa.create(KickCmd) catch return;
    k.* = .{ .slot = h.slot, .gen = h.gen };
    t.exec.post(&k.cmd);
}

/// On the executor: makes the upload's slot and its watcher task.
fn openUpload(x: *Exec, c: *Call, ctx: *db.Ctx, b: s3.Bucket) std.Io.Cancelable!void {
    var r: Res = .{ .user_data = c.user_data, .op = abi.S3_OP_UPLOAD_OPEN };
    const declared: ?u64 = if (c.flags & abi.S3_F_LENGTH != 0) c.content_length else null;
    const up = s3.upload_.open(b, ctx, c.key, c.putOptions(), declared) catch |err| {
        r.failed(ctx, err);
        if (r.canceled) return error.Canceled;
        return post(x, &r);
    };
    const t = x.s3.transfers.alloc(x) catch {
        up.deinit();
        r.status = abi.E_NOMEM;
        r.message = "too many transfers";
        return post(x, &r);
    };
    const g = t.gen();
    while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    t.kind = .upload;
    t.up = up;
    t.open_user_data = c.user_data;
    t.finish_user_data.store(0, .monotonic);
    t.finish_requested.store(false, .monotonic);
    t.wants_writable.store(false, .monotonic);
    t.released.store(false, .monotonic);
    t.word.store(packT(g, .open), .release);
    t.lock.unlock();
    r.handle = t.handle(g);
    r.s3_status = 200;
    post(x, &r);
    placement.concurrent(&x.s3.work, x.engine.io, .local, uploadWatch, .{ x, t, g }) catch teardownUpload(x, t, g);
}

fn teardownUpload(x: *Exec, t: *TSlot, g: u32) void {
    while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    const up = t.up;
    t.up = null;
    t.word.store(packT(g, .closing), .release);
    t.lock.unlock();
    if (up) |u| u.deinit();
    freeSlot(x, t, g);
}

/// One per upload: reports back-pressure relief and the end.
fn uploadWatch(x: *Exec, t: *TSlot, g: u32) std.Io.Cancelable!void {
    defer teardownUpload(x, t, g);
    const up = t.up.?;
    const handle = t.handle(g);
    while (true) {
        const seen = up.progress.seen();
        if (t.released.load(.acquire) or t.stopped) return;
        if (up.poll()) |res| {
            var r: Res = .{
                .user_data = if (t.finish_requested.load(.acquire)) t.finish_user_data.load(.acquire) else t.open_user_data,
                .op = abi.S3_OP_UPLOAD_FINISH,
                .handle = handle,
            };
            if (res) |stored| {
                r.fromStored(stored);
            } else |err| {
                r.status = abi.E_SERVICE;
                r.http_status = httpStatus(err);
                if (up.failureDetail()) |d| {
                    r.setClass(d.class);
                    r.message = d.message;
                    r.code = d.code;
                    if (d.class == .timeout) r.status = abi.E_TIMEOUT;
                }
            }
            post(x, &r);
            return;
        }
        if (t.wants_writable.load(.acquire) and up.lowWater()) {
            if (t.wants_writable.swap(false, .acq_rel)) postWritable(x, handle);
        }
        try up.progress.wait(x.engine.io, seen);
    }
}

fn scratchCtx(buf: []u8, fba: *std.heap.FixedBufferAllocator) db.Ctx {
    fba.* = .init(buf);
    return .{ .io = engine.threadedIo(), .arena = fba.allocator() };
}

/// `anole_s3_upload_write`: true is `ANOLE_BUSY`.
pub fn uploadWrite(e: *Engine, hv: u64, data: []const u8, flags: u32) AnswerError!bool {
    if (comptime !features.s3) return error.Unsupported;
    if (flags != 0) return error.Invalid;
    const t, const h = transferOf(e, hv) orelse return e.gone();
    testTransferHold();
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = undefined;
    var ctx = scratchCtx(&buf, &fba);
    if (!lockLive(t, h)) return e.gone();
    if (t.kind != .upload) {
        t.lock.unlock();
        return error.WrongKind;
    }
    const up = t.up orelse {
        t.lock.unlock();
        return e.gone();
    };
    if (data.len > up.part_size) {
        t.lock.unlock();
        return error.Invalid;
    }
    const res = up.copyIn(&ctx, data);
    // Under the lock: after it the slot may hold another transfer.
    if (res) |v| {
        if (v.taken != .ok) t.wants_writable.store(true, .release);
    } else |_| {}
    t.lock.unlock();
    const r = res catch return e.gone();
    if (r.rotated) kick(t, h);
    switch (r.taken) {
        .ok => return false,
        .busy => {
            kick(t, h);
            return true;
        },
        .full => {
            kick(t, h);
            return error.Again;
        },
    }
}

/// `anole_s3_upload_finish`.
pub fn uploadFinish(e: *Engine, hv: u64, user_data: u64) AnswerError!void {
    if (comptime !features.s3) return error.Unsupported;
    const t, const h = transferOf(e, hv) orelse return e.gone();
    testTransferHold();
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = undefined;
    var ctx = scratchCtx(&buf, &fba);
    if (!lockLive(t, h)) return e.gone();
    if (t.kind != .upload) {
        t.lock.unlock();
        return error.WrongKind;
    }
    const up = t.up orelse {
        t.lock.unlock();
        return e.gone();
    };
    if (t.finish_requested.load(.acquire)) {
        t.lock.unlock();
        return error.State;
    }
    t.finish_user_data.store(user_data, .release);
    t.finish_requested.store(true, .release);
    const res = up.beginFinish(&ctx);
    t.lock.unlock();
    res catch return e.gone();
    kick(t, h);
}

/// `anole_s3_read_more`.
pub fn readMore(e: *Engine, hv: u64, bytes: u32) AnswerError!void {
    if (comptime !features.s3) return error.Unsupported;
    const t, const h = transferOf(e, hv) orelse return e.gone();
    testTransferHold();
    if (!lockLive(t, h)) return e.gone();
    if (t.kind != .download) {
        t.lock.unlock();
        return error.WrongKind;
    }
    _ = t.credit.fetchAdd(bytes, .acq_rel);
    t.lock.unlock();
    kick(t, h);
}

/// `anole_handle_release` on a transfer (a cleanup call: over is OK).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    if (comptime !features.s3) return error.Unsupported;
    const t, const h = transferOf(e, hv) orelse return error.Over;
    testTransferHold();
    if (!lockLive(t, h)) return error.Over;
    t.released.store(true, .release);
    t.lock.unlock();
    kick(t, h);
}

// ---------------------------------------------------------------------------
// Transfers: streamed downloads

const Data = struct {
    user_data: u64,
    handle: u64,
    offset: u64,
    data: []const u8 = "",
    fin: bool = false,
    status: i32 = abi.OK,
    message: []const u8 = "",
};

fn postData(x: *Exec, d: *const Data) void {
    const total = @sizeOf(abi.S3DataEvent) + d.data.len + d.message.len;
    const rec = engine.newRecord(total, .s3_data, d.handle) catch return;
    const ev: *abi.S3DataEvent = @ptrCast(rec.ptr);
    ev.user_data = d.user_data;
    ev.status = d.status;
    ev.flags = if (d.fin) abi.S3_DATA_F_FIN else 0;
    ev.offset = d.offset;
    var w: Writer = .{ .rec = rec, .at = @sizeOf(abi.S3DataEvent) };
    ev.data = w.put(d.data);
    ev.@"error" = w.put(d.message);
    x.postRecord(rec, true);
}

/// On the executor: reads the object into DATA records within the credit.
fn streamGet(x: *Exec, c: *Call, ctx: *db.Ctx, b: s3.Bucket) std.Io.Cancelable!void {
    var r: Res = .{ .user_data = c.user_data, .op = abi.S3_OP_GET };
    var dl = b.open(ctx, c.key, c.getOptions()) catch |err| {
        r.failed(ctx, err);
        if (r.canceled) return error.Canceled;
        return post(x, &r);
    };
    defer dl.deinit();
    r.fromMeta(dl.meta);
    if (dl.meta.not_modified) return post(x, &r);
    const t = x.s3.transfers.alloc(x) catch {
        r.status = abi.E_NOMEM;
        r.message = "too many transfers";
        return post(x, &r);
    };
    const g = t.gen();
    while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    t.kind = .download;
    t.up = null;
    t.open_user_data = c.user_data;
    t.released.store(false, .monotonic);
    t.credit.store(c.window, .monotonic);
    t.event.reset();
    t.word.store(packT(g, .open), .release);
    t.lock.unlock();
    const handle = t.handle(g);
    r.handle = handle;
    post(x, &r);
    defer {
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
        t.word.store(packT(g, .closing), .release);
        t.lock.unlock();
        freeSlot(x, t, g);
    }
    const buf = ctx.arena.alloc(u8, s3.download_.read_buffer_len) catch return;
    var offset: u64 = 0;
    const rd = dl.reader();
    while (true) {
        if (t.released.load(.acquire) or t.stopped) return;
        const credit = t.credit.load(.acquire);
        if (credit == 0) {
            try t.event.wait(x.engine.io);
            t.event.reset();
            continue;
        }
        const want: usize = @intCast(@min(@as(u64, buf.len), credit));
        var w: std.Io.Writer = .fixed(buf[0..want]);
        const n = rd.stream(&w, .limited(want)) catch |err| {
            var d: Data = .{ .user_data = c.user_data, .handle = handle, .offset = offset, .fin = true };
            if (err != error.EndOfStream) {
                const re = dl.readError();
                d.status = if (re != null and re.? == error.GatewayTimeout) abi.E_TIMEOUT else abi.E_SERVICE;
                d.message = if (re) |v| @errorName(v) else "the download failed";
            }
            return postData(x, &d);
        };
        if (n == 0) continue;
        _ = t.credit.fetchSub(n, .acq_rel);
        postData(x, &.{ .user_data = c.user_data, .handle = handle, .offset = offset, .data = buf[0..n] });
        offset += n;
    }
}

// ---------------------------------------------------------------------------
// serve and put_body: the request's slot, used as a consumer would

fn slotOfReq(x: *Exec, hv: u64) ?*engine.Slot {
    const h = Handle.decode(hv);
    if (!db_mod.slotLive(x, h)) return null;
    return &x.slots[h.slot];
}

const CHeaders = struct {
    items: [16]abi.Header = undefined,
    len: usize = 0,

    fn add(self: *CHeaders, name: []const u8, value: []const u8) void {
        if (value.len == 0 or self.len >= self.items.len) return;
        self.items[self.len] = .{ .name = abi.Str.of(name), .value = abi.Str.of(value) };
        self.len += 1;
    }

    fn slice(self: *const CHeaders) []const abi.Header {
        return self.items[0..self.len];
    }
};

fn serveTask(x: *Exec, c: *Call, ctx: *db.Ctx, b: s3.Bucket) std.Io.Cancelable!void {
    const s = slotOfReq(x, c.req) orelse return postGone(x, c.user_data, abi.S3_OP_SERVE, "the request ended first");
    // The request's memory may go at any suspension below (its stream
    // reset, its deadline): what is read of it is copied first (M3).
    const a = ctx.arena;
    const req = s.req;
    const is_head = req.method == .head;
    // The request's own conditional headers, unless the options set them.
    var go = c.getOptions();
    const has_if_range = req.headers.get("If-Range") != null;
    if (go.range == null and !has_if_range) {
        if (req.headers.get("Range")) |rv| {
            const spec = if (std.mem.startsWith(u8, rv, "bytes=")) rv[6..] else "";
            if (std.mem.indexOfScalar(u8, spec, '-')) |dash| if (std.mem.indexOfScalar(u8, spec, ',') == null) {
                if (std.fmt.parseInt(u64, spec[0..dash], 10)) |start| {
                    const end: ?u64 = if (dash + 1 < spec.len) (std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch null) else null;
                    go.range = .{ .start = start, .end = end };
                } else |_| {}
            };
        }
    }
    if (go.if_none_match == null) if (req.headers.get("If-None-Match")) |v| {
        go.if_none_match = a.dupe(u8, v) catch return postNoMemory(x, c.user_data, abi.S3_OP_SERVE);
    };
    if (go.if_match == null) if (req.headers.get("If-Match")) |v| {
        go.if_match = a.dupe(u8, v) catch return postNoMemory(x, c.user_data, abi.S3_OP_SERVE);
    };
    if (go.if_modified_since == null) if (req.headers.get("If-Modified-Since")) |v| if (@import("../s3/util.zig").parseHttpDate(v)) |t| {
        go.if_modified_since = db.Time.fromSeconds(t);
    };
    // S3 applies RFC 9110 13.2.2's order itself (If-Unmodified-Since only
    // without If-Match), so both go on as the Zig path's `serve` sends them.
    if (go.if_unmodified_since == null) if (req.headers.get("If-Unmodified-Since")) |v| if (@import("../s3/util.zig").parseHttpDate(v)) |t| {
        go.if_unmodified_since = db.Time.fromSeconds(t);
    };
    var r: Res = .{ .user_data = c.user_data, .op = abi.S3_OP_SERVE };
    var hl: CHeaders = .{};
    if (is_head) {
        const m = b.head(ctx, c.key, go) catch |err| return serveFailed(x, c, ctx, &r, err);
        return serveAnswer(x, c, m, &hl, null, true);
    }
    var dl = b.open(ctx, c.key, go) catch |err| return serveFailed(x, c, ctx, &r, err);
    defer dl.deinit();
    try serveAnswer(x, c, dl.meta, &hl, &dl, false);
}

fn serveFailed(x: *Exec, c: *Call, ctx: *db.Ctx, r: *Res, err: anyerror) std.Io.Cancelable!void {
    r.failed(ctx, err);
    if (r.canceled) return error.Canceled;
    if (c.flags & abi.S3_F_PASS_NOT_FOUND != 0 and r.error_class == @backingInt(abi.DbErrorClass.not_found)) {
        return post(x, r);
    }
    const status: u16 = if (r.error_class == @backingInt(abi.DbErrorClass.precondition))
        412
    else if (std.mem.eql(u8, r.code, "InvalidRange"))
        416
    else if (r.http_status == 0) 500 else r.http_status;
    engine.fail(x.engine, c.req, status, r.message) catch {};
    if (c.flags & abi.S3_F_REPORT != 0) post(x, r);
}

fn serveAnswer(x: *Exec, c: *Call, m: s3.Meta, hl: *CHeaders, dl: ?*s3.Download, head: bool) std.Io.Cancelable!void {
    const e = x.engine;
    var date: [29]u8 = undefined;
    var range_text: [80]u8 = undefined;
    var cl_text: [24]u8 = undefined;
    hl.add("content-type", if (c.response_content_type.len > 0) c.response_content_type else (m.content_type orelse ""));
    hl.add("cache-control", if (c.response_cache_control.len > 0) c.response_cache_control else (m.cache_control orelse ""));
    hl.add("content-disposition", if (c.response_content_disposition.len > 0) c.response_content_disposition else (m.content_disposition orelse ""));
    hl.add("content-encoding", m.content_encoding orelse "");
    hl.add("etag", m.etag);
    if (m.last_modified) |t| hl.add("last-modified", @import("../s3/util.zig").formatHttpDate(&date, t.toSeconds()));
    hl.add("accept-ranges", "bytes");
    if (m.status == 206 and m.content_length > 0) {
        hl.add("content-range", std.fmt.bufPrint(&range_text, "bytes {d}-{d}/{d}", .{ m.range_start, m.range_start + m.content_length - 1, m.size }) catch "");
    }
    const status: u16 = if (m.status == 206) 206 else if (m.not_modified) 304 else 200;
    if (!m.not_modified) hl.add("content-length", std.fmt.bufPrint(&cl_text, "{d}", .{m.content_length}) catch "");
    const download = dl orelse null;
    if (m.not_modified or head or m.content_length == 0 or download == null) {
        engine.respond(e, c.req, status, hl.slice(), "", false) catch {};
        if (c.flags & abi.S3_F_REPORT != 0) {
            var r: Res = .{ .user_data = c.user_data, .op = abi.S3_OP_SERVE };
            r.fromMeta(m);
            post(x, &r);
        }
        return;
    }
    // The request is no longer owed when this fails (answered, or gone).
    engine.streamStart(e, c.req, status, hl.slice()) catch return;
    const slot = slotOfReq(x, c.req) orelse return;
    const h = Handle.decode(c.req);
    const buf = gpa.alloc(u8, 64 * 1024) catch return;
    defer gpa.free(buf);
    const rd = download.?.reader();
    var ok = true;
    while (true) {
        // Room first: the pipe holds what the client has not taken yet.
        while (true) {
            slot.out.acquire();
            const live = slot.out.live(h.gen) and !slot.out.ended and !slot.out.failed;
            const room = slot.out.bytes <= e.stream_high_water;
            slot.out.release();
            if (!live) return;
            if (room) break;
            try e.io.sleep(ms(2), .awake);
        }
        var w: std.Io.Writer = .fixed(buf);
        const n = rd.stream(&w, .limited(buf.len)) catch |err| {
            ok = err == error.EndOfStream;
            break;
        };
        if (n == 0) continue;
        _ = engine.streamWrite(e, c.req, buf[0..n], false) catch return;
    }
    if (ok) {
        engine.streamEnd(e, c.req, &.{}) catch {};
    } else {
        // The head is out; the only honest end is a cut one.
        engine.handleRelease(e, c.req) catch {};
    }
    if (c.flags & abi.S3_F_REPORT != 0) {
        var r: Res = .{ .user_data = c.user_data, .op = abi.S3_OP_SERVE };
        r.fromMeta(m);
        if (!ok) r.status = abi.E_SERVICE;
        post(x, &r);
    }
}

/// A `std.Io.Reader` over a request's body pipe, read from the executor
/// with short sleeps while nothing is there.
const BodyReader = struct {
    interface: std.Io.Reader,
    x: *Exec,
    slot: *engine.Slot,
    gen: u32,
    failed: bool = false,

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
        const s = self.slot;
        var tmp: [16 * 1024]u8 = undefined;
        const want = @min(tmp.len, @backingInt(limit));
        if (want == 0) return 0;
        while (true) {
            s.in.acquire();
            const word = s.word.load(.acquire);
            const state = engine.stateOf(word);
            // Orphaned: the stream went while a consumer call held the
            // slot, and with it what the pipe held (executor-local, read
            // on the executor).
            const mine = engine.genOf(word) == self.gen and state != .free and state != .expired and state != .done and !s.orphan;
            if (!mine or s.in.failed) {
                s.in.release();
                self.failed = true;
                return error.ReadFailed;
            }
            if (!s.in.live(self.gen)) {
                s.in.release();
                return error.EndOfStream;
            }
            const n = s.in.read(tmp[0..want]);
            const ended = s.in.ended and s.in.front() == null;
            const wake = s.in.exec_waiting and n > 0;
            if (wake) s.in.exec_waiting = false;
            s.in.release();
            if (wake) self.x.setEvent(&s.pump_event);
            if (n > 0) {
                w.writeAll(tmp[0..n]) catch return error.WriteFailed;
                return n;
            }
            if (ended) return error.EndOfStream;
            self.x.engine.io.sleep(ms(1), .awake) catch {
                self.failed = true;
                return error.ReadFailed;
            };
        }
    }
};

fn putBodyTask(x: *Exec, c: *Call, ctx: *db.Ctx, b: s3.Bucket, r: *Res) std.Io.Cancelable!void {
    const s = slotOfReq(x, c.req) orelse {
        r.status = abi.E_GONE;
        r.message = "the request ended first";
        return;
    };
    const h = Handle.decode(c.req);
    var po = c.putOptions();
    // The request's memory may go at any suspension below (its stream
    // reset, its deadline): what is read of it is copied first (M3).
    if (po.content_type == null) if (s.req.headers.get("Content-Type")) |v| {
        po.content_type = ctx.arena.dupe(u8, v) catch {
            r.status = abi.E_NOMEM;
            return;
        };
    };
    s.in.acquire();
    const streamed = s.in.live(h.gen);
    s.in.release();
    const result: anyerror!s3.Stored = blk: {
        if (!streamed) {
            const body = ctx.arena.dupe(u8, s.body) catch {
                r.status = abi.E_NOMEM;
                return;
            };
            break :blk b.put(ctx, c.key, .{ .bytes = body }, po);
        }
        const buffer = ctx.arena.alloc(u8, 16 * 1024) catch {
            r.status = abi.E_NOMEM;
            return;
        };
        var br: BodyReader = .{
            .interface = .{ .vtable = &.{ .stream = BodyReader.streamFn }, .buffer = buffer, .seek = 0, .end = 0 },
            .x = x,
            .slot = s,
            .gen = h.gen,
        };
        const len: ?u64 = if (s.content_length != std.math.maxInt(u64)) s.content_length else null;
        const res = b.put(ctx, c.key, .{ .reader = .{ .reader = &br.interface, .len = len } }, po);
        if (br.failed) {
            r.status = abi.E_GONE;
            r.message = "the request body failed";
            return;
        }
        break :blk res;
    };
    if (result) |st| r.fromStored(st) else |err| r.failed(ctx, err);
}

// ---------------------------------------------------------------------------
// Presigning

/// `anole_s3_presign`: the URL's length, written into `buf` when it fits;
/// negative: a status.
pub fn presign(st: *Store, method: u32, key: abi.Str, o: abi.S3PresignOptions, buf: []u8) i64 {
    if (comptime !features.s3) return abi.E_UNSUPPORTED;
    const cl = st.client orelse return abi.E_STATE;
    if (!st.open.load(.acquire)) return abi.E_STATE;
    if (key.len == 0 or key.len > 1024 or method > abi.S3_PRESIGN_UPLOAD_PART) return abi.E_INVALID;
    var scratch: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = undefined;
    var ctx = scratchCtx(&scratch, &fba);
    const bucket = if (o.bucket.len > 0) o.bucket.slice() else (cl.default_bucket orelse return abi.E_INVALID);
    const url = cl.presignUrl(&ctx, bucket, @fromBackingInt(@intCast(method)), key.slice(), .{
        .expires = std.Io.Duration.fromSeconds(if (o.expires_s == 0) 900 else o.expires_s),
        .version_id = if (o.version_id.len > 0) o.version_id.slice() else null,
        .content_type = if (o.content_type.len > 0) o.content_type.slice() else null,
        .content_length = if (o.flags & abi.S3_PRESIGN_F_CONTENT_LENGTH != 0) o.content_length else null,
        .response_content_type = if (o.response_content_type.len > 0) o.response_content_type.slice() else null,
        .response_content_disposition = if (o.response_content_disposition.len > 0) o.response_content_disposition.slice() else null,
        .upload_id = if (o.upload_id.len > 0) o.upload_id.slice() else null,
        .part_number = @intCast(@min(o.part_number, std.math.maxInt(u16))),
    }) catch |err| return switch (err) {
        error.OutOfMemory => abi.E_NOMEM,
        error.BadRequest => abi.E_INVALID,
        else => abi.E_STATE,
    };
    if (url.len <= buf.len) @memcpy(buf[0..url.len], url);
    return @intCast(url.len);
}
