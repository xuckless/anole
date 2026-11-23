# Query cache and coalescing

Up: [index](index.md). Related: [postgres](postgres.md), [sqlite](sqlite.md), [mongodb](mongodb.md), [redis](redis.md). Whole responses rather than rows: `ResponseCache`, see [response cache](../middleware-auth/caching.md).

Two opt-in options on reads (`one`, `optional`, `all`) of every connector, MongoDB's `find`, `findOne`, `findOptional`, `distinct`, `countDocuments`, `estimatedDocumentCount`, `aggregate`, and Redis's read commands and read helpers. Don't build a cache map or a singleflight of your own. A call without them is the plain call, with nothing added. Full docs: docs/database.md#caching. Source: src/db/cache.zig.

Use: `anole.db.QueryOptions` (`coalesce`, `cache`), `anole.db.QueryOptions.Cache` (`ttl`, `tag`, `keep_empty`), `anole.db.QueryCache` (`invalidate`, `invalidateQuery`, `stats`), `anole.db.CacheOptions` (`max_entries`, `max_bytes`), `anole.db.lastSource`, `anole.db.Source` (src/db/root.zig, src/db/cache.zig).

```zig
// Identical reads in flight at once share one round trip.
const feed = try app.db.with(.{ .coalesce = true }).all(Post, req, feed_sql, .{limit});

// The result kept for 5 s and served from memory meanwhile.
const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5), .tag = "posts" } }).all(Post, req, top_sql, .{});

// After a write: drop what it changed, on every executor.
_ = try app.db.exec(req, "INSERT INTO posts (body) VALUES ($1)", .{body});
app.db.cache.invalidate(.{ .tag = "posts" });
```

Cache-aside, in-process over Redis over PostgreSQL (from docs/database.md):

```zig
const aside = app.redis.with(.{ .cache = .{ .ttl = .fromSeconds(5), .keep_empty = false } });
const name = try aside.get(req, key) orelse blk: {
    const user = try app.db.one(User, req, "SELECT name FROM users WHERE id = $1", .{id});
    _ = try app.redis.set(req, key, user.name, .{ .ttl = .fromSeconds(60) });
    break :blk user.name;
};
```

Where an answer came from:

```zig
const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5) } }).all(Post, req, top_sql, .{});
try res.header("X-Cache", if (anole.db.lastSource(req) == .cache) "HIT" else "MISS");
```

Invalidation: `app.db.cache.invalidate(.all)`, `.invalidate(.{ .tag = "posts" })`, or `.invalidateQuery(sql, .{args})` for one statement (Redis: `app.redis.cache.invalidateQuery("GET", .{key})`; MongoDB: by tag). It reaches every executor at once.

Bounds per connector, split between executors, least recently used first: `app.postgres(.{ .cache = .{ .max_entries = 4096, .max_bytes = 32 << 20 } })`. With `app.metrics` each cache reports `anole_cache_*` series.

Traps:
- Each executor keeps its own results: two executors may answer from results read up to `ttl` apart, and a write shows only after `ttl` or an invalidation. Not for read-your-writes, balances, stock counts, unless every write invalidates.
- The key is the statement and its arguments. Per-user data must take the user as an argument, never only from the session.
- Not for statements with side effects (`nextval`, `INSERT ... RETURNING` through `one`): the statement runs once for every caller that shares it.
- Errors are never kept (`NotFound` included). Empty results are kept unless `.keep_empty = false`; use false for cache-aside, or "missing" is served for `ttl` after the value exists.
- Row types must be copyable (numbers, `bool`, enums, optionals, arrays, structs, tagged unions, slices of these). A row type with another pointer (`std.json.Value`) runs unshared, with a warning logged once (docs/database.md:1230; src/db/copy.zig `copyable`).
- Arguments compare by value: `5` as `u8` and as `i64` are one key, `"5"` is not.
- Calls on a `Tx` are never shared; `coalesce` or `cache` inside a transaction fail the call.
- A result larger than an executor's share of `max_bytes` is not kept.
