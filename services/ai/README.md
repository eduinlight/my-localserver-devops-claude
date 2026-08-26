# AI Stack (LXC 118 `ai`)

One privileged LXC holding everything that touches the GPU: llama.cpp (via
llama-swap) for text and embeddings, ComfyUI for image generation. Replaced the
three-container pool (113 `ollama-webui`, 117 `stable-diffusion`, 118 `ollama`)
in August 2026.

- **LXC:** 118 `ai`, pool `ia`, **privileged**, 12 cores / 24 GB cap / 200 GB
- **IP:** 192.168.0.118
- **Compose file on host:** `/home/admin/docker-compose.yaml`
- **GPU:** NVIDIA RTX 3050, **6144 MiB** — the binding constraint on everything below

| Purpose | Address |
|---------|---------|
| Chat UI + OpenAI API | http://ai.lan (Traefik) — redirects to `/ui` |
| OpenAI API direct | `http://192.168.0.118:8080/v1/...` |
| ComfyUI | http://images.ai.lan (Traefik) — only while it is running |
| ComfyUI direct | `http://192.168.0.118:8188` |

## Why LXC and not a VM

Recorded because the question recurs. Passing the GPU to a VM means vfio-binding
it: the host must blacklist the nvidia driver, `nvidia-smi` on PVE stops working,
and **no LXC can ever use the GPU again** — it belongs to that one VM. VM memory
is also *reserved* rather than capped, and the host runs near its 62 GB. With
LXC the driver stays on the host, costs nothing at runtime, and the card is
shared by bind-mounting `/dev/nvidia*`.

GPU sharing between LXCs was never the problem. 117 and 118 both had working
passthrough simultaneously. The real constraint is 6 GB of VRAM with no
arbitration — which is what llama-swap and `ai-gpu` now provide.

## VRAM policy

Only one thing holds the card at a time:

- **Between LLMs** — llama-swap's default routing runs exactly one model, and
  swaps on request (~5 s).
- **LLM idle** — each model has `ttl: 600`, so the card frees itself after ten
  idle minutes. llama.cpp has no keep-alive of its own; this ttl is the whole
  mechanism.
- **LLM ↔ ComfyUI** — `ai-gpu comfy-up` forces an unload first, rather than
  waiting up to ten minutes for the ttl. ComfyUI is behind a compose profile so
  it never starts on its own and never on boot.

```sh
ai-gpu status      # who holds the GPU right now
ai-gpu comfy-up    # unload LLMs, start ComfyUI
ai-gpu comfy-down  # stop ComfyUI, card returns to llama-swap
ai-gpu unload      # free VRAM without starting ComfyUI
```

`ai-gpu` lives at `/usr/local/bin/ai-gpu` (source in this directory). Note
`pct exec` uses a minimal PATH, so call it as `/usr/local/bin/ai-gpu` from the
PVE host.

## Models

Text models live in `/srv/models`, ComfyUI's in `/srv/comfyui/models`. Measured
figures, all fully GPU-offloaded (`-ngl 99`):

| Model ID | File | VRAM | Speed |
|----------|------|------|-------|
| `qwen3.5` | Qwen3.5-9B-IQ4_XS.gguf (5.2 GB) | ~5034 MiB | ~30 tok/s |
| `qwen2.5` | qwen2.5-7.6b-q4_k_m.gguf (4.7 GB) | ~4634 MiB | ~32 tok/s |
| `bge-m3` | bge-m3-566m-f16.gguf (1.2 GB) | ~687 MiB | embeddings only |

SDXL (`juggernautXL_v8Rundiffusion`) peaks at ~5064 MiB and renders 1024×1024 /
15 steps in **~26 s warm**. The first render after starting ComfyUI takes several
minutes — that is the 7 GB checkpoint being read from disk, not the GPU.

**Quantization is not free choice here.** Qwen3.5 at Q4_K_M is 5.7 GB and will
not fit alongside a KV cache; IQ4_XS at 5.2 GB does. Raising `-c` in
`llama-swap.yaml` grows the KV cache and can push a model over the edge —
re-measure with `nvidia-smi` after any change.

### Why qwen3.5 was re-downloaded

The old ollama store's qwen3.5 blob is **not loadable by llama.cpp**. Ollama
writes its own engine's metadata:

```
error loading model hyperparameters:
key qwen35.rope.dimension_sections has wrong array length; expected 4, got 3
```

The replacement is unsloth's llama.cpp-native GGUF. `qwen2.5` (arch `qwen2`) and
`bge-m3` (arch `bert`) were standard and were reused directly from the ollama
blobs by hardlink — no copy, no re-download.

## Gotchas

These cost real time to find; do not undo them casually.

**1. runc must stay on 1.3.x.** `containerd.io` 2.x ships runc 1.4.x, which
writes `net.ipv4.ip_unprivileged_port_start` at container init. LXC blocks that
and *every* container fails:

```
error during container init: open sysctl net.ipv4.ip_unprivileged_port_start
file: reopen fd 8: permission denied
```

`containerd.io` is pinned to `1.7.28-1~debian.12~bookworm` (runc 1.3.0) and
`apt-mark hold`-ed, matching the other Docker LXCs on this host. Docker CE is
held at 28.5.2 alongside it. This is not privileged-vs-unprivileged — the mounts
are identical to the working unprivileged LXCs.

**2. GPU needs `--gpus all` *and* explicit `devices:`.** `no-cgroups = true` in
`/etc/nvidia-container-runtime/config.toml` is required inside LXC, but it makes
nvidia-container-cli skip device cgroup setup, so runc never grants access:

```
Failed to initialize NVML: Unknown Error
```

The `devices:` list in the compose file is what adds the cgroup rules. Both the
`deploy.resources.reservations.devices` block and the `devices:` list are
required.

**3. Container driver must match the host exactly.** Host is **580.178.04
(CUDA 13.0)**, installed from the `.run` installer **with `--dkms`**, so it
rebuilds across kernel upgrades. The LXC has the same version's userspace,
installed with `--no-kernel-module`. After any host driver change, re-run the
matching `.run` inside the LXC:

```sh
pct exec 118 -- bash -c \
  './NVIDIA-Linux-x86_64-<version>.run --silent --no-kernel-module --no-x-check'
```

A copy of the 580.178.04 installer is kept at `/root/ai-backups/` on the PVE host.

**4. CUDA 12.4 was too old.** The previous driver (550.90.07) provided CUDA 12.4;
current llama.cpp images require **12.8+**. `NVIDIA_DISABLE_REQUIRE=1` does *not*
help — CUDA forward compatibility is a datacenter-GPU feature and the RTX 3050
reports `forward compatibility was attempted on non supported HW`. The Vulkan
image is not a workaround either: it silently falls back to CPU because the
`.run` installer ships no Vulkan ICD loader.

**5. llama-swap's config is mounted as a *directory*, deliberately.** Bind-mounting
the single file pins an inode: any editor that writes a replacement rather than
editing in place (`vim`, `sed -i`, `pct push`) leaves the container reading the
old inode. The config watcher then never fires and llama-swap silently keeps the
previous settings — the failure is invisible, since the file on the host looks
correct. Mounting `/srv/llama-swap` onto `/etc/llama-swap/config` avoids it. If
you ever change this back to a file mount, config edits will appear to do nothing.

**6. ComfyUI logs a harmless `IMPORT FAILED`.** The image symlinks
`/opt/comfyui-manager` into `custom_nodes` as if it were a legacy node, but
ComfyUI-Manager 4.x is a pip package with no top-level `__init__.py`. ComfyUI
itself is unaffected. The `-comfyui-manager-` tags behave identically, so there
is nothing to switch to. Install custom nodes by hand into
`/srv/comfyui/custom_nodes`.

## Layout on the LXC

```
/home/admin/docker-compose.yaml     both services
/srv/llama-swap/config.yaml         llama-swap.yaml from this directory
/srv/models/                        GGUFs
/srv/comfyui/{models,custom_nodes,input}/
/mnt/shared-outputs                 -> /mnt/shared/ai-outputs on the PVE host
/usr/local/bin/ai-gpu               GPU handoff helper
```

Renders land on host storage (`/mnt/shared/ai-outputs`), so they survive the
container. The directory carries over from the old Fooocus setup, including its
existing renders — it was just renamed from `fooocus-outputs`.

## Operations

```sh
ssh root@192.168.0.15
pct exec 118 -- bash -c 'cd /home/admin && docker compose ps'
pct exec 118 -- docker logs --tail 50 llama-swap
pct exec 118 -- bash -c 'cd /home/admin && docker compose up -d llama-swap'
pct exec 118 -- /usr/local/bin/ai-gpu status
```

llama-swap watches its config file and reloads on change, so editing
`/srv/llama-swap/config.yaml` does not require a restart.

Pulling: ghcr.io works directly. Only Docker Hub is blackholed by the ISP, which
`/etc/docker/daemon.json` routes through `mirror.docker.lan`.

## Decommissioned

- **LXC 117 `stable-diffusion`** — Fooocus, whose `fooocus-api.service` had been
  crash-looping for ~5 months (152,000+ restarts) on a stale container-name
  conflict, leaving `images.ai.lan` and `api.images.ai.lan` dead. Its only real
  assets — the SDXL checkpoint and one LoRA — were moved to `/srv/comfyui/models`
  and checksum-verified. Freed ~70 GB.
- **LXC 113 `ollama-webui`** — open-webui. Its compose declared no volumes, so
  its 22 chat histories only ever lived in the container's writable layer; the
  SQLite DB was copied to `/root/ai-backups/open-webui-chats-2026-08-26.db` on
  the PVE host before removal.
- **ollama on 118** — service, binary and model store removed. The 18 GB
  `qwen3:30b-a3b` MoE was dropped deliberately.

Rollback point for 118's pre-migration (ollama) state:
`/var/lib/vz/dump/vzdump-lxc-118-2026_08_26-12_11_40.tar.zst` (22 GB).
