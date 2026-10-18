"""FastAPI side of the benchmark (bench/SPEC.md).

One app, served by uvicorn (MODE=h1, tls) or Hypercorn (MODE=h2c, h3).
Every worker process imports this module, so RETAIN, the ticker, the trade
position and the Postgres pool are per process.
"""

import asyncio
import json
import math
import os
import re
import time
from contextlib import asynccontextmanager

import asyncpg
import jwt
from fastapi import Depends, FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.exception_handlers import http_exception_handler
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

MEDIA_DIR = os.environ.get("MEDIA_DIR", "/media")
DATABASE_URL = os.environ.get("DATABASE_URL")
PG_POOL = int(os.environ.get("PG_POOL", "20"))
WORKERS = int(os.environ.get("WORKERS", "1"))
JWT_SECRET = os.environ.get("JWT_SECRET", "twelve-dollar-challenge")
TICK_HZ = int(os.environ.get("TICK_HZ", "1000"))
RETAIN = int(os.environ.get("RETAIN", "0"))

# GC test: objects kept reachable for the life of the process.
retained = [
    {"id": i, "name": f"retained-{i}", "tags": [f"x{i % 7}", f"y{i % 11}", f"z{i % 13}"]}
    for i in range(RETAIN)
]


# /ws/feed: the broadcast pattern from FastAPI's WebSockets docs.
class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def broadcast(self, message: str):
        for connection in list(self.active_connections):
            try:
                await connection.send_text(message)
            except Exception:
                self.disconnect(connection)


feed = ConnectionManager()


async def ticker():
    loop = asyncio.get_running_loop()
    per_wake = TICK_HZ // 100
    seq = 0
    deadline = loop.time()
    while True:
        deadline += 0.01
        await asyncio.sleep(max(0.0, deadline - loop.time()))
        for _ in range(per_wake):
            seq += 1
            if not feed.active_connections:
                continue
            tick = {
                "seq": seq,
                "ts": time.time_ns() // 1000,
                "sym": "BTCUSD",
                "px": 100000 + seq % 1000,
                "qty": 1 + seq % 10,
            }
            await feed.broadcast(json.dumps(tick, separators=(",", ":")))


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(ticker())
    if DATABASE_URL:
        size = math.ceil(PG_POOL / WORKERS)
        app.state.pool = await asyncpg.create_pool(DATABASE_URL, min_size=size, max_size=size)
    yield
    task.cancel()
    if DATABASE_URL:
        await app.state.pool.close()


app = FastAPI(lifespan=lifespan, openapi_url=None, docs_url=None, redoc_url=None)


@app.exception_handler(StarletteHTTPException)
async def not_found(request: Request, exc: StarletteHTTPException):
    if exc.status_code == 404:
        return JSONResponse({"error": "not found"}, status_code=404)
    return await http_exception_handler(request, exc)


@app.get("/plaintext")
async def plaintext():
    return PlainTextResponse("Hello, World!")


@app.get("/json")
async def json_route():
    return {"message": "Hello, World!"}


@app.get("/users/{id}")
async def user(id: str):
    return PlainTextResponse(f"user {id}")


@app.get("/list")
async def list_items():
    return {
        "items": [
            {"id": i, "name": f"item-{i}", "active": i % 2 == 0, "score": i * 7}
            for i in range(1, 51)
        ]
    }


@app.post("/echo")
async def echo(request: Request):
    return Response(await request.body(), media_type="application/octet-stream")


@app.get("/gc/alloc")
async def gc_alloc(n: int = 2000):
    nodes = [
        {
            "id": i,
            "name": f"node-{i}",
            "tags": [f"a{i % 7}", f"b{i % 11}", f"c{i % 13}"],
            "active": i % 2 == 0,
        }
        for i in range(n)
    ]
    # The same json.dumps call Starlette's JSONResponse.render makes.
    body = json.dumps(nodes, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return {"n": n, "bytes": len(body)}


@app.get("/gc/stats")
async def gc_stats():
    return {"retained": len(retained)}


@app.websocket("/ws/echo")
async def ws_echo(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break
            if message.get("text") is not None:
                await websocket.send_text(message["text"])
            else:
                await websocket.send_bytes(message["bytes"])
    except WebSocketDisconnect:
        pass


@app.websocket("/ws/feed")
async def ws_feed(websocket: WebSocket):
    await feed.connect(websocket)
    try:
        # Client messages are ignored; this just waits for the close.
        while (await websocket.receive())["type"] != "websocket.disconnect":
            pass
    finally:
        feed.disconnect(websocket)


positions: dict[str, int] = {}  # one event loop per process: no lock needed


@app.websocket("/ws/trade")
async def ws_trade(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            order = await websocket.receive_json()
            qty = order["qty"]
            pos = positions.get(order["sym"], 0) + (qty if order["side"] == "buy" else -qty)
            positions[order["sym"]] = pos
            await websocket.send_json(
                {
                    "id": order["id"],
                    "status": "filled",
                    "px": order["px"],
                    "qty": qty,
                    "pos": pos,
                    "t": order["t"],
                }
            )
    except WebSocketDisconnect:
        pass


app.mount("/static", StaticFiles(directory=MEDIA_DIR), name="static")


# ---------------------------------------------------------------- $12 routes

if DATABASE_URL:
    started = time.monotonic()

    POST_SELECT = """SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id"""
    FEED_SQL = POST_SELECT + "\n ORDER BY p.created_at DESC, p.id DESC LIMIT 20"
    POST_SQL = POST_SELECT + "\n WHERE p.id = $1"
    INSERT_SQL = "INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at"
    LIKE_SQL = """WITH p AS (SELECT id FROM posts WHERE id = $2),
     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted"""

    POSITIVE_INT = re.compile(r"[1-9][0-9]*")

    class ApiError(Exception):
        def __init__(self, status: int, message: str):
            self.status = status
            self.message = message

    @app.exception_handler(ApiError)
    async def api_error(request: Request, exc: ApiError):
        return JSONResponse({"error": exc.message}, status_code=exc.status)

    @app.exception_handler(Exception)
    async def internal_error(request: Request, exc: Exception):
        return JSONResponse({"error": "internal server error"}, status_code=500)

    def post_json(row) -> dict:
        return {
            "id": row["id"],
            "body": row["body"],
            "created_at": row["created_at"],
            "author": row["username"],
            "like_count": row["like_count"],
        }

    def post_id(raw: str) -> int:
        if not POSITIVE_INT.fullmatch(raw):
            raise ApiError(400, "invalid post id")
        return int(raw)

    async def current_user(request: Request) -> tuple[int, str]:
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            raise ApiError(401, "missing bearer token")
        try:
            claims = jwt.decode(header[7:], JWT_SECRET, algorithms=["HS256"])
        except jwt.exceptions.InvalidSubjectError:  # validly signed, but `sub` isn't a string
            raise ApiError(401, "invalid token payload")
        except jwt.InvalidTokenError:
            raise ApiError(401, "invalid or expired token")
        sub, username = claims.get("sub"), claims.get("username")
        if not isinstance(sub, str) or not POSITIVE_INT.fullmatch(sub) or not isinstance(username, str):
            raise ApiError(401, "invalid token payload")
        return int(sub), username

    @app.get("/health")
    async def health(request: Request):
        try:
            await request.app.state.pool.fetchval("SELECT 1")
        except Exception as e:
            return JSONResponse(
                {"status": "degraded", "db": "unreachable", "error": str(e)}, status_code=503
            )
        return {"status": "ok", "db": "ok", "uptime_s": int(time.monotonic() - started)}

    @app.get("/feed")
    async def get_feed(request: Request):
        rows = await request.app.state.pool.fetch(FEED_SQL)
        return {"posts": [post_json(r) for r in rows]}

    @app.get("/posts/{id}")
    async def get_post(id: str, request: Request):
        row = await request.app.state.pool.fetchrow(POST_SQL, post_id(id))
        if row is None:
            raise ApiError(404, "post not found")
        return {"post": post_json(row)}

    @app.post("/posts", status_code=201)
    async def create_post(request: Request, user: tuple[int, str] = Depends(current_user)):
        try:
            payload = await request.json()
        except ValueError:
            raise ApiError(400, "malformed JSON body")
        body = payload.get("body") if isinstance(payload, dict) else None
        if not isinstance(body, str) or not (body := body.strip()):
            raise ApiError(400, "body is required")
        if len(body) > 500:
            raise ApiError(400, "body must be at most 500 characters")
        row = await request.app.state.pool.fetchrow(INSERT_SQL, user[0], body)
        return {
            "post": {
                "id": row["id"],
                "body": body,
                "created_at": row["created_at"],
                "author": user[1],
                "like_count": 0,
            }
        }

    @app.post("/posts/{id}/like")
    async def like_post(id: str, request: Request, user: tuple[int, str] = Depends(current_user)):
        pid = post_id(id)
        row = await request.app.state.pool.fetchrow(LIKE_SQL, user[0], pid)
        if row["found"] == 0:
            raise ApiError(404, "post not found")
        inserted = row["inserted"] == 1
        return JSONResponse(
            {"liked": True, "already_liked": not inserted, "post_id": pid},
            status_code=201 if inserted else 200,
        )
