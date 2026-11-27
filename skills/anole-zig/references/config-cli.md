# Config, build and CLI

Up: [SKILL.md](../SKILL.md). Related: [observability.md](observability.md), [testing.md](testing.md), [deployment](deployment/index.md), [zig-0.17.md](zig-0.17.md).

Full docs: docs/config.md, docs/templates.md, README.md (Build flags), docs/server.md (Root declarations). Examples: templates/full/src/config.zig, templates/*/build.zig, tools/anole/main.zig.

Do not hand-roll env parsing, a `.env` reader, a dev/prod switch or a `build.zig` that wires Anole's modules by hand.

## Typed config

Use: `anole.config.load(T, init, options)` (src/config/root.zig), `anole.config.Options` (`.prefix`, `.file`, `.environment`, `.env_files`, `.dir`), `anole.Secret` with `expose()` (src/config/Secret.zig), `anole.Duration`.

```zig
// docs/config.md
const Config = struct {
    database_url: anole.Secret, // required: DATABASE_URL
    port: u16 = 3000,
    stripe_key: ?anole.Secret = null,
    request_timeout: anole.Duration = .fromSeconds(30),
    cache: struct { ttl: anole.Duration = .fromSeconds(60) } = .{},

    pub const development = .{ .cache = .{ .ttl = anole.Duration.fromSeconds(1) } };
};

pub fn main(init: std.process.Init) !void {
    const cfg = try anole.config.load(Config, init, .{});
    var app = try anole.App.init(init.gpa, .{ .timeouts = .{ .request = cfg.request_timeout } });
    defer app.deinit();
    state.db = try app.postgres(.{ .url = cfg.database_url.expose() });
    try app.listen(":3000");
}
```

Order, lowest first: field defaults, `pub const development`/`production` defaults, `Options.file` (`.json` or `.ini`), `.env` files, the process environment. Names: field path joined by `_`, upper-cased, with `prefix` in front (`db.port` is `DB_PORT`).

Traps:
- A field without a default is required. Every problem is logged at once, then `error.InvalidConfig`; values are never printed.
- `anole.Duration` in a file or variable needs units (`"30s"`, `"250ms"`, `"1m30s"`); a bare number is refused.
- `Secret` does not compile with `{s}`; `{f}` prints `[REDACTED]`. Call `.expose()` only where the value is used.
- Slices are comma-separated in `.env` and the environment, arrays in JSON. Booleans take `true/false/yes/no/on/off/1/0`.
- Strings live in `init.arena` for the life of the process; do not free them.

## .env files

Use: `ServerOptions.env_files`, `anole.config.Options.env_files`, `anole.env.get`, `anole.env.environment` (src/env.zig).

In development, first file with a key wins: `.env.development.local`, `.env.local`, `.env.development`, `.env`. In production and tests: none unless named (`&.{}` reads none). Templates ship `.env.example` (committed) and `.gitignore` with `.env` and `.env*.local`.

Traps:
- Values go into a read-only overlay, never the process environment: a child process does not see them, and `std.process` environment reads do not either. Read with `anole.env.get("NAME")` or `config.load`.
- `ANOLE_ENV` in a `.env` file is ignored (it decides whether `.env` is read).
- No `${VAR}` expansion. Any problem in a file fails the whole read.

## Environment and deployment

Use: `ServerOptions.environment` (`anole.Environment`: `development`, `production`), `ServerOptions.deployment` (`anole.Deployment`: `standalone`, `behind_proxy`, `anole_lb`, `platform`, `lambda`) (src/modes.zig); `anole.App.environment`, `anole.App.deployment` (src/server.zig).

```zig
// templates/full/src/main.zig
if (app.environment() == .development) {
    std.log.info("demo API key:\n{s}", .{key.key});
}
```

- `environment` null: `ANOLE_ENV`, else development in a Debug build, production in a release build; tests and the C ABI fall back to production. Development reads `.env` and names the error in 500 answers (`error_detail`).
- `deployment` null: `ANOLE_DEPLOYMENT`, else the build's `-Ddefault-deployment`, else `standalone`. It fills only null fields: trusted proxies, listener address and port (`platform` takes `$PORT`), PROXY protocol, HTTP/3 from `listenTls`. Details: [listeners and proxies](deployment/listeners-proxy.md#behind-a-proxy).

Traps:
- Values are lower case (`ANOLE_DEPLOYMENT=behind_proxy`); anything else refuses to start with `InvalidEnvironmentVariable`.
- A mode never overrides a value you wrote, except `lambda`, which sets every named listener aside.
- No other Anole option has an environment variable: put tunables in your own `Config` and pass them in.

## Build side: addApp

Use: `addApp(b, AppOptions)` from Anole's build.zig, `AppOptions` `.name`, `.root_source_file`, `.target`, `.optimize`, `.profile`, `.features`, `.protos`, `.imports`, `.run_step`, `.openapi`, `.lambda`; returns `App` with `.exe` and `.anole` (build.zig).

```zig
// templates/minimal/build.zig
const app = anole.addApp(b, .{
    .name = "{{name}}",
    .root_source_file = b.path("src/main.zig"),
    .profile = .web,
});
```

Steps it adds: `run`, `openapi`, `openapi-check`, and with `.lambda = .{}` the `lambda` steps ([lambda](deployment/lambda.md)). The test step is yours ([testing.md](testing.md#test-step-in-buildzig)).

Traps:
- Reuse `app.anole` (the dependency) for more executables or tests; a second `b.dependency("anole", ...)` with other arguments collides.
- `-Doptimize=ReleaseFast`/`ReleaseSmall` logs a warning: use `ReleaseSafe` for production.

## Feature flags and profiles

`.profile = .minimal | .web | .full` (default `full`; `-Dprofile`) sets every flag; `.features = .{ .kafka = false }` (`FeatureFlags`, build.zig) overrides single ones. What is off is never fetched or compiled, and its `anole.<namespace>` is an empty struct. `anole.features` holds the result at compile time.

| Flag | minimal | web | full |
| --- | --- | --- | --- |
| `tls` (boringssl/none) | none | boringssl | boringssl |
| `http2`, `compression`, `brotli`, `libdeflate`, `websocket`, `auth`, `json`, `postgres`, `sqlite`, `openapi`, `console`, `net`, `jobs`, `webhooks`, `s3`, `smtp` | off | on | on |
| `http3`, `grpc`, `redis`, `mongodb`, `nats`, `kafka` | off | off | on |
| `lambda` | on | on | on |

Constraints (errors otherwise): gRPC needs HTTP/2, HTTP/3 needs TLS, Brotli/libdeflate/Kafka need compression, webhooks need jobs.

Traps:
- Calling a helper whose feature is off is a compile error that names the flag (`app.kafka needs Kafka (-Dkafka, on in the full profile)`).
- A listener the build left out fails at start (`error.TlsNotBuilt`, `error.Http3NotBuilt`); guard with `anole.features`:

```zig
.https = if (anole.features.tls != .none) .{ .port = 8443, .cert = .dev_self_signed } else null,
```

## Root file declarations

All optional, in the executable's root file (docs/server.md "Root declarations"; src/root.zig):

```zig
pub const std_options = anole.std_options; // quiet Debug-build runtime lines; logs as records
pub const panic = anole.panic;             // panic as one log line, then abort
pub const zio_options = anole.zio_options; // only if you declare zio options at all
```

Traps:
- Anole needs zio's pinned scheduling. A root `zio_options` that asks for `.work_stealing` is a compile error (src/server.zig `checkZioOptions`). To set other zio options keep `.scheduling = .pinned`: `pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned, .debug_cancel = true };`.
- Never set `std_options_debug_io = zio.debug_io` (as zio's own examples do): stack-trace capture inside allocator and task-pool locks can suspend a coroutine holding one, a livelock or recursive-lock abort (docs/server.md).

## The anole CLI

Std-only program, never linked into the app (tools/anole/main.zig):

```
anole new <dir> [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
anole init [--template <name>] [--anole <ref>] [--anole-path <dir>] [--no-fetch] [--force]
anole templates
anole console [<name>|<pid>|<socket path>] [options]
anole version
anole help [command]
```

Templates: `minimal` (default, web), `rest-postgres` (web), `realtime` (web), `grpc` (full), `full` (full). `new` runs `zig init -m`, writes the files, `zig fetch --save=anole` at the CLI's tag, and copies `.env.example` to `.env`. It never prompts. Every template has `routes` apart from `main`, a `test` step, and `zig build run` / `test` / `openapi`.

Traps:
- `--anole` and `--anole-path` together are a usage error. `init --force` keeps an existing `build.zig.zon` and never overwrites a file.
- Exit codes: 0 ok, 1 usage, 2 directory not empty or file exists, 3 `zig` not found, 4 `zig init`/`zig fetch` failed.
- Console subcommand: [observability.md](observability.md#live-console).
