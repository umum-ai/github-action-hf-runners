FROM ubuntu:24.04

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
    postgresql-client \
    sqlite3 \
    tzdata \
    vim-tiny \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# Building and moving OCI images without a daemon. Buildah keeps its whole
# graph in plain directories under the `vfs` driver, so nothing in a build needs
# mount(2) — which is what makes it the one builder that works on a runner
# holding no CAP_SYS_ADMIN. Skopeo copies finished images between a registry,
# the local store and a tarball, again with no daemon in the middle.
RUN apt-get update && apt-get install -y --no-install-recommends \
    buildah \
    skopeo \
    && rm -rf /var/lib/apt/lists/*

# Buildah looks at its own capabilities on startup and, finding no
# CAP_SYS_ADMIN, re-execs itself into a fresh user namespace to get one. That
# namespace is refused here, and buildah exits on
# `unshare(CLONE_NEWUSER): Operation not permitted` before it reads a
# Dockerfile. It skips the re-exec when it is euid 0 and already holds the
# mapped root of somebody else's namespace, which is what these two variables
# assert; _CONTAINERS_ROOTLESS_UID only has to be non-zero. Together with the
# `vfs` driver and chroot isolation they are the whole configuration a build
# needs, so `sudo buildah build -t <ref> .` works with no flags of its own.
ENV BUILDAH_ISOLATION=chroot \
    STORAGE_DRIVER=vfs \
    _CONTAINERS_ROOTLESS_UID=1001 \
    _CONTAINERS_USERNS_CONFIGURED=done

RUN printf '[storage]\ndriver = "vfs"\n' >/etc/containers/storage.conf \
    && printf 'Defaults env_keep += "BUILDAH_ISOLATION STORAGE_DRIVER REGISTRY_AUTH_FILE _CONTAINERS_ROOTLESS_UID _CONTAINERS_USERNS_CONFIGURED"\n' \
       >/etc/sudoers.d/buildah \
    && chmod 0440 /etc/sudoers.d/buildah

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
