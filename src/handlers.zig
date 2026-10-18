//! Handler and middleware shapes `Server` takes beside dusty's own: a plain
//! `(req, res)` handler on a server with state (adapted at comptime), and
//! middleware written as a function rather than a struct.
//!
//!     fn requireKey(req: *anole.Request, _: *anole.Response, next: anole.Next) !void {
//!         if (req.headers.get("X-Api-Key") == null) return error.Unauthorized;
//!         return next.call();
//!     }
//!     app.use(requireKey);                       // or anole.func(requireKey)
//!     app.with(.{requireKey}).get("/admin", h);  // this route only
const std = @import("std");
const dusty = @import("dusty");

/// `handler` as the router of a `Server(Ctx)` takes it: as it is when it
/// already has that shape, or wrapped when it is a `(req, res)` handler on a
/// server with state (which it then ignores).
pub fn adapt(comptime Ctx: type, comptime handler: anytype) dusty.Router(Ctx).Handler {
    const F = @TypeOf(handler);
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

/// What a function middleware calls to run the rest of the chain (the
/// middleware after it, then the handler): `return next.call();`. Not
/// calling it ends the request with whatever the middleware put in the
/// response.
pub const Next = struct {
    executor: *anyopaque,
    next_fn: *const fn (executor: *anyopaque) anyerror!void,

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
            res.status = @enumFromInt(s.n);
        }
    };
    const a: dusty.Router(State).Handler = adapt(State, H.plain);
    const b: dusty.Router(State).Handler = adapt(State, H.stateful);
    const c: dusty.Router(void).Handler = adapt(void, H.plain);
    _ = .{ a, b, c };
}
