//! `anole`: the command line of the Anole framework. `anole new <dir>` makes a
//! project from a template: `zig init -m` (name and fingerprint), the template
//! files, and `zig fetch --save=anole` (the matching Anole tag). Std-only; it
//! is never linked into an application.
//!
//!     anole new <dir> [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
//!     anole init [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
//!     anole templates
//!     anole console [<name>|<pid>|<socket path>] [options]
//!     anole version
//!     anole help [command]
//!
//! Exit codes: 0 ok; 1 usage; 2 directory not empty or a file exists; 3 `zig`
//! not found; 4 `zig init` or `zig fetch` failed.
const std = @import("std");
const options = @import("cli_options");
const index = @import("templates");
const banner = @import("banner");
const console_cmd = @import("console.zig");

const Io = std.Io;

pub const exit_usage = 1;
pub const exit_exists = 2;
pub const exit_no_zig = 3;
pub const exit_zig_failed = 4;

const repo_url = "git+https://github.com/xuckless/anole";

/// The process environment, for NO_COLOR and the like.
var environ: ?std.process.Environ = null;

fn getEnv(name: []const u8) ?[]const u8 {
    if (comptime @import("builtin").os.tag == .windows) return null;
    const e = environ orelse return null;
    return e.getPosix(name);
}

/// `banner.show` and `banner.styleFor` read the environment through this.
const EnvReader = struct {
    pub fn get(_: EnvReader, name: []const u8) ?[]const u8 {
        return getEnv(name);
    }
};

fn consoleEnv(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    return getEnv(name);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    environ = init.minimal.environ;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const code = run(gpa, io, args[1..]) catch |err| {
        std.debug.print("anole: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn run(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try say(io, usage_text, .{});
        return exit_usage;
    }
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "new")) return newCommand(gpa, io, args[1..], .new);
    if (std.mem.eql(u8, cmd, "init")) return newCommand(gpa, io, args[1..], .init);
    if (std.mem.eql(u8, cmd, "console")) return console_cmd.command(gpa, io, args[1..], .{ .get = consoleEnv });
    if (std.mem.eql(u8, cmd, "templates")) {
        try listTemplates(io);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        // The art with "anole x.y.z" under it at a terminal; the plain line
        // for scripts.
        if (!printBanner(io)) try say(io, "anole {s}\n", .{options.version});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        const topic: ?[]const u8 = if (args.len > 1) args[1] else null;
        const is_new = topic != null and (std.mem.eql(u8, topic.?, "new") or std.mem.eql(u8, topic.?, "init"));
        const text = if (is_new) new_help else if (topic != null and std.mem.eql(u8, topic.?, "console")) console_cmd.help_text else usage_text;
        try say(io, "{s}", .{text});
        return 0;
    }
    std.debug.print("anole: unknown command \"{s}\"\n\n{s}", .{ cmd, usage_text });
    return exit_usage;
}

const usage_text =
    \\anole: the command line of the Anole framework
    \\
    \\usage:
    \\  anole new <dir> [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
    \\  anole init [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
    \\  anole templates
    \\  anole console [<name>|<pid>|<socket path>] [options]
    \\  anole version
    \\  anole help [command]
    \\
;

const new_help =
    \\anole new <dir>: make a project from a template
    \\anole init: the same in the current directory (extends an existing Zig project:
    \\  build.zig.zon is kept and Anole is added to it; a file that exists is never overwritten)
    \\
    \\  --template <name>    which template (default: minimal; `anole templates` lists them)
    \\  --anole <ref>        the Anole tag, branch or commit to depend on (default: this CLI's tag)
    \\  --anole-path <dir>   depend on a local checkout instead (a path dependency)
    \\  --no-fetch           leave the dependency out and print the `zig fetch` line
    \\  --force              allow a non-empty directory (never overwrites a file)
    \\
    \\Every template writes a ready .env (copied from .env.example) unless one exists.
    \\
;

/// What `anole new` was asked for.
pub const NewArgs = struct {
    dir: []const u8,
    template: []const u8 = "minimal",
    anole_ref: ?[]const u8 = null,
    anole_path: ?[]const u8 = null,
    no_fetch: bool = false,
    force: bool = false,
};

pub const ArgError = error{ MissingDir, UnknownOption, MissingValue, ConflictingDependency, ExtraArgument };

/// Parses the arguments after `new`.
pub fn parseNewArgs(args: []const []const u8) ArgError!NewArgs {
    return parseArgs(args, true);
}

/// Parses the arguments after `init`: the directory is the current one.
pub fn parseInitArgs(args: []const []const u8) ArgError!NewArgs {
    return parseArgs(args, false);
}

fn parseArgs(args: []const []const u8, comptime want_dir: bool) ArgError!NewArgs {
    var out: NewArgs = .{ .dir = if (want_dir) "" else "." };
    var have_dir = !want_dir;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--template") or std.mem.eql(u8, a, "--anole") or std.mem.eql(u8, a, "--anole-path")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            if (std.mem.eql(u8, a, "--template")) out.template = args[i];
            if (std.mem.eql(u8, a, "--anole")) out.anole_ref = args[i];
            if (std.mem.eql(u8, a, "--anole-path")) out.anole_path = args[i];
        } else if (std.mem.eql(u8, a, "--no-fetch")) {
            out.no_fetch = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            out.force = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownOption;
        } else if (!have_dir) {
            out.dir = a;
            have_dir = true;
        } else return error.ExtraArgument;
    }
    if (!have_dir) return error.MissingDir;
    if (out.anole_ref != null and out.anole_path != null) return error.ConflictingDependency;
    return out;
}

const Mode = enum { new, init };

fn newCommand(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8, mode: Mode) !u8 {
    const list = try gpa.alloc([]const u8, args.len);
    defer gpa.free(list);
    for (args, list) |a, *out| out.* = a;
    const cmd_name = if (mode == .new) "new" else "init";
    const parsed = (if (mode == .new) parseNewArgs(list) else parseInitArgs(list)) catch |err| {
        std.debug.print("anole {s}: {s}\n\n{s}", .{ cmd_name, switch (err) {
            error.MissingDir => "give a directory: anole new <dir>",
            error.UnknownOption => "unknown option",
            error.MissingValue => "an option is missing its value",
            error.ConflictingDependency => "--anole and --anole-path cannot be used together",
            error.ExtraArgument => if (mode == .new) "one directory only" else "init works in the current directory; it takes no directory",
        }, new_help });
        return exit_usage;
    };

    const template = findTemplate(parsed.template) orelse {
        std.debug.print("anole {s}: no template named \"{s}\"; the templates are:\n", .{ cmd_name, parsed.template });
        for (index.templates) |t| std.debug.print("  {s}  {s}\n", .{ t.name, t.summary });
        if (index.templates.len == 0) std.debug.print("  (none built in)\n", .{});
        return exit_usage;
    };

    const cwd = Io.Dir.cwd();
    // 1. The directory: created if missing, empty unless --force.
    if (mode == .new) cwd.createDirPath(io, parsed.dir) catch |err| {
        std.debug.print("anole new: cannot create {s}: {s}\n", .{ parsed.dir, @errorName(err) });
        return exit_exists;
    };
    var dir = try cwd.openDir(io, parsed.dir, .{ .iterate = true });
    defer dir.close(io);
    if (!parsed.force) {
        var it = dir.iterate();
        if (try it.next(io)) |entry| {
            std.debug.print("anole {s}: {s} is not empty (found {s}); use an empty directory or --force\n", .{ cmd_name, parsed.dir, entry.name });
            return exit_exists;
        }
    }
    // An existing Zig project (init in a directory with a build.zig.zon) keeps
    // its manifest: Anole is added to it, and `zig init` does not run.
    const existing_project = mode == .init and exists(io, dir, "build.zig.zon");
    // A template file must not overwrite anything (build.zig, which `zig init`
    // writes, excepted in a new project).
    for (template.files) |f| {
        if (!existing_project and std.mem.eql(u8, f.path, "build.zig")) continue;
        if (exists(io, dir, f.path)) {
            std.debug.print("anole {s}: {s}/{s} exists; nothing was written\n", .{ cmd_name, parsed.dir, f.path });
            return exit_exists;
        }
    }

    // 2. zig init -m.
    const version = zigVersion(gpa, io) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("anole {s}: `zig` was not found on PATH; install Zig 0.17.0 from https://ziglang.org/download/\n", .{cmd_name});
            return exit_no_zig;
        },
        else => return err,
    };
    defer gpa.free(version);
    if (!std.mem.startsWith(u8, version, "0.17.")) {
        std.debug.print("anole {s}: warning: Anole needs Zig 0.17.x, this is {s}\n", .{ cmd_name, version });
    }
    if (!existing_project and !(try runZig(io, &.{ "zig", "init", "-m" }, parsed.dir))) {
        std.debug.print("anole {s}: `zig init -m` failed; retry it in {s}\n", .{ cmd_name, parsed.dir });
        return exit_zig_failed;
    }

    // 3. The project name, as zig init wrote it.
    const zon_bytes = try dir.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20));
    defer gpa.free(zon_bytes);
    const name = projectName(zon_bytes) orelse {
        std.debug.print("anole {s}: could not read the project name from build.zig.zon\n", .{cmd_name});
        return exit_zig_failed;
    };

    // 4. The template's files, and a ready .env from .env.example.
    for (template.files) |f| {
        const text = try substitute(gpa, f.data, name);
        defer gpa.free(text);
        if (std.fs.path.dirname(f.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = f.path, .data = text });
        if (std.mem.eql(u8, f.path, ".env.example") and !exists(io, dir, ".env")) {
            try dir.writeFile(io, .{ .sub_path = ".env", .data = text });
        }
    }

    // 5. The dependency.
    if (existing_project and std.mem.find(u8, zon_bytes, ".anole = ") != null) {
        std.debug.print("anole init: build.zig.zon already has an anole dependency; left as it is\n", .{});
    } else if (parsed.anole_path) |path| {
        // The manifest wants a path relative to the project, whatever the
        // path was relative to (or absolute) on the command line.
        const project_abs = try dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(project_abs);
        const cwd_abs = try cwd.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(cwd_abs);
        const rel = try relativeDependencyPath(gpa, project_abs, cwd_abs, path);
        defer gpa.free(rel);
        const edited = try insertPathDependency(gpa, zon_bytes, rel);
        defer gpa.free(edited);
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = edited });
    } else {
        const ref = parsed.anole_ref orelse try std.fmt.allocPrint(gpa, "v{s}", .{options.version});
        defer if (parsed.anole_ref == null) gpa.free(ref);
        const url = try std.fmt.allocPrint(gpa, "{s}#{s}", .{ repo_url, ref });
        defer gpa.free(url);
        if (parsed.no_fetch) {
            try say(io, "no dependency added; run it yourself:\n  cd {s} && zig fetch --save=anole {s}\n", .{ parsed.dir, url });
        } else if (!(try runZig(io, &.{ "zig", "fetch", "--save=anole", url }, parsed.dir))) {
            std.debug.print("anole {s}: `zig fetch` failed; retry it:\n  cd {s} && zig fetch --save=anole {s}\n", .{ cmd_name, parsed.dir, url });
            return exit_zig_failed;
        }
    }

    // 6. Next steps, after the anole when a person is looking.
    _ = printBanner(io);
    if (mode == .new) {
        try say(io, "created {s} (template: {s}, anole v{s})\n  cd {s}\n{s}", .{ parsed.dir, template.name, options.version, parsed.dir, template.next_steps });
    } else {
        try say(io, "added the {s} template (anole v{s}) to {s}\n{s}", .{ template.name, options.version, if (std.mem.eql(u8, parsed.dir, ".")) "this directory" else parsed.dir, template.next_steps });
    }
    return 0;
}

/// `path` (relative to `cwd_abs`, or absolute) as a path relative to the
/// project directory `project_abs`, '/'-separated as a manifest wants it.
pub fn relativeDependencyPath(gpa: std.mem.Allocator, project_abs: []const u8, cwd_abs: []const u8, path: []const u8) ![]u8 {
    const target = try std.fs.path.resolve(gpa, &.{ cwd_abs, path });
    defer gpa.free(target);
    const rel = try std.fs.path.relativeAlloc(gpa, project_abs, null, project_abs, target);
    if (rel.len == 0) {
        gpa.free(rel);
        return gpa.dupe(u8, ".");
    }
    std.mem.replaceScalar(u8, rel, '\\', '/');
    return rel;
}

fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// The anole art and "anole x.y.z", when stdout is a terminal (uncoloured
/// under NO_COLOR, none with ANOLE_NO_BANNER=1); whether it was shown.
fn printBanner(io: Io) bool {
    const out = Io.File.stdout();
    const tty = out.isTty(io) catch false;
    const env: EnvReader = .{};
    if (!banner.show(true, true, tty, env)) return false;
    var buf: [4096]u8 = undefined;
    var w = out.writer(io, &buf);
    banner.write(&w.interface, .{ .version = options.version }, banner.styleFor(banner.terminalColumns(io, out), env, banner.coin(io))) catch return false;
    w.interface.flush() catch return false;
    return true;
}

fn findTemplate(name: []const u8) ?index.Template {
    for (index.templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn listTemplates(io: Io) !void {
    if (index.templates.len == 0) {
        try say(io, "no templates are built into this anole\n", .{});
        return;
    }
    for (index.templates) |t| try say(io, "{s}  {s}\n", .{ t.name, t.summary });
}

/// `zig version`'s first line; the caller frees it.
fn zigVersion(gpa: std.mem.Allocator, io: Io) ![]u8 {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "zig", "version" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n"));
}

/// Runs a zig command in `cwd` with its output passed through; whether it succeeded.
fn runZig(io: Io, argv: []const []const u8, cwd: []const u8) !bool {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    const term = try child.wait(io);
    return term.success();
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ------------------------------------------------------------------ text helpers

/// The project name `zig init` wrote: `.name = .my_api,` in build.zig.zon.
pub fn projectName(zon: []const u8) ?[]const u8 {
    const key = ".name = .";
    const at = std.mem.find(u8, zon, key) orelse return null;
    const rest = zon[at + key.len ..];
    const end = std.mem.findAny(u8, rest, ",\r\n ") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// Replaces `{{name}}` by `name` everywhere; nothing else is touched.
pub fn substitute(gpa: std.mem.Allocator, text: []const u8, name: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, text, "{{name}}", name);
}

/// The zon with `.dependencies = .{ .anole = .{ .path = "<path>" } }`: in
/// the existing `.dependencies` table when there is one, else after the
/// `.version` line.
pub fn insertPathDependency(gpa: std.mem.Allocator, zon: []const u8, path: []const u8) ![]u8 {
    const entry = try std.fmt.allocPrint(gpa, "        .anole = .{{ .path = \"{s}\" }},\n", .{path});
    defer gpa.free(entry);
    if (std.mem.find(u8, zon, ".dependencies = .{")) |at| {
        const open = at + ".dependencies = .{".len;
        // `.dependencies = .{}` (empty, closed on the same line) or a table.
        if (zon[open] == '}') {
            const close = open + 1;
            const comma = if (zon[close] == ',') close + 1 else close;
            return std.fmt.allocPrint(gpa, "{s}\n{s}    }}{s}", .{ zon[0..open], entry, zon[comma..] }) catch error.OutOfMemory;
        }
        const nl = std.mem.findScalarPos(u8, zon, open, '\n') orelse return error.InvalidZon;
        return std.mem.concat(gpa, u8, &.{ zon[0 .. nl + 1], entry, zon[nl + 1 ..] });
    }
    const v = std.mem.find(u8, zon, ".version = ") orelse return error.InvalidZon;
    const nl = std.mem.findScalarPos(u8, zon, v, '\n') orelse return error.InvalidZon;
    const block = try std.fmt.allocPrint(gpa, "    .dependencies = .{{\n{s}    }},\n", .{entry});
    defer gpa.free(block);
    return std.mem.concat(gpa, u8, &.{ zon[0 .. nl + 1], block, zon[nl + 1 ..] });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// What `zig init -m` writes with Zig 0.17 (the fixture the CLI's parsing is pinned to).
const zig_init_zon =
    \\.{
    \\    .name = .my_api,
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x1234567890abcdef,
    \\    .minimum_zig_version = "0.17.0",
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

test "project name as zig init writes it" {
    try testing.expectEqualStrings("my_api", projectName(zig_init_zon).?);
    try testing.expectEqual(null, projectName(".{ .version = \"1\" }"));
}

test "path dependency inserted" {
    const edited = try insertPathDependency(testing.allocator, zig_init_zon, "../anole");
    defer testing.allocator.free(edited);
    const Zon = struct {
        name: enum { my_api },
        version: []const u8,
        fingerprint: u64,
        minimum_zig_version: []const u8,
        dependencies: struct { anole: struct { path: []const u8 } },
        paths: []const []const u8,
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const source = try arena_state.allocator().dupeSentinel(u8, edited, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = try std.zon.parse.fromSlice(Zon, .{ .gpa = testing.allocator, .arena = arena_state.allocator(), .source = source, .diagnostics = &diagnostics });
    try testing.expectEqualStrings("../anole", parsed.dependencies.anole.path);
    try testing.expectEqualStrings("0.0.0", parsed.version);
}

test "path dependency goes into an existing dependencies table, empty or not" {
    const empty = "    .version = \"0.0.0\",\n    .dependencies = .{},\n    .paths = .{},\n";
    const a = try insertPathDependency(testing.allocator, empty, "p");
    defer testing.allocator.free(a);
    try testing.expect(std.mem.find(u8, a, ".anole = .{ .path = \"p\" }") != null);
    try testing.expect(std.mem.find(u8, a, ".dependencies = .{\n") != null);
    const table = "    .version = \"0.0.0\",\n    .dependencies = .{\n        .x = .{ .path = \"x\" },\n    },\n";
    const b = try insertPathDependency(testing.allocator, table, "p");
    defer testing.allocator.free(b);
    try testing.expect(std.mem.find(u8, b, ".x = .{ .path = \"x\" }") != null);
    try testing.expect(std.mem.find(u8, b, ".anole = .{ .path = \"p\" }") != null);
}

test "the path dependency is relative to the project" {
    const a = try relativeDependencyPath(testing.allocator, "/work/apps/my_api", "/work/apps", "../anole");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("../../anole", a);
    const b = try relativeDependencyPath(testing.allocator, "/work/apps/my_api", "/elsewhere", "/work/anole");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("../../anole", b);
}

test "init takes no directory" {
    const ok = try parseInitArgs(&.{ "--template", "grpc", "--force" });
    try testing.expectEqualStrings(".", ok.dir);
    try testing.expectEqualStrings("grpc", ok.template);
    try testing.expectError(error.ExtraArgument, parseInitArgs(&.{"dir"}));
    try testing.expectError(error.ConflictingDependency, parseInitArgs(&.{ "--anole", "main", "--anole-path", "../anole" }));
}

test "placeholders" {
    const out = try substitute(testing.allocator, "name={{name}} again={{name}} keep={{other}} {name}", "my_api");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("name=my_api again=my_api keep={{other}} {name}", out);
}

test "arguments" {
    const ok = try parseNewArgs(&.{ "app", "--template", "grpc", "--no-fetch", "--force" });
    try testing.expectEqualStrings("app", ok.dir);
    try testing.expectEqualStrings("grpc", ok.template);
    try testing.expect(ok.no_fetch and ok.force);
    try testing.expectEqualStrings("minimal", (try parseNewArgs(&.{"app"})).template);
    try testing.expectError(error.ConflictingDependency, parseNewArgs(&.{ "app", "--anole", "main", "--anole-path", "../anole" }));
    try testing.expectError(error.MissingDir, parseNewArgs(&.{"--force"}));
    try testing.expectError(error.UnknownOption, parseNewArgs(&.{ "app", "--bogus" }));
    try testing.expectError(error.MissingValue, parseNewArgs(&.{ "app", "--template" }));
    try testing.expectError(error.ExtraArgument, parseNewArgs(&.{ "a", "b" }));
}

test "an unknown template is not found" {
    try testing.expectEqual(null, findTemplate("no-such-template"));
}

test "index lists every template file" {
    const io = testing.io;
    var root = Io.Dir.cwd().openDir(io, "templates", .{ .iterate = true }) catch return error.SkipZigTest;
    defer root.close(io);
    var walker = try root.walk(testing.allocator);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // templates/index.zig itself is the index.
        if (std.mem.eql(u8, entry.path, "index.zig")) continue;
        found += 1;
        // entry.path is "<template>/<file path>".
        const slash = std.mem.findScalar(u8, entry.path, '/') orelse continue;
        const tname = entry.path[0..slash];
        const fpath = entry.path[slash + 1 ..];
        const template = findTemplate(tname) orelse {
            std.debug.print("templates/{s} is not in templates/index.zig\n", .{entry.path});
            return error.TemplateNotIndexed;
        };
        var listed = false;
        for (template.files) |f| {
            if (std.mem.eql(u8, f.path, fpath)) listed = true;
        }
        if (!listed) {
            std.debug.print("templates/{s} is not in templates/index.zig\n", .{entry.path});
            return error.FileNotIndexed;
        }
    }
    var indexed: usize = 0;
    for (index.templates) |t| indexed += t.files.len;
    try testing.expectEqual(found, indexed);
}
