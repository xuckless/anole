//! HttpArena's async-db profile (`/async-db`), as Anole's HttpArena entry
//! answers it: a price range from the items table of HttpArena's
//! data/pgdb-seed.sql (no index on price), at most 50 rows.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;

pub const State = struct {
    db: *anole.pg.Client,

    pub fn init(app: *anole.Server(App), url: []const u8, pool_total: u32) !State {
        return .{ .db = try app.postgres(.{ .url = url, .max_connections = pool_total }) };
    }
};

pub fn routes(app: *anole.Server(App)) void {
    app.get("/async-db", asyncDb);
}

const sql =
    \\SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
    \\  FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3
;

const Row = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: std.json.Value,
    rating_score: i64,
    rating_count: i64,
};

const Item = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: std.json.Value,
    rating: struct { score: i64, count: i64 },
};

fn asyncDb(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const min = req.query.getInt(i64, "min") orelse 10;
    const max = req.query.getInt(i64, "max") orelse 50;
    const limit = std.math.clamp(req.query.getInt(i64, "limit") orelse 50, 1, 50);
    const rows = try app.asyncdb.?.db.all(Row, req, sql, .{ min, max, limit });
    const items = try res.arena.alloc(Item, rows.len);
    for (rows, items) |r, *out| out.* = .{
        .id = r.id,
        .name = r.name,
        .category = r.category,
        .price = r.price,
        .quantity = r.quantity,
        .active = r.active,
        .tags = r.tags,
        .rating = .{ .score = r.rating_score, .count = r.rating_count },
    };
    try res.json(.{ .items = items, .count = items.len });
}
