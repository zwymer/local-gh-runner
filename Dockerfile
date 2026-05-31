# Self-hosted GitHub Actions runner — Ubuntu 24.04 LTS (Noble Numbat)
# Based on myoung34/docker-github-actions-runner patterns, rebuilt on a
# modern base so Tauri 2 WebKitGTK / libsoup-3.0 packages resolve cleanly.

FROM ubuntu:24.04

LABEL maintainer="zwymer"

# ── base plumbing ────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG GH_RUNNER_VERSION=2.334.0
ARG TARGETPLATFORM=linux/amd64

# dumb-init + gosu (lightweight PID-1 and user-step-down). unzip is required by
# actions that download zipped release archives (e.g. hashicorp/setup-terraform,
# which otherwise fails with "Unable to locate executable file: unzip").
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq dumb-init gosu sudo git unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# GitHub CLI (used by release-tag workflow to trigger builds)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker client + buildx + compose plugins. We talk to the *host* daemon via
# the /var/run/docker.sock that docker-compose.runner.yml mounts in, so no
# dockerd is needed inside the runner — only the CLI. Without this,
# docker/login-action and docker/build-push-action fail with
#   "Unable to locate executable file: docker"
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── GitHub Actions runner ────────────────────────────────────────────
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
RUN mkdir -p /opt/hostedtoolcache

RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -s /bin/bash -u 1000 runner \
    && usermod -aG sudo runner \
    && echo "%sudo ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /actions-runner

COPY install_actions.sh /actions-runner/install_actions.sh
RUN chmod +x /actions-runner/install_actions.sh \
    && /actions-runner/install_actions.sh ${GH_RUNNER_VERSION} ${TARGETPLATFORM} \
    && rm /actions-runner/install_actions.sh \
    && chown -R runner /_work /actions-runner /opt/hostedtoolcache

COPY token.sh entrypoint.sh app_token.sh /
RUN chmod +x /token.sh /entrypoint.sh /app_token.sh

# ── system build toolchain ───────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc g++ \
      clang llvm \
      cmake pkg-config \
      protobuf-compiler libprotobuf-dev \
      libssl-dev \
      curl ca-certificates git \
      sudo \
      python3 python3-pip python3-venv pipx \
    && pipx install pyflakes \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Tauri 2 native dependencies (Ubuntu 24.04 ships these) ──────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      libwebkit2gtk-4.1-dev \
      libappindicator3-dev \
      librsvg2-dev \
      patchelf \
      libgtk-3-dev \
      libsoup-3.0-dev \
      javascriptcoregtk-4.1-dev \
      libfuse2t64 \
      file \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Node.js 24 ──────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# ── Rust (stable, minimal profile + clippy/rustfmt) ─────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal \
          --component clippy,rustfmt \
    && rustc --version && cargo --version

# ── entrypoint ───────────────────────────────────────────────────────
ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
