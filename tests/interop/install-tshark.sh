#!/usr/bin/env bash
# Installs tshark for the interop runners on an Ubuntu CI runner (#54).
#
#   tests/interop/install-tshark.sh [--required] DEBS_DIR
#
# The runner reads its traces with pyshark and documents Wireshark 4.5.0 or
# newer; Ubuntu 24.04's own tshark is 4.2. So, in order:
#   1. the Wireshark nightly PPA (what the runner's own CI uses), retried;
#      the .deb files it downloads replace DEBS_DIR's, which CI keeps in
#      actions/cache;
#   2. when Launchpad is down: the .deb files of the last good install from
#      DEBS_DIR;
#   3. when there are none: no tshark. Ubuntu's own is too old for the
#      runner, and its checks would fail as if a test had failed. The script
#      writes `available=false` to $GITHUB_OUTPUT, so the interop steps are
#      skipped with a notice (an infrastructure failure reported as one);
#      with --required (release checks) it fails instead.
#
# Every network step is bounded (`timeout`, apt's Acquire timeouts), and a
# PPA attempt starts only while it and the fallback still fit in the CI
# step's 10 minutes: a Launchpad that hangs instead of answering costs one
# bounded attempt, not the step.
set -uo pipefail

required=
if [ "${1:-}" = --required ]; then required=1; shift; fi
debs=${1:?usage: install-tshark.sh [--required] DEBS_DIR}
out=${GITHUB_OUTPUT:-/dev/null}
ppa=ppa:wireshark-dev/nightly
mkdir -p "$debs"

# Seconds: each command's bound, and the budget the whole script keeps
# under the CI step's 600, with room for `timeout -k 5`. apt's stalled
# connections fail after 20 s instead of its default 120.
t_repo=45 t_update=75 t_install=120 budget=560
attempt_max=$((t_repo + t_update + t_install))
fallback_max=$((t_update + t_install))

# `bounded SECS CMD...` runs CMD as root for SECS seconds at most; timeout
# runs as root too, so its signals reach CMD. sudo drops the environment,
# so apt's front end is set through env.
bounded() { local secs=$1; shift; sudo timeout -k 5 "$secs" "$@"; }
apt() {
  local secs=$1; shift
  bounded "$secs" env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=0 "$@"
}

from_ppa() {
  local fresh
  fresh=$(mktemp -d)
  mkdir -p "$fresh/partial"
  # -n: no update of its own (the bounded one below).
  bounded $t_repo add-apt-repository -y -n "$ppa" &&
    apt $t_update update -qq &&
    apt $t_install install -y -qq --no-install-recommends -o "Dir::Cache::archives=$fresh" tshark || return 1
  # Keep what this install downloaded for the next outage.
  if ls "$fresh"/*.deb >/dev/null 2>&1; then
    rm -f "$debs"/*.deb
    cp "$fresh"/*.deb "$debs"/
  fi
}

drop_ppa() {
  sudo add-apt-repository -r -y -n "$ppa" >/dev/null 2>&1 || true
  apt $t_update update -qq || true
}

version_line() { tshark --version 2>/dev/null | head -1; }

installed=
for i in 1 2 3; do
  if [ $((SECONDS + attempt_max + fallback_max)) -gt $budget ]; then
    echo "no time left for another PPA attempt (${SECONDS} s used)"
    break
  fi
  if from_ppa; then installed=ppa; break; fi
  echo "the Wireshark PPA failed (attempt $i, ${SECONDS} s used)"
  [ $i -eq 3 ] || sleep $((i * 10))
done

if [ -z "$installed" ] && ls "$debs"/*.deb >/dev/null 2>&1; then
  echo "::warning::the Wireshark PPA is unreachable; installing tshark from the cached packages of the last good install"
  drop_ppa
  if apt $t_install install -y -qq --no-install-recommends "$debs"/*.deb; then installed=cache; fi
fi

if [ -z "$installed" ]; then
  if [ -n "$required" ]; then
    echo "::error::no tshark could be installed (the PPA failed and no cached packages exist): an infrastructure failure, not a test failure"
    exit 1
  fi
  echo "::warning::the Wireshark PPA is unreachable and no cached packages exist: the interop checks are skipped (Ubuntu's own tshark is older than the 4.5.0 the runner needs). An infrastructure failure, not a test failure; rerun once Launchpad is back."
  echo "available=false" >>"$out"
  exit 0
fi
echo "tshark from the $installed: $(version_line)"
echo "available=true" >>"$out"
