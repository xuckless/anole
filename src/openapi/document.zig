//! The assembler: the recorded routes (each with its comptime-built
//! `Operation`) become the bytes of one OpenAPI 3.1 document. Everything here
//! is deterministic: paths, methods, tags, schemas and security schemes come
//! out in a fixed order, so the same app writes the same bytes.
const std = @import("std");
const json = @import("json.zig");
const operation = @import("operation.zig");
const fixed = @import("fixed.zig");
const mw = @import("mw.zig");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const Operation = operation.Operation;
const Node = json.Node;
const Member = json.Member;
const Options = root.Options;
const Entry = root.Entry;

const string_schema: Node = .{ .object = &.{.{ .key = "type", .value = .{ .string = "string" } }} };

fn str(v: []const u8) Node {
    return .{ .string = v };
}

const Builder = struct { a: Allocator };

/// Whether two trees write the same bytes.
fn sameNode(a: Allocator, x: Node, y: Node) bool {
    var wx: std.Io.Writer.Allocating = .init(a);
    var wy: std.Io.Writer.Allocating = .init(a);
    json.write(x, &wx.writer) catch return false;
    json.write(y, &wy.writer) catch return false;
    return std.mem.eql(u8, wx.written(), wy.written());
}

/// The components a document holds: every one an operation refers to,
/// directly or through another, in first-seen order.
const Components = struct {
    items: std.ArrayList(*const json.Component) = .empty,

    fn has(self: *const Components, c: *const json.Component) bool {
        for (self.items.items) |i| if (i == c) return true;
        return false;
    }

    fn add(self: *Components, a: Allocator, c: *const json.Component) Allocator.Error!void {
        if (self.has(c)) return;
        try self.items.append(a, c);
        try self.walk(a, c.schema);
    }

    fn walk(self: *Components, a: Allocator, node: Node) Allocator.Error!void {
        switch (node) {
            .object => |ms| for (ms) |m| try self.walk(a, m.value),
            .array => |ns| for (ns) |n| try self.walk(a, n),
            .ref => |f| try self.add(a, f()),
            else => {},
        }
    }
};

fn walkOp(cs: *Components, a: Allocator, op: *const Operation, infos: []const *const mw.Info) Allocator.Error!void {
    for (op.params) |p| try cs.walk(a, p.schema);
    if (op.body) |b| try cs.walk(a, b.schema);
    var any_error = false;
    for (op.responses) |r| {
        for (r.contents) |c| try cs.walk(a, c.schema);
        for (r.headers) |h| try cs.walk(a, h.schema);
        if (r.error_body) any_error = true;
    }
    for (infos) |info| {
        for (info.params) |p| try cs.walk(a, p.schema);
        for (info.responses) |r| for (r.contents) |c| try cs.walk(a, c.schema);
    }
    if (any_error) try cs.add(a, &fixed.error_body);
}

fn keep(e: Entry, opts: Options) bool {
    return switch (e.op.kind) {
        .rest => true,
        .connect => switch (opts.grpc.connect) {
            .none => false,
            .all => true,
            .unannotated => !e.annotated,
        },
        .transcoded => opts.grpc.transcoded,
    };
}

const verb_order = [_]operation.Verb{ .get, .put, .post, .delete, .options, .head, .patch, .trace };

fn verbRank(v: operation.Verb) usize {
    for (verb_order, 0..) |x, i| if (x == v) return i;
    return verb_order.len;
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    const c = std.mem.order(u8, a.path, b.path);
    if (c != .eq) return c == .lt;
    return verbRank(a.verb) < verbRank(b.verb);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `method` and `path` as an `operationId`: `GET /users/{id}/posts` ->
/// `getUsersByIdPosts`.
fn defaultId(a: Allocator, verb: operation.Verb, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, @tagName(verb));
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        var name = seg;
        if (name.len > 0 and (name[0] == '{' or name[0] == ':' or name[0] == '*')) {
            try out.appendSlice(a, "By");
            name = std.mem.trim(u8, name, "{}:*");
        }
        var upper = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                upper = true;
                continue;
            }
            try out.append(a, if (upper) std.ascii.toUpper(c) else c);
            upper = false;
        }
    }
    return out.items;
}

fn pathParams(a: Allocator, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, i, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, path, open, '}') orelse break;
        try out.append(a, path[open + 1 .. close]);
        i = close + 1;
    }
    return out.items;
}

const NameClash = struct { a: []const u8, b: []const u8, name: []const u8 };

/// Builds the document of `entries` in `gpa`'s memory; the caller frees it.
pub fn build(gpa: Allocator, entries_in: []const Entry, opts: Options, error_format: root.ErrorFormat, log: anytype) root.BuildError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const b: Builder = .{ .a = a };

    // 1. The entries that stay, in document order.
    var kept: std.ArrayList(Entry) = .empty;
    for (entries_in) |e| if (keep(e, opts)) try kept.append(a, e);
    std.mem.sort(Entry, kept.items, {}, lessEntry);

    // 2. Components.
    var comps: Components = .{};
    for (kept.items) |e| try walkOp(&comps, a, e.op, e.middleware);

    // 3. Their names: renames first, then a check that no two share one.
    const names = try a.alloc([]const u8, comps.items.items.len);
    for (comps.items.items, names) |c, *n| {
        n.* = c.name;
        for (opts.rename) |r| if (std.mem.eql(u8, r.type_name, c.type_name)) {
            n.* = r.name;
        };
    }
    for (comps.items.items, 0..) |c, i| {
        for (comps.items.items[0..i], 0..) |d, j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                log.err("openapi: two types are named \"{s}\": {s} and {s}; name one with pub const openapi: anole.openapi.Doc(@This()) = .{{ .name = \"...\" }}, or with app.openapi(.{{ .rename = &.{{.{{ .type_name = \"{s}\", .name = \"...\" }}}} }})", .{ names[i], d.type_name, c.type_name, c.type_name });
                return error.OpenApiNameClash;
            }
        }
    }
    const table: json.NameTable = .{ .components = comps.items.items, .names = names };

    // 4. Security schemes.
    var schemes: std.ArrayList(mw.Scheme) = .empty;
    for (kept.items) |e| for (e.middleware) |info| for (info.schemes) |sc| {
        var found = false;
        for (schemes.items) |have| {
            if (!std.mem.eql(u8, have.name, sc.name)) continue;
            found = true;
            if (!sameNode(a, have.definition, sc.definition)) {
                log.err("openapi: two security schemes are named \"{s}\" and differ", .{sc.name});
                return error.OpenApiNameClash;
            }
        }
        if (!found) try schemes.append(a, sc);
    };
    std.mem.sort(mw.Scheme, schemes.items, {}, struct {
        fn less(_: void, x: mw.Scheme, y: mw.Scheme) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);

    // 5. Paths.
    var used_ids: std.StringHashMapUnmanaged(u32) = .empty;
    var used_tags: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var path_members: std.ArrayList(Member) = .empty;
    var i: usize = 0;
    while (i < kept.items.len) {
        const path = kept.items[i].path;
        var verbs: std.ArrayList(Member) = .empty;
        var seen_verbs: [verb_order.len]bool = @splat(false);
        while (i < kept.items.len and std.mem.eql(u8, kept.items[i].path, path)) : (i += 1) {
            const e = kept.items[i];
            const rank = verbRank(e.verb);
            if (seen_verbs[rank]) continue;
            seen_verbs[rank] = true;
            try verbs.append(a, .{ .key = @tagName(e.verb), .value = try operationNode(b, e, opts, error_format, table, &used_ids, &used_tags) });
        }
        try path_members.append(a, .{ .key = path, .value = .{ .object = verbs.items } });
    }

    // 6. Top level.
    var info_members: std.ArrayList(Member) = .empty;
    try info_members.append(a, .{ .key = "title", .value = str(opts.info.title) });
    if (opts.info.summary) |t| try info_members.append(a, .{ .key = "summary", .value = str(t) });
    if (opts.info.description) |t| try info_members.append(a, .{ .key = "description", .value = str(t) });
    try info_members.append(a, .{ .key = "version", .value = str(opts.info.version) });

    var top: std.ArrayList(Member) = .empty;
    try top.append(a, .{ .key = "openapi", .value = str("3.1.0") });
    try top.append(a, .{ .key = "info", .value = .{ .object = info_members.items } });
    if (opts.servers.len > 0) {
        var servers: std.ArrayList(Node) = .empty;
        for (opts.servers) |sv| {
            var ms: std.ArrayList(Member) = .empty;
            try ms.append(a, .{ .key = "url", .value = str(sv.url) });
            if (sv.description) |d| try ms.append(a, .{ .key = "description", .value = str(d) });
            try servers.append(a, .{ .object = ms.items });
        }
        try top.append(a, .{ .key = "servers", .value = .{ .array = servers.items } });
    }
    if (used_tags.count() > 0) {
        var tag_names: std.ArrayList([]const u8) = .empty;
        var it = used_tags.iterator();
        while (it.next()) |kv| try tag_names.append(a, kv.key_ptr.*);
        std.mem.sort([]const u8, tag_names.items, {}, lessStr);
        var tags: std.ArrayList(Node) = .empty;
        for (tag_names.items) |t| {
            var ms: std.ArrayList(Member) = .empty;
            try ms.append(a, .{ .key = "name", .value = str(t) });
            var desc: ?[]const u8 = used_tags.get(t).?;
            for (opts.tags) |te| if (std.mem.eql(u8, te.name, t)) {
                desc = te.description;
            };
            if (desc) |d| try ms.append(a, .{ .key = "description", .value = str(d) });
            try tags.append(a, .{ .object = ms.items });
        }
        try top.append(a, .{ .key = "tags", .value = .{ .array = tags.items } });
    }
    try top.append(a, .{ .key = "paths", .value = .{ .object = path_members.items } });

    var comp_members: std.ArrayList(Member) = .empty;
    if (comps.items.items.len > 0) {
        const order = try a.alloc(usize, comps.items.items.len);
        for (order, 0..) |*o, k| o.* = k;
        std.mem.sort(usize, order, names, struct {
            fn less(n: []const []const u8, x: usize, y: usize) bool {
                return std.mem.order(u8, n[x], n[y]) == .lt;
            }
        }.less);
        var ms: std.ArrayList(Member) = .empty;
        for (order) |k| try ms.append(a, .{ .key = names[k], .value = comps.items.items[k].schema });
        try comp_members.append(a, .{ .key = "schemas", .value = .{ .object = ms.items } });
    }
    if (schemes.items.len > 0) {
        var ms: std.ArrayList(Member) = .empty;
        for (schemes.items) |sc| try ms.append(a, .{ .key = sc.name, .value = sc.definition });
        try comp_members.append(a, .{ .key = "securitySchemes", .value = .{ .object = ms.items } });
    }
    if (comp_members.items.len > 0) try top.append(a, .{ .key = "components", .value = .{ .object = comp_members.items } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    json.writeNamed(.{ .object = top.items }, &out.writer, table) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn responseCode(a: Allocator, status: u16) ![]const u8 {
    if (status == 0) return "default";
    return std.fmt.allocPrint(a, "{d}", .{status});
}

fn operationNode(
    b: Builder,
    e: Entry,
    opts: Options,
    error_format: root.ErrorFormat,
    table: json.NameTable,
    used_ids: *std.StringHashMapUnmanaged(u32),
    used_tags: *std.StringHashMapUnmanaged(?[]const u8),
) !Node {
    _ = table;
    const a = b.a;
    const op = e.op;
    var members: std.ArrayList(Member) = .empty;

    // Tags.
    var tag: ?[]const u8 = null;
    if (op.tags.len > 0) {
        var ts: std.ArrayList(Node) = .empty;
        for (op.tags) |t| {
            try ts.append(a, str(t));
            if (!used_tags.contains(t)) try used_tags.put(a, t, null);
        }
        try members.append(a, .{ .key = "tags", .value = .{ .array = ts.items } });
    } else {
        tag = op.grpc_service orelse if (opts.tags_from_path) operation.tagFromPath(e.path) else null;
        if (tag) |t| {
            try members.append(a, .{ .key = "tags", .value = .{ .array = try a.dupe(Node, &.{str(t)}) } });
            if (!used_tags.contains(t)) try used_tags.put(a, t, e.tag_doc) else if (e.tag_doc != null and used_tags.get(t).? == null) try used_tags.put(a, t, e.tag_doc);
        }
    }
    if (op.summary) |t| try members.append(a, .{ .key = "summary", .value = str(t) });
    if (op.description) |t| try members.append(a, .{ .key = "description", .value = str(t) });

    // operationId, unique within the document.
    const base = op.operation_id orelse try defaultId(a, e.verb, e.path);
    var id = base;
    if (used_ids.get(base)) |n| {
        id = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, n + 1 });
        try used_ids.put(a, base, n + 1);
    } else try used_ids.put(a, base, 1);
    try members.append(a, .{ .key = "operationId", .value = str(id) });
    if (op.deprecated) try members.append(a, .{ .key = "deprecated", .value = .{ .boolean = true } });

    // Parameters: the operation's, the path's that it leaves out, the middleware's.
    var params: std.ArrayList(Node) = .empty;
    var have: std.ArrayList(Operation.Param) = .empty;
    for (op.params) |p| try have.append(a, p);
    for (try pathParams(a, e.path)) |name| {
        var present = false;
        for (have.items) |p| if (p.in == .path and std.mem.eql(u8, p.name, name)) {
            present = true;
        };
        if (!present) try have.append(a, .{ .name = name, .in = .path, .required = true, .schema = string_schema });
    }
    for (e.middleware) |info| for (info.params) |p| {
        var present = false;
        for (have.items) |q| if (q.in == p.in and std.mem.eql(u8, q.name, p.name)) {
            present = true;
        };
        if (!present) try have.append(a, p);
    };
    for (have.items) |p| try params.append(a, try paramNode(a, p));
    if (params.items.len > 0) try members.append(a, .{ .key = "parameters", .value = .{ .array = params.items } });

    if (op.body) |body| {
        var ms: std.ArrayList(Member) = .empty;
        if (body.required) try ms.append(a, .{ .key = "required", .value = .{ .boolean = true } });
        const content = try a.dupe(Member, &.{.{ .key = body.content_type, .value = .{ .object = try a.dupe(Member, &.{.{ .key = "schema", .value = body.schema }}) } }});
        try ms.append(a, .{ .key = "content", .value = .{ .object = content } });
        try members.append(a, .{ .key = "requestBody", .value = .{ .object = ms.items } });
    }

    // Responses: the operation's, then the middleware's for statuses it lacks.
    var resp: std.ArrayList(Operation.Response) = .empty;
    for (op.responses) |r| try resp.append(a, r);
    for (e.middleware) |info| for (info.responses) |r| {
        var present = false;
        for (resp.items) |q| if (q.status == r.status) {
            present = true;
        };
        if (!present) try resp.append(a, r);
    };
    std.mem.sort(Operation.Response, resp.items, {}, struct {
        fn less(_: void, x: Operation.Response, y: Operation.Response) bool {
            const xs: u32 = if (x.status == 0) 1000 else x.status;
            const ys: u32 = if (y.status == 0) 1000 else y.status;
            return xs < ys;
        }
    }.less);
    var rms: std.ArrayList(Member) = .empty;
    for (resp.items) |r| try rms.append(a, .{ .key = try responseCode(a, r.status), .value = try responseNode(a, r, error_format) });
    try members.append(a, .{ .key = "responses", .value = .{ .object = rms.items } });

    // Security.
    if (try securityNode(a, e)) |sec| try members.append(a, .{ .key = "security", .value = sec });

    return .{ .object = members.items };
}

fn paramNode(a: Allocator, p: Operation.Param) !Node {
    var ms: std.ArrayList(Member) = .empty;
    try ms.append(a, .{ .key = "name", .value = str(p.name) });
    try ms.append(a, .{ .key = "in", .value = str(@tagName(p.in)) });
    if (p.description) |d| try ms.append(a, .{ .key = "description", .value = str(d) });
    if (p.required) try ms.append(a, .{ .key = "required", .value = .{ .boolean = true } });
    if (p.deprecated) try ms.append(a, .{ .key = "deprecated", .value = .{ .boolean = true } });
    if (p.explode) {
        try ms.append(a, .{ .key = "style", .value = str("form") });
        try ms.append(a, .{ .key = "explode", .value = .{ .boolean = true } });
    }
    try ms.append(a, .{ .key = "schema", .value = p.schema });
    if (p.rest_of_path) try ms.append(a, .{ .key = "x-anole-rest-of-path", .value = .{ .boolean = true } });
    return .{ .object = ms.items };
}

fn schemaMember(a: Allocator, ct: []const u8, schema: Node) !Member {
    return .{ .key = ct, .value = .{ .object = try a.dupe(Member, &.{.{ .key = "schema", .value = schema }}) } };
}

fn responseNode(a: Allocator, r: Operation.Response, error_format: root.ErrorFormat) !Node {
    var ms: std.ArrayList(Member) = .empty;
    try ms.append(a, .{ .key = "description", .value = str(r.description) });
    if (r.headers.len > 0) {
        var hs: std.ArrayList(Member) = .empty;
        for (r.headers) |h| try hs.append(a, .{ .key = h.name, .value = .{ .object = try a.dupe(Member, &.{
            .{ .key = "description", .value = str(h.description) },
            .{ .key = "schema", .value = h.schema },
        }) } });
        try ms.append(a, .{ .key = "headers", .value = .{ .object = hs.items } });
    }
    var contents: std.ArrayList(Member) = .empty;
    if (r.error_body) {
        if (error_format != .text) try contents.append(a, try schemaMember(a, "application/json", fixed.error_ref));
        if (error_format != .json) try contents.append(a, try schemaMember(a, "text/plain", .{ .object = try a.dupe(Member, &.{.{ .key = "type", .value = str("string") }}) }));
    }
    for (r.contents) |c| try contents.append(a, try schemaMember(a, c.content_type, c.schema));
    if (contents.items.len > 0) try ms.append(a, .{ .key = "content", .value = .{ .object = contents.items } });
    return .{ .object = ms.items };
}

/// The `security` of a route: the schemes its middleware requires.
fn securityNode(a: Allocator, e: Entry) !?Node {
    var declared: std.ArrayList([]const u8) = .empty;
    var required: std.ArrayList([]const u8) = .empty;
    var roles: std.ArrayList([]const u8) = .empty;
    var any_security = false;
    for (e.middleware) |info| {
        for (info.schemes) |sc| try declared.append(a, sc.name);
        for (info.roles) |r| try roles.append(a, r);
        const sec = info.security orelse continue;
        any_security = true;
        const wanted: []const []const u8 = switch (sec) {
            .any => declared.items,
            .schemes => |s| s,
        };
        for (wanted) |name| {
            var present = false;
            for (required.items) |q| if (std.mem.eql(u8, q, name)) {
                present = true;
            };
            if (!present) try required.append(a, name);
        }
    }
    if (!any_security) return null;
    var alts: std.ArrayList(Node) = .empty;
    for (required.items) |name| {
        var rs: std.ArrayList(Node) = .empty;
        for (roles.items) |r| try rs.append(a, str(r));
        try alts.append(a, .{ .object = try a.dupe(Member, &.{.{ .key = name, .value = .{ .array = rs.items } }}) });
    }
    return .{ .array = alts.items };
}
