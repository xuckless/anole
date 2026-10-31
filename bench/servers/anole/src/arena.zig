//! HttpArena's json-comp and static profiles, as Anole's HttpArena entry
//! answers them (ARENA_DATA=<HttpArena's data directory>):
//!
//! - GET /json/:count: the first `count` items of data/dataset.json with a
//!   `total` per item (`?m=` multiplies it), compressed when the client
//!   accepts it.
//! - GET /static/*: data/static with its precompressed .br and .gz files,
//!   instead of MEDIA_DIR.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;

const Rating = struct { score: i64, count: i64 };

const Item = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const Priced = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

var dataset: []const Item = &.{};

/// Loads the dataset (kept for the process's life) and registers both
/// routes; main.zig then skips its own /static.
pub fn routes(app: *anole.Server(App), io: std.Io, arena: std.mem.Allocator, dir: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/dataset.json", .{dir});
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
    dataset = try std.json.parseFromSliceLeaky([]const Item, arena, raw, .{ .ignore_unknown_fields = true });
    app.get("/json/:count", anole.noWait(json));
    try app.staticDir("/static", try std.fmt.allocPrint(arena, "{s}/static", .{dir}), .{ .precompressed = &.{ .br, .gzip } });
}

fn json(req: *anole.Request, res: *anole.Response) !void {
    const count = req.params.getInt(usize, "count") orelse return res.fail(.bad_request, "bad count");
    if (count < 1 or count > dataset.len) return res.fail(.bad_request, "bad count");
    const m = req.query.getInt(i64, "m") orelse 1;
    const items = try res.arena.alloc(Priced, count);
    for (dataset[0..count], items) |it, *out| out.* = .{
        .id = it.id,
        .name = it.name,
        .category = it.category,
        .price = it.price,
        .quantity = it.quantity,
        .active = it.active,
        .tags = it.tags,
        .rating = it.rating,
        .total = it.price * it.quantity * m,
    };
    res.compress = true;
    try res.json(.{ .items = items, .count = count });
}
