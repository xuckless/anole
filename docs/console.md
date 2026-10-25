# The live console

`anole console` shows a running Anole app from another terminal: its logs,
requests per route, recent 5xx answers, connections, databases, HTTP/3,
runtime numbers, resolved configuration and routes. In development, typing
`c` and Enter in the terminal the app runs in opens the same screen there.

```
$ zig build run
info(anole): listening on http://localhost:3000 (h1, h2c)
info(anole): console: `anole console api` attaches (socket /run/user/1000/anole/api.48213.sock)
info(anole): press c + Enter for the live console
```

## Opening it

- **Any time:** `anole console [name|pid|socket path]` from a terminal of the
  same user on the same machine (`ssh -t host anole console` for a remote
  one). Ctrl-C, `/quit` or `/exit` leave the console; the app keeps running.
- **Development:** `c` + Enter. Esc (empty command line, no popup) or `/quit`
  returns to plain logs; Ctrl-C stops the server as it always did. The hotkey
  is on only in development, when stdin and stderr are terminals, outside
  systemd, containers and CI, and never in tests. An app that reads stdin
  itself sets `console.keys = false`.
- **Windows:** not yet. `anole console` says so; use WSL2 or Docker.

Until the first log line arrives, the log view shows a small anole logo
(when the window has room for it).

`anole console --list` lists the apps, `--snapshot <view>` prints one view
(`conns`, `db`, `ws`, `h3`, `runtime`, `config`, `routes`, `errors`) as JSON
without a terminal, `--wedge-timeout <s>` sets when an app counts as stuck.
Exit codes: 5 no app found, 6 refused (busy, version, permission), 7 not a
terminal, 8 not available on this OS.

## Commands

| Command | Shows or does |
|---|---|
| `/logs [level=] [scope=] [route=] [id=] [grep=]` | live log tail; filters run in the server |
| `/requests [sort=] [window=10s\|60s]` | per route: req/s, p50, p99, 4xx/s, 5xx/s |
| `/errors [route=]` | the last 256 5xx answers; Enter jumps to `/logs id=...` |
| `/conns` | per executor: connections, streams, tasks, run queue; listeners |
| `/db [name]` | per database: pool size, open, idle, in use |
| `/ws` | open WebSockets by protocol, WebTransport sessions, rooms (members, queued bytes, members closed as slow), SSE topics (subscribers) |
| `/h3` | per HTTP/3 endpoint counters |
| `/runtime` | RSS, CPU, threads, descriptors, versions, the binding's language metrics |
| `/config` | resolved environment and deployment, options (secrets redacted), `.env` files (names and counts), features |
| `/routes [text]` | method, pattern, flags |
| `/tasks` | needs a task registry in the runtime; not available yet |
| `/reload` | reload TLS certificates from their files (as SIGHUP) |
| `/drain` | asks, then drains and stops the server |
| `/restart` | asks, then the zero-downtime hand-off (as SIGUSR2) |
| `/full-restart [--kill]` | asks, then drops everything and restarts |
| `/help`, `/quit`, `/exit` | |

Keys: Enter runs, Tab completes, Esc closes the popup then clears the input,
Up/Down history, PgUp/PgDn/Home/End scroll, Ctrl-L redraws, Ctrl-Z suspends.
`NO_COLOR` turns colour off; `TERM=dumb` refuses the interactive console.

## What is collected, and what it costs

- Log records: warnings and errors are always kept (4 MiB in 16 rings, no
  per-record allocation); info and debug only while a console shows logs.
  Producers never wait for a console: a console that stops reading sees a
  `dropped N` notice, not a slow server.
- 5xx answers: always kept (256 entries); one status compare per request.
- Per-route numbers (counts, status classes, a 98-bucket latency histogram)
  are collected only while a console shows `/requests`: one relaxed load per
  request otherwise. Latency of a 5xx kept while nobody collects is 0.
- Connections, streams, open WebSockets and WebTransport sessions, tasks and
  run queues come from the runtime's always-on gauges.
- Rooms, SSE topics and database pools are read when `/ws` or `/db` asks, by
  a task of the server's runtime under the locks they live behind (the
  console's own threads never take the runtime's locks); a room or hub busy
  at that moment is skipped until the next refresh, and a runtime too busy
  to answer within 200 ms shows the view as unavailable for that refresh.
  PostgreSQL pools show their size, open, idle and in use (pg counts no
  waiters).

## The control socket

A Unix stream socket `<runtime dir>/anole/<name>.<pid>.sock`: the runtime
directory is `$XDG_RUNTIME_DIR` (Linux), `/run` for root on Linux, `$TMPDIR`
on macOS, else `/tmp/anole-<uid>`. The directory is mode 0700 and owned by
the user (anything else disables the console with a warning and the server
runs on), the socket 0600, and a peer of another user (root excepted) is
refused. There is no TCP; remote is `ssh -t`. At most 4 consoles at once.
Protocol: newline-delimited JSON, `proto: 1`.

It is on by default in every environment (off in tests, under deployment
`lambda`, on Windows); off with `console.enabled = false` or `ANOLE_CONSOLE=0`.
Containers: `docker exec -it c anole console`; from the host mount the
directory and run `anole console /path/api.sock`. Kubernetes:
`kubectl exec -it pod -- anole console`.

`/reload`, `/drain`, `/restart` and `/full-restart` need a confirm token
(the terminal asks y/N first), and `console.read_only = true` refuses all of
them. `/restart` and `/full-restart` need `console.allow_restart` (default:
on in development, off in production). `/restart` needs the hand-off
(`.process = init.minimal`; not on Windows or under the C ABI).
`/full-restart` re-executes the process in place (same PID, arguments,
directory and environment), so systemd, Docker and pm2 see the same process;
when the app does not answer, or with `--kill`, the CLI sends SIGKILL and
waits for the supervisor or relaunches the app (output appended to
`<socket dir>/<name>.out`).

## Options

| Zig `ServerOptions.console` | JSON `console` | Default |
|---|---|---|
| `enabled` | `enabled` | on (see above) |
| `name` | `name` | `ANOLE_CONSOLE_NAME`, else the executable's name |
| `socket` | `socket` | the directory above |
| `allow_restart` | `allow_restart` | development on, production off |
| `read_only` | `read_only` | false |
| `keys` | (none: bindings own stdin) | development on a terminal |
| `log_buffer` | `log_buffer` | 4 MiB, 0 for none |
| `errors_kept` | `errors_kept` | 256 |
| `max_routes` | `max_routes` | 256 |
| | `runtime` | shown in the status line, e.g. `node 22.11.0` |

`-Dconsole=false` compiles the server side out (off in `-Dprofile=minimal`).

## Node and Python

The bindings set `console.name` and `console.runtime`, read `c` + Enter
themselves and call `anole_console_open` ([c-abi.md](c-abi.md#console)); the
screen runs on libanole's thread, so the language's event loop never blocks.
While it is open, `console.log` and `print` show in `/logs` as `stdout`.
The `anole` binary ships in each package (`npx anole console`,
`python -m anole console`).

## Troubleshooting

- A terminal left raw after a crash by signal: run `reset`.
- "not a private directory": set `console.socket` to a path in a 0700
  directory of yours.
- Several apps with the same name: pick by pid.
