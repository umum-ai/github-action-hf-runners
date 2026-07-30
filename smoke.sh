#!/usr/bin/env bash
#
# Smoke tests for the jobs-actions runner image.
#
#   ./smoke.sh [image-ref]        # defaults to ghcr.io/umum-ai/jobs-actions-runner:latest
#
# The checks prove that the tool set the image advertises actually works, not
# that files are present: jq parses, zstd round-trips, sqlite3 stores and reads
# back, envsubst substitutes, a PostgreSQL cluster comes up and answers a query
# before it is stopped again. They run inside a non-login, non-interactive
# shell, which is the shell a GitHub Actions step gets, so a tool that only
# resolves from shell initialization counts as broken here too.
#
# The first failed check exits non-zero and says what did not match.

set -euo pipefail

image="${1:-ghcr.io/umum-ai/jobs-actions-runner:latest}"

if ! command -v docker >/dev/null 2>&1; then
    echo "smoke: docker is required to run these checks" >&2
    exit 2
fi

echo "smoke: checking ${image}"

docker run --rm -i --entrypoint bash "${image}" -s <<'CHECKS'
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
                                     "entrypoint.sh execs it once the runner is registered"
pass "the runner binary runs and reports $runner_version"

[ -f /entrypoint.sh ] || fail "/entrypoint.sh is missing"
[ -x /entrypoint.sh ] || fail "/entrypoint.sh is not executable"
pass "/entrypoint.sh is present and executable"

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

[ "$(id -u)" -ne 0 ] || fail "the checks are running as root" \
    "initdb refuses to run as root, and a workflow step is not root either"

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

printf '\nsmoke: all checks passed\n'
CHECKS
