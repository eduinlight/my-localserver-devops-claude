# Disk cleanup timers

Scheduled cleanup added after the `local-lvm` thin pool hit 100% on 2026-10-25.
Both run three times a day (times in UTC), nice'd and at idle I/O priority.

| Where | Unit | When (UTC) | Does |
|-------|------|------------|------|
| every k3s node (.60–.63) | `k3s-node-cleanup.timer` | 02:15, 10:15, 18:15 (+0–10 min) | `crictl --timeout 15m rmi --prune`, then `fstrim /` |
| PVE host | `pve-guest-trim.timer` | 02:45, 10:45, 18:45 | `pct fstrim` every running LXC, logs the pool % |

The k3s VMs have `discard=on`, so the node's own `fstrim` hands blocks back to the pool.
Most LXCs do not, which is what the host job covers. `pct fstrim` skips bind mounts,
so the 8 TB media disk is never touched.

The `--timeout 15m` matters: with the default timeout, a prune on a busy disk aborts with
`context canceled` and leaves half-deleted layers behind, which is how each node had piled
up ~100 GB.

## Install

```sh
for ip in 60 61 62 63; do
  scp k3s-node-cleanup.{sh,service,timer} admin@192.168.0.$ip:/tmp/
  ssh admin@192.168.0.$ip 'sudo install -m 0755 /tmp/k3s-node-cleanup.sh /usr/local/sbin/k3s-node-cleanup &&
    sudo install -m 0644 /tmp/k3s-node-cleanup.{service,timer} /etc/systemd/system/ &&
    sudo systemctl daemon-reload && sudo systemctl enable --now k3s-node-cleanup.timer'
done

scp pve-guest-trim.{sh,service,timer} root@192.168.0.15:/tmp/
ssh root@192.168.0.15 'install -m 0755 /tmp/pve-guest-trim.sh /usr/local/sbin/pve-guest-trim &&
  install -m 0644 /tmp/pve-guest-trim.{service,timer} /etc/systemd/system/ &&
  systemctl daemon-reload && systemctl enable --now pve-guest-trim.timer'
```

## Check

```sh
ssh admin@192.168.0.61 'journalctl -u k3s-node-cleanup -n 5 -o cat'
ssh root@192.168.0.15 'journalctl -u pve-guest-trim -n 5 -o cat'
ssh root@192.168.0.15 'journalctl -t pve-guest-trim -p err'
```

The host job writes an `ALERT` line at priority `err` when the pool is at 90% or more.
Nothing pages on it yet.

The macOS runners (VMs 126/127) are not covered: their disks have no `discard` and macOS
does not TRIM them, so nothing scheduled can reclaim their space.
