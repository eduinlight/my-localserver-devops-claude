#!/bin/bash
set -uo pipefail

exec 9>/run/pve-guest-trim.lock
flock -n 9 || { echo "already running"; exit 0; }

pool() { lvs --noheadings -o data_percent pve/data | tr -d ' '; }

before=$(pool)

for c in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
  timeout 20m pct fstrim "$c" >/dev/null 2>&1 || echo "warning: fstrim failed on LXC $c"
done

after=$(pool)
echo "thin pool ${before}% -> ${after}%"

awk -v p="$after" 'BEGIN {exit !(p >= 90)}' && echo "ALERT: thin pool at ${after}%" | systemd-cat -t pve-guest-trim -p err
exit 0
