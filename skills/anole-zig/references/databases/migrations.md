# Migrations

Up: [index](index.md). Related: [postgres](postgres.md), [sqlite](sqlite.md).

Use `anole.db.migrate` for schema changes on PostgreSQL and SQLite instead of a hand-written version table or an external tool. Full docs: docs/database.md#migrations. Source: src/db/migrate.zig.

Use: `anole.db.migrate`, `anole.db.Migration` (`version`, `name`, `sql`), `anole.db.Ctx` (src/db/root.zig, src/db/migrate.zig).

Run it at startup, before `listen`; it returns how many ran (from docs/database.md):

```zig
const migrations = [_]anole.db.Migration{
    .{ .version = 1, .name = "init", .sql = @embedFile("migrations/001_init.sql") },
    .{ .version = 2, .name = "add_tags", .sql = @embedFile("migrations/002_add_tags.sql") },
};

var arena: std.heap.ArenaAllocator = .init(init.gpa);
defer arena.deinit();
var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
_ = try anole.db.migrate(state.db, &c, &migrations);
```

The table `schema_migrations` (`version`, `name`, `applied_at` in Unix seconds) records what ran and is created when missing. A migration runs when its version is not recorded, so one merged in below the latest applied version still runs.

Traps:
- Versions start at 1 and increase through the list; anything else is `error.MigrationsOutOfOrder` before anything runs.
- Append new migrations; never edit a shipped one: an edited migration does not run again (docs/database.md:157). There are no down migrations: undo with a new one.
- Each migration runs in its own transaction with its record. `sql` may hold several statements but no `BEGIN` or `COMMIT` of its own.
- Statements that cannot run in a transaction (PostgreSQL's `CREATE INDEX CONCURRENTLY`, SQLite's `VACUUM`) do not belong in a migration.
- A failed migration is rolled back and its error returned (the database's message in `anole.db.lastError(&c)`); the ones before it stay applied, and the next start tries it again.
- On PostgreSQL a second process migrating at the same time fails rather than applying twice: migrate from one process, a release step or the first instance (docs/database.md:166). SQLite processes take turns on the write lock.
- Neither the connector's `timeout` nor a transaction's applies to `migrate`.
- For a schema without versioning (examples, tests), `execScript(&c, schema)` (SQLite, PostgreSQL) or `exec(&c, schema, .{})` runs every statement in the text.
