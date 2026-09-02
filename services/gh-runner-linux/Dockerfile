# The Linux self-hosted runner image. Section numbers refer to install-on-runners.md.
#
# All four containers run this one image, and they carry identical labels, so a job lands on
# any of them — they have to be interchangeable. They were not: before this image, `dx` was on
# one of the four, `wasm32-unknown-unknown` was missing on another, and the Android NDK on two.
#
# Two rules govern where things go, and both come from docker-compose.yml mounting a named
# volume over /home/runner:
#
#   1. Nothing the image installs may live under /home/runner — the volume masks it at run
#      time. Hence CARGO_HOME=/usr/local/cargo and ANDROID_HOME=/opt/android-sdk rather than
#      the ~/.cargo and ~/android-sdk the doc writes for a bare-metal runner.
#   2. Everything must be on PATH for a *non-login, non-interactive* shell. Actions runs steps
#      as `bash --noprofile --norc`, which reads neither .bashrc nor .profile, so the ENV
#      instructions below are the container equivalent of the doc's systemd override (§1,
#      "Make it visible to the service"). Installing a tool without this looks like success
#      from an interactive `docker exec` and still fails every job.
FROM ubuntu:22.04

ARG RUNNER_VERSION=2.336.0
ENV DEBIAN_FRONTEND=noninteractive

# §3.1 base packages, §3.6 desktop packaging (AppImage/deb/rpm + the webkit stack dx links
# against). §4.3's Chromium libraries are handled by playwright install-deps further down,
# which picks the right names for this distro — the doc's list is the 24.04 t64 spelling.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      desktop-file-utils \
      dpkg-dev \
      file \
      fuse \
      git \
      gnupg \
      libayatana-appindicator3-dev \
      libfuse2 \
      libgtk-3-dev \
      librsvg2-dev \
      libssl-dev \
      libwebkit2gtk-4.1-dev \
      libxdo-dev \
      lsb-release \
      openssl \
      pkg-config \
      rpm \
      sudo \
      unzip \
      wget \
      xz-utils \
      zip \
    && rm -rf /var/lib/apt/lists/*

# §3.4 — the CLI only; the daemon is the LXC's, reached through the socket bind-mount.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

# §3.5 — Temurin 17. sdkmanager below needs a JDK, so this comes first.
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o /etc/apt/keyrings/adoptium.asc \
    && chmod a+r /etc/apt/keyrings/adoptium.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb jammy main" \
       > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-17-jdk \
    && rm -rf /var/lib/apt/lists/* \
    && java -version

# §4.2 — Node 22. Also what runs playwright's installers below.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version

# §4.4 — optional, for uploading test videos. Jobs skip it cleanly when absent; it is small.
RUN apt-get update && apt-get install -y --no-install-recommends awscli \
    && rm -rf /var/lib/apt/lists/*

# The CI tool belt. The harness's scripts/ensure-tools.sh verifies these are on PATH and fails
# the job by name if one is missing — it installs nothing, by design ("Jobs install nothing at
# execution time"). This layer is that provisioning.
#
# gh and jq come from upstream releases rather than apt because the floors in §2 are >= 2.76
# and >= 1.7, and jammy ships jq 1.6. kubectl and kustomize are §4, nominally one machine
# only; one image serves all four, so the binaries land everywhere and the `kubectl` *label*
# plus the kubeconfig mount are what actually route those jobs.
ARG TARGETARCH=amd64
ARG GH_VERSION=2.76.2
ARG YQ_VERSION=v4.44.3
ARG KUSTOMIZE_VERSION=5.4.3
ARG KUBECTL_VERSION=v1.31.3
ARG JQ_VERSION=1.7.1
ARG ACTIONLINT_VERSION=1.7.7

RUN set -eux \
    && curl -sSfL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
         | tar -xz -C /usr/local/bin --strip-components=2 "gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" \
    && curl -sSfL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
         -o /usr/local/bin/yq \
    && curl -sSfL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz" \
         | tar -xz -C /usr/local/bin kustomize \
    && curl -sSfL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
         -o /usr/local/bin/kubectl \
    && curl -sSfL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${TARGETARCH}" \
         -o /usr/local/bin/jq \
    && curl -sSfL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${TARGETARCH}.tar.gz" \
         | tar -xz -C /usr/local/bin actionlint \
    && chmod 0755 /usr/local/bin/gh /usr/local/bin/yq /usr/local/bin/kustomize \
         /usr/local/bin/kubectl /usr/local/bin/jq /usr/local/bin/actionlint \
    && gh --version && yq --version && kubectl version --client \
    && kustomize version && jq --version && actionlint --version

# §3.2 — Rust. Tracked as `stable` with a floor of 1.94, not pinned; `rustup update` on a
# schedule is the maintenance story (§8).
#
# CARGO_HOME and RUSTUP_HOME are /usr/local, not ~, for the masking reason at the top. Both are
# opened up because jobs fetch crates and may `cargo install` into them at run time — the same
# thing the official rust image does.
#
# It must be `a+rwX`, never `a+w`. Crate tarballs carry their own mode bits and cargo preserves
# them: fnv-1.0.7 ships lib.rs at 0660, which `a+w` turns into 0662 — writable by the runner and
# still unreadable. Every version check passes and the build dies partway through with
# "couldn't read .../fnv-1.0.7/lib.rs: Permission denied (os error 13)". The capital X sets the
# execute bit on directories only, keeping the registry traversable without making sources
# executable.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain stable --profile minimal \
    && rustup component add rustfmt clippy \
    && rustup target add wasm32-unknown-unknown aarch64-linux-android \
    && chmod -R a+rwX "$RUSTUP_HOME" "$CARGO_HOME" \
    && rustc --version && cargo --version \
    && rustup target list --installed

# §3.5 — Android SDK. ANDROID_NDK_ROOT is not optional: ci.yml reads it directly to locate the
# cross-compiler, and it was unset on all four runners before this.
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.2.12479018 \
    ANDROID_NDK_ROOT=/opt/android-sdk/ndk/27.2.12479018

ARG ANDROID_CMDLINE_TOOLS=13114758
ARG ANDROID_NDK_VERSION=27.2.12479018
ARG ANDROID_PLATFORM=34
ARG ANDROID_BUILD_TOOLS=34.0.0

RUN set -eux \
    && mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
         "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp \
    && mv /tmp/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" --licenses > /dev/null \
    && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" \
         "ndk;${ANDROID_NDK_VERSION}" "platform-tools" \
         "platforms;android-${ANDROID_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS}" > /dev/null \
    && chown -R runner:runner "$ANDROID_HOME" \
    && test -x "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"

# §4.3 — Playwright's system libraries, and the browser itself so no job downloads it.
# PLAYWRIGHT_BROWSERS_PATH moves the cache out of ~/.cache, which the volume would mask.
#
# `a+rwX`, not `a+rX`. Setting PLAYWRIGHT_BROWSERS_PATH to a root-owned directory is precisely
# what makes an in-job `playwright install` die with
#   EACCES: permission denied, mkdir '/opt/ms-playwright/__dirlock'
# — the browser is present and readable, so nothing looks wrong until a job tries to write.
#
# The version is load-bearing: playwright resolves a version-specific directory (1.49.1 wants
# chromium-1148) and a browser from another release sits here unused. Bump PLAYWRIGHT_VERSION
# and the browser together, and check with
#   node -e 'console.log(require("playwright").chromium.executablePath())'
ARG PLAYWRIGHT_VERSION=1.49.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

RUN npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium \
    && npx --yes "playwright@${PLAYWRIGHT_VERSION}" install chromium \
    && chmod -R a+rwX "$PLAYWRIGHT_BROWSERS_PATH" \
    && rm -rf /var/lib/apt/lists/* /root/.npm \
    # Assert what a version check cannot: that the cache is writable and the browser this
    # playwright release actually reaches for is the one present.
    && { nw="$(find "$PLAYWRIGHT_BROWSERS_PATH" -type d ! -perm -o+w -print -quit)"; \
         [ -z "$nw" ] || { echo "not writable by the runner user: $nw" >&2; exit 1; }; } \
    && test -x "$(ls -d "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux/chrome | head -1)"

# AppImage needs FUSE, which this container does not get (it would want --device /dev/fuse and
# --cap-add SYS_ADMIN). Extract-and-run is the documented alternative (§3.6).
ENV APPIMAGE_EXTRACT_AND_RUN=1

WORKDIR /home/runner/actions-runner

RUN curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && mkdir -p /home/runner/_work \
    && chown -R runner:runner /home/runner

# §3.3 — dioxus-cli. Last because it is the slowest layer by a wide margin (5-15 minutes of
# compilation); everything above stays cached when its version changes.
ARG DIOXUS_CLI_VERSION=0.7.10
RUN cargo install dioxus-cli --version "${DIOXUS_CLI_VERSION}" --locked \
    && chmod -R a+rwX "$CARGO_HOME" \
    && dx --version \
    # Fail the build rather than ship a registry a job cannot read. This is the check that
    # would have caught the a+w bug: every version command still succeeded with it in place.
    && { unreadable="$(find "$CARGO_HOME" "$RUSTUP_HOME" ! -perm -o+r -print -quit)"; \
         [ -z "$unreadable" ] || { echo "unreadable by the runner user: $unreadable" >&2; exit 1; }; }

# §3.7 — Keep $CARGO_HOME/bin free of regular files.
#
# Swatinem/rust-cache (used by the lightchat workflows, `cache-bin` defaults to true) deletes
# every *regular file* in $CARGO_HOME/bin in its post step. It keeps only binaries recorded in
# .crates2.json and then subtracts the ones that already existed when the cache was restored —
# which is precisely the set this image ships, so the keep-list comes out empty. On 2026-09-01
# it wiped `rustup` and `dx` from gh-runner-docker-2 and left the fourteen rustup proxy symlinks
# (cargo, rustc, rustfmt, clippy-driver, ...) dangling: `command -v cargo` fails, and the job
# reports the toolchain as missing even though /usr/local/rustup is untouched.
#
# It skips symlinks (`dirent.isFile()`), so moving the two real binaries to /usr/local/bin and
# leaving symlinks behind makes the directory nothing but symlinks and the cleanup a no-op. The
# proxies still resolve: cargo -> rustup -> /usr/local/bin/rustup, and rustup dispatches on the
# invoked basename, which the extra hop does not change.
RUN mv "$CARGO_HOME/bin/rustup" /usr/local/bin/rustup \
    && ln -s /usr/local/bin/rustup "$CARGO_HOME/bin/rustup" \
    && mv "$CARGO_HOME/bin/dx" /usr/local/bin/dx \
    && ln -s /usr/local/bin/dx "$CARGO_HOME/bin/dx" \
    && chmod 0755 /usr/local/bin/rustup /usr/local/bin/dx \
    # Fail the build if anything is left that rust-cache would delete.
    && { leftover="$(find "$CARGO_HOME/bin" -type f -print -quit)"; \
         [ -z "$leftover" ] || { echo "regular file in \$CARGO_HOME/bin: $leftover" >&2; exit 1; }; } \
    && rustup --version && cargo --version && rustc --version && dx --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
