# macOS GitHub Actions Runner (VM 126)

Self-hosted macOS runner for `eduinlight-org`, for the lightchat `macos` + `ios` CI
jobs and the `release-desktop-macos` matrix — off GitHub-hosted minutes (macOS bills
at a ×10 multiplier, the largest share of the org's usage).

- **VMID:** 126 `mac-runner`
- **IP:** 192.168.0.245 (DHCP)
- **Pool:** `github`
- **Specs:** 8 GB RAM, 4 cores, 80 GB disk
- **OS:** macOS Sequoia 15.7.9, **x86_64** (arch label `X64`)
- **Login:** `ssh eduin@192.168.0.245` (dev box key; password/PIN in `secrets.local.md`)

## This is a hackintosh — the honest version

Built with kholia's **OSX-KVM** (OpenCore) as a Proxmox VM, not real Apple hardware.
It works, but know what it is:

- **EULA:** Apple restricts macOS to Apple-branded hardware. This is a gray area.
- **CPU:** the host is a Core Ultra 7 265K (Arrow Lake) — a CPU Apple never shipped.
  The VM sidesteps that by presenting an **emulated Skylake-Client** (`-cpu` in the
  args below), so macOS never sees Arrow Lake. This is the single reason it boots.
- **Ceiling:** macOS Sequoia 15 (Tahoe 26 dropped Intel). Fine — it runs Xcode 16.
- A Mac mini would be faster, legal, and lower-maintenance. This exists because it
  costs nothing extra. Treat it as best-effort infrastructure.

## VM definition

Proxmox VM (q35 + OVMF) with OpenCore as the boot disk and macOS-specific QEMU args.
The critical pieces (`/etc/pve/qemu-server/126.conf`):

```
args: -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
      -smbios type=2 -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
      -device usb-tablet,bus=xhci.0 -global nec-usb-xhci.msi=off \
      -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,+hypervisor,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check
sata0: <OpenCore.qcow2>     # bootloader (boot: order=sata0)
sata2: <80G Macintosh HD>   # macOS
vga: vmware
net0: vmxnet3,...           # macOS has a built-in vmxnet3 driver
```

- The `args` `-cpu` intentionally **overrides** Proxmox's own `-cpu host` — it appears
  later on the QEMU command line and the last `-cpu` wins (verify with
  `qm showcmd 126`). This is what masks Arrow Lake down to Skylake.
- `-device isa-applesmc,osk=...` is the AppleSMC key macOS requires to boot.
- OpenCore `Timeout=2`, so it auto-boots. The installer media is **detached** after
  install so OpenCore can only boot the installed system.

Tooling to rebuild the image lives on the PVE host at `/root/OSX-KVM` (recovery
fetched with `fetch-macOS-v2.py -s sonoma`, which delivered a Sequoia installer).

## Setup (already done; here for rebuilds)

### 1. Install macOS (interactive, one time)
Boot the VM, at the OpenCore picker choose **macOS Base System**, then in the
installer: **Utilities → Disk Utility → View → Show All Devices**, select the ~85 GB
QEMU disk, **Erase** as `APFS` / `GUID Partition Map` named `Macintosh HD`, quit, then
**Reinstall macOS** onto it. ~30–60 min with auto-reboots. This part is GUI-only —
drive it via the Proxmox noVNC console (or the QMP mouse helper at
`/root/vmclick.py` on the PVE host).

### 2. Enable SSH (interactive, one time)
System Settings → General → Sharing → **Remote Login** on. (`systemsetup
-setremotelogin` needs Full Disk Access on Sequoia — the GUI toggle doesn't.) Then
install the dev-box key:
```sh
mkdir -p ~/.ssh && curl -fsS http://192.168.0.15:8000/id.pub >> ~/.ssh/authorized_keys \
  && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

### 3. Provision the toolchain (remote)
```sh
ssh eduin@192.168.0.245 'SUDO_PW=<pw> bash -s' < provision.sh
```
Installs Command Line Tools (clang + git + macOS SDK), rustup + stable + the three
Apple targets, Homebrew + `openssl@3` + `pkg-config`, disables sleep, and sets up
auto-login. Idempotent.

`openssl@3` is required because `cargo install dioxus-cli` (the `dx` bundler) links
OpenSSL, which macOS doesn't ship as a dev library. It's **keg-only**, so the runner
is pointed at it via `OPENSSL_DIR=$(brew --prefix openssl@3)` appended to
`~/actions-runner/.env` (read by the service at start — restart the runner after
adding it). The Homebrew installer shells out to interactive `sudo`, which fails over
a TTY-less SSH session, so `eduin` is given passwordless sudo (homelab convention,
`/etc/sudoers.d/eduin`) before running it.

### 4. Register (remote)
```sh
ssh eduin@192.168.0.245 'bash -s' < register.sh <TOKEN>
```
Token from org → Settings → Actions → Runners → New runner. Registers
`gh-runner-macos` with label `homelab` (`self-hosted, macOS, X64` are automatic) and
installs a **LaunchAgent**.

### 5. Grant repo access + flip workflows
Allow `lightchat` under org → Settings → Actions → Runner groups. Then, once the
runner shows `online`:

| File | Job | `runs-on` |
|---|---|---|
| `.github/workflows/ci.yml` | `macos` | `[self-hosted, macOS, homelab]` |
| `.github/workflows/ci.yml` | `ios` | `[self-hosted, macOS, homelab]` |
| `.github/workflows/release-desktop-macos.yml` | `bundle` (both matrix arches) | `[self-hosted, macOS, homelab]` |

## LaunchAgent + auto-login (the macOS-specific gotcha)

The runner is a **LaunchAgent**, not a daemon — it runs only inside a GUI login
session. So the box is set to **auto-login** (`/etc/kcpassword` + `autoLoginUser`;
`sysadminctl -autologin` throws error 22 on Sequoia, so kcpassword is written
directly). Without auto-login the runner never comes back after a reboot. A
LaunchAgent is also the right choice for eventual code signing — `codesign`/`hdiutil`
need an unlocked keychain, which only exists in a real login session.

On the very first login after `svc.sh install`, Sequoia's Background Task Management
holds the new agent (you'll see "Background Items Added"); it auto-starts on
subsequent logins. Manage/verify from the dev box:
```sh
ssh eduin@192.168.0.245 'cd ~/actions-runner && ./svc.sh status'   # or start/stop
```
`svc.sh` must **not** be run with sudo.

## Xcode — installed (Xcode 16.4, iOS 18.5 SDK)

Full Xcode 16.4 is installed at **`/Applications/Xcode-16.4.0.app`** (note the `.0`),
selected as the active developer dir, license accepted. `cargo check --target
aarch64-apple-ios` passes, so the **`ios` job works**. All four macOS jobs are covered.

**The App Store does NOT work on this hackintosh** — Apple ID / App Store sign-in is
hardware-attested (serial, MLB, ROM from a genuine built-in NIC), and this VM has
kholia's placeholder SMBIOS, so sign-in fails with a generic "unknown error". That is
expected and unrelated to the account/password.

Xcode was therefore installed with **`xcodes`** (`/usr/local/bin/xcodes`), which
authenticates against Apple's developer-download service (plain Apple ID + 2FA, *not*
hardware-attested) and works fine here:

```sh
# binary fetched from github.com/XcodesOrg/xcodes releases into /usr/local/bin
xcodes list                       # 16.4 is the newest Xcode that runs on Sequoia 15
xcodes install "16.4"             # prompts Apple ID + 2FA + sudo; ~8 GB xip, resumable
sudo xcode-select -s /Applications/Xcode-16.4.0.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -showsdks | grep -i ios # -> iOS 18.5
```

Pick Xcode ≤ 16.x on Sequoia; Xcode 26.x needs a newer macOS. To upgrade Xcode later,
`xcodes install` a newer build and re-run `xcode-select -s`.

### Disk grow (done)

Xcode needed more room, so the disk was grown 80 → 120 GB. The sequence, incl. the
GPT gotcha:

```sh
# PVE host: qm stop 126; qm resize 126 sata2 +40G; qm start 126
# in macOS — the partition grew but the GPT backup header was still at the old end,
# so resizeContainer failed with -69519. Fix by repairing the GPT first:
sudo diskutil repairDisk disk1          # answer 'y' — "Adjusting partition map to fit whole disk"
sudo diskutil apfs resizeContainer disk1s2 0
# (repairDisk is safe here: OpenCore boots from disk0, not disk1's EFI)
```
Data volume is now 120 GB.

## Code signing — inactive

`scripts/macos-bundle.sh` reads `APPLE_CERTIFICATE`/`APPLE_ID`/etc. None are
configured; the script warns and produces an unsigned build. No cert work needed. If
added later: keychain must be unlocked in the job (LaunchAgent + auto-login already
gives a login session, which helps).

## Notes

- **Not activated / no iCloud** needed for CI.
- Disk is 80 GB (see Xcode step to grow). Watch `local-lvm` on the PVE host — it runs
  hot; see CLAUDE.md.
- Reboot chain validated: cold boot → OpenCore auto-boots (2 s) → auto-login →
  LaunchAgent → runner online, no console interaction.
