//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
fn show(_: *anole.Request, in: anole.In(.{ .path = struct { uid: u64 } })) !void {
    _ = in;
}
export fn probe() void {
    var app: anole.App = undefined;
    app.get("/users/:id", show);
}
