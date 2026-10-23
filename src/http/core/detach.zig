//! Detached responses: a request whose handler returns before its answer
//! is known, finished later on the same executor with no task waiting for
//! it. Anole's C ABI hands a request to another thread (a Node or Python
//! consumer) and gets the reply back much later; over HTTP/2 and HTTP/3,
//! where a request that arrived whole runs on the connection's reader
//! (`RouteOptions.no_wait`), a handler that waited would hold up the whole
//! connection, and one task per request costs about half the throughput.
//! So the handler detaches instead: `res.detach(...)` returns a `Detached`,
//! the handler returns, and whoever has the answer calls `finish` on the
//! request's executor, which writes the response through the engine.
//!
//! Only some requests can detach (`Response.canDetach`): the engine must
//! support it (HTTP/2 and HTTP/3 on the reader; never HTTP/1.1, whose
//! connection task is the request's), and every middleware the request
//! passed must be detach-safe: one that does work after `next.call()`
//! returns would do it on the unanswered response. A middleware says it is
//! safe with `pub const detach_safe = true;`, either because it does
//! nothing after `next()` or because it moves that work into `onFinish`
//! when `res.isDetached()`.
const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const hooks = @import("hooks.zig");

pub const Detached = struct {
    request: *Request,
    response: *Response,
    engine: *const Engine,
    engine_ctx: *anyopaque,
    owner: Owner,
    /// Work middleware put off until the answer (`Response.onFinish`), in
    /// the order registered: the innermost middleware first, as an
    /// unwinding chain would run it.
    first: ?*Finisher = null,
    last: ?*Finisher = null,
    state: State = .detached,
    /// When the handler started, for the live console (`hooks.begin`); 0
    /// when no console collected then.
    console_start_ns: u64 = 0,

    pub const State = enum {
        /// Waiting for `finish`, with no task.
        detached,
        /// On a task the owner spawned (`attach`), which ends it with
        /// `finish`.
        attached,
        /// `finish` ran, or the engine aborted it.
        ended,
    };

    /// What the engine (HTTP/2, HTTP/3) provides.
    pub const Engine = struct {
        /// Moves the request and the response off the stack they were made
        /// on (the reader's: a request that is not detached costs no
        /// allocation and stays in warm memory) into memory that lives as
        /// long as the request, setting `d.request` and `d.response` to
        /// the moved ones. Returns the new `engine_ctx`. From `detach`, on
        /// the request's executor; the handler and every middleware go on
        /// with the old pair, which `detached` still marks.
        relocate: *const fn (d: *Detached) error{OutOfMemory}!*anyopaque,
        /// Ends the exchange: writes `d.response` when `result` is not an
        /// error, else handles the error as a handler's (a reset, a 500),
        /// then lets the engine free the request. On the request's
        /// executor.
        end: *const fn (d: *Detached, result: anyerror!void) void,
        /// The response will be written by a task from now on, which may
        /// wait (for the peer, for more body). Returns the group to spawn
        /// that task into, `.local` (the connection's, so the connection's
        /// end cancels it), or null once the connection's tasks are over
        /// (the owner then calls `finish` with an error). On the request's
        /// executor.
        attach: *const fn (d: *Detached) ?*std.Io.Group,
        /// First thing in the attached task: the engine notes the task, to
        /// cancel it when the peer resets the stream.
        enter: *const fn (d: *Detached) void,
    };

    /// The detacher's side.
    pub const Owner = struct {
        /// The request went away before `finish`: its connection ended, or
        /// its stream was reset. Called by the engine on the request's
        /// executor, never while attached (the task is canceled instead).
        /// Once it returns, the owner must not touch the request, the
        /// response or the `Detached` again.
        abort: *const fn (ctx: *anyopaque) void,
        ctx: *anyopaque,
    };

    /// Work a middleware put off until the response is known.
    pub const Finisher = struct {
        next: ?*Finisher = null,
        func: *const fn (f: *Finisher, req: *Request, res: *Response, result: anyerror!void) void,
    };

    /// Ends the request: the put-off middleware work, then the response
    /// written (or `result`'s error handled). On the request's executor;
    /// once.
    pub fn finish(d: *Detached, result: anyerror!void) void {
        std.debug.assert(d.state != .ended);
        d.state = .ended;
        var it = d.first;
        while (it) |f| {
            it = f.next;
            f.func(f, d.request, d.response, result);
        }
        hooks.finished(d, result);
        d.engine.end(d, result);
    }

    /// The response needs a task (a streamed body, a file): returns the
    /// group to spawn it into, `.local`. The task calls `enter` first and
    /// `finish` last. Null when the connection can take no more tasks: the
    /// caller calls `finish` (with an error) itself.
    pub fn attach(d: *Detached) ?*std.Io.Group {
        std.debug.assert(d.state == .detached);
        d.state = .attached;
        return d.engine.attach(d);
    }

    /// First thing in the task `attach` was for.
    pub fn enter(d: *Detached) void {
        d.engine.enter(d);
    }

    /// The engine's side of an abort: tells the owner, once.
    pub fn abort(d: *Detached) void {
        if (d.state != .detached) return;
        d.state = .ended;
        d.owner.abort(d.owner.ctx);
    }
};
