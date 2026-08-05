# github-action-hf-runners

umum-ai runs its GitHub Actions on Hugging Face, on two kinds of runner that share
one image lineage. This repository builds and publishes all three images of it:

| Image | What it is |
|---|---|
| `ghcr.io/umum-ai/github-action-hf-runners/base` | the toolchain, PostgreSQL 17, the Chromium shared libraries, the `ubuntu-latest` parity utilities and the pinned `actions/runner` release — and nothing about how a runner registers. It has no entrypoint |
| `ghcr.io/umum-ai/github-action-hf-runners/jobs-runner` | `FROM base` plus [`entrypoint.sh`](entrypoint.sh): the ephemeral Hugging Face Jobs runner. One container, one job, then gone |
| `ghcr.io/umum-ai/github-action-hf-runners/space-runner` | `FROM base` plus [`supervisor.sh`](supervisor.sh) and [`health-server.py`](health-server.py): the long-lived runner that lives in a Hugging Face Space and registers itself for every job |

Every image is published as `:latest` and as `:<commit sha>`; a `v*` tag adds
`:<tag>`. Nothing is pushed that has not passed [`smoke.sh`](smoke.sh) first — see
[`.github/workflows/publish.yml`](.github/workflows/publish.yml), which runs on
`ubuntu-latest` because building an image needs a docker daemon and neither of
these runners has one.

## Choosing a runner

In any repository in the organization, the label on the job is the whole
integration:

```yaml
jobs:
  build:
    runs-on: hf-jobs-cpu-upgrade   # an ephemeral container, started per job
  checks:
    runs-on: hf-spaces             # one of three long-lived Space runners
```

`hf-jobs-cpu-upgrade` is the default choice. `hf-spaces` is for a job that wants a
runner already up: nothing is started, the container is waiting.

## The ephemeral Jobs runner

A [GitHub App](https://github.com/organizations/umum-ai/settings/apps/huggingface-runners),
installed organization-wide, delivers `workflow_job.queued` webhooks to the
dispatcher Space at <https://huggingface.co/spaces/kvokka/jobs-actions-dispatcher>.
The dispatcher translates the `hf-jobs-*` label into a Hugging Face Jobs flavor,
mints a one-shot registration token, and starts a Job with the runner image its
`RUNNER_IMAGE_CPU` variable names. The container registers against the one
repository the job came from, takes it, and exits.

Two lines in that Space decide which image runs, and both are the owner's to
change: `RUNNER_IMAGE_CPU`, and the line that recognises an image as prebuilt — it
matches the literal substring `jobs-actions-runner` in the reference and executes
`/entrypoint.sh` in it instead of bootstrapping a runner inline. Until both name
`ghcr.io/umum-ai/github-action-hf-runners/jobs-runner`, Jobs runners keep starting
from the package `ghcr.io/umum-ai/jobs-actions-runner:latest`, which is no longer
published from here and is kept in place for exactly that reason.

## The Space runners

Three Hugging Face Spaces in the `kvokka` namespace — `space-runner-1`,
`space-runner-2` and `space-runner-3` — each run the `space-runner` image on
`cpu-basic` hardware. They are created and configured by `siam-infra`, not from
here.

Registration is nothing like the Jobs runner's. There is no dispatcher and no
webhook: the container holds a GitHub App credential and registers *itself*,
against the organization rather than a repository. Its App is
`umum-ai/huggingface-space-runners`, app id `4495616`, and its only permission is
`organization_self_hosted_runners: write` — enough for the two endpoints below and
nothing else.

[`supervisor.sh`](supervisor.sh) loops:

1. sign an App JWT, exchange it for an installation token
2. `POST /orgs/umum-ai/actions/runners/generate-jitconfig` for a fresh just-in-time
   configuration, with the label `hf-spaces` and a name that distinguishes this
   Space from the other two
3. `./run.sh --jitconfig <encoded>` — a JIT runner is inherently ephemeral: it takes
   one job, then removes its own registration. No removal token is held and no
   cleanup trap is needed, so a container killed mid-job leaves no zombie
   registration behind
4. round again. The Space stays up; every job still gets a registration of its own

The runner joins the runner group `Default` (`runner_group_id: 1`). Organization
runner groups beyond that one require GitHub Team, so the label — not the group —
is what a workflow selects on.

The Space passes its inputs in as environment, set by `siam-infra`:

| Variable | |
|---|---|
| `GH_APP_ID` | `4495616` |
| `GH_APP_PRIVATE_KEY` | base64 of the App's PEM private key; a PEM cannot travel as a single-line Space secret |
| `ORG_NAME` | the organization the runner joins |
| `RUNNER_NAME` | what distinguishes this Space from the other two |

### What a Space imposes

Four rules, all load-bearing:

- **It must answer HTTP on `app_port` or it is killed.** A Space that has not become
  healthy within `startup_duration_timeout` — 30 minutes by default — is flagged
  unhealthy and stopped. [`health-server.py`](health-server.py) is therefore started
  before anything else and outlives every registration:

  ```console
  $ curl https://kvokka-space-runner-1.hf.space/
  {"healthy":true,"image_revision":"9f1c...","jobs_taken":4,"runner_alive":true,"state":"waiting-for-job","uptime_seconds":51840}
  ```

  `/` always answers 200 — that is the liveness the platform probes, and a container
  that cannot register must still be reachable to be diagnosed at all. `/health`
  answers 200 only while the runner is actually able to take a job, and 503
  otherwise. These Spaces are public, because a private one could only be probed
  with a token this repository is not allowed to hold, so the payload is three facts
  and nothing else: whether the supervisor is alive, how many jobs this container
  has taken, and the commit its image was built from.

- **The application runs as uid 1000, never root.** `ubuntu:24.04` already ships a
  user at that uid; [`Dockerfile.base`](Dockerfile.base) removes it and gives the uid
  to `runner`, so one account owns the home directory, the toolchain and the runner
  directory in all three images.

- **Outbound traffic is limited to ports 80, 443 and 8080.** Everything a runner
  reaches — `api.github.com`, `github.com`, GHCR — is 443, so a normal job is
  unaffected. A job that dials any other port fails on `hf-spaces` and passes on
  `hf-jobs-cpu-upgrade`.

- **Any change to a Space's secrets restarts it**, killing whatever job is running at
  that moment. Rotating the App key, or applying anything in `siam-infra` that writes
  a Space secret, is disruptive by construction.

## What is in the base image

Ubuntu 24.04 with a pinned [`actions/runner`](https://github.com/actions/runner)
release, the dependencies `installdependencies.sh` asks for, and the set of
command-line tools that workflows written against `ubuntu-latest` quietly assume:
`zstd` (used by `actions/cache` and `actions/upload-artifact`, which fall back to a
much slower gzip path without it), `file`, `pkg-config`, `gawk`, `gettext-base`,
`sqlite3`, and the usual network debugging handful (`ip`, `ping`, `dig`, `lsof`,
`nc`). It also carries the shared libraries Chromium links against, so
`pnpm exec playwright install chromium` works without `--with-deps` and without an
apt round-trip on every run.

PostgreSQL 17 is in the image as a server, not only a client. Both come from
[PGDG](https://apt.postgresql.org), because Ubuntu 24.04 itself carries only the 16
branch, and `/usr/lib/postgresql/17/bin` is on `PATH`, so `initdb`, `pg_ctl`,
`pg_isready`, `createdb` and `psql` resolve inside a step without a full path. This
is how a job gets a database here — `services:` needs a docker daemon, and these
runners have none. The image ships no cluster of its own; the job creates the one it
wants:

```yaml
- name: Start PostgreSQL
  run: |
    initdb -D "$RUNNER_TEMP/pgdata" --auth=trust
    pg_ctl -D "$RUNNER_TEMP/pgdata" -l "$RUNNER_TEMP/pg.log" -o "-k $RUNNER_TEMP" start
    createdb -h 127.0.0.1 myapp_test
```

The `-k` is not optional: a step runs as `runner`, and the socket directory compiled
into the server, `/var/run/postgresql`, belongs to `postgres`, so a cluster started
without it dies creating its lock file. With it, the cluster answers on
`127.0.0.1:5432` as well as on the socket, so a `DATABASE_URL` pointed at
`localhost` needs no change.

Language toolchains do not come from the image. The build applies
[kvokka's dotfiles](https://github.com/kvokka/dotfiles) with chezmoi, which installs
[mise](https://mise.jdx.dev) and runs `mise install` against the dotfiles' global
tool config — that is where `gh`, `gcloud`, Node, Go, Python and friends come from.
Because workflow steps run as `bash -e` and not as a login shell, none of the
dotfiles' shell initialization is in effect during a step, so the image instead puts
mise's shim directory on `PATH` directly. Version pinning stays where it belongs: in
the consuming repository's own mise config, or in the dotfiles' global one. The
image pins nothing but the runner.

Homebrew arrives with the same dotfiles; rather than carry it as an unreachable few
hundred megabytes, its `bin` directory is on `PATH` too, so anything installed
through it is usable from a step.

The dotfiles also set a global `core.hooksPath`, which makes `prek install` refuse to
run. The image clears that setting, and `entrypoint.sh` clears it again before
starting the runner.

The `space-runner` image adds two packages of its own: `openssl`, which signs the App
JWT, and the distribution's `python3`, which runs the health server. That interpreter
is deliberately not the toolchain's `python` — a health server the Space is killed
without must not depend on what the dotfiles happen to resolve to.

## Smoke tests

Nothing reaches GHCR unverified.
[`publish.yml`](.github/workflows/publish.yml) builds each image into the runner's
own docker daemon, runs [`smoke.sh`](smoke.sh) against it, and pushes only what
passed — the derived images build `FROM` the base that has just passed, not from
whatever the registry currently serves.

```bash
./smoke.sh base         ghcr.io/umum-ai/github-action-hf-runners/base:latest
./smoke.sh jobs-runner  ghcr.io/umum-ai/github-action-hf-runners/jobs-runner:latest
./smoke.sh space-runner ghcr.io/umum-ai/github-action-hf-runners/space-runner:latest
```

Every mode runs the base checks, which prove that the advertised tool set *works*
rather than merely being installed: `jq` parses a document, `zstd` survives a round
trip, `sqlite3` creates a table and reads it back, `envsubst` expands a variable, an
`initdb` cluster starts and answers `SELECT 1` before being stopped again, the
Chromium shared libraries are in the linker cache, the runner binary reports the
version the image advertises, the container runs as uid 1000, and `core.hooksPath`
is unset in both the global and the system git config. They run in a non-login,
non-interactive shell — the shell a workflow step gets — so a tool that only
resolves out of shell initialization fails here exactly as it would in a job.

`base` additionally proves it carries no entrypoint of its own. `jobs-runner` proves
its entrypoint is present, executable and parses. `space-runner` is then *started*:
the checks read its health endpoint over TCP from outside the container, with no
credentials in the environment, and require that it answers, that it reports
`misconfigured` rather than dying, that it exposes nothing beyond liveness, job
count and image revision, and that `/` answers 200 while `/health` answers 503.

[`.hadolint.yaml`](.hadolint.yaml) lints the three Dockerfiles, `shellcheck` the
three shell scripts, and the health server has to compile — all before any image is
built.

## Keeping the Spaces awake

[`space-health.yml`](.github/workflows/space-health.yml) reads the health endpoint of
all three Spaces every six hours and fails on any that does not answer, or that
answers while reporting itself unhealthy. It uses no credential.

The schedule is not only a monitor: `cpu-basic` hardware stops a Space after 48
hours with no inbound traffic, that timer is not configurable, and a runner's own
traffic is outbound only. This is the inbound traffic.

## Bumping the runner version

Change `ARG RUNNER_VERSION` in [`Dockerfile.base`](Dockerfile.base) to a release tag
from [actions/runner](https://github.com/actions/runner/releases) (without the
leading `v`) and push to `main`. The Jobs runner is started with `--disableupdate`,
so the pin is what actually runs there; nothing self-updates mid-job.

## Known limitations

The images do have a docker client — it arrives transitively with the dotfiles'
global mise tool set rather than from a `Dockerfile` here — but neither a Hugging
Face Job nor a Space gives it a daemon to talk to. Jobs that use `services:`,
`docker/setup-buildx-action`, `docker build`/`run`/`push`, or `docker compose`
therefore fail on both labels partway through, with
`Cannot connect to the Docker daemon at unix:///var/run/docker.sock` rather than a
missing command, and should stay on `ubuntu-latest`.

There is also no `/opt/hostedtoolcache`, so `actions/setup-node`,
`actions/setup-python` and the rest of the `actions/setup-*` family download their
toolchain on every run instead of finding a preinstalled copy. Where that hurts,
prefer mise (already present) over `actions/setup-*`.

## Package visibility

Hugging Face pulls these images anonymously, so every GHCR package must be public. A
package published private is fixed at
<https://github.com/orgs/umum-ai/packages> — open it and, under
**Danger Zone → Change package visibility**, set it to **Public**.
