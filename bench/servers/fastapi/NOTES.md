# FastAPI: implementation notes

FastAPI 0.146.0 on Starlette 1.9.0 and Python 3.13.16 (`python:3.13.16-slim-trixie`).
One ASGI app (`app.py`) is served by uvicorn for `h1` and `tls`, and by
Hypercorn for `h2c` and `h3`. `grpc` is a separate grpc.aio process
(`grpc_server.py`). `entrypoint.sh` picks the server from `MODE`.
Every dependency is pinned with `==` in `requirements.txt`, which is the
`pip freeze` of the top-level packages.

## Source size

| File | Lines | Code (no blanks, comments or docstrings) |
|---|---:|---:|
| `app.py` | 328 | 258: HTTP routes, 404, static mount and setup 68; lifespan 10; WebSockets with ticker and trade 80; $12 routes 100 |
| `grpc_server.py` | 50 | 31 |
| `h3_workers.py` | 54 | 35 (only needed because of the Hypercorn bug below) |
| `entrypoint.sh` | 33 | 27 |
| `Dockerfile` | 21 | 16 |

## Per protocol

- **HTTP/1.1 (`h1`).** `uvicorn app:app --workers N` with `uvicorn[standard]`,
  so `--loop auto` and `--http auto` pick uvloop and httptools. FastAPI's
  deployment docs show both `fastapi run --workers 4` and
  `uvicorn main:app --workers 4`. We use `uvicorn` directly because
  `fastapi run` (fastapi-cli) has no flags for TLS, log level, access log
  or keep-alive. Flags: `--timeout-keep-alive 75`, because uvicorn's default
  is 5 s and the spec asks for at least 75 s; `--no-access-log`;
  `--log-level warning`. Friction: none, apart from the keep-alive default.
- **TLS (`tls`).** The same uvicorn command with
  `--ssl-certfile/--ssl-keyfile`. It is HTTP/1.1 only, and uvicorn
  advertises no ALPN at all (`openssl s_client -alpn h2,http/1.1` reports
  "No ALPN negotiated"), so clients fall back to HTTP/1.1. uvicorn 0.54 has
  an `--http zttp --http2` option, but it needs the separate pre-1.0 `zttp`
  package, which `uvicorn[standard]` doesn't include, so we leave it off.
- **HTTP/2 cleartext (`h2c`).** The same app under `hypercorn app:app --bind
  0.0.0.0:PORT --workers N --keep-alive 75`, using the default `asyncio`
  worker class (Hypercorn's documented default; `uvloop` is optional). It
  needs no code changes: Hypercorn speaks h2c with prior knowledge and
  HTTP/1.1 on the same port. Its default keep-alive is also 5 s. Hypercorn
  also supports WebSockets over HTTP/2 (RFC 8441, extended CONNECT); a
  hand-written h2 client got an echo back on `/ws/echo`.
- **HTTP/3 (`h3`).** `hypercorn[h3]` (aioquic) with `--certfile/--keyfile
  --bind :8443 --quic-bind :8443`. The TCP side does TLS with ALPN h2 and
  http/1.1, and responses carry `alt-svc: h3=":8443"`. **Friction, and a
  bug:** with `--workers N > 1`, Hypercorn binds a single UDP socket in the
  parent and shares it with every worker, so datagrams of one QUIC
  connection land in random processes and connections fail. In testing,
  about 5% of fresh connections failed and parallel 20 MB downloads were
  truncated. With `WORKERS > 1`, `h3_workers.py` therefore starts one
  Hypercorn per worker, each on its own `SO_REUSEPORT` TCP and UDP socket,
  handed over through Hypercorn's `fd://` binds. The kernel hashes each
  client address to one socket, and after that change every check passed.
  With `WORKERS=1` it is the plain `hypercorn` command.
- **gRPC (`grpc`).** grpcio 1.84.0 `grpc.aio`. The code is generated in the
  Docker build by grpcio-tools in a separate build stage, so it isn't in
  the runtime image. **Friction:** the protos live in the `grpc/testing/`
  directory, so the generated modules would be `grpc.testing.*`, and
  grpcio's own `grpc` package shadows them. The build copies the protos
  under `interop/` and rewrites their `import` lines to match. The proto
  package is still `grpc.testing`, so the service name on the wire is
  unchanged. `grpc.aio` is one process with one event loop, so for
  `WORKERS > 1` we start one process per worker with `grpc.so_reuseport`,
  as in grpcio's `examples/python/multiprocessing`.
- **WebSockets.** Starlette's `WebSocket`. Under uvicorn,
  `--ws auto` picks the websockets 17.2 sans-I/O implementation. Under
  Hypercorn it is wsproto. `/ws/feed` uses the `ConnectionManager.broadcast`
  pattern from FastAPI's WebSockets docs, and the ticker is one asyncio task
  per worker process, started in the lifespan. The ticker runs on a fixed
  10 ms deadline grid (`deadline += 0.01; sleep(deadline - now)`) and
  measured exactly 1000 msg/s per subscriber at `TICK_HZ=1000` and 5000
  msg/s at 5000. `/ws/trade` keeps its position in a per-process dict and
  needs no lock, because each process runs one event loop.
- **Static files.** `app.mount("/static", StaticFiles(directory=MEDIA_DIR))`.
  Starlette 1.9's `FileResponse` handles `Range` itself and returns 206 with
  `content-range`, so no add-on is needed.
- **$12.** asyncpg 0.32.0, with one `create_pool(min_size=max_size=
  ceil(PG_POOL/WORKERS))` per worker, created in the lifespan. Queries use
  `$1` parameters, and asyncpg prepares and caches statements by default.
  PyJWT 2.15.1 decodes with `algorithms=["HS256"]`; `exp` is checked when
  present (the library default, as with golang-jwt). PyJWT itself rejects a
  non-string `sub` (`InvalidSubjectError`), which is mapped to `invalid token
  payload`. PyJWT warns once per process (`InsecureKeyLengthWarning`) that
  the 23-byte challenge secret is shorter than 32 bytes. Auth is a FastAPI
  `Depends` that runs before the id check. Errors are an `ApiError`
  exception with an exception handler.

## JSON

- FastAPI's defaults throughout: routes return dicts, which go through
  `jsonable_encoder` and `JSONResponse`. Starlette's `JSONResponse.render`
  is `json.dumps(..., ensure_ascii=False, allow_nan=False,
  separators=(",", ":"))`, which is already compact, so no override is needed.
- `ORJSONResponse` (or `default_response_class=ORJSONResponse`) is the common
  speed-up for FastAPI. **We deliberately didn't apply it.**
- `/gc/alloc` builds `n` fresh dicts and serializes them with that same
  `json.dumps` call, without `jsonable_encoder`. It returns
  `{"n":2000,"bytes":137422}`, the same as Anole.
- WebSocket messages use `json.dumps(separators=(",", ":"))` (feed: one
  serialization per tick, sent to every subscriber) and Starlette's
  `send_json`/`receive_json` (trade).

## Other choices

- `openapi_url=None, docs_url=None, redoc_url=None`: otherwise `/docs`,
  `/redoc` and `/openapi.json` would answer 200, while the spec wants a 404
  for anything else.
- The 404 body comes from an exception handler for Starlette's
  `HTTPException`; a missing file under `/static/` gets the same body.
- `RETAIN` objects are dicts in a module-level list, built at import, so
  each worker process has its own copy.
- `/ws/feed`: `seq` advances on every tick, even when no one is
  subscribed, but no message is built until someone subscribes.
- Everything runs as root in the container, like the base image.
