# {{name}}

A small JSON API on [Anole](https://github.com/xuckless/anole).

```
zig build run          # http://localhost:3000, API docs at /docs
zig build test         # tests, in memory
zig build openapi      # writes openapi.json from the routes' types
```

`src/main.zig` has the routes: handlers take their input as a parameter and
return their output, so Anole checks the input and the OpenAPI document is made
from the signatures. `src/main_test.zig` calls them through `anole.testing`,
with no socket.

Release builds (`zig build -Doptimize=ReleaseSafe`) run in production mode:
JSON logs, no docs page, no `.env`. See
[the server guide](https://github.com/xuckless/anole/blob/main/docs/server.md)
for deploying.
