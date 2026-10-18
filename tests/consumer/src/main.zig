const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "hello";
}

fn sayHello(call: *anole.grpc.Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/hello", hello);
    app.grpc(pb.Greeter, .{ .SayHello = sayHello });
    _ = app.grpcHealth();
    try app.listenTls(":8443", .dev_self_signed);
}
