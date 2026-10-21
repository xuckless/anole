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

/// `handler` as the router of a `Server(Ctx)` takes it: as it is when it
/// already has that shape, or wrapped when it is a `(req, res)` handler on a
/// server with state (which it then ignores).
pub fn adapt(comptime Ctx: type, comptime handler: anytype) dusty.Router(Ctx).Handler {
    const F = @TypeOf(handler);
    if (comptime isNoWait(F)) return adapt(Ctx, F.no_wait_handler);
    if (comptime isCached(F)) return adapt(Ctx, F.cached_handler);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => @compileError("a handler is a function taking (*anole.Request, *anole.Response), not " ++ @typeName(F)),
    };
    const want = if (Ctx == void) 2 else 3;
    if (info.param_types.len == want) return handler;
    if (Ctx != void and info.param_types.len == 2) return struct {
        fn h(_: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return handler(req, res);
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
pub fn NoWait(comptime handler: anytype) type {
    if (@typeInfo(@TypeOf(handler)) != .@"fn") @compileError("anole.noWait takes a handler function, not " ++ @typeName(@TypeOf(handler)));
    return struct {
        pub const no_wait_handler = handler;
    };
}

fn isNoWait(comptime T: type) bool {
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

/// The router options a handler as `Server` takes it implies.
pub fn routeOptions(comptime handler: anytype) dusty.RouteOptions {
    const F = @TypeOf(handler);
    if (comptime isCached(F)) return routeOptions(F.cached_handler);
    return .{ .no_wait = comptime isNoWait(F) };
}

/// What a function middleware calls to run the rest of the chain (the
/// middleware after it, then the handler): `return next.call();`. Not
/// calling it ends the request with whatever the middleware put in the
/// response.
pub const Next = struct {
    executor: *anyopaque,
    next_fn: *const fn (executor: *anyopaque) anyerror!void,

    /// Runs the rest of the chain and returns its error, if any.
    pub fn call(self: Next) anyerror!void {
        return self.next_fn(self.executor);
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
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    if (params.len != 3 and params.len != 4 or params[params.len - 1] != Next)
        @compileError("a middleware function takes (*anole.Request, *anole.Response, anole.Next), or the server's state first; got " ++ @typeName(@TypeOf(f)));
    return struct {
        // Not zero-sized: the server keeps a pointer to its copy.
        _: u8 = 0,

        pub fn execute(_: *const @This(), req: *dusty.Request, res: *dusty.Response, executor: anytype) anyerror!void {
            const E = @TypeOf(executor);
            const next: Next = .{ .executor = executor, .next_fn = struct {
                fn next(p: *anyopaque) anyerror!void {
                    const e: E = @ptrCast(@alignCast(p));
                    return e.next();
                }
            }.next };
            if (params.len == 4) return f(executor.ctx, req, res, next);
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
