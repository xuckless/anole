//! MongoDB for Anole's handlers (`-Dmongodb`, in the full profile): a
//! client of Anole's own on std.Io, following the drivers' specifications
//! (OP_MSG, the handshake, SCRAM, the connection string, discovery and
//! monitoring, pooling, implicit sessions, retryable reads and writes).
//!
//!     const App = struct { mongo: *anole.mongodb.Client };
//!     state.mongo = try app.mongodb(.{}); // MONGODB_URI, else localhost
//!
//!     const User = struct { _id: anole.bson.ObjectId, name: []const u8, email: []const u8 };
//!
//!     fn byEmail(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         const users = app.mongo.collection("users");
//!         const email = req.query.get("email") orelse return error.BadRequest;
//!         try res.json(try users.findOne(User, req, .{ .email = email }, .{})); // none: 404
//!     }
//!
//! Every call takes the request first (or an `anole.db.Ctx` outside one):
//! results live in its arena, its deadline bounds the call, and failures
//! are `anole.db` errors that become statuses. See docs/database.md.
const std = @import("std");

pub const Client = @import("client.zig").Client;
pub const Options = @import("client.zig").Options;
pub const CallError = @import("client.zig").CallError;
pub const Database = @import("collection.zig").Database;
pub const Collection = @import("collection.zig").Collection;
pub const Cursor = @import("collection.zig").Cursor;
pub const InsertOneResult = @import("collection.zig").InsertOneResult;
pub const InsertManyResult = @import("collection.zig").InsertManyResult;
pub const UpdateResult = @import("collection.zig").UpdateResult;
pub const DeleteResult = @import("collection.zig").DeleteResult;
pub const ReturnDocument = @import("collection.zig").ReturnDocument;
pub const ObjectId = @import("bson").ObjectId;

/// The pieces, for tests and tools.
pub const uri = @import("uri.zig");
pub const scram = @import("scram.zig");
pub const wire = @import("wire.zig");
pub const sdam = @import("sdam.zig");
pub const connection = @import("connection.zig");

test {
    _ = uri;
    _ = scram;
    _ = wire;
    _ = sdam;
    _ = connection;
    _ = @import("client.zig");
    _ = @import("collection.zig");
    _ = @import("fake_test.zig");
    _ = @import("live_test.zig");
}
