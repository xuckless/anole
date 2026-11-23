#!/usr/bin/env bash
# Gives the quic-interop-runner's empty.env a value for every variable its
# docker-compose.yml mounts or names. After a timed-out case the runner runs
# `docker compose --env-file empty.env stop`, and an empty one ("invalid spec:
# :/www:ro") makes that fail, so the old sim container stays up and the next
# case captures the wrong ports (CI only; upstream still has the bug).
#
#   tests/interop/empty-env.sh RUNNER_DIR COMMIT
#
# Regenerated from COMMIT each run, so running it twice gives the same file.
set -euo pipefail

runner=$1
commit=$2
vars=(SERVER CLIENT SERVER_WWW SERVER_DOWNLOADS CLIENT_WWW CLIENT_DOWNLOADS CERTS REQUESTS_SERVER REQUESTS_CLIENT)
pattern=$(printf '^%s=\\|' "${vars[@]}")
pattern=${pattern%\\|}
# Read first, so a failed show stops the script (set -e); only grep's
# no-match is tolerated.
base=$(git -C "$runner" show "$commit:empty.env")
{
  printf %s "$base" | grep -v "$pattern" || true
  # Names that stop never uses: any non-empty value (images need a valid name).
  for v in "${vars[@]}"; do
    case $v in
      SERVER | CLIENT) echo "$v=unused:latest" ;;
      *) echo "$v=/dev/null" ;;
    esac
  done
} >"$runner/empty.env.new"
mv "$runner/empty.env.new" "$runner/empty.env"
