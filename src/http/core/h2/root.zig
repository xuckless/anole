//! Anole's own HTTP/2 protocol core (research/h2h3-takeover/PLAN.md §3.1),
//! the codecs first: frames, request field checks and the flood limits.
//! Pure Zig, nothing linked.

pub const frame = @import("frame.zig");
pub const fields = @import("fields.zig");
pub const limits = @import("limits.zig");

test {
    _ = frame;
    _ = fields;
    _ = limits;
    _ = @import("frame_test.zig");
    _ = @import("fields_test.zig");
    _ = @import("limits_test.zig");
}
