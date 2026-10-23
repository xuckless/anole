//! {{name}}: a small JSON API on Anole.
//!
//!   zig build run          # http://localhost:3000, API docs at /docs
//!   zig build test         # the tests below, in memory (src/main_test.zig)
//!   zig build openapi      # writes openapi.json
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const v = anole.validate;

const Greeting = struct { hello: []const u8 };
const User = struct { id: u64, name: []const u8 };

/// What POST /echo takes. A request that breaks a rule gets a 422 that names
/// the field, and the OpenAPI document shows the limits.
const Echo = struct {
    message: []const u8,

    pub const field_rules = .{
        .message = .{ v.trim, v.notBlank, v.maxLength(200) },
    };
};

// A handler may take its input as a parameter and return its output: Anole
// decodes and checks the input, writes the result as JSON, and the OpenAPI
// document is made from these signatures.

fn index(_: *anole.Request) Greeting {
    return .{ .hello = "world" };
}

fn user(_: *anole.Request, in: anole.In(.{ .path = struct { id: u64 } })) User {
    return .{ .id = in.path.id, .name = "Ada" };
}

fn echo(_: *anole.Request, in: anole.In(.{ .body = Echo })) Echo {
    return in.body;
}

/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.App) void {
    app.get("/", anole.doc(.{ .summary = "A greeting" }, index));
    app.get("/users/:id", user);
    app.post("/echo", echo);
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    _ = app.health(.{}); // /healthz and /readyz
    app.openapi(.{ .info = .{ .title = "{{name}}", .version = "0.1.0" } }); // /openapi.json and /docs, in development
    routes(&app);
    try app.listen(":3000");
}
