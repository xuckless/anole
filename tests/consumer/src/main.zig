const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{ .logFn = anole.logFn };

const Call = anole.grpc.Call;

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "hello";
}

fn sayHello(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = 8080 },
        .https = .{ .port = 8443, .cert = .dev_self_signed },
    }, {});
    defer app.deinit();
    app.get("/hello", hello);
    anole.grpc.register(void, app.router, pb.Greeter(Call, anyerror), .{ .SayHello = sayHello });
    try app.run();
}
