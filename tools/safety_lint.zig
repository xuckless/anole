//! `zig build lint`: SAFETY.md E2, a token-level check of the Zig sources
//! for the rules a grep can see.
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
//!
//! - DOC: a public doc comment (`///`, `//!`) that names dusty or the
//!   core's build options (`use_http2`, `use_tls`); attribution lines and
//!   identifiers that still carry the name are allowed. Checked in every
//!   file, test files included.
//!
//! Usage: safety_lint [--tests] <dir>...   (exit 1 on any hit)
//! Without --tests, test code is skipped: `test` blocks, `*_test.zig`,
//! `*_tests.zig`, `testing.zig`, files under a `testing/` directory and the
//! test runners.
const std = @import("std");
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

/// U1: the C binding modules and the files allowed to import them. A
/// library called from more than one file is a named set (an exception to
/// fold into one wrapper at the engine's takeover; listed in SAFETY.md).
const c_libs = [_]struct { modules: []const []const u8, files: []const []const u8 }{
    .{ .modules = &.{ "anole_nghttp2_c", "nghttp2" }, .files = &.{ "src/http/core/server/h2.zig", "src/http/core/client.zig", "src/h2/root.zig", "src/h2/client.zig" } },
    .{ .modules = &.{"anole_boringssl_c"}, .files = &.{ "src/tls/root.zig", "src/tls/dusty_tls.zig", "src/h3/root.zig" } },
    .{ .modules = &.{ "anole_ngtcp2_c", "anole_nghttp3_c" }, .files = &.{ "src/h3/root.zig", "src/h3/ngtcp2.zig", "src/h3/nghttp3.zig", "src/h3/quic_tls.zig", "src/h3/client.zig", "src/h3/session_cache.zig", "src/h3/server.zig", "src/h3/bridge.zig", "src/h3/webtransport.zig", "src/h3/net.zig" } },
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
    var dirs: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--tests")) tests = true else try dirs.append(arena, a);
    }
    if (dirs.items.len == 0) {
        std.debug.print("usage: safety_lint [--tests] <dir>...\n", .{});
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
        try docNames(arena, p, src, &hits);
        if (!tests and isTestFile(p)) continue;
        try lintFile(arena, p, src, tests, &hits);
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

const Ctx = enum { container, fn_body, block, test_block, init_list, error_set };

const Lint = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    src: [:0]const u8,
    toks: []const Token,
    hits: *std.ArrayList(Hit),
    /// The context of each token: the innermost brace it is in.
    ctx: []const Ctx,
    /// Whether each token is inside a test block (at any depth).
    in_test: []const bool,
    /// For each token, the index of the l_brace of its innermost function
    /// body, or null at container level.
    fn_start: []const ?usize,
    /// For each l_brace, the index of its r_brace.
    match: []const usize,

    fn text(self: *const Lint, i: usize) []const u8 {
        const t = self.toks[i];
        return self.src[t.loc.start..t.loc.end];
    }

    fn tag(self: *const Lint, i: usize) Token.Tag {
        return if (i < self.toks.len) self.toks[i].tag else .eof;
    }

    fn lineOf(self: *const Lint, i: usize) usize {
        return std.mem.count(u8, self.src[0..self.toks[i].loc.start], "\n") + 1;
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

    /// A `// SAFETY:` comment on the token's line, or in the comment lines
    /// just above the line of `stmt` (the statement's first token).
    fn hasSafetyComment(self: *const Lint, i: usize, stmt: usize) bool {
        const l = self.lineAt(self.toks[i].loc.start);
        if (std.mem.indexOf(u8, self.src[l.start..l.end], "// SAFETY:") != null) return true;
        for ([_]usize{ i, stmt }) |anchor| {
            var ls = self.lineAt(self.toks[anchor].loc.start).start;
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

    /// The first token of the statement or declaration holding token i.
    fn stmtStart(self: *const Lint, i: usize) usize {
        var depth: i32 = 0;
        var j = i;
        while (j > 0) {
            const t = self.tag(j - 1);
            switch (t) {
                .r_paren, .r_bracket => depth += 1,
                .l_paren, .l_bracket => {
                    if (depth == 0) return j;
                    depth -= 1;
                },
                .r_brace => if (depth == 0) return j,
                .l_brace, .semicolon => if (depth == 0) return j,
                .comma => if (depth == 0 and self.ctx[j - 1] != .fn_body and self.ctx[j - 1] != .block and self.ctx[j - 1] != .test_block) return j,
                else => {},
            }
            j -= 1;
        }
        return 0;
    }
};

fn lintFile(arena: std.mem.Allocator, path: []const u8, src: [:0]const u8, tests: bool, hits: *std.ArrayList(Hit)) !void {
    var toks: std.ArrayList(Token) = .empty;
    var tz: Tokenizer = .init(src);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        try toks.append(arena, t);
    }
    const n = toks.items.len;
    const ctx = try arena.alloc(Ctx, n);
    const in_test = try arena.alloc(bool, n);
    const fn_start = try arena.alloc(?usize, n);
    const match = try arena.alloc(usize, n);
    @memset(match, 0);
    {
        const Frame = struct { ctx: Ctx, tok: usize, in_test: bool, fn_start: ?usize };
        var stack: std.ArrayList(Frame) = .empty;
        var pending_fn = false; // saw `fn`, its body brace is next at paren depth 0
        var pending_test = false;
        var paren: i32 = 0;
        var paren_opener: std.ArrayList(Token.Tag) = .empty; // the tag before each open paren
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const t = toks.items[i].tag;
            const top: Frame = if (stack.items.len > 0) stack.items[stack.items.len - 1] else .{ .ctx = .container, .tok = 0, .in_test = false, .fn_start = null };
            ctx[i] = top.ctx;
            in_test[i] = top.in_test;
            fn_start[i] = top.fn_start;
            switch (t) {
                .keyword_fn => pending_fn = true,
                .keyword_test => pending_test = true,
                .l_paren => {
                    try paren_opener.append(arena, if (i > 0) toks.items[i - 1].tag else .invalid);
                    paren += 1;
                },
                .r_paren => {
                    if (paren > 0) paren -= 1;
                    _ = paren_opener.pop();
                },
                .semicolon => if (paren == 0) {
                    pending_fn = false;
                },
                .l_brace => {
                    const prev: Token.Tag = if (i > 0) toks.items[i - 1].tag else .invalid;
                    var c: Ctx = .block;
                    if (prev == .keyword_struct or prev == .keyword_enum or prev == .keyword_union or prev == .keyword_opaque) {
                        c = .container;
                    } else if (prev == .keyword_error) {
                        c = .error_set;
                    } else if (prev == .period) {
                        c = .init_list;
                    } else if (prev == .r_paren and parenOpenerIsContainer(toks.items, i - 1)) {
                        c = .container;
                    } else if (pending_test and paren == 0) {
                        c = .test_block;
                        pending_test = false;
                    } else if (pending_fn and paren == 0) {
                        c = .fn_body;
                        pending_fn = false;
                    } else if (isTypedInit(toks.items, i)) {
                        c = .init_list;
                    }
                    try stack.append(arena, .{
                        .ctx = c,
                        .tok = i,
                        .in_test = top.in_test or c == .test_block,
                        .fn_start = if (c == .fn_body) i else top.fn_start,
                    });
                },
                .r_brace => {
                    if (stack.pop()) |f| match[f.tok] = i;
                },
                else => {},
            }
        }
    }
    var lint: Lint = .{ .arena = arena, .path = path, .src = src, .toks = toks.items, .hits = hits, .ctx = ctx, .in_test = in_test, .fn_start = fn_start, .match = match };
    const wrapper = isWrapper(path);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!tests and in_test[i]) continue;
        const t = toks.items[i];
        const s = lint.text(i);
        switch (t.tag) {
            .builtin => {
                if (std.mem.eql(u8, s, "@ptrCast") or std.mem.eql(u8, s, "@alignCast") or std.mem.eql(u8, s, "@ptrFromInt") or std.mem.eql(u8, s, "@intFromPtr")) {
                    // `@ptrCast(@alignCast(x))` is one cast.
                    if (std.mem.eql(u8, s, "@alignCast") and i >= 2 and lint.tag(i - 1) == .l_paren and std.mem.eql(u8, lint.text(i - 2), "@ptrCast")) continue;
                    if (!wrapper and !lint.hasSafetyComment(i, lint.stmtStart(i)))
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
            .identifier => {
                if (std.mem.eql(u8, s, "undefined")) {
                    if (wrapper) continue;
                    const st = lint.stmtStart(i);
                    if (isLocalArrayDecl(&lint, st, i)) continue;
                    if (lint.hasSafetyComment(i, st)) continue;
                    try lint.hit(i, "U3", "undefined outside a local array declaration, without a // SAFETY: reason");
                } else if ((std.mem.eql(u8, s, "concurrent") or std.mem.eql(u8, s, "async")) and i > 0 and lint.tag(i - 1) == .period and lint.tag(i + 1) == .l_paren) {
                    try checkSpawn(&lint, i);
                } else if (std.mem.eql(u8, s, "spawnInto") and lint.tag(i + 1) == .l_paren) {
                    if (!std.mem.eql(u8, path, "src/http/core/placement.zig")) try lint.hit(i, "T1", "zio spawnInto outside placement.zig: use placement.concurrent");
                } else if (std.mem.eql(u8, s, "spawn") and i >= 2 and lint.tag(i - 1) == .period and std.mem.eql(u8, lint.text(i - 2), "Thread") and lint.tag(i + 1) == .l_paren) {
                    try checkThread(&lint, i);
                } else if (std.mem.eql(u8, s, "Canceled") and i >= 2 and lint.tag(i - 1) == .period and std.mem.eql(u8, lint.text(i - 2), "error")) {
                    try checkCanceled(&lint, i);
                }
            },
            else => {},
        }
    }
}

/// `enum(u8) {`, `union(enum) {`, `packed struct(u32) {`: the paren group
/// ending at r_paren `rp` was opened right after a container keyword.
fn parenOpenerIsContainer(toks: []const Token, rp: usize) bool {
    var depth: i32 = 0;
    var j = rp;
    while (true) {
        switch (toks[j].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                depth -= 1;
                if (depth == 0) {
                    if (j == 0) return false;
                    const t = toks[j - 1].tag;
                    return t == .keyword_enum or t == .keyword_union or t == .keyword_struct;
                }
            },
            else => {},
        }
        if (j == 0) return false;
        j -= 1;
    }
}

/// `T{ ... }`, `[_]u8{ ... }`, `std.ArrayList(u8){}`: a typed literal (an
/// identifier, a `]` of an array type, or a call's `)` that is not a
/// control-flow header).
fn isTypedInit(toks: []const Token, lb: usize) bool {
    if (lb == 0) return false;
    const prev = toks[lb - 1].tag;
    if (prev == .identifier) {
        // `else {`, `blk: {`, `=> |x| {` are not literals; an identifier right
        // before `{` is a type name only when no keyword precedes it.
        if (lb >= 2 and (toks[lb - 2].tag == .period or toks[lb - 2].tag == .equal or toks[lb - 2].tag == .l_paren or toks[lb - 2].tag == .comma or toks[lb - 2].tag == .keyword_return))
            return true;
    }
    return false;
}

/// `var|const name: [..]T = undefined` with `undefined` the whole initializer.
fn isLocalArrayDecl(l: *const Lint, st: usize, u: usize) bool {
    var j = st;
    if (l.tag(j) == .keyword_pub) j += 1;
    if (l.tag(j) == .keyword_threadlocal) j += 1;
    if (l.tag(j) != .keyword_var and l.tag(j) != .keyword_const) return false;
    if (l.tag(j + 1) != .identifier or l.tag(j + 2) != .colon) return false;
    if (l.tag(j + 3) != .l_bracket) return false;
    if (l.tag(u - 1) != .equal) return false;
    if (l.tag(u + 1) != .semicolon) return false;
    return l.fn_start[u] != null;
}

/// T1. `placement.concurrent(...)` is the way. Otherwise the spawn must be
/// function-local: its Future kept in a local (declared in this function),
/// or its receiver a Group or Select local to this function, and the
/// function cancels or awaits that local.
fn checkSpawn(l: *Lint, i: usize) !void {
    if (i >= 2 and std.mem.eql(u8, l.text(i - 2), "placement")) return;
    // Inside placement.zig, the one place that wraps the std call.
    if (std.mem.eql(u8, l.path, "src/http/core/placement.zig")) return;
    // `x.concurrent(` with x a simple name: a local Group or Select.
    if (i >= 2 and l.tag(i - 2) == .identifier and (i < 3 or l.tag(i - 3) != .period)) {
        const recv = l.text(i - 2);
        if (declaredLocal(l, i, recv) and localFutureEnded(l, i, recv)) return;
    }
    // `const f = ....concurrent(` or `f = ....concurrent(`: a local Future.
    const st = l.stmtStart(i);
    var j = st;
    if (l.tag(j) == .keyword_var or l.tag(j) == .keyword_const) j += 1;
    if (l.tag(j) == .identifier and (l.tag(j + 1) == .equal or l.tag(j + 1) == .colon)) {
        const name = l.text(j);
        if (declaredLocal(l, i, name) and localFutureEnded(l, i, name)) return;
        return l.hit(i, "T1", "a Future this function does not cancel or await, or one kept outside it: use placement.concurrent with the owner's group");
    }
    try l.hit(i, "T1", "a spawn outside placement.concurrent and outside a function-local Future, Group or Select");
}

/// `name` is declared (`var name` / `const name`) in the function holding
/// token i, before it.
fn declaredLocal(l: *const Lint, i: usize, name: []const u8) bool {
    const fs = l.fn_start[i] orelse return false;
    var k = fs;
    while (k + 1 < i) : (k += 1) {
        if ((l.tag(k) == .keyword_var or l.tag(k) == .keyword_const) and l.tag(k + 1) == .identifier and std.mem.eql(u8, l.text(k + 1), name)) return true;
    }
    return false;
}

/// The function holding token i mentions `name.cancel(` or `name.await(`.
fn localFutureEnded(l: *const Lint, i: usize, name: []const u8) bool {
    const fs = l.fn_start[i] orelse return false;
    const end = l.match[fs];
    var k = fs;
    while (k + 3 < end) : (k += 1) {
        if (l.tag(k) == .identifier and std.mem.eql(u8, l.text(k), name) and l.tag(k + 1) == .period and l.tag(k + 2) == .identifier) {
            const m = l.text(k + 2);
            if (std.mem.eql(u8, m, "cancel") or std.mem.eql(u8, m, "await")) return true;
        }
    }
    return false;
}

/// T1 for OS threads: the handle is kept and joined in the same file, never
/// detached.
fn checkThread(l: *Lint, i: usize) !void {
    // A detach in the same statement.
    var k = i;
    while (k < l.toks.len and l.tag(k) != .semicolon) : (k += 1) {
        if (l.tag(k) == .identifier and std.mem.eql(u8, l.text(k), "detach")) return l.hit(i, "T1", "a detached thread: keep the handle and join it in its owner's teardown");
    }
    for (l.toks, 0..) |t, m| {
        if (t.tag == .identifier and std.mem.eql(u8, l.text(m), "join") and m > 0 and l.tag(m - 1) == .period) return;
    }
    try l.hit(i, "T1", "a thread that this file never joins");
}

/// C3: a prong or branch on `error.Canceled` that carries on: it neither
/// returns (or breaks out with) an error nor calls `recancel`.
fn checkCanceled(l: *Lint, i: usize) !void {
    // Only where it is handled: a switch prong item (after `{` or `,`) or a
    // comparison; `return error.Canceled`, `=> error.Canceled` hand it on.
    const before = if (i >= 3) l.tag(i - 3) else .invalid;
    if (before != .l_brace and before != .comma and before != .equal_equal and before != .bang_equal) return;
    // Find the handling body: a switch prong `error.Canceled[, ...] => body`
    // or `if (... == error.Canceled) body`.
    var k = i + 1;
    while (k < l.toks.len and (l.tag(k) == .comma or l.tag(k) == .period or l.tag(k) == .identifier or l.tag(k) == .keyword_error)) : (k += 1) {}
    var body_start: usize = undefined;
    if (l.tag(k) == .equal_angle_bracket_right) {
        body_start = k + 1;
    } else if (l.tag(i - 3) == .equal_equal or l.tag(k) == .r_paren) {
        if (l.tag(i - 3) != .equal_equal) return;
        // `if (err == error.Canceled)`: the body follows the `)`.
        var depth: i32 = 0;
        while (k < l.toks.len) : (k += 1) {
            if (l.tag(k) == .l_paren) depth += 1;
            if (l.tag(k) == .r_paren) {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        body_start = k + 1;
    } else return;
    // The body: a block, or tokens up to the prong's `,` / statement's `;`.
    var end: usize = body_start;
    if (l.tag(body_start) == .pipe) {
        // `=> |e| ...`
        end = body_start + 1;
        while (end < l.toks.len and l.tag(end) != .pipe) : (end += 1) {}
        end += 1;
    }
    const start = end;
    if (l.tag(start) == .l_brace) {
        end = l.match[start];
    } else {
        var depth: i32 = 0;
        while (end < l.toks.len) : (end += 1) {
            switch (l.tag(end)) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket => depth -= 1,
                .r_brace => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .comma, .semicolon => if (depth == 0) break,
                else => {},
            }
        }
    }
    // `=> error.Canceled,` or `=> err,`: the prong's value is the error
    // itself, handed on by the switch's `return`/`break`.
    if (l.tag(start) == .keyword_error and l.tag(start + 2) == .identifier and std.mem.eql(u8, l.text(start + 2), "Canceled")) return;
    // `=> cause,`: the prong's value is the error being switched on.
    if (l.tag(start) == .identifier and (l.tag(start + 1) == .comma or l.tag(start + 1) == .r_brace)) return;
    var m = start;
    while (m <= end and m < l.toks.len) : (m += 1) {
        switch (l.tag(m)) {
            .keyword_return, .keyword_try, .keyword_unreachable => return,
            .identifier => if (std.mem.eql(u8, l.text(m), "recancel") or std.mem.eql(u8, l.text(m), "panic")) return,
            .keyword_break => {
                // `break :blk error.Canceled` hands it on.
                var q = m;
                while (q <= end and q < l.toks.len) : (q += 1) if (l.tag(q) == .keyword_error) return;
            },
            else => {},
        }
    }
    if (l.hasSafetyComment(i, l.stmtStart(i))) return;
    try l.hit(i, "C3", "error.Canceled caught and carried on from: return it, or call io.recancel()");
}
