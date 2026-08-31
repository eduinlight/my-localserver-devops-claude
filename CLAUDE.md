# Local Server DevOps

## Proxmox Server

- **IP:** 192.168.0.15
- **SSH:** `ssh root@192.168.0.15` (this host is in Proxmox allowed hosts)
- **Claude has full control** of all containers and VMs via Proxmox CLI (pct, qm, pvesm, etc.)
- **Version:** PVE 8.4.14, kernel 6.8.12-16-pve
- **Standalone node** (no cluster)

### Hardware

- **CPU:** Intel Core Ultra 7 265K (20 cores, no hyperthreading)
- **RAM:** 64 GB
- **GPU:** NVIDIA GeForce RTX 3050 6GB + Intel Arc integrated
- **Disks:**
  - `nvme0n1` — 1.8 TB NVMe (boot, root, LVM-thin for VMs)
  - `sda` — 8 TB SATA HDD (Seagate ST8000NT001, 7200 rpm CMR) — the media library,
    ext4 at `/mnt/media-8tb` on the host, bind-mounted into LXC 104 as `/mnt/media/data`
- **No ZFS pools**

### Storage

| Name | Type | Total | Used | Available | % |
|------|------|-------|------|-----------|---|
| local | dir | ~94 GB | ~60 GB | ~30 GB | 63.4% |
| local-lvm | lvmthin | ~1.7 TB | ~882 GB | ~828 GB | ~51.6% |
| /mnt/media-8tb | ext4 (host mount, not PVE storage) | 7.3 TiB | 690 GB | 6.7 TiB | 10% |

**`local-lvm` is thin-overcommitted** — provisioned volumes sum to ~2.98 TB against a
1.71 TB pool. It sat at 92% until Aug 2026, when moving the 690 GB media library to the
new 8 TB HDD (and dropping an empty orphan volume) brought it back to ~52%. If
`data_percent` reaches 100% every guest on it starts throwing I/O errors and thin
metadata can corrupt. Check with
`lvs --units g -o lv_name,lv_size,data_percent pve/data`.

Guests do not return freed blocks to the pool on their own unless the volume has
`discard=on` (the k3s/swarm VMs do; most LXCs and VMs 102/115/119/123 do not).
A periodic trim recovers a surprising amount — this reclaimed ~147 GB in Aug 2026:

```sh
for c in $(pct list | awk 'NR>1 {print $1}'); do pct fstrim $c; done   # on the PVE host
ssh admin@192.168.0.6X 'sudo fstrim -av'                               # VMs with discard=on
```

The VM half must be run **from the dev box**, not the PVE host — the `admin` SSH
key lives on the dev box and the host cannot authenticate to the VMs.

Consolidating the AI pool in Aug 2026 (three LXCs → one) took the pool from 97.4%
back to ~92%, mostly by destroying LXC 117, which held ~70 GB of dead Fooocus and
forge trees plus two duplicate 7 GB copies of the same SDXL checkpoint.

Templates 101/112 fail with `Read-only file system` — expected, harmless.

**RAM is the other tight resource.** 62 GB total; VM memory is *reserved* while LXC
memory is only a *cap*. Running VMs reserve ~38 GB and LXC 105 (gitlab) alone holds
~15 GB, so the host sits near capacity and swap stays full. Check real usage before
adding or growing a VM:

```sh
free -g; for c in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
  pct exec $c -- free -m 2>/dev/null | awk -v c=$c '/Mem:/ {print c, $3" MB"}'; done
```

### Networking

- **Bridge:** vmbr0 on enp129s0 — 192.168.0.15/24, gateway 192.168.0.1
- **WiFi:** wlp130s0f0 — link up, no IP (was 192.168.0.5/24, removed to resolve conflict with s3 LXC)

### LXC Containers

| VMID | Name | Status | IP | RAM | Cores | Disk |
|------|------|--------|-----|-----|-------|------|
| 100 | s3 | running | 192.168.0.5 | 512 MB | 1 | 8 GB |
| 101 | docker | **TEMPLATE** | — | 512 MB | 1 | — |
| 103 | docker-registry | running | 192.168.0.27 | 2 GB | 4 | 100 GB |
| 104 | media | running | 192.168.0.22 | 8 GB | 4 | 40+812 GB + 8 TB HDD |
| 105 | gitlab | running | 192.168.0.23 | 16 GB | 16 | 200 GB |
| 106 | gitlab-runner-docker | running | 192.168.0.24 | 8 GB | 8 | 100 GB |
| 107 | gitlab-runner-shell | running | 192.168.0.25 | 1 GB | 8 | 20 GB |
| 108 | immich | running | 192.168.0.26 | 8 GB | 4 | 208 GB |
| 109 | vaultwarden | running | 192.168.0.29 | 2 GB | 2 | 16 GB |
| 111 | dns | running | 192.168.0.21 | 512 MB | 8 | 8 GB |
| 112 | debian | **TEMPLATE** | — | 512 MB | 8 | — |
| 114 | traefik | running | 192.168.0.7 | 512 MB | 1 | 8 GB |
| 118 | ai | running | 192.168.0.118 | 24 GB | 12 | 200 GB |
| 120 | calibre-web | running | 192.168.0.120 | 2 GB | 2 | 100 GB |
| 122 | lgtm | running | 192.168.0.122 | 8 GB | 4 | 40 GB |
| 124 | github-runner | running | 192.168.0.28 | 8 GB | 4 | 100 GB |

### Virtual Machines

| VMID | Name | Status | IP | RAM | Cores | Disks | Pool |
|------|------|--------|-----|-----|-------|-------|------|
| 102 | work-ubuntu-01 | stopped | — | 8 GB | 2 | 100 GB | work |
| 115 | win11 | **TEMPLATE** | — | 4 GB | 4 | 100 GB (+2 unused) | — |
| 119 | work-ubuntu-02 | stopped | — | 8 GB | 2 | 100 GB | work |
| 123 | ubuntu | **TEMPLATE** | — | 8 GB | 2 | 100 GB | work |
| 125 | gh-runner-windows | running | 192.168.0.244 | 8 GB (balloon 4) | 8 | 150 GB | github |
| 126 | mac-runner | running | 192.168.0.245 | 8 GB | 4 | 80 GB | github |
| 200 | k3s-cp-01 | running | 192.168.0.60 | 4 GB | 2 | 40 GB | kubernete |
| 201 | k3s-w-01 | running | 192.168.0.61 | 6 GB | 2 | 60 GB | kubernete |
| 202 | k3s-w-02 | running | 192.168.0.62 | 6 GB | 2 | 60 GB | kubernete |
| 210 | swarm-mgr-01 | running | 192.168.0.65 | 2 GB | 2 | 90 GB | docker |
| 211 | swarm-w-01 | running | 192.168.0.66 | 6 GB | 4 | 60 GB | docker |
| 212 | swarm-w-02 | running | 192.168.0.67 | 6 GB | 4 | 60 GB | docker |
| 9000 | k3s-template | **TEMPLATE** | — | 2 GB | 2 | 3 GB (cloud-init) | kubernete |

### Resource Pools

| Pool | Comment | Members |
|------|---------|---------|
| docker | Docker services | 103, 210, 211, 212 |
| github | GitHub CI services | 124, 125, 126 |
| gitlab | GitLab services | 105, 106, 107 |
| ia | AI/ML services | 118 |
| kubernete | k3s cluster + template | 200, 201, 202, 9000 |
| tools | Tools and apps | 100, 104, 108, 109, 114, 120, 122 |
| work | Work VMs and ubuntu template | 102, 119, 123 |

Add a guest to a pool with `pvesh set /pools/<name> --vms <vmid>` (`pct set --pool` is not valid).

### Templates

- **LXC 101 (docker)** — Template for services that run via Docker/docker-compose inside an LXC.
- **LXC 112 (debian)** — Template for services that run natively via systemd (no Docker).
- **VM 9000 (k3s-template)** — Debian 13 cloud-init template with `admin` user pre-baked (NOPASSWD sudo, dev box SSH key; password in `secrets.local.md`, untracked). Use this for any new VM clone (k3s, swarm, anything Debian-based). **Do not pass `--ciuser`/`--cipassword` on `qm clone`** — values are baked into the image.
- **VM 123 (ubuntu)** — Older Ubuntu Server template (no cloud-init). Kept for compatibility; prefer 9000 for new builds.

### Proxmox Pools

- **kubernete** — k3s cluster (VMs 200/201/202) + the cloud-init template (9000).
- **docker** — Docker registry LXC (103) + new Swarm (VMs 210/211/212).

When deploying a new service, clone the appropriate template based on whether the service needs Docker (101) or can run with systemd (112) — or use VM template 9000 for a full-VM workload.

### Key Services

- **CI/CD:** GitLab (105) + 2 runners (106 docker, 107 shell) + Docker Registry (103) + GitHub Actions runners — Linux LXC 124, Windows VM 125 (`services/gh-runner-windows/`), macOS VM 126 (`services/gh-runner-macos/`, hackintosh via OpenCore)
- **Kubernetes:** k3s cluster — cp (200) + 2 workers (201, 202), ArgoCD + dashboard in-cluster
- **AI/ML:** single GPU LXC 118 `ai` — llama.cpp via llama-swap (text + embeddings) and ComfyUI (images), see "## AI Stack" below and `services/ai/`
- **Media:** Media server (104 — library on the 8 TB HDD, see `services/media/`), Immich photos (108), Calibre-web (120)
- **Infra:** DNS (111), Traefik reverse proxy (114), S3 (100)
- **Secrets:** Vaultwarden (109) at https://secrets.lan — see "## Vaultwarden" below and `services/vaultwarden/`
- **Observability:** LGTM stack (122) — Grafana/Loki/Tempo/Prometheus/Pyroscope + OTel Collector, see "## LGTM Observability Stack" below
- **Docker Swarm (VMs):** Manager 210 (192.168.0.65) + workers 211/212 — see "## Docker Swarm" section below.
- **Kubernetes (k3s, VMs):** Control-plane 200 (192.168.0.60) + workers 201/202 — see "## k3s Cluster" section below.

---

## Media Library Storage (8 TB HDD → LXC 104)

The Jellyfin/arr library lives on the **8 TB SATA disk**, not on `local-lvm`. Moved there
Aug 2026 — it was 690 GB in an 812 GB thin volume at 91% full, and it was most of what was
keeping the thin pool at 92%. Full detail in `services/media/README.md`.

- Host: `/dev/sda1` ext4, mounted at `/mnt/media-8tb` (fstab by UUID, `noatime,nofail`)
- Container: `mp2: /mnt/media-8tb,mp=/mnt/media/data` in `/etc/pve/lxc/104.conf`
- App configs stay on the NVMe volume (`mp1` → `/mnt/media`) — they are SQLite and belong
  on flash. `mp2` is a **nested** mount under `mp1`; the more specific mount wins, so the
  compose file needed no changes at all.

Three things to know before touching this tree again:

- **Hardlinks are load-bearing.** Sonarr/Radarr import by hardlinking from `downloads`
  into `movies`/`shows`, so those three directories must stay on one filesystem. 350 of
  789 files are hardlinked — 1.15 TB apparent, 690 GB real. Any move needs
  `rsync -aHAX --numeric-ids`; **`-H` is not optional** and `--numeric-ids` is what keeps
  the unprivileged idmap (offset 100000) intact, since the host has no user for UID 101000.
- **A host bind mount is not idmapped for you.** `chown 100000:100000` the host directory
  or the container sees `nobody:nogroup` — which is exactly the state the older
  `mp0: /mnt/usb` bind mount is in.
- **`mkfs.ext4 -m 0 -T largefile`** on a bulk data disk. The defaults cost ~400 GB to the
  root block reserve and ~120 GB to an inode table sized for 500 M small files.

Verify a move by comparing apparent bytes and the nlink>1 count on **both** sides — `du`
dedupes hardlinks, so matching `du` output does not prove the links survived:

```sh
find <tree> -type f -printf '%s\n' | awk '{s+=$1} END {print s}'   # must match exactly
find <tree> -type f -links +1 | wc -l                              # must match exactly
```

Reclaiming freed thin-pool space needs a trim, since deleting files inside a guest does
not return blocks to the pool (`mp1` has `discard=on`): `pct fstrim 104`.

**A pre-start hookscript guards the boot race.** The fstab entry is `nofail` and
`pve-guests.service` has no `local-fs` ordering, so a cold boot could otherwise start
LXC 104 (`onboot: 1`) before the disk mounts, bind-mount the bare empty directory, and
let Sonarr/Radarr mark the whole library missing. `local:snippets/media-mount-guard.pl`
fails closed if `/mnt/media-8tb` is unmounted *or* mounted-but-empty; the fstab entry
also carries `x-systemd.before=pve-guests.service`. `nofail` stays on purpose — a dead
disk should still let every other guest boot. Script and rationale in `services/media/`.

---

## DNS Service (VMID 111)

- **IP:** 192.168.0.21
- **Software:** BIND9
- **Access:** `ssh root@192.168.0.15` then `pct exec 111 -- bash -c '...'`
- **Config:** `/etc/bind/named.conf.local`
- **Zone files:** `/etc/bind/zones/db.<zone>.lan`

### DNS Zones

| Zone | A Record | Target | Notes |
|------|----------|--------|-------|
| ai.lan | `@`, `images` | 192.168.0.7 | Traefik → LXC 118. `fooocus`/`api.images` removed Aug 2026 |
| books.lan | `@` | 192.168.0.7 | Traefik |
| dns.lan | `@` | 192.168.0.21 | Direct |
| docker.lan | `@` → .27, `registry` → .7, `mirror` → .7 | mixed | Apex direct to registry LXC, `registry`/`mirror` via Traefik (mirror = Docker Hub pull-through cache) |
| git.lan | `@` | 192.168.0.23 | Direct to GitLab |
| gitlab.lan | `@` | 192.168.0.7 | Traefik (port 8929) |
| grafana.lan | `@` → .7 (Traefik); `otlp`, `loki`, `tempo`, `prom` → 192.168.0.122 | mixed | UI via Traefik, ingest/component APIs direct to LGTM LXC |
| immich.lan | `@` | 192.168.0.26 | Direct |
| k3s.lan | `@`, `cp`, `api` → .60, `w1` → .61, `w2` → .62 | direct | Cluster nodes |
| k3s.lan | `dashboard`, `argocd` | 192.168.0.7 | Traefik → NodePort |
| mail.lan | `@` | 192.168.0.6 | ⚠️ **ORPHANED** — target host is gone. Zone still has full mail records (DKIM, SPF, DMARC, SRV); kept in case mail is rebuilt |
| media.lan | `@`, `request`, `radar`, `sonar`, `qbittorrent` | 192.168.0.7 | Traefik, subdomains are CNAMEs |
| openclaw.lan | `@` | 192.168.0.7 | ⚠️ **ORPHANED** — LXC 116 removed Aug 2026; resolves to Traefik, which 502s |
| planer.lan | `@` | 192.168.0.7 | ⚠️ **ORPHANED** — LXC 121 removed Aug 2026; resolves to Traefik, which 502s |
| proxmox.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS, insecureSkipVerify to PVE:8006) |
| s3.lan | `@` + `*` (wildcard) | 192.168.0.5 | Direct |
| secrets.lan | `@` | 192.168.0.7 | Traefik (HTTPS only, self-signed; HTTP 301s to HTTPS) |

---

## Traefik Reverse Proxy (VMID 114)

- **IP:** 192.168.0.7
- **Software:** Traefik v3.1 (Docker via docker-compose)
- **Access:** `ssh root@192.168.0.15` then `pct exec 114 -- bash -c '...'`
- **Compose file:** `/home/admin/docker-compose.yaml`
- **Route configs:** `/home/admin/config/*.yml` (mounted as `/etc/traefik/config/`)
- **Certs:** `/home/admin/certs/`
- **Dashboard:** port 8080 (api.insecure=true)
- **Entrypoints:** `web` (:80), `websecure` (:443)

### Traefik Routes

| Config File | Host | Backend | Port | TLS |
|-------------|------|---------|------|-----|
| webui.yml | ai.lan | 192.168.0.118 (llama-swap) | 8080 | no |
| images.yml | images.ai.lan | 192.168.0.118 (ComfyUI) | 8188 | no |
| books.yml | books.lan | 192.168.0.120 (calibre-web) | 8083 | no |
| gitlab.yml | gitlab.lan | 192.168.0.23 (gitlab) | 8929 | no |
| grafana.yml | grafana.lan | 192.168.0.122 (lgtm) | 3000 | no |
| media.yml | media.lan | 192.168.0.22 (media) | 8096 | no |
| radar.yml | radar.media.lan | 192.168.0.22 | 7878 | no |
| sonar.yml | sonar.media.lan | 192.168.0.22 | 8989 | no |
| qbittorrent.yml | qbittorrent.media.lan | 192.168.0.22 | 8080 | no |
| seer.yml | request.media.lan | 192.168.0.22 | 5055 | no |
| openclaw.yml | openclaw.lan | 192.168.0.55 — ⚠️ **DEAD** | 18789 | yes |
| planer.yml | planer.lan | 192.168.0.121 — ⚠️ **DEAD** | 80 | no |
| proxmox.yml | proxmox.lan | 192.168.0.15 (PVE) | 8006 | yes |
| secrets.yml | secrets.lan | 192.168.0.29 (vaultwarden) | 8080 | yes (plus a `web` router that redirects to HTTPS) |
| registry.yml | registry.docker.lan | 192.168.0.27 (registry) | 5000 | no |
| mirror.yml | mirror.docker.lan | 192.168.0.27 (registry-mirror) | 5001 | no |
| dashboard.yml | dashboard.k3s.lan | 192.168.0.60 (k3s cp NodePort) | 30443 | yes (HTTPS frontend, HTTPS backend with insecureSkipVerify via `dashboardTransport` defined inline) |
| argocd.yml | argocd.k3s.lan | 192.168.0.60 (k3s-cp-01 NodePort) | 30080 | no |
| tls.yml | — | — | — | cert config for openclaw.lan, proxmox.lan, registry.docker.lan, dashboard.k3s.lan, secrets.lan |
| transports.yml | — | — | — | proxmoxTransport (insecureSkipVerify) |
| k3s-dashboard.yml | dashboard.k3s.lan | 192.168.0.60 | 30443 | ⚠️ duplicates `dashboard.yml` — same Host rule, two routers |
| spice.yml | — (`HostSNI(*)`) | — | — | TCP passthrough, undocumented |

⚠️ `openclaw.yml` and `planer.yml` point at removed containers. Traefik keeps serving
the routers, so those hosts return 502 rather than NXDOMAIN. Delete the route files
and the matching DNS zones if those services are not coming back.

---

## Docker Registry & Mirror (VMID 103)

Two `registry:2` containers run side-by-side on LXC 103 from `/home/admin/docker-compose.yaml`:

| Service | Container | Host port | Hostname (via Traefik) | Mode | Volume |
|---------|-----------|-----------|------------------------|------|--------|
| Push target | `registry` | 5000 | `registry.docker.lan` | read/write | `registry-data` |
| Pull-through cache | `registry-mirror` | 5001 | `mirror.docker.lan` | proxy → `https://mirror.gcr.io` | `registry-mirror-data` |

- Both hostnames resolve to **192.168.0.7** (Traefik LXC 114), which proxies to LXC 103 ports 5000 and 5001 respectively. Clients use the portless URLs.
- The **mirror** exists because the ISP route to Cloudflare anycast `172.64.66.0/24` (Docker Hub blob CDN) is blackholed — direct `docker pull node:22-alpine` from any host on this network hits an i/o timeout. The mirror's upstream is `mirror.gcr.io` (Google's public Docker Hub mirror) which goes through Google IPs that work fine.
- Proxy config: `/home/admin/registry-mirror/config.yml` (mounted into the container).
- Clients use it via `registry-mirrors` in `/etc/docker/daemon.json`:
  ```json
  {
    "insecure-registries": ["registry.docker.lan", "mirror.docker.lan"],
    "registry-mirrors": ["http://mirror.docker.lan"]
  }
  ```
  Configured on: LXC 106 (`gitlab-runner-docker`). Not yet rolled out to VMs 210/211/212 (swarm) or app LXCs.
- A registry in proxy mode is **read-only** for clients — don't try to push to it.
- **Cache state caveat:** if the proxy hits an upstream error mid-fetch (e.g., during the original Cloudflare blackhole), it can record blob metadata but no body, then serve `200 OK` with `Content-Length` set and zero bytes back. Symptom: docker pull retries forever. Fix: `docker compose rm -f registry-mirror && docker volume rm admin_registry-mirror-data && docker compose up -d registry-mirror`.
- **GC:** weekly cron at `/etc/cron.d/registry-mirror-gc` (Sun 03:15) runs `/usr/local/bin/registry-mirror-gc.sh` — calls `registry garbage-collect` without `--delete-untagged` so cached images stay warm. `--delete-untagged=true` is too aggressive on a proxy registry (treats all cached manifests as untagged).

---

## Docker Swarm (VMs)

Replaced the LXC-based swarm (formerly VMIDs 109/110/122) with VMs in 2026-04 to escape the privileged-LXC + overlay-network breakage and IP-change leave/rejoin pain. Apps continue running unchanged on Swarm.

- **Manager:** VM 210 `swarm-mgr-01` — **192.168.0.65** (Docker 29.4.1, Swarm Leader)
- **Workers:** VM 211 `swarm-w-01` (.66, has-postgres-data=true label, runs postgres+redis), VM 212 `swarm-w-02` (.67)
- **Pool:** `docker` (also includes LXC 103 docker-registry)
- **Login:** `ssh admin@192.168.0.65` (NOPASSWD sudo; password in `secrets.local.md`, untracked)
- **Insecure registry:** `/etc/docker/daemon.json` on all 3 nodes has `{"insecure-registries":["registry.docker.lan"]}` so pulls from the local registry (LXC 103) work over HTTP.
- **Stacks running:** `caxper-uat` (10 services) + `tel-bot-youtube-downloader` (1 service).
- **Stack source of truth:** `swarm-stacks/*.yml` in this repo (reverse-engineered from old swarm during migration; no compose files existed before).

### Docker contexts

- **Dev box (this machine):** `~/.docker/contexts/` has `new-swarm` (active) → `ssh://admin@192.168.0.65`. Old `swarm-manager`/`swarm-worker-1`/`swarm-worker-2` contexts removed.
- **gitlab-runner-shell (LXC 107):** `gitlab-runner` user has docker context `new-swarm` (active) → `ssh://admin@192.168.0.65`. SSH key at `/home/gitlab-runner/.ssh/id_ed25519` is trusted by `admin@.65`. Old `docker-swarm` context (tcp://192.168.0.50:2376) is left in place but inactive — safe to `docker context rm docker-swarm` once CI pipelines are confirmed working.

---

## k3s Cluster (VMs)

Built 2026-04 alongside Docker Swarm. Standalone k3s, not coupled with Swarm.

- **Control plane:** VM 200 `k3s-cp-01` — **192.168.0.60** (k3s v1.34.6+k3s1, Debian 13)
- **Workers:** VM 201 `k3s-w-01` (.61), VM 202 `k3s-w-02` (.62)
- **Template:** VM 9000 `k3s-template` (Debian 13 cloud-init, reusable for any new VM)
- **Pool:** `kubernete`
- **Login:** `ssh admin@192.168.0.60` (NOPASSWD sudo; password in `secrets.local.md`, untracked)
- **kubectl:** Dev box `~/.kube/config` is a symlink to `~/.kube/k3s-home.yaml` (server: 192.168.0.60:6443). `kubectl get nodes` works directly.
- **Built-in Traefik disabled** at install time (`--disable=traefik`) — homelab Traefik on LXC 114 handles ingress. `klipper-lb` (k3s ServiceLB) is kept.

### Kubernetes Dashboard

- Helm release `kubernetes-dashboard` v7.14.0 in namespace `kubernetes-dashboard` (5 pods).
- Exposed via NodePort on `kubernetes-dashboard-kong-proxy` (HTTPS port 30443 on the cluster).
- Reachable at **https://dashboard.k3s.lan** through homelab Traefik (route file `dashboard.yml` on LXC 114, self-signed cert at `/home/admin/certs/dashboard.k3s.lan.{crt,key}`).
- Login is **token-based**. Dev box has a helper:
  - `dash-token` — copies the permanent admin token to the X11 clipboard, ready to paste.
  - The token is a non-expiring ServiceAccount Secret (`dashboard-admin-token` in `kubernetes-dashboard` ns) bound via ClusterRoleBinding to `cluster-admin`.
- Re-fetch the token any time with: `kubectl -n kubernetes-dashboard get secret dashboard-admin-token -o jsonpath='{.data.token}' | base64 -d`.

### ArgoCD

- **URL:** http://argocd.k3s.lan (admin / see `argocd-initial-admin-secret`)
- **Version:** v3.5.0, namespace `argocd`
- **Exposure:** `argocd-server` Service is NodePort 30080 (http) / 30081 (https)
- **Insecure mode:** `server.insecure=true` in `argocd-cmd-params-cm` so Traefik terminates plain HTTP
- **Target cluster:** the built-in `in-cluster` destination (`https://kubernetes.default.svc`)
- **CLI:** `argocd login argocd.k3s.lan --plaintext`

Retrieve the initial admin password:

```
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

The `applicationsets.argoproj.io` CRD exceeds the annotation size limit for client-side apply.
Install or upgrade it with `kubectl apply --server-side --force-conflicts`.

---

## AI Stack (VMID 118)

Single **privileged** LXC holding everything that touches the GPU. Replaced the
three-container `ia` pool (113 `ollama-webui`, 117 `stable-diffusion`, 118
`ollama`) in Aug 2026. Full detail in `services/ai/README.md`.

- **IP:** 192.168.0.118, pool `ia`, 12 cores / 24 GB cap / 200 GB
- **Access:** `ssh root@192.168.0.15` then `pct exec 118 -- bash -c '...'`
- **Compose file:** `/home/admin/docker-compose.yaml` (mirrored at `services/ai/`)
- **GPU:** RTX 3050, **6144 MiB** — the binding constraint on everything here

| Purpose | Address |
|---------|---------|
| Chat UI + OpenAI API | http://ai.lan (redirects to `/ui`) |
| OpenAI API direct | `http://192.168.0.118:8080/v1/...` |
| ComfyUI | http://images.ai.lan (only while running) |

Models (`/srv/models`, all fully offloaded): `qwen3.5` (IQ4_XS, ~5034 MiB,
~30 tok/s), `qwen2.5` (Q4_K_M, ~4634 MiB, ~32 tok/s), `bge-m3` (embeddings,
~687 MiB). SDXL renders 1024×1024/15 steps in ~26 s warm.

### Why the GPU stays on LXC, not a VM

Passing the GPU to a VM means vfio-binding it: the host must blacklist the nvidia
driver, `nvidia-smi` on PVE stops working, and **no LXC can ever use the GPU
again**. VM memory is also *reserved* rather than capped, and the host runs near
its 62 GB. Sharing between LXCs was never the problem — 117 and 118 both had
working passthrough at once. The real constraint is 6 GB of VRAM with no
arbitration.

### VRAM arbitration

Only one workload holds the card. llama-swap runs exactly one model and swaps on
request (~5 s); each model has `ttl: 600` so the card frees itself when idle
(llama.cpp has no keep-alive of its own). ComfyUI sits behind a compose profile
so it never starts on boot, and `ai-gpu` does the handoff:

```sh
pct exec 118 -- /usr/local/bin/ai-gpu status      # who holds the GPU
pct exec 118 -- /usr/local/bin/ai-gpu comfy-up    # unload LLMs, start ComfyUI
pct exec 118 -- /usr/local/bin/ai-gpu comfy-down  # give the card back
```

(`pct exec` has a minimal PATH — use the absolute path.)

### Gotchas that will bite again

- **runc must stay 1.3.x.** `containerd.io` 2.x ships runc 1.4.x, which writes
  `net.ipv4.ip_unprivileged_port_start` at init; LXC blocks it and *every*
  container fails with `reopen fd 8: permission denied`. `containerd.io` is held
  at `1.7.28`, docker-ce at `28.5.2`. All the Docker LXCs on this host are on
  1.7.x for this reason.
- **GPU needs `--gpus all` *and* an explicit `devices:` list.** `no-cgroups = true`
  is required in LXC but makes nvidia-container-cli skip device cgroup setup, so
  runc never grants access → `Failed to initialize NVML: Unknown Error`.
- **Host driver is 580.178.04 / CUDA 13.0**, installed via `.run` **with `--dkms`**
  so it survives kernel upgrades. The LXC carries the same version's userspace
  (`--no-kernel-module`) and **must be re-run after any host driver change**.
  Installer kept at `/root/ai-backups/`.
- The old 550.90.07 (CUDA 12.4) driver was too old for current llama.cpp images
  (need 12.8+). `NVIDIA_DISABLE_REQUIRE=1` does not help — CUDA forward
  compatibility is datacenter-GPU only. Vulkan silently falls back to CPU (the
  `.run` installer ships no ICD loader).
- **llama-swap's config is mounted as a directory, not a file.** A single-file
  bind mount pins an inode, so `vim`/`sed -i`/`pct push` leave the container
  reading the old copy and config changes silently do nothing.
- **Ollama GGUFs are not always portable.** `qwen2.5`/`bge-m3` moved to llama.cpp
  by hardlink, but ollama's `qwen3.5` uses its own engine metadata
  (`qwen35.rope.dimension_sections` length 3 vs llama.cpp's 4) and had to be
  re-downloaded from Hugging Face.

Backups on the PVE host: `/root/ai-backups/` (open-webui chat DB, old LXC configs,
driver installer) and `/var/lib/vz/dump/vzdump-lxc-118-2026_08_26-12_11_40.tar.zst`
(22 GB, 118's pre-migration ollama state).

---

## Vaultwarden (VMID 109)

Bitwarden-compatible password server (`vaultwarden/server`), cloned from LXC template
101 (docker). Full detail in `services/vaultwarden/README.md`.

- **IP:** 192.168.0.29, pool `tools`, 2 cores / 2 GB / 16 GB
- **Access:** `ssh root@192.168.0.15` then `pct exec 109 -- bash -c '...'`
- **Compose file:** `/home/admin/docker-compose.yaml` (mirrored at `services/vaultwarden/`)
- **Data:** named volume `admin_vaultwarden-data` at `/data` — SQLite DB, attachments, RSA keys
- **Registry:** `/etc/docker/daemon.json` points at `mirror.docker.lan` (Docker Hub CDN is blackholed)

| Purpose | Address |
|---------|---------|
| Web vault | https://secrets.lan |
| Admin panel | https://secrets.lan/admin |
| Direct (behind proxy) | http://192.168.0.29:8080 |

**HTTPS is mandatory, not cosmetic.** The Bitwarden web vault uses WebCrypto, which
browsers only expose on a secure origin, so `secrets.lan` terminates TLS at Traefik
with a self-signed cert (`/home/admin/certs/secrets.lan.{crt,key}` on LXC 114) and the
`web` entrypoint 301-redirects to `websecure`. Vaultwarden itself speaks plain HTTP;
`DOMAIN=https://secrets.lan` is what it emits in links and WebAuthn origins.

**The admin token must be single-quoted in `.env`.** It is stored as an Argon2id PHC
string (OWASP preset `m=19456,t=2,p=1`); Compose interpolates `$` in unquoted *and*
double-quoted values, which silently mangles `$argon2id$...` and locks you out of
`/admin`. The plaintext token is in `secrets.local.md` (untracked). Generate a new
hash with the `argon2` CLI inside the LXC — the image's own `vaultwarden hash`
subcommand demands a TTY and panics under `pct exec`:

```sh
pct exec 109 -- bash -c 'echo -n "<token>" | argon2 "$(openssl rand -base64 24)" -id -k 19456 -t 2 -p 1 -e'
```

**No SMTP is configured, and invites still work.** `SIGNUPS_ALLOWED=false` with
`INVITATIONS_ALLOWED=true`: inviting an address from the admin panel writes an
`invitations` row that pre-authorizes that one address, so the person can register at
https://secrets.lan with that exact email even though signups are closed. Nothing is
emailed — pass the instruction along out-of-band. Verified 2026-09-03: an invited
address gets `200` from `POST /identity/accounts/register`, an uninvited one `400`.
Mail is off on purpose — sending from a residential IP with no PTR is rejected almost
everywhere, and the `mail.lan` host is gone. To enable it later, add `SMTP_HOST`,
`SMTP_PORT`, `SMTP_SECURITY`, `SMTP_FROM`, `SMTP_USERNAME` and `SMTP_PASSWORD` to
`.env` and reference them from the compose environment.

When driving the admin API with curl, **send an empty body (`-d ''`) to routes that
take no data**. Rocket treats a JSON body on a bodyless route as a route mismatch and
returns `404`, which is indistinguishable from a wrong URL — `/admin/users/<id>/delete`
gives `200` with `-d ''` and `404` with `-d '{}'`.

---

## LGTM Observability Stack (VMID 122)

All-in-one observability backend from the `grafana/otel-lgtm` Docker Hub image — Grafana,
Loki (logs), Tempo (traces), Prometheus (metrics), Pyroscope (profiles), fronted by an
OpenTelemetry Collector. Cloned from LXC template 101 (docker).

- **IP:** 192.168.0.122, pool `tools`, 4 cores / 8 GB / 40 GB
- **Access:** `ssh root@192.168.0.15` then `pct exec 122 -- bash -c '...'`
- **Compose file:** `/home/admin/docker-compose.yaml` (mirrored in this repo at `services/lgtm/`)
- **Data:** single named volume `admin_lgtm-data` mounted at `/data` — holds Grafana DB/plugins,
  Loki chunks, Tempo blocks, Prometheus TSDB and Pyroscope. No retention tuning applied.
- **Registry:** `/etc/docker/daemon.json` points at `mirror.docker.lan`; pulling this image
  without the mirror hangs (Docker Hub CDN is blackholed by the ISP).

| Purpose | Address |
|---------|---------|
| Grafana UI | http://grafana.lan (Traefik) / 192.168.0.122:3000 |
| OTLP gRPC ingest | `otlp.grafana.lan:4317` |
| OTLP HTTP ingest | `http://otlp.grafana.lan:4318` |
| Loki API | `http://loki.grafana.lan:3100` |
| Tempo API | `http://tempo.grafana.lan:3200` |
| Prometheus API | `http://prom.grafana.lan:9090` |
| Pyroscope | `http://192.168.0.122:4040` |

Ingest ports are published straight off the LXC, not proxied — OTLP gRPC needs h2c end to
end and agents have no reason to traverse Traefik.

Grafana runs with the image default of **anonymous access at Admin role** (no login prompt);
an `admin` account also exists for API use, with its password supplied via
`GF_SECURITY_ADMIN_PASSWORD` in `/home/admin/.env` on the LXC (see `services/lgtm/.env.example`;
value in `secrets.local.md`, untracked). Set
`GF_AUTH_ANONYMOUS_ENABLED=false` in the compose environment to require login.

Point services at it with:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otlp.grafana.lan:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=<service>
```

Health check: `pct exec 122 -- docker exec lgtm /otel-lgtm/docker/healthcheck.sh`

---

## GitHub Actions Runner (VMID 124)

- **IP:** 192.168.0.28
- **Pool:** github
- **Base:** cloned from LXC template 101 (docker), Docker 28.1.1 available for container jobs
- **Runner:** actions/runner v2.336.0 at `/opt/actions-runner`, runs as the `runner` user (in `docker` group)
- **Access:** `ssh root@192.168.0.15` then `pct exec 124 -- bash -c '...'`

### Current registration

- **Registered to org:** `eduinlight-org` (org-level runner; personal accounts can't have account-wide runners)
- **Runner name:** `github-runner-lxc124`
- **Labels:** `self-hosted,linux,x64,docker,proxmox,homelab`
- **Service:** `actions.runner.eduinlight-org.github-runner-lxc124.service` — active + enabled (auto-starts on boot, reconnects on its own)
- **Status check:** `pct exec 124 -- systemctl status actions.runner.eduinlight-org.github-runner-lxc124.service` or `journalctl -u actions.runner.eduinlight-org.github-runner-lxc124.service -n 20`
- Target it in workflows with `runs-on: [self-hosted, linux, x64]`. For a repo to use this org runner, allow it under org → Settings → Actions → Runner groups → repository access. `docker build`/container steps work; if a workflow pulls from Docker Hub, use the local mirror (`mirror.docker.lan`) to avoid the blackhole.

### Re-registering

Register against a repo or org with a token from
*Settings → Actions → Runners → New self-hosted runner*:

```
pct exec 124 -- /opt/actions-runner/register.sh <github-url> <registration-token> [name] [labels]
```

Registration tokens expire about an hour after they are issued.

### Containerised runners (the ones that actually take the load)

Alongside the native runner above, LXC 124 runs **four** containerised runners —
`gh-runner-docker`, `-2`, `-3`, `-4` — from a locally built image
`lightnotes-gh-runner:22.04`. Compose project at `/opt/gh-runner-docker/`, mirrored in this
repo at `services/gh-runner-linux/` (see its README for the full picture).

- Labels `self-hosted,Linux,X64,docker,homelab,kubectl`, identical on all four, so a job lands
  on any of them — they must stay interchangeable.
- The Docker socket is bind-mounted, so jobs share the LXC's daemon.
- **The whole toolchain is baked into the image** (Aug 2026): Rust stable + rustfmt/clippy +
  the wasm32 and aarch64-linux-android targets, `dx` 0.7.10, Temurin 17, the Android SDK/NDK,
  Node 22, Playwright 1.49.1 + chromium, `gh`/`jq`/`yq`/`kubectl`/`kustomize`/`actionlint`,
  and the AppImage/deb/rpm packaging stack. The lightchat harness's `scripts/ensure-tools.sh`
  only *verifies* and fails the job by name — provisioning is this Dockerfile's job.

**Two rules govern the image, both from the named volume mounted over `/home/runner`:**

1. **Nothing installs under `/home/runner`** — the volume masks it. Hence
   `CARGO_HOME=/usr/local/cargo`, `ANDROID_HOME=/opt/android-sdk`,
   `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`. The kubeconfig bind-mount at
   `/home/runner/.kube` is the exception — a nested, more specific mount wins.
2. **PATH must be set by `ENV`, not a profile.** Actions runs steps as
   `bash --noprofile --norc`, which reads neither `.bashrc` nor `.profile`. This bites
   silently: before Aug 2026, `cargo` and `dx` were installed on a runner, resolved fine from
   an interactive `docker exec`, and were missing from every job. **Always verify with
   `bash --noprofile --norc`, never `bash -lc`** — the latter lies.

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker bash --noprofile --norc -c 'command -v cargo dx kubectl'
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose build runner && docker compose up -d'
```

`up -d` recreates all four; volumes (registrations, `_work`, gradle/bun caches) survive.
Rebuild while idle. For a minute afterwards each logs `Runner connect error: Conflict` while
GitHub's old session lease expires — self-healing.

**Cargo registry perms:** `CARGO_HOME=/usr/local/cargo` is root-owned, so it is opened with
`chmod -R a+rwX` — **never `a+w`**. Crate tarballs keep their own modes; `fnv-1.0.7` ships
`lib.rs` at 0660, and `a+w` makes that 0662: writable, still unreadable, and CI dies with
`couldn't read .../fnv-1.0.7/lib.rs: Permission denied (os error 13)` partway through a build
while `cargo`/`rustc`/`dx --version` all look fine. The Dockerfile now asserts readability at
build time. Repair a live container with
`docker exec -u root <c> chmod -R a+rwX /usr/local/cargo /usr/local/rustup`.

**Playwright:** `/opt/ms-playwright` needs `chmod -R a+rwX`, not `a+rX` — a root-owned browser
cache reads fine and then fails any in-job `playwright install` with
`EACCES ... mkdir '/opt/ms-playwright/__dirlock'`. The browser build is version-locked
(1.49.1 → `chromium-1148`); a mismatched one sits unused, so verify with
`node -e 'console.log(require("playwright").chromium.executablePath())'` rather than checking
that some chromium exists.

**k8s access:** all four share a read-only kubeconfig at `/srv/gh-runner/kube/config` →
`/home/runner/.kube`, using a dedicated k3s ServiceAccount `gh-runner-deployer` (kube-system,
non-expiring token, `cluster-admin` — preview deploys create/delete namespaces). Not the human
admin credential; revoke with `kubectl delete clusterrolebinding gh-runner-deployer`.

**Unattended re-registration works** (Aug 2026). `.env`/`runners.env` now hold `ACCESS_TOKEN`,
a PAT that `entrypoint.sh` exchanges for a fresh registration token on every start, so a runner
whose volume is lost comes back on its own. Install one with
`pct exec 124 -- bash -c 'read -rs T && printf %s "$T" | /opt/gh-runner-docker/set-runner-pat.sh'`
(validates before writing), then **`docker compose up -d`** — `env_file` is injected at *create*
time, so running containers keep the old value until recreated. Verified end to end by deleting
runner-4's registration and restarting it. Note the token is readable by any job: the Docker
socket is mounted, so file modes buy nothing — scope it to `admin:org` alone.
A runner counts as configured if any of `.runner`, `.credentials`, `.credentials_rsaparams`,
`.runner_migrated` survive in `actions-runner/`; removing only the first two makes `config.sh`
refuse. Labels are fixed at registration, so change them on an existing runner via the API:
`gh api -X POST /orgs/eduinlight-org/actions/runners/<id>/labels -f 'labels[]=kubectl'`.
