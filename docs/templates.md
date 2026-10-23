# Templates: `anole new` and `anole init`

`anole` is a small command line (a std-only Zig program, never linked into your
app) that makes a project from one of five templates:

```
anole new my-api                          # the minimal template
anole new my-api --template rest-postgres
anole templates                           # lists them
cd my-api && zig build run
```

It runs `zig init -m` (so the project gets its own name and fingerprint), writes
the template's files, adds Anole to `build.zig.zon` with `zig fetch --save`
(the tag that matches the CLI) and writes a ready `.env` copied from
`.env.example`. It never asks anything, so it works the same in a script.

## Getting it

Download `anole` for your system from the
[latest release](https://github.com/xuckless/anole/releases) (Linux and macOS,
x86_64 and aarch64, and Windows x86_64), check it against `SHA256SUMS`, make it
executable and put it on your PATH. Or build it from a clone, with no download
of C libraries:

```
zig build cli -Dprofile=minimal       # zig-out/bin/anole
```

## The templates

| Template | Profile | What it is |
| --- | --- | --- |
| `minimal` (default) | `web` | typed routes (`GET /`, `GET /users/:id`, `POST /echo` with rules), health, the OpenAPI page, in-memory tests |
| `rest-postgres` | `web` | a todo API on PostgreSQL: typed CRUD, rules as 422, a missing row as 404, a duplicate as 409, `/readyz` pings the database, `compose.yaml` and `db/schema.sql`, typed config |
| `realtime` | `web` | a WebSocket chat with rooms, a browser page as static files, a typed `GET /rooms`, a test with two clients |
| `grpc` | `full` | a `.proto` service that answers gRPC, gRPC-Web, Connect and REST, with the comments in the OpenAPI document |
| `full` | `full` | most of Anole in one app that needs no outside service: typed routes with rules on SQLite, WebSocket rooms, server-sent event topics, background jobs and a cron schedule on SQLite, sessions with CSRF, JWT and roles, API keys, gRPC with transcoding, an outbound client with retry and a breaker, rate limit, metrics, health, tracing, typed config and `.env`, an OpenAPI page. PostgreSQL, Redis, NATS, Kafka, S3 and SMTP start when their URL is set in `.env` |

Every template has `src/main.zig` with a `routes` function separate from
`main` (so `src/main_test.zig` serves the same routes through `anole.testing`),
`build.zig` (`addApp` plus a `test` step), `.gitignore` (`zig-out/`,
`.zig-cache/`, `zig-pkg/`, `.env`, `.env*.local`), `.env.example` (committed;
`.env` is not) and a README. `zig build run` starts the app, `zig build test`
runs the tests and `zig build openapi` writes `openapi.json`.

There is no Dockerfile: a release build (`zig build -Doptimize=ReleaseSafe`)
already runs in production mode, and [server.md](server.md) says how to deploy
it.

## `anole init`

`anole init` does the same in the current directory. It refuses a directory
that has files unless you give `--force`; with `--force` in an existing Zig
project (one with a `build.zig.zon`) it keeps your manifest, adds Anole to it
and writes the template's files, stopping before it overwrites anything
(including your `build.zig`).

## Options

| | |
| --- | --- |
| `--template <name>` | which template (default `minimal`) |
| `--anole <ref>` | the Anole tag, branch or commit to depend on (default: the CLI's tag) |
| `--anole-path <dir>` | depend on a local checkout (a path dependency, written relative to the project) |
| `--no-fetch` | leave the dependency out and print the `zig fetch` line (offline) |
| `--force` | allow a non-empty directory (never overwrites a file) |

Exit codes: 0 done; 1 usage; 2 the directory is not empty or a file exists; 3
`zig` not found; 4 `zig init` or `zig fetch` failed (the command to retry is
printed).
