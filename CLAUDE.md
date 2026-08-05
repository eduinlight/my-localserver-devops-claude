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
  - `sda` — 57.3 GB (secondary)
- **No ZFS pools**

### Storage

| Name | Type | Total | Used | Available | % |
|------|------|-------|------|-----------|---|
| local | dir | ~94 GB | ~20 GB | ~69 GB | 21.6% |
| local-lvm | lvmthin | ~1.7 TB | ~1.1 TB | ~614 GB | 64.1% |

### Networking

- **Bridge:** vmbr0 on enp129s0 — 192.168.0.15/24, gateway 192.168.0.1
- **WiFi:** wlp130s0f0 — link up, no IP (was 192.168.0.5/24, removed to resolve conflict with s3 LXC)

### LXC Containers

| VMID | Name | Status | IP | RAM | Cores | Disk |
|------|------|--------|-----|-----|-------|------|
| 100 | s3 | running | 192.168.0.5 | 512 MB | 1 | 8 GB |
| 101 | docker | **TEMPLATE** | — | 512 MB | 1 | — |
| 102 | mail | running | 192.168.0.6 | 512 MB | 8 | 8 GB |
| 103 | docker-registry | running | 192.168.0.27 | 2 GB | 4 | 100 GB |
| 104 | media | running | 192.168.0.22 | 8 GB | 4 | 20+512+812 GB |
| 105 | gitlab | running | 192.168.0.23 | 16 GB | 16 | 200 GB |
| 106 | gitlab-runner-docker | running | 192.168.0.24 | 8 GB | 8 | 100 GB |
| 107 | gitlab-runner-shell | running | 192.168.0.25 | 1 GB | 8 | 20 GB |
| 108 | immich | running | 192.168.0.26 | 8 GB | 4 | 208 GB |
| 111 | dns | running | 192.168.0.21 | 512 MB | 8 | 8 GB |
| 112 | debian | **TEMPLATE** | — | 512 MB | 8 | — |
| 113 | ollama-webui | running | 192.168.0.51 | 512 MB | 8 | 58 GB |
| 114 | traefik | running | 192.168.0.7 | 512 MB | 1 | 8 GB |
| 116 | openclaw | running | 192.168.0.55 | 8 GB | 8 | 100 GB |
| 117 | stable-diffusion | running | 192.168.0.117 | 16 GB | 8 | 100 GB |
| 118 | ollama | running | 192.168.0.118 | 36 GB | 8 | 200 GB |
| 120 | calibre-web | running | 192.168.0.120 | 2 GB | 2 | 100 GB |
| 121 | plane | running | 192.168.0.121 | 8 GB | 4 | 50 GB |

### Virtual Machines

| VMID | Name | Status | IP | RAM | Cores | Disks | Pool |
|------|------|--------|-----|-----|-------|-------|------|
| 115 | win11 | stopped | — | 4 GB | — | 100+100+100 GB | — |
| 123 | ubuntu | **TEMPLATE** | — | 8 GB | 2 | 100 GB | — |
| 200 | k3s-cp-01 | running | 192.168.0.60 | 4 GB | 2 | 40 GB | kubernete |
| 201 | k3s-w-01 | running | 192.168.0.61 | 6 GB | 2 | 60 GB | kubernete |
| 202 | k3s-w-02 | running | 192.168.0.62 | 6 GB | 2 | 60 GB | kubernete |
| 210 | swarm-mgr-01 | running | 192.168.0.65 | 2 GB | 2 | 30 GB | docker |
| 211 | swarm-w-01 | running | 192.168.0.66 | 6 GB | 4 | 60 GB | docker |
| 212 | swarm-w-02 | running | 192.168.0.67 | 6 GB | 4 | 50 GB | docker |
| 9000 | k3s-template | **TEMPLATE** | — | 2 GB | 2 | 3 GB (cloud-init) | kubernete |

### Templates

- **LXC 101 (docker)** — Template for services that run via Docker/docker-compose inside an LXC.
- **LXC 112 (debian)** — Template for services that run natively via systemd (no Docker).
- **VM 9000 (k3s-template)** — Debian 13 cloud-init template with `admin` user pre-baked (NOPASSWD sudo, password `REDACTED`, dev box SSH key). Use this for any new VM clone (k3s, swarm, anything Debian-based). **Do not pass `--ciuser`/`--cipassword` on `qm clone`** — values are baked into the image.
- **VM 123 (ubuntu)** — Older Ubuntu Server template (no cloud-init). Kept for compatibility; prefer 9000 for new builds.

### Proxmox Pools

- **kubernete** — k3s cluster (VMs 200/201/202) + the cloud-init template (9000).
- **docker** — Docker registry LXC (103) + new Swarm (VMs 210/211/212).

When deploying a new service, clone the appropriate template based on whether the service needs Docker (101) or can run with systemd (112) — or use VM template 9000 for a full-VM workload.

### Key Services

- **CI/CD:** GitLab (105) + 2 runners (106 docker, 107 shell) + Docker Registry (103)
- **AI/ML:** Ollama (118, 36GB RAM), Ollama WebUI (113), Stable Diffusion (117)
- **Media:** Media server (104, 1.3TB disk), Immich photos (108), Calibre-web (120)
- **Infra:** DNS (111), Traefik reverse proxy (114), S3 (100), Mail (102)
- **Docker Swarm (VMs):** Manager 210 (192.168.0.65) + workers 211/212 — see "## Docker Swarm" section below.
- **Kubernetes (k3s, VMs):** Control-plane 200 (192.168.0.60) + workers 201/202 — see "## k3s Cluster" section below.
- **Apps:** OpenClaw (116), Plane project mgmt (121)

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
| ai.lan | `@`, `images`, `fooocus`, `api.images` | 192.168.0.7 | Traefik |
| books.lan | `@` | 192.168.0.7 | Traefik |
| dns.lan | `@` | 192.168.0.21 | Direct |
| docker.lan | `@` → .27, `registry` → .7, `mirror` → .7 | mixed | Apex direct to registry LXC, `registry`/`mirror` via Traefik (mirror = Docker Hub pull-through cache) |
| git.lan | `@` | 192.168.0.23 | Direct to GitLab |
| gitlab.lan | `@` | 192.168.0.7 | Traefik (port 8929) |
| immich.lan | `@` | 192.168.0.26 | Direct |
| k3s.lan | `@` → .60, `cp`, `w1`, `w2`, `api` (direct), `dashboard` → .7 | mixed | Direct to nodes; `dashboard` via Traefik |
| mail.lan | `@` | 192.168.0.6 | Direct, full mail records (DKIM, SPF, DMARC, SRV) |
| media.lan | `@`, `request`, `radar`, `sonar`, `qbittorrent` | 192.168.0.7 | Traefik, subdomains are CNAMEs |
| openclaw.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS) |
| planer.lan | `@` | 192.168.0.7 | Traefik |
| proxmox.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS, insecureSkipVerify to PVE:8006) |
| s3.lan | `@` + `*` (wildcard) | 192.168.0.5 | Direct |

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
| webui.yml | ai.lan | 192.168.0.51 (ollama-webui) | 3000 | no |
| images.yml | images.ai.lan | 192.168.0.117 (stable-diff) | 7865 | no |
| images-api.yml | api.images.ai.lan | 192.168.0.117 | 7866 | no |
| books.yml | books.lan | 192.168.0.120 (calibre-web) | 8083 | no |
| gitlab.yml | gitlab.lan | 192.168.0.23 (gitlab) | 8929 | no |
| media.yml | media.lan | 192.168.0.22 (media) | 8096 | no |
| radar.yml | radar.media.lan | 192.168.0.22 | 7878 | no |
| sonar.yml | sonar.media.lan | 192.168.0.22 | 8989 | no |
| qbittorrent.yml | qbittorrent.media.lan | 192.168.0.22 | 8080 | no |
| seer.yml | request.media.lan | 192.168.0.22 | 5055 | no |
| openclaw.yml | openclaw.lan | 192.168.0.55 (openclaw) | 18789 | yes |
| planer.yml | planer.lan | 192.168.0.121 (plane) | 80 | no |
| proxmox.yml | proxmox.lan | 192.168.0.15 (PVE) | 8006 | yes |
| registry.yml | registry.docker.lan | 192.168.0.27 (registry) | 5000 | no |
| mirror.yml | mirror.docker.lan | 192.168.0.27 (registry-mirror) | 5001 | no |
| dashboard.yml | dashboard.k3s.lan | 192.168.0.60 (k3s cp NodePort) | 30443 | yes (HTTPS frontend, HTTPS backend with insecureSkipVerify via `dashboardTransport` defined inline) |
| tls.yml | — | — | — | cert config for openclaw.lan, proxmox.lan, registry.docker.lan, dashboard.k3s.lan |
| transports.yml | — | — | — | proxmoxTransport (insecureSkipVerify) |

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
- **Login:** `ssh admin@192.168.0.65` (password `REDACTED`, NOPASSWD sudo)
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
- **Login:** `ssh admin@192.168.0.60` (password `REDACTED`, NOPASSWD sudo)
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
