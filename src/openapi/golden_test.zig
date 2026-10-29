//! Whole documents: the app's routes and services written out and compared,
//! byte for byte, with the files in tests/openapi/. On a mismatch the
//! document is written to tests/openapi/<name>.actual.json for review.
//! After an intended change, regenerate them with ANOLE_UPDATE_GOLDEN=1
//! (`ANOLE_UPDATE_GOLDEN=1 zig build test -Dtest-filter=openapi`, as the
//! console's goldens) and read the diff (TESTING.md F2). A golden file
//! checked out with CRLF line ends (Git's autocrlf on Windows) compares as
//! LF.
const std = @import("std");
const dusty = @import("dusty");
const server_mod = @import("../server.zig");
const typed = @import("../typed.zig");
const handlers = @import("../handlers.zig");
const errors = @import("../errors.zig");
const auth = @import("../auth/root.zig");
const ratelimit = @import("../ratelimit/root.zig");
const testing_mod = @import("../testing/root.zig");
const root = @import("root.zig");
const document = @import("document.zig");
const operation = @import("operation.zig");
const features = @import("build_options");
const grpc_on = features.grpc;
const tpb = if (grpc_on) @import("anole_transcode_pb") else struct {};
const proto = if (grpc_on) @import("proto.zig") else struct {};
const Widgets = if (grpc_on) tpb.Widgets(@import("../grpc/server.zig").Call, anyerror) else void;
const v = @import("validate");

const alloc = std.testing.allocator;
const Request = dusty.Request;
const Response = dusty.Response;

fn expectGolden(name: []const u8, actual: []const u8) !void {
    const io = std.testing.io;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "tests/openapi/{s}.json", .{name});
    if (try std.testing.environ.containsUnempty(alloc, "ANOLE_UPDATE_GOLDEN")) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = actual });
        return;
    }
    const file = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (file.len > 0) alloc.free(file);
    const want = try std.mem.replaceOwned(u8, alloc, file, "\r\n", "\n");
    defer alloc.free(want);
    if (std.mem.eql(u8, want, actual)) return;
    const actual_path = try std.fmt.allocPrint(alloc, "tests/openapi/{s}.actual.json", .{name});
    defer alloc.free(actual_path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = actual_path, .data = actual }) catch {};
    std.debug.print("{s} differs from {s}; the document is in {s}\n", .{ name, path, actual_path });
    return error.GoldenMismatch;
}

// ------------------------------------------------------------------ the todos app

const Todo = struct {
    id: u64,
    title: []const u8,
    done: bool = false,
    tags: []const []const u8 = &.{},
};

const NewTodo = struct {
    title: []const u8,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .title = .{ v.notBlank, v.maxLength(100) },
    };
};

fn listTodos(_: *Request, in: typed.In(.{ .query = struct { limit: u32 = 50, tag: ?[]const u8 = null } })) []const Todo {
    _ = in;
    return &.{};
}

fn getTodo(_: *Request, in: typed.In(.{ .path = struct { id: u64 } })) error{NotFound}!Todo {
    _ = in;
    return error.NotFound;
}

fn createTodo(_: *Request, in: typed.In(.{ .body = NewTodo })) !typed.Created(Todo) {
    _ = in;
    return error.Unexpected;
}

fn removeTodo(_: *Request, in: typed.In(.{ .path = struct { id: u64 } })) error{ NotFound, Conflict }!void {
    _ = in;
}

fn legacy(_: *Request, _: *Response) !void {}

fn hidden(_: *Request, _: *Response) !void {}

fn todosApp(app: *server_mod.App) void {
    app.openapi(.{ .info = .{ .title = "Todos", .version = "1.0.0" }, .tags = &.{.{ .name = "todos", .description = "Things to do." }} });
    const api = app.group("/api/v1", .{});
    api.get("/todos", handlers.doc(.{ .summary = "List todos" }, listTodos));
    api.get("/todos/:id", getTodo);
    api.post("/todos", createTodo);
    api.delete("/todos/:id", removeTodo);
    app.get("/legacy/export", handlers.doc(.{
        .summary = "Export",
        .response = []const Todo,
        .status = .ok,
        .responses = &.{.{ .status = .not_modified, .description = "Unchanged" }},
    }, legacy));
    app.get("/internal", handlers.doc(.{ .hidden = true }, hidden));
}

test "golden: todos REST app" {
    var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    todosApp(&app);
    const doc = try app.openapiDocument(alloc);
    defer alloc.free(doc);
    try expectGolden("todos", doc);
}

test "deterministic: the same routes in another order write the same bytes" {
    const first = blk: {
        var a = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
        defer a.deinit();
        todosApp(&a);
        const one_doc = try a.openapiDocument(alloc);
        errdefer alloc.free(one_doc);
        // Twice from one app: the same bytes.
        const again = try a.openapiDocument(alloc);
        defer alloc.free(again);
        try std.testing.expectEqualStrings(one_doc, again);
        break :blk one_doc;
    };
    defer alloc.free(first);
    var b = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer b.deinit();
    b.openapi(.{ .info = .{ .title = "Todos", .version = "1.0.0" }, .tags = &.{.{ .name = "todos", .description = "Things to do." }} });
    b.get("/internal", handlers.doc(.{ .hidden = true }, hidden));
    b.get("/legacy/export", handlers.doc(.{
        .summary = "Export",
        .response = []const Todo,
        .status = .ok,
        .responses = &.{.{ .status = .not_modified, .description = "Unchanged" }},
    }, legacy));
    const api = b.group("/api/v1", .{});
    api.delete("/todos/:id", removeTodo);
    api.post("/todos", createTodo);
    api.get("/todos/:id", getTodo);
    api.get("/todos", handlers.doc(.{ .summary = "List todos" }, listTodos));
    const second = try b.openapiDocument(alloc);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "left out: any, hidden and routes of other kinds" {
    var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.any("/anything", legacy);
    app.get("/internal", handlers.doc(.{ .hidden = true }, hidden));
    app.get("/shown", legacy);
    const doc = try app.openapiDocument(alloc);
    defer alloc.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/anything") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/internal") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/shown") != null);
}

// ------------------------------------------------------------------ security

fn secret(_: *Request, _: *Response) !void {}

test "golden: security from middleware" {
    var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.openapi(.{ .info = .{ .title = "Secure", .version = "1.0.0" } });
    const keys = [_]auth.Key{.{ .kid = "k", .alg = .HS256, .material = .{ .hmac = "0123456789abcdef0123456789abcdef" } }};
    const policy: auth.rbac.Policy = .{ .roles = &.{.{ .name = "admin", .grants = &.{"*"} }} };
    const bearer = auth.RequireJwt.init(.{ .static = &keys }, .{ .issuer = "i", .audience = "a" }, .{});
    const api = app.group("/api", .{bearer});
    api.get("/me", secret);
    api.with(.{auth.rbac.Require.init(&policy, "admin:write", .{ .roles = rolesOf })}).post("/admin", secret);
    const keyed = app.group("/service", .{auth.apikey.Middleware.init(.{ .ptr = null, .lookup = lookupKey })});
    keyed.get("/stats", secret);
    app.get("/open", secret);
    const doc = try app.openapiDocument(alloc);
    defer alloc.free(doc);
    try expectGolden("security", doc);
}

fn rolesOf(_: ?*anyopaque, _: *Request) anyerror![]const []const u8 {
    return &.{};
}

fn lookupKey(_: ?*anyopaque, _: std.mem.Allocator, _: auth.apikey.Digest) anyerror!?[]const u8 {
    return null;
}

// ------------------------------------------------------------------ gRPC

test "golden: Widgets gRPC service" {
    if (comptime !grpc_on) return error.SkipZigTest;
    const ops = comptime proto.serviceOperations(Widgets);
    var entries: [ops.len]root.Entry = undefined;
    inline for (0..ops.len) |i| {
        const op: *const operation.Operation = comptime &ops[i].op;
        entries[i] = .{
            .verb = ops[i].verb,
            .path = ops[i].path,
            .op = op,
            .annotated = ops[i].annotated,
            .tag_doc = comptime proto.serviceDoc(Widgets),
        };
    }
    const doc = try document.build(alloc, &entries, .{ .info = .{ .title = "Widgets", .version = "1.0.0" } }, .auto, errors.log);
    defer alloc.free(doc);
    try expectGolden("widgets", doc);
}

test "gRPC forms by Options.grpc" {
    if (comptime !grpc_on) return error.SkipZigTest;
    const ops = comptime proto.serviceOperations(Widgets);
    var entries: [ops.len]root.Entry = undefined;
    inline for (0..ops.len) |i| {
        const op: *const operation.Operation = comptime &ops[i].op;
        entries[i] = .{ .verb = ops[i].verb, .path = ops[i].path, .op = op, .annotated = ops[i].annotated };
    }
    const none = try document.build(alloc, &entries, .{ .grpc = .{ .connect = .none } }, .auto, errors.log);
    defer alloc.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "application/json") != null);
    const rest_off = try document.build(alloc, &entries, .{ .grpc = .{ .transcoded = false } }, .auto, errors.log);
    defer alloc.free(rest_off);
    try std.testing.expect(rest_off.len != none.len);
}

// ------------------------------------------------------------------ names

const one = struct {
    pub const User = struct { id: u8 };
};
const two = struct {
    pub const User = struct { name: []const u8 };
};

fn userOne(_: *Request) one.User {
    return .{ .id = 1 };
}
fn userTwo(_: *Request) two.User {
    return .{ .name = "x" };
}

test "name clash, and rename" {
    var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/one", userOne);
    app.get("/two", userTwo);
    // (The log line names both types.)
    const expected_log = errors.expectLog();
    defer expected_log.deinit();
    try std.testing.expectError(error.OpenApiNameClash, app.openapiDocument(alloc));

    app.openapi(.{ .rename = &.{.{ .type_name = @typeName(two.User), .name = "UserTwo" }} });
    const doc = try app.openapiDocument(alloc);
    defer alloc.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"UserTwo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"User\"") != null);
}

// ------------------------------------------------------------------ serving

test "served when allowed: the document and the page" {
    var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.openapi(.{ .serve = .always, .info = .{ .title = "Served" } });
    app.get("/shown", secret);
    var t = try testing_mod.client(&app);
    defer t.deinit();
    var res = try t.get("/openapi.json", .{});
    defer res.deinit();
    try res.expectStatus(.ok);
    try std.testing.expect(std.mem.startsWith(u8, res.header("Content-Type").?, "application/json"));
    var page = try t.get("/docs", .{});
    defer page.deinit();
    try page.expectStatus(.ok);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "data-url=\"/openapi.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.body, "integrity=\"sha384-") != null);
}

test "not served in production (what tests resolve), the default being development only" {
    var quiet = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
    defer quiet.deinit();
    quiet.openapi(.{});
    quiet.get("/shown", secret);
    var t = try testing_mod.client(&quiet);
    defer t.deinit();
    var gone = try t.get("/openapi.json", .{});
    defer gone.deinit();
    try gone.expectStatus(.not_found);
}

test "ANOLE_OPENAPI_OUT writes the file and ANOLE_OPENAPI_CHECK compares it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir);
    const file = try std.fmt.allocPrint(alloc, "{s}/openapi.json", .{dir});
    defer alloc.free(file);
    const expected_log = errors.expectLog();
    defer expected_log.deinit();

    {
        // Missing file: out of date.
        var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
        defer app.deinit();
        todosApp(&app);
        app._openapi_env = .{ .check = file };
        try std.testing.expectError(error.OpenApiOutOfDate, app.run());
    }
    var expected: []u8 = undefined;
    {
        var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
        defer app.deinit();
        todosApp(&app);
        app._openapi_env = .{ .out = file };
        try app.run(); // returns without binding anything
        expected = try app.openapiDocument(alloc);
    }
    defer alloc.free(expected);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, .limited(1 << 20));
    defer alloc.free(written);
    try std.testing.expectEqualStrings(expected, written);
    {
        var app = try server_mod.App.init(alloc, .{ .executors = .exact(1) });
        defer app.deinit();
        todosApp(&app);
        app._openapi_env = .{ .check = file };
        try app.run();
    }
}
