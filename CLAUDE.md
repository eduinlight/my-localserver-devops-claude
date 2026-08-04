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
| 109 | docker-swarm-manager | running | 192.168.0.50 | 2 GB | 4 | 50 GB |
| 110 | docker-swarm-worker | running | 192.168.0.30 | 8 GB | 8 | 50 GB |
| 111 | dns | running | 192.168.0.21 | 512 MB | 8 | 8 GB |
| 112 | debian | **TEMPLATE** | — | 512 MB | 8 | — |
| 113 | ollama-webui | running | 192.168.0.51 | 512 MB | 8 | 58 GB |
| 114 | traefik | running | 192.168.0.7 | 512 MB | 1 | 8 GB |
| 116 | openclaw | running | 192.168.0.55 | 8 GB | 8 | 100 GB |
| 117 | stable-diffusion | running | 192.168.0.117 | 16 GB | 8 | 100 GB |
| 118 | ollama | running | 192.168.0.118 | 36 GB | 8 | 200 GB |
| 120 | calibre-web | running | 192.168.0.120 | 2 GB | 2 | 100 GB |
| 121 | plane | running | 192.168.0.121 | 8 GB | 4 | 50 GB |
| 122 | docker-swarm-worker | running | 192.168.0.237 | 8 GB | 8 | 50 GB |
| 124 | github-runner | running | 192.168.0.28 | 4 GB | 4 | 40 GB |

### Virtual Machines

| VMID | Name | Status | IP | RAM | Disk |
|------|------|--------|-----|-----|------|
| 102 | work-ubuntu-01 | stopped | — | 8 GB | 100 GB |
| 115 | win11 | stopped | — | 4 GB | 100+100+100 GB |
| 119 | work-ubuntu-02 | stopped | — | 8 GB | 100 GB |
| 123 | ubuntu | stopped | — | 8 GB | 100 GB |
| 200 | k3s-cp-01 | running | 192.168.0.60 | 4 GB | 40 GB |
| 201 | k3s-w-01 | running | 192.168.0.61 | 6 GB | 60 GB |
| 202 | k3s-w-02 | running | 192.168.0.62 | 6 GB | 60 GB |
| 210 | swarm-mgr-01 | running | — | 2 GB | 90 GB |
| 211 | swarm-w-01 | running | — | 6 GB | 60 GB |
| 212 | swarm-w-02 | running | — | 6 GB | 60 GB |
| 9000 | k3s-template | **TEMPLATE** | — | 2 GB | 3 GB |

### Resource Pools

| Pool | Comment | Members |
|------|---------|---------|
| ansible | — | 109, 110 |
| docker | Docker services | 103, 210, 211, 212 |
| github | GitHub CI services | 124 |
| gitlab | GitLab services | 105, 106, 107 |
| ia | AI/ML services | 113, 117, 118 |
| kubernete | k3s cluster + template | 200, 201, 202, 9000 |
| tools | Tools and apps | 100, 104, 108, 114, 116, 120, 121 |
| work | Work VMs and ubuntu template | 102, 119, 123 |

Add a guest to a pool with `pvesh set /pools/<name> --vms <vmid>` (`pct set --pool` is not valid).

### LXC Templates

- **VMID 101 (docker)** — Template for services that run via Docker/docker-compose
- **VMID 112 (debian)** — Template for services that run natively via systemd (no Docker)

When deploying a new service, clone the appropriate template based on whether the service needs Docker or can run with systemd.

### Key Services

- **CI/CD:** GitLab (105) + 2 runners (106 docker, 107 shell) + Docker Registry (103) + GitHub Actions runner (124)
- **Kubernetes:** k3s cluster — cp (200) + 2 workers (201, 202), ArgoCD + dashboard in-cluster
- **AI/ML:** Ollama (118, 36GB RAM), Ollama WebUI (113), Stable Diffusion (117)
- **Media:** Media server (104, 1.3TB disk), Immich photos (108), Calibre-web (120)
- **Infra:** DNS (111), Traefik reverse proxy (114), S3 (100), Mail (102)
- **Docker Swarm:** Manager (109) + 2 workers (110, 122)
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
| docker.lan | `@` → .27, `registry` → .7 | mixed | Registry direct, UI via Traefik |
| git.lan | `@` | 192.168.0.23 | Direct to GitLab |
| gitlab.lan | `@` | 192.168.0.7 | Traefik (port 8929) |
| immich.lan | `@` | 192.168.0.26 | Direct |
| k3s.lan | `@`, `cp`, `api` → .60, `w1` → .61, `w2` → .62 | direct | Cluster nodes |
| k3s.lan | `dashboard`, `argocd` | 192.168.0.7 | Traefik → NodePort |
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
| k3s-dashboard.yml | dashboard.k3s.lan | 192.168.0.60 (k3s-cp-01) | 30443 | yes (insecureSkipVerify) |
| argocd.yml | argocd.k3s.lan | 192.168.0.60 (k3s-cp-01) | 30080 | no |
| tls.yml | — | — | — | cert config for openclaw.lan, proxmox.lan, registry.docker.lan, dashboard.k3s.lan |
| transports.yml | — | — | — | proxmoxTransport (insecureSkipVerify) |

---

## Kubernetes / k3s Cluster

- **Nodes:** k3s-cp-01 (200, .60), k3s-w-01 (201, .61), k3s-w-02 (202, .62)
- **Version:** k3s v1.34.6+k3s1, containerd, Debian 13
- **Access:** `ssh root@192.168.0.15` then `qm guest exec 200 -- /bin/bash -c 'kubectl ...'`
- **No in-cluster ingress controller** — k3s Traefik/servicelb are disabled. Services are exposed as
  NodePort and routed from the external Traefik LXC (114).

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

## GitHub Actions Runner (VMID 124)

- **IP:** 192.168.0.28
- **Pool:** github
- **Base:** cloned from LXC template 101 (docker), Docker 28.1.1 available for container jobs
- **Runner:** actions/runner v2.336.0 at `/opt/actions-runner`, runs as the `runner` user (in `docker` group)
- **Access:** `ssh root@192.168.0.15` then `pct exec 124 -- bash -c '...'`

Register against a repo or org with a token from
*Settings → Actions → Runners → New self-hosted runner*:

```
pct exec 124 -- /opt/actions-runner/register.sh <github-url> <registration-token> [name] [labels]
```

Registration tokens expire about an hour after they are issued.
