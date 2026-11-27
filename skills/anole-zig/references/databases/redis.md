# Redis and Valkey

Up: [index](index.md). Related: [caching](caching.md) (in-process cache in front of Redis), [realtime](../realtime/index.md) (streams and pub/sub feeds through `app.watch`), [middleware-auth](../middleware-auth/index.md) (`anole.session.RedisStore`, `anole.ratelimit.RedisLimiter` take this client).

Built in with `-Dredis` (in the `full` profile). hiredis parses replies; connections, pools and TLS are Anole's. Full docs: docs/database.md#redis-and-valkey. Example: examples/redis/main.zig.

## Setup

Use: `anole.App.redis` (src/server.zig), `anole.redis.Client`, `anole.redis.Options` (src/redis/root.zig).

`app.redis(.{})` reads `.url`, else `REDIS_URL`, else `redis://127.0.0.1:6379`. URLs: `redis://host:6379/2` (database 2), `redis://user:password@host`, `rediss://...` (TLS), `unix:///run/redis.sock?db=0`.

```zig
const App = struct { redis: *anole.redis.Client };

state.redis = try app.redis(.{});
_ = app.metrics(.{}); // the pool and command times too
_ = app.health(.{}); // /readyz sends PING
```

Trap: Redis Cluster and Sentinel are not supported; a URL with several hosts is refused (docs/database.md:941).

## Commands and helpers

Use: `anole.redis.Client.command`, `.one`, `.optional`, `.all`, `.with`; helpers `get`, `set`, `del`, `incr`, `incrBy`, `expire`, `hget`, `hset`, `hgetAll`, `hdel`, `hincrBy`, `lpush`, `rpush`, `lrange`, `sadd`, `srem`, `smembers`, `sismember`, `zadd`, `zincrBy`, `zscore`, `zrem`, `zrange`, `zrangeWithScores`, `publish`; `anole.redis.Reply`, `anole.redis.SetOptions`, `anole.redis.RangeOptions`.

From examples/redis/main.zig:

```zig
fn hits(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .hits = try app.redis.incr(req, "example:hits") });
}

fn quote(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u32, "id") orelse return error.NotFound;
    const key = try std.fmt.allocPrint(req.arena, "example:quote:{d}", .{id});
    if (try app.redis.get(req, key)) |cached| {
        res.content_type = .json;
        res.body = cached;
        return;
    }
    const body = try render(req); // the slow part
    _ = try app.redis.set(req, key, body, .{ .ttl = .fromSeconds(30) });
    res.content_type = .json;
    res.body = body;
}

fn leaderboard(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(try app.redis.zrangeWithScores(req, "example:board", 0, 9, .{ .rev = true }));
}
```

Anything else: `command(req, .{ "INCR", key })` returns the `Reply` (`.int`, `.string`, `.array`, `.nil`...); `one(T, req, args)` reads it as a `T` (nil, or an empty hash for a struct, is `error.NotFound`); `optional` gives null; `all` reads an array as `[]T`. `hgetAll(Profile, req, key)` reads a hash into a struct by field name.

Arguments are a tuple: strings as they are, numbers in decimal, `bool` as 1/0, enums by name, null left out, slices item by item, a struct as field names and values: `.{ "HSET", key, profile }`, `.{ "SET", key, value, "EX", 60 }`.

Traps:
- `set` returns false when `.nx` or `.xx` kept it from being set.
- A blocking command (`BLPOP`, `XREAD BLOCK`) holds its pooled connection while it waits: give it a `with(.{ .timeout })` of its own or `acquire` one (docs/database.md:1092).
- A canceled call closes its connection, since the reply may still be on its way.
- Errors: `LOADING`, `READONLY`, `OOM`, `WRONGPASS`, no connection are `ServiceUnavailable` (503); a call past its timeout `GatewayTimeout` (504); `WRONGTYPE`, `ERR`, a reply that does not fit the type `Database` (500).

## Pipelines and WATCH

Use: `anole.redis.Client.pipeline`, `anole.redis.Client.acquire`, `anole.redis.Conn` (`command`, `one`, `optional`, `all`, `pipeline`, `release`).

```zig
// One round trip; MULTI ... EXEC makes it atomic.
const r = try app.redis.pipeline(req, .{ .{"MULTI"}, .{ "INCR", key }, .{ "EXPIRE", key, 60 }, .{"EXEC"} });
const count = r[3].array[0].int;
```

WATCH needs one connection across round trips:

```zig
var conn = try app.redis.acquire(req);
defer conn.release();
_ = try conn.command(req, .{ "WATCH", key });
const stock = try conn.one(i64, req, .{ "GET", key });
const r = try conn.pipeline(req, .{ .{"MULTI"}, .{ "SET", key, stock - 1 }, .{"EXEC"} });
if (r[2] == .nil) return error.Conflict; // the key changed: nothing was set
```

Traps:
- Release the connection once, before the arena of the request or `Ctx` given to `acquire` is reset or freed: the pool's record of it lives there (docs/database.md:1044). Call nothing on it after.
- A pipeline fails with its first error reply; errors inside EXEC's reply come back as `.err` replies.
- A connection left inside MULTI or WATCH, on another database (SELECT), subscribed, or with `CLIENT SETNAME`/`CLIENT TRACKING` state is closed, not reused.

## Pub/sub

Use: `anole.redis.Client.subscribe`, `anole.redis.Client.psubscribe`, `anole.redis.Subscriber` (`next`, `subscribe`, `psubscribe`, `unsubscribe`, `punsubscribe`, `stop`, `close`), `anole.redis.Message`, `anole.redis.Client.publish`.

From examples/redis/main.zig, streamed as Server-Sent Events:

```zig
fn events(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const room = req.params.get("room") orelse return error.NotFound;
    req.setTimeout(null); // a stream, not a request with a deadline
    const channel = try std.fmt.allocPrint(req.arena, "example:room:{s}", .{room});
    const sub = try app.redis.subscribe(req, channel);
    defer sub.close();
    var buf: [1024]u8 = undefined;
    var stream = try res.startEventStream(&buf);
    while (try sub.next(req)) |msg| try stream.send(msg.payload, .{ .event = "message" });
    try stream.body.end();
}
```

Traps:
- A subscriber has a connection of its own, outside the pools. `close` it (`defer sub.close()`); not while another task waits in `next`.
- `msg` is valid until the next `next`: copy what you keep.
- `next` returns null once nothing is subscribed, after `stop()` (from any task), or when the server drains, so the stream ends in time.
- Fan-out to many clients (SSE topics, WebSocket rooms): prefer `app.watch` ([realtime](../realtime/index.md)), one shared connection.
