#!/bin/bash
# Sharkbench web: Anole (v0.1.0) vs httpz, actix, hyper, fasthttp, drogon, with
# Sharkbench's own runner. Rested protocol: one unmeasured --validate pass per
# entry so every Docker build is cached (a cold Rust build heats the CPU),
# then 2 interleaved measured rounds with 70 s idle before each invocation.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
OUT=$S/shark; mkdir -p $OUT
cd /home/xuckl/Dev/ext/sharkbench
entries="zig/anole-0.1 zig/httpz-0.16 rust/actix-4-rust-1.98.1 rust/hyper-1-rust-1.98.1 go/fasthttp-1-go-1.20 cpp/drogon-1.9"
for e in $entries; do
  ./target/release/sharkbench --web --only $e --validate > $OUT/validate-${e//\//_}.log 2>&1
  echo "validate $e exit $?"
done
for i in 1 2; do for e in $entries; do
  sleep 70
  ./target/release/sharkbench --web --only $e > $OUT/run$i-${e//\//_}.log 2>&1
  echo "round $i $e exit $?: $(grep -o '\[Run #[0-9]*\]: t = [0-9]* ms, RAM = [0-9.]* MB, {[^}]*}' $OUT/run$i-${e//\//_}.log | sed -E 's/.*RAM = ([0-9.]+) MB, \{"rps_median": ([0-9]+).*"latency_median": ([0-9]+), "latency_p99": ([0-9]+), "errors": ([0-9]+).*/\2 rps p50 \3us p99 \4us \1MB err \5/' | tr '\n' ';')"
done; done
