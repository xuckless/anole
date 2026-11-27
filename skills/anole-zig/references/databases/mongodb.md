# MongoDB

Up: [index](index.md). Related: [caching](caching.md); change streams in [realtime](../realtime/index.md).

Built in with `-Dmongodb` (in the `full` profile): Anole's own client on `std.Io` (OP_MSG, SCRAM, TLS, server discovery, pooling, retryable reads and writes), documents in BSON (`anole.bson`). MongoDB 4.2 and later. Full docs: docs/database.md#mongodb. Example: examples/mongodb/main.zig.

## Setup

Use: `anole.App.mongodb` (src/server.zig), `anole.mongodb.Client`, `anole.mongodb.Options` (src/mongodb/client.zig).

`app.mongodb(.{})` reads `.url`, else `MONGODB_URI`, else `mongodb://localhost:27017`. It starts a monitor per server at once; call connections open when a handler needs one, per executor. Startup work takes an `anole.db.Ctx` (from examples/mongodb/main.zig):

```zig
const App = struct { db: *anole.mongodb.Client };

state.db = try app.mongodb(.{});
_ = app.health(.{}); // /readyz pings MongoDB

var arena: std.heap.ArenaAllocator = .init(init.gpa);
defer arena.deinit();
var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
_ = state.db.collection("users").createIndex(&c, .{ .email = 1 }, .{ .unique = true }) catch |err| {
    std.log.warn("users.email index not created ({t}): {f}", .{ err, anole.db.lastError(&c).? });
};
```

Traps:
- Not supported yet, refused at start: `mongodb+srv://` (use the standard `mongodb://host1,host2,host3/?replicaSet=...&tls=true` string), read preferences other than `primary`, `loadBalanced`, compression, GSSAPI/AWS/OIDC auth (docs/database.md:744).
- `app.db.collection(name)` is in the connection string's database, else `"test"`. Name another with `app.db.db("app").collection("users")`.
- A standalone `mongod` works, without retryable writes and sessions. Retryable writes need a replica set.

## CRUD

Use: `anole.mongodb.Collection` (`find`, `findOne`, `findOptional`, `insertOne`, `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, `deleteMany`, `findOneAndUpdate`, `findOneAndReplace`, `findOneAndDelete`, `countDocuments`, `estimatedDocumentCount`, `distinct`, `aggregate`, `createIndex`, `dropIndex`, `drop`, `with`), `anole.mongodb.Database.runCommand`, `anole.mongodb.ReturnDocument`, `anole.mongodb.InsertOneResult.objectId` (src/mongodb/collection.zig).

Filters, updates, projections and pipelines are Zig literals: an anonymous struct is a document, a tuple an array. From examples/mongodb/main.zig:

```zig
const User = struct {
    _id: anole.bson.ObjectId,
    name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},
};

fn userId(req: *anole.Request) !anole.bson.ObjectId {
    return anole.bson.ObjectId.parse(req.params.get("id") orelse "") catch error.NotFound;
}

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(try app.db.collection("users").findOne(User, req, .{ ._id = try userId(req) }, .{}));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewUser);
    const r = try app.db.collection("users").insertOne(req, in); // the same email: 409
    res.status = .created;
    try res.json(.{ .id = r.objectId().? });
}

fn update(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const patch = try req.bind(Patch);
    const users = app.db.collection("users");
    // Fields left null are left out of $set.
    const updated = try users.findOneAndUpdate(User, req, .{ ._id = try userId(req) }, .{ .@"$set" = patch }, .{
        .return_document = anole.mongodb.ReturnDocument.after,
    });
    try res.json(updated orelse return error.NotFound);
}

fn remove(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const r = try app.db.collection("users").deleteOne(req, .{ ._id = try userId(req) }, .{});
    if (r.deleted_count == 0) return error.NotFound;
    res.status = .no_content;
}
```

A query with options: `users.find(User, req, .{ .tags = tag }, .{ .sort = .{ .name = 1 }, .limit = limit })`. The shared verbs `one`, `optional`, `all` are `findOne`, `findOptional`, `find` under the other connectors' names.

Traps:
- No `exec`: writes return their own counts (`matched_count`, `modified_count`, `deleted_count`, `upserted_id`); `db(name).runCommand(req, command)` runs any command and returns a `bson.Document`.
- No transactions yet: each call stands alone and is retried on its own (docs/database.md:807). Don't write multi-document invariants that need one.
- `updateMany` and `deleteMany` are not retried after a network error (the spec says so).
- An option a call does not take is a compile error that lists the ones it does: read it rather than guessing.
- Errors: 11000 duplicate key, 112 write conflict are `Conflict` (409); no primary, auth failure, pool busy are `ServiceUnavailable` (503); 50 `MaxTimeMSExpired` or a call past its `timeout` is `GatewayTimeout` (504); the rest, document validation (121) included, `Database` (500).

## Cursors

Use: `anole.mongodb.Collection.iterate`, `anole.mongodb.Collection.aggregateIterate`, `anole.mongodb.Cursor` (`next`, `deinit`).

From src/mongodb/live_test.zig:

```zig
var cursor = try users.iterate(User, c, .{ .name = "many" }, .{ .batch_size = 5, .sort = .{ .age = 1 } });
defer cursor.deinit(); // ends the cursor on the server if documents are left
while (try cursor.next()) |u| {
    // ...
}
```

## BSON

Use: `anole.bson.ObjectId` (`parse`), `anole.bson.Datetime`, `anole.bson.Value`, `anole.bson.Document`.

Documents map onto structs by field name: integers, floats, `bool`, `[]const u8`, enums (by name), slices, nested structs, optionals (missing or `null` is null), `ObjectId`, `Datetime`, and `bson.Value` or `bson.Document` for anything dynamic. A missing field keeps its default, or the call fails (500, logged). Decoded strings are copies in the request's arena. In JSON responses an ObjectId is its hex string, a date ISO 8601.

Trap: an id from the URL that is not a valid ObjectId should be a 404: `ObjectId.parse(...) catch error.NotFound`, as above.

## Timeouts

A canceled request cancels the call where it waits, and the connection is closed. `with(.{ .timeout = .fromSeconds(2) })` or `timeoutMS` (`Options.timeout`, 30 s) bounds a call and sends the rest as `maxTimeMS`. The request's own deadline is not sent as `maxTimeMS` yet (docs/database.md, Timeouts and cancellation).
