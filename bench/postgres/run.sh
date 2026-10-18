#!/bin/sh
# The shared Postgres for the $12 benchmark, and its seed database.
#   bench/postgres/run.sh start   # start (seeding on first use: ~2 min)
#   bench/postgres/run.sh reset   # fresh "run" database from the "seed" template
#   bench/postgres/run.sh stop
# Postgres listens on 127.0.0.1:5432 (host network), trust auth for user
# "bench", pinned to the cpuset in bench/lib/cpus.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bench=$(dirname "$here")
. "$bench/lib/cpus.sh"
name=anole-bench-pg
image=postgres:18.0-alpine3.22
data=$bench/.data

psql() { docker exec -i "$name" psql -v ON_ERROR_STOP=1 -q -U bench "$@"; }

wait_ready() {
  for _ in $(seq 120); do
    docker exec "$name" pg_isready -q -h 127.0.0.1 -U bench 2>/dev/null && return 0
    sleep 0.5
  done
  echo "postgres did not come up" >&2; docker logs --tail 50 "$name" >&2; exit 1
}

seed() {
  mkdir -p "$data/seed"
  if [ ! -f "$data/seed/posts.tsv" ]; then
    docker run --rm -v "$bench/twelve:/twelve:ro,z" -v "$data/seed:/out:z" -u "$(id -u):$(id -g)" \
      node:24.11-alpine node /twelve/generate.mjs /out
  fi
  psql -d postgres -c "DROP DATABASE IF EXISTS seed" -c "CREATE DATABASE seed"
  psql -d seed <"$here/schema.pg.sql"
  # QUOTE as a byte that never appears, so fields load verbatim.
  for t in users posts likes; do
    psql -d seed -c "\\copy $t FROM '/seed/$t.tsv' WITH (FORMAT csv, DELIMITER E'\\t', QUOTE E'\\x01')"
  done
  psql -d seed <"$here/indexes.pg.sql"
  psql -d postgres -c "VACUUM" >/dev/null
  psql -d seed -c "VACUUM (ANALYZE)"
  psql -d postgres -c "UPDATE pg_database SET datistemplate = true WHERE datname = 'seed'"
}

case "${1:-start}" in
start)
  mkdir -p "$data/seed"
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network host \
      --cpuset-cpus "$PG_CPUS" --memory 4g --memory-swap 4g --shm-size 1g \
      -e POSTGRES_USER=bench -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=postgres \
      -e POSTGRES_INITDB_ARGS="--locale=C --encoding=UTF8" \
      -v anole-bench-pgdata:/var/lib/postgresql \
      -v "$here/postgresql.conf:/etc/postgresql/postgresql.conf:ro,z" \
      -v "$data/seed:/seed:ro,z" \
      "$image" -c config_file=/etc/postgresql/postgresql.conf >/dev/null
  fi
  wait_ready
  if [ "$(psql -d postgres -tA -c "SELECT count(*) FROM pg_database WHERE datname='seed' AND datistemplate")" != 1 ]; then
    seed
  fi
  ;;
reset)
  psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'run'" >/dev/null
  psql -d postgres -c "DROP DATABASE IF EXISTS run" -c "CREATE DATABASE run TEMPLATE seed"
  ;;
stop) docker rm -f "$name" >/dev/null ;;
*) echo "usage: $0 start|reset|stop" >&2; exit 2 ;;
esac
