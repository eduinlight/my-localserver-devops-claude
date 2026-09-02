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

## The registry must be readable, not just writable

Moving `CARGO_HOME` to `/usr/local/cargo` makes the registry root-owned, so it has to be opened
up for the runner user. It must be **`chmod -R a+rwX`**, never `a+w`:

```
error: couldn't read `/usr/local/cargo/registry/src/.../fnv-1.0.7/lib.rs`:
Permission denied (os error 13)
```

Crate tarballs carry their own mode bits and cargo preserves them on extraction. `fnv-1.0.7`
ships `lib.rs` at `0660`, which `a+w` turns into `0662` — writable by the runner and still
unreadable. It was the only such file among ~35,000 in the registry, so a smoke test that
compiles an ordinary crate passes and CI dies only when it reaches that one.

`cargo`, `rustc` and `dx` all print correct versions the whole time, which is what makes this
worth a build-time assertion rather than a version check. The Dockerfile fails the build if
anything under `CARGO_HOME` or `RUSTUP_HOME` lacks `o+r`. To check a running container:

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker bash --noprofile --norc -c \
  'find /usr/local/cargo /usr/local/rustup ! -perm -o+r -print -quit'
```

Empty output is correct. To repair one in place without a rebuild:

```sh
pct exec 124 -- docker exec -u root gh-runner-docker chmod -R a+rwX /usr/local/cargo /usr/local/rustup
```

The capital `X` sets the execute bit on directories only — that is what keeps the registry
traversable without marking every source file executable.

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

## Playwright: the cache must be writable, and the version must match

Two separate traps, both silent.

**Writable.** `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` is populated by root at build time,
so it has to be opened with `chmod -R a+rwX` — `a+rX` leaves the browser readable and present
while any in-job `playwright install` dies with:

```
EACCES: permission denied, mkdir '/opt/ms-playwright/__dirlock'
```

**Matching build.** Playwright resolves a *version-specific* directory — 1.49.1 wants
`chromium-1148` — and a browser from another release sits in that directory unused. Checking
that "a chromium is there" proves nothing. Ask playwright itself:

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker bash --noprofile --norc -c \
  'node -e "console.log(require(\'playwright\').chromium.executablePath())"'
```

That path must exist and be executable. Bump `PLAYWRIGHT_VERSION` and the browser in the same
change. The Dockerfile asserts both at build time.

## `$CARGO_HOME/bin` must contain nothing but symlinks

`Swatinem/rust-cache` (the lightchat workflows use `@v2`, where `cache-bin` defaults to true)
runs a cleanup in its post step that **deletes regular files from `$CARGO_HOME/bin`**. It builds
its keep-list from `.crates2.json` and then subtracts every binary that was already present when
the cache was restored — which is exactly the set this image ships, so the list comes out empty
and it deletes all of them.

On 2026-09-01 that emptied `/usr/local/cargo/bin` on `gh-runner-docker-2`: `rustup` and `dx`,
the only two regular files there, were removed. The fourteen rustup proxies (`cargo`, `rustc`,
`rustfmt`, `clippy-driver`, …) are symlinks to `rustup`, so they survived — and dangled. Jobs
then failed with:

```
Error: this runner is missing 2 tool(s) the job needs: cargo target:wasm32-unknown-unknown
```

which is misleading twice over: `/usr/local/rustup` was completely intact, wasm32 std included,
and the runner had not been "provisioned by hand" wrong — it had been *un*provisioned by the job
before it. Only the runner that happened to take that job was affected, which is why this
presents as one broken runner out of four rather than a bad image.

The cleanup skips symlinks (it tests `dirent.isFile()`), so the fix is to leave it nothing to
delete: the real `rustup` and `dx` live in `/usr/local/bin` and `$CARGO_HOME/bin` holds symlinks
to them. The proxies still work — `cargo` → `rustup` → `/usr/local/bin/rustup`, and rustup
dispatches on the basename it was invoked as, which the extra hop does not change. The Dockerfile
asserts the directory holds zero regular files at build time.

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker-2 bash --noprofile --norc -c \
  'find /usr/local/cargo/bin -type f'
```

Empty output is correct. If a future tool does land there as a regular file, it is one
`rust-cache` post step away from disappearing.

A job hitting a *dangling* proxy reports the tool as absent, never as broken, so check the link
target and not just `command -v`:

```sh
pct exec 124 -- docker exec -u runner gh-runner-docker-2 bash --noprofile --norc -c \
  'readlink -f /usr/local/cargo/bin/cargo && cargo --version'
```

Recreating the container (`docker compose up -d --force-recreate <name>`) also repairs this,
since the deletions live in the writable layer and the registration lives in the volume. That is
the recovery; the symlink layout is what stops it recurring.

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

To make that case unattended instead, install a PAT as `ACCESS_TOKEN` — `entrypoint.sh`
prefers it and mints a fresh registration token on every start:

```sh
pct exec 124 -- bash -c 'read -rs T && printf %s "$T" | /opt/gh-runner-docker/set-runner-pat.sh'
```

The helper validates the token against the org before writing anything, backs up both env
files, and writes them 0600. It reads stdin rather than argv so the value misses shell history
and the process list.

After installing a token, **recreate the containers** — `env_file` is injected at create
time, so a running container keeps the token it was created with:

```sh
pct exec 124 -- bash -c 'cd /opt/gh-runner-docker && docker compose up -d'
```

This path is verified, not assumed: on 2026-08-28 runner-4's registration was deleted and the
container restarted with no human input. It minted a token from `ACCESS_TOKEN`, logged
"A runner exists with the same name / Successfully replaced the runner", and was listening for
jobs ~30 s later with its labels intact from `RUNNER_LABELS`.

A runner counts as "already configured" if *any* of these survive in
`actions-runner/` — deleting only `.runner` and `.credentials` makes `config.sh` refuse with
"Cannot configure the runner because it is already configured":

```
.runner  .credentials  .credentials_rsaparams  .runner_migrated
```

Scope it to exactly `admin:org` (fine-grained: organisation → "Self-hosted runners: read and
write") and use a dedicated token, never a broad personal one. **Any job on these runners can
read it.** That is not fixable by tightening file modes: the Docker socket is mounted, so a job
can start a container that mounts these files. It is the price of socket-mounted runners, and
the reason the token should be able to do nothing but register runners.

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
