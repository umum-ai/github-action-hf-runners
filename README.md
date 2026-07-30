# jobs-actions-runner

This repository builds and publishes `ghcr.io/umum-ai/jobs-actions-runner`, the container
image that umum-ai's self-hosted GitHub Actions runners run inside. Each container
registers itself with GitHub as an ephemeral runner, picks up exactly one queued job,
and exits — there is no long-lived runner and no state carried between jobs.

The image is built from [`Dockerfile`](Dockerfile) and started by
[`entrypoint.sh`](entrypoint.sh). Pushes to `main` publish `:latest` and `:<commit sha>`;
a `v*` tag additionally publishes `:<tag>`. See
[`.github/workflows/publish.yml`](.github/workflows/publish.yml) — it runs on
`ubuntu-latest` rather than on our own runners, because building an image needs a
docker daemon and these runners do not have one.

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
`--with-deps` and without an apt round-trip on every run.

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

## Bumping the runner version

Change `ARG RUNNER_VERSION` in the [`Dockerfile`](Dockerfile) to a release tag from
[actions/runner](https://github.com/actions/runner/releases) (without the leading `v`) and
push to `main`. The runner is started with `--disableupdate`, so the pin is what actually
runs; nothing self-updates mid-job.

## Known limitations

There is no docker in the image and no docker daemon in a Hugging Face Job. Jobs that use
`services:`, `docker/setup-buildx-action`, `docker build`/`run`/`push`, or `docker compose`
will not work on `hf-jobs-cpu-upgrade` and should stay on `ubuntu-latest` for now.

There is also no `/opt/hostedtoolcache`, so `actions/setup-node`, `actions/setup-python`
and the rest of the `actions/setup-*` family download their toolchain on every run instead
of finding a preinstalled copy. Where that hurts, prefer mise (already present) over
`actions/setup-*`.

## Package visibility

Hugging Face Jobs pulls the image anonymously, so the GHCR package must be public. If a
fresh package is published private, open
<https://github.com/orgs/umum-ai/packages/container/jobs-actions-runner/settings> and, under
**Danger Zone → Change package visibility**, set it to **Public**.
