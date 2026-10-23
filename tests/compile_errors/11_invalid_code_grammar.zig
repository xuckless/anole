//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn inner(req: *anole.Request) !void {
    return req.invalid(null, "Bad", "x");
}
export fn probe(req: *anole.Request) void {
    inner(req) catch {};
}
