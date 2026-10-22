// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Method = @import("http.zig").Method;
const Middleware = @import("middleware.zig").Middleware;
const Static = @import("server/static.zig").Static;
const StaticOptions = @import("server/static.zig").StaticOptions;
const Precompressed = @import("server/static.zig").Precompressed;
const Embedded = @import("server/static.zig").Embedded;
const EmbeddedOptions = @import("server/static.zig").EmbeddedOptions;

/// What a request learns of the route it matched, as `Request.route`.
pub const RouteInfo = struct {
    /// The pattern the route was registered under, group prefix included:
    /// `/users/:id`, not the path that matched it.
    path: []const u8,
    /// Whatever the route was registered with, for its handler to cast
    /// back (`Router.addRoute`). Null for the routes `get`, `post` and the
    /// like register.
    data: ?*const anyopaque = null,
};

const NodeKind = enum {
    static,
    param,
    wildcard,
};

const Node = struct {
    // Compressed path segment
    segment: []const u8,

    // Type of this segment
    kind: NodeKind,

    // For param/wildcard nodes, the parameter name (without ':' or '*')
    param_name: ?[]const u8,

    // Children organized by type for proper precedence:
    // 1. Static children (checked first) - linked list
    static_children: ?*Node,
    // 2. Param child (checked second) - single node
    param_child: ?*Node,
    // 3. Wildcard child (checked last) - single node
    wildcard_child: ?*Node,

    // For linked list of siblings (only used in static_children)
    next_sibling: ?*Node,

    // Route (opaque pointer to Route) - only set on terminal nodes
    route: ?*const anyopaque,
};

/// How a route is registered (`Router.addRouteWith`).
pub const RouteOptions = struct {
    /// Whatever the route is registered with, for its handler to read back
    /// as `req.route.?.data`; see `Router.addRoute`.
    data: ?*const anyopaque = null,
    /// The handler and every middleware that runs for it never wait: no
    /// I/O, no sleeping, no lock or event that another task releases.
    /// Reading the request body is fine. A protocol engine that runs each
    /// request on a task of its own may then run this route's requests that
    /// arrived whole right where it reads them, without a task (HTTP/2
    /// does, for a request whose end, body included, came in the read that
    /// brought its HEADERS; HTTP/3 for one whose end came in the packet
    /// that completed its head). A handler that waits anyway still works,
    /// but holds up every other request on its connection meanwhile, and
    /// gets no request timeout. Leave it off for anything that talks to a
    /// database, a cache, another service or the file system.
    no_wait: bool = false,
};

pub fn Action(comptime Ctx: type) type {
    return *const Router(Ctx).Handler;
}

pub fn Router(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const Handler = if (Ctx == void)
            fn (*Request, *Response) anyerror!void
        else
            fn (*Ctx, *Request, *Response) anyerror!void;

        pub const Route = struct {
            info: RouteInfo,
            action: *const Handler,
            middlewares: []const Middleware(Ctx),
            /// See `RouteOptions.no_wait`.
            no_wait: bool = false,
        };

        /// One method's route in `static_routes`; the methods for one path
        /// are a list.
        const StaticRoute = struct {
            method: Method,
            route: *const Route,
            next: ?*StaticRoute,
        };

        arena: std.heap.ArenaAllocator,
        // Each HTTP method has its own radix tree
        trees: [256]?*Node,
        // Routes registered with `any`, tried after the method's own tree
        any_tree: ?*Node = null,
        /// The routes with no parameter or wildcard, by their path in
        /// canonical form ("/a/b"; "/" for the root), for `findHandler` to
        /// find without walking a tree. A request path in that form that is
        /// here for its method gets the route the tree walk would: at every
        /// level the walk tries static children first, so a route of static
        /// segments only wins over any parameter or wildcard route.
        static_routes: std.StringHashMapUnmanaged(*StaticRoute) = .empty,
        // Global middlewares applied to all routes
        middlewares: []const Middleware(Ctx) = &.{},
        /// A route was registered: each route took a copy of the global
        /// middleware then, so adding more now would miss them.
        has_routes: bool = false,
        /// Some route was registered with `no_wait`.
        has_no_wait: bool = false,
        /// A route that conflicts with one registered before it panics
        /// (a programmer error in Zig code) unless this is set: then it is
        /// left out, and the first conflict's message is kept in `conflict`
        /// for the caller to report. For route tables that come from data
        /// at run time (the C ABI's configuration), where a panic would
        /// take the host process with it.
        record_conflicts: bool = false,
        /// The first conflict found under `record_conflicts`.
        conflict: ?[]const u8 = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .trees = @splat(null),
            };
        }

        pub fn deinit(self: *Self) void {
            // Arena deinit frees everything at once
            self.arena.deinit();
        }

        fn findChild(parent: *Node, segment: []const u8, kind: NodeKind) ?*Node {
            switch (kind) {
                .static => {
                    // Search in static_children linked list
                    var child = parent.static_children;
                    while (child) |c| {
                        if (std.mem.eql(u8, c.segment, segment)) {
                            return c;
                        }
                        child = c.next_sibling;
                    }
                    return null;
                },
                .param => return parent.param_child,
                .wildcard => return parent.wildcard_child,
            }
        }

        const Conflict = struct {
            method: Method,
            method_path: []const u8,
            any_path: []const u8,
        };

        /// The first route that registering `path` for `method`, or for
        /// `any` when null, would conflict with.
        fn findConflict(self: *const Self, path: []const u8, method: ?Method) ?Conflict {
            if (method) |m| {
                const root = self.any_tree orelse return null;
                const other = findConflictIn(root, path, false) orelse return null;
                return .{ .method = m, .method_path = path, .any_path = other };
            }
            for (self.trees, 0..) |tree, i| {
                const root = tree orelse continue;
                const other = findConflictIn(root, path, true) orelse continue;
                return .{ .method = @fromBackingInt(@intCast(i)), .method_path = other, .any_path = path };
            }
            return null;
        }

        fn findConflictIn(node: *const Node, path: []const u8, path_is_any: bool) ?[]const u8 {
            if (node.route) |opaque_route| {
                const route: *const Route = @ptrCast(@alignCast(opaque_route));
                const other = route.info.path;
                if (if (path_is_any) conflicts(other, path) else conflicts(path, other)) return other;
            }
            var child = node.static_children;
            while (child) |c| : (child = c.next_sibling) {
                if (findConflictIn(c, path, path_is_any)) |other| return other;
            }
            if (node.param_child) |c| if (findConflictIn(c, path, path_is_any)) |other| return other;
            if (node.wildcard_child) |c| if (findConflictIn(c, path, path_is_any)) |other| return other;
            return null;
        }

        /// A conflict: a panic, or under `record_conflicts` the message
        /// (the first one) and the route left out.
        fn conflicted(self: *Self, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
            if (!self.record_conflicts) std.debug.panic(fmt, args);
            if (self.conflict == null) self.conflict = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        }

        fn insertRoute(
            self: *Self,
            path: []const u8,
            method: ?Method,
            handler: *const Handler,
            middlewares: []const Middleware(Ctx),
            opts: RouteOptions,
        ) !void {
            self.has_routes = true;
            if (opts.no_wait) self.has_no_wait = true;
            if (self.findConflict(path, method)) |c| {
                return self.conflicted("route {s} {s} conflicts with any() route {s}: both match some paths, but {s} is not more specific", .{ c.method.name(), c.method_path, c.any_path, c.method_path });
            }

            const slot = if (method) |m| &self.trees[@backingInt(m)] else &self.any_tree;

            // Get or create root for this method
            if (slot.* == null) {
                const root = try self.arena.allocator().create(Node);
                root.* = Node{
                    .segment = "",
                    .kind = .static,
                    .param_name = null,
                    .static_children = null,
                    .param_child = null,
                    .wildcard_child = null,
                    .next_sibling = null,
                    .route = null,
                };
                slot.* = root;
            }

            var current = slot.*.?;

            var iter = std.mem.splitScalar(u8, path, '/');
            while (iter.next()) |segment| {
                if (segment.len == 0) continue;
                // Determine segment kind
                const kind: NodeKind = if (segment[0] == '*')
                    .wildcard
                else if (segment[0] == ':')
                    .param
                else
                    .static;

                const param_name = if (kind == .param or kind == .wildcard)
                    segment[1..]
                else
                    null;

                // Find or create child
                var child = findChild(current, segment, kind);
                if (child) |existing| {
                    // One param or wildcard node captures under one name, and
                    // a route reading another would never find its value.
                    if ((kind == .wildcard or kind == .param) and !std.mem.eql(u8, existing.param_name.?, param_name.?)) {
                        return self.conflicted("route {s}: {s} conflicts with {c}{s}, registered at the same position by another route", .{
                            path, segment, segment[0], existing.param_name.?,
                        });
                    }
                }
                if (child == null) {
                    const new_node = try self.arena.allocator().create(Node);
                    new_node.* = Node{
                        .segment = try self.arena.allocator().dupe(u8, segment),
                        .kind = kind,
                        .param_name = if (param_name) |name| try self.arena.allocator().dupe(u8, name) else null,
                        .static_children = null,
                        .param_child = null,
                        .wildcard_child = null,
                        .next_sibling = null,
                        .route = null,
                    };

                    // Add to appropriate child field
                    switch (kind) {
                        .static => {
                            // Prepend to static_children linked list
                            new_node.next_sibling = current.static_children;
                            current.static_children = new_node;
                        },
                        .param => current.param_child = new_node,
                        .wildcard => current.wildcard_child = new_node,
                    }

                    child = new_node;
                }

                current = child.?;
            }

            // A second registration would silently replace the first.
            if (current.route != null) {
                return self.conflicted("route {s} {s} is registered twice", .{ if (method) |m| m.name() else "ANY", path });
            }

            // Create and store route
            const alloc = self.arena.allocator();
            const route = try alloc.create(Route);
            route.* = .{
                .info = .{ .path = try alloc.dupe(u8, path), .data = opts.data },
                .action = handler,
                .middlewares = middlewares,
                .no_wait = opts.no_wait,
            };
            current.route = @ptrCast(route);

            if (method) |m| if (std.mem.indexOfAny(u8, path, ":*") == null) {
                // `path` without empty segments, as `canonicalPath` takes a
                // request's.
                var key: std.ArrayList(u8) = .empty;
                var it = std.mem.splitScalar(u8, path, '/');
                while (it.next()) |segment| {
                    if (segment.len == 0) continue;
                    try key.append(alloc, '/');
                    try key.appendSlice(alloc, segment);
                }
                if (key.items.len == 0) try key.append(alloc, '/');
                const entry = try self.static_routes.getOrPut(alloc, key.items);
                const node = try alloc.create(StaticRoute);
                node.* = .{ .method = m, .route = route, .next = if (entry.found_existing) entry.value_ptr.* else null };
                entry.value_ptr.* = node;
            };
        }

        /// The route registered for exactly `path` and `method` with no
        /// parameter or wildcard, when `path` is in canonical form (no
        /// empty segment, so no "//" and no trailing slash); null otherwise,
        /// and the tree decides.
        fn staticRoute(self: *const Self, method: Method, path: []const u8) ?*const Route {
            if (path.len == 0 or path[0] != '/') return null;
            if (path.len > 1 and path[path.len - 1] == '/') return null;
            if (std.mem.indexOf(u8, path, "//") != null) return null;
            var node = self.static_routes.get(path) orelse return null;
            while (true) {
                if (node.method == method) return node.route;
                node = node.next orelse return null;
            }
        }

        fn matchRecursive(node: *Node, req: *Request, path: []const u8, segments: []const []const u8, segment_offsets: []const usize, index: usize) !?*Node {
            // Terminal case: consumed all segments
            if (index >= segments.len) {
                // Only return node if it has a route registered
                if (node.route == null) return null;
                return node;
            }

            const current_segment = segments[index];

            // Check children in precedence order: static > param > wildcard

            // 1. Try static children first (highest precedence)
            var static_child = node.static_children;
            while (static_child) |c| {
                if (std.mem.eql(u8, c.segment, current_segment)) {
                    const result = try matchRecursive(c, req, path, segments, segment_offsets, index + 1);
                    if (result != null) return result;
                }
                static_child = c.next_sibling;
            }

            // 2. Try param child (medium precedence)
            if (node.param_child) |c| {
                if (req.params.count() >= req._config.max_param_count) {
                    return error.TooManyParams;
                }
                try req.params.map.put(req.arena, c.param_name.?, current_segment);
                const result = try matchRecursive(c, req, path, segments, segment_offsets, index + 1);
                if (result != null) return result;
                _ = req.params.map.remove(c.param_name.?); // backtrack
            }

            // 3. Try wildcard child (lowest precedence)
            if (node.wildcard_child) |c| {
                if (req.params.count() >= req._config.max_param_count) {
                    return error.TooManyParams;
                }
                // Capture remaining path (without query parameters)
                const remaining = path[segment_offsets[index]..];
                try req.params.map.put(req.arena, c.param_name.?, remaining);
                return c;
            }

            return null;
        }

        pub fn findHandler(self: *const Self, req: *Request) !?Route {
            req.route = null;
            // Strip query parameters from URL and parse them
            req.query.map.clearRetainingCapacity();
            const path = if (std.mem.indexOfScalar(u8, req.url, '?')) |query_start| blk: {
                const query_string = req.url[query_start + 1 ..];
                try parseQueryString(req, query_string);
                break :blk req.url[0..query_start];
            } else req.url;

            if (self.staticRoute(req.method, path)) |r| {
                req.route = &r.info;
                return r.*;
            }

            // Count segments (max possible is number of '/' + 1)
            const max_segments = std.mem.count(u8, path, "/") + 1;

            // Pre-allocate exact capacity needed
            var segments = try std.ArrayList([]const u8).initCapacity(req.arena, max_segments);
            defer segments.deinit(req.arena);

            var offsets = try std.ArrayList(usize).initCapacity(req.arena, max_segments);
            defer offsets.deinit(req.arena);

            // Split path into segments and track their offsets
            var offset: usize = 0;
            var iter = std.mem.splitScalar(u8, path, '/');
            while (iter.next()) |segment| {
                if (segment.len > 0) {
                    segments.appendAssumeCapacity(segment);
                    offsets.appendAssumeCapacity(offset);
                }
                offset += segment.len + 1; // +1 for the '/'
            }

            const route = try self.matchIn(req.method, req, path, segments.items, offsets.items) orelse
                // A HEAD response is the GET response without the body, so a
                // HEAD with no route of its own is answered by the GET one.
                // Second, so a route registered with `head` still wins.
                (if (req.method == .head) try self.matchIn(.get, req, path, segments.items, offsets.items) else null) orelse
                try self.matchIn(null, req, path, segments.items, offsets.items);
            if (route) |r| {
                req.route = &r.info;
                return r.*;
            }
            return null;
        }

        /// The methods with a route for `req`'s path, as an `Allow` value
        /// ("GET, HEAD, POST"), when there is none for its own method.
        /// Null when no method has one either: a 404, not a 405. For
        /// the miss path only, after `findHandler` came up empty; it
        /// leaves `req.params` empty.
        pub fn allowedMethods(self: *const Self, req: *Request) !?[]const u8 {
            return self.methodMiss(req, null);
        }

        /// What a request no route matched runs: `allow` as
        /// `allowedMethods` gives it, and the middleware to run before the
        /// 404 or 405. That is the global middleware, except for an
        /// OPTIONS request to a path with routes for other methods (a CORS
        /// preflight), which runs the middleware of the route it asks
        /// about (`Access-Control-Request-Method`), or else of one of them:
        /// so a `Cors` middleware in a group answers the preflights for
        /// the group's routes.
        pub fn miss(self: *const Self, req: *Request) !Miss {
            var route: ?*const Route = null;
            const allow = try self.methodMiss(req, if (req.method == .options) &route else null);
            return .{
                .allow = allow,
                .middlewares = if (route) |r| r.middlewares else self.middlewares,
            };
        }

        pub const Miss = struct {
            allow: ?[]const u8,
            middlewares: []const Middleware(Ctx),
        };

        fn methodMiss(self: *const Self, req: *Request, preflight_route: ?*?*const Route) !?[]const u8 {
            const wanted: ?Method = if (preflight_route != null)
                (if (req.headers.get("Access-Control-Request-Method")) |m| methodNamed(m) else null)
            else
                null;
            const path = if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
            const max_segments = std.mem.count(u8, path, "/") + 1;
            const segments = try req.arena.alloc([]const u8, max_segments);
            const offsets = try req.arena.alloc(usize, max_segments);
            var n: usize = 0;
            var offset: usize = 0;
            var iter = std.mem.splitScalar(u8, path, '/');
            while (iter.next()) |segment| {
                if (segment.len > 0) {
                    segments[n] = segment;
                    offsets[n] = offset;
                    n += 1;
                }
                offset += segment.len + 1;
            }
            defer req.params.map.clearRetainingCapacity();

            var allow: std.ArrayList(u8) = .empty;
            var has_get = false;
            var has_head = false;
            for (std.enums.values(Method)) |m| {
                if (m == req.method) continue;
                req.params.map.clearRetainingCapacity();
                const route = self.matchIn(m, req, path, segments[0..n], offsets[0..n]) catch continue;
                if (route == null) continue;
                if (preflight_route) |out| {
                    if (out.* == null or m == wanted) out.* = route;
                }
                if (m == .get) has_get = true;
                if (m == .head) has_head = true;
                if (allow.items.len > 0) try allow.appendSlice(req.arena, ", ");
                try allow.print(req.arena, "{f}", .{m});
            }
            // A GET route answers HEAD too (see `findHandler`).
            if (has_get and !has_head and req.method != .head) try allow.appendSlice(req.arena, ", HEAD");
            return if (allow.items.len == 0) null else allow.items;
        }

        fn methodNamed(text: []const u8) ?Method {
            for (std.enums.values(Method)) |m| if (std.mem.eql(u8, m.name(), text)) return m;
            return null;
        }

        fn matchIn(
            self: *const Self,
            method: ?Method,
            req: *Request,
            path: []const u8,
            segments: []const []const u8,
            offsets: []const usize,
        ) !?*const Route {
            const root = (if (method) |m| self.trees[@backingInt(m)] else self.any_tree) orelse return null;
            const node = try matchRecursive(root, req, path, segments, offsets, 0) orelse return null;
            const opaque_route = node.route orelse return null;
            return @ptrCast(@alignCast(opaque_route));
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .get, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn head(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .head, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn post(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .post, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn put(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .put, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn delete(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .delete, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn patch(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .patch, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn options(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .options, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        pub fn query(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, .query, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        /// Registers `handler` for `method` (null: every method, as `any`)
        /// together with `data`, which the handler reads back as
        /// `req.route.?.data`: per-route state for handlers that are the
        /// same function for several routes or registrations. `data` must
        /// outlive the router.
        pub fn addRoute(self: *Self, method: ?Method, path: []const u8, handler: Handler, data: ?*const anyopaque) void {
            self.insertRoute(path, method, handler, self.middlewares, .{ .data = data }) catch @panic("OOM");
        }

        /// Registers `handler` for `method` (null: every method, as `any`)
        /// with `opts`.
        pub fn addRouteWith(self: *Self, method: ?Method, path: []const u8, handler: Handler, opts: RouteOptions) void {
            self.insertRoute(path, method, handler, self.middlewares, opts) catch @panic("OOM");
        }

        /// Whether the route a request for `method` and `url` would get was
        /// registered `no_wait`: the same route `findHandler` picks, found
        /// without touching a request. False when no route matches.
        pub fn noWait(self: *const Self, method: Method, url: []const u8) bool {
            if (!self.has_no_wait) return false;
            const path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url;
            if (self.staticRoute(method, path)) |r| return r.no_wait;
            const found = self.peekIn(method, path) orelse
                (if (method == .head) self.peekIn(.get, path) else null) orelse
                self.peekIn(null, path) orelse return false;
            return found.no_wait;
        }

        /// `matchIn` without capturing parameters.
        fn peekIn(self: *const Self, method: ?Method, path: []const u8) ?*const Route {
            const root = (if (method) |m| self.trees[@backingInt(m)] else self.any_tree) orelse return null;
            const node = peekRecursive(root, path, 0) orelse return null;
            const opaque_route = node.route orelse return null;
            return @ptrCast(@alignCast(opaque_route));
        }

        /// `matchRecursive` over the path's segments from `start`, in the
        /// same order (static, then parameter, then wildcard), recording
        /// nothing.
        fn peekRecursive(node: *Node, path: []const u8, start: usize) ?*Node {
            var i = start;
            while (i < path.len and path[i] == '/') i += 1;
            if (i >= path.len) return if (node.route != null) node else null;
            const end = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
            const segment = path[i..end];
            var child = node.static_children;
            while (child) |c| : (child = c.next_sibling) {
                if (std.mem.eql(u8, c.segment, segment)) {
                    if (peekRecursive(c, path, end)) |found| return found;
                }
            }
            if (node.param_child) |c| if (peekRecursive(c, path, end)) |found| return found;
            if (node.wildcard_child) |c| return c;
            return null;
        }

        /// Matches every method, for requests that no route of their own
        /// method matches (or, for HEAD, of GET). A route of one method
        /// conflicts with an `any` route when both match some path and its
        /// own path is not more specific, and registering the second of the
        /// two panics.
        pub fn any(self: *Self, path: []const u8, handler: Handler) void {
            self.insertRoute(path, null, handler, self.middlewares, .{}) catch @panic("OOM");
        }

        /// Serves the files under `dir` at `prefix`: `GET prefix/a/b.css` is
        /// `a/b.css` in `dir`, and a HEAD is answered the same way without
        /// the body. A path that leaves `dir` with `..` is a 404, and so is
        /// one naming nothing to serve. `dir` must stay open while the
        /// router is in use.
        pub fn static(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions) void {
            self.addStatic(prefix, dir, opts, self.middlewares);
        }

        fn addStatic(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions, middlewares: []const Middleware(Ctx)) void {
            const alloc = self.arena.allocator();
            const files = alloc.create(Static) catch @panic("OOM");
            files.* = .{ .dir = dir, .options = opts };
            if (opts.index) |index| files.options.index = alloc.dupe(u8, index) catch @panic("OOM");
            files.options.precompressed = alloc.dupe(Precompressed, opts.precompressed) catch @panic("OOM");
            if (opts.cache_control) |cc| files.options.cache_control = alloc.dupe(u8, cc) catch @panic("OOM");
            const base = std.mem.trimEnd(u8, prefix, "/");
            // The directory itself, for its index.
            self.insertRoute(if (base.len == 0) "/" else base, .get, staticAction, middlewares, .{ .data = files }) catch @panic("OOM");
            const files_path = std.fmt.allocPrint(alloc, "{s}/*" ++ Static.param, .{base}) catch @panic("OOM");
            self.insertRoute(files_path, .get, staticAction, middlewares, .{ .data = files }) catch @panic("OOM");
        }

        /// Serves `data` at `path`, usually a file embedded with
        /// `@embedFile`, with the same conditional and `Range` handling as
        /// `static`. There is no `Last-Modified`; the `ETag` is a hash of
        /// the content. `data` must outlive the router.
        pub fn embedded(self: *Self, path: []const u8, data: []const u8, opts: EmbeddedOptions) void {
            self.addEmbedded(path, data, opts, self.middlewares);
        }

        fn addEmbedded(self: *Self, path: []const u8, data: []const u8, opts: EmbeddedOptions, middlewares: []const Middleware(Ctx)) void {
            const alloc = self.arena.allocator();
            const file = alloc.create(Embedded) catch @panic("OOM");
            file.* = Embedded.init(alloc, path, data, opts) catch @panic("OOM");
            self.insertRoute(path, .get, plainAction(Embedded.handle), middlewares, .{ .data = file }) catch @panic("OOM");
        }

        const staticAction = plainAction(Static.handle);

        fn plainAction(comptime handler: fn (*Request, *Response) anyerror!void) Handler {
            return if (Ctx == void) handler else struct {
                fn handle(_: *Ctx, req: *Request, res: *Response) anyerror!void {
                    return handler(req, res);
                }
            }.handle;
        }

        /// Routes under `prefix` that run `middlewares` after the global
        /// ones. The list is copied, so it may be a temporary (`&.{mw}`)
        /// on a frame that returns before the server runs; the
        /// middlewares it points at must still outlive the router.
        pub fn group(self: *Self, prefix: []const u8, middlewares: []const Middleware(Ctx)) Group {
            const owned = self.arena.allocator().dupe(Middleware(Ctx), middlewares) catch @panic("OOM");
            return .{ .router = self, .prefix = prefix, .middlewares = owned };
        }

        /// Adds a global middleware, run before every route's own, in the
        /// order added. Routes take the global middleware when they are
        /// registered, so this must come first: it panics once a route
        /// exists, rather than leave earlier routes without it.
        pub fn use(self: *Self, middleware: Middleware(Ctx)) void {
            if (self.has_routes) @panic("router.use() after a route was registered: add middleware first");
            const list = self.arena.allocator().alloc(Middleware(Ctx), self.middlewares.len + 1) catch @panic("OOM");
            @memcpy(list[0..self.middlewares.len], self.middlewares);
            list[self.middlewares.len] = middleware;
            self.middlewares = list;
        }

        pub const Group = struct {
            router: *Self,
            prefix: []const u8,
            middlewares: []const Middleware(Ctx),

            fn mergeMiddlewares(g: Group) []const Middleware(Ctx) {
                if (g.router.middlewares.len == 0) return g.middlewares;
                if (g.middlewares.len == 0) return g.router.middlewares;
                const merged = g.router.arena.allocator().alloc(Middleware(Ctx), g.router.middlewares.len + g.middlewares.len) catch @panic("OOM");
                @memcpy(merged[0..g.router.middlewares.len], g.router.middlewares);
                @memcpy(merged[g.router.middlewares.len..], g.middlewares);
                return merged;
            }

            /// A group inside this one: its prefix after this one's, its
            /// middleware after this one's.
            pub fn group(g: Group, prefix: []const u8, middlewares: []const Middleware(Ctx)) Group {
                const alloc = g.router.arena.allocator();
                const merged = alloc.alloc(Middleware(Ctx), g.middlewares.len + middlewares.len) catch @panic("OOM");
                @memcpy(merged[0..g.middlewares.len], g.middlewares);
                @memcpy(merged[g.middlewares.len..], middlewares);
                return .{ .router = g.router, .prefix = g.concatPath(prefix), .middlewares = merged };
            }

            fn concatPath(g: Group, path: []const u8) []const u8 {
                return std.fmt.allocPrint(g.router.arena.allocator(), "{s}{s}", .{ g.prefix, path }) catch @panic("OOM");
            }

            fn register(g: Group, method: ?Method, path: []const u8, handler: Handler) void {
                g.addRouteWith(method, path, handler, .{});
            }

            /// Registers `handler` for `method` (null: every method) under
            /// the group's prefix and middleware, with `opts`.
            pub fn addRouteWith(g: Group, method: ?Method, path: []const u8, handler: Handler, opts: RouteOptions) void {
                g.router.insertRoute(g.concatPath(path), method, handler, g.mergeMiddlewares(), opts) catch @panic("OOM");
            }

            pub fn get(g: Group, path: []const u8, handler: Handler) void {
                g.register(.get, path, handler);
            }

            pub fn head(g: Group, path: []const u8, handler: Handler) void {
                g.register(.head, path, handler);
            }

            pub fn post(g: Group, path: []const u8, handler: Handler) void {
                g.register(.post, path, handler);
            }

            pub fn put(g: Group, path: []const u8, handler: Handler) void {
                g.register(.put, path, handler);
            }

            pub fn delete(g: Group, path: []const u8, handler: Handler) void {
                g.register(.delete, path, handler);
            }

            pub fn patch(g: Group, path: []const u8, handler: Handler) void {
                g.register(.patch, path, handler);
            }

            pub fn options(g: Group, path: []const u8, handler: Handler) void {
                g.register(.options, path, handler);
            }

            pub fn query(g: Group, path: []const u8, handler: Handler) void {
                g.register(.query, path, handler);
            }

            pub fn any(g: Group, path: []const u8, handler: Handler) void {
                g.register(null, path, handler);
            }

            pub fn static(g: Group, prefix: []const u8, dir: std.Io.Dir, opts: StaticOptions) void {
                g.router.addStatic(g.concatPath(prefix), dir, opts, g.mergeMiddlewares());
            }

            pub fn embedded(g: Group, path: []const u8, data: []const u8, opts: EmbeddedOptions) void {
                g.router.addEmbedded(g.concatPath(path), data, opts, g.mergeMiddlewares());
            }
        };

        fn parseQueryString(req: *Request, query_string: []const u8) !void {
            if (query_string.len == 0) return;

            // Count '&' to estimate capacity (upper bound on number of key-value pairs)
            // Number of segments = ampersands + 1
            const ampersand_count = std.mem.count(u8, query_string, "&");
            const max_params = @min(ampersand_count + 1, req._config.max_query_count);

            // Pre-allocate capacity for the query hashmap
            try req.query.map.ensureTotalCapacity(req.arena, @intCast(max_params));

            var it = std.mem.splitScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (pair.len == 0) continue;

                // Check query count limit
                if (req.query.count() >= req._config.max_query_count) {
                    return error.TooManyQueryParams;
                }

                if (std.mem.indexOfScalar(u8, pair, '=')) |sep| {
                    const key = try Request.urlUnescape(req.arena, pair[0..sep]);
                    const value = try Request.urlUnescape(req.arena, pair[sep + 1 ..]);
                    req.query.map.putAssumeCapacity(key, value);
                } else {
                    const key = try Request.urlUnescape(req.arena, pair);
                    req.query.map.putAssumeCapacity(key, "");
                }
            }
        }
    };
}

/// Whether some request path matches both, and `method_path` matches some
/// path `any_path` doesn't. Segments are literals, `:param` matching one
/// segment, and `*wildcard` matching one or more.
fn conflicts(method_path: []const u8, any_path: []const u8) bool {
    var it1 = std.mem.tokenizeScalar(u8, method_path, '/');
    var it2 = std.mem.tokenizeScalar(u8, any_path, '/');
    var more_general = false;
    while (true) {
        const s1 = it1.next() orelse return more_general and it2.next() == null;
        const s2 = it2.next() orelse return false;
        if (s1[0] == '*') return s2[0] != '*' or more_general;
        if (s2[0] == '*') return more_general;
        if (s1[0] == ':') {
            if (s2[0] != ':') more_general = true;
        } else if (s2[0] != ':' and !std.mem.eql(u8, s1, s2)) {
            return false;
        }
    }
}

// Tests
const TestRouter = Router(TestContext);

const TestContext = struct {
    called: bool = false,
};

fn testHandler(ctx: *TestContext, req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
    ctx.called = true;
}

fn testHandler2(ctx: *TestContext, req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
    _ = ctx;
}

test "Router: register and find GET route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: register and find POST route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.post("/posts", testHandler);

    var req = Request{
        .method = .post,
        .url = "/posts",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: method mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .post,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler == null);
}

test "Router: path mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .get,
        .url = "/posts",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler == null);
}

test "Router: parameterized routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: multiple routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);
    router.post("/users", testHandler2);
    router.get("/posts", testHandler2);

    // Find first route
    var req1 = Request{
        .method = .get,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const handler1 = try router.findHandler(&req1);
    try std.testing.expect(handler1 != null);
    try std.testing.expect(handler1.?.action == testHandler);

    // Find second route
    var req2 = Request{
        .method = .post,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const handler2 = try router.findHandler(&req2);
    try std.testing.expect(handler2 != null);
    try std.testing.expect(handler2.?.action == testHandler2);

    // Find third route
    var req3 = Request{
        .method = .get,
        .url = "/posts",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const handler3 = try router.findHandler(&req3);
    try std.testing.expect(handler3 != null);
    try std.testing.expect(handler3.?.action == testHandler2);
}

test "Router: all HTTP methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.any("/resource", testHandler);

    for ([_]Method{ .get, .head, .post, .query, .trace, .propfind }) |method| {
        var req = Request{
            .method = method,
            .url = "/resource",
            .arena = arena.allocator(),
            ._parser = undefined,
            ._transport = undefined,
        };
        const handler = try router.findHandler(&req);
        try std.testing.expect(handler != null);
    }
}

test "Router: extract single parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);
}

test "Router: the matched route is on the request, by its pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api", &.{});
    api.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/users/123",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    _ = try router.findHandler(&req);
    try std.testing.expectEqualStrings("/api/users/:id", req.route.?.path);

    req.url = "/nowhere";
    _ = try router.findHandler(&req);
    try std.testing.expectEqual(null, req.route);
}

test "Router: addRoute hands its data to the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const first: u32 = 1;
    const second: u32 = 2;
    router.addRoute(.post, "/one", testHandler, &first);
    router.addRoute(.post, "/two", testHandler, &second);
    router.post("/plain", testHandler);

    var req = Request{
        .method = .post,
        .url = "/two",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    _ = try router.findHandler(&req);
    try std.testing.expectEqual(@as(u32, 2), @as(*const u32, @ptrCast(@alignCast(req.route.?.data.?))).*);
    req.url = "/one";
    _ = try router.findHandler(&req);
    try std.testing.expectEqual(@as(u32, 1), @as(*const u32, @ptrCast(@alignCast(req.route.?.data.?))).*);
    req.url = "/plain";
    _ = try router.findHandler(&req);
    try std.testing.expectEqual(null, req.route.?.data);
}

test "Router: extract multiple parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:userId/posts/:postId", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/456/posts/789",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const userId = req.params.get("userId");
    try std.testing.expect(userId != null);
    try std.testing.expectEqualStrings("456", userId.?);

    const postId = req.params.get("postId");
    try std.testing.expect(postId != null);
    try std.testing.expectEqualStrings("789", postId.?);
}

test "Router: mixed static and parameter segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/v1/users/:id/profile", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/v1/users/abc123/profile",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("abc123", id.?);
}

test "Router: static route has precedence over param route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    // Register static route first, then param route (reversed order)
    router.get("/users/new", testHandler2);
    router.get("/users/:id", testHandler);

    // Should match static route, not param route
    var req = Request{
        .method = .get,
        .url = "/users/new",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Params should be empty (no :id captured)
    try std.testing.expect(req.params.get("id") == null);
}

test "Router: a static path finds what the tree walk would, in any spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);
    router.get("//users/new/", testHandler2);
    router.post("/users/new", testHandler);
    router.get("/", testHandler2);
    router.get("/files/*rest", testHandler);

    const cases = [_]struct { method: Method, url: []const u8, want: ?*const TestRouter.Handler }{
        .{ .method = .get, .url = "/users/new", .want = testHandler2 },
        .{ .method = .get, .url = "/users//new/", .want = testHandler2 },
        .{ .method = .get, .url = "/users/new?x=1", .want = testHandler2 },
        .{ .method = .post, .url = "/users/new", .want = testHandler },
        .{ .method = .get, .url = "/users/7", .want = testHandler },
        .{ .method = .get, .url = "/", .want = testHandler2 },
        .{ .method = .get, .url = "", .want = testHandler2 },
        .{ .method = .get, .url = "/files/a/b", .want = testHandler },
        .{ .method = .put, .url = "/users/new", .want = null },
        // A GET route answers HEAD, through the tree.
        .{ .method = .head, .url = "/users/new", .want = testHandler2 },
    };
    for (cases) |case| {
        var req = Request{
            .method = case.method,
            .url = case.url,
            .arena = arena.allocator(),
            ._parser = undefined,
            ._transport = undefined,
        };
        const found = try router.findHandler(&req);
        if (case.want) |want| {
            try std.testing.expect(found != null);
            try std.testing.expect(found.?.action == want);
        } else try std.testing.expect(found == null);
    }
}

test "Router: wildcard route basic matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/document.txt",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);
}

test "Router: wildcard captures remaining path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/path/to/file.txt",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("path/to/file.txt", path.?);
}

test "Router: static route has precedence over wildcard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);
    router.get("/files/config.json", testHandler2);

    var req = Request{
        .method = .get,
        .url = "/files/config.json",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Wildcard param should not be captured
    try std.testing.expect(req.params.get("path") == null);
}

test "Router: param route has precedence over wildcard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/*catchall", testHandler);
    router.get("/api/:id", testHandler2);

    var req = Request{
        .method = .get,
        .url = "/api/123",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler2);

    // Should capture :id param, not wildcard
    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);
    try std.testing.expect(req.params.get("catchall") == null);
}

test "Router: wildcard with multiple segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/assets/*filepath", testHandler);

    var req = Request{
        .method = .get,
        .url = "/assets/images/icons/logo.png",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const filepath = req.params.get("filepath");
    try std.testing.expect(filepath != null);
    try std.testing.expectEqualStrings("images/icons/logo.png", filepath.?);
}

test "Router: wildcard with prefix path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/api/v1/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/api/v1/files/docs/readme.md",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("docs/readme.md", path.?);
}

test "Router: static route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/profile", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/profile?debug=true&page=1",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("true", req.query.get("debug").?);
    try std.testing.expectEqualStrings("1", req.query.get("page").?);
}

test "Router: param route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123?format=json",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);
    try std.testing.expect(handler.?.action == testHandler);

    // Parameter should not include query string
    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("json", req.query.get("format").?);
}

test "Router: multiple params with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:userId/posts/:postId", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/456/posts/789?include=comments&sort=date",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    // Parameters should not include query string
    const userId = req.params.get("userId");
    try std.testing.expect(userId != null);
    try std.testing.expectEqualStrings("456", userId.?);

    const postId = req.params.get("postId");
    try std.testing.expect(postId != null);
    try std.testing.expectEqualStrings("789", postId.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("comments", req.query.get("include").?);
    try std.testing.expectEqualStrings("date", req.query.get("sort").?);
}

test "Router: wildcard route with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/files/*path", testHandler);

    var req = Request{
        .method = .get,
        .url = "/files/docs/readme.md?download=true",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    // Wildcard should not include query string
    const path = req.params.get("path");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("docs/readme.md", path.?);

    // Query parameters should be parsed
    try std.testing.expectEqualStrings("true", req.query.get("download").?);
}

test "Router: empty query string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123?",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // Empty query parameters
    try std.testing.expectEqual(0, req.query.count());
}

test "Router: no query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .get,
        .url = "/users/123",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    const id = req.params.get("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("123", id.?);

    // No query parameters
    try std.testing.expectEqual(0, req.query.count());
}

test "Router: URL encoded query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/search", testHandler);

    var req = Request{
        .method = .get,
        .url = "/search?q=hello+world&tag=foo%20bar&special=%21%40%23%24",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    // URL decoding: + -> space, %20 -> space, %XX -> byte
    try std.testing.expectEqualStrings("hello world", req.query.get("q").?);
    try std.testing.expectEqualStrings("foo bar", req.query.get("tag").?);
    try std.testing.expectEqualStrings("!@#$", req.query.get("special").?);
}

test "Router: query parameter without value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/items", testHandler);

    var req = Request{
        .method = .get,
        .url = "/items?featured&sort=name",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    // Parameters without values should have empty string value
    try std.testing.expectEqualStrings("", req.query.get("featured").?);
    try std.testing.expectEqualStrings("name", req.query.get("sort").?);
}

test "Router: query with empty key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/test", testHandler);

    var req = Request{
        .method = .get,
        .url = "/test?a=1&&b=2&",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };

    const handler = try router.findHandler(&req);
    try std.testing.expect(handler != null);

    // Should handle double && and trailing &
    try std.testing.expectEqualStrings("1", req.query.get("a").?);
    try std.testing.expectEqualStrings("2", req.query.get("b").?);
    try std.testing.expectEqual(2, req.query.count());
}

// Group tests

const TestVoidRouter = Router(void);

fn voidHandler1(req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
}

fn voidHandler2(req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
}

test "Group: prefix concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api/v1", &.{});
    api.get("/users", testHandler);
    api.post("/users", testHandler2);

    var req1 = Request{
        .method = .get,
        .url = "/api/v1/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route1 = try router.findHandler(&req1);
    try std.testing.expect(route1 != null);
    try std.testing.expect(route1.?.action == testHandler);

    var req2 = Request{
        .method = .post,
        .url = "/api/v1/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route2 = try router.findHandler(&req2);
    try std.testing.expect(route2 != null);
    try std.testing.expect(route2.?.action == testHandler2);
}

test "Group: routes without group middleware get global middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Chain(void)) !void {}
    };

    var mw1 = TestMw{ .id = 1 };
    var mw2 = TestMw{ .id = 2 };
    router.middlewares = &.{ Middleware(void).init(&mw1), Middleware(void).init(&mw2) };

    router.get("/direct", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/direct",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route = try router.findHandler(&req);
    try std.testing.expect(route != null);
    try std.testing.expectEqual(2, route.?.middlewares.len);
}

test "Group: group middlewares appended after global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Chain(void)) !void {}
    };

    var mw_global = TestMw{ .id = 1 };
    var mw_group = TestMw{ .id = 2 };
    router.middlewares = &.{Middleware(void).init(&mw_global)};

    const api = router.group("/api", &.{Middleware(void).init(&mw_group)});
    api.get("/users", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/api/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route = try router.findHandler(&req);
    try std.testing.expect(route != null);
    // Should have global + group middlewares
    try std.testing.expectEqual(2, route.?.middlewares.len);
    // Global middleware should come first
    try std.testing.expect(route.?.middlewares[0].ptr == @as(*anyopaque, @ptrCast(@constCast(&mw_global))));
    try std.testing.expect(route.?.middlewares[1].ptr == @as(*anyopaque, @ptrCast(@constCast(&mw_group))));
}

test "Group: no global middlewares, only group middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Chain(void)) !void {}
    };

    var mw_group = TestMw{ .id = 1 };
    const api = router.group("/api", &.{Middleware(void).init(&mw_group)});
    api.get("/users", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/api/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route = try router.findHandler(&req);
    try std.testing.expect(route != null);
    try std.testing.expectEqual(1, route.?.middlewares.len);
}

test "Group: keeps its own copy of the middleware list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    const TestMw = struct {
        id: u8,
        pub fn execute(_: *const @This(), _: *Request, _: *Response, _: *@import("middleware.zig").Chain(void)) !void {}
    };

    var mw_group = TestMw{ .id = 1 };
    var mw_other = TestMw{ .id = 2 };
    // The caller's list, gone (here: overwritten) once `group` returns,
    // as a `&.{mw}` on a helper's frame is when the server runs.
    var list = [_]Middleware(void){Middleware(void).init(&mw_group)};
    const api = router.group("/api", &list);
    list[0] = Middleware(void).init(&mw_other);
    api.get("/users", voidHandler1);
    api.group("/v1", &.{}).get("/users", voidHandler1);

    for ([_][]const u8{ "/api/users", "/api/v1/users" }) |url| {
        var req = Request{
            .method = .get,
            .url = url,
            .arena = arena.allocator(),
            ._parser = undefined,
            ._transport = undefined,
        };
        const route = try router.findHandler(&req);
        try std.testing.expect(route != null);
        try std.testing.expectEqual(1, route.?.middlewares.len);
        try std.testing.expect(route.?.middlewares[0].ptr == @as(*anyopaque, @ptrCast(&mw_group)));
    }
}

test "Group: direct routes have no middlewares when none set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestVoidRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/health", voidHandler1);

    var req = Request{
        .method = .get,
        .url = "/health",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    const route = try router.findHandler(&req);
    try std.testing.expect(route != null);
    try std.testing.expectEqual(0, route.?.middlewares.len);
}

test "Group: any method registers all methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    const api = router.group("/api", &.{});
    api.any("/resource", testHandler);

    for ([_]Method{ .get, .head, .post, .query, .trace, .propfind }) |method| {
        var req = Request{
            .method = method,
            .url = "/api/resource",
            .arena = arena.allocator(),
            ._parser = undefined,
            ._transport = undefined,
        };
        const route = try router.findHandler(&req);
        try std.testing.expect(route != null);
    }
}

test "Router: QUERY route" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.query("/search", testHandler);
    router.group("/api", &.{}).query("/search", testHandler2);

    var req = Request{
        .method = .query,
        .url = "/search",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(&req)).?.action);
    req.url = "/api/search";
    try std.testing.expectEqual(&testHandler2, (try router.findHandler(&req)).?.action);

    req.method = .get;
    try std.testing.expect(try router.findHandler(&req) == null);
}

test "Router: any() comes after the method's own routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/x", testHandler);
    router.any("/x", testHandler2);
    router.any("/users/:id", testHandler2);
    router.get("/users/me", testHandler);

    const cases = [_]struct { Method, []const u8, *const TestRouter.Handler }{
        .{ .get, "/x", testHandler },
        .{ .head, "/x", testHandler },
        .{ .post, "/x", testHandler2 },
        .{ .get, "/users/me", testHandler },
        .{ .get, "/users/1", testHandler2 },
        .{ .post, "/users/me", testHandler2 },
    };
    for (cases) |case| {
        var req = Request{
            .method = case[0],
            .url = case[1],
            .arena = arena.allocator(),
            ._parser = undefined,
            ._transport = undefined,
        };
        try std.testing.expectEqual(case[2], (try router.findHandler(&req)).?.action);
    }
}

test "Router: a method route conflicts with a more specific any() route" {
    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();
    router.get("/users/:id", testHandler);
    router.get("/a/:x", testHandler);
    router.any("/b/:y", testHandler2);
    const c1 = router.findConflict("/users/me", null).?;
    try std.testing.expectEqualStrings("/users/:id", c1.method_path);

    var router2 = TestRouter.init(std.testing.allocator);
    defer router2.deinit();
    router2.any("/users/me", testHandler2);
    const c2 = router2.findConflict("/users/:id", .get).?;
    try std.testing.expectEqualStrings("/users/me", c2.any_path);

    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "/x", "/x", false },
        .{ "/users/me", "/users/:id", false },
        .{ "/users/:id", "/users/me", true },
        .{ "/a/:x", "/b/:y", false },
        .{ "/:x/b", "/a/:y", true },
        .{ "/files/*p", "/files/a", true },
        .{ "/files/a/b", "/files/*p", false },
        .{ "/files/*p", "/files/*q", false },
        .{ "/files", "/files/*p", false },
        .{ "/*", "/a/*p", true },
        .{ "/a/*p", "/*", false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case[2], conflicts(case[0], case[1]));
    }
}

test "Router: record_conflicts keeps the first conflict and leaves the route out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();
    router.record_conflicts = true;
    router.get("/users/:id", testHandler);
    router.get("/users/:name/posts", testHandler2);
    try std.testing.expectEqualStrings("route /users/:name/posts: :name conflicts with :id, registered at the same position by another route", router.conflict.?);
    router.get("/users/:id", testHandler2);
    router.any("/a/b", testHandler);
    router.get("/a/:x", testHandler);
    // Still the first.
    try std.testing.expect(std.mem.indexOf(u8, router.conflict.?, ":name") != null);
    // What was registered before stands, and the duplicate did not replace it.
    var req = Request{
        .method = .get,
        .url = "/users/7",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(&req)).?.action);
}

test "Router: a GET route answers HEAD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(&req)).?.action);

    // The fallback is HEAD's alone; nothing else borrows from GET.
    req.method = .post;
    try std.testing.expect(try router.findHandler(&req) == null);
    req.url = "/nothing";
    req.method = .head;
    try std.testing.expect(try router.findHandler(&req) == null);
}

test "Router: an explicit HEAD route wins over the GET one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users", testHandler);
    router.head("/users", testHandler2);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(&testHandler2, (try router.findHandler(&req)).?.action);

    req.method = .get;
    try std.testing.expectEqual(&testHandler, (try router.findHandler(&req)).?.action);
}

test "Router: HEAD falls back per path, not per tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    // A HEAD tree exists because of /other, but /users is not in it.
    router.head("/other", testHandler2);
    router.get("/users", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expectEqual(&testHandler, (try router.findHandler(&req)).?.action);
}

test "Router: HEAD falling back to GET still captures path params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = TestRouter.init(std.testing.allocator);
    defer router.deinit();

    router.get("/users/:id", testHandler);

    var req = Request{
        .method = .head,
        .url = "/users/42",
        .arena = arena.allocator(),
        ._parser = undefined,
        ._transport = undefined,
    };
    try std.testing.expect(try router.findHandler(&req) != null);
    try std.testing.expectEqualStrings("42", req.params.get("id").?);
}
