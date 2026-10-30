//! Numbered SQL migrations for the SQL connectors (`anole.pg`,
//! `anole.sqlite`): `anole.db.migrate`. Each migration runs once, in a
//! transaction of its own, and is recorded in the table `schema_migrations`.
//!
//!     const migrations = [_]anole.db.Migration{
//!         .{ .version = 1, .name = "init", .sql = @embedFile("migrations/001_init.sql") },
//!         .{ .version = 2, .name = "add_tags", .sql = @embedFile("migrations/002_add_tags.sql") },
//!     };
//!     _ = try anole.db.migrate(state.db, &ctx, &migrations);
const std = @import("std");

const log = std.log.scoped(.anole);

/// One migration: SQL that runs once, recorded by its version.
pub const Migration = struct {
    /// Orders the migrations and identifies one in `schema_migrations`;
    /// from 1, increasing through the list. Never reuse one that shipped.
    version: u32,
    /// For `schema_migrations` and the logs.
    name: []const u8,
    /// One or more statements, without `BEGIN` or `COMMIT`: the migration's
    /// transaction is the runner's.
    sql: []const u8,
};

/// The table that records what ran.
pub const table = "schema_migrations";

const create_table = "CREATE TABLE IF NOT EXISTS " ++ table ++
    " (version BIGINT PRIMARY KEY, name TEXT NOT NULL, applied_at BIGINT NOT NULL)";

/// Runs every migration of `migrations` that `schema_migrations` does not
/// record, in the list's order, each in its own transaction with its
/// record, and returns how many ran. `db` is an `*anole.pg.Client` or an
/// `*anole.sqlite.Client`; `c` a `*anole.db.Ctx` (startup) or the request.
///
/// A migration that fails is rolled back with its record, the call returns
/// its error (the detail in `anole.db.lastError(c)`), and the ones before
/// it stay applied. Versions that do not increase through the list are
/// `error.MigrationsOutOfOrder`, before anything runs. A migration whose
/// version is below the latest applied but is not recorded (merged in
/// from another branch) runs too.
///
/// No bound on time: neither the connector's `Options.timeout` nor
/// `TxOptions.timeout` applies.
pub fn migrate(db: anytype, c: anytype, migrations: []const Migration) !usize {
    comptime {
        const Db = @typeInfo(@TypeOf(db)).pointer.child;
        if (!@hasDecl(Db, "begin") or !@hasDecl(Db, "execScript"))
            @compileError("anole.db.migrate takes an *anole.pg.Client or an *anole.sqlite.Client, not " ++ @typeName(@TypeOf(db)));
    }
    var previous: u32 = 0;
    for (migrations) |m| {
        if (m.version <= previous) {
            log.warn("migration {d} ({s}) follows version {d}: versions must increase from 1", .{ m.version, m.name, previous });
            return error.MigrationsOutOfOrder;
        }
        previous = m.version;
    }

    try db.execScript(c, create_table);
    const applied = try db.with(.{ .timeout = .max }).all(i64, c, "SELECT version FROM " ++ table ++ " ORDER BY version", .{});

    var ran: usize = 0;
    var seen: usize = 0;
    for (migrations) |m| {
        const version: i64 = m.version;
        while (seen < applied.len and applied[seen] < version) seen += 1;
        if (seen < applied.len and applied[seen] == version) continue;

        var tx = try db.begin(c, .{ .timeout = .max });
        defer tx.deinit();
        // Another process may have run it since the read above.
        if (try tx.optional(i64, c, "SELECT version FROM " ++ table ++ " WHERE version = $1", .{version}) != null) continue;
        _ = tx.with(.{ .timeout = .max, .prepare = false }).exec(c, m.sql, .{}) catch |err| {
            log.warn("migration {d} ({s}) failed: {t}; rolled back", .{ m.version, m.name, err });
            return err;
        };
        const now = std.Io.Clock.real.now(c.io).toSeconds();
        _ = try tx.exec(c, "INSERT INTO " ++ table ++ " (version, name, applied_at) VALUES ($1, $2, $3)", .{ version, m.name, now });
        try tx.commit(c);
        log.info("migration {d} ({s}) applied", .{ m.version, m.name });
        ran += 1;
    }
    return ran;
}
