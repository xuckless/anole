//! `anole_net_*`: raw TCP and UDP listeners whose connections and datagrams
//! go to a consumer (p3/net, design-net.md §6.4). Handle kinds 10
//! (`anole_net_conn`) and 11 (`anole_net_udp`); events 96-100.
//!
//! A skeleton for now: the hooks `engine.zig` calls, in their final
//! names and signatures (research/p3-pass/PLAN.md R42).
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = @import("abi.zig");

const Engine = engine.Engine;
const AnswerError = engine.AnswerError;

/// Engine-wide state (`Engine.net_state`).
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

/// Per executor (`Exec.net`): the tasks it runs are canceled at the stop.
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

/// `anole_handle_release` for the kinds `net_conn` and `net_udp` (a cleanup call: a handle that is
/// over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    _ = e;
    _ = hv;
    return error.Over;
}

/// Fills this area's fields of `anole_stats`.
pub fn stats(e: *Engine, out: *abi.Stats) void {
    _ = e;
    _ = out;
}
