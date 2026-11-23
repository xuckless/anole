//! The streamed body's block writer, shared by the server engine's
//! `StreamSink` (server.zig) and the client's `Stream` (src/h2/client.zig):
//! a body goes out of two blocks filled in turn, each handed to
//! `Conn.submitData` as one DATA part by reference, never copied. The lend
//! lifecycle, stated once here (out.zig's borrow contract, :1-21):
//!
//!   1. A block (`Lend`, table below) is borrowed by `out` from the submit
//!      until it is framed (the stream's queue no longer holds it) and
//!      written (`out.sent_total` past a mark taken once framed). Only then
//!      does `Pair.roomFree` hand it back to the writer.
//!   2. A closed stream whose bytes `out` may still borrow is parked
//!      (`Retire`) and its memory kept until `sent_total` passes the mark
//!      taken at the close.
//!   3. Once the connection is gone nothing writes: no block is handed back
//!      to the writer (each role's own guard before `roomFree`), and every
//!      parked stream is freed at once (`Retire.popPassed` with `maxInt`).
//!   4. The server's reader-run stream never waits for a block: it hands
//!      each submitted block to `EStream.spent`, freed with the stream.
//!
//! Each role keeps its own waiting (the server's `room` Signal, the client's
//! deadline-aware `waitRoom`) and its own part storage.

const std = @import("std");
const Out = @import("out.zig").Out;

/// Where one block is, as `out` sees it. Every change is a cell below, made
/// in `Pair.lend` or `Pair.roomFree`; add a state or a row, not a flag
/// beside it.
///
/// | state \ event | lend      | framed (queue no longer holds it) | written (sent_total >= mark) |
/// |---------------|-----------|-----------------------------------|------------------------------|
/// | free          | submitted | -                                 | -                            |
/// | submitted     | never     | framed(out.mark())                | - (no mark yet: its bytes may not be in `out`) |
/// | framed(mark)  | never     | - (the mark is not retaken)       | free                         |
///
/// "never": the writer fills only `Pair.current()`, which `roomFree` proved
/// free (asserted in `lend`).
pub const Lend = union(enum) { free, submitted, framed: u64 };

pub const Block = struct {
    mem: []u8 = &.{},
    lend: Lend = .free,
};

/// The two blocks; the writer fills `blocks[cur]`.
pub const Pair = struct {
    blocks: [2]Block = .{ .{}, .{} },
    cur: u1 = 0,

    pub fn current(p: *Pair) *Block {
        return &p.blocks[p.cur];
    }

    /// The writer's block went to `submitData`: it is lent, and the writer
    /// moves to the other one.
    pub fn lend(p: *Pair) void {
        std.debug.assert(p.current().lend == .free);
        p.current().lend = .submitted;
        p.cur ^= 1;
    }

    /// Whether `current()` is free, advancing its `Lend` by what `out` and
    /// the stream's queue of DATA (`pending`) show (so it mutates). Blocks
    /// go in order, the other one after it: the current one is framed once
    /// the queue holds no more than the other. Under the connection's lock.
    pub fn roomFree(p: *Pair, pending: *const std.DoublyLinkedList, out: *const Out) bool {
        const b = p.current();
        sw: switch (b.lend) {
            .free => return true,
            .submitted => {
                var queued: usize = 0;
                var it = pending.first;
                while (it) |n| : (it = n.next) queued += 1;
                const after: usize = if (p.blocks[p.cur ^ 1].lend != .free) 1 else 0;
                if (queued > after) return false;
                b.lend = .{ .framed = out.mark() };
                continue :sw b.lend;
            },
            .framed => |mark| {
                if (out.sent_total < mark) return false;
                b.lend = .free;
                return true;
            },
        }
    }

    /// Some block may still be borrowed by `out`.
    pub fn lent(p: *const Pair) bool {
        return p.blocks[0].lend != .free or p.blocks[1].lend != .free;
    }
};

/// A closed stream's place in its connection's `retiring` list: `mark` is
/// null until `park`, set while in the list, null again once `popPassed`
/// returned it.
pub const Retire = struct {
    node: std.DoublyLinkedList.Node = .{},
    mark: ?u64 = null,

    /// Queues the owner on `list` when `out` still borrows what was queued
    /// so far; whether it did.
    pub fn park(r: *Retire, list: *std.DoublyLinkedList, out: *const Out) bool {
        const mark = out.mark();
        if (out.sent_total >= mark) return false;
        r.mark = mark;
        list.append(&r.node);
        return true;
    }

    /// The first parked owner, taken off `list` once `sent` passed its
    /// mark; null otherwise (owners leave in list order). `maxInt(u64)`
    /// takes every one (the connection is gone: nothing writes).
    pub fn popPassed(list: *std.DoublyLinkedList, sent: u64) ?*Retire {
        const node = list.first orelse return null;
        const r: *Retire = @fieldParentPtr("node", node);
        if (r.mark.? > sent) return null;
        _ = list.popFirst();
        r.mark = null;
        return r;
    }
};
