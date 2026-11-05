//! The static file cache (K7, #102; research/s2/tier2/k7-qsbr.md): the
//! bytes of small files served by `Static`, kept process-wide so a request
//! for one takes no read and no blocking-pool hop.
//!
//! - One per server, made by `prepareStatic` when a static mount exists,
//!   shared by its mounts. Keyed by the mount, the cleaned path and the
//!   encoding served (identity or a precompressed copy).
//! - A fixed table of atomic slots, two choices per key, read in a
//!   `qsbr.Domain` read section: no lock on an executor. A writer
//!   publishes with a cmpxchg and retires what it took out.
//! - Freshness: a hit only while the served file and the plain file are
//!   the ones the fill saw (inode, size, mtime and ctime in ns), checked by
//!   a stat of both per request, as viltrum (`http1/file_cache.v`
//!   `same_file`) and goose-http (`file.goose` L176-L280) do. Only for a
//!   path the cache already holds: a path it doesn't know goes to today's
//!   `Static.serve` with no stat of its own. The stat is of a file opened
//!   as today's open does it (`resolve_beneath` included): a file whose
//!   directory was moved out and linked back keeps its ids, and must not
//!   keep hitting.
//! - Filled at the end of today's `Static.serve` from the file its
//!   confined open chose, so which file is served, and every refusal, stay
//!   today's; the cache only remembers the bytes.
//! - No eviction: fills stop at `Options.bytes`, and `sweep`, from the
//!   server's trim loop, drops entries whose files changed or went away
//!   (lighttpd's `stat_cache_periodic_cleanup`, keyed on a stat).
//!
//! Linux on 64-bit only for now: the filesystem check needs `fstatfs`,
//! which Zig 0.17's std doesn't have. Elsewhere `create` makes nothing and
//! every request takes today's path.
const std = @import("std");
const builtin = @import("builtin");
const qsbr = @import("../qsbr.zig");
const exec_counter = @import("../exec_counter.zig");
const static = @import("static.zig");
const Static = static.Static;
const Precompressed = static.Precompressed;

pub const Options = struct {
    /// Bytes the cache may hold, process-wide: file contents plus each
    /// entry's path and header, as the allocator rounds them. Fills stop
    /// once it is used up. 0 turns the cache off.
    bytes: usize = 8 << 20,
    /// Files larger than this are never cached: they go out from the file
    /// as before.
    max_file: usize = 64 << 10,
};

/// Where the cache runs (see the file's doc). `StaticOptions.cache` and
/// `Options` are accepted everywhere and do nothing elsewhere.
pub const supported = builtin.os.tag == .linux and @sizeOf(usize) == 8;

/// How a hit stats its files: open, `statx` and close by syscalls on the
/// executor, or through the `Io` (a blocking-pool hop each on epoll).
/// Sub-A/B 1 of k7-qsbr.md picks one; the other goes.
pub const stat_via: enum { statx, io } = .statx;

/// A file younger than this (by ctime) is not cached: a rewrite within
/// the timestamp granularity of the filesystem (2 s on FAT) could keep
/// its size and times (git's "racy-git" problem).
const racy_ns: i96 = 2 * std.time.ns_per_s;

/// The bytes on disk a cached copy stands for. All of them must match.
/// No device number: `std.Io.File.Stat` has none, and a file reached on
/// another device through a swapped link would also need the same inode
/// number, size, mtime and ctime, which userspace can't set.
pub const FileId = struct {
    ino: u64,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,

    pub fn of(st: std.Io.File.Stat) FileId {
        return .{ .ino = @intCast(st.inode), .size = st.size, .mtime_ns = st.mtime.nanoseconds, .ctime_ns = st.ctime.nanoseconds };
    }

    fn eql(a: FileId, b: FileId) bool {
        return a.ino == b.ino and a.size == b.size and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

/// Why a fill was not kept.
pub const Skip = enum {
    /// `Options.bytes` used up.
    budget,
    /// Both of the key's slots hold other keys.
    table,
    /// The served or the plain file changed within the last 2 s.
    racy,
    /// Too many replaced entries not yet freed (`Domain.pending`).
    retire,
    /// Not on a local filesystem the cache knows (NFS, FUSE, SMB...).
    fs,
    /// The file changed while it was read.
    changed,
};

const Entry = struct {
    link: qsbr.Retired = .{ .destroy = destroyLink },
    cache: *StaticCache,
    owner: *const Static,
    /// Of `owner` and the plain path.
    hash: u64,
    /// 0: identity, else 1 + the `Precompressed`.
    encoding: u8,
    /// The served file and the plain file when the fill read them.
    id: FileId,
    plain_id: FileId,
    path_len: u16,
    /// The plain path, then the body.
    mem: []u8,
    /// What the entry counts against `Options.bytes`.
    charge: usize,

    fn path(e: *const Entry) []const u8 {
        return e.mem[0..e.path_len];
    }

    fn body(e: *const Entry) []const u8 {
        return e.mem[e.path_len..];
    }

    fn matches(e: *const Entry, owner: *const Static, hash: u64, encoding: u8, p: []const u8) bool {
        return e.hash == hash and e.owner == owner and e.encoding == encoding and std.mem.eql(u8, e.path(), p);
    }

    fn destroyLink(r: *qsbr.Retired) void {
        // SAFETY: every `Retired` this domain holds is an `Entry`'s `link`.
        const e: *Entry = @alignCast(@fieldParentPtr("link", r));
        e.cache.free(e);
    }
};

/// The key of an encoding (`Entry.encoding`).
pub fn encodingKey(encoding: ?Precompressed) u8 {
    return if (encoding) |e| 1 + @as(u8, @backingInt(e)) else 0;
}

fn encodingOf(key: u8) ?Precompressed {
    return if (key == 0) null else @fromBackingInt(@as(@typeInfo(Precompressed).@"enum".tag_type, @intCast(key - 1)));
}

/// What `stats` returns: the counters `/metrics` shows.
pub const Stats = struct {
    hits: u64,
    misses: u64,
    fills: u64,
    swept: u64,
    skipped: [std.enums.values(Skip).len]u64,
    /// Held now, entries not yet freed included.
    bytes: usize,
};

/// Test builds: knobs tests set.
pub const TestHooks = struct {
    /// Added to the real-time clock the racy check reads: tests write
    /// their files just before they ask for them.
    clock_offset_ns: i96 = 10 * std.time.ns_per_s,
};
pub var test_hooks: TestHooks = .{};

/// owner: the core `Server`, created by `prepareStatic` and destroyed by
/// its `deinit`, after every task that serves, and the trim loop that
/// sweeps, has been joined.
pub const StaticCache = struct {
    gpa: std.mem.Allocator,
    domain: qsbr.Domain,
    opts: Options,
    /// A power of two in length.
    slots: []std.atomic.Value(?*Entry),
    /// Charged by the entries, from the reservation in `fill` until their
    /// `destroy`.
    used: std.atomic.Value(usize) = .init(0),
    /// Where `sweep` goes on: the trim loop on executor 0 (and tests).
    sweep_cursor: std.atomic.Value(usize) = .init(0),
    /// Per request: a slot per executor.
    hits: exec_counter.PerExecutor(u64) = .init,
    misses: exec_counter.PerExecutor(u64) = .init,
    fills: std.atomic.Value(u64) = .init(0),
    swept: std.atomic.Value(u64) = .init(0),
    skipped: [std.enums.values(Skip).len]std.atomic.Value(u64) = @splat(.init(0)),
    /// Test builds: the stats a hit made.
    inline_stats: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {},
    /// Test builds: the files a fill read.
    fill_reads: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {},

    /// A cache for `statics` (those with `StaticOptions.cache`), or null
    /// when there is nothing to cache or the platform is not supported.
    /// Sets each one's `cache`. Never moves: its `domain` is registered.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, statics: []const *Static, opts: Options) !?*StaticCache {
        if (comptime !supported) return null;
        if (opts.bytes == 0) return null;
        for (statics) |s| {
            if (s.options.cache) break;
        } else return null;
        // One slot per 2 KiB of budget, 4,096 at the default (32 KiB).
        const n = std.math.ceilPowerOfTwoAssert(usize, std.math.clamp(opts.bytes / 2048, 1024, 1 << 20));
        const c = try gpa.create(StaticCache);
        errdefer gpa.destroy(c);
        const slots = try gpa.alloc(std.atomic.Value(?*Entry), n);
        @memset(slots, .init(null));
        // SAFETY: `domain.init` sets it up in place on the next line.
        c.* = .{ .gpa = gpa, .domain = undefined, .opts = opts, .slots = slots };
        c.domain.init(io, .{});
        for (statics) |s| {
            if (s.options.cache) s.cache = c;
        }
        return c;
    }

    /// Frees every entry, retired or held. Only when nothing serves.
    pub fn destroy(c: *StaticCache) void {
        c.domain.deinit();
        for (c.slots) |*slot| {
            if (slot.swap(null, .seq_cst)) |e| c.free(e);
        }
        std.debug.assert(c.used.load(.monotonic) == 0);
        c.gpa.free(c.slots);
        c.gpa.destroy(c);
    }

    fn free(c: *StaticCache, e: *Entry) void {
        const charge = e.charge;
        c.gpa.free(e.mem);
        c.gpa.destroy(e);
        std.debug.assert(c.used.load(.monotonic) >= charge);
        _ = c.used.fetchSub(charge, .monotonic);
    }

    pub fn stats(c: *const StaticCache) Stats {
        var s: Stats = .{
            .hits = c.hits.sum(),
            .misses = c.misses.sum(),
            .fills = c.fills.load(.monotonic),
            .swept = c.swept.load(.monotonic),
            // SAFETY: filled by the loop below.
            .skipped = undefined,
            .bytes = c.used.load(.monotonic),
        };
        for (&s.skipped, &c.skipped) |*out, *in| out.* = in.load(.monotonic);
        return s;
    }

    fn skip(c: *StaticCache, why: Skip) void {
        _ = c.skipped[@backingInt(why)].fetchAdd(1, .monotonic);
    }

    pub fn hash(owner: *const Static, path: []const u8) u64 {
        // SAFETY: the address only seeds the hash; `Static`s never move.
        return std.hash.Wyhash.hash(@intFromPtr(owner), path);
    }

    /// The key's two slots.
    fn positions(c: *const StaticCache, h: u64, encoding: u8) [2]usize {
        const mask = c.slots.len - 1;
        const k = h ^ (@as(u64, encoding) *% 0x9E3779B97F4A7C15);
        const a = k & mask;
        const b = (k >> 32 | 1) & mask;
        return .{ a, if (b == a) a ^ 1 else b };
    }

    /// Whether an entry is held for `path` in identity or one of `order`:
    /// only then does a request stat its files. Loads only.
    pub fn known(c: *StaticCache, io: std.Io, owner: *const Static, h: u64, path: []const u8, order: []const Precompressed) bool {
        const s = c.domain.enter(io);
        defer s.end();
        if (c.findIn(owner, h, encodingKey(null), path) != null) return true;
        for (order) |e| {
            if (c.findIn(owner, h, encodingKey(e), path) != null) return true;
        }
        return false;
    }

    const Found = struct { slot: usize, e: *Entry };

    /// Inside a read section.
    fn findIn(c: *StaticCache, owner: *const Static, h: u64, encoding: u8, path: []const u8) ?Found {
        for (c.positions(h, encoding)) |i| {
            const e = c.slots[i].load(.seq_cst) orelse continue;
            if (e.matches(owner, h, encoding, path)) return .{ .slot = i, .e = e };
        }
        return null;
    }

    /// The hit: whether the entry for the key is the one for `id` and
    /// `plain_id`, and then, when `out` is not empty, its body copied into
    /// `out` (`id.size` bytes, allocated before). Inside the read section
    /// only loads, compares and the copy (L5: no allocation under the
    /// lock-mode spin lock).
    pub fn copyOut(c: *StaticCache, io: std.Io, owner: *const Static, h: u64, path: []const u8, encoding: ?Precompressed, id: FileId, plain_id: FileId, out: []u8) bool {
        const s = c.domain.enter(io);
        defer s.end();
        const f = c.findIn(owner, h, encodingKey(encoding), path) orelse return false;
        if (!f.e.id.eql(id) or !f.e.plain_id.eql(plain_id)) return false;
        if (out.len > 0) @memcpy(out, f.e.body());
        return true;
    }

    pub fn countHit(c: *StaticCache, io: std.Io) void {
        c.hits.add(io, 1);
    }

    pub fn countMiss(c: *StaticCache, io: std.Io) void {
        c.misses.add(io, 1);
    }

    pub const Probe = union(enum) {
        file: std.Io.File.Stat,
        /// Nothing there (ENOENT, ENOTDIR): the next candidate.
        missing,
        /// Something else: an error, or not a regular file. Today's path
        /// answers it.
        other,
    };

    /// The stat of a hit: `path` in `dir`, opened as today's open does
    /// it (read-only; under `confine`, `resolve_beneath`, kernel-confined
    /// as zio's openat2 is), then stat'ed and closed. A file today's open
    /// refuses (no permission, a link or a directory out of `dir`) or that
    /// is not a regular file is `.missing`, as `Static.serve` takes it.
    pub fn statAt(c: *StaticCache, io: std.Io, dir: std.Io.Dir, path: []const u8, confine: bool) std.Io.Cancelable!Probe {
        if (builtin.is_test) _ = c.inline_stats.fetchAdd(1, .monotonic);
        return statFile(io, dir, path, confine);
    }

    fn statFile(io: std.Io, dir: std.Io.Dir, path: []const u8, confine: bool) std.Io.Cancelable!Probe {
        switch (stat_via) {
            .statx => if (comptime !supported) unreachable else return statLinux(dir, path, confine),
            // Confined only where the `Io` honours the flag (zio).
            .io => {
                const file = dir.openFile(io, path, .{ .resolve_beneath = confine }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.FileNotFound, error.NotDir, error.IsDir, error.AccessDenied, error.BadPathName, error.NameTooLong, error.SymLinkLoop => return .missing,
                    else => return .other,
                };
                defer file.close(io);
                const st = file.stat(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return .other,
                };
                return if (st.kind == .file) .{ .file = st } else .missing;
            },
        }
    }

    /// openat2 (`RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS`, zio's flags for
    /// a confined open), or openat, then statx of the fd and close: three
    /// syscalls on the executor. O_NONBLOCK so a FIFO can't hold it.
    fn statLinux(dir: std.Io.Dir, path: []const u8, confine: bool) Probe {
        const linux = std.os.linux;
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buf.len) return .other;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOCTTY = true, .NONBLOCK = true };
        const rc = if (confine) blk: {
            const how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = resolve_beneath | resolve_no_magiclinks };
            // SAFETY: the kernel reads the path and `how` during the call only.
            break :blk linux.syscall4(.openat2, @as(usize, @bitCast(@as(isize, dir.handle))), @intFromPtr(&buf), @intFromPtr(&how), @sizeOf(OpenHow));
        } else linux.openat(dir.handle, buf[0..path.len :0], flags, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // What `isMissing` in static.zig takes as no file (EXDEV: the
            // path left the directory).
            .NOENT, .NOTDIR, .ACCES, .XDEV, .LOOP, .NAMETOOLONG => return .missing,
            else => return .other,
        }
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        // SAFETY: filled by statx; read only on success.
        var stx: linux.Statx = undefined;
        const want: linux.STATX = .{ .TYPE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true };
        if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH | linux.AT.STATX_DONT_SYNC, want, &stx)) != .SUCCESS) return .other;
        if (@as(u32, @bitCast(stx.mask)) & @as(u32, @bitCast(want)) != @as(u32, @bitCast(want))) return .other;
        if (stx.mode & linux.S.IFMT != linux.S.IFREG) return .missing;
        return .{ .file = .{
            .inode = stx.ino,
            .nlink = stx.nlink,
            .size = stx.size,
            .permissions = .default_file,
            .kind = .file,
            .atime = null,
            .mtime = timestamp(stx.mtime),
            .ctime = timestamp(stx.ctime),
            .block_size = stx.blksize,
        } };
    }

    /// struct open_how (linux/openat2.h), as zio has it.
    const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
    const resolve_no_magiclinks: u64 = 0x02;
    const resolve_beneath: u64 = 0x08;

    fn timestamp(t: std.os.linux.statx_timestamp) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, t.sec) * std.time.ns_per_s + t.nsec };
    }

    /// The fill, at the end of today's serve: the file `file` (open, the
    /// served one, `st`) is read whole and kept under the key when every
    /// check passes. Returns a copy of its bytes in `arena` once read and
    /// checked (the request goes out from those, published or not), or
    /// null when it was not read (the request goes out from the file).
    pub fn fill(
        c: *StaticCache,
        io: std.Io,
        arena: std.mem.Allocator,
        owner: *const Static,
        path: []const u8,
        encoding: ?Precompressed,
        file: std.Io.File,
        st: std.Io.File.Stat,
        plain: std.Io.File.Stat,
    ) std.Io.Cancelable!?[]u8 {
        // The cheap checks first: a key that can't be kept is asked for
        // again on every request.
        if (st.size > c.opts.max_file or path.len > std.math.maxInt(u16)) return null;
        const size: usize = @intCast(st.size);
        const now = std.Io.Clock.real.now(io).nanoseconds + (if (builtin.is_test) test_hooks.clock_offset_ns else 0);
        if (now - st.ctime.nanoseconds < racy_ns or now - plain.ctime.nanoseconds < racy_ns) return c.skipped_(.racy);
        if (c.domain.pending() >= c.domain.max_retired / 2) return c.skipped_(.retire);
        const charge = charged(@sizeOf(Entry)) + charged(path.len + size);
        if (c.used.load(.monotonic) + charge > c.opts.bytes) return c.skipped_(.budget);
        const h = hash(owner, path);
        const key = encodingKey(encoding);
        const id: FileId = .of(st);
        const plain_id: FileId = .of(plain);
        // A hint: `publish` decides for a racing writer.
        switch (c.room(io, owner, h, key, path, id, plain_id)) {
            .held => return null,
            .full => return c.skipped_(.table),
            .free => {},
        }
        if (!localFs(file.handle)) return c.skipped_(.fs);
        if (c.used.fetchAdd(charge, .monotonic) + charge > c.opts.bytes) {
            _ = c.used.fetchSub(charge, .monotonic);
            return c.skipped_(.budget);
        }
        var reserved = true;
        defer if (reserved) {
            _ = c.used.fetchSub(charge, .monotonic);
        };

        if (builtin.is_test) _ = c.fill_reads.fetchAdd(1, .monotonic);
        const out = arena.alloc(u8, size) catch return null;
        const n = file.readPositionalAll(io, out, 0) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        const after = file.stat(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        if (n != size or !FileId.of(after).eql(id)) {
            c.skip(.changed);
            return null;
        }

        const mem = c.gpa.alloc(u8, path.len + size) catch return out;
        const e = c.gpa.create(Entry) catch {
            c.gpa.free(mem);
            return out;
        };
        @memcpy(mem[0..path.len], path);
        @memcpy(mem[path.len..], out);
        e.* = .{
            .cache = c,
            .owner = owner,
            .hash = h,
            .encoding = key,
            .id = id,
            .plain_id = plain_id,
            .path_len = @intCast(path.len),
            .mem = mem,
            .charge = charge,
        };
        // The entry holds the reservation now: its `destroy` gives it back.
        reserved = false;
        c.publish(io, e);
        return out;
    }

    /// Whether a fill of the key has a slot to go in: the same bytes held
    /// already, both slots taken by other keys, or room. Loads only.
    fn room(c: *StaticCache, io: std.Io, owner: *const Static, h: u64, key: u8, path: []const u8, id: FileId, plain_id: FileId) enum { held, full, free } {
        const s = c.domain.enter(io);
        defer s.end();
        if (c.findIn(owner, h, key, path)) |f| return if (f.e.id.eql(id) and f.e.plain_id.eql(plain_id)) .held else .free;
        for (c.positions(h, key)) |i| {
            if (c.slots[i].load(.seq_cst) == null) return .free;
        }
        return .full;
    }

    /// What an allocation of `len` bytes takes from the release allocator
    /// (smp_allocator: power-of-two slots up to 32 KiB, whole pages above).
    fn charged(len: usize) usize {
        if (len <= 32 << 10) return std.math.ceilPowerOfTwoAssert(usize, @max(len, 8));
        return std.mem.alignForward(usize, len, std.heap.page_size_min);
    }

    fn skipped_(c: *StaticCache, why: Skip) ?[]u8 {
        c.skip(why);
        return null;
    }

    /// k7-qsbr.md §5, in one read section (nothing in it can be freed,
    /// so no ABA): replace the key's entry, else take the first empty of
    /// its two slots in fixed order, rescanning once; then take out a copy
    /// a racing writer put in the other slot (seq_cst store, then load, on
    /// both sides: at least one of two racers sees the other). Retires and
    /// frees after `end` (`retire` takes the domain's lock; L5).
    fn publish(c: *StaticCache, io: std.Io, new: *Entry) void {
        const at = c.positions(new.hash, new.encoding);
        var old: ?*Entry = null;
        var dup: ?*Entry = null;
        const Outcome = enum { published, current, full };
        const outcome: Outcome = blk: {
            const s = c.domain.enter(io);
            defer s.end();
            const slot: usize = publish: for (0..2) |_| {
                if (c.findIn(new.owner, new.hash, new.encoding, new.path())) |f| {
                    // Another fill of the same bytes came first.
                    if (f.e.id.eql(new.id) and f.e.plain_id.eql(new.plain_id)) break :blk .current;
                    if (c.slots[f.slot].cmpxchgStrong(f.e, new, .seq_cst, .seq_cst) == null) {
                        old = f.e;
                        break :publish f.slot;
                    }
                    continue;
                }
                for (at) |i| {
                    if (c.slots[i].cmpxchgStrong(null, new, .seq_cst, .seq_cst) == null) break :publish i;
                }
            } else break :blk .full;
            const other = if (slot == at[0]) at[1] else at[0];
            if (c.slots[other].load(.seq_cst)) |e| {
                if (e.matches(new.owner, new.hash, new.encoding, new.path()) and
                    c.slots[other].cmpxchgStrong(e, null, .seq_cst, .seq_cst) == null) dup = e;
            }
            break :blk .published;
        };
        switch (outcome) {
            .published => _ = c.fills.fetchAdd(1, .monotonic),
            .current => c.free(new),
            .full => {
                c.skip(.table);
                c.free(new);
            },
        }
        if (old) |e| c.domain.retire(&e.link);
        if (dup) |e| c.domain.retire(&e.link);
    }

    /// Drops the entries, up to `max` of them from where the last call
    /// stopped, whose served or plain file changed or went away, so names
    /// no longer asked for (content-hashed assets after a deploy) give
    /// their bytes back. The trim loop on executor 0 runs it every 5 s;
    /// it stats as a hit does (`statAt`), so it also drops an entry whose
    /// file today's open would refuse.
    pub fn sweep(c: *StaticCache, io: std.Io, max: usize) std.Io.Cancelable!void {
        var checked: usize = 0;
        var scanned: usize = 0;
        var buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        while (checked < max and scanned < c.slots.len) : (scanned += 1) {
            const i = c.sweep_cursor.load(.monotonic);
            c.sweep_cursor.store((i + 1) & (c.slots.len - 1), .monotonic);
            const Copy = struct { e: *Entry, owner: *const Static, encoding: u8, id: FileId, plain_id: FileId, len: usize };
            const copy: Copy = blk: {
                const s = c.domain.enter(io);
                defer s.end();
                const e = c.slots[i].load(.seq_cst) orelse continue;
                const p = e.path();
                @memcpy(buf[0..p.len], p);
                break :blk .{ .e = e, .owner = e.owner, .encoding = e.encoding, .id = e.id, .plain_id = e.plain_id, .len = p.len };
            };
            checked += 1;
            const plain_path = buf[0..copy.len];
            const fresh = blk: {
                const confine = copy.owner.options.resolve_beneath;
                if (!try sameFile(io, copy.owner.dir, plain_path, confine, copy.plain_id)) break :blk false;
                const enc = encodingOf(copy.encoding) orelse break :blk true;
                const ext = enc.extension();
                @memcpy(buf[copy.len..][0..ext.len], ext);
                break :blk try sameFile(io, copy.owner.dir, buf[0 .. copy.len + ext.len], confine, copy.id);
            };
            if (fresh) continue;
            if (c.domain.pending() >= c.domain.max_retired / 2) continue;
            const removed = blk: {
                const s = c.domain.enter(io);
                defer s.end();
                // Still the entry the stats were for: one freed and filled
                // again at the same address meanwhile has other ids.
                const cur = c.slots[i].load(.seq_cst) orelse break :blk false;
                if (cur != copy.e or !cur.id.eql(copy.id) or !cur.plain_id.eql(copy.plain_id)) break :blk false;
                break :blk c.slots[i].cmpxchgStrong(cur, null, .seq_cst, .seq_cst) == null;
            };
            if (removed) {
                _ = c.swept.fetchAdd(1, .monotonic);
                c.domain.retire(&copy.e.link);
            }
        }
    }

    fn sameFile(io: std.Io, dir: std.Io.Dir, path: []const u8, confine: bool, id: FileId) std.Io.Cancelable!bool {
        return switch (try statFile(io, dir, path, confine)) {
            .file => |st| FileId.of(st).eql(id),
            .missing, .other => false,
        };
    }

    /// Test builds: puts a second copy of the key's entry in its other
    /// slot, as two fills racing on two executors can, charged like any.
    pub fn testDuplicate(c: *StaticCache, owner: *const Static, path: []const u8, encoding: ?Precompressed) !void {
        const h = hash(owner, path);
        const key = encodingKey(encoding);
        const f = c.findIn(owner, h, key, path) orelse return error.NotCached;
        const at = c.positions(h, key);
        const other = if (f.slot == at[0]) at[1] else at[0];
        if (c.slots[other].load(.seq_cst) != null) return error.SlotTaken;
        const e = try c.gpa.create(Entry);
        e.* = f.e.*;
        e.link = .{ .destroy = Entry.destroyLink };
        e.mem = try c.gpa.dupe(u8, f.e.mem);
        _ = c.used.fetchAdd(e.charge, .monotonic);
        c.slots[other].store(e, .seq_cst);
    }

    /// Test builds: fills the key's empty slots with entries of another
    /// key, so its fill finds no room.
    pub fn testOccupy(c: *StaticCache, owner: *const Static, path: []const u8, encoding: ?Precompressed) !void {
        const h = hash(owner, path);
        const key = encodingKey(encoding);
        const none: FileId = .{ .ino = 0, .size = 0, .mtime_ns = 0, .ctime_ns = 0 };
        for (c.positions(h, key)) |i| {
            if (c.slots[i].load(.seq_cst) != null) continue;
            const mem = try c.gpa.dupe(u8, "occupied");
            const e = try c.gpa.create(Entry);
            e.* = .{ .cache = c, .owner = owner, .hash = h +% 1, .encoding = key, .id = none, .plain_id = none, .path_len = @intCast(mem.len), .mem = mem, .charge = charged(@sizeOf(Entry)) + charged(mem.len) };
            _ = c.used.fetchAdd(e.charge, .monotonic);
            c.slots[i].store(e, .seq_cst);
        }
    }

    /// Test builds: how many entries the table holds.
    pub fn testCount(c: *StaticCache) usize {
        var n: usize = 0;
        for (c.slots) |*slot| {
            if (slot.load(.seq_cst) != null) n += 1;
        }
        return n;
    }
};

/// Whether the open file is on a local filesystem the cache trusts with a
/// stat on an executor: an allowlist of `f_type`s (include/uapi/linux/
/// magic.h; OpenZFS's ZFS_SUPER_MAGIC), so anything unknown (NFS, FUSE,
/// CIFS, Ceph, 9p) is refused. Checked at every fill, so a filesystem
/// mounted below a static root counts too.
fn localFs(fd: std.posix.fd_t) bool {
    if (comptime !supported) return false else return localFsLinux(fd);
}

fn localFsLinux(fd: std.posix.fd_t) bool {
    const linux = std.os.linux;
    // struct statfs on x86_64 and aarch64: 120 bytes, f_type the leading long.
    var buf: [128]u8 align(8) = undefined;
    // SAFETY: the kernel writes at most 120 bytes to `buf`.
    const rc = linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&buf));
    if (linux.errno(rc) != .SUCCESS) return false;
    const f_type: u32 = @truncate(@as(u64, @bitCast(std.mem.bytesToValue(i64, buf[0..8]))));
    return switch (f_type) {
        0xEF53, // ext2/3/4
        0x58465342, // xfs
        0x9123683E, // btrfs
        0x01021994, // tmpfs
        0x794c7630, // overlayfs
        0xF2F52010, // f2fs
        0x2fc12fc1, // zfs
        0xca451a4e, // bcachefs
        0x73717368, // squashfs
        0xE0F5E1E2, // erofs
        => true,
        else => false,
    };
}
