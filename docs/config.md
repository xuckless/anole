# Configuration

Three things, in the order you meet them: your app's own settings
(`anole.config`), `.env` files, and the two modes Anole itself has,
`environment` (development or production) and `deployment` (what sits in
front of the server). A mode only fills what you left unset: a value you
write in code, JSON or a variable is never changed, and everything a mode
changed is printed once at startup.

## 1. Your app's settings

Declare a struct and load it:

```zig
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

`load` reads, lowest first: the field defaults, the per-environment defaults,
`Options.file`, the `.env` files and the process environment. It returns
`error.InvalidConfig` after logging every problem at once (`try` in `main`
then exits with status 1), and never puts a value in a message. Strings live
in `init.arena`, for the life of the process.

**Field types:** `bool`, integers, floats, enums, `[]const u8`,
`anole.Secret`, `anole.Duration`, a `[]const` slice of those (comma-separated
in `.env` and the environment, an array in JSON), nested structs, and `?T` of
any. Booleans accept `true/false/yes/no/on/off/1/0`.

**Names:** the field path joined by `_` and upper-cased, with
`Options.prefix` in front: `database_url` is `DATABASE_URL`; `db.port` is
`DB_PORT` (`APP_DB_PORT` with `.prefix = "APP_"`) and `"db": {"port": ...}`
in JSON or `port` in the `[db]` section of an INI file. Two fields that map
to one variable are a compile error. Unknown keys in a JSON or INI file are
problems with a "did you mean" hint; unknown variables are ignored (they hold
other programs' settings).

**`anole.Duration`** is written as a string with units in a file or variable:
`"30s"`, `"250ms"`, `"1m30s"`, `"1h"`. A bare number is refused, because `30`
could be seconds or milliseconds. In code, `.fromSeconds(30)`.

**`anole.Secret`** wraps a string that never prints: `{f}` writes
`[REDACTED]`, `{s}` does not compile, `{any}` shows only an address and a
length, and the JSON Lines logger redacts it wherever it sits in a logged
value. Read it with `.expose()`, so every use is easy to find. It guards
against accidental logging, not against code that wants the value.

**Per-environment defaults:** `pub const development = .{...}` and
`pub const production = .{...}` on the struct (or any nested struct) override
field defaults in that environment only; a nested struct literal overrides
some of its fields. They are defaults: the file, `.env` and the environment
still win. A name that matches no field is a compile error.

`Options` has `prefix`, `file` (a `.json` or `.ini` file that must exist),
`environment` (null: the resolved one), `env_files` and `dir`.

## 2. `.env` files

A `.env` file is `KEY=value` per line:

- keys match `[A-Za-z_][A-Za-z0-9_]*`; `export KEY=value` is accepted;
- `#` starts a comment at the start of a line, or after whitespace in an
  unquoted value;
- `"double quotes"` unescape `\n \t \r \" \\` and may span lines (paste a PEM
  key straight in); `'single quotes'` are literal and one line;
- `KEY=` is the empty string; there is no `${VAR}` expansion;
- a line without `=`, a bad name, an unterminated quote, a key twice in one
  file or a file over 1 MiB is a problem; every problem is reported, and any
  problem fails the whole read (nothing is applied).

**Which files, and when.** In `development`, from the working directory, the
first file that has a key wins: `.env.development.local`, `.env.local`,
`.env.development`, `.env`. In `production` and in tests, none, unless you
name them (`ServerOptions.env_files`, `config.Options.env_files`; `&.{}`
reads none). Missing files are skipped. A production process reads the real
environment; a development `.env` copied into an image must not supply a
production secret. Ignore `.env` and `.env*.local` in version control and
commit a `.env.example`.

The values go into a read-only overlay that Anole's environment reads consult
after the real environment: `DATABASE_URL`, `PG*`, `REDIS_URL`,
`MONGODB_URI`, `OTEL_*`, `ANOLE_*`, `PORT`. They are never put in the process
environment (a child process does not see them; pass what it needs
explicitly). `anole.env.get("NAME")` reads the same way. `ANOLE_ENV` in a
`.env` file is ignored, because it decides whether `.env` is read; the
startup line says so.

## 3. Anole's own variables

| Variable | Read when | Effect | From `.env` too |
| --- | --- | --- | --- |
| `ANOLE_ENV` | `environment` is null | `development` or `production`; anything else refuses to start | no |
| `ANOLE_DEPLOYMENT` | `deployment` is null | `standalone`, `behind_proxy`, `anole_lb`, `platform`, `lambda`; else refuses to start | yes |
| `ANOLE_PROXY_TRUSTED` | `proxy.trusted` is null | comma-separated entries as `proxy.trusted`; `""` trusts nobody | yes |
| `PORT` | deployment `platform`, for listeners whose port is null | that port | yes |
| `DATABASE_URL`, `PG*`, `REDIS_URL`, `MONGODB_URI` | the connectors | as before | yes |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` | tracing | as before | yes |
| `NATS_URL`, `KAFKA_BOOTSTRAP_SERVERS` (then `KAFKA_URL`) | the brokers | as before | yes |
| `LISTEN_PID`, `LISTEN_FDS`, `LISTEN_FDNAMES`, `NOTIFY_SOCKET`, `ANOLE_READY_FD`, `ANOLE_H3_SECRET_FD` | process control from systemd or a predecessor | as before | never |

Values are case-sensitive and lower case (`ANOLE_DEPLOYMENT=behind_proxy`).
They apply in Zig and in the C ABI alike. No other option has a variable: an
option you want operations to tune goes in your own `Config` and is passed to
Anole, as in section 1.

## 4. Precedence

For Anole's own settings, lowest first: the built-in default, the mode's
default, the `.env` files, the process environment, then the explicit option
(the Zig field or the JSON key). "Explicit" is exact: a mode or variable
fills a field only when it is `null`, so a value you wrote that happens to
equal the default is still yours.

For your app's typed config, lowest first: the field default, the
per-environment default, the config file, the `.env` files, the process
environment, then code.

## 5. `environment`

`ServerOptions.environment` is `development` or `production`. Null resolves
as: `ANOLE_ENV` (the real environment only), else development in a Debug
build and production in any release build, so `zig build run` is development
and a deployed release build is production. Tests and the C ABI fall back to
production, which keeps them deterministic (no `.env`, no detail in 500s).

| | development | production |
| --- | --- | --- |
| `.env` files | read | none |
| `error_detail` | on | off |
| Startup | the environment line | the environment line; a Debug build warns |

`error_detail` (null: on in development) makes a 500 for an error with no
status of its own name the error (`Internal Server Error: ConnectionRefused`)
instead of the bare phrase. Errors that map to a status (`error.NotFound`)
are unaffected. `app.environment()` and `anole.env.environment()` give the
resolved value.

## 6. `deployment`

`ServerOptions.deployment` says what sits in front. Null resolves from
`ANOLE_DEPLOYMENT`, else `standalone`; Anole never guesses from the platform
(it prints a hint when it sees Cloud Run's, Heroku's, Fly.io's or Render's
variables).

| Setting | standalone | behind_proxy | anole_lb | platform |
| --- | --- | --- | --- | --- |
| `proxy.trusted` (after `ANOLE_PROXY_TRUSTED`) | none: no gate | `loopback`, `private` | `loopback`, `private` | `loopback`, `private` |
| `X-Forwarded-*` read | only with `trusted_hops` (as 0.2) | from trusted peers | from trusted peers (after the PROXY header) | from trusted peers |
| `proxy_protocol` on each TCP listener | off | off | on | off |
| listener `address` | `127.0.0.1` | `127.0.0.1` | `""` (every interface) | `""` |
| listener `port` | 8080 | 8080 | 8080 | `$PORT`, else 8080 |
| `listenTls` adds HTTP/3 | yes | no | yes | no |
| warning for an untrusted peer | no | once | once | once |

Only `null` fields are filled: set `.address = "127.0.0.1"` under `platform`
and it stays. `proxy.trusted` takes addresses, CIDR networks, and the names
`loopback`, `private` (RFC 1918 and `fc00::/7`) and `link_local`. The client
is the rightmost `X-Forwarded-For` address that is not trusted, so a client
cannot forge the address by sending its own header; from a peer that is not
trusted the headers are ignored and the first such request logs one warning
(a public address: "firewall this port or add your proxy"; a private one:
"add it to proxy.trusted"). With `proxy_protocol` on and no
`proxy_protocol_from`, only `proxy.trusted` peers may connect; an empty
`trusted` with PROXY on is `ProxyProtocolNoPeers`.

**standalone** is the default and changes nothing from 0.2.

**behind_proxy**: nginx, Caddy, Traefik or a cloud L7 balancer sets
`X-Forwarded-For` and `X-Forwarded-Proto`. The listener stays on
`127.0.0.1` (a proxy on the same machine); a proxy in another container or
host needs `address = ""`, which the startup line reminds you of.

```nginx
location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Caddy sets both headers by default. Keep `timeouts.keepalive` (75 s by
default) above the balancer's idle timeout (nginx and AWS ALB: 60 s), or the
balancer can reuse a connection Anole just closed and see a 502.

**anole_lb**: an L4 balancer in front sends a PROXY protocol v2 header on
every connection (anole-lb when it ships; HAProxy `mode tcp` with
`send-proxy-v2`; AWS NLB with proxy protocol v2). Every TCP listener then
expects the header unless it sets `proxy_protocol = false`, so an admin or
metrics port scraped directly must say so.

**platform**: Render, Heroku, Fly.io, Cloud Run and Railway run the app
behind their own proxy and name the port in `PORT`. Leave the port to it
(`app.run()` or `.http = .{}`): a port you name in code (`listen(":3000")`)
wins, with a startup warning when `PORT` differs. TLS is the platform's, so
`listenTls` adds no HTTP/3.

**lambda** is reserved: `error.DeploymentUnavailable` before Anole 0.4.

## 7. What is printed at startup

Each line is logged once at `info` (scope `anole`). A warning is `warn`.

```
environment development (Debug build): read .env (3 values), .env.local (1 value); 500 answers name the error
environment production (ANOLE_ENV)
environment production (release build)
deployment behind_proxy (ANOLE_DEPLOYMENT): X-Forwarded-For and X-Forwarded-Proto from 127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 (proxy.trusted); 127.0.0.1 only: a proxy in another container or on another host needs address ""
deployment platform (ANOLE_DEPLOYMENT): X-Forwarded-For and X-Forwarded-Proto from ...; every interface (address ""); port 41234 from PORT; no HTTP/3 from listenTls (listen_tls_http3)
proxy.trusted from ANOLE_PROXY_TRUSTED: 10.0.0.0/8, 203.0.113.7/32
this looks like Cloud Run (K_SERVICE is set): set ANOLE_DEPLOYMENT=platform to listen on $PORT and trust its proxy
ANOLE_ENV in .env.local is not used: it decides whether .env files are read, so set it in the environment
```

A Debug build that runs as production warns: "a Debug build running as
production: Debug builds are several times slower; build with
-Doptimize=ReleaseSafe". Nothing in these lines is a `.env` value, or any
variable's value other than `ANOLE_*`, `PORT` and the trusted networks.

## The C ABI

The same keys exist in the JSON configuration (`environment`, `deployment`,
`error_detail`, `proxy.trusted`, nullable listener fields), and
`anole_dotenv_read` lets a binding read `.env` files with this page's
dialect and order. See [c-abi.md](c-abi.md#environment-and-env).
