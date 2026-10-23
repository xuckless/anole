# {{name}}

A todo API on [Anole](https://github.com/xuckless/anole) and PostgreSQL.

```
docker compose up -d   # Postgres 17, with db/schema.sql applied on first start
zig build run          # http://localhost:3000, API docs at /docs
zig build test         # DATABASE_URL (from .env, or exported) enables the database tests
zig build openapi      # writes openapi.json; needs no database
```

`DATABASE_URL` is in `.env` (copied from `.env.example`, not committed). Anole
reads `.env` in development only; a release build reads the real environment.

- `src/main.zig`: the routes. Handlers take their input as a parameter and
  return their output; the title's rules (`field_rules`) become the 422 answer
  and the OpenAPI document's limits.
- A missing row is `error.NotFound` (404) and a duplicate title a unique
  violation (409): the database layer maps both.
- `/readyz` pings the database, `/healthz` only the process.

Release builds (`zig build -Doptimize=ReleaseSafe`) run in production mode;
see [the server guide](https://github.com/xuckless/anole/blob/main/docs/server.md)
for deploying.
