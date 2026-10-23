//! Webhooks (`-Dwebhooks`): Standard Webhooks delivery to endpoints as jobs,
//! and the `Verify` middleware for incoming ones (p3/webhooks, design-
//! jobs.md).

pub const sign = @import("sign.zig");
pub const standard = sign;
pub const dedup = @import("dedup.zig");
pub const verify = @import("verify.zig");
pub const Verify = verify.Verify;
pub const inbound = verify.inbound;
pub const Inbound = verify.Inbound;

test {
    _ = sign;
    _ = dedup;
    _ = verify;
}
