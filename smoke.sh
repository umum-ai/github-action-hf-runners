#!/usr/bin/env bash
#
# Smoke tests for the three images this repository publishes.
#
#   ./smoke.sh base         ghcr.io/umum-ai/github-action-hf-runners/base:latest
#   ./smoke.sh jobs-runner  ghcr.io/umum-ai/github-action-hf-runners/jobs-runner:latest
#   ./smoke.sh space-runner ghcr.io/umum-ai/github-action-hf-runners/space-runner:latest
#
# Every mode runs the base checks — they prove that the tool set the lineage
# advertises actually works, not that files are present: jq parses, zstd
# round-trips, sqlite3 stores and reads back, envsubst substitutes, a PostgreSQL
# cluster comes up and answers a query before it is stopped again. They run inside
# a non-login, non-interactive shell, which is the shell a GitHub Actions step
# gets, so a tool that only resolves from shell initialization counts as broken
# here too.
#
# `jobs-runner` adds its entrypoint. `space-runner` adds its supervisor, the
# interpreter and the signing tool it needs, and then starts the image for real
# and reads its health endpoint from outside the container.
#
# The first failed check exits non-zero and says what did not match.

set -euo pipefail

mode="${1:-}"
image="${2:-}"

usage() {
    echo "usage: ./smoke.sh <base|jobs-runner|space-runner> <image-ref>" >&2
    exit 2
}

case "$mode" in
    base | jobs-runner | space-runner) ;;
    *) usage ;;
esac
[ -n "$image" ] || usage

if ! command -v docker >/dev/null 2>&1; then
    echo "smoke: docker is required to run these checks" >&2
    exit 2
fi

echo "smoke: checking ${image} as ${mode}"

# --- checks that run inside the container -----------------------------------

shared_checks=$(
    cat <<'CHECKS'
set -euo pipefail

fail() {
    printf '\nFAIL: %s\n' "$1" >&2
    if [ "$#" -gt 1 ]; then
        printf '      %s\n' "$2" >&2
    fi
    exit 1
}

pass() { printf 'ok  %s\n' "$1"; }

# The harness itself has to be honest: a login shell would source the dotfiles
# and make tools resolve that a workflow step never sees.
if shopt -q login_shell; then
    fail "the checks are running in a login shell" \
         "they must mirror a workflow step, which runs as a plain 'bash -e'"
fi
pass "checks run in a non-login shell"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the image runs as uid 1000 ---------------------------------------------
# A Hugging Face Space runs its container as uid 1000 whatever the image asks
# for, so the account owning the home directory, the toolchain and the runner
# directory is that one throughout the lineage — the Space image inherits the
# uid rather than patching it, and initdb still has a non-root user to run as.
uid=$(id -u)
[ "$uid" = "1000" ] || fail "the image runs as uid $uid, not 1000" \
    "a Space runs its container as uid 1000, and initdb refuses to run as root"
pass "the image runs as uid 1000 ($(id -un))"

# --- the advertised commands run at all ------------------------------------
for tool in gh gcloud mise jq git zstd sqlite3 psql; do
    if out=$("$tool" --version 2>&1); then
        pass "$tool --version -> $(printf '%s\n' "$out" | head -n 1)"
    else
        fail "\`$tool --version\` exited $? — missing from PATH, or present but not runnable" \
             "$(printf '%s\n' "$out" | head -n 3)"
    fi
done

# --- jq really parses JSON --------------------------------------------------
json='{"tools":[{"name":"gh"},{"name":"zstd"}],"count":2}'
if ! got=$(printf '%s' "$json" | jq -r '.tools[1].name + ":" + (.count | tostring)' 2>&1); then
    fail "jq could not parse a JSON document" "$got"
fi
[ "$got" = "zstd:2" ] || fail "jq parsed a JSON document into the wrong value" \
                              "expected 'zstd:2', got '$got'"
pass "jq parses JSON ($got)"

# --- zstd really compresses and decompresses --------------------------------
# actions/cache and actions/upload-artifact hand their payloads to this binary.
plain="$work/payload"
for i in $(seq 1 500); do
    echo "the quick brown fox jumps over the lazy dog $i"
done >"$plain"

zstd -q -f "$plain" -o "$plain.zst" || fail "zstd could not compress a file"
plain_bytes=$(wc -c <"$plain")
packed_bytes=$(wc -c <"$plain.zst")
[ "$packed_bytes" -lt "$plain_bytes" ] || fail "zstd did not compress anything" \
    "$plain_bytes bytes in, $packed_bytes bytes out"
zstd -q -d -f "$plain.zst" -o "$plain.back" || fail "zstd could not decompress what it wrote"
cmp -s "$plain" "$plain.back" || fail "a zstd round trip did not return the original bytes"
pass "zstd round trip ($plain_bytes -> $packed_bytes bytes, restored intact)"

# --- envsubst really substitutes --------------------------------------------
got=$(SMOKE_VALUE=substituted envsubst <<<'value=${SMOKE_VALUE}') \
    || fail "envsubst could not run"
[ "$got" = "value=substituted" ] || fail "envsubst did not expand a variable" \
                                        "expected 'value=substituted', got '$got'"
pass "envsubst expands variables ($got)"

# --- sqlite3 really stores and reads back -----------------------------------
if ! got=$(sqlite3 "$work/smoke.db" \
    "create table t (k text, v integer); insert into t values ('answer', 42); select k || '=' || v from t;" 2>&1); then
    fail "sqlite3 could not create a table and read from it" "$got"
fi
[ "$got" = "answer=42" ] || fail "sqlite3 returned the wrong row" \
                                "expected 'answer=42', got '$got'"
pass "sqlite3 creates a table and reads it back ($got)"

# --- git carries no core.hooksPath ------------------------------------------
# The dotfiles baked into the image set one; a core.hooksPath pointing outside
# the repository being installed into makes `prek install` refuse to run in
# every consuming workflow.
for scope in global system; do
    value=$(git config --"$scope" --get-all core.hooksPath 2>/dev/null || true)
    [ -z "$value" ] || fail "git core.hooksPath is set in the $scope config: $value" \
        "'prek install' refuses to run while it points outside the repository"
    pass "git core.hooksPath is unset ($scope)"
done

# --- the Chromium shared libraries are in the linker cache ------------------
if ! ldcache=$(ldconfig -p 2>&1); then
    fail "ldconfig -p could not be read" "$ldcache"
fi
for lib in libnss3 libgbm.so.1 libatk-1.0.so.0 libatk-bridge-2.0.so.0 libasound.so.2 \
           libcups.so.2 libxkbcommon.so.0 libdrm.so.2 libpango-1.0.so.0 libcairo.so.2; do
    printf '%s\n' "$ldcache" | grep -qF -- "$lib" \
        || fail "$lib is not in the linker cache" \
                "'playwright install chromium' produces a browser that cannot start"
done
pass "the Chromium shared libraries are all in the linker cache"

# --- parity with what ubuntu-latest offers ----------------------------------
for tool in file ip dig lsof nc gawk pkg-config less; do
    path=$(command -v "$tool" 2>/dev/null) \
        || fail "$tool does not resolve on PATH" \
                "workflows written against ubuntu-latest assume it is there"
    pass "$tool -> $path"
done

# --- the runner itself ------------------------------------------------------
if ! out=$(/actions-runner/config.sh --version 2>&1); then
    fail "/actions-runner/config.sh --version failed" "$(printf '%s\n' "$out" | head -n 3)"
fi
runner_version=$(printf '%s\n' "$out" | head -n 1)
[ -n "$runner_version" ] || fail "/actions-runner/config.sh --version printed nothing"
if [ -n "${RUNNER_VERSION:-}" ] && [ "$runner_version" != "$RUNNER_VERSION" ]; then
    fail "the runner binary reports $runner_version but the image advertises RUNNER_VERSION=$RUNNER_VERSION"
fi
[ -x /actions-runner/run.sh ] || fail "/actions-runner/run.sh is missing or not executable" \
                                     "both runners exec it once a registration is in hand"
pass "the runner binary runs and reports $runner_version"

# --- PostgreSQL initializes, starts, serves and stops -----------------------
# A job runs its database as a job process, so the whole cycle has to work for an
# unprivileged user; the binaries being installed proves nothing on its own.
for tool in postgres initdb pg_ctl pg_isready createdb psql; do
    path=$(command -v "$tool" 2>/dev/null) \
        || fail "$tool does not resolve on PATH" \
                "a job cannot be expected to spell out /usr/lib/postgresql/17/bin"
    pass "$tool -> $path"
done

server_version=$(postgres --version 2>&1) || fail "\`postgres --version\` did not run" "$server_version"
case "$server_version" in
    *"(PostgreSQL) 17."*) pass "$server_version" ;;
    *) fail "the server is not on the 17 branch" "postgres --version -> $server_version" ;;
esac

client_version=$(psql --version 2>&1) || fail "\`psql --version\` did not run" "$client_version"
case "$client_version" in
    *"(PostgreSQL) 17."*) pass "$client_version" ;;
    *) fail "the client is not on the same branch as the server" \
            "server: $server_version, client: $client_version" ;;
esac

# No cluster of the image's own: nothing here can start one, and a leftover would
# shadow the data directory a job builds.
clusters=$(pg_lsclusters --no-header 2>/dev/null || true)
[ -z "$clusters" ] || fail "the image ships a cluster of its own" "$clusters"
pass "the image ships no cluster"

pgdata="$work/pgdata"
socket="$work/socket"
mkdir -p "$socket"

if ! out=$(initdb -D "$pgdata" --auth=trust --encoding=UTF8 --no-sync 2>&1); then
    fail "initdb could not create a cluster in $pgdata" "$(printf '%s\n' "$out" | tail -n 5)"
fi
pass "initdb created a cluster as $(id -un)"

# A unix socket inside the temp directory, not a TCP port: two of these running at
# once must not be able to collide.
if ! out=$(pg_ctl -D "$pgdata" -l "$work/pg.log" -o "-k $socket -h ''" start 2>&1); then
    fail "pg_ctl could not start the cluster" \
         "$(printf '%s\n' "$out"; tail -n 20 "$work/pg.log" 2>/dev/null)"
fi

deadline=$((SECONDS + 30))
until pg_isready -h "$socket" -q; do
    [ "$SECONDS" -lt "$deadline" ] \
        || fail "the cluster did not accept connections within 30s" \
                "$(tail -n 20 "$work/pg.log" 2>/dev/null)"
    sleep 1
done
pass "pg_ctl started the cluster and pg_isready reports it accepting connections"

if ! out=$(createdb -h "$socket" smoke 2>&1); then
    fail "createdb could not create a database" "$out"
fi

if ! got=$(psql -h "$socket" -d smoke -Atc 'SELECT 1' 2>&1); then
    fail "psql could not query the database createdb just made" "$got"
fi
[ "$got" = "1" ] || fail "psql returned the wrong value for SELECT 1" \
                        "expected '1', got '$got'"
pass "createdb, then psql -c 'SELECT 1' -> $got"

if ! out=$(pg_ctl -D "$pgdata" -m fast stop 2>&1); then
    fail "pg_ctl could not stop the cluster" "$out"
fi
pass "pg_ctl stopped the cluster"
CHECKS
)

base_only_checks=$(
    cat <<'CHECKS'

# --- the base image is only a base ------------------------------------------
# Whatever starts a runner belongs to an image derived from this one; a base that
# already knew how to register would make the derived images ambiguous.
for path in /entrypoint.sh /supervisor.sh /health-server.py; do
    [ ! -e "$path" ] || fail "the base image carries $path" \
        "registration belongs to jobs-runner and space-runner, not here"
done
pass "the base image carries no runner entrypoint of its own"
CHECKS
)

jobs_runner_checks=$(
    cat <<'CHECKS'

# --- the Jobs entrypoint ----------------------------------------------------
[ -f /entrypoint.sh ] || fail "/entrypoint.sh is missing"
[ -x /entrypoint.sh ] || fail "/entrypoint.sh is not executable"
bash -n /entrypoint.sh || fail "/entrypoint.sh is not valid bash"
pass "/entrypoint.sh is present, executable and parses"
CHECKS
)

space_runner_checks=$(
    cat <<'CHECKS'

# --- the Space supervisor and its health server -----------------------------
for path in /supervisor.sh /health-server.py; do
    [ -f "$path" ] || fail "$path is missing"
    [ -x "$path" ] || fail "$path is not executable"
done
bash -n /supervisor.sh || fail "/supervisor.sh is not valid bash"
pass "/supervisor.sh and /health-server.py are present, executable and parse"

# The interpreter is the distribution's on purpose: the health server is what
# keeps the Space alive, so it must not depend on what the toolchain resolves to.
[ -x /usr/bin/python3 ] || fail "/usr/bin/python3 is missing" \
    "the health server must not depend on the toolchain's interpreter"
/usr/bin/python3 -c 'import http.server, json, socketserver' \
    || fail "the standard library the health server imports is not installed"
/usr/bin/python3 -m py_compile /health-server.py \
    || fail "/health-server.py does not compile"
pass "/usr/bin/python3 runs and compiles the health server"

# `openssl` signs the GitHub App JWT; without it the supervisor mints nothing.
command -v openssl >/dev/null 2>&1 || fail "openssl does not resolve on PATH" \
    "the supervisor signs the App JWT with it"
pass "openssl -> $(command -v openssl)"

[ "${RUNNER_LABELS:-}" = "hf-spaces" ] || fail \
    "the image advertises RUNNER_LABELS='${RUNNER_LABELS:-}' rather than 'hf-spaces'" \
    "a workflow selects this runner by that label"
pass "the image defaults RUNNER_LABELS to hf-spaces"
CHECKS
)

case "$mode" in
    base) checks="${shared_checks}${base_only_checks}" ;;
    jobs-runner) checks="${shared_checks}${jobs_runner_checks}" ;;
    space-runner) checks="${shared_checks}${space_runner_checks}" ;;
esac

printf '%s\n\nprintf "\\nsmoke: in-container checks passed\\n"\n' "$checks" \
    | docker run --rm -i --entrypoint bash "${image}" -s

# --- the Space image, started for real --------------------------------------
# The health server is the one thing a Space cannot be without, so it is checked
# by running the published entrypoint and reading the endpoint over TCP. With no
# credentials in the environment the supervisor reports `misconfigured` and keeps
# answering, which is exactly the state a Space has to stay diagnosable in.

if [ "$mode" = "space-runner" ]; then
    container=$(docker run -d --rm -p 127.0.0.1:0:7860 "${image}")
    # shellcheck disable=SC2064 # the id is wanted now, not when the trap fires
    trap "docker rm -f '${container}' >/dev/null 2>&1 || true" EXIT

    endpoint=$(docker port "${container}" 7860/tcp | head -n 1)
    [ -n "$endpoint" ] || { echo "FAIL: the container published no port" >&2; exit 1; }

    deadline=$((SECONDS + 90))
    until curl -fsS --max-time 5 "http://${endpoint}/" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAIL: the health server did not answer on ${endpoint} within 90s" >&2
            docker logs "${container}" 2>&1 | tail -n 30 >&2
            exit 1
        fi
        docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -q true \
            || { echo "FAIL: the container exited before answering" >&2
                 docker logs "${container}" 2>&1 | tail -n 30 >&2
                 exit 1; }
        sleep 2
    done
    echo "ok  the health server answers on ${endpoint}/"

    body=$(curl -fsS --max-time 5 "http://${endpoint}/")
    for field in state runner_alive jobs_taken image_revision healthy; do
        printf '%s' "$body" | jq -e "has(\"${field}\")" >/dev/null \
            || { echo "FAIL: the health payload has no ${field}: ${body}" >&2; exit 1; }
    done
    echo "ok  the health payload reports ${body}"

    # Nothing a public reader must not see: no organization, no runner name, no
    # token, no label set.
    for leak in token org organization runner_name labels installation; do
        if printf '%s' "$body" | jq -e "has(\"${leak}\")" >/dev/null 2>&1; then
            echo "FAIL: the public health payload exposes ${leak}" >&2
            exit 1
        fi
    done
    echo "ok  the health payload exposes nothing but liveness, count and revision"

    alive=$(printf '%s' "$body" | jq -r '.runner_alive')
    [ "$alive" = "true" ] \
        || { echo "FAIL: runner_alive is ${alive} while the supervisor runs" >&2; exit 1; }

    taken=$(printf '%s' "$body" | jq -r '.jobs_taken')
    [ "$taken" = "0" ] \
        || { echo "FAIL: a container that took no job reports jobs_taken=${taken}" >&2; exit 1; }

    state=$(printf '%s' "$body" | jq -r '.state')
    [ "$state" = "misconfigured" ] || {
        echo "FAIL: with no credentials the supervisor reports '${state}', not 'misconfigured'" >&2
        docker logs "${container}" 2>&1 | tail -n 30 >&2
        exit 1
    }
    echo "ok  with no credentials the supervisor reports misconfigured and stays up"

    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${endpoint}/health")
    [ "$status" = "503" ] \
        || { echo "FAIL: /health answered ${status} for a runner that cannot register, expected 503" >&2; exit 1; }
    echo "ok  /health answers 503 while the runner cannot take a job"

    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${endpoint}/")
    [ "$status" = "200" ] \
        || { echo "FAIL: / answered ${status}, expected 200 — a Space that stops answering is stopped" >&2; exit 1; }
    echo "ok  / answers 200 regardless, which is what keeps the Space alive"
fi

printf '\nsmoke: all checks passed\n'
