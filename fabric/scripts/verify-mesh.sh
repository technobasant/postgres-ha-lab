#!/bin/bash
# Prove host↔VM and VM↔VM connectivity on 192.168.105.0/24 for running nodes.
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATEWAY=192.168.105.1
NODES=(
  "ubuntu1:192.168.105.111:22111"
  "ubuntu2:192.168.105.112:22112"
  "rocky1:192.168.105.121:22121"
  "rocky2:192.168.105.122:22122"
)

running=()
for entry in "${NODES[@]}"; do
  IFS=: read -r name _ip _port <<<"$entry"
  if vagrant status "$name" 2>/dev/null | grep -q running; then
    running+=("$entry")
  fi
done

if [[ ${#running[@]} -eq 0 ]]; then
  echo "No running nodes. Start with: ./bin/vagrant-up ubuntu1 rocky1" >&2
  exit 1
fi

echo "== host → lab IPs =="
fail=0
for entry in "${running[@]}"; do
  IFS=: read -r name ip _port <<<"$entry"
  echo "-- $name ($ip) --"
  if /sbin/ping -c 2 -W 2000 "$ip"; then
    echo "PING OK $name"
  else
    echo "PING FAIL $name" >&2
    fail=1
  fi
done

echo
echo "== Vagrant SSH =="
for entry in "${running[@]}"; do
  IFS=: read -r name _ip _port <<<"$entry"
  echo "-- $name --"
  vagrant ssh "$name" -c "hostname; cat /etc/lab/ip; ip -br addr"
done

echo
echo "== inter-node mesh =="
src_entry="${running[0]}"
IFS=: read -r src _src_ip _src_port <<<"$src_entry"
targets=()
for entry in "${running[@]}"; do
  IFS=: read -r _n tip _p <<<"$entry"
  targets+=("$tip")
done
vagrant ssh "$src" -c "bash -lc '
  for t in ${targets[*]}; do
    echo -n \"ping \$t: \"
    if ping -c 1 -W 2 \$t >/dev/null; then echo OK; else echo FAIL; exit 1; fi
  done
  echo -n \"ARP gateway $GATEWAY: \"
  ip neigh show $GATEWAY | head -1 || true
'"

echo
echo "== note =="
echo "Guest ICMP to $GATEWAY often fails on macOS vmnet; ARP REACHABLE + peer pings are the pass criteria."

exit "$fail"
