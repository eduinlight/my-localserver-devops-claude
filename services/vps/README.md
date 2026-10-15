# Lightsail VPS (51.44.40.82)

Public edge for `*.eduindev.com`. Debian, Docker, AWS Lightsail `eu-west-3`.

- **SSH:** `ssh-my-lightsail` (zsh alias → `ssh -i ~/.ssh/my-lightsail-private-key.pem admin@51.44.40.82`)
- **Compose dirs on host:** `/home/admin/services/{traefik,vpn,portfolio}` — `traefik` and `vpn`
  are mirrored here (secrets live in each `.env`, see `.env.example`)
- **Backups from the frp cutover:** `/home/admin/backups/frp-cutover-*` (old frps dir, vpn compose, wg-easy db)

| Container | Role |
|-----------|------|
| `traefik` (v3.5) | TLS for everything, Let's Encrypt DNS-01 via Route53, docker label provider only |
| `wg-easy` (15.4.0) | WireGuard server `wg0` 10.8.0.1/24, UI at https://vpn.eduindev.com, and the forwarder into the cluster |
| `portfolio` | `eduindev.com` / `www` |

## WireGuard peers

| Peer | Who |
|------|-----|
| 10.8.0.2 | another client, not the cluster |
| 10.8.0.3 | **the k3s cluster** — Traefik pod, see `services/k8s-edge/` |

## How the cluster is reached

`wg-easy` carries the routing for the cluster, in two parts:

1. **Labels** (`vpn/docker-compose.yml`): router `k8s` =
   `HostRegexp(^.+\.eduindev\.com$)`, `websecure`, wildcard cert, **priority 10** (below
   `wg-easy`/`traefik` at 100 and `portfolio` at 50), service port **8000** on the wg-easy
   container. `$` is written `$$` in compose.
2. **PostUp hooks** in wg-easy's database (`hooks_table`, editable in Admin → Hooks), applied by
   `hooks.sql` here:
   - TCP 8000 arriving from Traefik → DNAT `10.8.0.3:8000`
   - UDP 7000 (published `7000:7000/udp`) → DNAT `10.8.0.3:7000` (LiveKit media)
   - MASQUERADE toward 10.8.0.3 so the cluster sees 10.8.0.1 and needs no route back

**Restarting wg-easy is a ~1 minute public outage.** Traefik ignores a container until its
healthcheck reports `healthy`, and wg-easy spends about a minute in `starting` — every
`*.eduindev.com` host and the VPN UI return 404 until then.

Lightsail firewall must keep **UDP 51820** (WireGuard) and **UDP 7000** (LiveKit) open, plus
TCP 80/443. TCP 7000 was frps's control port and is no longer used.
