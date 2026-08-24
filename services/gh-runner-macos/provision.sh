#!/bin/bash
# Provision the macOS GitHub Actions runner (VM 126) with the toolchain the
# lightchat macOS/iOS jobs need. Run over SSH from the dev box:
#
#     ssh eduin@192.168.0.245 'bash -s' < provision.sh
#
# Idempotent. Needs sudo for the Command Line Tools step — run interactively, or
# export SUDO_PW so the script can feed `sudo -S`.
set -euo pipefail

step() { printf '\n==> %s\n' "$1"; }
SUDO() { if [ -n "${SUDO_PW:-}" ]; then echo "$SUDO_PW" | sudo -S "$@"; else sudo "$@"; fi; }

# ------------------------------------------------------ Command Line Tools
# Provides clang, git, and the macOS SDK — enough for the `macos` job and both
# release-desktop-macos matrix legs. NOT enough for the `ios` job (see README:
# that needs full Xcode's iOS SDK).
step 'Command Line Tools'
if ! xcode-select -p >/dev/null 2>&1; then
  # Headless CLT install: the .in-progress file makes softwareupdate list the CLT.
  SUDO touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(softwareupdate -l 2>/dev/null | grep -B1 'Command Line Tools' \
         | grep 'Label:' | sed 's/.*Label: //' | sort -V | tail -1)
  echo "installing: $PROD"
  SUDO softwareupdate -i "$PROD" --verbose
  SUDO rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
xcode-select -p

# ----------------------------------------------------------------- rustup
# The workflows use dtolnay/rust-toolchain@stable, which calls `rustup toolchain
# install` — it does not bootstrap rustup itself.
step 'rustup + Apple targets'
if ! command -v rustup >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustup" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
rustup toolchain install stable
# aarch64/x86_64-apple-darwin for the desktop release matrix; aarch64-apple-ios
# for the ios job (std only — the iOS *SDK* still requires full Xcode).
rustup target add aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios

# ------------------------------------------------- Homebrew + OpenSSL + pkg-config
# `cargo install dioxus-cli` (the `dx` bundler the release jobs use) links OpenSSL.
# macOS ships only LibreSSL headers, so the build needs Homebrew's openssl@3. It is
# keg-only (not symlinked into the prefix), so the runner must be told where it is
# via OPENSSL_DIR in the runner's .env — otherwise dx fails to build.
step 'Homebrew + openssl@3 + pkg-config'
if [ ! -x /usr/local/bin/brew ] && [ ! -x /opt/homebrew/bin/brew ]; then
  # The Homebrew installer shells out to `sudo` interactively; over a TTY-less SSH
  # session that fails. eduin is given passwordless sudo (homelab admin convention),
  # which also lets the installer run under NONINTERACTIVE.
  if [ -n "${SUDO_PW:-}" ] && [ ! -f /etc/sudoers.d/eduin ]; then
    echo "$SUDO_PW" | sudo -S bash -c 'echo "'"$(whoami)"' ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/eduin && chmod 440 /etc/sudoers.d/eduin'
  fi
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
BREW=$([ -x /opt/homebrew/bin/brew ] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew)
eval "$("$BREW" shellenv)"
brew install openssl@3 pkg-config
# Point the runner at keg-only openssl. .env is read by the runner service at start.
ENVFILE="$HOME/actions-runner/.env"
if [ -f "$ENVFILE" ] && ! grep -q '^OPENSSL_DIR=' "$ENVFILE"; then
  echo "OPENSSL_DIR=$(brew --prefix openssl@3)" >> "$ENVFILE"
fi

# --------------------------------------------------------- power management
# A CI runner must never sleep.
step 'Disable sleep'
SUDO pmset -a sleep 0 disksleep 0 displaysleep 0

# ------------------------------------------------------------- auto-login
# The runner is a LaunchAgent — it only runs inside a GUI login session, so the
# box must auto-login after reboot or the runner never comes back. sysadminctl's
# -autologin is unreliable on Sequoia (error 22); write /etc/kcpassword directly.
step 'Auto-login'
USER_NAME=$(whoami)
if [ -n "${SUDO_PW:-}" ]; then
  python3 - "$SUDO_PW" <<'PY' > /tmp/kcpassword.bin
import sys
pw = sys.argv[1]
key = [0x7D,0x89,0x52,0x23,0x06,0x44,0xBB,0x25,0xF5,0x54,0xC0,0x50,0x2C,0x1A,0x2C,0xB6]
b = [ord(c) for c in pw]
b += [0] * (12 - (len(b) % 12))          # pad to a 12-byte block
sys.stdout.buffer.write(bytes(b[i] ^ key[i % len(key)] for i in range(len(b))))
PY
  SUDO cp /tmp/kcpassword.bin /etc/kcpassword
  SUDO chmod 600 /etc/kcpassword
  SUDO chown root:wheel /etc/kcpassword
  SUDO defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$USER_NAME"
  rm -f /tmp/kcpassword.bin
else
  echo "SUDO_PW not set — skipping auto-login (set it and re-run, or configure in System Settings)"
fi

step 'Versions'
source "$HOME/.cargo/env"
clang --version | head -1
git --version
rustc --version
cargo --version
echo "targets: $(rustup target list --installed | tr '\n' ' ')"
echo
echo "Provisioning complete. Register with register.sh next."
echo "For the ios job, install full Xcode (Apple ID required) — see README."
