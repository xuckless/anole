# The key file (D19, research/s15/instructions-column.md §4.2): plain
# name=value lines in a fixed order, so `diff key.txt other/key.txt` shows
# whether two results directories are comparable. Values that need root are
# "unknown" unless `sudo -n` works.
#   . bench/lib/key.sh; write_key <file> <tools-image> <name>=<image>[,VAR=value...] ...
write_key() {
  local f=$1 tools=$2; shift 2
  local bench; bench=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  local c=/sys/devices/system/cpu
  local dirty=; git -C "$bench" diff --quiet HEAD -- . 2>/dev/null || dirty=-dirty
  local nft=unknown; sudo -n true 2>/dev/null && nft=$(sudo -n nft list ruleset | sha256sum | cut -d' ' -f1)
  {
    echo key_version=1
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "bench_ref=$(git -C "$bench" rev-parse HEAD)$dirty"
    echo "bench_app_ref=$(git -C "$bench" log -1 --format=%H -- servers/anole)"
    echo "script=${KEY_SCRIPT:-$0}"
    echo "kernel=$(uname -r)"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
    echo "microcode=$(grep -m1 microcode /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
    echo "smt=$(cat $c/smt/control 2>/dev/null)"
    echo "sut_cpus=$SUT_CPUS_1"
    echo "sut_siblings=$(cat $c/cpu$SUT_CPUS_1/topology/thread_siblings_list 2>/dev/null)"
    echo "load_cpus=$LOAD_CPUS"
    echo "governor=$(cat $c/cpu$SUT_CPUS_1/cpufreq/scaling_governor 2>/dev/null)"
    echo "epp=$(cat $c/cpu$SUT_CPUS_1/cpufreq/energy_performance_preference 2>/dev/null)"
    echo "no_turbo=$(cat $c/intel_pstate/no_turbo 2>/dev/null)"
    echo "nmi_watchdog=$(cat /proc/sys/kernel/nmi_watchdog)"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
    echo "user_slice_cpus=$(systemctl show user.slice -p AllowedCPUs --value 2>/dev/null)"
    echo "netfilter=$(lsmod | grep -q '^nf_conntrack ' && echo yes || echo no); nft_ruleset_sha256=$nft"
    echo "docker=$(docker version -f '{{.Server.Version}}')"
    echo "tools_image=$tools $(docker image inspect -f '{{.Id}}' "$tools")"
    echo "perf=$(docker run --rm --entrypoint perf "$tools" --version)"
    echo "h2load=$(docker run --rm --entrypoint h2load "$tools" --version | head -1)"
    echo "bpftrace=$(docker run --rm --entrypoint bpftrace "$tools" --version)"
    local spec n img
    for spec in "$@"; do
      n=${spec%%=*} img=${spec#*=}; img=${img%%,*}
      echo "side.$n.image=$img"
      echo "side.$n.image_id=$(docker image inspect -f '{{.Id}}' "$img")"
      echo "side.$n.binary_sha256=$(docker run --rm --entrypoint sha256sum "$img" /usr/local/bin/anole-bench | cut -d' ' -f1)"
      echo "side.$n.anole_ref=$(docker image inspect -f '{{index .Config.Labels "anole.ref"}}' "$img")"
      echo "side.$n.env=$([ "$spec" = "${spec#*,}" ] || echo "${spec#*,}")"
    done
  } >"$f"
}
