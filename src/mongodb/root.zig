//! MongoDB for Anole's handlers (`-Dmongodb`, in the full profile): a
//! client of Anole's own on std.Io, following the drivers' specifications
//! (OP_MSG, the handshake, SCRAM, the connection string, discovery and
//! monitoring, pooling, implicit sessions, retryable reads and writes).
//!
//!     const App = struct { db: *anole.mongodb.Client };
//!     state.db = try app.mongodb(.{}); // MONGODB_URI, else localhost
//!
//!     const User = struct { _id: anole.bson.ObjectId, name: []const u8, email: []const u8 };
//!
//!     fn byEmail(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         const users = app.db.collection("users");
//!         const email = req.query.get("email") orelse return error.BadRequest;
//!         try res.json(try users.findOne(User, req, .{ .email = email }, .{})); // none: 404
//!     }
//!
//! Every call takes the request first (or an `anole.db.Ctx` outside one):
//! results live in its arena, its deadline bounds the call, and failures
//! are `anole.db` errors that become statuses. See docs/database.md.
const std = @import("std");

/// The handle in the App state: `app.mongodb(.{})`, or `Client.init`
/// outside `anole.Server`. `client.collection("users")` and
/// `client.db("app")` lead to the calls; `client.with(.{ ... })` to the
/// same with options.
pub const Client = @import("client.zig").Client;
/// `app.mongodb(options)` and `Client.init`: the connection string,
/// pool bounds, timeouts, TLS, retries, and how errors map to statuses.
pub const Options = @import("client.zig").Options;
/// What every call fails with: `anole.db.Error`, a cancel, or memory.
pub const Error = @import("client.zig").Error;
/// What `Client.with` returns: `db` and `collection`, whose calls take
/// its options.
pub const Query = @import("client.zig").Query;
/// A database of the client (`client.db("app")`): `collection`,
/// `runCommand` (any command; its reply as a `bson.Document`), `drop`.
pub const Database = @import("collection.zig").Database;
/// A collection (`client.collection("users")`): find, aggregate, count,
/// insert, update, replace, delete, find-and-modify, indexes.
pub const Collection = @import("collection.zig").Collection;
/// The documents of `Collection.iterate` and `aggregateIterate`, a batch
/// at a time: `next` until null, then `deinit`.
pub const Cursor = @import("collection.zig").Cursor;
/// What `Collection.insertOne` returns.
pub const InsertOneResult = @import("collection.zig").InsertOneResult;
/// What `Collection.insertMany` returns.
pub const InsertManyResult = @import("collection.zig").InsertManyResult;
/// What `updateOne`, `updateMany` and `replaceOne` return.
pub const UpdateResult = @import("collection.zig").UpdateResult;
/// What `deleteOne` and `deleteMany` return.
pub const DeleteResult = @import("collection.zig").DeleteResult;
/// `findOneAndUpdate`'s and `findOneAndReplace`'s `return_document`
/// option: the document as it was (`before`, the default) or became.
pub const ReturnDocument = @import("collection.zig").ReturnDocument;
/// `anole.bson.ObjectId`, the usual `_id`.
pub const ObjectId = @import("bson").ObjectId;
/// Change streams: `Collection.watch`, `Database.watch`, `Client.watch`.
pub const change_stream = @import("change_stream.zig");
/// A change stream decoding its events into `T` (`Collection.watch`).
pub const ChangeStream = change_stream.ChangeStream;
/// What `watch` takes: `full_document`, resume tokens, `max_await`...
pub const ChangeStreamOptions = change_stream.ChangeStreamOptions;
/// A typed change event, for `ChangeStream(ChangeEvent)`.
pub const ChangeEvent = change_stream.ChangeEvent;
pub const FullDocument = change_stream.FullDocument;
pub const FullDocumentBeforeChange = change_stream.FullDocumentBeforeChange;
/// Collection calls named at run time, with BSON arguments (the C ABI).
pub const dynamic = @import("dynamic.zig");

test {
    _ = @import("uri.zig");
    _ = @import("uri_fuzz_test.zig");
    _ = @import("scram.zig");
    _ = @import("wire.zig");
    _ = @import("sdam.zig");
    _ = @import("connection.zig");
    _ = @import("client.zig");
    _ = @import("collection.zig");
    _ = @import("dynamic.zig");
    _ = @import("change_stream.zig");
    _ = @import("fake_test.zig");
    _ = @import("live_test.zig");
}
