//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
const T = anole.In(.{ .bdy = struct { a: u8 } });
comptime {
    _ = T;
}
