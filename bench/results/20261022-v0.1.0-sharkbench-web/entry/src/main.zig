const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options;

const Element = struct { name: []const u8, number: i64, group: i64 };

/// GET /api/v1/periodic-table/element?symbol=He: the element from the data
/// source, through the server's pooled HTTP client (anole.client).
fn element(req: *anole.Request, res: *anole.Response) !void {
    const symbol = req.query.get("symbol") orelse return error.BadRequest;
    var upstream = try anole.client(req).fetch("http://127.0.0.1:5002/element.json", .{});
    defer upstream.deinit();
    const all = try upstream.json(std.json.ArrayHashMap(Element), req.arena);
    const e = all.map.get(symbol) orelse return error.NotFound;
    try res.json(.{ .name = e.name, .number = e.number, .group = e.group });
}

/// GET /api/v1/periodic-table/shells?symbol=He
fn shells(req: *anole.Request, res: *anole.Response) !void {
    const symbol = req.query.get("symbol") orelse return error.BadRequest;
    var upstream = try anole.client(req).fetch("http://127.0.0.1:5002/shells.json", .{});
    defer upstream.deinit();
    const all = try upstream.json(std.json.ArrayHashMap([]const i64), req.arena);
    try res.json(.{ .shells = all.map.get(symbol) orelse return error.NotFound });
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .address = "0.0.0.0", .port = 5001 },
    }, {});
    defer app.deinit();
    app.get("/api/v1/periodic-table/element", element);
    app.get("/api/v1/periodic-table/shells", shells);
    try app.run();
}
