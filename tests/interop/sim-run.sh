#!/bin/bash
# Adapted from quic-interop/quic-network-simulator, sim/run.sh (Apache-2.0,
# Copyright 2019 Jana Iyengar, Marten Seemann), the entrypoint of its image.
# Changed: the INT and TERM handlers wait for the children, so both dumpcaps
# flush their pcaps before the container exits (upstream's single `wait`
# returns at the signal and ends PID 1 first). Mounted over /ns3/run.sh by
# docker-compose.override.yml; CI only, never linked.

set -e

# We are using eth0 and eth1 as EmuFdNetDevices in ns3.
# Use promiscuous mode to allow ns3 to capture all packets.
ifconfig eth0 promisc
ifconfig eth1 promisc

# A packet arriving at eth0 destined to 10.100.0.0/16 could be routed directly to eth1,
# and a packet arriving at eth1 destined to 10.0.0.0/16 directly to eth0.
# This would allow packets to skip the ns3 simulator altogether.
# Drop those to make sure they actually take the path through ns3.
iptables -A FORWARD -i eth0 -o eth1 -j DROP
iptables -A FORWARD -i eth1 -o eth0 -j DROP
ip6tables -A FORWARD -i eth0 -o eth1 -j DROP
ip6tables -A FORWARD -i eth1 -o eth0 -j DROP

if [[ -n "$WAITFORSERVER" ]]; then
  wait-for-it-quic -t 10s $WAITFORSERVER
fi

echo "Using scenario:" $SCENARIO

dumpcap -i eth0 -s 0 -w "/logs/trace_node_left.pcap" &
dumpcap -i eth1 -s 0 -w "/logs/trace_node_right.pcap" &
eval ./scratch/"$SCENARIO &"

PID=`jobs -p | tr '\n' ' '`
trap "kill -SIGINT $PID; wait $PID" INT
trap "kill -SIGTERM $PID; wait $PID" TERM
trap "kill -SIGKILL $PID" KILL
wait
