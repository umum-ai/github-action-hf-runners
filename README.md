# github-action-hf-runners

umum-ai runs its GitHub Actions on Hugging Face, on two kinds of runner that
share one image lineage. This repository builds and publishes its three images:

| Image | What it is |
|---|---|
| `ghcr.io/umum-ai/github-action-hf-runners/base` | the toolchain, PostgreSQL 17, the Chromium shared libraries, the `ubuntu-latest` parity utilities and the pinned [`actions/runner`](https://github.com/actions/runner) release — and nothing about how a runner registers. It has no entrypoint |
| `ghcr.io/umum-ai/github-action-hf-runners/jobs-actions-runner` | `FROM` base plus [`entrypoint.sh`](entrypoint.sh): the ephemeral Hugging Face Jobs runner behind the `hf-jobs-*` labels. One container, one job, then gone |
| `ghcr.io/umum-ai/github-action-hf-runners/space-runner` | `FROM` base plus [`supervisor.sh`](supervisor.sh) and [`health-server.py`](health-server.py): the long-lived runner behind `hf-spaces`, living in a Hugging Face Space and registering itself afresh for every job |

Every image is published as `:latest` and as `:<commit sha>`; an `X.Y.Z` tag
adds `:<tag>`. [`publish.yml`](.github/workflows/publish.yml) builds each
image, runs [`smoke.sh`](smoke.sh) against it, and pushes only what passed.

Which label a job declares is the `ci-and-build` capability of `siam-platform`.

## The Jobs runner

The dispatcher Space turns a queued `hf-jobs-*` job into one Hugging Face Job
running this image; the container registers against the repository the job came
from, takes it, and exits.

The image's name is load-bearing. The dispatcher decides how to start a
container from its image reference alone: a reference carrying the literal
substring `jobs-actions-runner` runs through its own `/entrypoint.sh`, and any
other reference gets an inline runner install as root — which this lineage,
running as uid 1000, cannot take. Renaming the image fails every `hf-jobs-*`
job in the organization.

## The Space runner

The container holds a GitHub App credential and registers itself, against the
organization rather than a repository. [`supervisor.sh`](supervisor.sh) loops:
exchange the App credential for an installation token, fetch a just-in-time
runner configuration carrying the `hf-spaces` label, run the runner for one
job, round again. A JIT runner removes its own registration when its job ends,
so a container killed mid-job leaves no zombie registration behind.

A Space running the image sets three inputs; the Spaces that do are
`siam-infra`'s — the `deployment-ownership` capability of `siam-platform`.

| | Set as | |
|---|---|---|
| `GH_APP_ID` | Space variable | the App whose key the Space holds |
| `GH_ORG` | Space variable | the organization the runner joins |
| `GH_APP_PRIVATE_KEY` | Space secret | base64 of the App's PEM private key; a PEM cannot travel as a single-line Space secret |

There is deliberately no fourth: the runner's name is derived from `SPACE_ID`,
which Hugging Face injects into every Space itself. Everything else the
supervisor reads is defaulted in
[`Dockerfile.space-runner`](Dockerfile.space-runner).

[`health-server.py`](health-server.py) answers HTTP on `APP_PORT` — 7860, the
`app_port` of the Space's own front matter. `/` is liveness and always answers
200; `/health` answers 200 only while the runner can take a job, and 503
otherwise, with a `reason` naming which variable is unset, what shape a
credential failed to have, or what the GitHub API did not return — never
anything derived from a credential's value.

## What a job finds in the images

Every step runs as `runner`, uid 1000, never root.

- **Toolchains come from mise, not from the image**: the global tool set of
  [kvokka's dotfiles](https://github.com/kvokka/dotfiles), with mise's shim
  directory and Homebrew's `bin` on `PATH` — `gh`, `gcloud`, Node, Go, Python
  and friends. Version pins belong in the consuming repository's own mise
  config; the image pins nothing but the runner. There is no
  `/opt/hostedtoolcache`, so `actions/setup-*` downloads its toolchain on
  every run — prefer mise.
- **PostgreSQL 17 is in the image as a server**, with
  `/usr/lib/postgresql/17/bin` on `PATH`. This is how a job gets a database —
  `services:` needs a docker daemon and these runners have none. The image
  ships no cluster; the job creates the one it wants:

  ```yaml
  - name: Start PostgreSQL
    run: |
      initdb -D "$RUNNER_TEMP/pgdata" --auth=trust
      pg_ctl -D "$RUNNER_TEMP/pgdata" -l "$RUNNER_TEMP/pg.log" -o "-k $RUNNER_TEMP" start
      createdb -h 127.0.0.1 myapp_test
  ```

  The `-k` is not optional: a step runs as `runner`, and the socket directory
  compiled into the server, `/var/run/postgresql`, belongs to `postgres`. The
  cluster answers on `127.0.0.1:5432` as well as on the socket, so a
  `DATABASE_URL` pointed at `localhost` needs no change.

- **The Chromium shared libraries are present**, so
  `pnpm exec playwright install chromium` works without `--with-deps` and
  without an apt round-trip on every run.
- **The `ubuntu-latest` parity utilities**: `zstd` (`actions/cache` and
  `actions/upload-artifact` fall back to a much slower gzip path without it),
  `file`, `pkg-config`, `gawk`, `gettext-base`, `sqlite3`, and the network
  debugging handful (`ip`, `ping`, `dig`, `lsof`, `nc`).
- **A docker client with no daemon to talk to**: a job using `services:`,
  `docker build`/`run`/`push` or `docker compose` fails on both labels and
  belongs on `ubuntu-latest`.
- **Outbound traffic from a Space is limited to ports 80, 443 and 8080**: a
  job that dials any other port fails on `hf-spaces` and passes on
  `hf-jobs-cpu-upgrade`.
