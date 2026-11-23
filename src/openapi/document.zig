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

const yes: Node = .{ .boolean = true };

fn strOrNull(v: ?[]const u8) ?Node {
    return if (v) |s| str(s) else null;
}

/// The members of a JSON object, in the order listed; an optional value that
/// is null leaves its key out. `items` is a tuple of `.{ "key", Node-or-?Node }`.
fn members(a: Allocator, items: anytype) Allocator.Error![]Member {
    var out: std.ArrayList(Member) = .empty;
    inline for (items) |kv| {
        if (@typeInfo(@TypeOf(kv[1])) == .optional) {
            if (kv[1]) |v| try out.append(a, .{ .key = kv[0], .value = v });
        } else try out.append(a, .{ .key = kv[0], .value = kv[1] });
    }
    return out.items;
}

fn obj(a: Allocator, items: anytype) Allocator.Error!Node {
    return .{ .object = try members(a, items) };
}

/// The entries that stay, in document order.
fn keptEntries(a: Allocator, entries_in: []const Entry, opts: Options) Allocator.Error![]Entry {
    var kept: std.ArrayList(Entry) = .empty;
    for (entries_in) |e| if (keep(e, opts)) try kept.append(a, e);
    std.mem.sort(Entry, kept.items, {}, lessEntry);
    return kept.items;
}

/// The names of `comps`: renames first, then a check that no two share one.
fn componentNames(a: Allocator, comps: *const Components, opts: Options, log: anytype) root.BuildError![]const []const u8 {
    const items = comps.items.items;
    const names = try a.alloc([]const u8, items.len);
    for (items, names) |c, *n| {
        n.* = c.name;
        for (opts.rename) |r| if (std.mem.eql(u8, r.type_name, c.type_name)) {
            n.* = r.name;
        };
    }
    for (items, 0..) |c, i| {
        for (items[0..i], 0..) |d, j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                log.err("openapi: two types are named \"{s}\": {s} and {s}; name one with pub const openapi: anole.openapi.Doc(@This()) = .{{ .name = \"...\" }}, or with app.openapi(.{{ .rename = &.{{.{{ .type_name = \"{s}\", .name = \"...\" }}}} }})", .{ names[i], d.type_name, c.type_name, c.type_name });
                return error.OpenApiNameClash;
            }
        }
    }
    return names;
}

/// The security schemes the routes' middleware declare, sorted by name.
fn securitySchemes(a: Allocator, kept: []const Entry, log: anytype) root.BuildError![]mw.Scheme {
    var schemes: std.ArrayList(mw.Scheme) = .empty;
    for (kept) |e| for (e.middleware) |info| for (info.schemes) |sc| {
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
    return schemes.items;
}

/// `paths`: one object per path, one operation per verb (the first wins).
fn pathsNode(b: Builder, kept: []const Entry, opts: Options, error_format: root.ErrorFormat, table: json.NameTable, used_tags: *std.StringHashMapUnmanaged(?[]const u8)) !Node {
    const a = b.a;
    var used_ids: std.StringHashMapUnmanaged(u32) = .empty;
    var path_members: std.ArrayList(Member) = .empty;
    var i: usize = 0;
    while (i < kept.len) {
        const path = kept[i].path;
        var verbs: std.ArrayList(Member) = .empty;
        var seen_verbs: [verb_order.len]bool = @splat(false);
        while (i < kept.len and std.mem.eql(u8, kept[i].path, path)) : (i += 1) {
            const e = kept[i];
            const rank = verbRank(e.verb);
            if (seen_verbs[rank]) continue;
            seen_verbs[rank] = true;
            try verbs.append(a, .{ .key = @tagName(e.verb), .value = try operationNode(b, e, opts, error_format, table, &used_ids, used_tags) });
        }
        try path_members.append(a, .{ .key = path, .value = .{ .object = verbs.items } });
    }
    return .{ .object = path_members.items };
}

fn infoNode(a: Allocator, opts: Options) !Node {
    return obj(a, .{
        .{ "title", str(opts.info.title) },
        .{ "summary", strOrNull(opts.info.summary) },
        .{ "description", strOrNull(opts.info.description) },
        .{ "version", str(opts.info.version) },
    });
}

fn serversNode(a: Allocator, opts: Options) !?Node {
    if (opts.servers.len == 0) return null;
    const servers = try a.alloc(Node, opts.servers.len);
    for (opts.servers, servers) |sv, *n| n.* = try obj(a, .{
        .{ "url", str(sv.url) },
        .{ "description", strOrNull(sv.description) },
    });
    return .{ .array = servers };
}

/// The tags some operation uses, sorted; a description from `opts.tags` wins
/// over the one found on the route.
fn tagsNode(a: Allocator, used_tags: *const std.StringHashMapUnmanaged(?[]const u8), opts: Options) !?Node {
    if (used_tags.count() == 0) return null;
    var tag_names: std.ArrayList([]const u8) = .empty;
    var it = used_tags.iterator();
    while (it.next()) |kv| try tag_names.append(a, kv.key_ptr.*);
    std.mem.sort([]const u8, tag_names.items, {}, lessStr);
    const tags = try a.alloc(Node, tag_names.items.len);
    for (tag_names.items, tags) |t, *n| {
        var desc: ?[]const u8 = used_tags.get(t).?;
        for (opts.tags) |te| if (std.mem.eql(u8, te.name, t)) {
            desc = te.description;
        };
        n.* = try obj(a, .{ .{ "name", str(t) }, .{ "description", strOrNull(desc) } });
    }
    return .{ .array = tags };
}

fn componentsNode(a: Allocator, comps: *const Components, names: []const []const u8, schemes: []const mw.Scheme) !?Node {
    var schemas: ?Node = null;
    if (comps.items.items.len > 0) {
        const order = try a.alloc(usize, comps.items.items.len);
        for (order, 0..) |*o, k| o.* = k;
        std.mem.sort(usize, order, names, struct {
            fn less(n: []const []const u8, x: usize, y: usize) bool {
                return std.mem.order(u8, n[x], n[y]) == .lt;
            }
        }.less);
        const ms = try a.alloc(Member, order.len);
        for (order, ms) |k, *m| m.* = .{ .key = names[k], .value = comps.items.items[k].schema };
        schemas = .{ .object = ms };
    }
    var security: ?Node = null;
    if (schemes.len > 0) {
        const ms = try a.alloc(Member, schemes.len);
        for (schemes, ms) |sc, *m| m.* = .{ .key = sc.name, .value = sc.definition };
        security = .{ .object = ms };
    }
    const ms = try members(a, .{ .{ "schemas", schemas }, .{ "securitySchemes", security } });
    return if (ms.len > 0) .{ .object = ms } else null;
}

/// Builds the document of `entries` in `gpa`'s memory; the caller frees it.
pub fn build(gpa: Allocator, entries_in: []const Entry, opts: Options, error_format: root.ErrorFormat, log: anytype) root.BuildError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const b: Builder = .{ .a = a };

    const kept = try keptEntries(a, entries_in, opts);
    var comps: Components = .{};
    for (kept) |e| try walkOp(&comps, a, e.op, e.middleware);
    const names = try componentNames(a, &comps, opts, log);
    const table: json.NameTable = .{ .components = comps.items.items, .names = names };
    const schemes = try securitySchemes(a, kept, log);

    var used_tags: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    const paths = try pathsNode(b, kept, opts, error_format, table, &used_tags);

    const top = try obj(a, .{
        .{ "openapi", str("3.1.0") },
        .{ "info", try infoNode(a, opts) },
        .{ "servers", try serversNode(a, opts) },
        .{ "tags", try tagsNode(a, &used_tags, opts) },
        .{ "paths", paths },
        .{ "components", try componentsNode(a, &comps, names, schemes) },
    });

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    json.writeNamed(top, &out.writer, table) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn responseCode(a: Allocator, status: u16) ![]const u8 {
    if (status == 0) return "default";
    return std.fmt.allocPrint(a, "{d}", .{status});
}

/// `tags`: the operation's own, else its gRPC service or path tag; records
/// every tag used.
fn tagsMember(a: Allocator, e: Entry, opts: Options, used_tags: *std.StringHashMapUnmanaged(?[]const u8)) !?Node {
    const op = e.op;
    if (op.tags.len > 0) {
        const ts = try a.alloc(Node, op.tags.len);
        for (op.tags, ts) |t, *n| {
            n.* = str(t);
            if (!used_tags.contains(t)) try used_tags.put(a, t, null);
        }
        return .{ .array = ts };
    }
    const t = op.grpc_service orelse if (opts.tags_from_path) operation.tagFromPath(e.path) else null;
    const tag = t orelse return null;
    if (!used_tags.contains(tag)) try used_tags.put(a, tag, e.tag_doc) else if (e.tag_doc != null and used_tags.get(tag).? == null) try used_tags.put(a, tag, e.tag_doc);
    return .{ .array = try a.dupe(Node, &.{str(tag)}) };
}

/// The operationId, unique within the document.
fn uniqueId(a: Allocator, e: Entry, used_ids: *std.StringHashMapUnmanaged(u32)) ![]const u8 {
    const base = e.op.operation_id orelse try defaultId(a, e.verb, e.path);
    if (used_ids.get(base)) |n| {
        try used_ids.put(a, base, n + 1);
        return std.fmt.allocPrint(a, "{s}_{d}", .{ base, n + 1 });
    }
    try used_ids.put(a, base, 1);
    return base;
}

/// `parameters`: the operation's, the path's that it leaves out, the middleware's.
fn parametersNode(a: Allocator, e: Entry) !?Node {
    var have: std.ArrayList(Operation.Param) = .empty;
    for (e.op.params) |p| try have.append(a, p);
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
    if (have.items.len == 0) return null;
    const params = try a.alloc(Node, have.items.len);
    for (have.items, params) |p, *n| n.* = try paramNode(a, p);
    return .{ .array = params };
}

fn requestBodyNode(a: Allocator, body: Operation.Body) !Node {
    return obj(a, .{
        .{ "required", if (body.required) yes else null },
        .{ "content", try obj(a, .{.{ body.content_type, try obj(a, .{.{ "schema", body.schema }}) }}) },
    });
}

/// `responses`: the operation's, then the middleware's for statuses it lacks.
fn responsesNode(a: Allocator, e: Entry, error_format: root.ErrorFormat) !Node {
    var resp: std.ArrayList(Operation.Response) = .empty;
    for (e.op.responses) |r| try resp.append(a, r);
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
    const rms = try a.alloc(Member, resp.items.len);
    for (resp.items, rms) |r, *m| m.* = .{ .key = try responseCode(a, r.status), .value = try responseNode(a, r, error_format) };
    return .{ .object = rms };
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
    return obj(a, .{
        .{ "tags", try tagsMember(a, e, opts, used_tags) },
        .{ "summary", strOrNull(op.summary) },
        .{ "description", strOrNull(op.description) },
        .{ "operationId", str(try uniqueId(a, e, used_ids)) },
        .{ "deprecated", if (op.deprecated) yes else null },
        .{ "parameters", try parametersNode(a, e) },
        .{ "requestBody", if (op.body) |body| try requestBodyNode(a, body) else null },
        .{ "responses", try responsesNode(a, e, error_format) },
        .{ "security", try securityNode(a, e) },
    });
}

fn paramNode(a: Allocator, p: Operation.Param) !Node {
    return obj(a, .{
        .{ "name", str(p.name) },
        .{ "in", str(@tagName(p.in)) },
        .{ "description", strOrNull(p.description) },
        .{ "required", if (p.required) yes else null },
        .{ "deprecated", if (p.deprecated) yes else null },
        .{ "style", if (p.explode) str("form") else null },
        .{ "explode", if (p.explode) yes else null },
        .{ "schema", p.schema },
        .{ "x-anole-rest-of-path", if (p.rest_of_path) yes else null },
    });
}

fn schemaMember(a: Allocator, ct: []const u8, schema: Node) !Member {
    return .{ .key = ct, .value = .{ .object = try a.dupe(Member, &.{.{ .key = "schema", .value = schema }}) } };
}

fn responseNode(a: Allocator, r: Operation.Response, error_format: root.ErrorFormat) !Node {
    var headers: ?Node = null;
    if (r.headers.len > 0) {
        const hs = try a.alloc(Member, r.headers.len);
        for (r.headers, hs) |h, *m| m.* = .{ .key = h.name, .value = try obj(a, .{
            .{ "description", str(h.description) },
            .{ "schema", h.schema },
        }) };
        headers = .{ .object = hs };
    }
    var contents: std.ArrayList(Member) = .empty;
    if (r.error_body) {
        if (error_format != .text) try contents.append(a, try schemaMember(a, "application/json", fixed.error_ref));
        if (error_format != .json) try contents.append(a, try schemaMember(a, "text/plain", string_schema));
    }
    for (r.contents) |c| try contents.append(a, try schemaMember(a, c.content_type, c.schema));
    return obj(a, .{
        .{ "description", str(r.description) },
        .{ "headers", headers },
        .{ "content", if (contents.items.len > 0) Node{ .object = contents.items } else null },
    });
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
