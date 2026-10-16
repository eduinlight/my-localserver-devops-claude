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
   - TCP 2525/4465/5587/9993 → DNAT `10.8.0.3` (mail, see below)

## Mail (takuteku.com)

Traefik publishes **25, 465, 587, 993** as TCP entrypoints `smtp`, `submissions`, `submission`,
`imaps` (read timeout 0, for IMAP IDLE). The wg-easy labels route each with `HostSNI(*)` (no
TLS termination — Stalwart presents its own cert) to wg-easy ports 2525/4465/5587/9993 **with
PROXY protocol v2**, and the hook DNATs those into the tunnel. The in-cluster Traefik trusts
PROXY only from 10.8.0.1 and passes it on to Stalwart.

The HTTPS hosts (`mail`, `webmail`, `autoconfig`, `autodiscover`, `mta-sts`.takuteku.com) are
router `takuteku-mail` → service `k8s`, certificate from resolver **`letsencrypt-http`** —
HTTP-01, because the `letsencrypt` resolver's `AWS_HOSTED_ZONE_ID` pins it to eduindev.com.

There is no PTR requirement: nothing is sent from this IP, all outbound mail goes through SES.

`hooks.sql` has no sqlite3 on the VPS to run it — apply it with python:
`sudo python3 -c 'import sqlite3; c=sqlite3.connect("vpn/wg-easy/wg-easy.db"); c.executescript(open("/tmp/hooks.sql").read()); c.commit()'`
then recreate wg-easy. Backups of the pre-mail state: `/home/admin/backups/mail-20261016-120658/`.

**Restarting wg-easy is a ~1 minute public outage.** Traefik ignores a container until its
healthcheck reports `healthy`, and wg-easy spends about a minute in `starting` — every
`*.eduindev.com` host and the VPN UI return 404 until then.

Lightsail firewall: TCP 22/80/443/25/465/587/993, UDP 51820 (WireGuard) and 7000 (LiveKit).
TCP 7000 (old frps) was closed in Oct 2026. `aws lightsail put-instance-public-ports` replaces the
whole list — pass every port each time.
