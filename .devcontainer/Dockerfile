FROM mcr.microsoft.com/devcontainers/base:bookworm

# The whole solution in one container. Not one per app: the two apps talk to
# each other over backend.local / frontend.local, both of which resolve to
# 127.0.0.1, and the frontend's OData client fetches $metadata from the backend
# at creation time. Splitting them across a compose network would mean rewriting
# those hostnames and the ServiceUrl constant, which is exactly the thing the
# repo already got right.
#
# Everything below is a dependency of something committed: the toolchain that
# scripts/build-mxcli.sh needs, the interpreters scripts/*.sh shell out to, and
# a Postgres server for the two Mendix databases plus f1ops.

# Resolved at build time rather than pinned, so the image does not rot when a
# patch release lands. Override with --build-arg GO_VERSION=go1.24.5 to pin.
# mxcli needs Go 1.24+; Debian bookworm ships 1.19, hence the tarball.
ARG GO_VERSION=

# JDK 21 is MxBuild's requirement and also what the antlr4 launcher runs on.
# Node 22 bundles the browser client and runs scripts/shoot-screenshots.mjs.
# unzip is for f1db-csv.zip; python3 and sed do the JSON and text munging in
# the four fetch scripts; make and git build mxcli from source.
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget apt-transport-https gpg ca-certificates curl unzip && \
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
        > /etc/apt/sources.list.d/adoptium.list && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        temurin-21-jdk \
        nodejs \
        postgresql \
        postgresql-client \
        python3 \
        python3-pip \
        make \
        git \
        procps \
        socat \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# dpkg's architecture names (arm64, amd64) are the same ones Go uses in its
# download filenames, so this needs no mapping table.
RUN ARCH="$(dpkg --print-architecture)" && \
    VER="${GO_VERSION:-$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)}" && \
    echo "installing ${VER} for linux-${ARCH}" && \
    curl -fsSL "https://go.dev/dl/${VER}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz

# Both, and not just the ENV. Debian's /etc/profile assigns PATH outright rather
# than appending to it, so a *login* shell throws this ENV away — and an SSH
# session is a login shell. Without the profile.d half, a Claude Code Desktop
# session in this container fails at
# "Cannot build mxcli: 'go' is not installed", with Go sitting in /usr/local/go
# the whole time. The ENV still earns its place: it covers `docker exec` and
# devcontainer lifecycle commands, which are not login shells.
ENV PATH=/usr/local/go/bin:/home/vscode/go/bin:$PATH
RUN printf 'export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH\n' \
      > /etc/profile.d/99-devcontainer-path.sh

# scripts/build-mxcli.sh installs this itself with a bare `pip install`, which
# fails on bookworm: PEP 668 marks the system interpreter externally-managed.
# Installing it here satisfies the script's `command -v antlr4` guard, so that
# branch never runs. The version matches the one the script pins.
ENV ANTLR4_TOOLS_ANTLR_VERSION=4.13.2
RUN pip3 install --no-cache-dir --break-system-packages 'antlr4-tools==0.2.2'

# Playwright, for scripts/shoot-screenshots.mjs. This block is carried over from
# the per-app devcontainers mxcli generated, comments included, because what it
# encodes is arm64-specific and was learned the hard way:
#
# @playwright/cli ships its OWN playwright-core, so browsers must be installed
# via that bundled core (matching revision) — NOT via a transient "npx
# playwright", which resolves a different package and cache. Browsers go under a
# world-readable PLAYWRIGHT_BROWSERS_PATH so the non-root "vscode" user finds
# them (a root-owned ~/.cache/ms-playwright would be invisible to it).
#
# On Linux arm64 the chrome/msedge *channels* have no distribution and the alpha
# CLI's browserName:chromium resolution is unreliable, so we pin the bundled
# Chromium headless-shell through a stable symlink. The symlink keeps the config
# revision-proof as the headless-shell build number changes.
# @playwright/cli is pinned (not @latest): it is a young package whose CLI
# surface still shifts between releases, and an unexpected bump has silently
# broken browser provisioning before.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npm install -g @playwright/cli@0.1.15 && \
    CORE="$(npm root -g)/@playwright/cli/node_modules/playwright-core/cli.js" && \
    node "$CORE" install --with-deps chromium chromium-headless-shell && \
    chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH" && \
    ln -sf "$PLAYWRIGHT_BROWSERS_PATH"/chromium_headless_shell-*/chrome-linux/headless_shell \
        /usr/local/bin/mx-headless-shell
