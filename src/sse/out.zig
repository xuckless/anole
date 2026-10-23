//! Where a subscriber's bytes go (internal). The same six operations as
//! `dusty.Parked`: the real one (a parked stream), the fallback (the
//! handler's own task writes through the response's body writer, when the
//! stream cannot park), and the tests' fake.

const std = @import("std");
const dusty = @import("dusty");

const Parked = dusty.Parked;

pub const WriteError = Parked.WriteError;

pub const Out = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (ptr: *anyopaque) bool,
        write: *const fn (ptr: *anyopaque, parts: []const []const u8) WriteError!void,
        endBurst: *const fn (ptr: *anyopaque) void,
        end: *const fn (ptr: *anyopaque) void,
        abort: *const fn (ptr: *anyopaque) void,
        release: *const fn (ptr: *anyopaque) void,
    };

    pub fn begin(o: Out) bool {
        return o.vtable.begin(o.ptr);
    }
    pub fn write(o: Out, parts: []const []const u8) WriteError!void {
        return o.vtable.write(o.ptr, parts);
    }
    pub fn endBurst(o: Out) void {
        return o.vtable.endBurst(o.ptr);
    }
    pub fn end(o: Out) void {
        return o.vtable.end(o.ptr);
    }
    pub fn abort(o: Out) void {
        return o.vtable.abort(o.ptr);
    }
    pub fn release(o: Out) void {
        return o.vtable.release(o.ptr);
    }

    /// A parked stream.
    pub fn fromParked(p: *Parked) Out {
        return .{ .ptr = p, .vtable = &parked_vtable };
    }

    const parked_vtable: VTable = .{
        .begin = struct {
            fn f(ptr: *anyopaque) bool {
                return parkedOf(ptr).begin();
            }
        }.f,
        .write = struct {
            fn f(ptr: *anyopaque, parts: []const []const u8) WriteError!void {
                return parkedOf(ptr).write(parts);
            }
        }.f,
        .endBurst = struct {
            fn f(ptr: *anyopaque) void {
                parkedOf(ptr).endBurst();
            }
        }.f,
        .end = struct {
            fn f(ptr: *anyopaque) void {
                parkedOf(ptr).end();
            }
        }.f,
        .abort = struct {
            fn f(ptr: *anyopaque) void {
                parkedOf(ptr).abort();
            }
        }.f,
        .release = struct {
            fn f(ptr: *anyopaque) void {
                parkedOf(ptr).release();
            }
        }.f,
    };

    fn parkedOf(ptr: *anyopaque) *Parked {
        return @ptrCast(@alignCast(ptr));
    }
};

/// The fallback: the handler's task writes through the response's body
/// writer. `end` ends the body; `abort` makes the handler return
/// `error.ResponseAborted` (`aborted`).
pub const Fallback = struct {
    res: *dusty.Response,
    body: dusty.StreamingBodyWriter,
    ended: bool = false,
    aborted: bool = false,

    pub fn out(self: *Fallback) Out {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Out.VTable = .{
        .begin = begin,
        .write = write,
        .endBurst = endBurst,
        .end = end,
        .abort = abort,
        .release = release,
    };

    fn of(ptr: *anyopaque) *Fallback {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(ptr: *anyopaque) bool {
        const self = of(ptr);
        return !self.ended and !self.aborted;
    }

    fn write(ptr: *anyopaque, parts: []const []const u8) WriteError!void {
        const self = of(ptr);
        if (self.ended or self.aborted) return error.Gone;
        const w = &self.body.interface;
        for (parts) |part| w.writeAll(part) catch return self.failed();
        w.flush() catch return self.failed();
    }

    fn failed(self: *Fallback) WriteError {
        if (self.res.peerGone()) return error.Gone;
        return error.Gone;
    }

    fn endBurst(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn end(ptr: *anyopaque) void {
        const self = of(ptr);
        if (self.ended) return;
        self.ended = true;
        self.body.end() catch {};
    }

    fn abort(ptr: *anyopaque) void {
        of(ptr).aborted = true;
    }

    fn release(ptr: *anyopaque) void {
        _ = ptr;
    }
};

/// For tests: records what is written, and can hold a write until released.
pub const Fake = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Every `write` call, its parts concatenated.
    writes: std.ArrayList([]u8) = .empty,
    /// All bytes written, in order.
    bytes: std.ArrayList(u8) = .empty,
    ended: bool = false,
    aborted: bool = false,
    released: bool = false,
    bursts: u32 = 0,
    open_bursts: u32 = 0,
    /// While set, `write` waits (cancelably) before recording.
    hold: bool = false,
    held: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    /// The next `write` fails with this.
    fail_with: ?WriteError = null,
    writes_done: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Fake {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Fake) void {
        for (self.writes.items) |w| self.gpa.free(w);
        self.writes.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
    }

    pub fn out(self: *Fake) Out {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Lets a held write go on.
    pub fn open(self: *Fake) void {
        self.hold = false;
        self.gate.set(self.io);
    }

    const vtable: Out.VTable = .{
        .begin = begin,
        .write = write,
        .endBurst = endBurst,
        .end = end,
        .abort = abort,
        .release = release,
    };

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(ptr: *anyopaque) bool {
        const self = of(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ended or self.aborted) return false;
        self.bursts += 1;
        self.open_bursts += 1;
        return true;
    }

    fn write(ptr: *anyopaque, parts: []const []const u8) WriteError!void {
        const self = of(ptr);
        if (self.hold) {
            self.held.set(self.io);
            self.gate.wait(self.io) catch return error.Canceled;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fail_with) |e| {
            self.fail_with = null;
            return e;
        }
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const copy = self.gpa.alloc(u8, total) catch return error.SystemResources;
        var at: usize = 0;
        for (parts) |p| {
            @memcpy(copy[at..][0..p.len], p);
            at += p.len;
        }
        self.bytes.appendSlice(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.SystemResources;
        };
        self.writes.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.SystemResources;
        };
        _ = self.writes_done.fetchAdd(1, .release);
    }

    fn endBurst(ptr: *anyopaque) void {
        const self = of(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.open_bursts -= 1;
    }

    fn end(ptr: *anyopaque) void {
        const self = of(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ended = true;
        self.open_bursts -|= 1;
    }

    fn abort(ptr: *anyopaque) void {
        const self = of(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.aborted = true;
        self.open_bursts -|= 1;
    }

    fn release(ptr: *anyopaque) void {
        const self = of(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.released = true;
    }
};
