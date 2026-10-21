#!/bin/sh
# Two Anole servers (src/main.zig): 8080 + 8081, and 8082 + 8443 (TCP and UDP).
# Exit when either does, so the container does not run on half its ports.
ROLE=h1 /anole-arena &
ROLE=h2 /anole-arena &
wait -n 2>/dev/null || wait
exit 1
