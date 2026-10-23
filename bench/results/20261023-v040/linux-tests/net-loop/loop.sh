#!/bin/sh
# loop.sh <loops> <runs per loop> <binary>: parallel loops; failures keep their full log.
L=$1 N=$2 B=$3
for l in $(seq $L); do
  (for i in $(seq $N); do
     t0=$(date +%s.%N)
     timeout 300 $B > /out/run-$l-$i.log 2>&1; rc=$?
     t1=$(date +%s.%N)
     d=$(awk "BEGIN{printf \"%.2f\", $t1 - $t0}")
     if [ $rc = 0 ]; then rm -f /out/run-$l-$i.log; echo "$l $i ok $d" >> /out/times.txt
     else echo "$l $i FAIL rc=$rc $d" >> /out/times.txt; fi
   done) &
done
wait
echo "runs $(wc -l < /out/times.txt) fails $(grep -c FAIL /out/times.txt)"
