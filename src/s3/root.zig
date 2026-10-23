//! `anole.s3` (`-Ds3`): an S3-compatible object storage client (AWS S3,
//! Cloudflare R2, MinIO, Backblaze B2, Supabase Storage) on Anole's core
//! HTTP client, with its own SigV4 signer. Built, not adopted: no candidate
//! is on `std.Io` with BoringSSL and has presigning, multipart and correct
//! XML (research: design-connectors.md section 1.1).
//!
//!     const files = try app.s3(.{});          // AWS_* variables, S3_BUCKET
//!     _ = try files.put(req, "avatars/1.png", .request, .{});   // the request body goes to S3
//!     _ = try files.serve(req, res, "avatars/1.png", .{});      // and back
//!
//! A write returns once its bytes are buffered: `Upload.write` never waits
//! for the network (`.busy` and `error.ServiceUnavailable` with code
//! "upload_full" signal back-pressure). Every operation is idempotent, so
//! retries are on by default. See docs/storage.md.
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");
const resilience = @import("../resilience/root.zig");

pub const sigv4 = @import("sigv4.zig");
pub const xml = @import("xml.zig");
pub const endpoint = @import("endpoint.zig");
pub const credentials = @import("credentials.zig");
pub const errors_ = @import("errors.zig");
const fetch = @import("fetch.zig");
const util = @import("util.zig");
pub const upload_ = @import("upload.zig");
pub const download_ = @import("download.zig");
pub const testing = @import("testing.zig");

const Duration = std.Io.Duration;
const log = std.log.scoped(.anole);

pub const Header = [2][]const u8;

/// What a call can fail with: `anole.db.Error` (so a handler's `try` gives
/// the right status), a cancel, memory.
pub const Error = db.Error || error{ Canceled, OutOfMemory };

pub const Provider = endpoint.Provider;
pub const Addressing = endpoint.Addressing;
pub const Upload = upload_.Upload;
pub const Download = download_.Download;

pub const Options = struct {
    /// "https://<account>.r2.cloudflarestorage.com", "http://127.0.0.1:9000",
    /// "https://<ref>.supabase.co/storage/v1/s3". Null: AWS_ENDPOINT_URL_S3,
    /// then AWS_ENDPOINT_URL, else AWS (https://s3.<region>.amazonaws.com).
    endpoint: ?[]const u8 = null,
    /// Null: AWS_REGION, then AWS_DEFAULT_REGION, else the provider's
    /// (R2 "auto"), else "us-east-1".
    region: ?[]const u8 = null,
    /// The bucket calls use; null: S3_BUCKET. A call on a client without one
    /// (and not through `bucket(name)`) is error.BadRequest, code "no_bucket",
    /// and init logs a warning.
    bucket: ?[]const u8 = null,
    credentials: Credentials = .chain,
    provider: Provider = .auto,
    addressing: Addressing = .auto,
    payload_signing: PayloadSigning = .auto,
    /// The client's name in metrics, spans and logs; null: "s3".
    name: ?[]const u8 = null,
    tls: db.Tls = .{},
    /// A bound on each call (each request to the service). `.max`: none.
    timeout: ?Duration = .fromSeconds(30),
    /// Calls that move a body get `timeout + bytes / min_throughput`.
    min_throughput: u64 = 1024 * 1024,
    connect_timeout: Duration = .fromSeconds(10),
    /// Idle connections kept per executor (the core client's per-host limit).
    max_idle_connections: u16 = 64,
    /// Uploads: the part size (5 MiB .. 5 GiB).
    part_size: u64 = 8 * 1024 * 1024,
    /// A body of known length up to this size goes up as one PUT; null:
    /// `part_size`. A body of unknown length switches to multipart after
    /// `part_size` bytes.
    multipart_threshold: ?u64 = null,
    /// Parts of one upload in flight at once (1..16).
    concurrency: u8 = 2,
    /// Part buffers of every upload of this client together; past it a part
    /// waits (pull) or `write` answers busy/upload_full (push).
    upload_memory: u64 = 256 * 1024 * 1024,
    /// `get`'s default bound on a whole body read into memory.
    max_object_bytes: u64 = 16 * 1024 * 1024,
    errors: db.ErrorMap = .{},
    retry: ?resilience.Retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(2) } },
    breaker: ?resilience.Breaker.Options = .{},
    /// Register a readiness check (HeadBucket, cached 5 s). Off: a storage
    /// outage hits every instance at once; pulling them all from the load
    /// balancer makes it worse.
    readiness: bool = false,
    environ: ?std.process.Environ = null,

    pub const Credentials = union(enum) {
        /// The chain: environment, shared file, then roles on AWS.
        chain,
        static: struct { access_key_id: []const u8, secret_access_key: []const u8, session_token: ?[]const u8 = null },
        /// Unsigned requests (public buckets).
        anonymous,
    };
    pub const PayloadSigning = enum { auto, signed, unsigned };
};

pub const CallOptions = struct {
    /// Null: Options.timeout; `.max`: none.
    timeout: ?Duration = null,
    /// Null: on (Options.retry); false: this call is tried once.
    retry: ?bool = null,
};

pub const GetOptions = struct {
    /// Bytes `start..end` inclusive; `end` null: to the end. A 206 answer.
    range: ?struct { start: u64, end: ?u64 = null } = null,
    version_id: ?[]const u8 = null,
    /// A 304: `Object`/`Download` with `not_modified = true`, no body.
    if_none_match: ?[]const u8 = null,
    /// A 412 is `precondition` (409).
    if_match: ?[]const u8 = null,
    if_modified_since: ?db.Time = null,
    /// `get`: the whole-body bound; null: Options.max_object_bytes.
    max_bytes: ?u64 = null,
};

pub const ServeOptions = struct {
    version_id: ?[]const u8 = null,
    /// Overrides of what the object has.
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    /// Take Range and If-* from the request (default) or ignore them.
    conditional: bool = true,
};

pub const Meta = struct {
    /// What S3 answered: 200, 206, 304.
    status: u16 = 200,
    not_modified: bool = false,
    content_length: u64 = 0,
    /// The whole object's size (from Content-Range on a 206).
    size: u64 = 0,
    range_start: u64 = 0,
    etag: []const u8 = "",
    version_id: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    last_modified: ?db.Time = null,
    storage_class: ?[]const u8 = null,
    /// x-amz-meta-* without the prefix, names lower-cased.
    metadata: []const Header = &.{},
    request_id: []const u8 = "",
    delete_marker: bool = false,

    pub fn meta(self: Meta, name: []const u8) ?[]const u8 {
        for (self.metadata) |m| if (std.ascii.eqlIgnoreCase(m[0], name)) return m[1];
        return null;
    }
};

/// A whole object, in the call's arena.
pub const Object = struct { meta: Meta, body: []const u8 };

pub const Body = union(enum) {
    bytes: []const u8,
    /// Read to its end, or to `len` when given (then the part size is chosen
    /// from it and a shorter stream is error.BadRequest, code "short_body").
    reader: struct { reader: *std.Io.Reader, len: ?u64 = null },
    /// A file path, read with `std.Io` (its size is the length).
    file: []const u8,
    /// The request's body (`c` must be the request): Content-Length when
    /// given; read through the request's reader, so `limits.body_max` applies.
    request,
};

pub const PutOptions = struct {
    /// Null: from the key's extension, else application/octet-stream.
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
    metadata: []const Header = &.{},
    storage_class: ?[]const u8 = null,
    /// Create only: If-None-Match: * (fails with `precondition` -> 409 when it exists).
    if_absent: bool = false,
    /// Overwrite only this version: If-Match.
    if_match: ?[]const u8 = null,
    /// `copy`: replace the metadata with these options' instead of copying it.
    replace_metadata: bool = false,
    /// Signed extra headers (`x-amz-server-side-encryption`, ...).
    headers: []const Header = &.{},
};

pub const Stored = struct { etag: []const u8 = "", version_id: ?[]const u8 = null, size: u64 = 0, parts: u32 = 0 };

pub const DeleteOptions = struct { version_id: ?[]const u8 = null };
pub const Failure = xml.Failure;
pub const DeleteResult = struct { deleted: u32, failed: []const Failure };

pub const ListOptions = struct {
    prefix: ?[]const u8 = null,
    /// "/" lists one level: sub-"folders" come in `prefixes`.
    delimiter: ?[]const u8 = null,
    start_after: ?[]const u8 = null,
    continuation: ?[]const u8 = null,
    /// 1..1000.
    max_keys: u16 = 1000,
};
pub const Entry = struct { key: []const u8, size: u64, etag: []const u8, last_modified: ?db.Time, storage_class: ?[]const u8 };
pub const ListPage = struct { entries: []const Entry, prefixes: []const []const u8, next: ?[]const u8 };

pub const Source = struct { key: []const u8, bucket: ?[]const u8 = null, version_id: ?[]const u8 = null };

pub const PresignMethod = enum { get, put, head, delete, upload_part };
pub const PresignOptions = struct {
    /// 1 s .. 7 days.
    expires: Duration = .fromMinutes(15),
    version_id: ?[]const u8 = null,
    /// PUT: signed, so the browser must send exactly this.
    content_type: ?[]const u8 = null,
    /// PUT: signed, so the browser must send exactly this length.
    content_length: ?u64 = null,
    /// GET: response-content-type / response-content-disposition overrides.
    response_content_type: ?[]const u8 = null,
    response_content_disposition: ?[]const u8 = null,
    /// upload_part.
    upload_id: ?[]const u8 = null,
    part_number: u16 = 0,
};

pub const Part = struct { number: u16, etag: []const u8 };

/// Calls on a bucket, with call options. Made by `Client.bucket` and `Client.with`.
pub const Bucket = struct {
    client: *Client,
    name: ?[]const u8,
    call: CallOptions = .{},

    pub fn bucketName(self: Bucket, c: anytype) Error![]const u8 {
        return self.name orelse self.client.default_bucket orelse
            return self.client.failOur(c, .invalid, "no_bucket", "no bucket: set Options.bucket, S3_BUCKET or use bucket(name)");
    }

    /// The same bucket with call options.
    pub fn with(self: Bucket, opts: CallOptions) Bucket {
        var b = self;
        b.call = opts;
        return b;
    }

    pub fn get(self: Bucket, c: anytype, key: []const u8, opts: GetOptions) Error!Object {
        return (try self.getInner(c, key, opts, false)) orelse unreachable;
    }

    pub fn optional(self: Bucket, c: anytype, key: []const u8, opts: GetOptions) Error!?Object {
        return self.getInner(c, key, opts, true);
    }

    fn getInner(self: Bucket, c: anytype, key: []const u8, opts: GetOptions, comptime absent_ok: bool) Error!?Object {
        const bucket = try self.bucketName(c);
        const cl = self.client;
        const limit = opts.max_bytes orelse cl.max_object_bytes;
        var hl: Headers = .{};
        try cl.getHeaders(c, &hl, opts);
        const query: []const Header = if (opts.version_id) |v| try c.arena.dupe(Header, &.{.{ "versionId", v }}) else &.{};
        const reply = cl.execute(c, .{
            .name = "GetObject",
            .method = .get,
            .bucket = bucket,
            .key = key,
            .query = query,
            .headers = hl.slice(),
            .want = .buffered,
            .max_bytes = limit,
            .allow_304 = true,
            .bound_bytes = limit,
        }, self.call) catch |err| {
            if (absent_ok and err == error.NotFound) {
                if (internal.lastError(c)) |d| if (d.class == .not_found) return null;
            }
            return err;
        };
        return .{ .meta = reply.meta, .body = reply.body };
    }

    /// Opens the object for streaming. `deinit` the `Download`.
    pub fn open(self: Bucket, c: anytype, key: []const u8, opts: GetOptions) Error!Download {
        return download_.open(self, c, key, opts);
    }

    /// Answers `req` from the object (S11).
    pub fn serve(self: Bucket, req: *anole.Request, res: *anole.Response, key: []const u8, opts: ServeOptions) Error!Meta {
        return download_.serve(self, req, res, key, opts);
    }

    pub fn head(self: Bucket, c: anytype, key: []const u8, opts: GetOptions) Error!Meta {
        const bucket = try self.bucketName(c);
        const cl = self.client;
        var hl: Headers = .{};
        try cl.getHeaders(c, &hl, opts);
        const query: []const Header = if (opts.version_id) |v| try c.arena.dupe(Header, &.{.{ "versionId", v }}) else &.{};
        const reply = try cl.execute(c, .{
            .name = "HeadObject",
            .method = .head,
            .bucket = bucket,
            .key = key,
            .query = query,
            .headers = hl.slice(),
            .want = .none,
            .allow_304 = true,
        }, self.call);
        return reply.meta;
    }

    pub fn headBucket(self: Bucket, c: anytype) Error!void {
        const bucket = try self.bucketName(c);
        _ = try self.client.execute(c, .{ .name = "HeadBucket", .method = .head, .bucket = bucket, .key = "", .want = .none }, self.call);
    }

    pub fn exists(self: Bucket, c: anytype, key: []const u8) Error!bool {
        _ = self.head(c, key, .{}) catch |err| {
            if (err == error.NotFound) if (internal.lastError(c)) |d| if (d.class == .not_found) return false;
            return err;
        };
        return true;
    }

    pub fn put(self: Bucket, c: anytype, key: []const u8, body: Body, opts: PutOptions) Error!Stored {
        return upload_.put(self, c, key, body, opts);
    }

    pub fn upload(self: Bucket, c: anytype, key: []const u8, opts: PutOptions) Error!*Upload {
        return upload_.open(self, c, key, opts, null);
    }

    pub fn delete(self: Bucket, c: anytype, key: []const u8, opts: DeleteOptions) Error!void {
        const bucket = try self.bucketName(c);
        const query: []const Header = if (opts.version_id) |v| try c.arena.dupe(Header, &.{.{ "versionId", v }}) else &.{};
        _ = try self.client.execute(c, .{
            .name = "DeleteObject",
            .method = .delete,
            .bucket = bucket,
            .key = key,
            .query = query,
            .want = .buffered,
            .max_bytes = 64 * 1024,
        }, self.call);
    }

    /// Deletes any number of keys, 1000 per request.
    pub fn deleteMany(self: Bucket, c: anytype, keys: []const []const u8) Error!DeleteResult {
        const bucket = try self.bucketName(c);
        const cl = self.client;
        var deleted: u32 = 0;
        var failed: std.ArrayList(Failure) = .empty;
        var i: usize = 0;
        while (i < keys.len) : (i += 1000) {
            const chunk = keys[i..@min(keys.len, i + 1000)];
            var body: std.Io.Writer.Allocating = .init(c.arena);
            const w = &body.writer;
            w.writeAll("<Delete><Quiet>true</Quiet>") catch return error.OutOfMemory;
            for (chunk) |k| {
                if (!endpoint.validKey(k)) return cl.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
                w.writeAll("<Object><Key>") catch return error.OutOfMemory;
                writeXmlText(w, k) catch return error.OutOfMemory;
                w.writeAll("</Key></Object>") catch return error.OutOfMemory;
            }
            w.writeAll("</Delete>") catch return error.OutOfMemory;
            var md5: [24]u8 = undefined;
            const md5_text = util.contentMd5(&md5, body.written());
            var hl: Headers = .{};
            hl.add("Content-MD5", try c.arena.dupe(u8, md5_text)) catch return error.OutOfMemory;
            hl.add("Content-Type", "application/xml") catch return error.OutOfMemory;
            const reply = try cl.execute(c, .{
                .name = "DeleteObjects",
                .method = .post,
                .bucket = bucket,
                .key = "",
                .query = &.{.{ "delete", "" }},
                .headers = hl.slice(),
                .body = body.written(),
                .has_body = true,
                .want = .buffered,
                .max_bytes = 8 * 1024 * 1024,
                .bound_bytes = body.written().len,
            }, self.call);
            const parsed = xml.parseDeleteResult(c.arena, reply.body) catch
                return cl.failOur(c, .other, "bad_response", "DeleteObjects answered something that is not XML");
            // With Quiet, only failures are listed; the rest were deleted.
            deleted += @as(u32, @intCast(chunk.len)) - @as(u32, @intCast(parsed.failures.len));
            try failed.appendSlice(c.arena, parsed.failures);
        }
        return .{ .deleted = deleted, .failed = failed.items };
    }

    /// One page of keys.
    pub fn list(self: Bucket, c: anytype, opts: ListOptions) Error!ListPage {
        const bucket = try self.bucketName(c);
        const cl = self.client;
        var q: [8]Header = undefined;
        var n: usize = 0;
        q[n] = .{ "list-type", "2" };
        n += 1;
        q[n] = .{ "encoding-type", "url" };
        n += 1;
        if (opts.prefix) |p| {
            q[n] = .{ "prefix", p };
            n += 1;
        }
        if (opts.delimiter) |p| {
            q[n] = .{ "delimiter", p };
            n += 1;
        }
        if (opts.start_after) |p| {
            q[n] = .{ "start-after", p };
            n += 1;
        }
        if (opts.continuation) |p| {
            q[n] = .{ "continuation-token", p };
            n += 1;
        }
        q[n] = .{ "max-keys", try std.fmt.allocPrint(c.arena, "{d}", .{std.math.clamp(opts.max_keys, 1, 1000)}) };
        n += 1;
        const reply = try cl.execute(c, .{
            .name = "ListObjectsV2",
            .method = .get,
            .bucket = bucket,
            .key = "",
            .query = q[0..n],
            .want = .buffered,
            .max_bytes = 32 * 1024 * 1024,
        }, self.call);
        const r = xml.parseListObjects(c.arena, reply.body, true) catch
            return cl.failOur(c, .other, "bad_response", "ListObjectsV2 answered something that is not XML");
        const entries = try c.arena.alloc(Entry, r.entries.len);
        for (r.entries, entries) |e, *out| out.* = .{
            .key = e.key,
            .size = e.size,
            .etag = e.etag,
            .last_modified = if (e.last_modified) |t| (db.Time.parse(t) catch null) else null,
            .storage_class = e.storage_class,
        };
        return .{ .entries = entries, .prefixes = r.prefixes, .next = if (r.truncated) r.next else null };
    }

    /// Pages on demand.
    pub fn iterate(self: Bucket, c: anytype, opts: ListOptions) Lister {
        _ = c;
        return .{ .bucket = self, .opts = opts };
    }

    pub fn copy(self: Bucket, c: anytype, from: Source, to_key: []const u8, opts: PutOptions) Error!Stored {
        const bucket = try self.bucketName(c);
        const cl = self.client;
        const src_bucket = from.bucket orelse bucket;
        if (!endpoint.validKey(from.key) or !endpoint.validKey(to_key)) return cl.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
        var hl: Headers = .{};
        var src: std.Io.Writer.Allocating = .init(c.arena);
        src.writer.writeByte('/') catch return error.OutOfMemory;
        sigv4.uriEncode(&src.writer, src_bucket, false) catch return error.OutOfMemory;
        src.writer.writeByte('/') catch return error.OutOfMemory;
        sigv4.uriEncode(&src.writer, from.key, true) catch return error.OutOfMemory;
        if (from.version_id) |v| {
            src.writer.writeAll("?versionId=") catch return error.OutOfMemory;
            sigv4.uriEncode(&src.writer, v, false) catch return error.OutOfMemory;
        }
        hl.add("x-amz-copy-source", src.written()) catch return error.OutOfMemory;
        hl.add("x-amz-metadata-directive", if (opts.replace_metadata) "REPLACE" else "COPY") catch return error.OutOfMemory;
        if (opts.replace_metadata) try cl.putHeaders(c, &hl, to_key, opts, true) else try cl.conditionalHeaders(&hl, opts);
        const reply = try cl.execute(c, .{
            .name = "CopyObject",
            .method = .put,
            .bucket = bucket,
            .key = to_key,
            .headers = hl.slice(),
            .has_body = true,
            .want = .buffered,
            .max_bytes = 64 * 1024,
        }, self.call);
        // S3 can start answering 200 and then fail: the error is in the body.
        if (xml.parseError(c.arena, reply.body)) |e| return cl.failCode(c, 500, if (e.code.len > 0) e.code else "InternalError", e.message, e.region);
        const etag = (xml.firstText(c.arena, reply.body, "ETag") catch null) orelse "";
        return .{ .etag = etag, .version_id = reply.meta.version_id };
    }

    /// A URL anyone can use for a while; no request is made.
    pub fn presign(self: Bucket, c: anytype, method: PresignMethod, key: []const u8, opts: PresignOptions) Error![]const u8 {
        const bucket = try self.bucketName(c);
        return self.client.presignUrl(c, bucket, method, key, opts);
    }

    /// For browsers uploading parts with presigned URLs.
    pub fn multipart(self: Bucket) Multipart {
        return .{ .bucket = self };
    }
};

fn writeXmlText(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(ch),
    };
}

/// ListObjectsV2, a page at a time.
pub const Lister = struct {
    bucket: Bucket,
    opts: ListOptions,
    page: ?ListPage = null,
    index: usize = 0,
    done: bool = false,

    pub fn next(self: *Lister, c: anytype) Error!?Entry {
        while (true) {
            if (self.done) return null;
            if (self.page) |p| {
                if (self.index < p.entries.len) {
                    defer self.index += 1;
                    return p.entries[self.index];
                }
                if (p.next == null) {
                    self.done = true;
                    return null;
                }
                self.opts.continuation = p.next;
            }
            self.page = try self.bucket.list(c, self.opts);
            self.index = 0;
        }
    }
};

/// For browsers uploading parts with presigned URLs.
pub const Multipart = struct {
    bucket: Bucket,

    /// CreateMultipartUpload; the upload id.
    pub fn create(self: Multipart, c: anytype, key: []const u8, opts: PutOptions) Error![]const u8 {
        return upload_.createMultipart(self.bucket, c, key, opts);
    }

    pub fn complete(self: Multipart, c: anytype, key: []const u8, upload_id: []const u8, parts: []const Part) Error!Stored {
        return upload_.completeMultipart(self.bucket, c, key, upload_id, parts);
    }

    pub fn abort(self: Multipart, c: anytype, key: []const u8, upload_id: []const u8) Error!void {
        return upload_.abortMultipart(self.bucket, c, key, upload_id);
    }
};

// ---------------------------------------------------------------------------
// The call machinery

/// The headers of one request while it is built.
pub const Headers = struct {
    items: [sigv4.max_headers - 6]Header = undefined,
    len: usize = 0,

    pub fn add(self: *Headers, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (self.len >= self.items.len) return error.TooManyHeaders;
        self.items[self.len] = .{ name, value };
        self.len += 1;
    }

    pub fn slice(self: *const Headers) []const Header {
        return self.items[0..self.len];
    }
};

pub const Want = enum { none, buffered, stream };

/// One request to the service.
pub const Op = struct {
    name: []const u8,
    method: fetch.Method,
    bucket: []const u8,
    key: []const u8,
    query: []const Header = &.{},
    headers: []const Header = &.{},
    body: []const u8 = "",
    has_body: bool = false,
    want: Want = .none,
    /// `buffered`: the largest body read.
    max_bytes: u64 = 0,
    allow_304: bool = false,
    /// Bytes this call moves, for its bound (G4).
    bound_bytes: u64 = 0,
};

pub const Reply = struct {
    meta: Meta,
    body: []const u8 = "",
    /// `stream`: the response, to read and `deinit`.
    resp: ?dusty.ClientResponse = null,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    label: []const u8,
    ep: endpoint.Endpoint,
    addressing: Addressing,
    region: []const u8,
    default_bucket: ?[]const u8,
    signer: sigv4.Signer,
    creds: credentials.Provider,
    anonymous: bool,
    http: *dusty.Client,
    payload_signing: Options.PayloadSigning,
    timeout: ?Duration,
    min_throughput: u64,
    part_size: u64,
    threshold: u64,
    concurrency: u8,
    upload_memory: u64,
    memory_used: std.atomic.Value(u64) = .init(0),
    max_object_bytes: u64,
    errors: db.ErrorMap,
    retry_on: bool,
    guard: internal.Guard,
    observer: db.Observer,
    readiness_on: bool,
    draining: std.atomic.Value(bool) = .init(false),
    /// Seconds to add to the clock (from a RequestTimeTooSkewed answer).
    clock_offset: std.atomic.Value(i64) = .init(0),
    started: bool = false,
    bytes_up: ?*observe.metrics.Counter = null,
    bytes_down: ?*observe.metrics.Counter = null,
    memory_gauge: ?*observe.metrics.Gauge = null,
    ready_mutex: std.Io.Mutex = .init,
    ready_at: ?std.Io.Clock.Timestamp = null,
    ready_ok: bool = false,
    /// Uploads in flight (so `drain` can wait for them).
    uploads_live: std.atomic.Value(u32) = .init(0),
    /// Wakes whoever waits for upload memory or room.
    bell: upload_.Bell = .{},

    /// `app.s3(options)` calls it; outside an app, `init` then `start`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        try validate(opts);
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = undefined;
        self.gpa = gpa;
        self.io = io;
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        const env = struct {
            fn get(o: Options, name: []const u8) ?[]const u8 {
                const v = db.env(o.environ, name) orelse return null;
                return if (v.len == 0) null else v;
            }
        }.get;

        self.label = try a.dupe(u8, opts.name orelse "s3");
        const region_hint = opts.region orelse env(opts, "AWS_REGION") orelse env(opts, "AWS_DEFAULT_REGION");
        const endpoint_text = opts.endpoint orelse env(opts, "AWS_ENDPOINT_URL_S3") orelse env(opts, "AWS_ENDPOINT_URL");
        if (endpoint_text) |t| {
            self.ep = endpoint.Endpoint.parse(a, t, opts.provider) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("s3 \"{s}\": the endpoint \"{s}\" is not an http(s) URL", .{ self.label, t });
                    return error.InvalidOptions;
                },
            };
        } else {
            self.ep = try endpoint.Endpoint.aws(a, region_hint orelse "us-east-1");
        }
        self.region = try a.dupe(u8, region_hint orelse self.ep.defaultRegion());
        self.addressing = opts.addressing;
        self.default_bucket = if (opts.bucket orelse env(opts, "S3_BUCKET")) |b| try a.dupe(u8, b) else null;
        if (self.default_bucket == null) log.warn("s3 \"{s}\": no bucket (Options.bucket or S3_BUCKET); calls need bucket(name)", .{self.label});
        self.signer = .init(self.region);
        self.payload_signing = opts.payload_signing;
        self.timeout = opts.timeout;
        self.min_throughput = @max(opts.min_throughput, 1);
        self.part_size = opts.part_size;
        self.threshold = @max(opts.multipart_threshold orelse opts.part_size, 1);
        self.concurrency = opts.concurrency;
        self.upload_memory = opts.upload_memory;
        self.memory_used = .init(0);
        self.max_object_bytes = opts.max_object_bytes;
        self.errors = opts.errors;
        self.retry_on = opts.retry != null;
        self.readiness_on = opts.readiness;
        self.draining = .init(false);
        self.clock_offset = .init(0);
        self.started = false;
        self.bytes_up = null;
        self.bytes_down = null;
        self.memory_gauge = null;
        self.ready_mutex = .init;
        self.ready_at = null;
        self.ready_ok = false;
        self.uploads_live = .init(0);
        self.bell = .{};
        self.guard = try .init(.s3, self.label, opts.breaker, opts.retry orelse .{ .attempts = 1 });
        errdefer self.guard.deinit();
        self.observer = .{ .system = .s3, .name = self.label };

        // The HTTP client: Anole's own bounds apply, never the client's.
        self.http = try gpa.create(dusty.Client);
        errdefer gpa.destroy(self.http);
        self.http.* = dusty.Client.init(gpa, io, .{
            .max_redirects = 0,
            .max_response_size = std.math.cast(usize, opts.max_object_bytes) orelse std.math.maxInt(usize),
            .max_idle_per_host = opts.max_idle_connections,
            .timeout = null,
            .http2 = false,
            .user_agent = "anole/" ++ anole.version,
            .tls = .{
                .ca = opts.tls.ca orelse .system,
                .client_certificate = opts.tls.client_certificate,
                .insecure_skip_verify = opts.tls.insecure_skip_verify,
            },
        });
        errdefer self.http.deinit();

        self.anonymous = opts.credentials == .anonymous;
        self.creds = .{
            .gpa = gpa,
            .io = io,
            .http = self.http,
            .label = self.label,
            .environ = opts.environ,
            .is_aws = self.ep.provider == .aws,
            .region = self.region,
            .anonymous = self.anonymous,
        };
        switch (opts.credentials) {
            .static => |s| try self.creds.setStatic(s.access_key_id, s.secret_access_key, s.session_token),
            else => {},
        }
        return self;
    }

    fn validate(o: Options) !void {
        const bad = struct {
            fn f(field: []const u8, why: []const u8) error{InvalidOptions} {
                log.err("invalid option s3.{s}: {s}", .{ field, why });
                return error.InvalidOptions;
            }
        }.f;
        if (o.part_size < 5 * 1024 * 1024 or o.part_size > 5 * 1024 * 1024 * 1024) return bad("part_size", "must be 5 MiB .. 5 GiB");
        if (o.concurrency < 1 or o.concurrency > 16) return bad("concurrency", "must be 1 .. 16");
        if (o.upload_memory < o.part_size) return bad("upload_memory", "must hold at least one part");
        if (o.credentials == .static) {
            const s = o.credentials.static;
            if (s.access_key_id.len == 0 or s.secret_access_key.len == 0) return bad("credentials", "access_key_id and secret_access_key are both needed");
        }
        if (o.retry) |r| try r.validate();
        if (o.breaker) |b| try b.validate();
    }

    /// Resolves credentials (the chain; fails the start with every source it
    /// tried when none has keys), starts the renewal task. `app` calls it.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        if (self.started) return;
        self.observer = try .init(.s3, self.label, registry, tracer);
        try self.guard.observe(self.gpa, registry);
        if (registry) |r| {
            const bytes = try r.counter("anole_s3_bytes_total", "Object bytes moved to and from the store.", &.{ "db", "direction" });
            self.bytes_up = bytes.with(&.{ self.label, "up" });
            self.bytes_down = bytes.with(&.{ self.label, "down" });
            self.memory_gauge = (try r.gauge("anole_s3_upload_memory_bytes", "Memory held by upload part buffers.", &.{"db"})).with(&.{self.label});
        }
        if (!self.anonymous and self.creds.current_ == null) {
            self.creds.resolve(util.nowSeconds(self.io)) catch |err| switch (err) {
                error.NoCredentials => {
                    log.err("s3 \"{s}\": no credentials ({s})", .{ self.label, self.creds.report.items });
                    return error.DatabaseUnavailable;
                },
                else => |e| return e,
            };
            self.creds.start();
        }
        if (health) |h| if (self.readiness_on) try h.addCheck(self.label, readyCheck, self);
        self.started = true;
    }

    /// No new uploads start; those in flight run to their end until
    /// `deadline`, then abort.
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        self.draining.store(true, .release);
        while (self.uploads_live.load(.acquire) > 0) {
            if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gt, deadline)) break;
            self.io.sleep(.fromMilliseconds(10), .awake) catch break;
        }
    }

    pub fn deinit(self: *Client) void {
        self.draining.store(true, .release);
        self.creds.stop.store(true, .release);
        self.creds.deinit();
        self.http.deinit();
        self.gpa.destroy(self.http);
        self.guard.deinit();
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn readyCheck(ctx: ?*anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.ready_mutex.lock(self.io) catch return false;
        defer self.ready_mutex.unlock(self.io);
        const now: std.Io.Clock.Timestamp = .now(self.io, .awake);
        if (self.ready_at) |at| if (at.durationTo(now).raw.nanoseconds < 5 * std.time.ns_per_s) return self.ready_ok;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var ctx_: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        self.ready_ok = if (self.default_bucket == null) true else if (self.with(.{ .timeout = .fromSeconds(2), .retry = false }).headBucket(&ctx_)) true else |_| false;
        self.ready_at = .now(self.io, .awake);
        return self.ready_ok;
    }

    /// The console's `/db` entry.
    pub fn consoleInfo(self: *Client, w: *std.Io.Writer) !void {
        try w.print("\"system\":\"s3\",\"name\":\"{s}\",\"target\":\"{s}://{s}:{d}\",\"pools\":[]", .{ self.label, if (self.ep.https) "https" else "http", self.ep.host, self.ep.port });
    }

    // ---- Views -----------------------------------------------------------

    /// Calls on another bucket of the same endpoint and credentials.
    pub fn bucket(self: *Client, name: []const u8) Bucket {
        return .{ .client = self, .name = name };
    }

    /// The default bucket with call options.
    pub fn with(self: *Client, opts: CallOptions) Bucket {
        return .{ .client = self, .name = null, .call = opts };
    }

    fn dflt(self: *Client) Bucket {
        return .{ .client = self, .name = null };
    }

    pub fn get(self: *Client, c: anytype, key: []const u8, opts: GetOptions) Error!Object {
        return self.dflt().get(c, key, opts);
    }
    pub fn optional(self: *Client, c: anytype, key: []const u8, opts: GetOptions) Error!?Object {
        return self.dflt().optional(c, key, opts);
    }
    pub fn open(self: *Client, c: anytype, key: []const u8, opts: GetOptions) Error!Download {
        return self.dflt().open(c, key, opts);
    }
    pub fn serve(self: *Client, req: *anole.Request, res: *anole.Response, key: []const u8, opts: ServeOptions) Error!Meta {
        return self.dflt().serve(req, res, key, opts);
    }
    pub fn head(self: *Client, c: anytype, key: []const u8, opts: GetOptions) Error!Meta {
        return self.dflt().head(c, key, opts);
    }
    pub fn exists(self: *Client, c: anytype, key: []const u8) Error!bool {
        return self.dflt().exists(c, key);
    }
    pub fn put(self: *Client, c: anytype, key: []const u8, body: Body, opts: PutOptions) Error!Stored {
        return self.dflt().put(c, key, body, opts);
    }
    pub fn upload(self: *Client, c: anytype, key: []const u8, opts: PutOptions) Error!*Upload {
        return self.dflt().upload(c, key, opts);
    }
    pub fn delete(self: *Client, c: anytype, key: []const u8, opts: DeleteOptions) Error!void {
        return self.dflt().delete(c, key, opts);
    }
    pub fn deleteMany(self: *Client, c: anytype, keys: []const []const u8) Error!DeleteResult {
        return self.dflt().deleteMany(c, keys);
    }
    pub fn list(self: *Client, c: anytype, opts: ListOptions) Error!ListPage {
        return self.dflt().list(c, opts);
    }
    pub fn iterate(self: *Client, c: anytype, opts: ListOptions) Lister {
        return self.dflt().iterate(c, opts);
    }
    pub fn copy(self: *Client, c: anytype, from: Source, to_key: []const u8, opts: PutOptions) Error!Stored {
        return self.dflt().copy(c, from, to_key, opts);
    }
    pub fn presign(self: *Client, c: anytype, method: PresignMethod, key: []const u8, opts: PresignOptions) Error![]const u8 {
        return self.dflt().presign(c, method, key, opts);
    }
    pub fn multipart(self: *Client) Multipart {
        return self.dflt().multipart();
    }

    // ---- Upload memory -----------------------------------------------------

    /// Takes `n` bytes of the upload memory; false when it is used up.
    pub fn takeMemory(self: *Client, n: u64) bool {
        var cur = self.memory_used.load(.acquire);
        while (true) {
            if (cur + n > self.upload_memory) return false;
            cur = self.memory_used.cmpxchgWeak(cur, cur + n, .acq_rel, .acquire) orelse {
                if (self.memory_gauge) |g| g.add(@intCast(n));
                return true;
            };
        }
    }

    pub fn giveMemory(self: *Client, n: u64) void {
        if (n == 0) return;
        _ = self.memory_used.fetchSub(n, .acq_rel);
        if (self.memory_gauge) |g| g.add(-@as(i64, @intCast(n)));
        self.bell.ring(self.io);
    }

    // ---- Errors ----------------------------------------------------------

    /// One of our own failures (no request was made).
    pub fn failOur(self: *Client, c: anytype, class: db.Class, code: []const u8, message: []const u8) Error {
        return internal.fail(c, self.errors, .{ .system = .s3, .class = class, .code = code, .message = message });
    }

    /// A failure the service answered with.
    pub fn failCode(self: *Client, c: anytype, status: u16, code: []const u8, message: []const u8, region: []const u8) Error {
        var buf: [512]u8 = undefined;
        const text = errors_.explain(&buf, code, message, region);
        return internal.fail(c, self.errors, .{
            .system = .s3,
            .class = errors_.classify(status, code),
            .code = if (code.len > 0) code else statusName(status),
            .message = text,
        });
    }

    fn statusName(status: u16) []const u8 {
        return switch (status) {
            404 => "NotFound",
            403 => "Forbidden",
            412 => "PreconditionFailed",
            304 => "NotModified",
            else => "HttpError",
        };
    }

    // ---- Requests --------------------------------------------------------

    /// The wall clock in seconds, corrected by what the service told us.
    pub fn nowSeconds(self: *Client) i64 {
        return util.nowSeconds(self.io) + self.clock_offset.load(.monotonic);
    }

    /// The bound of a call that moves `bytes`: `timeout + bytes / min_throughput`.
    pub fn boundFor(self: *Client, call: CallOptions, bytes: u64) ?Duration {
        const base = internal.callTimeout(call.timeout, self.timeout) orelse return null;
        const extra: Duration = .fromSeconds(@intCast(@min(bytes / self.min_throughput, 24 * 3600)));
        return .{ .nanoseconds = base.nanoseconds + extra.nanoseconds };
    }

    /// Runs `op` under the guard (breaker and retries), with one transparent
    /// retry after a clock-skew answer.
    pub fn execute(self: *Client, c: anytype, op: Op, call: CallOptions) Error!Reply {
        if (op.key.len > 0 and !endpoint.validKey(op.key)) return self.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
        const C = @TypeOf(c);
        const retry = call.retry orelse self.retry_on;
        const bound = self.boundFor(call, op.bound_bytes);
        const observed = self.observer.start(c);
        var skewed = false;
        const result: Error!Reply = while (true) {
            const r = internal.guarded(c, &self.guard, self.errors, retry, null, onceFn(C), .{ self, c, &op, bound });
            if (r) |ok| break ok else |err| {
                if (!skewed and err != error.Canceled) if (internal.lastError(c)) |d| if (std.mem.eql(u8, d.code, "RequestTimeTooSkewed")) {
                    skewed = true;
                    continue;
                };
                break err;
            }
        };
        observed.end(c, op.name, op.bucket, if (result) |_| null else |e| e);
        return result;
    }

    fn onceFn(comptime C: type) fn (*Client, C, *const Op, ?Duration) Error!Reply {
        return struct {
            fn run(self: *Client, c: C, op: *const Op, bound: ?Duration) Error!Reply {
                return internal.bounded(c, .s3, bound, attemptFn(C), .{ self, c, op }) catch |err| switch (err) {
                    error.Canceled => error.Canceled,
                    error.OutOfMemory => error.OutOfMemory,
                    error.GatewayTimeout => error.GatewayTimeout,
                    error.NotFound => error.NotFound,
                    error.Conflict => error.Conflict,
                    error.ServiceUnavailable => error.ServiceUnavailable,
                    error.Database => error.Database,
                    error.MissingColumn => error.MissingColumn,
                    error.BadRequest => error.BadRequest,
                    error.UnprocessableEntity => error.UnprocessableEntity,
                    else => self.failOur(c, .unavailable, "transport", @errorName(err)),
                };
            }
        }.run;
    }

    fn attemptFn(comptime C: type) fn (*Client, C, *const Op) Error!Reply {
        return struct {
            fn run(self: *Client, c: C, op: *const Op) Error!Reply {
                return self.attempt(c, op);
            }
        }.run;
    }

    /// Whether the request body is hashed (plain HTTP, or forced).
    fn payloadFor(self: *Client, op: *const Op) sigv4.PayloadHash {
        const hash_it = switch (self.payload_signing) {
            .signed => true,
            .unsigned => false,
            .auto => !self.ep.https,
        };
        if (!hash_it) return .unsigned;
        if (op.body.len == 0) return .empty;
        return sigv4.PayloadHash.of(op.body);
    }

    /// One request, signed and sent; the answer checked.
    fn attempt(self: *Client, c: anytype, op: *const Op) Error!Reply {
        const arena = c.arena;
        const target = endpoint.target(arena, self.ep, self.addressing, op.bucket, op.key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.failOur(c, .invalid, "invalid_key", "the endpoint and bucket do not make a URL"),
        };
        var hl: sigv4.HeaderList = .{};
        for (op.headers) |h| hl.add(h[0], h[1]) catch return self.failOur(c, .invalid, "request_too_long", "too many headers");
        if (!self.anonymous) {
            const snap = self.creds.acquire() orelse return self.failOur(c, .other, "no_credentials", "no credentials");
            defer self.creds.release(snap);
            self.signer.sign(snap.keys(), self.nowSeconds(), .{
                .method = @tagName(op.method),
                .host = target.host,
                .canonical_uri = target.uri,
                .query = op.query,
                .payload_hash = self.payloadFor(op),
            }, &hl) catch return self.failOur(c, .invalid, "request_too_long", "the request is too long to sign");
        }
        var url: std.Io.Writer.Allocating = .init(arena);
        url.writer.writeAll(target.url) catch return error.OutOfMemory;
        if (op.query.len > 0) {
            url.writer.writeByte('?') catch return error.OutOfMemory;
            sigv4.writeQuery(&url.writer, op.query) catch return error.OutOfMemory;
        }
        var st: fetch.HeaderStorage = .{};
        const headers = st.headers(hl.slice()) catch return self.failOur(c, .invalid, "request_too_long", "too many headers");
        var resp = self.http.fetch(url.written(), .{
            .method = op.method,
            .headers = &headers,
            .body = if (op.has_body or op.body.len > 0) op.body else null,
            .decompress = false,
            .max_redirects = 0,
            .stream = true,
            .timeout = .none,
            .retry = .off,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.failOur(c, .unavailable, "transport", @errorName(err)),
        };
        var keep = false;
        defer if (!keep) resp.deinit();
        if (self.bytes_up) |m| m.add(op.body.len);
        const status: u16 = @intFromEnum(resp.status());
        if (status >= 300 and !(status == 304 and op.allow_304)) {
            return self.errorAnswer(c, &resp, op, status);
        }
        const meta = try self.metaOf(c, &resp, status);
        switch (op.want) {
            .none => return .{ .meta = meta },
            .buffered => {
                var no_buf: [0]u8 = .{};
                var r = resp.reader(&no_buf) catch |err| return self.failOur(c, .unavailable, "transport", @errorName(err));
                const limit = std.math.cast(usize, op.max_bytes) orelse std.math.maxInt(usize);
                const bytes = r.interface.allocRemaining(arena, .limited(limit)) catch |err| switch (err) {
                    error.StreamTooLong => return self.failOur(c, .invalid, "object_too_large", "the object is larger than max_bytes; use open() to stream it"),
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    error.ReadFailed => return self.failOur(c, .unavailable, "transport", if (r.err) |e| @errorName(e) else "read failed"),
                };
                if (self.bytes_down) |m| m.add(bytes.len);
                return .{ .meta = meta, .body = bytes };
            },
            .stream => {
                keep = true;
                return .{ .meta = meta, .resp = resp };
            },
        }
    }

    /// An error status: read the XML, classify, record.
    fn errorAnswer(self: *Client, c: anytype, resp: *dusty.ClientResponse, op: *const Op, status: u16) Error {
        var body: []const u8 = "";
        if (op.method != .head) {
            var no_buf: [0]u8 = .{};
            if (resp.reader(&no_buf)) |rr| {
                var r = rr;
                body = r.interface.allocRemaining(c.arena, .limited(64 * 1024)) catch "";
            } else |_| {}
        }
        const hdrs = resp.headers();
        const parsed = xml.parseError(c.arena, body);
        const code = if (parsed) |p| p.code else "";
        // A clock that is off: remember by how much; the caller retries once.
        if (std.mem.eql(u8, code, "RequestTimeTooSkewed") or std.mem.eql(u8, code, "RequestExpired")) {
            if (hdrs.get("Date")) |d| if (util.parseHttpDate(d)) |server| {
                self.clock_offset.store(server - util.nowSeconds(self.io), .monotonic);
            };
        }
        var region: []const u8 = if (parsed) |p| p.region else "";
        if (hdrs.get("x-amz-bucket-region")) |r| region = c.arena.dupe(u8, r) catch region;
        const message = if (parsed) |p| p.message else "";
        return self.failCode(c, status, code, message, region);
    }

    /// The `Meta` of an answer, its strings copied into the call's arena.
    pub fn metaOf(self: *Client, c: anytype, resp: *dusty.ClientResponse, status: u16) Error!Meta {
        _ = self;
        const arena = c.arena;
        const h = resp.headers();
        var m: Meta = .{ .status = status, .not_modified = status == 304 };
        const dup = struct {
            fn f(a: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
                return if (v) |x| try a.dupe(u8, x) else null;
            }
        }.f;
        m.etag = (try dup(arena, h.get("ETag"))) orelse "";
        m.version_id = try dup(arena, h.get("x-amz-version-id"));
        m.content_type = try dup(arena, h.get("Content-Type"));
        m.cache_control = try dup(arena, h.get("Cache-Control"));
        m.content_disposition = try dup(arena, h.get("Content-Disposition"));
        m.content_encoding = try dup(arena, h.get("Content-Encoding"));
        m.storage_class = try dup(arena, h.get("x-amz-storage-class"));
        m.request_id = (try dup(arena, h.get("x-amz-request-id"))) orelse "";
        m.delete_marker = if (h.get("x-amz-delete-marker")) |v| std.mem.eql(u8, v, "true") else false;
        if (h.get("Last-Modified")) |lm| if (util.parseHttpDate(lm)) |s| {
            m.last_modified = db.Time.fromSeconds(s);
        };
        const cl: u64 = if (h.get("Content-Length")) |v| (std.fmt.parseInt(u64, v, 10) catch 0) else (resp.contentLength() orelse 0);
        m.content_length = cl;
        m.size = cl;
        if (h.get("Content-Range")) |cr| {
            // bytes 0-9/1234
            if (std.mem.indexOfScalar(u8, cr, '/')) |slash| m.size = std.fmt.parseInt(u64, cr[slash + 1 ..], 10) catch cl;
            if (std.mem.startsWith(u8, cr, "bytes ")) {
                const dash = std.mem.indexOfScalar(u8, cr, '-') orelse cr.len;
                m.range_start = std.fmt.parseInt(u64, cr["bytes ".len..dash], 10) catch 0;
            }
        }
        var meta_list: std.ArrayList(Header) = .empty;
        var it = h.iterator();
        while (it.next()) |e| {
            if (e.key.len > 11 and std.ascii.eqlIgnoreCase(e.key[0..11], "x-amz-meta-")) {
                const name = try std.ascii.allocLowerString(arena, e.key[11..]);
                try meta_list.append(arena, .{ name, try arena.dupe(u8, e.value) });
            }
        }
        m.metadata = meta_list.items;
        return m;
    }

    // ---- Header builders ---------------------------------------------------

    pub fn getHeaders(self: *Client, c: anytype, hl: *Headers, opts: GetOptions) Error!void {
        if (opts.range) |r| {
            const text = if (r.end) |e| try std.fmt.allocPrint(c.arena, "bytes={d}-{d}", .{ r.start, e }) else try std.fmt.allocPrint(c.arena, "bytes={d}-", .{r.start});
            hl.add("Range", text) catch return self.failOur(c, .invalid, "request_too_long", "too many headers");
        }
        if (opts.if_none_match) |v| hl.add("If-None-Match", v) catch return error.OutOfMemory;
        if (opts.if_match) |v| hl.add("If-Match", v) catch return error.OutOfMemory;
        if (opts.if_modified_since) |t| {
            var buf: [29]u8 = undefined;
            hl.add("If-Modified-Since", try c.arena.dupe(u8, util.formatHttpDate(&buf, t.toSeconds()))) catch return error.OutOfMemory;
        }
    }

    pub fn conditionalHeaders(self: *Client, hl: *Headers, opts: PutOptions) Error!void {
        _ = self;
        if (opts.if_absent) hl.add("If-None-Match", "*") catch return error.OutOfMemory;
        if (opts.if_match) |v| hl.add("If-Match", v) catch return error.OutOfMemory;
    }

    /// The headers a PUT (or an upload's CreateMultipartUpload) carries.
    pub fn putHeaders(self: *Client, c: anytype, hl: *Headers, key: []const u8, opts: PutOptions, conditional: bool) Error!void {
        hl.add("Content-Type", opts.content_type orelse contentTypeOf(key)) catch return error.OutOfMemory;
        if (opts.cache_control) |v| hl.add("Cache-Control", v) catch return error.OutOfMemory;
        if (opts.content_disposition) |v| hl.add("Content-Disposition", v) catch return error.OutOfMemory;
        if (opts.content_encoding) |v| hl.add("Content-Encoding", v) catch return error.OutOfMemory;
        if (opts.storage_class) |v| hl.add("x-amz-storage-class", v) catch return error.OutOfMemory;
        for (opts.metadata) |m| {
            for (m[1]) |ch| if (ch == '\r' or ch == '\n') return self.failOur(c, .invalid, "invalid_header", "a metadata value must not contain a line break");
            const name = try std.fmt.allocPrint(c.arena, "x-amz-meta-{s}", .{m[0]});
            hl.add(try std.ascii.allocLowerString(c.arena, name), m[1]) catch return error.OutOfMemory;
        }
        for (opts.headers) |h| hl.add(h[0], h[1]) catch return error.OutOfMemory;
        if (conditional) try self.conditionalHeaders(hl, opts);
    }

    // ---- Presigning --------------------------------------------------------

    pub fn presignUrl(self: *Client, c: anytype, bucket_name: []const u8, method: PresignMethod, key: []const u8, opts: PresignOptions) Error![]const u8 {
        if (!endpoint.validKey(key)) return self.failOur(c, .invalid, "invalid_key", "a key must be 1 to 1024 bytes of UTF-8");
        const secs: u64 = @intCast(@max(0, @divTrunc(opts.expires.nanoseconds, std.time.ns_per_s)));
        if (secs < 1 or secs > 7 * 24 * 3600) return self.failOur(c, .invalid, "invalid_expires", "expires must be 1 s .. 7 days");
        if (method == .upload_part and (opts.upload_id == null or opts.part_number < 1 or opts.part_number > 10000))
            return self.failOur(c, .invalid, "invalid_part", "upload_part needs an upload id and a part number 1..10000");
        const snap = self.creds.acquire() orelse return self.failOur(c, .other, "no_credentials", "no credentials to sign with");
        defer self.creds.release(snap);
        const target = endpoint.target(c.arena, self.ep, self.addressing, bucket_name, key) catch return error.OutOfMemory;

        var q: [6]Header = undefined;
        var n: usize = 0;
        if (opts.version_id) |v| {
            q[n] = .{ "versionId", v };
            n += 1;
        }
        if (method == .get) {
            if (opts.response_content_type) |v| {
                q[n] = .{ "response-content-type", v };
                n += 1;
            }
            if (opts.response_content_disposition) |v| {
                q[n] = .{ "response-content-disposition", v };
                n += 1;
            }
        }
        if (method == .upload_part) {
            q[n] = .{ "partNumber", try std.fmt.allocPrint(c.arena, "{d}", .{opts.part_number}) };
            n += 1;
            q[n] = .{ "uploadId", opts.upload_id.? };
            n += 1;
        }
        var extra: [2]Header = undefined;
        var ne: usize = 0;
        if (method == .put or method == .upload_part) {
            if (opts.content_type) |v| {
                extra[ne] = .{ "content-type", v };
                ne += 1;
            }
            if (opts.content_length) |l| {
                extra[ne] = .{ "content-length", try std.fmt.allocPrint(c.arena, "{d}", .{l}) };
                ne += 1;
            }
        }
        var out: std.Io.Writer.Allocating = .init(c.arena);
        out.writer.print("{s}?", .{target.url}) catch return error.OutOfMemory;
        self.signer.presign(snap.keys(), self.nowSeconds(), .{
            .method = switch (method) {
                .get => "GET",
                .put, .upload_part => "PUT",
                .head => "HEAD",
                .delete => "DELETE",
            },
            .host = target.host,
            .canonical_uri = target.uri,
            .query = q[0..n],
            .headers = extra[0..ne],
        }, @intCast(secs), &out.writer) catch return error.OutOfMemory;
        return out.written();
    }
};

fn contentTypeOf(key: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, key, '/')) |s| key[s + 1 ..] else key;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "application/octet-stream";
    const ct = dusty.ContentType.fromExtension(base[dot..]);
    if (ct == .unknown) return "application/octet-stream";
    return ct.toContentType();
}

test {
    _ = sigv4;
    _ = xml;
    _ = endpoint;
    _ = credentials;
    _ = errors_;
    _ = upload_;
    _ = download_;
    _ = testing;
    _ = @import("s3_test.zig");
}
