#!/usr/bin/env bash
# Runs anole.kafka's live tests (`zig build test -Dkafka-test-url=...`) against
# a throwaway single-node broker in Docker: Apache Kafka (KRaft) or Redpanda.
#
#   tests/kafka/run.sh                              # apache/kafka:4.1.0 on port 59092
#   KAFKA_FLAVOR=redpanda tests/kafka/run.sh        # redpandadata/redpanda
#   KAFKA_IMAGE=apache/kafka:4.0.0 KAFKA_PORT=59093 tests/kafka/run.sh
#   tests/kafka/run.sh -Doptimize=ReleaseSafe       # extra zig build arguments
#
# Only the plain listener is exercised here; SASL SCRAM and TLS are covered by
# the fake broker's tests (a SASL + TLS listener for the live run is a
# follow-up).
#
# ANOLE_KEEP_CONTAINERS=1 leaves the containers when the script ends (CI
# collects their logs and states after a failure, then removes them).
set -euo pipefail

cd "$(dirname "$0")/../.."
. tests/lib/wait.sh
ZIG=${ZIG:-zig}
FLAVOR=${KAFKA_FLAVOR:-kafka}
PORT=${KAFKA_PORT:-59092}
NAME=anole-kafka-test-$$
trap '[ -n "${ANOLE_KEEP_CONTAINERS:-}" ] || docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

case "$FLAVOR" in
  kafka)
    IMAGE=${KAFKA_IMAGE:-apache/kafka:4.1.0}
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" \
      -e KAFKA_NODE_ID=1 \
      -e KAFKA_PROCESS_ROLES=broker,controller \
      -e KAFKA_LISTENERS="PLAINTEXT://:$PORT,CONTROLLER://:9093" \
      -e KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://127.0.0.1:$PORT" \
      -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
      -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
      -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT \
      -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
      -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
      -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
      -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
      -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
      "$IMAGE" >/dev/null
    ;;
  redpanda)
    IMAGE=${KAFKA_IMAGE:-redpandadata/redpanda:v25.2.1}
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:$PORT" "$IMAGE" \
      redpanda start --mode dev-container --smp 1 --memory 1G \
      --kafka-addr "internal://0.0.0.0:$PORT" \
      --advertise-kafka-addr "internal://127.0.0.1:$PORT" >/dev/null
    ;;
  *)
    echo "KAFKA_FLAVOR is kafka or redpanda" >&2
    exit 2
    ;;
esac

# The port opens before the broker is ready: wait for the line the broker
# logs once it serves (testcontainers' wait strategies for both images), a
# slow start (KRaft formats its log first) given up to two minutes.
case "$FLAVOR" in
  kafka) READY="Transitioning from RECOVERY to RUNNING" ;;
  redpanda) READY="Successfully started Redpanda!" ;;
esac
if ! wait_until 120 "the broker to start" docker_log_has "$NAME" "$READY" ||
  ! wait_until 30 "the broker to listen" port_open 127.0.0.1 "$PORT"; then
  docker logs "$NAME" 2>&1 | tail -30 >&2
  exit 1
fi
"$ZIG" build test -Dkafka-test-url="127.0.0.1:$PORT" "$@"
