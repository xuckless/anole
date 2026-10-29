//! `zig build lint`: SAFETY.md E2, a check of the Zig sources on
//! `std.zig.Ast` (the parser `zig fmt` uses). The tree gives each token its
//! context: test code (`test` declarations), its function, its statement.
//! Comments are not in the tree, so `// SAFETY:` reasons are read from the
//! source lines: on the hit's line, or in the comment lines just above the
//! hit's line or its statement's first line. A file that does not parse is
//! a PARSE hit.
//!
//! - T1: a task spawned outside a group. `placement.concurrent` (a group,
//!   placed) is the way; a Future from `io.concurrent`/`io.async` is allowed
//!   only as a local that the same function cancels or awaits; a thread from
//!   `std.Thread.spawn` only when the same file joins it.
//! - U1: a C library's binding imported outside the files allowed to call it.
//! - U3: a pointer cast (`@ptrCast`, `@alignCast`, `@ptrFromInt`,
//!   `@intFromPtr`) or an `undefined` outside a wrapper module, without a
//!   `// SAFETY:` comment on its line or just above its statement. A local
//!   array declared `undefined` (`var buf: [N]T = undefined;`) is Zig's
//!   write-before-read idiom and allowed.
//! - C3: an `error.Canceled` caught and then carried on from, neither
//!   returned nor re-armed (`recancel`).
//! - L2 (L2/L4): a raw lock (`std.Io.Mutex`, `std.atomic.Mutex`,
//!   `std.Io.Condition`, `std.Io.RwLock`) named outside `src/safety/`. The
//!   debug checks see only the ranked `safety.Mutex/SpinLock/Condition`.
//! - T5: in `src/capi/` and in files with an `export fn` (code foreign
//!   threads call), a wake of a runtime task (`.set(io)` on an Event,
//!   `futexWake`, `.signal`/`.broadcast`/`.unlock(io)`, `put`/`putOne` on
//!   a Queue) outside `IoGate`, unless the enclosing function's doc comment
//!   starts with the thread it runs on ("On the executor", "On the capi
//!   task", "Run by the capi task", "On the run thread"). Wakes through
//!   `Threaded` io wake consumer threads and are exempt.
//!
//! Any hit but DOC and PARSE is also allowed with a `// SAFETY:` reason.
//!
//! - DOC: a public doc comment (`///`, `//!`) that names dusty or the
//!   core's build options (`use_http2`, `use_tls`); attribution lines and
//!   identifiers that still carry the name are allowed. Checked in every
//!   file, test files included.
//!
//! Usage: safety_lint [--tests] [--rules=R1,R2] <dir>...   (exit 1 on any hit)
//! `--rules` reports only the named rules (CI runs `--rules=DOC` until the
//! retrofit clears the T1/U1/U3/C3 backlog).
//! Without --tests, test code is skipped: `test` blocks, `*_test.zig`,
//! `*_tests.zig`, `testing.zig`, files under a `testing/` directory and the
//! test runners.
const std = @import("std");
const Ast = std.zig.Ast;
const Token = std.zig.Token;

/// U1: the C binding modules and the files allowed to import them. A
/// library called from more than one file is a named set (an exception to
/// fold into one wrapper at the engine's takeover; listed in SAFETY.md).
const c_libs = [_]struct { modules: []const []const u8, files: []const []const u8 }{
    .{ .modules = &.{ "anole_nghttp2_c", "nghttp2" }, .files = &.{ "src/http/core/server/h2.zig", "src/http/core/client.zig", "src/h2/root.zig", "src/h2/client.zig" } },
    .{ .modules = &.{"anole_boringssl_c"}, .files = &.{ "src/tls/root.zig", "src/tls/dusty_tls.zig", "src/h3/root.zig" } },
    .{ .modules = &.{ "anole_ngtcp2_c", "anole_nghttp3_c" }, .files = &.{ "src/h3/root.zig", "src/h3/layout.zig", "src/h3/ngtcp2.zig", "src/h3/nghttp3.zig", "src/h3/quic_tls.zig", "src/h3/client.zig", "src/h3/session_cache.zig", "src/h3/server.zig", "src/h3/bridge.zig", "src/h3/webtransport.zig", "src/h3/net.zig" } },
    .{ .modules = &.{"anole_yyjson_c"}, .files = &.{"src/json/root.zig"} },
    .{ .modules = &.{"anole_hiredis_c"}, .files = &.{"src/redis/root.zig"} },
    .{ .modules = &.{"anole_upb_c"}, .files = &.{"src/capi/grpc_schema.zig"} },
    .{ .modules = &.{"llhttp"}, .files = &.{ "src/http/core/parser.zig", "src/http/core/http.zig" } },
    .{ .modules = &.{ "zlib", "anole_zlib_c" }, .files = &.{ "src/http/core/root.zig", "src/http/core/response.zig", "src/http/core/parser.zig", "src/compression/root.zig", "src/websocket/deflate.zig", "src/kafka/compress.zig" } },
    .{ .modules = &.{ "zstd", "anole_zstd_c" }, .files = &.{ "src/http/core/zstd_io.zig", "src/http/core/root.zig", "src/compression/root.zig", "src/kafka/compress.zig" } },
    .{ .modules = &.{ "brotli", "anole_brotli_c" }, .files = &.{ "src/http/core/brotli_io.zig", "src/http/core/root.zig", "src/compression/root.zig" } },
    .{ .modules = &.{"anole_lz4_c"}, .files = &.{"src/kafka/compress.zig"} },
    .{ .modules = &.{ "anole_sqlite_c", "sqlite" }, .files = &.{"src/sqlite/root.zig"} },
};

/// U3: modules whose job is the unsafe operations (the shared mechanisms).
const unsafe_modules = [_][]const u8{"src/safety/"};

const Hit = struct { path: []const u8, line: usize, rule: []const u8, msg: []const u8 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var tests = false;
    var rules: ?[]const u8 = null;
    var dirs: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--tests")) {
            tests = true;
        } else if (std.mem.startsWith(u8, a, "--rules=")) {
            rules = a["--rules=".len..];
        } else try dirs.append(arena, a);
    }
    if (dirs.items.len == 0) {
        std.debug.print("usage: safety_lint [--tests] [--rules=R1,R2] <dir>...\n", .{});
        std.process.exit(2);
    }
    var hits: std.ArrayList(Hit) = .empty;
    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList([]const u8) = .empty;
    for (dirs.items) |d| {
        var dir = try cwd.openDir(io, d, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, d, "/"), e.path });
            std.mem.replaceScalar(u8, p, '\\', '/');
            try files.append(arena, p);
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (files.items) |p| {
        const src = try cwd.readFileAllocOptions(io, p, arena, .unlimited, .of(u8), 0);
        try lintSource(arena, p, src, tests, &hits);
    }
    if (rules) |list| {
        var kept: usize = 0;
        for (hits.items) |h| {
            if (!ruleListed(list, h.rule)) continue;
            hits.items[kept] = h;
            kept += 1;
        }
        hits.shrinkRetainingCapacity(kept);
    }
    var buf: [4096]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &out.interface;
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (hits.items) |h| {
        try w.print("{s}:{d}: {s}: {s}\n", .{ h.path, h.line, h.rule, h.msg });
        const gop = try counts.getOrPut(arena, h.rule);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    if (hits.items.len > 0) {
        try w.print("\n{d} hit(s):", .{hits.items.len});
        var it = counts.iterator();
        while (it.next()) |e| try w.print(" {s} {d}", .{ e.key_ptr.*, e.value_ptr.* });
        try w.writeAll(" (SAFETY.md E2)\n");
    }
    try w.flush();
    if (hits.items.len > 0) std.process.exit(1);
}

/// Every rule over one file: DOC everywhere, the SAFETY.md rules outside
/// test files.
fn lintSource(arena: std.mem.Allocator, path: []const u8, src: [:0]const u8, tests: bool, hits: *std.ArrayList(Hit)) !void {
    try docNames(arena, path, src, hits);
    if (!tests and isTestFile(path)) return;
    try lintFile(arena, path, src, tests, hits);
}

/// DOC: public doc comments speak Anole's names, not the HTTP core's
/// origin (dusty) or its internal build options.
fn docNames(arena: std.mem.Allocator, path: []const u8, src: []const u8, hits: *std.ArrayList(Hit)) !void {
    const allowed = [_][]const u8{ "Adapted from", "adapted from", "lalinsky/dusty", "xuckless/dusty", "LICENSE.dusty", "dusty_tls", "`dusty.", "dusty_mod", "`dusty`" };
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    next: while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "///") and !std.mem.startsWith(u8, line, "//!")) continue;
        const names = std.mem.indexOf(u8, line, "dusty") != null or std.mem.indexOf(u8, line, "use_http2") != null or
            std.mem.indexOf(u8, line, "use_tls") != null;
        if (!names) continue;
        for (allowed) |a| if (std.mem.indexOf(u8, line, a) != null) continue :next;
        try hits.append(arena, .{ .path = path, .line = n, .rule = "DOC", .msg = "a public doc comment names dusty or a core build option" });
    }
}

fn ruleListed(list: []const u8, rule: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |r| if (std.mem.eql(u8, std.mem.trim(u8, r, " "), rule)) return true;
    return false;
}

fn isTestFile(p: []const u8) bool {
    const base = std.fs.path.basename(p);
    return std.mem.endsWith(u8, base, "_test.zig") or std.mem.endsWith(u8, base, "_tests.zig") or
        std.mem.eql(u8, base, "testing.zig") or std.mem.eql(u8, base, "test_runner.zig") or
        std.mem.indexOf(u8, p, "/testing/") != null;
}

fn startsWithAny(p: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |pre| if (std.mem.startsWith(u8, p, pre)) return true;
    return false;
}

fn inList(p: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, p, x)) return true;
    return false;
}

/// A file allowed to call some C library: a wrapper module (U3 too).
fn isWrapper(p: []const u8) bool {
    for (c_libs) |l| if (inList(p, l.files)) return true;
    return startsWithAny(p, &unsafe_modules);
}

const none = std.math.maxInt(u32);

/// One file's syntax tree plus, for each token, the context the rules ask
/// about: whether it is in a test, its innermost function, its innermost
/// statement (a block statement or a container member).
const Lint = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    tree: *const Ast,
    tags: []const Token.Tag,
    starts: []const u32,
    hits: *std.ArrayList(Hit),
    line_starts: []const u32,
    in_test: []const bool,
    /// The innermost `fn_decl` holding each token's body, or `none`.
    fn_of: []const u32,
    /// The innermost statement holding each token, or `none`.
    stmt_of: []const u32,
    /// T5 applies: a C ABI file, or one with an `export fn`.
    t5: bool,
    /// Tokens inside `IoGate` (T5's one place for foreign wakes).
    in_gate: []const bool,

    fn text(self: *const Lint, i: usize) []const u8 {
        return self.tree.tokenSlice(@intCast(i));
    }

    fn tag(self: *const Lint, i: usize) Token.Tag {
        return if (i < self.tags.len) self.tags[i] else .eof;
    }

    fn first(self: *const Lint, n: Node) u32 {
        return self.tree.firstToken(n);
    }

    fn last(self: *const Lint, n: Node) u32 {
        return self.tree.lastToken(n);
    }

    fn lineOf(self: *const Lint, i: usize) usize {
        const pos = self.starts[i];
        // The number of line starts at or before pos.
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.line_starts[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn hit(self: *Lint, i: usize, rule: []const u8, msg: []const u8) !void {
        try self.hits.append(self.arena, .{ .path = self.path, .line = self.lineOf(i), .rule = rule, .msg = msg });
    }

    /// The source line holding byte `pos`.
    fn lineAt(self: *const Lint, pos: usize) struct { start: usize, end: usize } {
        const s = if (std.mem.lastIndexOfScalar(u8, self.src[0..pos], '\n')) |n| n + 1 else 0;
        const e = std.mem.indexOfScalarPos(u8, self.src, pos, '\n') orelse self.src.len;
        return .{ .start = s, .end = e };
    }

    /// The first token of the statement holding token i (i itself at
    /// container level outside any member).
    fn stmtStart(self: *const Lint, i: usize) usize {
        const s = self.stmt_of[i];
        return if (s == none) i else self.first(@fromBackingInt(@intCast(s)));
    }

    /// A `// SAFETY:` comment on the token's line, or in the comment lines
    /// just above the token's line or its statement's first line. Comments
    /// are not in the tree, so this reads the source lines.
    fn hasSafetyComment(self: *const Lint, i: usize) bool {
        const l = self.lineAt(self.starts[i]);
        if (std.mem.indexOf(u8, self.src[l.start..l.end], "// SAFETY:") != null) return true;
        for ([_]usize{ i, self.stmtStart(i) }) |anchor| {
            var ls = self.lineAt(self.starts[anchor]).start;
            while (ls > 0) {
                const prev = self.lineAt(ls - 1);
                const line = std.mem.trim(u8, self.src[prev.start..prev.end], " \t\r");
                if (!std.mem.startsWith(u8, line, "//")) break;
                if (std.mem.indexOf(u8, line, "SAFETY:") != null) return true;
                ls = prev.start;
            }
        }
        return false;
    }

    /// The tokens of a node's subtree.
    fn tokensOf(self: *const Lint, n: Node) struct { u32, u32 } {
        return .{ self.first(n), self.last(n) };
    }

    /// An identifier token in [a, b] named `name`, followed by `.` and one
    /// of `fields`.
    fn mentionsField(self: *const Lint, a: u32, b: u32, name: []const u8, fields: []const []const u8) bool {
        var k = a;
        while (k + 2 <= b) : (k += 1) {
            if (self.tags[k] != .identifier or self.tags[k + 1] != .period or self.tags[k + 2] != .identifier) continue;
            if (!std.mem.eql(u8, self.text(k), name)) continue;
            for (fields) |f| if (std.mem.eql(u8, self.text(k + 2), f)) return true;
        }
        return false;
    }
};

const Node = Ast.Node.Index;
const Span = struct { node: u32, first: u32, last: u32 };

/// Writes each span's node over its tokens, outer spans first, so a token
/// ends up with its innermost span.
fn paint(dst: []u32, spans: []Span) void {
    std.mem.sort(Span, spans, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.last - a.first > b.last - b.first;
        }
    }.lt);
    for (spans) |s| @memset(dst[s.first .. s.last + 1], s.node);
}

fn lintFile(arena: std.mem.Allocator, path: []const u8, src: [:0]const u8, tests: bool, hits: *std.ArrayList(Hit)) !void {
    const tree = try arena.create(Ast);
    tree.* = try Ast.parse(arena, src, .{});
    if (tree.errors.len > 0) {
        const t = tree.errors[0].token;
        const line = std.mem.count(u8, src[0..tree.tokens.items(.start)[t]], "\n") + 1;
        try hits.append(arena, .{ .path = path, .line = line, .rule = "PARSE", .msg = "the file does not parse, so the lint cannot check it" });
        return;
    }
    const ntok = tree.tokens.len;
    var line_starts: std.ArrayList(u32) = .empty;
    try line_starts.append(arena, 0);
    for (src, 0..) |c, k| if (c == '\n') try line_starts.append(arena, @intCast(k + 1));

    const in_test = try arena.alloc(bool, ntok);
    @memset(in_test, false);
    const fn_of = try arena.alloc(u32, ntok);
    @memset(fn_of, none);
    const stmt_of = try arena.alloc(u32, ntok);
    @memset(stmt_of, none);
    {
        var fns: std.ArrayList(Span) = .empty;
        var stmts: std.ArrayList(Span) = .empty;
        var buf2: [2]Node = undefined;
        for (0..tree.nodes.len) |k| {
            const n: Node = @fromBackingInt(@intCast(k));
            switch (tree.nodeTag(n)) {
                .test_decl => @memset(in_test[tree.firstToken(n) .. tree.lastToken(n) + 1], true),
                .fn_decl => {
                    const body = tree.nodeData(n).node_and_node[1];
                    try fns.append(arena, .{ .node = @intCast(k), .first = tree.firstToken(body), .last = tree.lastToken(body) });
                },
                else => {},
            }
            const members: []const Node = if (tree.blockStatements(&buf2, n)) |s| s else if (tree.fullContainerDecl(&buf2, n)) |c| c.ast.members else &.{};
            for (members) |m| try stmts.append(arena, .{ .node = @backingInt(m), .first = tree.firstToken(m), .last = tree.lastToken(m) });
        }
        paint(fn_of, fns.items);
        paint(stmt_of, stmts.items);
    }

    const in_gate = try arena.alloc(bool, ntok);
    @memset(in_gate, false);
    for (0..tree.nodes.len) |k| {
        const n: Node = @fromBackingInt(@intCast(k));
        const vd = tree.fullVarDecl(n) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token + 1), "IoGate")) @memset(in_gate[tree.firstToken(n) .. tree.lastToken(n) + 1], true);
    }
    var t5 = std.mem.startsWith(u8, path, "src/capi/");
    for (tree.tokens.items(.tag), 0..) |t, k| {
        if (t == .keyword_export and k + 1 < ntok and tree.tokens.items(.tag)[k + 1] == .keyword_fn) t5 = true;
    }

    var lint: Lint = .{
        .arena = arena,
        .path = path,
        .src = src,
        .tree = tree,
        .tags = tree.tokens.items(.tag),
        .starts = tree.tokens.items(.start),
        .hits = hits,
        .line_starts = line_starts.items,
        .in_test = in_test,
        .fn_of = fn_of,
        .stmt_of = stmt_of,
        .t5 = t5,
        .in_gate = in_gate,
    };
    const wrapper = isWrapper(path);

    // Token rules: U3, U1, L2 (raw locks).
    for (0..ntok) |i| {
        if (!tests and in_test[i]) continue;
        const s = lint.text(i);
        switch (lint.tags[i]) {
            .builtin => {
                if (std.mem.eql(u8, s, "@ptrCast") or std.mem.eql(u8, s, "@alignCast") or std.mem.eql(u8, s, "@ptrFromInt") or std.mem.eql(u8, s, "@intFromPtr")) {
                    // `@ptrCast(@alignCast(x))` is one cast.
                    if (std.mem.eql(u8, s, "@alignCast") and i >= 2 and lint.tag(i - 1) == .l_paren and std.mem.eql(u8, lint.text(i - 2), "@ptrCast")) continue;
                    if (!wrapper and !lint.hasSafetyComment(i))
                        try lint.hit(i, "U3", try std.fmt.allocPrint(arena, "{s} without a // SAFETY: reason (or safety.fromCtx/toCtx)", .{s}));
                } else if (std.mem.eql(u8, s, "@import") and lint.tag(i + 1) == .l_paren and lint.tag(i + 2) == .string_literal) {
                    const name = std.mem.trim(u8, lint.text(i + 2), "\"");
                    for (c_libs) |l| {
                        if (!inList(name, l.modules)) continue;
                        if (!inList(path, l.files)) try lint.hit(i, "U1", try std.fmt.allocPrint(arena, "imports the C binding {s} outside the files allowed to call it", .{name}));
                    }
                } else if (std.mem.eql(u8, s, "@cImport")) {
                    if (!wrapper) try lint.hit(i, "U1", "@cImport outside a wrapper module");
                }
            },
            .keyword_extern => {
                // `extern "c"` is libc (exempt); any other extern is a C call.
                if (lint.tag(i + 1) == .string_literal and std.mem.eql(u8, lint.text(i + 1), "\"c\"")) continue;
                if (lint.tag(i + 1) == .keyword_struct or lint.tag(i + 1) == .keyword_union or lint.tag(i + 1) == .keyword_enum) continue;
                if (!wrapper) try lint.hit(i, "U1", "an extern declaration outside a wrapper module");
            },
            .identifier => if (std.mem.eql(u8, s, "undefined")) {
                if (wrapper) continue;
                if (isLocalArrayDecl(&lint, i)) continue;
                if (lint.hasSafetyComment(i)) continue;
                try lint.hit(i, "U3", "undefined outside a local array declaration, without a // SAFETY: reason");
            } else if (rawLock(&lint, i)) |what| {
                if (startsWithAny(path, &unsafe_modules) or lint.hasSafetyComment(i)) continue;
                try lint.hit(i + 2, "L2", try std.fmt.allocPrint(arena, "a raw {s}: use safety.Mutex/SpinLock/Condition with a rank (L2/L4)", .{what}));
            },
            else => {},
        }
    }

    // Node rules: T1, T5, C3.
    var buf1: [1]Node = undefined;
    for (0..tree.nodes.len) |k| {
        const n: Node = @fromBackingInt(@intCast(k));
        if (!tests and in_test[tree.nodeMainToken(n)]) continue;
        if (tree.fullCall(&buf1, n)) |call| {
            try checkCall(&lint, n, call);
        } else if (tree.fullSwitchCase(n)) |case| {
            for (case.ast.values) |v| {
                if (!isCanceled(&lint, v)) continue;
                try checkCanceled(&lint, tree.lastToken(v), case.ast.target_expr);
            }
        } else if (tree.fullIf(n)) |f| {
            if (canceledComparison(&lint, f.ast.cond_expr)) |tok| try checkCanceled(&lint, tok, f.ast.then_expr);
        }
    }
}

/// L2/L4: `Io.Mutex`, `Io.Condition`, `Io.RwLock` or `atomic.Mutex` at
/// token i (`Io`/`atomic`, the `std.` before it optional): the lock's name,
/// or null.
fn rawLock(l: *const Lint, i: usize) ?[]const u8 {
    if (l.tag(i + 1) != .period or l.tag(i + 2) != .identifier) return null;
    const ns = l.text(i);
    const name = l.text(i + 2);
    if (std.mem.eql(u8, ns, "Io")) {
        for ([_][]const u8{ "Mutex", "Condition", "RwLock" }) |n| if (std.mem.eql(u8, name, n)) return switch (n[0]) {
            'M' => "std.Io.Mutex",
            'C' => "std.Io.Condition",
            else => "std.Io.RwLock",
        };
    } else if (std.mem.eql(u8, ns, "atomic") and std.mem.eql(u8, name, "Mutex")) return "std.atomic.Mutex";
    return null;
}

/// The thread names a C ABI function's doc comment starts with when it
/// runs on the runtime's side (T5).
const runtime_side = [_][]const u8{ "On the executor", "On the capi task", "Run by the capi task", "On the run thread" };

/// T5: in a C ABI file (or one with an `export fn`), a wake of a runtime
/// task goes through an `IoGate`, unless the function says it runs on the
/// runtime's side. Wakes through `Threaded` io wake consumer threads.
fn checkWake(l: *Lint, call: Ast.full.Call, name_tok: u32, recv: ?Node) !void {
    const name = l.text(name_tok);
    const params = call.ast.params;
    const io_node: ?Node = if (std.mem.eql(u8, name, "futexWake"))
        recv
    else if (recv == null)
        null
    else if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "unlock"))
        (if (params.len == 1) params[0] else null)
    else if (std.mem.eql(u8, name, "signal") or std.mem.eql(u8, name, "broadcast") or std.mem.eql(u8, name, "putOne") or std.mem.eql(u8, name, "put"))
        (if (params.len >= 1) params[0] else null)
    else
        null;
    const io = io_node orelse return;
    switch (ioKind(l, io)) {
        .none, .threaded => return,
        .runtime => {},
    }
    if (l.in_gate[name_tok]) return;
    if (runtimeSide(l, name_tok)) return;
    if (l.hasSafetyComment(name_tok)) return;
    try l.hit(name_tok, "T5", try std.fmt.allocPrint(l.arena, "a runtime wake (.{s}) outside an IoGate, in a function whose doc comment does not say it runs on the executor", .{name}));
}

const IoKind = enum { none, runtime, threaded };

/// Whether an expression is an `std.Io`: `io`, `rt_io`, `self.io`,
/// `app.io()`; through `threadedIo()` or `Threaded` it is a consumer's.
fn ioKind(l: *const Lint, n: Node) IoKind {
    const a, const b = l.tokensOf(n);
    const txt = l.src[l.starts[a] .. l.starts[b] + l.text(b).len];
    if (std.mem.indexOf(u8, txt, "threadedIo") != null or std.mem.indexOf(u8, txt, "Threaded") != null) return .threaded;
    // `x.io()`: the name before a final empty call.
    var e = b;
    if (l.tags[e] == .r_paren and e >= 1 and l.tags[e - 1] == .l_paren and e >= 2) e -= 2;
    if (l.tags[e] != .identifier) return .none;
    const id = l.text(e);
    if (std.mem.eql(u8, id, "io") or std.mem.endsWith(u8, id, "_io") or std.mem.endsWith(u8, id, "Io")) return .runtime;
    return .none;
}

/// The function holding token i has a doc comment starting with one of
/// `runtime_side`.
fn runtimeSide(l: *const Lint, i: u32) bool {
    const f = l.fn_of[i];
    if (f == none) return false;
    var t = l.first(@fromBackingInt(@intCast(f)));
    // The doc comment's first line is the earliest doc_comment token
    // before the declaration.
    var top: ?u32 = null;
    while (t > 0 and l.tags[t - 1] == .doc_comment) : (t -= 1) top = t - 1;
    const d = top orelse return false;
    const line = std.mem.trim(u8, l.text(d)["///".len..], " ");
    for (runtime_side) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

/// `var|const name: [..]T = undefined` in a function, with `undefined` the
/// whole initializer.
fn isLocalArrayDecl(l: *const Lint, u: usize) bool {
    if (l.fn_of[u] == none) return false;
    const s = l.stmt_of[u];
    if (s == none) return false;
    const vd = l.tree.fullVarDecl(@fromBackingInt(@intCast(s))) orelse return false;
    const init = vd.ast.init_node.unwrap() orelse return false;
    if (l.tree.nodeMainToken(init) != u or l.tree.nodeTag(init) != .identifier) return false;
    const ty = vd.ast.type_node.unwrap() orelse return false;
    return l.tag(l.first(ty)) == .l_bracket;
}

/// `error.Canceled` as a node.
fn isCanceled(l: *const Lint, n: Node) bool {
    return l.tree.nodeTag(n) == .error_value and std.mem.eql(u8, l.text(l.last(n)), "Canceled");
}

/// The `Canceled` token of an `x == error.Canceled` (either side) anywhere
/// in an `if` condition.
fn canceledComparison(l: *const Lint, cond: Node) ?u32 {
    const a, const b = l.tokensOf(cond);
    var k = a;
    while (k + 3 <= b) : (k += 1) {
        if (l.tags[k] == .equal_equal and l.tags[k + 1] == .keyword_error and l.tags[k + 2] == .period and std.mem.eql(u8, l.text(k + 3), "Canceled")) return k + 3;
        if (l.tags[k] == .keyword_error and l.tags[k + 1] == .period and std.mem.eql(u8, l.text(k + 2), "Canceled") and l.tags[k + 3] == .equal_equal) return k + 2;
    }
    return null;
}

/// T1 over one call: `.concurrent(`/`.async(`, `spawnInto`, `Thread.spawn`.
fn checkCall(l: *Lint, call_node: Node, call: Ast.full.Call) !void {
    const tree = l.tree;
    const callee = call.ast.fn_expr;
    const name_tok: u32, const recv: ?Node = switch (tree.nodeTag(callee)) {
        .field_access => .{ tree.nodeData(callee).node_and_token[1], tree.nodeData(callee).node_and_token[0] },
        .identifier => .{ tree.nodeMainToken(callee), null },
        else => return,
    };
    const name = l.text(name_tok);
    if (l.t5) try checkWake(l, call, name_tok, recv);
    if (std.mem.eql(u8, name, "spawnInto")) {
        if (!std.mem.eql(u8, l.path, "src/http/core/placement.zig")) try l.hit(name_tok, "T1", "zio spawnInto outside placement.zig: use placement.concurrent");
        return;
    }
    const r = recv orelse return;
    if (std.mem.eql(u8, name, "concurrent") or std.mem.eql(u8, name, "async")) {
        try checkSpawn(l, call_node, name_tok, r);
    } else if (std.mem.eql(u8, name, "spawn") and std.mem.eql(u8, l.text(l.last(r)), "Thread")) {
        try checkThread(l, name_tok);
    }
}

/// T1. `placement.concurrent(...)` is the way. Otherwise the spawn must be
/// function-local: its Future kept in a local (declared in this function),
/// or its receiver a Group or Select local to this function, and the
/// function cancels or awaits that local.
fn checkSpawn(l: *Lint, call_node: Node, i: u32, recv: Node) !void {
    if (std.mem.eql(u8, l.text(l.last(recv)), "placement")) return;
    // Inside placement.zig, the one place that wraps the std call.
    if (std.mem.eql(u8, l.path, "src/http/core/placement.zig")) return;
    // `x.concurrent(` with x a simple name: a local Group or Select.
    if (l.tree.nodeTag(recv) == .identifier) {
        const name = l.text(l.tree.nodeMainToken(recv));
        if (declaredLocal(l, i, name) and localFutureEnded(l, i, name)) return;
    }
    // `const f = [try] ....concurrent(` or `f = [try] ....concurrent(`: a
    // local Future.
    if (futureName(l, i, call_node)) |name| {
        if (declaredLocal(l, i, name) and localFutureEnded(l, i, name)) return;
        return l.hit(i, "T1", "a Future this function does not cancel or await, or one kept outside it: use placement.concurrent with the owner's group");
    }
    try l.hit(i, "T1", "a spawn outside placement.concurrent and outside a function-local Future, Group or Select");
}

/// The name a statement stores the call's Future in: the statement is a
/// declaration or a plain assignment to a name, and its value is the call
/// (or `try` of it).
fn futureName(l: *const Lint, i: u32, call_node: Node) ?[]const u8 {
    const tree = l.tree;
    const s = l.stmt_of[i];
    if (s == none) return null;
    const stmt: Node = @fromBackingInt(@intCast(s));
    var value: Node = undefined; // SAFETY: set on every path that reaches its read
    var name: []const u8 = undefined; // SAFETY: as value
    if (tree.fullVarDecl(stmt)) |vd| {
        value = vd.ast.init_node.unwrap() orelse return null;
        name = l.text(vd.ast.mut_token + 1);
    } else if (tree.nodeTag(stmt) == .assign) {
        const lhs, value = tree.nodeData(stmt).node_and_node;
        if (tree.nodeTag(lhs) != .identifier) return null;
        name = l.text(tree.nodeMainToken(lhs));
    } else return null;
    return if (holdsCall(l, value, call_node)) name else null;
}

/// The value is the call itself, through `try`, `catch` (its left side) and
/// the branches of an `if`.
fn holdsCall(l: *const Lint, value: Node, call_node: Node) bool {
    const tree = l.tree;
    if (value == call_node) return true;
    switch (tree.nodeTag(value)) {
        .@"try" => return holdsCall(l, tree.nodeData(value).node, call_node),
        .@"catch", .@"orelse" => return holdsCall(l, tree.nodeData(value).node_and_node[0], call_node),
        else => {},
    }
    if (tree.fullIf(value)) |f| {
        if (holdsCall(l, f.ast.then_expr, call_node)) return true;
        if (f.ast.else_expr.unwrap()) |e| return holdsCall(l, e, call_node);
    }
    return false;
}

/// `name` is declared (`var name` / `const name`) in the function holding
/// token i, before it.
fn declaredLocal(l: *const Lint, i: u32, name: []const u8) bool {
    const f = l.fn_of[i];
    if (f == none) return false;
    const body = l.tree.nodeData(@fromBackingInt(@intCast(f))).node_and_node[1];
    var k = l.first(body);
    while (k + 1 < i) : (k += 1) {
        if ((l.tags[k] == .keyword_var or l.tags[k] == .keyword_const) and l.tags[k + 1] == .identifier and std.mem.eql(u8, l.text(k + 1), name)) return true;
    }
    return false;
}

/// The function holding token i mentions `name.cancel` or `name.await`.
fn localFutureEnded(l: *const Lint, i: u32, name: []const u8) bool {
    const f = l.fn_of[i];
    if (f == none) return false;
    const body = l.tree.nodeData(@fromBackingInt(@intCast(f))).node_and_node[1];
    const a = l.first(body);
    const b = l.last(body);
    if (l.mentionsField(a, b, name, &.{ "cancel", "await" })) return true;
    // An optional Future: `if (name) |*x| x.cancel(io)`.
    var k = a;
    while (k + 6 <= b) : (k += 1) {
        if (l.tags[k] != .keyword_if or l.tags[k + 1] != .l_paren or l.tags[k + 2] != .identifier or l.tags[k + 3] != .r_paren or l.tags[k + 4] != .pipe) continue;
        if (!std.mem.eql(u8, l.text(k + 2), name)) continue;
        const cap = if (l.tags[k + 5] == .asterisk) k + 6 else k + 5;
        if (l.tags[cap] != .identifier) continue;
        if (l.mentionsField(cap + 1, @min(b, cap + 8), l.text(cap), &.{ "cancel", "await" })) return true;
    }
    return false;
}

/// T1 for OS threads: the handle is kept and joined in the same file, never
/// detached.
fn checkThread(l: *Lint, i: u32) !void {
    // A detach in the same statement.
    const s = l.stmt_of[i];
    const end = if (s == none) i else l.last(@fromBackingInt(@intCast(s)));
    var k = i;
    while (k <= end) : (k += 1) {
        if (l.tags[k] == .identifier and std.mem.eql(u8, l.text(k), "detach")) return l.hit(i, "T1", "a detached thread: keep the handle and join it in its owner's teardown");
    }
    for (l.tags, 0..) |t, m| {
        if (t == .identifier and m > 0 and l.tags[m - 1] == .period and std.mem.eql(u8, l.text(m), "join")) return;
    }
    try l.hit(i, "T1", "a thread that this file never joins");
}

/// C3: a prong or branch on `error.Canceled` (token i) whose body carries
/// on: it neither returns (or breaks out with) an error nor calls
/// `recancel`.
fn checkCanceled(l: *Lint, i: u32, body: Node) !void {
    const tree = l.tree;
    // `=> error.Canceled,` or `=> cause,`: the prong's value is the error
    // itself, handed on by the switch's `return`/`break`.
    if (isCanceled(l, body) or tree.nodeTag(body) == .identifier) return;
    const a, const b = l.tokensOf(body);
    var m = a;
    while (m <= b) : (m += 1) {
        switch (l.tags[m]) {
            .keyword_return, .keyword_try, .keyword_unreachable => return,
            .identifier => if (std.mem.eql(u8, l.text(m), "recancel") or std.mem.eql(u8, l.text(m), "panic")) return,
            .keyword_break => {
                // `break :blk error.Canceled` hands it on.
                var q = m;
                while (q <= b) : (q += 1) if (l.tags[q] == .keyword_error) return;
            },
            else => {},
        }
    }
    if (l.hasSafetyComment(i)) return;
    try l.hit(i, "C3", "error.Canceled caught and carried on from: return it, or call io.recancel()");
}

test "ruleListed: --rules matches whole rule names in a comma list" {
    try std.testing.expect(ruleListed("DOC", "DOC"));
    try std.testing.expect(ruleListed("U3, DOC", "DOC"));
    try std.testing.expect(!ruleListed("DOC", "U3"));
    try std.testing.expect(!ruleListed("DO", "DOC"));
}

// Self-tests (TESTING.md Q5): each fixture under safety_lint/fixtures/ names
// the path it is linted as on its first line (`// lint-path: src/...`) and
// marks every line that must hit with `// expect: RULE [RULE...]`. A line
// without a mark must not hit.

const LineRule = struct {
    line: usize,
    rule: []const u8,

    fn lessThan(_: void, a: LineRule, b: LineRule) bool {
        if (a.line != b.line) return a.line < b.line;
        return std.mem.lessThan(u8, a.rule, b.rule);
    }
};

fn expectFixture(comptime name: []const u8) !void {
    const src: [:0]const u8 = @embedFile("safety_lint/fixtures/" ++ name ++ ".zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = src[0 .. std.mem.indexOfScalar(u8, src, '\n') orelse src.len];
    const tag = "// lint-path: ";
    if (!std.mem.startsWith(u8, first, tag)) return error.FixtureWithoutPath;
    const path = first[tag.len..];

    var want: std.ArrayList(LineRule) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        const at = std.mem.indexOf(u8, line, "// expect: ") orelse continue;
        var rules = std.mem.tokenizeScalar(u8, line[at + "// expect: ".len ..], ' ');
        while (rules.next()) |r| try want.append(arena, .{ .line = n, .rule = r });
    }
    var hits: std.ArrayList(Hit) = .empty;
    try lintSource(arena, path, src, false, &hits);
    var got: std.ArrayList(LineRule) = .empty;
    for (hits.items) |h| try got.append(arena, .{ .line = h.line, .rule = h.rule });
    std.mem.sort(LineRule, want.items, {}, LineRule.lessThan);
    std.mem.sort(LineRule, got.items, {}, LineRule.lessThan);
    var same = want.items.len == got.items.len;
    if (same) for (want.items, got.items) |a, b| {
        if (a.line != b.line or !std.mem.eql(u8, a.rule, b.rule)) same = false;
    };
    if (same) return;
    std.debug.print("fixture {s}: want", .{name});
    for (want.items) |w| std.debug.print(" {d}:{s}", .{ w.line, w.rule });
    std.debug.print("\n  got:", .{});
    for (hits.items) |h| std.debug.print("\n    {d}: {s}: {s}", .{ h.line, h.rule, h.msg });
    std.debug.print("\n", .{});
    return error.FixtureMismatch;
}

test "lint: U3 casts, with and without a SAFETY reason" {
    try expectFixture("u3_casts");
}

test "lint: U3 undefined, the local-array exemption" {
    try expectFixture("u3_undefined");
}

test "lint: U3 is off in a wrapper module" {
    try expectFixture("u3_wrapper");
}

test "lint: U1 C bindings and externs outside their wrapper" {
    try expectFixture("u1");
}

test "lint: U1 a wrapper may import its binding" {
    try expectFixture("u1_wrapper");
}

test "lint: T1 spawns, local Futures and Groups" {
    try expectFixture("t1_spawn");
}

test "lint: T1 placement.zig wraps the std call" {
    try expectFixture("t1_placement");
}

test "lint: T1 a detached or never-joined thread" {
    try expectFixture("t1_thread");
}

test "lint: T1 a thread the file joins" {
    try expectFixture("t1_thread_joined");
}

test "lint: U1 src/h3/layout.zig is part of the ngtcp2/nghttp3 wrapper" {
    try expectFixture("u1_layout");
}

test "lint: L2 raw locks outside src/safety" {
    try expectFixture("l2_raw_lock");
}

test "lint: L2 the ranked wrappers may hold raw locks" {
    try expectFixture("l2_safety");
}

test "lint: T5 runtime wakes in the C ABI go through IoGate" {
    try expectFixture("t5_capi");
}

test "lint: T5 applies to a file with an export fn" {
    try expectFixture("t5_export");
}

test "lint: T5 does not apply elsewhere" {
    try expectFixture("t5_outside");
}

test "lint: C3 swallowed and handed-on cancels" {
    try expectFixture("c3");
}

test "lint: DOC names in doc comments" {
    try expectFixture("doc");
}

test "lint: a test file gets DOC only" {
    try expectFixture("skipped_test");
}
