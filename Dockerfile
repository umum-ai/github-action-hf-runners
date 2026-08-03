FROM ubuntu:26.04

ARG RUNNER_VERSION=2.336.0
ARG TARGETARCH=x64

ARG TZ=Asia/Bangkok
ENV TZ=${TZ}

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=1 \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y extrepo --no-install-recommends && extrepo enable mise && \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    bubblewrap \
    curl \
    git \
    git-lfs \
    gnupg \
    jq \
    libicu74 \
    locales \
    lsb-release \
    openssh-client \
    rsync \
    sudo \
    unzip \
    wget \
    xz-utils \
    zip \
    zsh \
    mise \
    && rm -rf /var/lib/apt/lists/*

# Parity with what workflows assume exists on `ubuntu-latest`. zstd is the one
# that silently costs money if missing: actions/cache and actions/upload-artifact
# compress with it and fall back to a much slower gzip path when it is absent.
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsutils \
    file \
    gawk \
    gettext-base \
    iproute2 \
    iputils-ping \
    less \
    lsof \
    netcat-openbsd \
    pkg-config \
    sqlite3 \
    tzdata \
    vim-tiny \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL 17 from PGDG, since Ubuntu 24.04 carries only the 16 branch. A job
# on these runners has no docker daemon behind `services:`, so it runs the
# database as a job process; server and client come from the same branch so that
# `psql` and `pg_dump` are never older than the cluster they are pointed at.
#
# `create_main_cluster = false` is what leaves the image cluster-free: the
# postinst would otherwise put a cluster in /var/lib/postgresql/17 that nothing
# here can start, and a job creates the cluster it needs with `initdb` anyway.
RUN curl -fsSL -o /usr/share/keyrings/postgresql-pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-pgdg.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends postgresql-common \
    && sed -i 's/^#*create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf \
    && apt-get install -y --no-install-recommends \
    postgresql-17 \
    postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

# The server binaries sit outside every default PATH, and a workflow step is a
# plain `bash -e` that sources no shell initialization, so `initdb`, `pg_ctl` and
# friends have to resolve from the image environment itself.
ENV PATH=/usr/lib/postgresql/17/bin:${PATH}

# Shared libraries Chromium links against, so `playwright install chromium`
# needs neither `--with-deps` nor an apt round-trip on every run.
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-liberation \
    libasound2t64 \
    libatk-bridge2.0-0t64 \
    libatk1.0-0t64 \
    libatspi2.0-0t64 \
    libcairo2 \
    libcups2t64 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0t64 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    libxshmfence1 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/runner \
    && mkdir -p /actions-runner /workdir \
    && chown -R runner:runner /actions-runner /workdir

USER runner
WORKDIR /actions-runner

RUN curl -fsSL -o /tmp/runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${TARGETARCH}-${RUNNER_VERSION}.tar.gz" \
    && tar xzf /tmp/runner.tar.gz -C /actions-runner \
    && rm /tmp/runner.tar.gz \
    && sudo ./bin/installdependencies.sh \
    && sudo rm -rf /var/lib/apt/lists/*

RUN sh -c "cd $HOME && $(curl -fsLS get.chezmoi.io/lb)" -- init --apply --force --purge-binary kvokka

# The dotfiles run `mise install` for the global tool set, but workflow steps run
# as `bash -e`, not a login shell, so nothing that lives in ~/.zshrc reaches them.
# Reshim explicitly and put the shim directory (and Homebrew's bin, also dragged
# in by the dotfiles) on the image PATH so `gh`, `gcloud`, `mise` & co. resolve
# inside a step without any per-workflow setup.
RUN mise reshim || true
ENV PATH=/home/runner/.local/share/mise/shims:/home/linuxbrew/.linuxbrew/bin:/home/runner/.local/bin:${PATH}

# The dotfiles point core.hooksPath at a shared hook directory, and `prek install`
# refuses to run while it is set outside the repository being installed into.
RUN git config --global --unset-all core.hooksPath || true; \
    sudo git config --system --unset-all core.hooksPath || true

COPY --chown=runner:runner entrypoint.sh /entrypoint.sh
RUN sudo chmod +x /entrypoint.sh

ENV RUNNER_VERSION=${RUNNER_VERSION}

ENTRYPOINT ["/entrypoint.sh"]
