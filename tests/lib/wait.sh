# Waiting in the shell runners (MAINTAINING.md "Waiting in tests"), sourced:
#
#   . "$(dirname "$0")/../lib/wait.sh"
#   wait_until 60 "the broker to listen" port_open 127.0.0.1 9092
#
# A runner waits for the condition a fixed sleep stood for (a port that
# accepts, a log line, a process gone), polled with a short back-off, never
# for a fixed time. The limit is a hang guard, never a latency bound: SECONDS
# times ANOLE_TEST_TIMEOUT_FACTOR (a whole number, default 1; raise it on a
# crowded machine), counted on the clock, as src/testing/wait.zig does for the
# Zig tests. Prior art: testcontainers' wait strategies (a port, a log line
# "N times", a command that succeeds; each with a startup timeout).
#
# POSIX sh: the runners under /bin/sh (dash) source it too.

# The timeout factor, 1 when unset or not a whole number >= 1.
wait_factor() {
  _wf=${ANOLE_TEST_TIMEOUT_FACTOR:-1}
  case $_wf in
    '' | *[!0-9]* | 0) echo 1 ;;
    *) echo "$_wf" ;;
  esac
}

# wait_until SECONDS WHAT CMD [ARGS...]: runs CMD until it succeeds. Past
# SECONDS times the factor it looks once more, then prints "timed out after
# Ns waiting for: WHAT" on stderr and returns 1.
wait_until() {
  _wu_limit=$(($1 * $(wait_factor)))
  _wu_what=$2
  shift 2
  _wu_start=$(date +%s)
  _wu_delay=0.02
  while ! "$@"; do
    if [ $(($(date +%s) - _wu_start)) -ge "$_wu_limit" ]; then
      "$@" && return 0
      echo "timed out after ${_wu_limit}s waiting for: $_wu_what" >&2
      return 1
    fi
    sleep "$_wu_delay"
    case $_wu_delay in
      0.02) _wu_delay=0.05 ;;
      0.05) _wu_delay=0.1 ;;
      0.1) _wu_delay=0.2 ;;
    esac
  done
}

# port_open HOST PORT: a TCP connection to HOST:PORT is accepted (bash's
# /dev/tcp when there is one, else Python, which the /bin/sh runners need
# anyway).
port_open() {
  if [ -n "${BASH_VERSION:-}" ]; then
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
  else
    python3 -I -c 'import socket, sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1).close()' "$1" "$2" 2>/dev/null
  fi
}

# udp_bound PORT: a UDP socket is bound to PORT on this host (Linux: read
# from /proc/net/udp and udp6, where the local port is the hex after the
# address's colon).
udp_bound() {
  grep -qiE "^ *[0-9]+: [0-9A-F]+:$(printf '%04X' "$1") " /proc/net/udp /proc/net/udp6 2>/dev/null
}

# log_has FILE PATTERN [COUNT]: FILE has at least COUNT (default 1) lines
# matching the extended regular expression PATTERN.
log_has() {
  _lh_n=$(grep -cE -- "$2" "$1" 2>/dev/null) || true
  [ "${_lh_n:-0}" -ge "${3:-1}" ]
}

# docker_log_has NAME PATTERN [COUNT]: as log_has, on a container's log.
docker_log_has() {
  _dl_n=$(docker logs "$1" 2>&1 | grep -cE -- "$2") || true
  [ "${_dl_n:-0}" -ge "${3:-1}" ]
}

# gone PID: the process has exited.
gone() {
  ! kill -0 "$1" 2>/dev/null
}
