# The fixed CPU map (i7-14700F: P-core threads 0-15 as sibling pairs 2k,2k+1;
# E-cores 16-27). Sourced by every script and recorded in env.json.
# Override any of these in the environment for another machine.
#   SUT_CPUS_1  the 1-CPU tier: one P-core thread, its sibling left idle
#   SUT_CPUS_4  the 4-CPU tier: one thread on each of four P-cores, siblings idle
#   PG_CPUS     the shared Postgres
#   LOAD_CPUS   load generators and the orchestrator
: "${SUT_CPUS_1:=2}"
: "${SUT_CPUS_4:=0,2,4,6}"
: "${PG_CPUS:=16-19}"
: "${LOAD_CPUS:=8-15,20-27}"
