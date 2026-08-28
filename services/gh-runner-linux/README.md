# Linux GitHub Actions Runners (LXC 124)

Four containerised `actions/runner` instances on LXC 124 (`github-runner`, 192.168.0.28),
all from one locally built image. Mirrors `/opt/gh-runner-docker/` on the LXC.

| | |
|---|---|
| Image | `lightnotes-gh-runner:22.04` (Ubuntu 22.04, built here — not pulled) |
| Containers | `gh-runner-docker`, `-2`, `-3`, `-4` |
| Registered to | `https://github.com/eduinlight-org` (org-level) |
| Labels | `self-hosted,Linux,X64,docker,homelab` (identical on all four) |
| Runner version | 2.336.0 (`RUNNER_VERSION` build arg) |
| Docker | socket bind-mount, `group_add: 996` — jobs share the LXC's daemon |

There is also a **native** runner on the same LXC at `/opt/actions-runner`
(`github-runner-lxc124`, systemd unit `actions.runner.eduinlight-org.github-runner-lxc124`).
It predates these containers and is a separate registration.

```sh
ssh root@192.168.0.15
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose ps'
pct exec 124 -- docker logs --tail 20 gh-runner-docker
```

## Baked-in tools

The `lightchat` harness ships `scripts/ensure-tools.sh`, which **verifies** the CLI tools a
job needs are on PATH and fails the job by name if one is missing — it installs nothing, by
design. The Dockerfile is the other half of that contract:

| Tool | Version |
|---|---|
| `gh` | 2.76.2 |
| `yq` | v4.44.3 |
| `jq` | 1.7.1 (shadows Ubuntu's 1.6) |
| `kubectl` | v1.31.3 |
| `kustomize` | v5.4.3 |
| `actionlint` | 1.7.7 |

Each is an `ARG`, so a one-off can be overridden at build time without editing the file.
Keep them in step with `docs/SETUP.md` in the harness repo.

### Why /usr/local/bin and not ~/.local/bin

Each container mounts a named volume (`runner-home`, `runner-home-2`, ...) over
`/home/runner`, so **anything the image writes under `/home/runner` is invisible at run
time**. Tools have to go somewhere outside it.

That cuts the other way too. `PATH` is
`~/.cargo/bin:~/.local/bin:/usr/local/sbin:/usr/local/bin:...`, so a copy left in a volume's
`~/.local/bin` by the old install-on-demand script **wins over the image's**. Those were
cleared out of all four volumes on 2026-08-28; if a runner ever seems to be on a stale
version, look there first:

```sh
pct exec 124 -- docker exec gh-runner-docker bash -lc 'ls ~/.local/bin; command -v gh'
```

The Rust toolchain and the Android SDK also live in the volumes, installed at job time —
they are *not* in the image.

## Rebuilding

```sh
ssh root@192.168.0.15
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose build runner && docker compose up -d'
```

`up -d` recreates all four. Volumes survive, so registrations, caches and toolchains do.
Do it while the runners are idle (`docker logs --tail 1 <container>` should say
"Listening for Jobs"). For a minute or two afterwards each container logs
`A session for this runner already exists` / `Runner connect error: Conflict` while
GitHub's old session lease expires — it retries and reconnects on its own.

## Adding a runner

Add a `runner-N` service and a matching `runner-home-N` volume to `docker-compose.yml`
(copy `runner-2`), then `docker compose up -d`. Only the first service carries `build:`;
the rest reuse the image. `entrypoint.sh` registers on first start using `ACCESS_TOKEN`
from `runners.env` and writes `.runner` into the volume, so restarts do not re-register.

Secrets are not in this repo — see `.env.example`.
