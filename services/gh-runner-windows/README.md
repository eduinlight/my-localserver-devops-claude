# Windows GitHub Actions Runner (VM 125)

Self-hosted Windows runner for the `eduinlight-org` organization, built to take the
`windows` CI job and `release-desktop-windows.yml` off GitHub-hosted minutes (billed
at a ×2 multiplier, ~722 min/month).

- **VMID:** 125 `gh-runner-windows`
- **IP:** 192.168.0.244 (DHCP)
- **Pool:** `github` (alongside LXC 124, the Linux runner)
- **Specs:** 12 GB RAM, 8 cores, 150 GB disk, `onboot=1`
- **Base:** full clone of VM template 115 (`win11`, Win11 24H2, OVMF + TPM 2.0 + q35)

## Why a VM and not an LXC

Windows can't run in an LXC. The existing `win11` template (VMID 115) was already
built with the OVMF/TPM/q35 combination Win11 requires, so cloning it skips the
install entirely.

## Disk and the thin pool

The clone was given `discard=on`, which template 115 lacks. This matters: without
it the LVM thin pool never gets freed blocks back, and a Rust CI runner churns
disk harder than anything else on this host. Auditing for exactly this problem
recovered ~147 GB across the other guests (see "Thin pool hygiene" below).

`local-lvm` is **thin-overcommitted** — the sum of provisioned volumes exceeds the
pool. The 150 GB given here is provisioned, not reserved. Watch it:

```sh
ssh root@192.168.0.15 'lvs --units g -o lv_name,lv_size,data_percent pve/data'
```

If the pool approaches 100% every guest on it starts throwing I/O errors, so keep
`cargo clean` / `_work` pruning on the schedule the runbook recommends.

## Setup

### 1. One-time console bootstrap

The template has no remote access at all — RDP, WinRM, SSH and the QEMU guest agent
are all off, and Win11 boots straight to a lock screen. This step is unavoidably
manual; everything after it is remote.

Open the Proxmox console (https://proxmox.lan → VM 125 → Console), log in, open
**PowerShell as Administrator**, and run:

```powershell
irm http://192.168.0.15:8000/bootstrap.ps1 | iex
```

That installs OpenSSH server, opens port 22, and authorizes the dev box key. The
script is served by a transient HTTP server on the Proxmox host:

```sh
ssh root@192.168.0.15 'systemd-run --unit=ghrunner-http \
  --working-directory=/root/ghrunner \
  /usr/bin/python3 -m http.server 8000 --bind 192.168.0.15'
```

Stop it once setup is done — it has no auth and serves whatever is in that directory:

```sh
ssh root@192.168.0.15 'systemctl stop ghrunner-http'
```

Note that admin accounts on Windows OpenSSH authenticate against
`%ProgramData%\ssh\administrators_authorized_keys`, **not** `~/.ssh/authorized_keys`.
`bootstrap.ps1` handles this; hand-editing the wrong file is the usual reason key
auth silently fails here.

### 2. Provision the toolchain

```sh
scp provision.ps1 <user>@192.168.0.244:C:/provision.ps1
ssh <user>@192.168.0.244 "powershell -ExecutionPolicy Bypass -File C:\provision.ps1"
```

Installs Git, PowerShell 7, VS 2022 Build Tools (VCTools workload), rustup + stable
+ the `x86_64-pc-windows-msvc` target, NASM, Strawberry Perl, long-path support,
Defender exclusions, and disables sleep. Idempotent. Budget 30–45 minutes — Build
Tools dominates.

Everything the jobs need must be reachable **as LocalSystem** (the service account),
so `provision.ps1` installs machine-wide and puts every tool on the *machine* PATH.
The failure points that caught this build, all now handled by the script:

- **`bash` is not on PATH by default.** Git's installer adds `cmd\` (git.exe) but not
  `bin\` (bash.exe). `dtolnay/rust-toolchain@stable` bootstraps through bash, so the
  "Install Rust" step fails with `bash: command not found` until `C:\Program Files\
  Git\bin` is on the machine PATH. This is the single most common self-hosted Windows
  gotcha.
- **`pwsh` must be the MSI, not winget.** `release-desktop-windows.yml` uses
  `shell: pwsh`. Winget's PowerShell is an MSIX that installs into a user's
  `WindowsApps` folder — invisible to LocalSystem, so the bundle step fails with
  `pwsh not found`. The MSI installs to `C:\Program Files\PowerShell\7` on the machine
  PATH. (`pwsh` is also not PowerShell 5.1 — stock Windows has no `pwsh` at all.)
- **`rustup`/`cargo` are machine-wide** under `C:\rust`, not `%USERPROFILE%\.cargo`,
  for the same LocalSystem-visibility reason (see step 3).
- **Perl is required** — the vendored OpenSSL build (`openssl-sys`) runs its
  Configure through perl. `windows-latest` ships Strawberry Perl; a bare box has
  none, so `cargo check` fails compiling `openssl-sys`. Installed machine-wide to
  `C:\Strawberry`.
- **`winget` is unreliable over SSH** (it wants a loaded user profile), so every
  install in `provision.ps1` falls back to a direct download.
- **.NET Framework 3.5 (NetFx3)** — WiX's `candle.exe` is a .NET 3.5 app and won't
  start without it; the release bundle fails otherwise. Win11 ships it as
  `DisabledWithPayloadRemoved`, so it's fetched from Windows Update. DISM needs a
  HIGH-integrity token, which a plain SSH admin session isn't (Error 5 / "Access is
  denied"), so `provision.ps1` enables it via a **SYSTEM scheduled task**. If WU is
  blocked, attach the Win11 ISO and add `/LimitAccess /Source:<CD>\sources\sxs`.

Reboot (or at least restart the runner service) afterwards so the machine PATH is
picked up — the runner caches its environment at service start.

Verify tools resolve *for the service account specifically* — a plain SSH shell runs
as `eduin` and can mask a LocalSystem PATH gap. Run the check as SYSTEM:

```powershell
'@echo off
where bash & where pwsh & where cargo & where nasm > C:\syscheck.txt 2>&1' | Set-Content C:\syscheck.cmd -Encoding ASCII
schtasks /Create /TN syscheck /TR C:\syscheck.cmd /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F
schtasks /Run /TN syscheck; Start-Sleep 3; schtasks /Delete /TN syscheck /F
Get-Content C:\syscheck.txt
```

### 3. Register with GitHub

Token from *org `eduinlight-org` → Settings → Actions → Runners → New runner → Windows*.
**Registration tokens expire about an hour after they are issued.**

```sh
scp register.ps1 <user>@192.168.0.244:C:/register.ps1
ssh <user>@192.168.0.244 "powershell -ExecutionPolicy Bypass -File C:\register.ps1 -Token <TOKEN>"
```

Registers as `gh-runner-windows` with label `homelab`; `self-hosted`, `Windows` and
`X64` are applied by GitHub automatically. Installs as a Windows service (delayed
auto-start) so it survives reboots.

**Service account — runs as LocalSystem.** The interactive account on this box
(`eduin`) is a **Microsoft account**, which Windows cannot use as a service logon
(`net user` can't set its password, and a Hello PIN is not the account password).
So the toolchain is installed **machine-wide** under `C:\rust` (`CARGO_HOME`/
`RUSTUP_HOME` at Machine scope) and the service runs as `NT AUTHORITY\SYSTEM` — no
password, nothing to rotate, unaffected if the Microsoft credentials change. This
is why `provision.ps1` puts Rust in `C:\rust` and not `%USERPROFILE%\.cargo`: a
per-user install would be invisible to LocalSystem and every job would fail to find
`cargo`. To bind to a genuine *local* account instead, pass
`-RunAsUser 'HOST\user' -RunAsPassword '...'`.

`register.ps1` removes any existing local runner config first — `config.cmd` refuses
to reconfigure an already-configured runner even with `--replace`.

Then allow the `lightchat` repo to use it: *org → Settings → Actions → Runner groups
→ repository access*.

### 4. Verify before touching workflows

```sh
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/orgs/eduinlight-org/actions/runners \
  | jq '.runners[] | {name, os, status, labels: [.labels[].name]}'
```

Only once it shows `online`, switch `runs-on` in the workflows. A job targeting
labels with no matching online runner queues silently for hours rather than
failing, which is indistinguishable from a hang.

| File | Job | To |
|---|---|---|
| `.github/workflows/ci.yml` | `windows` | `[self-hosted, Windows, homelab]` |
| `.github/workflows/release-desktop-windows.yml` | `bundle` | `[self-hosted, Windows, homelab]` |

## Licensing

Windows is **not activated**. This is fine for CI — you get a desktop watermark and
locked personalization settings, neither of which affects builds. Add a key with
`slmgr /ipk <key>` if you want it clean.

## Thin pool hygiene

The reclaim that made room for this VM was pure `fstrim` — no data deleted. The
guests had freed blocks that were never returned to the pool:

```sh
# containers
ssh root@192.168.0.15 'for c in $(pct list | awk "NR>1 {print \$1}"); do pct fstrim $c; done'
# VMs (only those with discard=on)
ssh admin@192.168.0.6X 'sudo fstrim -av'
```

Worth running periodically. Templates 101/112 fail with `Read-only file system`,
which is expected and harmless.

## Not done

- **Windows activation** — see above.
- **QEMU guest agent** is enabled in the VM config but not installed in the guest,
  so `qm agent 125 ...` won't work. The virtio-win ISO
  (`/var/lib/vz/template/iso/virtio-win-0.1.285.iso`) has the installer.
- **A macOS runner.** See the parent discussion — it needs ~180 GB, which this pool
  does not currently have, and macOS on non-Apple hardware is an Apple EULA
  violation. A Mac mini on the LAN is the cleaner answer.
