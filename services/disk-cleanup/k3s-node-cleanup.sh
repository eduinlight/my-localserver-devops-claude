#!/bin/bash
set -uo pipefail

exec 9>/run/k3s-node-cleanup.lock
flock -n 9 || { echo "already running"; exit 0; }

used() { df --output=used -BG / | tail -1 | tr -dc '0-9'; }

before=$(used)
images_before=$(k3s crictl images -q 2>/dev/null | wc -l)

if ! k3s crictl --timeout 15m rmi --prune >/dev/null 2>&1; then
  echo "warning: image prune exited non-zero"
fi

sleep 30
images_after=$(k3s crictl images -q 2>/dev/null | wc -l)
after=$(used)
trimmed=$(fstrim -v / 2>&1 | awk '{print $2, $3}')

echo "images ${images_before} -> ${images_after}, used ${before}G -> ${after}G, trimmed ${trimmed}"
