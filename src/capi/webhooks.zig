//! `anole_webhooks_*`: webhooks out, delivered as jobs, and the
//! `webhook_verify` middleware's configuration (p3/webhooks, design-jobs.md
//! phase W). Events 109-110.
//!
//! A skeleton for now: the hooks `engine.zig` calls, in their final
//! names and signatures (research/p3-pass/PLAN.md R42).
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = @import("abi.zig");

const Engine = engine.Engine;
const AnswerError = engine.AnswerError;
const db = @import("db.zig");

/// Engine-wide state (`Engine.webhooks_state`).
pub const State = struct {
    pub fn init(s: *State, first_gen: u32) void {
        _ = s;
        _ = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        _ = s;
    }
};

/// Per executor (`Exec.webhooks`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    pub fn cancel(st: *ExecState, io: std.Io) void {
        _ = st;
        _ = io;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        _ = st;
        return 0;
    }

    pub fn deinit(st: *ExecState) void {
        _ = st;
    }
};

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    _ = e;
    _ = app;
}

/// The drain started (`anole_server_drain`, once).
pub fn draining(e: *Engine) void {
    _ = e;
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    _ = e;
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    _ = e;
}

/// A ``webhook_publish`` call queued on an open transaction (`db.TxWhat`), run in
/// order on the transaction's connection.
pub fn txOp(any: *db.AnyTx, ctx: *anole.db.Ctx, op: *const db.TxOp, answer: *db.Answer) anyerror!void {
    _ = any;
    _ = ctx;
    _ = op;
    _ = answer;
    return error.Unsupported;
}
