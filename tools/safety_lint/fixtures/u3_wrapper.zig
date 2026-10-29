// lint-path: src/safety/u3_wrapper.zig
// A wrapper module: casts and undefined are its job.
fn casts(p: *anyopaque) *u32 {
    var n: u32 = undefined;
    n = 0;
    return @ptrCast(@alignCast(p));
}
