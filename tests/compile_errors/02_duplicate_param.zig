//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
export fn probe() void {
    var app: anole.App = undefined;
    app.get("/a/:id/b/:id", h);
}
