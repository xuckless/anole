//! What Anole's caches share (`anole.db`'s query cache and
//! `ResponseCache`): a store per executor, bounded in entries and bytes
//! and evicted least recently used first, entries that expire, and
//! invalidation that every executor sees at once.
//!
//! Each executor keeps its own store, which only tasks on that executor
//! touch: Anole runs zio pinned, so they are one OS thread, and there is
//! no lock. What one executor has cached the others do not see; each
//! fills its own. Invalidation is shared: `Generations` are atomics every
//! executor reads, and an entry is served only while the generations it
//! was filled under are current, so an invalidation reaches every
//! executor's entries at once, those still being filled included.
const std = @import("std");
const dusty = @import("dusty");
const observe = @import("../observe/root.zig");
const placement = dusty.placement;

const Allocator = std.mem.Allocator;
const Counter = std.atomic.Value(u64);

/// The awake clock in nanoseconds: what expiry is measured on.
pub fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Counters an invalidation bumps, shared by every executor: one for
/// everything, one per tag (hashed into a slot) and one per key (hashed
/// into a slot). Two tags or keys that share a slot invalidate each
/// other, which costs a refill and never serves stale data.
pub const Generations = struct {
    all: Counter = .init(0),
    tags: [tag_slots]Counter = @splat(.init(0)),
    keys: [key_slots]Counter = @splat(.init(0)),

    pub const tag_slots = 256;
    pub const key_slots = 1024;
    /// No tag.
    pub const untagged: u16 = std.math.maxInt(u16);

    pub fn tagSlot(tag: ?[]const u8) u16 {
        const t = tag orelse return untagged;
        return @intCast(std.hash.Wyhash.hash(0x7a67, t) % tag_slots);
    }

    pub fn keySlot(hash: u64) u16 {
        return @intCast(hash % key_slots);
    }

    /// The generations an entry is filled under: taken before the work
    /// that fills it starts, so an invalidation during that work leaves
    /// the entry stale from the start.
    pub fn stamp(self: *const Generations, tag_slot: u16, key_slot: u16) Stamp {
        return .{
            .all = self.all.load(.acquire),
            .tag = if (tag_slot == untagged) 0 else self.tags[tag_slot].load(.acquire),
            .key = self.keys[key_slot].load(.acquire),
            .tag_slot = tag_slot,
            .key_slot = key_slot,
        };
    }

    /// Whether nothing `s` covers was invalidated since it was taken.
    pub fn fresh(self: *const Generations, s: Stamp) bool {
        if (self.all.load(.acquire) != s.all) return false;
        if (s.tag_slot != untagged and self.tags[s.tag_slot].load(.acquire) != s.tag) return false;
        return self.keys[s.key_slot].load(.acquire) == s.key;
    }

    pub fn invalidateAll(self: *Generations) void {
        _ = self.all.fetchAdd(1, .release);
    }

    pub fn invalidateTag(self: *Generations, tag: []const u8) void {
        _ = self.tags[tagSlot(tag)].fetchAdd(1, .release);
    }

    pub fn invalidateKey(self: *Generations, hash: u64) void {
        _ = self.keys[keySlot(hash)].fetchAdd(1, .release);
    }
};

pub const Stamp = struct {
    all: u64,
    tag: u64,
    key: u64,
    tag_slot: u16,
    key_slot: u16,
};

/// One executor's counters. Only its own executor writes them (a load
/// and a store, no locked instruction); `Totals` adds them up from any
/// thread. `Store.count` bumps them, and the registry's series too when
/// the cache reports to one.
pub const Stats = struct {
    /// Served from the store.
    hits: Counter = .init(0),
    /// Looked up and not there (or stale, or expired).
    misses: Counter = .init(0),
    /// Calls that joined one already in flight (`anole.db`'s coalescing).
    coalesced: Counter = .init(0),
    /// Entries put in the store.
    stores: Counter = .init(0),
    /// Entries pushed out to make room (not those that expired or were
    /// invalidated).
    evictions: Counter = .init(0),
    entries: Counter = .init(0),
    bytes: Counter = .init(0),

    pub fn bump(counter: *Counter) void {
        counter.store(counter.load(.monotonic) +% 1, .monotonic);
    }

    fn set(counter: *Counter, v: usize) void {
        counter.store(v, .monotonic);
    }
};

/// Every executor's `Stats`, added up.
/// A cache's counters, added up over its executors (`stats`): hits,
/// misses, requests that waited on another's fill (`coalesced`), entries
/// stored and evicted, and what it holds now (`entries`, `bytes`).
pub const Totals = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    coalesced: u64 = 0,
    stores: u64 = 0,
    evictions: u64 = 0,
    entries: u64 = 0,
    bytes: u64 = 0,

    /// Adds one executor's counters.
    pub fn add(self: *Totals, s: *const Stats) void {
        inline for (@typeInfo(Totals).@"struct".field_names) |name| @field(self, name) += @field(s, name).load(.monotonic);
    }
};

/// One executor's entries: a hash map by key, and a list from most to
/// least recently used.
pub const Store = struct {
    gpa: Allocator,
    map: std.StringHashMapUnmanaged(*Entry) = .empty,
    lru: std.DoublyLinkedList = .{},
    bytes: usize = 0,
    max_entries: usize,
    max_bytes: usize,
    stats: Stats = .{},
    /// The cache's series, once it reports to a registry.
    metrics: ?*const Metrics = null,

    /// One allocation: this header, the key, then the value, aligned.
    pub const Entry = struct {
        node: std.DoublyLinkedList.Node = .{},
        key: []const u8,
        /// On the awake clock (`now`).
        expires: i96,
        stamp: Stamp,
        /// The user's mark (the response cache tells responses from the
        /// markers that name a route's `Vary` headers).
        kind: u8 = 0,
        alignment: std.mem.Alignment,
        size: usize,
        value_offset: usize,
        value_len: usize,

        pub fn value(self: *Entry) []u8 {
            const base: [*]u8 = @ptrCast(self);
            return base[self.value_offset..][0..self.value_len];
        }

        /// The value as a `T` laid at its start.
        pub fn as(self: *Entry, comptime T: type) *T {
            return @ptrCast(@alignCast(self.value().ptr));
        }

        fn fromNode(node: *std.DoublyLinkedList.Node) *Entry {
            return @alignCast(@fieldParentPtr("node", node));
        }
    };

    pub fn init(gpa: Allocator, max_entries: usize, max_bytes: usize) Store {
        return .{ .gpa = gpa, .max_entries = max_entries, .max_bytes = max_bytes };
    }

    pub const Event = enum { hit, miss, coalesced };

    /// Counts a lookup's outcome.
    pub fn count(self: *Store, event: Event) void {
        switch (event) {
            .hit => Stats.bump(&self.stats.hits),
            .miss => Stats.bump(&self.stats.misses),
            .coalesced => Stats.bump(&self.stats.coalesced),
        }
        const m = self.metrics orelse return;
        switch (event) {
            .hit => m.hits.inc(),
            .miss => m.misses.inc(),
            .coalesced => m.coalesced.inc(),
        }
    }

    pub fn deinit(self: *Store) void {
        while (self.lru.popFirst()) |node| self.free(Entry.fromNode(node));
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// The entry for `key` that is neither expired nor invalidated, now
    /// the most recently used; one that is goes, and the lookup misses.
    /// Counts neither: the caller knows what a lookup was for.
    pub fn get(self: *Store, key: []const u8, at: i96, gens: *const Generations) ?*Entry {
        const entry = self.map.get(key) orelse return null;
        if (at >= entry.expires or !gens.fresh(entry.stamp)) {
            self.remove(entry);
            return null;
        }
        if (self.lru.first != &entry.node) {
            self.lru.remove(&entry.node);
            self.lru.prepend(&entry.node);
        }
        return entry;
    }

    /// An entry for `key` with room for `len` bytes of value aligned to
    /// `alignment`, not in the store yet: fill `value()`, then `insert`
    /// it (or `discard` it). Null when it would not fit in the store at
    /// all.
    pub fn create(self: *Store, key: []const u8, len: usize, alignment: std.mem.Alignment, expires: i96, stamp: Stamp) ?*Entry {
        const a = std.mem.Alignment.max(.of(Entry), alignment);
        const key_offset = @sizeOf(Entry);
        const value_offset = alignment.forward(key_offset + key.len);
        const size = std.math.add(usize, value_offset, len) catch return null;
        if (size > self.max_bytes or self.max_entries == 0) return null;
        const memory = self.gpa.rawAlloc(size, a, @returnAddress()) orelse return null;
        const entry: *Entry = @ptrCast(@alignCast(memory));
        @memcpy(memory[key_offset..][0..key.len], key);
        entry.* = .{
            .key = memory[key_offset..][0..key.len],
            .expires = expires,
            .stamp = stamp,
            .alignment = a,
            .size = size,
            .value_offset = value_offset,
            .value_len = len,
        };
        return entry;
    }

    /// Frees an entry `create` made that was never inserted.
    pub fn discard(self: *Store, entry: *Entry) void {
        self.free(entry);
    }

    /// Puts `entry` in, in place of any entry of its key, then evicts the
    /// least recently used until the store is within its bounds.
    pub fn insert(self: *Store, entry: *Entry) void {
        const slot = self.map.getOrPut(self.gpa, entry.key) catch return self.free(entry);
        if (slot.found_existing) {
            const old = slot.value_ptr.*;
            self.lru.remove(&old.node);
            self.bytes -= old.size;
            self.free(old);
        }
        // The key now points into the new entry.
        slot.key_ptr.* = entry.key;
        slot.value_ptr.* = entry;
        self.lru.prepend(&entry.node);
        self.bytes += entry.size;
        Stats.bump(&self.stats.stores);
        if (self.metrics) |m| m.stores.inc();
        while (self.map.count() > self.max_entries or self.bytes > self.max_bytes) {
            const last = Entry.fromNode(self.lru.last.?);
            self.remove(last);
            Stats.bump(&self.stats.evictions);
            if (self.metrics) |m| m.evictions.inc();
        }
        self.gauge();
    }

    /// Takes `entry` out and frees it.
    pub fn remove(self: *Store, entry: *Entry) void {
        _ = self.map.remove(entry.key);
        self.lru.remove(&entry.node);
        self.bytes -= entry.size;
        self.free(entry);
        self.gauge();
    }

    /// Empties the store.
    pub fn clear(self: *Store) void {
        while (self.lru.popFirst()) |node| self.free(Entry.fromNode(node));
        self.map.clearRetainingCapacity();
        self.bytes = 0;
        self.gauge();
    }

    fn free(self: *Store, entry: *Entry) void {
        const base: [*]u8 = @ptrCast(entry);
        self.gpa.rawFree(base[0..entry.size], entry.alignment, @returnAddress());
    }

    /// Brings the entry and byte counts up to date, the registry's
    /// gauges by the change.
    fn gauge(self: *Store) void {
        const entries: u64 = self.map.count();
        const was_entries = self.stats.entries.load(.monotonic);
        const was_bytes = self.stats.bytes.load(.monotonic);
        Stats.set(&self.stats.entries, entries);
        Stats.set(&self.stats.bytes, self.bytes);
        if (self.metrics) |m| {
            m.entries.add(@as(i64, @intCast(entries)) - @as(i64, @intCast(was_entries)));
            m.bytes.add(@as(i64, @intCast(self.bytes)) - @as(i64, @intCast(was_bytes)));
        }
    }
};

/// Part `index` of `total` split over `parts` executors, at least 1
/// (`anole.db.split`).
pub fn share(total: usize, parts: usize, index: usize) usize {
    if (total <= parts) return 1;
    return total / parts + @intFromBool(index < total % parts);
}

/// One `T` per executor of a runtime, for state only that executor's
/// tasks touch. Off the executors (`std.Io.Threaded`, a thread of zio's
/// blocking pool) there is none: callers then go without.
pub fn PerExecutor(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,

        pub fn init(gpa: Allocator, io: std.Io) Allocator.Error!Self {
            return .{ .items = try gpa.alloc(T, placement.executorCount(io) orelse 1) };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.items);
            self.* = undefined;
        }

        /// The calling task's executor's, or null off zio's executors.
        pub fn get(self: *const Self, io: std.Io) ?*T {
            const i = placement.currentExecutor(io) orelse return null;
            if (i >= self.items.len) return null;
            return &self.items[i];
        }
    };
}

/// A cache's series in a metrics registry, labelled `kind` ("db" or
/// "http") and `name`: `anole_cache_hits_total`, `anole_cache_misses_total`,
/// `anole_cache_coalesced_total`, `anole_cache_stores_total`,
/// `anole_cache_evictions_total`, and the gauges `anole_cache_entries` and
/// `anole_cache_bytes`. Like the HTTP metrics, they are shared counters,
/// bumped only when the app has a registry.
pub const Metrics = struct {
    hits: *observe.metrics.Counter,
    misses: *observe.metrics.Counter,
    coalesced: *observe.metrics.Counter,
    stores: *observe.metrics.Counter,
    evictions: *observe.metrics.Counter,
    entries: *observe.metrics.Gauge,
    bytes: *observe.metrics.Gauge,

    const labels: []const []const u8 = &.{ "kind", "name" };

    /// `name` must outlive the registry.
    pub fn init(registry: *observe.metrics.Registry, kind: []const u8, name: []const u8) !Metrics {
        const values: []const []const u8 = &.{ kind, name };
        return .{
            .hits = (try registry.counter("anole_cache_hits_total", "Lookups served from a cache.", labels)).with(values),
            .misses = (try registry.counter("anole_cache_misses_total", "Lookups a cache could not serve.", labels)).with(values),
            .coalesced = (try registry.counter("anole_cache_coalesced_total", "Database calls that shared one already in flight.", labels)).with(values),
            .stores = (try registry.counter("anole_cache_stores_total", "Entries put in a cache.", labels)).with(values),
            .evictions = (try registry.counter("anole_cache_evictions_total", "Entries a cache pushed out to make room.", labels)).with(values),
            .entries = (try registry.gauge("anole_cache_entries", "Entries in a cache.", labels)).with(values),
            .bytes = (try registry.gauge("anole_cache_bytes", "Bytes a cache's entries take.", labels)).with(values),
        };
    }

    /// Has `st` report here too, starting the gauges where it is.
    pub fn attach(self: *const Metrics, st: *Store) void {
        st.metrics = self;
        self.entries.add(@intCast(st.map.count()));
        self.bytes.add(@intCast(st.bytes));
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testStamp(gens: *const Generations) Stamp {
    return gens.stamp(Generations.untagged, 0);
}

fn put(store: *Store, gens: *const Generations, key: []const u8, len: usize, expires: i96) !void {
    const e = store.create(key, len, .of(u64), expires, testStamp(gens)) orelse return error.TooBig;
    @memset(e.value(), 0xab);
    store.insert(e);
}

test "Store: least recently used goes first, by entries and by bytes" {
    var gens: Generations = .{};
    var store: Store = .init(testing.allocator, 3, 1 << 20);
    defer store.deinit();
    try put(&store, &gens, "a", 8, 100);
    try put(&store, &gens, "b", 8, 100);
    try put(&store, &gens, "c", 8, 100);
    // "a" used, so "b" is the least recent.
    try testing.expect(store.get("a", 0, &gens) != null);
    try put(&store, &gens, "d", 8, 100);
    try testing.expect(store.get("b", 0, &gens) == null);
    try testing.expect(store.get("a", 0, &gens) != null);
    try testing.expectEqual(@as(u64, 1), store.stats.evictions.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), store.stats.entries.load(.monotonic));

    // By bytes: room for about two entries of 1000.
    var small: Store = .init(testing.allocator, 100, 2 * (1000 + @sizeOf(Store.Entry) + 16));
    defer small.deinit();
    try put(&small, &gens, "x", 1000, 100);
    try put(&small, &gens, "y", 1000, 100);
    try put(&small, &gens, "z", 1000, 100);
    try testing.expect(small.get("x", 0, &gens) == null);
    try testing.expect(small.get("z", 0, &gens) != null);
    try testing.expect(small.bytes <= small.max_bytes);
    // Larger than the whole store: not created.
    try testing.expectError(error.TooBig, put(&small, &gens, "w", 1 << 20, 100));
}

test "Store: an entry of the same key replaces the old one; expired and invalidated ones miss" {
    var gens: Generations = .{};
    var store: Store = .init(testing.allocator, 10, 1 << 20);
    defer store.deinit();
    try put(&store, &gens, "k", 8, 100);
    try put(&store, &gens, "k", 16, 100);
    try testing.expectEqual(@as(u32, 1), store.map.count());
    try testing.expectEqual(@as(usize, 16), store.get("k", 0, &gens).?.value_len);
    // Expired at 100.
    try testing.expect(store.get("k", 100, &gens) == null);
    try testing.expectEqual(@as(u32, 0), store.map.count());

    // Invalidation by key slot, by tag and of everything.
    const e = store.create("t", 8, .of(u64), 100, gens.stamp(Generations.tagSlot("posts"), 7)).?;
    store.insert(e);
    try testing.expect(store.get("t", 0, &gens) != null);
    gens.invalidateTag("users");
    try testing.expect(store.get("t", 0, &gens) != null);
    gens.invalidateTag("posts");
    try testing.expect(store.get("t", 0, &gens) == null);

    store.insert(store.create("u", 8, .of(u64), 100, gens.stamp(Generations.untagged, 7)).?);
    gens.invalidateKey(7 + Generations.key_slots);
    try testing.expect(store.get("u", 0, &gens) == null);

    try put(&store, &gens, "v", 8, 100);
    gens.invalidateAll();
    try testing.expect(store.get("v", 0, &gens) == null);
}
