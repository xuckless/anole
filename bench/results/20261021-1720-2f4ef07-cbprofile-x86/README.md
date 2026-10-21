# Callback vs loop WebSockets on x86: profiles (req-mem 2f4ef07)

anole-bench/anole:b (req-mem 2f4ef07), 1 CPU (cpu 2), epoll, gcannon 11c802b `--ws -t 16 -p 16`.
perf 7.2.11 ran from a throwaway privileged container (scripts/Dockerfile.perf) on cpus 16-19.

- c16384-echo, c16384-echo-cb: fresh server each; perf stat (8-12 s into a 15 s run),
  memory.stat at 8 s and 12 s; perf record on a second fresh server (scripts/profile-cb.sh).
  /proc/PID/io wchar does not count socket sends, so frames/s is gcannon's over the whole run.
- c512-*: fresh server, memory every second (carry-over check).
- sequence/: fresh server, then 16384 / 4096,16384 / 512,4096,16384 with 3 s gaps (scripts/seq-cb.sh).
- warmup/: a 5 s run then the 15 s run at the same count, gap 0 or 5 s, as the suite's warm-up does (scripts/warm-cb.sh).
- warmup-profile/: perf stat/record of that second run and memory afterwards (scripts/warm-prof.sh).
- close-check/: server fds and TCP states 15 s after a 5 s 16384-connection run.
