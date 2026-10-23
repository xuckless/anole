#!/bin/sh
# loop.sh <loops> <runs per loop>: parallel loops of the test binary; failures keep their full log.
L=$1 N=$2
for l in $(seq $L); do
  (for i in $(seq $N); do
     t0=$(date +%s.%N)
     timeout 90 anole-test > /out/run-$l-$i.log 2>&1; rc=$?
     t1=$(date +%s.%N)
     if [ $rc = 0 ]; then rm -f /out/run-$l-$i.log; echo "$l $i ok $(awk "BEGIN{printf \"%.2f\", $t1 - $t0}")" >> /out/times.txt
     else echo "$l $i FAIL rc=$rc $(awk "BEGIN{printf \"%.2f\", $t1 - $t0}")" >> /out/times.txt; fi
   done) &
done
wait
echo "runs $(wc -l < /out/times.txt) fails $(grep -c FAIL /out/times.txt)"
