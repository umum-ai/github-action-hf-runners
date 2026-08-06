# github-action-hf-runners

umum-ai runs its GitHub Actions on Hugging Face, on two kinds of runner that share
one image lineage. This repository builds and publishes all three images of it:

| Image | What it is |
|---|---|
| `ghcr.io/umum-ai/github-action-hf-runners/base` | the toolchain, PostgreSQL 17, the Chromium shared libraries, the `ubuntu-latest` parity utilities and the pinned `actions/runner` release — and nothing about how a runner registers. It has no entrypoint |
| `ghcr.io/umum-ai/github-action-hf-runners/jobs-actions-runner` | `FROM base` plus [`entrypoint.sh`](entrypoint.sh): the ephemeral Hugging Face Jobs runner. One container, one job, then gone. Its name is not ours to shorten — see "The ephemeral Jobs runner" below |
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

The dispatcher picks how to start that container from its name alone, before the
container runs: a reference containing the literal substring `jobs-actions-runner`
is treated as a prebuilt runner image and executed through its own
`/entrypoint.sh`; any other reference is treated as a bare image, and the
dispatcher installs an `actions/runner` into it inline, with `apt-get`, as root.
This lineage runs as uid 1000, so an image the dispatcher decides to bootstrap
fails before the job starts — and that is every job in the organization at once.

That is the whole reason the image is published as
`ghcr.io/umum-ai/github-action-hf-runners/jobs-actions-runner` and not under a
tidier name: the substring is the dispatcher's test, the dispatcher Space is a
duplicate of the upstream [`huggingface/jobs-actions`](https://huggingface.co/spaces/huggingface/jobs-actions)
Space and belongs to the owner, and nothing in this repository can change how it
decides. Renaming this image without that substring breaks the whole organization.

`RUNNER_IMAGE_CPU` in that Space is the owner's too, and names the image the
dispatcher starts: `ghcr.io/umum-ai/github-action-hf-runners/jobs-actions-runner:latest`.

## The Space runners

Three Hugging Face Spaces in the `kvokka` namespace — `siam-gha-runner-1`,
`siam-gha-runner-2` and `siam-gha-runner-3` — each run the `space-runner` image on
`cpu-basic` hardware. They are created and configured by `siam-infra`, which is
where their names come from too.

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

The Space passes its inputs in as environment. Three come from `siam-infra`, which
sets them on all three Spaces alike:

| | Set as | |
|---|---|---|
| `GH_APP_ID` | Space variable | `4495616` |
| `GH_ORG` | Space variable | the organization the runner joins |
| `GH_APP_PRIVATE_KEY` | Space secret | base64 of the App's PEM private key; a PEM cannot travel as a single-line Space secret |

That is the whole set, and there is deliberately no fourth. What distinguishes one
Space from the other two is `SPACE_ID` — `<namespace>/<space>`, which Hugging Face
injects into every Space itself — so a runner's name is derived rather than
configured, and no name has to be kept in step in two repositories at once.

A registration is named `<space>-<container start>-<jobs taken>`. Both suffixes
earn their place: a just-in-time runner removes itself when its job ends, but "the
job ended" and "the registration is gone" are not the same instant, so the counter
keeps the next turn of the loop from colliding with a registration still on its way
out, and the start epoch keeps a restarted Space from reusing the names the
previous container left behind.

Everything else the supervisor reads — `RUNNER_LABELS`, `RUNNER_GROUP_ID`,
`RUNNER_WORKDIR`, `APP_PORT`, `STATE_FILE`, `GITHUB_API` — is defaulted in
[`Dockerfile.space-runner`](Dockerfile.space-runner) and set by nobody. `APP_PORT`
defaults to 7860 and is the one to watch: a Space's `app_port` is declared in its
own README front matter by `siam-infra`, and a Space whose front matter names a
port nothing listens on never leaves the starting stage. Both say 7860.

### What a Space imposes

Four rules, all load-bearing:

- **It must answer HTTP on `app_port` or it is killed.** A Space that has not become
  healthy within `startup_duration_timeout` — 30 minutes by default — is flagged
  unhealthy and stopped. [`health-server.py`](health-server.py) is therefore started
  before anything else and outlives every registration:

  ```console
  $ curl https://kvokka-siam-gha-runner-1.hf.space/
  {"healthy":true,"image_revision":"9f1c...","jobs_taken":4,"reason":null,"runner_alive":true,"state":"waiting-for-job","uptime_seconds":51840}
  ```

  `/` always answers 200 — that is the liveness the platform probes, and a container
  that cannot register must still be reachable to be diagnosed at all. `/health`
  answers 200 only while the runner is actually able to take a job, and 503
  otherwise. These Spaces are public, because a private one could only be probed
  with a token this repository is not allowed to hold, so the payload is four facts
  and nothing else: whether the supervisor is alive, how many jobs this container
  has taken, the commit its image was built from, and `reason`.

  `reason` is why the runner is not working, and null while it is. A Space that
  cannot take a job says so where anyone can read it, because the only other place
  that says it — the Space's own run log — needs an owner token:

  ```console
  $ curl https://kvokka-siam-gha-runner-1.hf.space/
  {"healthy":false,"image_revision":"a83d...","jobs_taken":0,"reason":"GH_APP_PRIVATE_KEY is not the base64 of a PEM private key","runner_alive":true,"state":"misconfigured","uptime_seconds":233}
  ```

  It is one of four sentences, all of them literals of
  [`supervisor.sh`](supervisor.sh):

  | State | `reason` |
  |---|---|
  | `misconfigured` | `required environment variables are not set: <names>` |
  | `misconfigured` | `GH_APP_PRIVATE_KEY is not the base64 of a PEM private key` |
  | `error-backoff` | `the GitHub API did not return an installation token for this organization` |
  | `error-backoff` | `the GitHub API did not return a just-in-time runner configuration` |

  What a reason may say is bounded by the endpoint being public and
  unauthenticated: which variable is unset, what *shape* a credential failed to
  have, or what the GitHub API did not return. Never anything derived from a
  credential's value — not a prefix, not a length, not a hash — and never a body an
  API sent back. [`smoke.sh`](smoke.sh) starts the image with an unusable key and
  fails if any part of that value reaches the payload.

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
./smoke.sh base                ghcr.io/umum-ai/github-action-hf-runners/base:latest
./smoke.sh jobs-actions-runner ghcr.io/umum-ai/github-action-hf-runners/jobs-actions-runner:latest
./smoke.sh space-runner        ghcr.io/umum-ai/github-action-hf-runners/space-runner:latest
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

`base` additionally proves it carries no entrypoint of its own. `jobs-actions-runner`
proves its entrypoint is present, executable and parses. `space-runner` is then
*started*, twice, and its health endpoint read over TCP from outside the container
each time. With no credentials in the environment it has to answer, report
`misconfigured` rather than dying, name every unset variable in its `reason`,
expose nothing beyond liveness, job count, image revision and that reason, and
answer 200 on `/` while `/health` answers 503. With every variable set but a
`GH_APP_PRIVATE_KEY` that is not the base64 of a PEM, its `reason` has to be
exactly that sentence — and no part of the value handed in may appear anywhere in
the payload.

[`.hadolint.yaml`](.hadolint.yaml) lints the three Dockerfiles, `shellcheck` the
three shell scripts, and the health server has to compile — all before any image is
built.

## Keeping the Spaces awake

[`space-health.yml`](.github/workflows/space-health.yml) reads the health endpoint of
all three Spaces every six hours and fails on any that does not answer, or that
answers while reporting itself unhealthy. A failure carries the `reason` the Space
gave in its own annotation, so a failed run names the cause on its face instead of
sending a reader to a log they need an owner token to open. It uses no credential.

The schedule is not only a monitor: `cpu-basic` hardware stops a Space after 48
hours with no inbound traffic, that timer is not configurable, and a runner's own
traffic is outbound only. This is the inbound traffic.

The same run reads one more Space, which carries no image of this repository: the
dispatcher at `kvokka/jobs-actions-dispatcher`, the Space GitHub delivers
`workflow_job` to and the only thing that turns an `hf-jobs-*` label into a
Hugging Face Job. Its `/healthz` answers `{"status":"ok"}` when it is configured
and `needs-config` when its GitHub App settings are not, and both are judged: a
dispatcher that is up and unconfigured dispatches nothing.

It sleeps on the same 48-hour terms and matters more when it does. A webhook
arriving at a sleeping Space is not what wakes it in time — the job it announced
stays queued until the workflow is rerun or the delivery is redelivered. That is
what this read prevents, and it is why a job that sits queued forever on an
`hf-jobs-*` label is worth checking here first.

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
