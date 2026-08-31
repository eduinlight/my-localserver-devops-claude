# Media Stack (LXC 104)

Jellyfin + the *arr* suite + qBittorrent, all sharing one `/data` tree so that
Sonarr/Radarr import by **hardlink** instead of copying.

- **LXC:** 104 `media`, pool `tools`, 4 cores / 8 GB
- **IP:** 192.168.0.22
- **Compose file on host:** `/home/admin/docker-compose.yaml`
- **Access:** `ssh root@192.168.0.15` then `pct exec 104 -- bash -c '...'`

## Services

| Container | Port | Hostname (via Traefik) |
|-----------|------|------------------------|
| jellyfin | 8096 | media.lan |
| radarr | 7878 | radar.media.lan |
| sonarr | 8989 | sonar.media.lan |
| qbittorrent | 8080 | qbittorrent.media.lan |
| seerr | 5055 | request.media.lan |
| bazarr | 6767 | — (direct :6767) |
| prowlarr | 9696 | — (direct :9696) |
| flaresolverr | 8191 | — (internal, used by prowlarr) |

## Storage layout

Two different disks, deliberately:

| Path in LXC | Backing store | Size | Holds |
|-------------|---------------|------|-------|
| `/mnt/media` | `local-lvm:vm-104-disk-2` (NVMe, mp1) | 812 GB vol, ~2 GB used | app configs — SQLite DBs for jellyfin/sonarr/radarr/… |
| `/mnt/media/data` | `/dev/sda1` ext4, bind-mounted (mp2) | **7.3 TiB** | the library: `downloads`, `movies`, `shows`, `subtitles` |

`mp2` is a **nested** mountpoint underneath `mp1` — the more specific mount wins, so
`/mnt/media/data` comes off the HDD while its siblings (`jellyfin/config`, …) stay on
the NVMe. This is why the compose file needed no changes when the library moved: the
container-side paths are identical.

Configs stay on NVMe on purpose. They are only ~2 GB but they are SQLite, and putting
those databases on a 7200 rpm spinner makes library scans and the web UIs noticeably
slower.

### The 8 TB library disk

Seagate ST8000NT001 (IronWolf Pro, 7200 rpm, CMR) on SATA, single full-disk GPT
partition, ext4, mounted on the **PVE host** at `/mnt/media-8tb` and bind-mounted in.

```sh
# host /etc/fstab
UUID=b60e11de-138a-49f8-aa87-e38b291d6544  /mnt/media-8tb  ext4  defaults,noatime,nofail  0  2
```

```
# /etc/pve/lxc/104.conf
mp2: /mnt/media-8tb,mp=/mnt/media/data
```

It was formatted with two non-default flags that together reclaim ~500 GB:

```sh
mkfs.ext4 -m 0 -T largefile -L media8t /dev/sda1
```

- `-m 0` — drops the 5% reserved-for-root block reserve. That reserve exists to keep a
  *root* filesystem usable when full; on a pure data disk it just costs **~400 GB**.
- `-T largefile` — 1 inode per MB (7.6 M inodes) instead of the default 1 per 16 KB
  (~500 M inodes). The library holds under a thousand very large files, so the default
  inode table would waste **~120 GB**. Result: `df` shows the full 7.3 T.

`nofail` matters — without it the PVE host refuses to boot if the drive ever dies or is
unplugged.

### Ownership and the unprivileged idmap

LXC 104 is **unprivileged** with the default idmap (offset 100000), so container UID 0 is
host UID 100000 and container UID 1000 (`admin`, the PUID the containers run as) is host
UID 101000. A host bind mount is **not** idmapped automatically — a freshly created
directory shows up inside the container as `nobody:nogroup` (see `mp0` / `/mnt/usb`, which
has exactly that problem).

So the host-side mountpoint must be chowned to the shifted UID:

```sh
chown 100000:100000 /mnt/media-8tb && chmod 777 /mnt/media-8tb
```

and anything copied in must preserve the shifted UIDs — hence `--numeric-ids` below.
The host has no user for UID 101000, so without it rsync maps everything to root and the
containers lose write access.

## Hardlinks are load-bearing

`downloads`, `movies` and `shows` must live on **one filesystem**. Sonarr/Radarr "import"
a finished download by hardlinking it into the library, so the file exists in both trees
while occupying the space once and the torrent keeps seeding. Split them across two
filesystems and the arrs silently fall back to copying — double the space, and the seeding
copy drifts.

Currently 350 of 789 files are hardlinked: 1.15 TB apparent, 690 GB on disk.

Any move of this tree therefore needs `rsync -H`:

```sh
rsync -aHAX --numeric-ids --info=progress2 /source/data/ /mnt/media-8tb/
```

Verify afterwards by comparing *apparent* bytes and the nlink>1 count on both sides —
matching `du` output alone will not catch lost hardlinks, because `du` dedupes them:

```sh
find <tree> -type f -printf '%s\n' | awk '{s+=$1} END {print s}'   # must match exactly
find <tree> -type f -links +1 | wc -l                              # must match exactly
```

Note also that per-directory `du` is **not** stable for a hardlinked tree: whichever
directory is traversed first is charged for the shared inode. `du -sh downloads movies` in
one invocation gives different per-directory numbers than two separate invocations. Only
the total is meaningful.

## Gotchas

- **Don't move files into the library by hand.** Sonarr/Radarr track paths in their DBs;
  a manual move orphans the entry and Bazarr then can't find the video to match subtitles
  against. Use the app's own rename/move.
- **`docker compose down` before any storage surgery.** qBittorrent writes continuously.
- The old `mp0: /mnt/usb` bind mount points at a directory on `pve-root`, not a real USB
  disk, and is visible in the container as `nobody:nogroup`. It is unused by the stack.

## Boot-race guard

`mp2` is a host bind mount, and two things conspire against it on a cold boot:
the fstab entry is `nofail` (so `local-fs.target` does not wait for the disk), and
`pve-guests.service` carries no `local-fs` ordering at all. LXC 104 has `onboot: 1`.
So a boot that outruns the SATA disk would bind-mount the bare, empty `/mnt/media-8tb`
directory — and Sonarr/Radarr would scan an empty library and mark the entire collection
missing. That is a slow, annoying recovery.

Two mitigations, belt and braces:

1. **Ordering** — the fstab entry carries `x-systemd.before=pve-guests.service`, so if the
   mount is going to happen at all, it happens before any guest starts.
2. **A pre-start hook that refuses to start the container** if the library isn't really
   there. `nofail` means a genuinely dead disk still lets the host boot and every *other*
   guest start; only LXC 104 is held back.

```sh
pvesm set local --content iso,vztmpl,backup,snippets      # one-time
# media-mount-guard.pl -> /var/lib/vz/snippets/ on the PVE host
pct set 104 --hookscript local:snippets/media-mount-guard.pl
```

The guard fails closed on both "not mounted" and "mounted but empty" (the second matters
because an empty mountpoint directory is indistinguishable from a mounted-but-blank disk
by path alone). Verified all three ways — unmounted, tmpfs mounted over it, and healthy.

> Writing this file onto the host via `ssh root@host '... <<"EOF" ...'` silently corrupts
> it: the outer single quotes end at the first `'` inside the Perl source, so every quoted
> string loses its quotes and the script dies with `Bareword ... not allowed`. Because the
> hook fails closed, that in turn blocks the container from starting at all. `scp` the file
> instead, and `perl -c` it on the host.
