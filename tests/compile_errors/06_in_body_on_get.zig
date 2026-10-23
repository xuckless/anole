//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
const Body = struct { a: u8 };
fn read(_: *anole.Request, in: anole.In(.{ .body = Body })) !void {
    _ = in;
}
export fn probe() void {
    var app: anole.App = undefined;
    app.get("/read", read);
}
