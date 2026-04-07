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
- **WiFi:** wlp130s0f0 — 192.168.0.5/24

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
| 109 | docker-swarm-manager | running | 192.168.0.50 | 2 GB | 4 | 50 GB |
| 110 | docker-swarm-worker | running | 192.168.0.30 | 8 GB | 8 | 50 GB |
| 111 | dns | running | 192.168.0.21 | 512 MB | 8 | 8 GB |
| 112 | debian | **TEMPLATE** | — | 512 MB | 8 | — |
| 113 | ollama-webui | running | 192.168.0.51 | 512 MB | 8 | 58 GB |
| 114 | traefik | running | 192.168.0.7 | 512 MB | 1 | 8 GB |
| 116 | openclaw | running | 192.168.0.55 | 8 GB | 8 | 100 GB |
| 117 | stable-diffusion | running | 192.168.0.117 | 16 GB | 8 | 100 GB |
| 118 | ollama | running | 192.168.0.118 | 36 GB | 8 | 200 GB |
| 119 | todo-app | running | 192.168.0.235 | 2 GB | 2 | 20 GB |
| 120 | calibre-web | running | 192.168.0.120 | 2 GB | 2 | 100 GB |
| 121 | plane | running | 192.168.0.121 | 8 GB | 4 | 50 GB |
| 122 | docker-swarm-worker | running | 192.168.0.237 | 8 GB | 8 | 50 GB |

### Virtual Machines

| VMID | Name | Status | RAM | Disks |
|------|------|--------|-----|-------|
| 115 | win11 | stopped | 4 GB | 100+100+100 GB |

### LXC Templates

- **VMID 101 (docker)** — Template for services that run via Docker/docker-compose
- **VMID 112 (debian)** — Template for services that run natively via systemd (no Docker)

When deploying a new service, clone the appropriate template based on whether the service needs Docker or can run with systemd.

### Key Services

- **CI/CD:** GitLab (105) + 2 runners (106 docker, 107 shell) + Docker Registry (103)
- **AI/ML:** Ollama (118, 36GB RAM), Ollama WebUI (113), Stable Diffusion (117)
- **Media:** Media server (104, 1.3TB disk), Immich photos (108), Calibre-web (120)
- **Infra:** DNS (111), Traefik reverse proxy (114), S3 (100), Mail (102)
- **Docker Swarm:** Manager (109) + 2 workers (110, 122)
- **Apps:** OpenClaw (116), Todo-app (119), Plane project mgmt (121)

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
| docker.lan | `@` → .27, `registry` → .7 | mixed | Registry direct, UI via Traefik |
| git.lan | `@` | 192.168.0.23 | Direct to GitLab |
| gitlab.lan | `@` | 192.168.0.7 | Traefik (port 8929) |
| immich.lan | `@` | 192.168.0.26 | Direct |
| mail.lan | `@` | 192.168.0.6 | Direct, full mail records (DKIM, SPF, DMARC, SRV) |
| media.lan | `@`, `request`, `radar`, `sonar`, `qbittorrent` | 192.168.0.7 | Traefik, subdomains are CNAMEs |
| openclaw.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS) |
| planer.lan | `@` | 192.168.0.7 | Traefik |
| proxmox.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS, insecureSkipVerify to PVE:8006) |
| s3.lan | `@` + `*` (wildcard) | 192.168.0.5 | Direct |
| todo.lan | `@` | 192.168.0.7 | Traefik |

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
| todo.yml | todo.lan | 192.168.0.235 (todo-app) | 80 | no |
| tls.yml | — | — | — | cert config for openclaw.lan, proxmox.lan |
| transports.yml | — | — | — | proxmoxTransport (insecureSkipVerify) |
