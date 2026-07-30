# jobs-actions-runner

This repository builds and publishes `ghcr.io/umum-ai/jobs-actions-runner`, the container
image that umum-ai's self-hosted GitHub Actions runners run inside. Each container
registers itself with GitHub as an ephemeral runner, picks up exactly one queued job,
and exits — there is no long-lived runner and no state carried between jobs.

The image is built from [`Dockerfile`](Dockerfile) and started by
[`entrypoint.sh`](entrypoint.sh). Pushes to `main` publish `:latest` and `:<commit sha>`;
a `v*` tag additionally publishes `:<tag>`. See
[`.github/workflows/publish.yml`](.github/workflows/publish.yml) — it runs on
`ubuntu-latest` rather than on our own runners, because this
[`Dockerfile`](Dockerfile) has `RUN` steps and a runner cannot execute one (see
[Building images](#building-images)).

## Using it

In any repository in the organization, put the label on the job:

```yaml
jobs:
  build:
    runs-on: hf-jobs-cpu-upgrade
```

That is the whole integration. Nothing else in the consuming workflow changes.

## How a job gets a runner

A [GitHub App](https://github.com/organizations/umum-ai/settings/apps/huggingface-runners),
installed organization-wide, delivers `workflow_job.queued` webhooks to the dispatcher
Space at <https://huggingface.co/spaces/kvokka/jobs-actions-dispatcher>. The dispatcher
translates the `hf-jobs-*` label into a Hugging Face Jobs flavor, mints a one-shot runner
registration token, and starts a Job with this image. The Space's `RUNNER_IMAGE_CPU`
environment variable is what points it here:

```text
RUNNER_IMAGE_CPU=ghcr.io/umum-ai/jobs-actions-runner:latest
```

The dispatcher treats an image whose name contains `jobs-actions-runner` as prebuilt and
executes `/entrypoint.sh` in it instead of bootstrapping a runner inline, so the image
name matters — do not rename it.

## What is in the image

Ubuntu 24.04 with a pinned [`actions/runner`](https://github.com/actions/runner) release,
the dependencies `installdependencies.sh` asks for, and the set of command-line tools that
workflows written against `ubuntu-latest` quietly assume: `zstd` (used by `actions/cache`
and `actions/upload-artifact`, which fall back to a much slower gzip path without it),
`file`, `pkg-config`, `gawk`, `gettext-base`, `sqlite3`, `postgresql-client`, and the usual
network debugging handful (`ip`, `ping`, `dig`, `lsof`, `nc`). It also carries the shared
libraries Chromium links against, so `pnpm exec playwright install chromium` works without
`--with-deps` and without an apt round-trip on every run, and `buildah` and `skopeo`, which
are how a job reaches an OCI image without a daemon (see
[Building images](#building-images)).

Language toolchains do not come from the image. The build applies
[kvokka's dotfiles](https://github.com/kvokka/dotfiles) with chezmoi, which installs
[mise](https://mise.jdx.dev) and runs `mise install` against the dotfiles' global tool
config — that is where `gh`, `gcloud`, Node, Go, Python and friends come from. Because
workflow steps run as `bash -e` and not as a login shell, none of the dotfiles' shell
initialization is in effect during a step, so the image instead puts mise's shim directory
on `PATH` directly. Version pinning stays where it belongs: in the consuming repository's
own mise config, or in the dotfiles' global one. The image pins nothing but the runner.

Homebrew arrives with the same dotfiles; rather than carry it as an unreachable few hundred
megabytes, its `bin` directory is on `PATH` too, so anything installed through it is usable
from a step.

The dotfiles also set a global `core.hooksPath`, which makes `prek install` refuse to run.
The image clears that setting, and `entrypoint.sh` clears it again before starting the
runner.

## Smoke tests

Nothing reaches GHCR unverified. [`publish.yml`](.github/workflows/publish.yml) builds the
image into the runner's own docker daemon, runs [`smoke.sh`](smoke.sh) against it, and
pushes only if that passes. The script checks that the advertised tool set *works* rather
than merely being installed: `jq` parses a document, `zstd` survives a round trip, `sqlite3`
creates a table and reads it back, `envsubst` expands a variable, a bare `sudo buildah build`
produces an image that `skopeo` can read back, the Chromium shared libraries are in the
linker cache, the runner binary reports the version the image advertises, and
`core.hooksPath` is unset in both the global and the system git config.
Every check runs in a non-login, non-interactive shell — the shell a workflow step gets —
so a tool that only resolves out of shell initialization fails here exactly as it would in
a job.

The script takes an image reference and can be pointed at anything, including what is live:

```bash
./smoke.sh ghcr.io/umum-ai/jobs-actions-runner:latest
```

## Bumping the runner version

Change `ARG RUNNER_VERSION` in the [`Dockerfile`](Dockerfile) to a release tag from
[actions/runner](https://github.com/actions/runner/releases) (without the leading `v`) and
push to `main`. The runner is started with `--disableupdate`, so the pin is what actually
runs; nothing self-updates mid-job.

## Building images

There is no docker daemon on these runners, and there is no way to start one: a job runs
already inside somebody else's user namespace, without `CAP_SYS_ADMIN`, and the kernel
refuses both `unshare(CLONE_NEWUSER)` and `unshare(CLONE_NEWNS)`. `mount(2)` is refused in
every form, including a plain bind mount, and `/sys/fs/cgroup` is read only. Images are
therefore built with [buildah](https://buildah.io), which keeps its whole graph in ordinary
directories under the `vfs` driver and never mounts anything:

```yaml
jobs:
  image:
    runs-on: hf-jobs-cpu-upgrade
    steps:
      - uses: actions/checkout@v4
      - run: sudo buildah build -t ghcr.io/umum-ai/thing:${{ github.sha }} .
      - run: |
          sudo buildah login -u "${{ github.actor }}" -p "${{ secrets.GITHUB_TOKEN }}" ghcr.io
          sudo buildah push ghcr.io/umum-ai/thing:${{ github.sha }}
```

`sudo` is not decoration: buildah has to be euid 0 to write a store whose files carry
foreign ownership. It needs no flags — the storage driver, the isolation and the two
variables that keep buildah from re-execing itself into a user namespace it cannot have all
come from the image. [`skopeo`](https://github.com/containers/skopeo) is there too, for
copying a finished image between a registry, the local store and a tarball.

**A Dockerfile built here may not execute anything.** `RUN` fails —
`creating new mount namespace ...: operation not permitted` — and so does anything else that
starts a process inside the image being built. `FROM`, `COPY`, `ADD`, `ENV`, `WORKDIR`,
`ENTRYPOINT` and the rest of the metadata instructions all work, base images are pulled and
unpacked normally, and a `FROM scratch` build needs no registry at all. So the compiling,
the `pnpm install`, the `pip install` happen in workflow steps, on the runner, and the
Dockerfile only copies the result in. Building the runner image itself is the counterexample
— [`Dockerfile`](Dockerfile) is full of `RUN` — which is why
[`publish.yml`](.github/workflows/publish.yml) stays on `ubuntu-latest`.

BuildKit is not in the image. Its first act on any build, before it has even read the
Dockerfile, is to mount its own snapshot read only, and that mount is refused here; every
worker shape it offers — rootful, rootless, `--oci-worker-no-process-sandbox`, the `native`
snapshotter, `buildctl-daemonless.sh` — fails at the same call.
[`.github/workflows/probe-image-build.yml`](.github/workflows/probe-image-build.yml) is the
measurement; it walks BuildKit, buildah and runc itself across every worker shape and
reports one `RESULT` line each. It runs on demand, and on a pull request that changes it.

## Known limitations

The image does have a docker client — it arrives transitively with the dotfiles' global mise
tool set rather than from the [`Dockerfile`](Dockerfile) — but a Hugging Face Job has no
docker daemon for it to talk to. Jobs that use `services:`, `docker/setup-buildx-action`,
`docker build`/`run`/`push`, or `docker compose` fail on `hf-jobs-cpu-upgrade` partway
through, with `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` rather
than a missing command. Building and pushing an image has an answer here (see
[Building images](#building-images)); running one does not, so a job that needs a container
to actually execute belongs on `ubuntu-latest`.

There is also no `/opt/hostedtoolcache`, so `actions/setup-node`, `actions/setup-python`
and the rest of the `actions/setup-*` family download their toolchain on every run instead
of finding a preinstalled copy. Where that hurts, prefer mise (already present) over
`actions/setup-*`.

## Package visibility

Hugging Face Jobs pulls the image anonymously, so the GHCR package must be public. If a
fresh package is published private, open
<https://github.com/orgs/umum-ai/packages/container/jobs-actions-runner/settings> and, under
**Danger Zone → Change package visibility**, set it to **Public**.
