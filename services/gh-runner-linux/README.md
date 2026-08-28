# Linux GitHub Actions Runners (LXC 124)

Four containerised `actions/runner` instances on LXC 124 (`github-runner`, 192.168.0.28),
all from one locally built image. Mirrors `/opt/gh-runner-docker/` on the LXC.
Provisioning follows `install-on-runners.md`; section numbers below refer to it.

| | |
|---|---|
| Image | `lightnotes-gh-runner:22.04` (Ubuntu 22.04, built here — not pulled) |
| Containers | `gh-runner-docker`, `-2`, `-3`, `-4` |
| Registered to | `https://github.com/eduinlight-org` (org-level) |
| Labels | `self-hosted,Linux,X64,docker,homelab,kubectl` (identical on all four) |
| Runner version | 2.336.0 (`RUNNER_VERSION` build arg) |
| Docker | socket bind-mount, `group_add: 996` — jobs share the LXC's daemon |

There is also a **native** runner on the same LXC at `/opt/actions-runner`
(`github-runner-lxc124`, systemd unit `actions.runner.eduinlight-org.github-runner-lxc124`).
It predates these containers, is a separate registration, and is *not* provisioned from this
image — it has none of the tools below.

```sh
ssh root@192.168.0.15
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose ps'
pct exec 124 -- docker logs --tail 20 gh-runner-docker
```

## The two rules that decide where everything goes

Both follow from `docker-compose.yml` mounting a named volume over `/home/runner`.

**1. Nothing installs under `/home/runner`.** The volume masks it at run time. So
`CARGO_HOME=/usr/local/cargo`, `ANDROID_HOME=/opt/android-sdk`,
`PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` — not the `~/.cargo`, `~/android-sdk`,
`~/.cache/ms-playwright` the doc writes for a bare-metal runner. The kubeconfig is the
exception, and works because a bind-mount at `/home/runner/.kube` is nested *inside* the
volume mount and the more specific mount wins.

**2. Everything must be on PATH for a non-login, non-interactive shell.** Actions runs steps
as `bash --noprofile --norc`, which reads neither `.bashrc` nor `.profile`. The `ENV` lines in
the Dockerfile are the container equivalent of the doc's §1 systemd override. This is easy to
get wrong in a way that looks fine: before this image, `cargo` and `dx` were installed on a
runner, resolved perfectly from an interactive `docker exec`, and were absent from every job.

Verify the way a job sees it, never with `bash -lc`:

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker bash --noprofile --norc -c 'command -v cargo dx kubectl'
```

## What is in the image

| Tool | Version | §|
|---|---|---|
| Rust (`stable`, floor 1.94) + `rustfmt`, `clippy` | 1.98.0 today | 3.2 |
| targets `wasm32-unknown-unknown`, `aarch64-linux-android` | — | 3.2 |
| `dx` (dioxus-cli) | 0.7.10 | 3.3 |
| Temurin JDK | 17 | 3.5 |
| Android cmdline-tools / NDK / platform / build-tools | 13114758 / 27.2.12479018 / 34 / 34.0.0 | 3.5 |
| `gh` | 2.76.2 | 3.1 |
| `jq` | 1.7.1 — shadows jammy's 1.6, which is below the §2 floor | 3.1 |
| `yq` | v4.44.3 | — |
| `actionlint` | 1.7.7 | — |
| `kubectl` / `kustomize` | v1.31.3 / 5.4.3 | 4.1 |
| Node.js | 22.x | 4.2 |
| Playwright chromium + system libs | 1.49.1 | 4.3 |
| `awscli` | apt | 4.4 |
| AppImage/deb/rpm packaging, webkit stack, `openssl` | apt | 3.1, 3.6 |

Versions are `ARG`s — override at build time without editing the file. Keep them in step with
§2 of the doc; nothing enforces them automatically.

`APPIMAGE_EXTRACT_AND_RUN=1` is set because the container has no FUSE (that would need
`--device /dev/fuse --cap-add SYS_ADMIN`).

Chromium's system libraries come from `playwright install-deps`, not the package list in §4.3
— that list is the 24.04 `t64` spelling and does not resolve on jammy.

## kubectl access

All four carry the `kubectl` label and share one read-only kubeconfig at
`/srv/gh-runner/kube/config` on the LXC, mounted to `/home/runner/.kube`. §4 puts this on one
machine; here it is on all four, so `preview-deploy.yml` — which targets
`[self-hosted, Linux, homelab, kubectl]` — can land anywhere.

The credential is **not** the human admin kubeconfig. It is a dedicated k3s ServiceAccount,
`gh-runner-deployer` in `kube-system`, with a non-expiring token and a `cluster-admin` binding
(preview deploys create and delete whole namespaces). Revoke CI's access without touching
anything else:

```sh
kubectl delete clusterrolebinding gh-runner-deployer
kubectl -n kube-system delete sa gh-runner-deployer secret gh-runner-deployer-token
```

## Rebuilding

```sh
ssh root@192.168.0.15
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose build runner && docker compose up -d'
```

`up -d` recreates all four. Volumes survive, so `_work`, gradle and bun caches do.
Do it while the runners are idle (`docker logs --tail 1 <container>` should say
"Listening for Jobs"). For a minute or two afterwards each container logs
`A session for this runner already exists` / `Runner connect error: Conflict` while
GitHub's old session lease expires — it retries and reconnects on its own.

`dx` is the slowest layer by far and is deliberately last, so changing its version does not
rebuild Rust, the Android SDK or Playwright.

## ⚠️ Re-registration is not possible unattended

`entrypoint.sh` accepts either:

- `ACCESS_TOKEN` — a PAT, exchanged for a fresh registration token on every start. **Not set
  anywhere on this host.**
- `RUNNER_TOKEN` — a registration token: single-use, valid about an hour. This is what `.env`
  and `runners.env` actually hold, dated 2026-08-06 and 2026-08-27. Both are long expired.

Day to day nothing is wrong — a registered runner authenticates with the `.credentials` in its
own volume and never reads either variable. But **a runner whose volume is lost cannot
re-register**: `entrypoint.sh` exits with "no registration token available" and the container
restart-loops until someone intervenes.

Recovery needs no stored secret, because the dev box's `gh` already carries `admin:org`:

```sh
TOKEN=$(gh api -X POST /orgs/eduinlight-org/actions/runners/registration-token --jq .token)
ssh root@192.168.0.15 "pct exec 124 -- bash -c 'printf \"RUNNER_TOKEN=$TOKEN\\n\" > /opt/gh-runner-docker/runners.env'"
# then, within the hour:
ssh root@192.168.0.15 "pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose up -d'"
```

**Do not park a long-lived PAT here as `ACCESS_TOKEN`.** `env_file` injects it into the
container environment, where every job step can read it — verified: a job shell finds
`RUNNER_TOKEN` in its own `env`. Handing an `admin:org` PAT to arbitrary PR code is a poor
trade for unattended recovery.

Labels are fixed at registration, so `RUNNER_LABELS` only affects a *fresh* registration. To
change labels on runners that are already registered, use the API instead — no token in the
container needed, and no re-registration:

```sh
gh api -X POST /orgs/eduinlight-org/actions/runners/<id>/labels -f 'labels[]=kubectl'
```

## Adding a runner

Add a `runner-N` service and a matching `runner-home-N` volume to `docker-compose.yml`
(copy `runner-2`), then `docker compose up -d`. Only the first service carries `build:`;
the rest reuse the image. Registration on first start needs a **live** `RUNNER_TOKEN` — see above.

Secrets are not in this repo — see `.env.example`.

## Stale toolchains in the volumes

Before this image, Rust, `dx` and the Android SDK were installed by hand into each container's
volume, unevenly — `dx` existed on one runner of four. Those copies are now dead: jobs resolve
everything from `/usr/local` and `/opt`. They still occupy roughly 9 GB across the four volumes
(`~/.cargo`, `~/.rustup`, `~/android-sdk`) and can be removed. `.gradle`, `.bun` and `_work`
are live caches — leave them.
