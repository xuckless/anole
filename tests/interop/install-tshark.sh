#!/usr/bin/env bash
# Installs tshark for the interop runners on an Ubuntu CI runner (#54).
#
#   tests/interop/install-tshark.sh DEBS_DIR
#
# The runner reads its traces with pyshark and documents Wireshark 4.5.0 or
# newer; Ubuntu 24.04's own tshark is 4.2. So, in order:
#   1. the Wireshark nightly PPA (what the runner's own CI uses), retried;
#      the .deb files it downloads replace DEBS_DIR's, which CI keeps in
#      actions/cache;
#   2. when Launchpad is down: the .deb files of the last good install from
#      DEBS_DIR;
#   3. when there are none: Ubuntu's tshark, with a warning that it is older
#      than the runner asks for (version-dependent checks may then fail).
set -uo pipefail

debs=${1:?usage: install-tshark.sh DEBS_DIR}
ppa=ppa:wireshark-dev/nightly
mkdir -p "$debs"

# sudo drops the environment, so the front end is set on its command line.
apt() { sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

from_ppa() {
  local fresh
  fresh=$(mktemp -d)
  mkdir -p "$fresh/partial"
  sudo add-apt-repository -y "$ppa" &&
    apt update -qq &&
    apt install -y -qq --no-install-recommends -o "Dir::Cache::archives=$fresh" tshark || return 1
  # Keep what this install downloaded for the next outage.
  if ls "$fresh"/*.deb >/dev/null 2>&1; then
    rm -f "$debs"/*.deb
    cp "$fresh"/*.deb "$debs"/
  fi
}

drop_ppa() {
  sudo add-apt-repository -r -y "$ppa" >/dev/null 2>&1 || true
  apt update -qq || true
}

version_line() { tshark --version 2>/dev/null | head -1; }

installed=
for i in 1 2 3; do
  if from_ppa; then installed=ppa; break; fi
  echo "the Wireshark PPA failed (attempt $i)"
  sleep $((i * 15))
done

if [ -z "$installed" ] && ls "$debs"/*.deb >/dev/null 2>&1; then
  echo "::warning::the Wireshark PPA is unreachable; installing tshark from the cached packages of the last good install"
  drop_ppa
  if apt install -y -qq --no-install-recommends "$debs"/*.deb; then installed=cache; fi
fi

if [ -z "$installed" ]; then
  echo "::warning::the Wireshark PPA is unreachable and no cached packages exist; installing Ubuntu's own tshark, older than the 4.5.0 the interop runner documents"
  drop_ppa
  if apt install -y -qq --no-install-recommends tshark; then installed=distro; fi
fi

if [ -z "$installed" ]; then
  echo "::error::no tshark could be installed (PPA, cache and Ubuntu's archive all failed): an infrastructure failure, not a test failure"
  exit 1
fi
echo "tshark from the $installed: $(version_line)"
