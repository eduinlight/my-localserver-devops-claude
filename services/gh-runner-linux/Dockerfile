FROM ubuntu:22.04

ARG RUNNER_VERSION=2.336.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      file \
      git \
      gnupg \
      jq \
      libayatana-appindicator3-dev \
      libgtk-3-dev \
      librsvg2-dev \
      libssl-dev \
      libwebkit2gtk-4.1-dev \
      libxdo-dev \
      lsb-release \
      pkg-config \
      sudo \
      unzip \
      wget \
      zip \
    && rm -rf /var/lib/apt/lists/*

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

WORKDIR /home/runner/actions-runner

RUN curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz \
    && ./bin/installdependencies.sh \
    && mkdir -p /home/runner/_work \
    && chown -R runner:runner /home/runner

# The CI tool belt. The harness's scripts/ensure-tools.sh verifies these are on PATH and
# fails the job by name if one is not — it deliberately installs nothing, on the grounds that
# provisioning the runner belongs to whoever owns the runner. This layer is that provisioning.
# Versions and install paths match what lightchat's docs/SETUP.md asks for; keep them in step.
#
# They land in /usr/local/bin, deliberately not ~/.local/bin, because docker-compose.yml mounts
# a named volume over /home/runner — anything the image wrote there would be masked at run time,
# and a stale copy left in a volume's ~/.local/bin shadows this one (PATH puts it first).
#
# The pinned jq shadows the apt jq (1.6) above, since /usr/local/bin precedes /usr/bin.
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
    && gh --version \
    && yq --version \
    && kustomize version \
    && kubectl version --client \
    && jq --version \
    && actionlint --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
