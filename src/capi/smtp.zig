//! `anole_smtp_*`: the configuration's mail servers ("mail") (p3/smtp,
//! design-connectors.md §5). Event 126.
//!
//! A skeleton for now: the hooks `engine.zig` calls, in their final
//! names and signatures (research/p3-pass/PLAN.md R42).
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = @import("abi.zig");

const Engine = engine.Engine;
const AnswerError = engine.AnswerError;

/// Engine-wide state (`Engine.smtp_state`).
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

/// Per executor (`Exec.smtp`): the tasks it runs are canceled at the stop.
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
