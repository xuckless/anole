//! Typed handlers: a handler that names its inputs and its output in its
//! signature, so a tool (the compiler's checks here, OpenAPI later) can see
//! them.
//!
//!     fn update(req: *anole.Request, in: anole.In(.{ .path = struct { id: u64 }, .body = UpdateUser })) !User {
//!         return store.update(in.path.id, in.body);
//!     }
//!     app.put("/users/:id", update);
//!
//! The shape is `fn ([ctx: *Ctx,] req: *anole.Request, [res: *anole.Response,]
//! [in: anole.In(...)]) [E!]Out`. A handler that is exactly `(req, res)` or
//! `(ctx, req, res)` and returns `void` or `!void` is *plain*: it answers
//! itself. Any other handler of this shape is typed:
//!
//! - `in` is bound before the handler runs: the path (`error.NotFound` on a
//!   mismatch), then the query, headers and body, whose violations are
//!   collected into one 422 problem+json (`req.violations()`).
//! - A non-void `Out` is written with `res.json`, status 200, or the type's
//!   own: `anole.Created(T)` (201, with `Location`), `anole.Accepted(T)`
//!   (202), `anole.WithStatus(status, T)` (any 2xx). A handler that takes
//!   `res` and changed `res.status` keeps its status.
//! - A `void` result answers 204 when the handler takes no `res`.

const std = @import("std");
const dusty = @import("dusty");
const validate = @import("validate");
const route_pattern = dusty.route_pattern;

// ------------------------------------------------------------------ In

/// What `anole.In` takes: the types of each input, `void` for none.
pub const InSpec = struct { path: type = void, query: type = void, headers: type = void, body: type = void };

const spec_keys = [_][]const u8{ "path", "query", "headers", "body" };

/// Typed inputs of a handler, its last parameter:
///
///     fn update(req: *anole.Request, res: *anole.Response,
///               in: anole.In(.{ .path = struct { id: u64 }, .body = UpdateUser })) !void
///
/// Keys: `.path` (`req.bindPath`; a mismatch is 404), `.query`
/// (`req.bindQuery`, repeats into `[]const T`), `.headers`
/// (`req.bindHeaders`) and `.body` (`req.bind`). Absent keys are `void`
/// fields. Query, header and body violations are reported together as one
/// 422. A path field must be a parameter of the route; a wildcard's field
/// is a `[]const u8`.
pub fn In(comptime spec: anytype) type {
    const S = @TypeOf(spec);
    const info = switch (@typeInfo(S)) {
        .@"struct" => |s| s,
        else => @compileError("anole.In takes a struct literal such as .{ .body = NewUser }, not " ++ @typeName(S)),
    };
    comptime var parsed: InSpec = .{};
    inline for (info.field_names) |name| {
        const value = @field(spec, name);
        if (@TypeOf(value) != type) @compileError("anole.In: ." ++ name ++ " is a type (a struct for path, query and headers), not a value of " ++ @typeName(@TypeOf(value)));
        if (comptime std.mem.eql(u8, name, "path")) {
            parsed.path = value;
        } else if (comptime std.mem.eql(u8, name, "query")) {
            parsed.query = value;
        } else if (comptime std.mem.eql(u8, name, "headers")) {
            parsed.headers = value;
        } else if (comptime std.mem.eql(u8, name, "body")) {
            parsed.body = value;
        } else {
            const hint = if (validate.closest(&spec_keys, name)) |c| " (did you mean ." ++ c ++ "?)" else "";
            @compileError("anole.In: unknown key ." ++ name ++ "; the keys are .path, .query, .headers and .body" ++ hint);
        }
    }
    const final: InSpec = parsed;
    comptime checkSpec(final);
    return struct {
        path: final.path,
        query: final.query,
        headers: final.headers,
        body: final.body,

        pub const anole_in: InSpec = final;
    };
}

/// Whether `T` is a type `In` returned.
pub fn isIn(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "anole_in") and @TypeOf(T.anole_in) == InSpec;
}

fn isScalar(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .int, .float, .bool, .@"enum" => true,
        else => X == []const u8,
    };
}

fn checkSpec(comptime s: InSpec) void {
    @setEvalBranchQuota(200_000);
    inline for (.{ .{ "path", s.path }, .{ "query", s.query }, .{ "headers", s.headers } }) |entry| {
        const T = entry[1];
        if (T == void) continue;
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".is_tuple)
            @compileError("anole.In: ." ++ entry[0] ++ " is a struct of named fields, not " ++ @typeName(T));
        for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |name, F, attrs| {
            if (attrs.@"comptime") continue;
            if (comptime std.mem.eql(u8, entry[0], "path")) {
                if (@typeInfo(F) == .optional) @compileError("anole.In: path field " ++ name ++ " is optional; a route parameter is always there");
                if (!isScalar(F)) @compileError("anole.In: path field " ++ name ++ " is a " ++ @typeName(F) ++ "; a path parameter is an integer, float, bool, enum or []const u8");
            }
            if (comptime std.mem.eql(u8, entry[0], "headers")) {
                const Inner = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
                if (!isScalar(Inner)) @compileError("anole.In: header field " ++ name ++ " is a " ++ @typeName(F) ++ "; a header is a scalar, an enum, []const u8 or an optional of those");
            }
        }
        // The mapper's own checks (scalar shapes, lists for query).
        if (comptime std.mem.eql(u8, entry[0], "path")) dusty.input.strings.check(T, .path);
        if (comptime std.mem.eql(u8, entry[0], "query")) dusty.input.strings.check(T, .query);
        if (comptime std.mem.eql(u8, entry[0], "headers")) dusty.input.strings.check(T, .headers);
        validate.assertRules(T);
    }
    if (s.body != void and @typeInfo(s.body) == .@"struct") validate.assertRules(s.body);
}

// ------------------------------------------------------------------ outputs

/// A typed handler's result written as JSON with this status (any 2xx):
/// `return .{ .value = todo };`.
pub fn WithStatus(comptime status: dusty.Status, comptime T: type) type {
    const code = @backingInt(status);
    if (code < 200 or code > 299) @compileError("anole.WithStatus takes a 2xx status, not " ++ @tagName(status));
    return struct {
        value: T,
        /// Sent as `Location` (Created).
        location: ?[]const u8 = null,

        pub const anole_status: dusty.Status = status;
        pub const Payload = T;
    };
}

/// 201 with the value as JSON and an optional `Location`:
/// `return .{ .value = todo, .location = "/todos/7" };`.
pub fn Created(comptime T: type) type {
    return WithStatus(.created, T);
}

/// 202 with the value as JSON.
pub fn Accepted(comptime T: type) type {
    return WithStatus(.accepted, T);
}

fn hasStatus(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "anole_status");
}

// ------------------------------------------------------------------ shape

/// What a handler function takes and returns, from its signature alone.
pub const Shape = struct {
    has_ctx: bool,
    takes_res: bool,
    In: ?type,
    Out: type,
    /// The error set, null for `anyerror` or an unresolvable one.
    Errors: ?type,
    /// Not (req, res) / (ctx, req, res) returning void.
    typed: bool,
};

fn paramTypes(comptime F: type) []const ?type {
    return switch (@typeInfo(F)) {
        .@"fn" => |f| f.param_types,
        else => @compileError("a handler is a function taking (*anole.Request, *anole.Response), not " ++ @typeName(F)),
    };
}

/// Reads the signature of the handler function type `F`.
pub fn shapeOf(comptime F: type) Shape {
    const info = @typeInfo(F).@"fn";
    const params = info.param_types;
    var i: usize = 0;
    // A first parameter that is neither the request nor the response is the
    // server's state.
    const has_ctx = params.len > 0 and params[0] != null and params[0].? != *dusty.Request and params[0].? != *dusty.Response and !isIn(params[0].?);
    if (has_ctx) i += 1;
    if (i >= params.len or params[i] == null or params[i].? != *dusty.Request)
        @compileError("a handler takes (*anole.Request, *anole.Response), the server's state first on a server with state, and anole.In(...) last when it has typed inputs; this one is " ++ @typeName(F));
    i += 1;
    const takes_res = i < params.len and params[i] != null and params[i].? == *dusty.Response;
    if (takes_res) i += 1;
    var InT: ?type = null;
    if (i < params.len and params[i] != null and isIn(params[i].?)) {
        InT = params[i].?;
        i += 1;
    }
    if (i != params.len)
        @compileError("a handler takes (*anole.Request, *anole.Response), the server's state first, and anole.In(...) last; parameter " ++ std.fmt.comptimePrint("{d}", .{i + 1}) ++ " of " ++ @typeName(F) ++ " is not one of those");
    const ret = info.return_type orelse @compileError("a handler must not be generic: " ++ @typeName(F));
    const payload = switch (@typeInfo(ret)) {
        .error_union => |e| e.payload,
        else => ret,
    };
    const errors: ?type = switch (@typeInfo(ret)) {
        .error_union => |e| blk: {
            if (e.error_set == anyerror) break :blk null;
            break :blk if (@typeInfo(e.error_set).error_set.error_names != null) e.error_set else null;
        },
        else => error{},
    };
    const plain = takes_res and InT == null and payload == void;
    return .{ .has_ctx = has_ctx, .takes_res = takes_res, .In = InT, .Out = payload, .Errors = errors, .typed = !plain };
}

/// What a handler takes and returns, for tools that describe routes
/// (OpenAPI): see `routeInfo`.
pub const RouteInfo = struct {
    path: type = void,
    query: type = void,
    headers: type = void,
    body: type = void,
    /// The type written as the response body: `void` for none; the
    /// payload of `Created(T)` and the like is `T`.
    output: type = void,
    /// The error set the handler declares; null for `anyerror` or one that
    /// cannot be resolved.
    errors: ?type = null,
    takes_res: bool = false,
    /// A typed handler (see the module doc), not a plain (req, res) one.
    typed: bool = false,
    no_wait: bool = false,
    cached: bool = false,
};

/// The `RouteInfo` of `handler` as `app.get` takes it (also wrapped in
/// `anole.noWait` or `anole.cached`).
pub fn routeInfo(comptime handler: anytype) RouteInfo {
    const handlers = @import("handlers.zig");
    const fp = comptime handlers.unwrap(handler);
    const F = @TypeOf(fp.*);
    const sh = shapeOf(F);
    const spec: InSpec = if (sh.In) |T| T.anole_in else .{};
    const output = if (hasStatus(sh.Out)) sh.Out.Payload else sh.Out;
    return .{
        .path = spec.path,
        .query = spec.query,
        .headers = spec.headers,
        .body = spec.body,
        .output = output,
        .errors = sh.Errors,
        .takes_res = sh.takes_res,
        .typed = sh.typed,
        .no_wait = handlers.anyNoWait(handler),
        .cached = handlers.anyCached(handler),
    };
}

// ------------------------------------------------------------------ adapter

fn bindIn(comptime InT: type, req: *dusty.Request, out: *InT) anyerror!void {
    const spec = InT.anole_in;
    if (spec.path != void) out.path = try req.bindPath(spec.path);
    var failed = false;
    if (spec.query != void) {
        if (req.bindQuery(spec.query)) |v| out.query = v else |e| switch (e) {
            error.ValidationFailed => failed = true,
            else => return e,
        }
    }
    if (spec.headers != void) {
        if (req.bindHeaders(spec.headers)) |v| out.headers = v else |e| switch (e) {
            error.ValidationFailed => failed = true,
            else => return e,
        }
    }
    if (spec.body != void) {
        if (req.bind(spec.body)) |v| out.body = v else |e| switch (e) {
            error.ValidationFailed => failed = true,
            else => return e,
        }
    }
    if (failed) return error.ValidationFailed;
}

fn writeOut(comptime sh: Shape, res: *dusty.Response, payload: sh.Out) !void {
    const Out = sh.Out;
    if (Out == void) {
        if (!sh.takes_res) res.status = .no_content;
        return;
    }
    if (comptime hasStatus(Out)) {
        if (!(sh.takes_res and res.status != .ok)) res.status = Out.anole_status;
        if (payload.location) |l| try res.header("Location", l);
        return res.json(payload.value);
    }
    return res.json(payload);
}

/// The router's handler for a typed `handler` on a server with state `Ctx`.
pub fn adapt(comptime Ctx: type, comptime handler: anytype) dusty.Router(Ctx).Handler {
    const F = @TypeOf(handler);
    const sh = comptime shapeOf(F);
    if (sh.has_ctx and (Ctx == void or paramTypes(F)[0].? != *Ctx))
        @compileError("the handler's first parameter " ++ @typeName(paramTypes(F)[0].?) ++ " is not the server's state " ++
            (if (Ctx == void) "(this server has none)" else "*" ++ @typeName(Ctx)));
    const Run = struct {
        fn exec(ctx: if (Ctx == void) void else *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            var args: std.meta.ArgsTuple(F) = undefined;
            comptime var k = 0;
            if (comptime sh.has_ctx) {
                args[k] = ctx;
                k += 1;
            }
            args[k] = req;
            k += 1;
            if (comptime sh.takes_res) {
                args[k] = res;
                k += 1;
            }
            if (comptime sh.In) |InT| {
                var in: InT = undefined;
                try bindIn(InT, req, &in);
                args[k] = in;
                k += 1;
            }
            const result = @call(.auto, handler, args);
            const payload = if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result else result;
            try writeOut(sh, res, payload);
        }
    };
    if (Ctx == void) return struct {
        fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return Run.exec({}, req, res);
        }
    }.h;
    return struct {
        fn h(ctx: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return Run.exec(ctx, req, res);
        }
    }.h;
}

// ------------------------------------------------------------------ route checks

/// The compile-time checks of one route registered with a comptime path:
/// the pattern, the handler's `In` against the route, and `cached` against
/// the method. `whole_path` is false under a group (its prefix is a
/// run-time string; `required_params` covers it at startup), where an
/// empty `path` is the group's own path.
pub fn checkRoute(comptime method: ?dusty.Method, comptime path: []const u8, comptime handler: anytype, comptime whole_path: bool) void {
    const handlers = @import("handlers.zig");
    const name = comptime (if (method) |m| upper(@tagName(m)) else "ANY");
    const where = "anole: route " ++ name ++ " " ++ path ++ ": ";
    // Under a group, "" is the group's own path (`admin.post("", ..)`).
    const group_root = !whole_path and path.len == 0;
    if (comptime !group_root) if (comptime route_pattern.problem(path)) |p| @compileError(where ++ route_pattern.comptimeMessage(p));
    if (comptime handlers.isCached(@TypeOf(handler))) {
        if (method) |m| if (m != .get and m != .head)
            @compileError(where ++ "anole.cached keeps GET and HEAD answers only; it cannot wrap a " ++ name ++ " route");
    }
    const fp = comptime handlers.unwrap(handler);
    const F = @TypeOf(fp.*);
    const sh = comptime shapeOf(F);
    const InT = sh.In orelse return;
    const spec = InT.anole_in;
    if (spec.body != void) {
        if (method) |m| if (m == .get or m == .head)
            @compileError(where ++ "anole.In .body on a " ++ name ++ " route; a " ++ name ++ " request has no body (use .query, or app.query for the QUERY method)");
    }
    if (spec.path != void) {
        const params = comptime route_pattern.paramNames(path);
        const fields = @typeInfo(spec.path).@"struct";
        inline for (fields.field_names, fields.field_types) |fname, FT| {
            const wildcard = comptime isWildcard(path, fname);
            if (wildcard and FT != []const u8)
                @compileError(where ++ "path field " ++ fname ++ " is the wildcard *" ++ fname ++ ", which is a []const u8");
            if (whole_path) {
                const found = for (params) |p| {
                    if (std.mem.eql(u8, p, fname)) break true;
                } else false;
                if (!found) @compileError(where ++ "anole.In path field \"" ++ fname ++ "\" is not a parameter of the route" ++ paramHint(params));
            }
        }
    }
}

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, &out) |c, *o| o.* = std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}

fn paramHint(comptime params: []const []const u8) []const u8 {
    if (params.len == 0) return " (the route has none)";
    var out: []const u8 = " (parameters: ";
    for (params, 0..) |p, i| out = out ++ (if (i > 0) ", " else "") ++ p;
    return out ++ ")";
}

fn isWildcard(comptime path: []const u8, comptime name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len > 1 and seg[0] == '*' and std.mem.eql(u8, seg[1..], name)) return true;
    }
    return false;
}

/// The `required_params` of a handler: its `In.path` fields.
pub fn requiredParams(comptime handler: anytype) []const []const u8 {
    const handlers = @import("handlers.zig");
    const fp = comptime handlers.unwrap(handler);
    const F = @TypeOf(fp.*);
    const sh = comptime shapeOf(F);
    const InT = sh.In orelse return &.{};
    const P = InT.anole_in.path;
    if (P == void) return &.{};
    const names = @typeInfo(P).@"struct".field_names;
    comptime var out: [names.len][]const u8 = undefined;
    inline for (names, 0..) |n, i| out[i] = n;
    const final = out;
    return &final;
}

test "In: absent keys are void" {
    const T = In(.{ .body = struct { a: u8 } });
    try std.testing.expect(isIn(T));
    try std.testing.expect(@FieldType(T, "path") == void);
    try std.testing.expect(@FieldType(T, "query") == void);
    try std.testing.expect(T.anole_in.body != void);
    try std.testing.expect(!isIn(struct {}));
}

test "shapeOf: plain and typed handlers" {
    const H = struct {
        fn plain(_: *dusty.Request, _: *dusty.Response) !void {}
        fn withState(_: *u32, _: *dusty.Request, _: *dusty.Response) void {}
        fn out(_: *dusty.Request) !u32 {
            return 1;
        }
        fn nothing(_: *dusty.Request) void {}
        fn withIn(_: *dusty.Request, _: *dusty.Response, in: In(.{ .query = struct { page: u32 = 1 } })) !void {
            _ = in;
        }
    };
    try std.testing.expect(!shapeOf(@TypeOf(H.plain)).typed);
    try std.testing.expect(shapeOf(@TypeOf(H.withState)).has_ctx);
    try std.testing.expect(!shapeOf(@TypeOf(H.withState)).typed);
    try std.testing.expect(shapeOf(@TypeOf(H.out)).typed);
    try std.testing.expect(shapeOf(@TypeOf(H.out)).Out == u32);
    try std.testing.expect(shapeOf(@TypeOf(H.nothing)).typed);
    try std.testing.expect(shapeOf(@TypeOf(H.withIn)).typed);
    try std.testing.expect(shapeOf(@TypeOf(H.withIn)).In != null);
}

test "routeInfo reflects In through noWait and cached" {
    const handlers = @import("handlers.zig");
    const H = struct {
        const Q = struct { page: u32 = 1 };
        fn list(_: *dusty.Request, in: In(.{ .query = Q })) ![]const u8 {
            _ = in;
            return "x";
        }
        fn plain(_: *dusty.Request, _: *dusty.Response) !void {}
    };
    const a = comptime routeInfo(H.list);
    try std.testing.expect(a.query == H.Q);
    try std.testing.expect(a.output == []const u8);
    try std.testing.expect(a.typed and !a.takes_res and !a.no_wait and !a.cached);
    const b = comptime routeInfo(handlers.noWait(H.list));
    try std.testing.expect(b.no_wait and b.query == H.Q);
    const c = comptime routeInfo(handlers.cached(.{}, H.list));
    try std.testing.expect(c.cached and c.query == H.Q);
    const d = comptime routeInfo(H.plain);
    try std.testing.expect(!d.typed and d.takes_res and d.output == void);
}

test "typed: Created and Accepted answer their status with the value as JSON" {
    const anole = @import("root.zig");
    const Todo = struct { id: u32 };
    const H = struct {
        fn created(_: *dusty.Request) !Created(Todo) {
            return .{ .value = .{ .id = 7 }, .location = "/todos/7" };
        }
        fn accepted(_: *dusty.Request) !Accepted(Todo) {
            return .{ .value = .{ .id = 8 } };
        }
    };
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer app.deinit();
    app.post("/created", H.created);
    app.post("/accepted", H.accepted);
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var c = try t.post("/created", .{});
    defer c.deinit();
    try c.expectStatus(.created);
    try c.expectHeader("location", "/todos/7");
    try c.expectBody("{\"id\":7}");

    var a = try t.post("/accepted", .{});
    defer a.deinit();
    try a.expectStatus(.accepted);
    try a.expectBody("{\"id\":8}");
}

// Kept (the audit's rewrite would drop it): a typed handler returning
// WithStatus(.no_content, void) does not compile (res.json of void), so the
// 204 claim has no behaviour test yet; reported, not fixed here.
test "Created and Accepted carry a status" {
    try std.testing.expect(Created(u8).anole_status == .created);
    try std.testing.expect(Accepted(u8).anole_status == .accepted);
    try std.testing.expect(WithStatus(.no_content, void).anole_status == .no_content);
}
