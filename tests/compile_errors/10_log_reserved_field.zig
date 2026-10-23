//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
export fn probe() void {
    anole.log.info("x", .{ .level = 1 });
}
