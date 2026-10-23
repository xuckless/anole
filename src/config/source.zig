// Copied from vkiryakov/zefir src/confy/source.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Where configuration comes from.

/// One configuration source. Create it with `.json(path)`, `.ini(path)`,
/// `.env(path)` or `.osEnv()`.
pub const ConfigSource = union(enum) {
    json_file: []const u8,
    ini_file: []const u8,
    dotenv: []const u8,
    os_env,
    /// The `.env` entries Anole read (`SourceOptions.overlay`).
    dotenv_files,

    /// A JSON file. It must exist.
    pub fn json(path: []const u8) ConfigSource {
        return .{ .json_file = path };
    }

    /// An INI file. It must exist.
    pub fn ini(path: []const u8) ConfigSource {
        return .{ .ini_file = path };
    }

    /// A `.env` file. It is skipped when it doesn't exist, so optional files
    /// such as `.env.local` can always be listed.
    pub fn env(path: []const u8) ConfigSource {
        return .{ .dotenv = path };
    }

    pub fn dotenvFiles() ConfigSource {
        return .dotenv_files;
    }

    /// The process environment, taken from `Options.environ`.
    pub fn osEnv() ConfigSource {
        return .os_env;
    }
};
