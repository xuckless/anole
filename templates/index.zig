//! The project templates of `anole new`, embedded in the CLI. Each template is
//! a directory under templates/ with its files; this index lists them (a test
//! in tools/anole/main.zig checks that no file is forgotten). Templates come
//! with the second part of the tooling lane; the list is empty until then.

pub const File = struct {
    /// Relative to the project root, '/'-separated.
    path: []const u8,
    /// The file's text; `{{name}}` is replaced by the project name.
    data: []const u8,
};

pub const Template = struct {
    name: []const u8,
    summary: []const u8,
    /// Printed after the project is created (lines, already indented).
    next_steps: []const u8,
    files: []const File,
};

pub const templates = [_]Template{};
