//! Handler and middleware shapes `Server` takes beside the HTTP core's own:
//! a plain `(req, res)` handler on a server with state (adapted at
//! comptime), and middleware written as a function rather than a struct.
//!
//!     fn requireKey(req: *anole.Request, _: *anole.Response, next: anole.Next) !void {
//!         if (req.headers.get("X-Api-Key") == null) return error.Unauthorized;
//!         return next.call();
//!     }
//!     app.use(requireKey);                       // or anole.func(requireKey)
//!     app.with(.{requireKey}).get("/admin", h);  // this route only
const std = @import("std");
const dusty = @import("dusty");
const ResponseCache = @import("cache/response.zig").ResponseCache;
const typed = @import("typed.zig");
const declarations = @import("openapi/declarations.zig");

/// `handler` as the router of a `Server(Ctx)` takes it: as it is when it
/// already has that shape, or wrapped when it is a `(req, res)` handler on a
/// server with state (which it then ignores).
pub fn adapt(comptime Ctx: type, comptime handler: anytype) dusty.Router(Ctx).Handler {
    const bare = comptime Peel(handler).bare;
    const F = @TypeOf(bare);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => @compileError("a handler is a function taking (*anole.Request, *anole.Response), not " ++ @typeName(F)),
    };
    // Typed inputs or output (anole.In, a result type): see typed.zig.
    if (comptime typed.shapeOf(F).typed) return typed.adapt(Ctx, bare);
    const want = if (Ctx == void) 2 else 3;
    if (info.param_types.len == want) return bare;
    if (Ctx != void and info.param_types.len == 2) return struct {
        fn h(_: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return bare(req, res);
        }
    }.h;
    @compileError("a handler takes (*anole.Request, *anole.Response)" ++
        (if (Ctx == void) "" else ", or (*" ++ @typeName(Ctx) ++ ", *anole.Request, *anole.Response) for the server's state") ++
        ", but this one is " ++ @typeName(F));
}

/// `handler`, marked as one that never waits: it answers from what it has
/// (the request and its body, the server's state, memory) without I/O,
/// sleeping, or a lock another task holds across a wait, and so does every
/// middleware that runs for its route. On HTTP/2 its requests that arrive
/// whole (body included) in one read then run on the connection's reader,
/// right after that read, rather than on a task each, and their responses
/// go out in that read's one write; on HTTP/3 those that arrive whole in
/// one packet run on the endpoint task, right after that packet:
///
///     app.get("/plaintext", anole.noWait(plaintext));
///
/// A handler that waits anyway still works, but holds up every other
/// request on its connection (on HTTP/3, its endpoint) meanwhile, and gets
/// no request timeout. Leave the mark off a handler that queries a
/// database, a cache or another service: those keep a task per request, so
/// a slow query delays nothing else. On HTTP/1.1 the mark changes nothing.
pub fn noWait(comptime handler: anytype) NoWait(handler) {
    return .{};
}

/// The type `noWait` returns: a marker the route methods recognise.
/// Given a middleware function it marks the middleware instead (`use`,
/// `group` and `with` take it).
pub fn NoWait(comptime handler: anytype) type {
    if (@typeInfo(@TypeOf(handler)) != .@"fn") @compileError("anole.noWait takes a handler function or a middleware function, not " ++ @typeName(@TypeOf(handler)));
    return struct {
        pub const no_wait_handler = handler;
    };
}

/// Whether `T` is the type `noWait` returns.
pub fn isNoWait(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "no_wait_handler");
}

/// `handler`, with its answers kept and served from memory by a
/// `ResponseCache` of the route's own (see `anole.middleware.ResponseCache`
/// for what is kept, and when not):
///
///     app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed));
///
/// A hit runs neither the handler nor anything after the cache; the
/// server's and the groups' middleware runs as for any request. Takes a
/// handler marked with `noWait` too.
pub fn cached(comptime options: ResponseCache.Options, comptime handler: anytype) Cached(options, handler) {
    return .{};
}

/// The type `cached` returns: a marker the route methods recognise.
pub fn Cached(comptime options: ResponseCache.Options, comptime handler: anytype) type {
    return struct {
        pub const cached_handler = handler;
        pub const cache_options = options;
    };
}

/// Whether `T` is the type `cached` returns.
pub fn isCached(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "cached_handler");
}

/// `handler` with the texts of its route for the OpenAPI document (summary,
/// tags, ...) and, for a plain `(req, res)` handler, its body and response
/// types. Combines with `noWait` and `cached` in any order; the texts are
/// ignored in a build without `-Dopenapi`.
///
///     app.get("/health", anole.doc(.{ .summary = "Liveness" }, health));
pub fn doc(comptime texts: declarations.RouteDoc, comptime handler: anytype) Doc(texts, handler) {
    return .{};
}

/// The type `doc` returns: a marker the route methods recognise.
pub fn Doc(comptime texts: declarations.RouteDoc, comptime handler: anytype) type {
    return struct {
        pub const doc_handler = handler;
        pub const route_doc: declarations.RouteDoc = texts;
    };
}

/// Whether `T` is the type `doc` returns.
pub fn isDoc(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "doc_handler");
}

/// What the markers around a handler say, outermost first where a marker can
/// repeat (`doc(a, doc(b, h))` is `a`).
const Marks = struct {
    no_wait: bool = false,
    cached: ?ResponseCache.Options = null,
    doc: ?declarations.RouteDoc = null,
};

/// The one walk through the handler markers: `.bare` is the function inside
/// them and `.marks` what they say. Every reader below reads this and
/// never names a marker. A new marker is one arm here and its constructor.
fn Peel(comptime handler: anytype) type {
    const F = @TypeOf(handler);
    if (isNoWait(F)) return Under(.{ .no_wait = true }, F.no_wait_handler);
    if (isCached(F)) return Under(.{ .cached = F.cache_options }, F.cached_handler);
    if (isDoc(F)) return Under(.{ .doc = F.route_doc }, F.doc_handler);
    return struct {
        pub const bare = handler;
        pub const marks: Marks = .{};
    };
}

/// `Peel(inner)` with one more marker, `own`, around it.
fn Under(comptime own: Marks, comptime inner: anytype) type {
    const in = Peel(inner);
    return struct {
        pub const bare = in.bare;
        pub const marks: Marks = .{
            .no_wait = own.no_wait or in.marks.no_wait,
            .cached = own.cached orelse in.marks.cached,
            .doc = own.doc orelse in.marks.doc,
        };
    };
}

/// The `RouteDoc` given to `doc` anywhere in the markers around `handler`
/// (all defaults when none).
pub fn routeDoc(comptime handler: anytype) declarations.RouteDoc {
    return Peel(handler).marks.doc orelse .{};
}

/// Whether any marker around `handler` is `noWait`.
pub fn anyNoWait(comptime handler: anytype) bool {
    return Peel(handler).marks.no_wait;
}

/// Whether any marker around `handler` is `cached`.
pub fn anyCached(comptime handler: anytype) bool {
    return Peel(handler).marks.cached != null;
}

/// The options of the outermost `cached` around `handler`, wherever it
/// sits among the markers; null when none.
pub fn cacheOptions(comptime handler: anytype) ?ResponseCache.Options {
    return comptime Peel(handler).marks.cached;
}

/// The router options a handler as `Server` takes it implies.
pub fn routeOptions(comptime handler: anytype) dusty.RouteOptions {
    return .{ .no_wait = comptime anyNoWait(handler), .required_params = comptime typed.requiredParams(handler) };
}

/// The function type inside `noWait` and `cached` markers (`F` itself for
/// a bare function).
pub fn Unwrapped(comptime F: type) type {
    if (@typeInfo(F) != .@"struct") return F;
    return @TypeOf(Peel(@as(F, undefined)).bare);
}

/// The handler function inside `noWait` / `cached` markers, as a pointer
/// to it: what tools that read a handler's signature (`anole.routeInfo`,
/// OpenAPI) start from.
pub fn unwrap(comptime handler: anytype) *const Unwrapped(@TypeOf(handler)) {
    return &Peel(handler).bare;
}

/// What a function middleware calls to run the rest of the chain (the
/// middleware after it, then the handler): `return next.call();`. Not
/// calling it ends the request with whatever the middleware put in the
/// response.
pub const Next = struct {
    chain: *anyopaque,
    next_fn: *const fn (chain: *anyopaque) anyerror!void,

    /// Runs the rest of the chain and returns its error, if any.
    pub fn call(self: Next) anyerror!void {
        return self.next_fn(self.chain);
    }
};

/// A middleware value from a function: `fn (req, res, next: anole.Next)
/// !void`, or `fn (state: *Ctx, req, res, next)` for a `Server(Ctx)`'s
/// state. `use`, `group` and `with` also take the bare function.
pub fn func(comptime f: anytype) Func(f) {
    return .{};
}

/// The middleware type `func` returns for `f`. A compile error when `f`
/// does not take `anole.Next` last.
pub fn Func(comptime f: anytype) type {
    return FuncMarked(f, false);
}

/// `Func(f)` that says it never waits (`pub const no_wait = true`), for
/// routes registered `no_wait`: what `app.use(anole.noWait(f))` makes.
pub fn FuncNoWait(comptime f: anytype) type {
    return FuncMarked(f, true);
}

/// Whether `f` takes `anole.Next` last: a middleware function, not a
/// handler.
pub fn isMiddlewareFn(comptime f: anytype) bool {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return (params.len == 3 or params.len == 4) and params[params.len - 1] == Next;
}

fn FuncMarked(comptime f: anytype, comptime never_waits: bool) type {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    if (params.len != 3 and params.len != 4 or params[params.len - 1] != Next)
        @compileError("a middleware function takes (*anole.Request, *anole.Response, anole.Next), or the server's state first; got " ++ @typeName(@TypeOf(f)));
    return struct {
        // Not zero-sized: the server keeps a pointer to its copy.
        _: u8 = 0,

        pub const no_wait = never_waits;

        pub fn execute(_: *const @This(), req: *dusty.Request, res: *dusty.Response, chain: anytype) anyerror!void {
            const E = @TypeOf(chain);
            const next: Next = .{ .chain = chain, .next_fn = struct {
                fn call(p: *anyopaque) anyerror!void {
                    const e: E = @ptrCast(@alignCast(p));
                    return e.call();
                }
            }.call };
            if (params.len == 4) return f(chain.ctx, req, res, next);
            return f(req, res, next);
        }
    };
}

/// Whether `value` is a function, which `use`, `group` and `with` take as
/// a function middleware.
pub fn isFn(comptime T: type) bool {
    return @typeInfo(T) == .@"fn";
}

test "adapt: a (req, res) handler on a server with state" {
    const State = struct { n: u32 };
    const H = struct {
        fn plain(_: *dusty.Request, res: *dusty.Response) !void {
            res.status = .accepted;
        }
        fn stateful(s: *State, _: *dusty.Request, res: *dusty.Response) !void {
            res.status = @fromBackingInt(@intCast(s.n));
        }
    };
    const a: dusty.Router(State).Handler = adapt(State, H.plain);
    const b: dusty.Router(State).Handler = adapt(State, H.stateful);
    const c: dusty.Router(void).Handler = adapt(void, H.plain);
    _ = .{ a, b, c };
}

test "noWait: the handler adapts as it is, and marks its route" {
    const State = struct { n: u32 };
    const H = struct {
        fn plain(_: *dusty.Request, res: *dusty.Response) !void {
            res.status = .accepted;
        }
    };
    const a: dusty.Router(State).Handler = adapt(State, noWait(H.plain));
    _ = a;
    try std.testing.expect(routeOptions(noWait(H.plain)).no_wait);
    try std.testing.expect(!routeOptions(H.plain).no_wait);
}

test "peel: every nesting of the handler markers answers as before" {
    const H = struct {
        fn h(_: *dusty.Request, in: typed.In(.{ .path = struct { id: u64 } })) ![]const u8 {
            _ = in;
            return "x";
        }
    };
    const h = H.h;
    const N = noWait(h);
    // Row: marked handler, no_wait, outermost cache max_entries (0: none), outermost doc summary ("": none).
    const rows = .{
        .{ h, false, 0, "" },
        .{ N, true, 0, "" },
        .{ cached(.{ .max_entries = 1 }, h), false, 1, "" },
        .{ doc(.{ .summary = "d1" }, h), false, 0, "d1" },
        .{ cached(.{ .max_entries = 1 }, N), true, 1, "" },
        .{ doc(.{ .summary = "d1" }, N), true, 0, "d1" },
        .{ cached(.{ .max_entries = 1 }, doc(.{ .summary = "d1" }, h)), false, 1, "d1" },
        .{ doc(.{ .summary = "d1" }, cached(.{ .max_entries = 1 }, h)), false, 1, "d1" },
        .{ cached(.{ .max_entries = 1 }, doc(.{ .summary = "d1" }, N)), true, 1, "d1" },
        .{ doc(.{ .summary = "d1" }, cached(.{ .max_entries = 1 }, N)), true, 1, "d1" },
        .{ doc(.{ .summary = "d1" }, doc(.{ .summary = "d2" }, h)), false, 0, "d1" },
        .{ cached(.{ .max_entries = 1 }, cached(.{ .max_entries = 2 }, h)), false, 1, "" },
    };
    inline for (rows) |row| {
        const m = comptime Peel(row[0]).marks;
        try std.testing.expectEqual(row[1], anyNoWait(row[0]));
        try std.testing.expectEqual(row[1], routeOptions(row[0]).no_wait);
        try std.testing.expectEqual(row[2] != 0, anyCached(row[0]));
        try std.testing.expectEqual(row[2], if (m.cached) |c| c.max_entries else 0);
        try std.testing.expectEqual(row[2], if (cacheOptions(row[0])) |c| c.max_entries else 0);
        try std.testing.expectEqualStrings(row[3], routeDoc(row[0]).summary orelse "");
        try std.testing.expectEqualStrings("id", routeOptions(row[0]).required_params[0]);
        try std.testing.expect(@TypeOf(unwrap(row[0])) == *const @TypeOf(h));
        try std.testing.expect(Unwrapped(@TypeOf(row[0])) == @TypeOf(h));
    }
}
