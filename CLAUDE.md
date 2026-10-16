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
| local-lvm | lvmthin | ~1.7 TB | ~1244 GB | ~466 GB | ~72.7% (Oct 2026) |
| /mnt/media-8tb | ext4 (host mount, not PVE storage) | 7.3 TiB | 690 GB | 6.7 TiB | 10% |

**`local-lvm` is thin-overcommitted** — provisioned volumes sum to ~2.19 TB against a
1.71 TB pool. It sat at 92% until Aug 2026, when moving the 690 GB media library to the
new 8 TB HDD, dropping an empty orphan volume, and shrinking LXC 104's now-oversized
812 GB config volume to 20 GB brought it back to ~51%. If
`data_percent` reaches 100% every guest on it starts throwing I/O errors and thin
metadata can corrupt. Check with
`lvs --units g -o lv_name,lv_size,data_percent pve/data`.

Guests do not return freed blocks to the pool on their own unless the volume has
`discard=on` (the k3s/swarm VMs do; most LXCs and VM 115 do not).
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

**RAM is the other tight resource.** 62 GB total, and the host runs near capacity with swap
largely full. VM memory is *reserved* in config but **allocated lazily** — so a VM's configured
size is a poor guide to what it actually costs. Judge by host-side RSS instead, which is the
only number that reflects reality:

```sh
ps -eo rss,args | grep '[k]vm -id' \
  | sed -E 's/^ *([0-9]+).*-id ([0-9]+).*-name ([^,]*),.*/\1 \2 \3/' \
  | sort -rn | awk '{printf "VM %-5s %-22s %6.2f GB\n", $2, $3, $1/1048576}'
```

Sep 2026 measurements showing why config size misleads in *both* directions:

| Guest | Configured | Real host RSS | Note |
|-------|-----------|---------------|------|
| swarm-w-01 (211) | 6 GB | **0.82 GB** | shrinking its config would have freed almost nothing |
| gh-runner-windows (125) | 8 GB | **7.27 GB** | guest only *uses* 2.4 GB — Windows hoards cache |
| mac-runner (126) | 8 GB | 6.4–7.3 GB | genuinely used |

For LXCs, split anon from cache — `memory.current` counts page cache, which the kernel
reclaims for free and which made the containers look far heavier than they are:

```sh
for d in /sys/fs/cgroup/lxc/*/; do
  awk -v c="$(basename $d)" '/^anon /{a=$2} /^file /{f=$2}
    END {printf "LXC %-5s anon=%5.2fGB cache=%5.2fGB\n", c, a/2^30, f/2^30}' $d/memory.stat
done
```

That split is the real budget: Sep 2026 showed ~48.6 GB genuinely committed (KVM RSS + LXC
anon) with ~13 GB of it merely page cache — LXC 104 alone held 5 GB of evictable cache. The
best remaining reclaim target is **VM 125**, holding 7.3 GB to run a 2.4 GB workload.

### Networking

- **Bridge:** vmbr0 on enp129s0 — 192.168.0.15/24, gateway 192.168.0.1
- **WiFi:** wlp130s0f0 — link up, no IP (was 192.168.0.5/24, removed to resolve conflict with s3 LXC)

### LXC Containers

| VMID | Name | Status | IP | RAM | Cores | Disk |
|------|------|--------|-----|-----|-------|------|
| 100 | s3 (Garage) | running | 192.168.0.5 | 512 MB | 1 | **200 GB** (Sep 2026, was 8 GB) |
| 101 | docker | **TEMPLATE** | — | 512 MB | 1 | — |
| 103 | docker-registry | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.27 | 2 GB | 4 | 100 GB |
| 104 | media | running | 192.168.0.22 | 8 GB | 4 | 40+20 GB + 8 TB HDD |
| 105 | gitlab | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.23 | 16 GB | 16 | 200 GB |
| 106 | gitlab-runner-docker | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.24 | 8 GB | 8 | 100 GB |
| 107 | gitlab-runner-shell | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.25 | 1 GB | 8 | 20 GB |
| 108 | immich | running | 192.168.0.26 | 8 GB | 4 | 208 GB |
| 109 | vaultwarden | running | 192.168.0.29 | 2 GB | 2 | 16 GB |
| 111 | dns | running | 192.168.0.21 | 512 MB | 8 | 8 GB |
| 112 | debian | **TEMPLATE** | — | 512 MB | 8 | — |
| 114 | traefik | running | 192.168.0.7 | 512 MB | 1 | 8 GB |
| 118 | ai | running | 192.168.0.118 | 24 GB | 12 | 200 GB |
| 120 | calibre-web | running | 192.168.0.120 | 2 GB | 2 | 100 GB |
| 122 | lgtm | running | 192.168.0.122 | 8 GB | 4 | 40 GB |
| 124 | github-runner | running | 192.168.0.28 | **10 GB + 512 MB swap** (Oct 2026, was 12+8) | 4 | **150 GB** (Oct 2026, was 100) |

### Virtual Machines

| VMID | Name | Status | IP | RAM | Cores | Disks | Pool |
|------|------|--------|-----|-----|-------|-------|------|
| 110 | work-arch-01 | running | (no agent reporting) | 8 GB (balloon 2) | 12 | 164 GB | — |
| 115 | win11 | **TEMPLATE** | — | 4 GB | 4 | 100 GB (+2 unused) | — |
| 125 | gh-runner-windows | running | 192.168.0.244 | 6 GB (balloon 4) — **staged, applies at next reboot** | 8 | 150 GB | github |
| 126 | mac-runner | running | 192.168.0.245 | 8 GB | **8** | **170 GB** (Oct 2026, was 120) | github |
| 127 | mac-runner-2 | running | 192.168.0.237 | 8 GB | **8** | **170 GB** (Oct 2026, was 120) | github — clone of 126, Sep 2026 |
| 200 | k3s-cp-01 | running | 192.168.0.60 | 4 GB | 2 | **200 GB** | kubernete |
| 201 | k3s-w-01 | running | 192.168.0.61 | **12 GB** | **4** | **200 GB** | kubernete |
| 202 | k3s-w-02 | running | 192.168.0.62 | **12 GB** | **4** | **200 GB** | kubernete |
| 203 | k3s-w-03 | running | 192.168.0.63 | **12 GB** | **4** | **200 GB** | kubernete |
| 210 | swarm-mgr-01 | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.65 | 2 GB | 2 | 90 GB | docker |
| 211 | swarm-w-01 | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.66 | 6 GB | 4 | 60 GB | docker |
| 212 | swarm-w-02 | **stopped** (Sep 2026, `onboot: 0`) | 192.168.0.67 | 6 GB | 4 | 60 GB | docker |
| 9000 | k3s-template | **TEMPLATE** | — | 2 GB | 2 | 3 GB (cloud-init) | kubernete |

**VMs 102 `work-ubuntu-01`, 119 `work-ubuntu-02` and 123 `ubuntu` no longer exist** — they
were listed here but are absent from `qm list` as of Sep 2026. VM 110 `work-arch-01` is an
Arch work VM with `onboot: 0` that was started by hand; it is in no pool and holds ~4.9 GB
of host RAM whenever it is up.

### Resource Pools

| Pool | Comment | Members |
|------|---------|---------|
| docker | Docker services — **entirely shut down Sep 2026**, kept for possible future use | 103, 210, 211, 212 |
| github | GitHub CI services | 124, 125, 126, 127 |
| gitlab | GitLab services — **entirely shut down Sep 2026**, data preserved | 105, 106, 107 |
| ia | AI/ML services | 118 |
| kubernete | k3s cluster + template | 200, 201, 202, 203, 9000 |
| tools | Tools and apps | 100, 104, 108, 109, 114, 120, 122 |
| work | Work VMs and ubuntu template — **all members gone**, pool is empty | (none) |

Add a guest to a pool with `pvesh set /pools/<name> --vms <vmid>` (`pct set --pool` is not valid).

### Templates

- **LXC 101 (docker)** — Template for services that run via Docker/docker-compose inside an LXC.
- **LXC 112 (debian)** — Template for services that run natively via systemd (no Docker).
- **VM 9000 (k3s-template)** — Debian 13 cloud-init template with `admin` user pre-baked (NOPASSWD sudo; password in `secrets.local.md`, untracked). Use this for any new VM clone (k3s, swarm, anything Debian-based). **Do not pass `--ciuser`/`--cipassword` on `qm clone`** — values are baked into the image. ⚠️ **Its baked-in SSH key is `light@light-pc`, not this MacBook's** — a fresh clone refuses the Mac's key until you inject it via `qm guest exec` (see "Adding a worker node" under "## k3s Cluster").
- ~~**VM 123 (ubuntu)**~~ — no longer exists (absent from `qm list`, Sep 2026).

### Proxmox Pools

- **kubernete** — k3s cluster (VMs 200/201/202/203) + the cloud-init template (9000).
- **docker** — Docker registry LXC (103) + Swarm (VMs 210/211/212). **All four are shut down
  as of Sep 2026** and kept only so the stack can be revived if Swarm is ever needed again.

When deploying a new service, clone the appropriate template based on whether the service needs Docker (101) or can run with systemd (112) — or use VM template 9000 for a full-VM workload.

### Key Services

- **CI/CD:** ⚠️ GitLab (105) + runners (106, 107) and Docker Registry (103) are **all stopped** as of Sep 2026 — CI is GitHub Actions only — Linux LXC 124, Windows VM 125 (`services/gh-runner-windows/`), macOS VMs 126 + 127 (`services/gh-runner-macos/`, hackintosh via OpenCore, two interchangeable runners)
- **Kubernetes:** k3s cluster — cp (200) + 3 workers (201/202/203, **12 GB / 4 cores each**), ArgoCD + dashboard in-cluster. **The only deployment target as of Sep 2026.**
- **AI/ML:** single GPU LXC 118 `ai` — llama.cpp via llama-swap (text + embeddings) and ComfyUI (images), see "## AI Stack" below and `services/ai/`
- **Media:** Media server (104 — library on the 8 TB HDD, see `services/media/`), Immich photos (108), Calibre-web (120)
- **Infra:** DNS (111), Traefik reverse proxy (114), S3 (100 — Garage v2.3.0 in Docker, single node,
  `replication_factor = 1`, data/meta at `/home/admin/{data,meta}` on the rootfs). **Keep the Garage
  layout capacity at or below the real disk size** (`garage layout assign -c <N>G 7fd7a57ffde32734`) —
  it was set to 186 GiB on an 8 GB disk, so Garage never refused writes and the `takuteku-maps` bucket
  (7 GiB of map tarballs) filled the disk to 100% in Sep 2026, breaking uploads and metadata snapshots.
  Now 200 GB rootfs with the layout set to 180G. Run the CLI with `pct exec 100 -- docker exec admin-garage-1 /garage <cmd>`.
  **Web UI:** http://console.s3.lan (`khairul169/garage-webui:1.1.0`, port 3909, bcrypt login in
  `/home/admin/webui.env` — single-quoted because of the `$`s; credentials in `secrets.local.md`). It
  reads `admin_token` from the mounted `garage.toml` and talks to the admin API on `garage:3903`,
  which is **not published** on the LXC — test it from the compose network. `garage.toml` is a
  single-file bind mount: edit it in place (not `sed -i`) and `docker compose restart garage`.
  Compose mirrored at `services/s3/docker-compose.yaml`.
  **The web UI can only browse buckets that have a global alias** — its browse handler resolves
  the bucket with `GetBucketInfo?globalAlias=<name>`, so a bucket created with only a key-local
  alias (what an S3 `CreateBucket` call from a client key produces) lists fine but cannot be
  opened. Fix with `garage bucket alias <bucket-id> <name>`; done for `takuteku-maps`
  in Sep 2026. Bucket `d8dd02521bb4a2f0` (local alias `other` on key `test`) has the same issue.
- **Secrets:** Vaultwarden (109) at https://secrets.lan — see "## Vaultwarden" below and `services/vaultwarden/`
- **Observability:** LGTM stack (122) — Grafana/Loki/Tempo/Prometheus/Pyroscope + OTel Collector, see "## LGTM Observability Stack" below
- **Docker Swarm (VMs):** ⚠️ **shut down Sep 2026, not deleted** — manager 210 + workers 211/212, see "## Docker Swarm" section below.
- **Kubernetes (k3s, VMs):** Control-plane 200 (192.168.0.60) + workers 201/202/203 — see "## k3s Cluster" section below.
- **Public edge:** Lightsail VPS 51.44.40.82 terminates TLS for `*.eduindev.com` and forwards over WireGuard to the in-cluster Traefik — see "## Public Edge" below. **frp is gone** (Oct 2026).
- **Email:** takuteku.com + eduindev.com mail (one Stalwart + Bulwark) in k3s namespace `email`, outbound via Amazon SES — see "## Email (takuteku.com, eduindev.com)" below and the `eduinlight-org/email-cd` repo.
- **Project management:** Taiga at https://pm.eduindev.com in k3s namespace `project-manager` — see "## Taiga (pm.eduindev.com)" below and the `eduinlight-org/project-manager-cd` repo.

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

**Shrinking a thin volume needs the volume recreated, not just `lvreduce`.** Reducing
LXC 104's `mp1` from 812 GB to 20 GB (`resize2fs` to 19 GB → `lvreduce -L 20G` →
`resize2fs` to fill) left ~15 GB of thin-pool mappings stranded *beyond the new end of
the volume*: unreachable by `fstrim` because they are no longer addressable through the
device, so `data_percent` read **91% on a volume holding 1.9 GB** and would have climbed
past 100% as the filesystem grew. `lvs` reports the percentage against the new, smaller
`LSize`, which is what makes it look alarming — the absolute figure barely moved
(1.95% of 812 GB = 15.8 GB, then 91.31% of 20 GB = 18.7 GB: the same blocks). The only
way to release them is to drop the thin device: create a fresh volume, copy the data over
with `rsync -aHAX --numeric-ids`, repoint the config, then `lvremove` the old one. Also
note `pct fstrim` is the right tool — `fstrim` *inside* an unprivileged container fails
with `FITRIM ioctl failed: Operation not permitted`, and ext4 will not re-issue a discard
for a range it has already trimmed, so a second run reporting a tiny number is normal and
is not evidence the first one failed.

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
| k3s.lan | `@`, `cp`, `api` → .60, `w1` → .61, `w2` → .62, `w3` → .63 | direct | Cluster nodes |
| k3s.lan | `dashboard`, `argocd` | 192.168.0.7 | Traefik → NodePort |
| mail.lan | `@` | 192.168.0.6 | ⚠️ **ORPHANED** — target host is gone. Zone still has full mail records (DKIM, SPF, DMARC, SRV); kept in case mail is rebuilt |
| media.lan | `@`, `request`, `radar`, `sonar`, `qbittorrent` | 192.168.0.7 | Traefik, subdomains are CNAMEs |
| openclaw.lan | `@` | 192.168.0.7 | ⚠️ **ORPHANED** — LXC 116 removed Aug 2026; resolves to Traefik, which 502s |
| planer.lan | `@` | 192.168.0.7 | ⚠️ **ORPHANED** — LXC 121 removed Aug 2026; resolves to Traefik, which 502s |
| proxmox.lan | `@` | 192.168.0.7 | Traefik (HTTPS/TLS, insecureSkipVerify to PVE:8006) |
| s3.lan | `@` + `*` (wildcard) → .5; `console` → .7 | mixed | S3 API direct; `console` = Garage web UI via Traefik (specific record beats the wildcard) |
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
| s3-console.yml | console.s3.lan | 192.168.0.5 (garage-webui) | 3909 | no |

⚠️ `openclaw.yml` and `planer.yml` point at removed containers. Traefik keeps serving
the routers, so those hosts return 502 rather than NXDOMAIN. Delete the route files
and the matching DNS zones if those services are not coming back.

---

## Docker Registry & Mirror (VMID 103)

> **⚠️ SHUT DOWN as of Sep 2026.** LXC 103 is stopped with `onboot: 0`. Everything below
> describes the service as it was configured and still is on disk — nothing was deleted, so
> `pct start 103` brings it back intact. Two reasons it went away: all deployments moved to
> Kubernetes, and **the ISP Docker Hub blackhole that justified the mirror is resolved**
> (verified Sep 2026 — `auth.docker.io` answers 200 and the Cloudflare CDN answers 403 in
> 0.12 s; a blackhole times out instead). The registry held only Swarm-era images
> (`caxper-uat-*`, `todo-list/*`, `test`), so nothing Kubernetes needs. **k3s never used it** —
> the nodes have no `registries.yaml` and pull straight from ghcr.io/docker.io/quay.io.
>
> **Still pointing at the dead mirror:** LXC 106, 107, 109, 118 and 122 keep
> `registry-mirrors`/`insecure-registries` entries for `mirror.docker.lan` in
> `/etc/docker/daemon.json`. Their *running* containers are unaffected, but the next
> `docker compose pull` on those hosts will try a mirror that is down. Docker falls back to
> Docker Hub on mirror failure, so this degrades to slow rather than broken — clean the
> entries out when convenient. 76 GB of disk (64 GB registry + 12 GB mirror cache) is still
> held by the stopped container's volumes.

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

## GitLab (VMIDs 105, 106, 107) — SHUT DOWN Sep 2026

> **⚠️ The whole `gitlab` pool is stopped** (`onboot: 0` on all three). Nothing was deleted —
> the 95 GB `gitlab` Docker volume and the 259 MB `gitlab-postgres` volume are intact on LXC
> 105, so `pct start 105` brings it back (allow several minutes; GitLab is slow to boot).
> Restart order if reviving: 105 first, then 106/107 so the runners find a live coordinator.
>
> **Why it went:** GitLab was the single largest non-VM memory consumer — ~5.0 GB anon
> (six Ruby workers at ~1.2 GB each) and ~6.8 GB resident, for a service with **14 projects
> whose most recent activity was 2026-07-22**, two months before shutdown. The only thing
> still running was a scheduled pipeline firing daily at 09:33 on `project=1` for ~6 seconds.
> Stopping the pool freed **5.4 GB of real host RAM**, which is what funded taking all three
> k3s workers to 12 GB.
>
> **Verified safe first:** ArgoCD syncs every Application from **github.com**
> (`lightchat-cd`, `lightnotes-cd`, `takuteku-core-cd`) and the cluster contains **zero**
> references to `git.lan`/`gitlab.lan`, so nothing in Kubernetes depends on it. `git.lan` and
> `gitlab.lan` now resolve to a host that is down — the Traefik route and DNS zones were left
> in place for an easy revival.

---

## Docker Swarm (VMs)

> **⚠️ SHUT DOWN as of Sep 2026 — all deployments are Kubernetes now.** VMs 210/211/212 were
> gracefully shut down (manager first, so it could not trigger reschedule churn as the workers
> went) and set `onboot: 0`. **Nothing was destroyed:** disks, named volumes, swarm raft state
> and the `caxper-uat` postgres data are all intact on `local-lvm`, so the cluster can be
> restarted with `qm start 210 && qm start 211 && qm start 212` (manager first, so the workers
> rejoin a live leader). The `caxper-uat` and `tel-bot-youtube-downloader` stacks were left
> deployed and will come back with the nodes.
>
> Shutting these down freed ~3.2 GB of *real* host RAM, 14 GB of VM memory reservation and
> 10 CPU cores, which is what funded the k3s expansion below.

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

- **Control plane:** VM 200 `k3s-cp-01` — **192.168.0.60** (k3s v1.34.6+k3s1, Debian 13), 4 GB / 2 cores
- **Workers:** all three at **12 GB / 4 cores / 200 GB** (Sep 2026) — VM 201 `k3s-w-01` (.61),
  VM 202 `k3s-w-02` (.62), VM 203 `k3s-w-03` (.63, added Sep 2026). Cluster total 40 GB RAM.
  The control plane is also on a 200 GB disk.
- **Template:** VM 9000 `k3s-template` (Debian 13 cloud-init, reusable for any new VM)
- **Pool:** `kubernete`
- **Login:** `ssh admin@192.168.0.60` (NOPASSWD sudo; password in `secrets.local.md`, untracked)

### Node sizing — why w-01 is the odd one out

**A pod cannot be split across nodes**, so a service requesting 8 GB needs one node with more
than 8 GB *allocatable*; adding more 6 GB workers does nothing for it. That is why the Sep 2026
expansion made **w-01 asymmetric (12 GB / 4 cores)** rather than growing every node evenly —
w-01 is the node big workloads land on. It reports ~11.7 GB capacity, and an 8 Gi pod was
verified to schedule on it. Keep that headroom in mind before filling w-01 with small pods.

Growing a node is a reboot: `kubectl drain`, `qm shutdown`, `qm set <id> -memory <MB> -cores <n>`,
`qm start`, `kubectl uncordon`. **`kubectl get nodes` reports stale capacity for a minute or two
after the node returns** — it showed `Ready` with the *old* 6 GB while the VM had been up for 13
seconds. Confirm against `qm status <id> --verbose | grep maxmem`, not the node object.

**w-01 holds five node-pinned `local-path` PVs** (`lightnotes/data-mongo-0`,
`lightchat-staging/data-mongo-0`, and three `takuteku-staging-maps` tiles volumes). Those
StatefulSet pods **cannot migrate** — a drain evicts them and they sit Pending until the node is
back, so any w-01 reboot means real downtime for mongo and the map tiles. They return on their
own once it rejoins. Build and join a replacement node *before* draining, so the ordinary
Deployments have somewhere to land.

### Growing a node's disk — online, no reboot

All four nodes moved from 40/60 GB to **200 GB** in Sep 2026. The Debian cloud image puts root
on `/dev/sda1` as the **last** partition on disk (`sda14`/`sda15` sit *before* it despite the
higher numbers), so it grows in place while mounted:

```sh
qm resize <vmid> scsi0 200G                      # on the PVE host
ssh admin@<node> 'sudo growpart /dev/sda 1 && sudo resize2fs /dev/sda1'
```

**kubelet caches `ephemeral-storage` at startup and will keep reporting the old size** — `df`
shows 197G while `kubectl get nodes` still says 60 GB, which looks like the resize silently
failed. Restart kubelet to re-read it: `systemctl restart k3s-agent` on a worker, `systemctl
restart k3s` on the control plane. Running containers survive it (containerd keeps them); the
control-plane restart does briefly drop the API server.

**This deepened the thin-pool overcommit to 171%** — 2931 GB provisioned against a 1710 GB pool
that is 54% full, with only 16 GB free in the VG, so the pool itself cannot be extended. Nothing
is consumed until written, but if the k3s nodes ever genuinely fill their 200 GB they alone want
800 GB against ~790 GB free. Watch it:

```sh
lvs --units g -o lv_name,lv_size,data_percent,metadata_percent pve/data
```

`activation/thin_pool_autoextend_threshold` is still unset (LVM warns on every resize) and would
have almost no room to extend into anyway. Treat `data_percent` as the number to alarm on.

### Adding a worker node

```sh
qm clone 9000 <vmid> --name k3s-w-0N --full --storage local-lvm --pool kubernete
qm set <vmid> --memory 6144 --cores 2 --cpu host \
  --ipconfig0 ip=192.168.0.<N>/24,gw=192.168.0.1 \
  --nameserver 192.168.0.21 --searchdomain lan --onboot 1 --agent enabled=1
qm resize <vmid> scsi0 60G
qm start <vmid>
# then, from the dev box — pin the version or the node joins on a newer k3s than the cluster:
TOKEN=$(ssh admin@192.168.0.60 'sudo cat /var/lib/rancher/k3s/server/node-token')
ssh admin@192.168.0.<N> "export K3S_URL=https://192.168.0.60:6443 K3S_TOKEN='$TOKEN' \
  INSTALL_K3S_VERSION=v1.34.6+k3s1; curl -sfL https://get.k3s.io | sudo -E sh -s - agent"
```

Then add a `wN` A record to `/etc/bind/zones/db.k3s.lan` on LXC 111, bump the zone serial, and
`rndc reload k3s.lan`.

**Template 9000 does not carry this Mac's SSH key.** Its baked-in `authorized_keys` holds one
key commented `light@light-pc`, so a fresh clone answers `Permission denied (publickey,password)`
from the MacBook — the same reason .66/.67 were unreachable. VMs .60 and .65 work only because
the Mac key was added to them by hand after provisioning. Until the template is rebuilt, push the
key in through the guest agent (which works before SSH does):

```sh
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
ssh root@192.168.0.15 "qm guest exec <vmid> -- /bin/bash -c 'echo \"$PUBKEY\" >> /home/admin/.ssh/authorized_keys'"
```

Done for .61, .62 and .63 in Sep 2026. `qm guest exec` is also the way to debug a node that
boots but will not accept SSH — it reaches `systemctl`/`cloud-init` with no network login.
- **kubectl:** Dev box `~/.kube/config` is a symlink to `~/.kube/k3s-home.yaml` (server: 192.168.0.60:6443). `kubectl get nodes` works directly.
- **Built-in Traefik disabled** at install time (`--disable=traefik`). LAN `.lan` routes go through the homelab Traefik on LXC 114; **public** `*.eduindev.com` traffic goes through a separately installed Traefik in namespace `traefik` (Helm, see "## Public Edge"). `klipper-lb` (k3s ServiceLB) is kept but unused.

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

## Public Edge (Lightsail VPS + WireGuard)

Replaced frp (frps on the VPS + one `frpc` pod per namespace) in Oct 2026. Detail in
`services/k8s-edge/README.md` (cluster half) and `services/vps/README.md` (VPS half).

```
client ─443─▶ VPS Traefik (TLS, wildcard *.eduindev.com) ─▶ wg-easy:8000 ─DNAT─▶ 10.8.0.3:8000
          ─▶ traefik pod in ns traefik (wg0 = 10.8.0.3 is inside this pod) ─▶ Ingress ─▶ Service
client ─udp 7000─▶ wg-easy ─DNAT─▶ 10.8.0.3:7000 ─▶ IngressRouteUDP ─▶ lightchat/livekit:7000
client ─tcp 25/465/587/993─▶ VPS Traefik TCP (PROXY v2) ─▶ wg-easy:2525/4465/5587/9993 ─DNAT─▶
          10.8.0.3 ─▶ in-cluster entrypoints smtp/submissions/submission/imaps ─▶ email/stalwart
```

- **VPS:** `ssh-my-lightsail` (alias → `admin@51.44.40.82` with `~/.ssh/my-lightsail-private-key.pem`).
  Containers `traefik`, `wg-easy`, `portfolio` under `/home/admin/services/`. The forwarding
  is wg-easy labels (router `k8s`, priority 10) plus PostUp hooks in wg-easy's DB.
- **Cluster:** Helm release `traefik` (chart 41.7.1) in ns `traefik`, IngressClass `traefik`
  (default). The `traefik/wg0` Secret holds peer 10.8.0.3's config — not in git.
- **Publishing a host** = an Ingress rule in the app's CD repo. No DNS, cert or VPS change.
- **`coredns-custom`** forwards `.lan` to BIND (192.168.0.21), so pods now resolve `*.lan`.

Gotchas:

- **Restarting wg-easy = ~1 min public outage**: Traefik ignores the container until its
  healthcheck says `healthy`.
- **Upgrading the in-cluster Traefik = ~10 s outage** (`Recreate`, one replica on purpose —
  two pods would fight over peer 10.8.0.3).
- **ArgoCD never syncs `Endpoints`/`EndpointSlice`** (default `resource.exclusions`). External
  backends must be `ExternalName` Services (`allowExternalNameServices` is on).
- **Ingress needs a status address** or ArgoCD shows the app `Progressing` forever —
  `ingressEndpoint.ip: 51.44.40.82` in the values provides it.
- Lightsail firewall (Oct 2026): TCP 22/80/443/25/465/587/993, UDP 51820/7000. TCP 7000 (old
  frps) was closed when the mail ports were opened — `put-instance-public-ports` replaces the
  whole list, so always pass every port.
- **Hosts outside `*.eduindev.com`** (e.g. `*.takuteku.com`) need their own `Host()` router on
  the wg-easy labels with resolver **`letsencrypt-http`** (HTTP-01). The original `letsencrypt`
  resolver is Route53 DNS-01 with `AWS_HOSTED_ZONE_ID` pinned to the eduindev zone, so it cannot
  issue for any other domain.

---

## Email (takuteku.com, eduindev.com)

Self-hosted mail for **takuteku.com** and **eduindev.com**, built Oct 2026. Stalwart v0.16.26 (SMTP/IMAP/JMAP/CalDAV/
CardDAV) and Bulwark Webmail 1.15.0 run in k3s namespace `email`, deployed by ArgoCD app
`email-prod` from **`eduinlight-org/email-cd`** — that repo's README is the full runbook.

| What | Where |
|------|-------|
| Webmail | https://webmail.takuteku.com, https://webmail.eduindev.com (same Bulwark) |
| Stalwart admin / JMAP / DAV | https://mail.takuteku.com (`/admin`) |
| IMAP / submission / MX | mail.takuteku.com :993 / :465, :587 / :25 |
| Mailboxes | `it@takuteku.com` (aliases `postmaster@`, `abuse@`, `dmarc@` on both domains), `support@takuteku.com`, `contact@eduindev.com` |
| Credentials | `secrets.local.md` (untracked); k8s Secrets `email/{stalwart,bulwark,stalwart-backup}`; admin + SES SMTP also in SSM Parameter Store `/email/takuteku/*` (eu-west-3, free SecureString) |
| Backups | nightly 03:30 → Garage bucket `email-backups` (14 days) |

- **No inbound port at home.** Mail ports enter at the VPS and cross the WireGuard tunnel with
  PROXY protocol v2 on both hops, so Stalwart sees the real client IP (verified).
- **Outbound goes only through Amazon SES** (eu-west-3, production access granted Oct 2026,
  50k/day). IAM users: `stalwart-ses` (`ses:SendRawEmail` for `*@takuteku.com`) and
  `stalwart-route53` (takuteku.com zone only, for Stalwart's ACME DNS-01 and DKIM publishing).
- **Stalwart 0.16 has no config file to edit** — settings live in its DB and are declared in
  `email-cd/prod/stalwart/plan.ndjson`, applied by an ArgoCD PostSync Job with `stalwart-cli`.
  Gotchas found while building it:
  - Settings changes need a reload Action (the plan ends with `ReloadSettings` +
    `ReloadBlockedIps`), and **listener changes need a pod restart**.
  - Stalwart's scanner auto-ban bans the **TCP peer** for HTTP, i.e. the in-cluster Traefik pod
    — internet scanners got the whole HTTP side 403'd within minutes. `10.42.0.0/16` is an
    `AllowedIp` in the plan for that reason.
  - **Stalwart does not DKIM-sign; SES does.** SES rejects two `DKIM-Signature` headers (Stalwart
    defaults to Ed25519 + RSA) and rewrites `Message-ID`, which broke even a single Stalwart
    signature. `dkimManagement` is `Manual` with no keys; SES Easy DKIM signs `d=takuteku.com`.
- **Backups stop the server** (~1 min nightly): 0.16's only RocksDB backup is offline
  `--export`. The StatefulSet deliberately has no `replicas` field so ArgoCD selfHeal does not
  fight the scale-down.
- The `takuteku.com` apex has no A record; nothing in mail needs one.
- **eduindev.com is the same server**: a `Manual` domain in the plan whose MX and clients use
  `mail.takuteku.com`; its DNS is hand-written in the eduindev zone and SES verifies it separately.
  Bulwark calls JMAP from the browser, so CORS for both webmail origins is a Traefik Middleware
  (`email/stalwart-cors`), not a Stalwart header — Stalwart's static header can name one origin only.

---

## Taiga (pm.eduindev.com)

Taiga 6.10 project management, built Oct 2026. Kustomize manifests in
**`eduinlight-org/project-manager-cd`** (its README is the runbook), deployed by ArgoCD app
`project-manager-prod` into namespace `project-manager`. Public through the normal edge — one
Ingress, no DNS/cert/VPS change.

- Upstream taiga-docker layout, one Deployment per service; the nginx gateway shares the
  taiga-back pod so it can read static (copied from the image by an init container) and media.
- Postgres 16 StatefulSet `taiga-db` (10 Gi) and PVC `taiga-media` (10 Gi) are `local-path`,
  so back, async and the backup Job all land on the media volume's node.
- Secrets `taiga` and `taiga-backup` were made by hand; values in `secrets.local.md`.
- **Email is the console backend** (logged, not sent) until an SES SMTP user exists — steps in
  the repo README.
- Registration is closed. First admin:
  `kubectl -n project-manager exec -it deploy/taiga-back -c back -- python manage.py createsuperuser`.
- Backups nightly 04:00 → Garage bucket `taiga-backups` (pg_dump + media tarball, 14 days).

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

Alongside the native runner above, LXC 124 runs **two** containerised runners —
`gh-runner-docker` and `-2`, each capped at `mem_limit: 4608m` — from a locally built image
`lightnotes-gh-runner:22.04`. Compose project at `/opt/gh-runner-docker/`, mirrored in this
repo at `services/gh-runner-linux/` (see its README for the full picture).

- Labels `self-hosted,Linux,X64,docker,homelab,kubectl`, identical on both, so a job lands
  on any of them — they must stay interchangeable.
- The Docker socket is bind-mounted, so jobs share the LXC's daemon.
- **Cut from four to two on 2026-10-16 after CI took the whole host down.** Gradle and
  Kotlin daemons outlive the job that started them; four runners' worth of them, plus jest
  workers, held 11.4 GB in LXC 124 (then 12 GB + 8 GB swap) with **no job running**. That
  pushed the host to 61/62 GB with swap full, load ~176 and 92% I/O pressure — BIND on LXC 111
  stalled, so every `.lan` name timed out, and macOS cached the router's NXDOMAIN on top.
  The per-container `mem_limit` makes a runaway build OOM inside its own container instead.
  `runner-home-3`/`-4` volumes were left in place; GitHub still lists those runners as offline.
- **The whole toolchain is baked into the image** (Aug 2026): Rust stable + rustfmt/clippy +
  the wasm32 and aarch64-linux-android targets, `dx` 0.7.10, Temurin 17, the Android SDK/NDK,
  Node 22, Playwright 1.49.1 + chromium, `gh`/`jq`/`yq`/`kubectl`/`kustomize`/`actionlint`,
  and the AppImage/deb/rpm packaging stack. The lightchat harness's `scripts/ensure-tools.sh`
  only *verifies* and fails the job by name — provisioning is this Dockerfile's job.
- **`clang` + `libclang-dev`** were added Sep 2026. Nothing calls `clang` directly, but any
  crate whose build script uses `bindgen` dlopens `libclang.so`; lightchat reaches it through
  `v4l2-sys-mit` and failed with `Unable to find libclang` after compiling ~800 of 899 crates.
  `clang-sys` globs for the library instead of asking the compiler, so the Dockerfile asserts
  the glob matches. `libclang-dev` (not just `clang`) is the package — it carries the `.so` and
  the builtin headers.

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

`up -d` recreates both; volumes (registrations, `_work`, gradle/bun caches) survive.
Rebuild while idle. For a minute afterwards each logs `Runner connect error: Conflict` while
GitHub's old session lease expires — self-healing.

**Cargo registry perms:** `CARGO_HOME=/usr/local/cargo` is root-owned, so it is opened with
`chmod -R a+rwX` — **never `a+w`**. Crate tarballs keep their own modes; `fnv-1.0.7` ships
`lib.rs` at 0660, and `a+w` makes that 0662: writable, still unreadable, and CI dies with
`couldn't read .../fnv-1.0.7/lib.rs: Permission denied (os error 13)` partway through a build
while `cargo`/`rustc`/`dx --version` all look fine. The Dockerfile now asserts readability at
build time. Repair a live container with
`docker exec -u root <c> chmod -R a+rwX /usr/local/cargo /usr/local/rustup`.

**`$CARGO_HOME/bin` holds only symlinks, on purpose** (Sep 2026). `Swatinem/rust-cache@v2`
(`cache-bin` defaults to true) deletes every *regular file* in `$CARGO_HOME/bin` in its post
step — its keep-list comes from `.crates2.json` minus whatever already existed at cache-restore
time, which is exactly what this image ships, so the list is empty. It emptied
`/usr/local/cargo/bin` on `gh-runner-docker-2`, leaving the fourteen rustup proxies (`cargo`,
`rustc`, …) dangling and jobs reporting
`this runner is missing 2 tool(s): cargo target:wasm32-unknown-unknown` — while
`/usr/local/rustup` sat fully intact, wasm32 std included. It hits **one runner at a time**,
whichever took that job, so it looks like drift rather than a bad image. The cleanup skips
symlinks, so the real `rustup` and `dx` now live in `/usr/local/bin` with symlinks left behind;
the Dockerfile asserts `find $CARGO_HOME/bin -type f` is empty. A dangling proxy reports as
*absent*, never broken — check `readlink -f /usr/local/cargo/bin/cargo`, not just `command -v`.
`docker compose up -d --force-recreate <name>` repairs a hit container (the deletions are in the
writable layer; the registration is in the volume).

**Playwright:** `/opt/ms-playwright` needs `chmod -R a+rwX`, not `a+rX` — a root-owned browser
cache reads fine and then fails any in-job `playwright install` with
`EACCES ... mkdir '/opt/ms-playwright/__dirlock'`. The browser build is version-locked
(1.49.1 → `chromium-1148`); a mismatched one sits unused, so verify with
`node -e 'console.log(require("playwright").chromium.executablePath())'` rather than checking
that some chromium exists.

**k8s access:** both share a read-only kubeconfig at `/srv/gh-runner/kube/config` →
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
