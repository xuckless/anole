//! JSON transcoding (`google.api.http`) against the generated Library test
//! service (tests/grpc/proto/transcode.proto): the request decoder, the
//! response encoder, and end to end over HTTP/1.1 and HTTP/2.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const pb = @import("anole_transcode_pb");
const grpc = @import("root.zig");
const transcode = @import("transcode.zig");
const features = @import("build_options");

const Library = pb.Library(grpc.Call, anyerror);
const Capture = transcode.Capture;

fn decode(comptime Req: type, arena: std.mem.Allocator, comptime body: []const u8, body_text: []const u8, captures: []const Capture, query: []const u8) !Req {
    var diag: transcode.Diagnostic = .{};
    return transcode.decodeRequest(Req, arena, body, body_text, captures, query, &diag) catch |err| {
        if (err == error.InvalidArgument) std.debug.print("invalid: {s}\n", .{diag.message});
        return err;
    };
}

test "transcoding: the request from path variables and query parameters" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try decode(pb.GetBookRequest, a, "", "", &.{
        .{ .field = "name", .raw = "shelves/s%201/books/b%2F2", .multi = true },
    }, "view=FULL&shade=DARK&tags=a&tags=b+c&author.name=Ada&author.born=1815&revision=42" ++
        "&full=true&score=2.5&since=2024-01-02T03:04:05Z&token=aGk%3D&pages=1&pages=2&big=18446744073709551615" ++
        "&unknown=1&author.unknown=x&name=ignored");
    try std.testing.expectEqualStrings("shelves/s 1/books/b%2F2", r.name);
    try std.testing.expectEqualStrings("FULL", r.view);
    try std.testing.expectEqual(pb.Shade.DARK, r.shade);
    try std.testing.expectEqual(@as(usize, 2), r.tags.items.len);
    try std.testing.expectEqualStrings("b c", r.tags.items[1]);
    try std.testing.expectEqualStrings("Ada", r.author.?.name);
    try std.testing.expectEqual(@as(i32, 1815), r.author.?.born);
    try std.testing.expectEqual(@as(i64, 42), r.revision);
    try std.testing.expect(r.full);
    try std.testing.expectEqual(@as(f64, 2.5), r.score);
    try std.testing.expectEqual(@as(i64, 1704164645), r.since.?.seconds);
    try std.testing.expectEqualStrings("hi", r.token);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, r.pages.items);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), r.big);

    // JSON names work as well as proto names; enums by number.
    const j = try decode(pb.CreateBookRequest, a, "book", "{\"title\":\"T\",\"tags\":[\"x\"]}", &.{
        .{ .field = "parent", .raw = "shelves/1", .multi = true },
    }, "bookId=b7&book.title=ignored");
    try std.testing.expectEqualStrings("shelves/1", j.parent);
    try std.testing.expectEqualStrings("b7", j.book_id);
    try std.testing.expectEqualStrings("T", j.book.?.title);

    const e = try decode(pb.GetBookRequest, a, "", "", &.{}, "shade=1&score=-Infinity");
    try std.testing.expectEqual(pb.Shade.LIGHT, e.shade);
    try std.testing.expect(std.math.isNegativeInf(e.score));
    try std.testing.expect(std.math.isNan((try decode(pb.GetBookRequest, a, "", "", &.{}, "score=NaN")).score));

    // A path variable inside the body field wins over the body.
    const u = try decode(pb.UpdateBookRequest, a, "book", "{\"name\":\"other\",\"title\":\"New\"}", &.{
        .{ .field = "book.name", .raw = "shelves/1/books/2", .multi = true },
    }, "mask=title");
    try std.testing.expectEqualStrings("shelves/1/books/2", u.book.?.name);
    try std.testing.expectEqualStrings("New", u.book.?.title);
    try std.testing.expectEqualStrings("title", u.mask);

    // body "*": everything from the body, the path over it, no query.
    const w = try decode(pb.GetBookRequest, a, "*", "{\"view\":\"V\",\"name\":\"body\"}", &.{
        .{ .field = "name", .raw = "n", .multi = false },
    }, "view=query");
    try std.testing.expectEqualStrings("n", w.name);
    try std.testing.expectEqualStrings("V", w.view);
    const empty = try decode(pb.GetBookRequest, a, "*", "", &.{}, "");
    try std.testing.expectEqualStrings("", empty.name);
}

/// 200 arrays deep.
const deep_body = blk: {
    var b: [400]u8 = undefined;
    @memset(b[0..200], '[');
    @memset(b[200..], ']');
    break :blk b;
};

test "transcoding: requests that do not make a message" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: transcode.Diagnostic = .{};
    const cases = [_]struct { body: []const u8, query: []const u8 }{
        .{ .body = "", .query = "full=yes" },
        .{ .body = "", .query = "revision=ten" },
        .{ .body = "", .query = "shade=PURPLE" },
        .{ .body = "", .query = "author=x" },
        .{ .body = "", .query = "view=%zz" },
        .{ .body = "", .query = "since=yesterday" },
        .{ .body = "{", .query = "" },
        .{ .body = "[1]", .query = "" },
        .{ .body = "{\"revision\":\"x\"}", .query = "" },
        .{ .body = &deep_body, .query = "" },
    };
    for (cases) |c| {
        const body: []const u8 = if (c.body.len > 0) "*" else "";
        _ = body;
        if (c.body.len > 0) {
            try std.testing.expectError(error.InvalidArgument, transcode.decodeRequest(pb.GetBookRequest, a, "*", c.body, &.{.{ .field = "name", .raw = "x", .multi = false }}, c.query, &diag));
        } else {
            try std.testing.expectError(error.InvalidArgument, transcode.decodeRequest(pb.GetBookRequest, a, "", "", &.{}, c.query, &diag));
        }
    }
    try std.testing.expectError(error.InvalidArgument, transcode.decodeRequest(pb.GetBookRequest, a, "", "", &.{
        .{ .field = "name", .raw = "a%2", .multi = false },
    }, "", &diag));
}

test "transcoding: a Timestamp out of range is an invalid argument" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: transcode.Diagnostic = .{};
    for ([_][]const u8{ "since=2024-03-00T00:00:00Z", "since=2024-02-30T00:00:00Z", "since=2024-13-01T00:00:00Z" }) |query| {
        try std.testing.expectError(error.InvalidArgument, transcode.decodeRequest(pb.GetBookRequest, a, "", "", &.{}, query, &diag));
    }
    try std.testing.expectError(error.InvalidArgument, transcode.decodeRequest(pb.GetBookRequest, a, "*", "{\"since\":\"2024-03-00T00:00:00Z\"}", &.{}, "", &diag));
}

test "transcoding: the response, whole or one field" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var books: std.ArrayList(pb.Book) = .empty;
    try books.append(a, .{ .name = "a", .pages = 3, .edition = .{ .isbn = "978" } });
    const list: pb.ListBooksResponse = .{ .books = books, .next_page_token = "t" };
    try std.testing.expectEqualStrings(
        "{\"books\":[{\"name\":\"a\",\"pages\":\"3\",\"isbn\":\"978\"}],\"nextPageToken\":\"t\"}",
        try transcode.encodeResponse(pb.ListBooksResponse, a, list, ""),
    );
    try std.testing.expectEqualStrings(
        "[{\"name\":\"a\",\"pages\":\"3\",\"isbn\":\"978\"}]",
        try transcode.encodeResponse(pb.ListBooksResponse, a, list, "books"),
    );
    try std.testing.expectEqualStrings("[]", try transcode.encodeResponse(pb.ListBooksResponse, a, .{}, "books"));
    try std.testing.expectEqualStrings("\"\"", try transcode.encodeResponse(pb.ListBooksResponse, a, .{}, "next_page_token"));
    try std.testing.expectEqualStrings("{\"name\":\"Ada\"}", try transcode.encodeResponse(pb.CreateBookRequest, a, .{ .book = .{ .name = "Ada" } }, "book"));
    try std.testing.expectEqualStrings("{}", try transcode.encodeResponse(pb.CreateBookRequest, a, .{}, "book"));
    try std.testing.expectEqualStrings("\"SHADE_UNSPECIFIED\"", try transcode.encodeResponse(pb.GetBookRequest, a, .{}, "shade"));
    try std.testing.expectEqualStrings("\"0\"", try transcode.encodeResponse(pb.GetBookRequest, a, .{}, "revision"));
}

test "transcoding: the bindings of the annotations" {
    const get = transcode.rules(Library, "GetBook");
    try std.testing.expectEqual(@as(usize, 3), get.len);
    try std.testing.expectEqual(dusty.Method.get, get[0].method);
    try std.testing.expectEqualStrings("/v1/books/{name}", get[1].pattern);
    const search = transcode.rules(Library, "SearchBooks");
    try std.testing.expectEqual(dusty.Method.search, search[0].method);
    try std.testing.expectEqualStrings("*", search[0].body);
    try std.testing.expectEqualStrings("books", transcode.rules(Library, "ListBooks")[0].response_body);
    try std.testing.expectEqual(@as(usize, 0), transcode.rules(Library, "Plain").len);
}

test "fuzz: transcoded query parameters and bodies" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            // A query, then after a newline a body for the `book` field.
            const nl = std.mem.indexOfScalar(u8, input, '\n') orelse input.len;
            const query = input[0..nl];
            const body = if (nl < input.len) input[nl + 1 ..] else "";
            var diag: transcode.Diagnostic = .{};
            const captures: []const Capture = &.{.{ .field = "parent", .raw = query[0..@min(query.len, 8)], .multi = true }};
            // Refusing the input is fine; anything else but running out of
            // memory is not.
            if (transcode.decodeRequest(pb.GetBookRequest, a, "", "", &.{}, query, &diag)) |_| {} else |err| {
                if (err == error.OutOfMemory) return err;
                if (diag.message.len == 0) return error.NoDiagnostic;
            }
            if (transcode.decodeRequest(pb.CreateBookRequest, a, "book", body, captures, query, &diag)) |_| {} else |err| {
                if (err == error.OutOfMemory) return err;
            }
        }
    }.check, &.{
        "view=FULL&shade=DARK&tags=a&tags=b&author.name=Ada&author.born=1&revision=-2",
        "full=true&score=NaN&since=2024-01-02T03:04:05Z&token=aGk=&pages=1&pages=2&big=1",
        "bookId=b&book_id=c\n{\"title\":\"T\",\"tags\":[\"x\"],\"author\":{\"name\":\"A\"}}",
        "parent=p%20q&x=%41\n{\"pages\":\"12\",\"published\":\"2020-01-01T00:00:00Z\",\"isbn\":\"1\"}",
        "shade=2&shade=LIGHT&revision=9223372036854775807\n[]",
        "a.b.c.d=1&author.name.x=2\n\"str\"",
    });
}

// ---------------------------------------------------------------------------
// End to end
// ---------------------------------------------------------------------------

fn summary(call: *grpc.Call, r: pb.GetBookRequest) ![]const u8 {
    return std.fmt.allocPrint(call.arena, "view={s} shade={t} tags={d} author={s} rev={d} full={} big={d}", .{
        r.view, r.shade, r.tags.items.len, if (r.author) |au| au.name else "-", r.revision, r.full, r.big,
    });
}

fn getBook(call: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    if (std.mem.eql(u8, req.name, "missing")) return call.fail(.not_found, "no such book");
    if (std.mem.eql(u8, req.name, "boom")) return error.SecretInternalName;
    try call.addHeader("x-book", "yes");
    try call.addTrailer("x-served", "1");
    return .{ .name = req.name, .title = try summary(call, req), .tags = req.tags, .author = req.author };
}

fn createBook(call: *grpc.Call, req: pb.CreateBookRequest) anyerror!pb.Book {
    var book = req.book orelse pb.Book{};
    book.name = try std.fmt.allocPrint(call.arena, "{s}/books/{s}", .{ req.parent, req.book_id });
    return book;
}

fn updateBook(_: *grpc.Call, req: pb.UpdateBookRequest) anyerror!pb.Book {
    var book = req.book orelse pb.Book{};
    if (req.mask.len > 0) book.edition = .{ .isbn = req.mask };
    return book;
}

fn listBooks(call: *grpc.Call, req: pb.ListBooksRequest) anyerror!pb.ListBooksResponse {
    var books: std.ArrayList(pb.Book) = .empty;
    for (0..@intCast(req.page_size)) |i| {
        try books.append(call.arena, .{ .name = try std.fmt.allocPrint(call.arena, "{s}/books/{d}", .{ req.parent, i }) });
    }
    return .{ .books = books, .next_page_token = "next" };
}

fn deleteBook(_: *grpc.Call, _: pb.GetBookRequest) anyerror!pb.Empty {
    return .{};
}

fn publishBook(call: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = req.name, .title = try summary(call, req), .available = true };
}

fn statBook(_: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = req.name, .title = "stat" };
}

fn batchGet(call: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = "batch", .title = try summary(call, req) };
}

fn getFile(_: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = req.name, .title = "file" };
}

fn getFileInfo(_: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = req.name, .title = "info" };
}

fn searchBooks(_: *grpc.Call, req: pb.GetBookRequest) anyerror!pb.Book {
    return .{ .name = "found", .title = req.view };
}

fn watchBooks(call: *grpc.Call, req: pb.ListBooksRequest, out: *std.Io.Queue(pb.Book)) anyerror!void {
    if (std.mem.eql(u8, req.fail, "first")) return call.fail(.failed_precondition, "nothing to watch");
    for (0..@intCast(req.page_size)) |i| {
        if (i == 2 and std.mem.eql(u8, req.fail, "midway")) return call.fail(.aborted, "shelf removed");
        try out.putOne(call.io, .{ .name = try std.fmt.allocPrint(call.arena, "{s}/books/{d}", .{ req.parent, i }) });
    }
}

fn uploadBooks(_: *grpc.Call, _: *std.Io.Queue(pb.Book)) anyerror!pb.Book {
    unreachable;
}

fn plain(_: *grpc.Call, _: pb.GetBookRequest) anyerror!pb.Book {
    return .{};
}

const impl: Library = .{
    .GetBook = getBook,
    .CreateBook = createBook,
    .UpdateBook = updateBook,
    .ListBooks = listBooks,
    .DeleteBook = deleteBook,
    .PublishBook = publishBook,
    .StatBook = statBook,
    .BatchGet = batchGet,
    .GetFile = getFile,
    .GetFileInfo = getFileInfo,
    .SearchBooks = searchBooks,
    .WatchBooks = watchBooks,
    .UploadBooks = uploadBooks,
    .Plain = plain,
};

/// A response, as each client hands it back.
const Reply = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "",
    book_header: bool = false,
    served_trailer: ?[]const u8 = null,
    /// The body ended badly (a reset stream, a connection closed mid-body).
    cut: bool = false,
};

const Exchange = struct {
    method: dusty.Method,
    path: []const u8,
    body: ?[]const u8 = null,
};

fn http1(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, port: u16, x: Exchange) !Reply {
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var headers = try dusty.Headers.init(gpa, 8);
    defer headers.deinit(gpa);
    if (x.body != null) try headers.put("Content-Type", "application/json");
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ port, x.path });
    // Streamed, so a body cut short shows in `body`.
    var resp = try client.fetch(url, .{ .method = x.method, .headers = &headers, .body = x.body, .stream = true });
    defer resp.deinit();
    const h = resp.headers();
    var reply: Reply = .{
        .status = @intCast(@backingInt(resp.status())),
        .body = "",
        .content_type = try arena.dupe(u8, h.get("Content-Type") orelse ""),
        .book_header = h.get("x-book") != null,
        .served_trailer = if (h.get("grpc-trailer-x-served")) |v| try arena.dupe(u8, v) else null,
    };
    if (resp.body()) |body| {
        reply.body = try arena.dupe(u8, body orelse "");
    } else |_| reply.cut = true;
    return reply;
}

fn http2(conn: *@import("anole_h2_client").ClientConnection, arena: std.mem.Allocator, x: Exchange) !Reply {
    const H = @import("anole_h2_client").Header;
    var name_buf: [16]u8 = undefined;
    const method = std.ascii.upperString(&name_buf, @tagName(x.method));
    var headers: std.ArrayList(H) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = ":method", .value = method },
        .{ .name = ":path", .value = x.path },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "localhost" },
    });
    if (x.body != null) try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    const stream = try conn.request(headers.items, .{ .body = x.body != null });
    defer stream.release();
    if (x.body) |body| {
        try stream.writer().writeAll(body);
        try stream.closeSend();
    }
    // A stream reset before its head arrived is cut short too.
    stream.waitHead() catch |err| switch (err) {
        error.StreamReset => return .{ .status = 0, .body = "", .cut = true },
        else => |e| return e,
    };
    var reply: Reply = .{
        .status = stream.status,
        .body = "",
        .content_type = try arena.dupe(u8, stream.header("content-type") orelse ""),
        .book_header = stream.header("x-book") != null,
        .served_trailer = if (stream.header("grpc-trailer-x-served")) |v| try arena.dupe(u8, v) else null,
    };
    if (stream.reader().allocRemaining(arena, .limited(1 << 20))) |body| {
        reply.body = body;
    } else |_| reply.cut = true;
    return reply;
}

/// Every check, over one protocol.
fn exercise(ctx: anytype, send: anytype, arena: std.mem.Allocator) !void {
    {
        // A resource name with literals inside the variable, and the query.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/s1/books/b%201?view=FULL&shade=DARK&tags=a&tags=b&author.name=Ada&revision=7&full=true&big=9" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("application/json", r.content_type);
        try std.testing.expect(r.book_header);
        try std.testing.expectEqualStrings("1", r.served_trailer.?);
        try std.testing.expectEqualStrings(
            "{\"name\":\"shelves/s1/books/b 1\",\"title\":\"view=FULL shade=DARK tags=2 author=Ada rev=7 full=true big=9\",\"tags\":[\"a\",\"b\"],\"author\":{\"name\":\"Ada\"}}",
            r.body,
        );
    }
    {
        // The additional bindings; a nested field in the path.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/books/one" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"name\":\"one\"") != null);
        const r2 = try send(ctx, arena, .{ .method = .get, .path = "/v1/authors/Ada%20L/books" });
        try std.testing.expect(std.mem.indexOf(u8, r2.body, "author=Ada L") != null);
        // Another binding on the same route (/v1/books/:name), with a verb.
        const stat = try send(ctx, arena, .{ .method = .get, .path = "/v1/books/one:stat" });
        try std.testing.expectEqualStrings("{\"name\":\"one\",\"title\":\"stat\"}", stat.body);
        // A variable named differently at a position another route has.
        const shelf = try send(ctx, arena, .{ .method = .get, .path = "/v1/authors/Ada/shelf?pageSize=1" });
        try std.testing.expectEqualStrings("{\"books\":[{\"name\":\"Ada/books/0\"}],\"nextPageToken\":\"next\"}", shelf.body);
    }
    {
        // A gRPC status: its HTTP status and google.rpc.Status JSON.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/books/missing" });
        try std.testing.expectEqual(@as(u16, 404), r.status);
        try std.testing.expectEqualStrings("{\"code\":5,\"message\":\"no such book\",\"details\":[]}", r.body);
        const boom = try send(ctx, arena, .{ .method = .get, .path = "/v1/books/boom" });
        try std.testing.expectEqual(@as(u16, 500), boom.status);
        try std.testing.expectEqualStrings("{\"code\":2,\"message\":\"Application error processing RPC\",\"details\":[]}", boom.body);
        const bad = try send(ctx, arena, .{ .method = .get, .path = "/v1/books/x?full=maybe" });
        try std.testing.expectEqual(@as(u16, 400), bad.status);
        try std.testing.expect(std.mem.indexOf(u8, bad.body, "\"code\":3") != null);
    }
    {
        // body: a field; the rest from the query (JSON or proto names).
        const r = try send(ctx, arena, .{ .method = .post, .path = "/v1/shelves/s2/books?bookId=b9", .body = "{\"title\":\"Dune\",\"pages\":\"412\",\"shade\":\"LIGHT\"}" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("{\"name\":\"shelves/s2/books/b9\",\"title\":\"Dune\",\"pages\":\"412\",\"shade\":\"LIGHT\"}", r.body);
        const bad = try send(ctx, arena, .{ .method = .post, .path = "/v1/shelves/s2/books", .body = "{\"title\":" });
        try std.testing.expectEqual(@as(u16, 400), bad.status);
    }
    {
        // PATCH with the body field and a path variable inside it; the
        // PUT binding with body "*".
        const r = try send(ctx, arena, .{ .method = .patch, .path = "/v1/shelves/s/books/b?mask=isbn", .body = "{\"title\":\"T\"}" });
        try std.testing.expectEqualStrings("{\"name\":\"shelves/s/books/b\",\"title\":\"T\",\"isbn\":\"isbn\"}", r.body);
        const p = try send(ctx, arena, .{ .method = .put, .path = "/v1/shelves/s/books/b", .body = "{\"book\":{\"title\":\"U\"},\"mask\":\"m\"}" });
        try std.testing.expectEqualStrings("{\"name\":\"shelves/s/books/b\",\"title\":\"U\",\"isbn\":\"m\"}", p.body);
    }
    {
        // response_body: the repeated field alone.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/s3/books?pageSize=2" });
        try std.testing.expectEqualStrings("[{\"name\":\"shelves/s3/books/0\"},{\"name\":\"shelves/s3/books/1\"}]", r.body);
        const none = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/s3/books" });
        try std.testing.expectEqualStrings("[]", none.body);
    }
    {
        const r = try send(ctx, arena, .{ .method = .delete, .path = "/v1/shelves/s/books/b" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("{}", r.body);
    }
    {
        // Verbs: after a variable, after a literal, after **.
        const r = try send(ctx, arena, .{ .method = .post, .path = "/v1/shelves/s/books/b:publish", .body = "{\"view\":\"V\"}" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"name\":\"shelves/s/books/b\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "view=V") != null);
        const b = try send(ctx, arena, .{ .method = .get, .path = "/v1/books:batchGet?view=W" });
        try std.testing.expect(std.mem.indexOf(u8, b.body, "\"name\":\"batch\"") != null);
        const f = try send(ctx, arena, .{ .method = .get, .path = "/files/x/a/b%2Fc/d.txt" });
        try std.testing.expectEqualStrings("{\"name\":\"a/b%2Fc/d.txt\",\"title\":\"file\"}", f.body);
        const i = try send(ctx, arena, .{ .method = .get, .path = "/info/a/b:stat" });
        try std.testing.expectEqualStrings("{\"name\":\"a/b\",\"title\":\"info\"}", i.body);
        const no_verb = try send(ctx, arena, .{ .method = .get, .path = "/info/a/b" });
        try std.testing.expectEqual(@as(u16, 404), no_verb.status);
    }
    {
        // A custom HTTP method.
        const r = try send(ctx, arena, .{ .method = .search, .path = "/v1/books", .body = "{\"view\":\"S\"}" });
        try std.testing.expectEqualStrings("{\"name\":\"found\",\"title\":\"S\"}", r.body);
    }
    {
        // Server streaming: one JSON array.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/w/books:watch?pageSize=3" });
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(!r.cut);
        try std.testing.expectEqualStrings("[{\"name\":\"shelves/w/books/0\"},{\"name\":\"shelves/w/books/1\"},{\"name\":\"shelves/w/books/2\"}]", r.body);
        const none = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/w/books:watch" });
        try std.testing.expectEqualStrings("[]", none.body);
        // Failing before the first message: an ordinary error.
        const first = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/w/books:watch?pageSize=3&fail=first" });
        try std.testing.expectEqual(@as(u16, 400), first.status);
        try std.testing.expect(std.mem.indexOf(u8, first.body, "\"code\":9") != null);
        // Failing after it: the array is cut short.
        const midway = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/w/books:watch?pageSize=5&fail=midway" });
        try std.testing.expect(midway.cut);
    }
    {
        // Client streaming is not transcoded.
        const r = try send(ctx, arena, .{ .method = .post, .path = "/v1/books:upload", .body = "{}" });
        try std.testing.expectEqual(@as(u16, 501), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":12") != null);
    }
    {
        // Paths no binding matches.
        const r = try send(ctx, arena, .{ .method = .get, .path = "/v1/shelves/s/papers/b" });
        try std.testing.expectEqual(@as(u16, 404), r.status);
    }
}

test "transcoding: REST routes over HTTP/1.1 and HTTP/2" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = features.http2 }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Library, impl);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);
    const port = server.address.ip.getPort();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The server's warnings for the failing calls are expected.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;

    const H1 = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        port: u16,
        fn send(self: @This(), a: std.mem.Allocator, x: Exchange) !Reply {
            return http1(self.gpa, a, self.io, self.port, x);
        }
    };
    try exercise(H1{ .gpa = gpa, .io = io, .port = port }, H1.send, arena);

    // The gRPC route of an annotated method still serves gRPC's protocols.
    {
        var client = dusty.Client.init(gpa, io, .{});
        defer client.deinit();
        var headers = try dusty.Headers.init(gpa, 4);
        defer headers.deinit(gpa);
        try headers.put("Content-Type", "application/json");
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/transcode.Library/GetBook", .{port});
        var resp = try client.fetch(url, .{ .method = .post, .headers = &headers, .body = "{\"name\":\"c\"}" });
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), @as(u16, @intCast(@backingInt(resp.status()))));
        // Connect's JSON is protojson too: a oneof member is a field of
        // the message, not nested under the oneof's name.
        const update = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/transcode.Library/UpdateBook", .{port});
        var oneof = try client.fetch(update, .{ .method = .post, .headers = &headers, .body = "{\"book\":{\"title\":\"T\"},\"mask\":\"978\"}" });
        defer oneof.deinit();
        try std.testing.expectEqualStrings("{\"title\":\"T\",\"isbn\":\"978\"}", (try oneof.body()).?);
    }

    if (features.http2) {
        const h2 = @import("anole_h2_client");
        const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = port });
        defer conn.close();
        try exercise(conn, http2, arena);
    }
}

test "transcoding: off for a registration" {
    const gpa = std.testing.allocator;
    var router = dusty.Router(void).init(gpa);
    defer router.deinit();
    grpc.registerWith(void, &router, Library, impl, .{ .transcode = false });
    // Only the gRPC routes (POST, one per method).
    try std.testing.expect(router.trees[@backingInt(dusty.Method.get)] == null);
    try std.testing.expect(router.trees[@backingInt(dusty.Method.patch)] == null);
}
