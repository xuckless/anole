//! A route or call the compiler must refuse (zig build test-compile-errors).
const anole = @import("anole");
fn h(_: *anole.Request, _: *anole.Response) !void {}
const v = anole.validate;
const Dto = struct {
    pair: [2]i32,
    user_name: []const u8,
    pub const field_rules = .{ .user_name = v.rename("userName") };
};
export fn probe(req: *anole.Request) void {
    _ = req.bind(Dto) catch {};
}
