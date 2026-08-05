#!/bin/bash
#
# Supervisor for the long-lived Hugging Face Space runner.
#
# It holds a GitHub App credential and registers itself against the organization,
# one just-in-time runner per job: a JIT runner takes exactly one job and removes
# its own registration, so there is no removal token to hold and no cleanup trap
# to get right — a container killed mid-job leaves nothing behind on GitHub.
#
# Required env. The first three are a Space variable or a Space secret, set by
# `siam-infra`; the fourth is injected into every Space by Hugging Face itself, so
# a Space's own identity is never configuration anybody has to keep in step:
#   GH_APP_ID           GitHub App id
#   GH_ORG              organization the runner joins
#   GH_APP_PRIVATE_KEY  base64 of the App's PEM private key; a PEM cannot travel
#                       as a single-line value
#   SPACE_ID            `<namespace>/<space>`, which is where the runner name
#                       comes from
#
# Optional env, all defaulted in the image:
#   RUNNER_LABELS       comma-separated, default `hf-spaces`
#   RUNNER_GROUP_ID     default 1, the `Default` group
#   RUNNER_WORKDIR      default `_work`
#   APP_PORT            port the health server answers on
#   STATE_FILE          where the health server reads state from
#   GITHUB_API          API base, default https://api.github.com

# Deliberately no `-e`: a failed API call is a backoff, not the end of the Space.
set -uo pipefail

: "${RUNNER_LABELS:=hf-spaces}"
: "${RUNNER_GROUP_ID:=1}"
: "${RUNNER_WORKDIR:=_work}"
: "${APP_PORT:=7860}"
: "${STATE_FILE:=/tmp/runner-state.json}"
: "${GITHUB_API:=https://api.github.com}"
: "${IMAGE_REVISION:=unknown}"

export APP_PORT STATE_FILE IMAGE_REVISION

jobs_taken=0
health_pid=""
key_file=""
runner_base=""

# Fixed for the life of this container, and half of what makes a runner name
# unique: the counter separates one registration from the next, this separates
# this container's names from those a previous one may still hold.
boot_epoch=$(date +%s)

log() { printf '%s supervisor: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Written whole and moved into place, so the health server never reads half a
# document. `supervisor_pid` is how that server knows this process is still there.
write_state() {
    local state="$1"
    printf '{"state":"%s","jobs_taken":%d,"image_revision":"%s","supervisor_pid":%d,"updated_at":%d}\n' \
        "$state" "$jobs_taken" "$IMAGE_REVISION" "$$" "$(date +%s)" >"${STATE_FILE}.tmp" \
        && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

start_health_server() {
    python3 /health-server.py &
    health_pid=$!
    log "health server started on port ${APP_PORT} (pid ${health_pid})"
}

# The health server is what keeps the Space alive; if it ever dies, the container
# is worth nothing and is better replaced than left answering nothing.
ensure_health_server() {
    if [[ -n "$health_pid" ]] && kill -0 "$health_pid" 2>/dev/null; then
        return 0
    fi
    log "the health server is gone; stopping so the Space restarts"
    exit 1
}

shutdown() {
    log "stopping"
    [[ -n "$health_pid" ]] && kill "$health_pid" 2>/dev/null
    [[ -n "$key_file" ]] && rm -f "$key_file"
    exit 0
}

# --- GitHub App credentials -------------------------------------------------

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# RS256 over `header.payload`, which is all a GitHub App JWT is. `openssl` reads
# the PKCS#1 PEM the App hands out without conversion.
app_jwt() {
    local now header payload signing_input signature
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | base64url)
    # Backdated by a minute against clock skew, and the 10 minutes GitHub allows
    # are cut to 9 for the same reason.
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GH_APP_ID" | base64url)
    signing_input="${header}.${payload}"
    signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_file" -binary | base64url) || return 1
    printf '%s.%s' "$signing_input" "$signature"
}

# Prints the response body; returns non-zero and logs the status when the call
# did not succeed, so a caller never parses an error document as a result.
api() {
    local method="$1" path="$2" auth="$3" body="${4:-}"
    local response status payload
    local -a args=(
        --silent --show-error --location --max-time 60
        --request "$method"
        --header "Authorization: Bearer ${auth}"
        --header "Accept: application/vnd.github+json"
        --header "X-GitHub-Api-Version: 2022-11-28"
        --write-out '\n%{http_code}'
    )
    if [[ -n "$body" ]]; then
        args+=(--header "Content-Type: application/json" --data "$body")
    fi
    response=$(curl "${args[@]}" "${GITHUB_API}${path}") || return 1
    status="${response##*$'\n'}"
    payload="${response%$'\n'*}"
    if [[ "$status" != 2* ]]; then
        log "${method} ${path} -> HTTP ${status}: $(printf '%s' "$payload" | head -c 300)"
        return 1
    fi
    printf '%s' "$payload"
}

installation_id() {
    local jwt="$1" payload
    payload=$(api GET /app/installations "$jwt") || return 1
    printf '%s' "$payload" | jq -r --arg org "$GH_ORG" \
        'map(select(.account.login == $org)) | first | .id // empty'
}

# One registration, valid for one job. `runner_group_id: 1` is `Default`, the only
# group a Free-plan organization has; the label is what a workflow selects on.
jit_config() {
    local token="$1" name="$2" body payload
    body=$(jq -n \
        --arg name "$name" \
        --argjson group "$RUNNER_GROUP_ID" \
        --arg labels "$RUNNER_LABELS" \
        --arg work "$RUNNER_WORKDIR" \
        '{name: $name, runner_group_id: $group, labels: ($labels | split(",")), work_folder: $work}') || return 1
    payload=$(api POST "/orgs/${GH_ORG}/actions/runners/generate-jitconfig" "$token" "$body") || return 1
    printf '%s' "$payload" | jq -r '.encoded_jit_config // empty'
}

# --- the loop ---------------------------------------------------------------

main() {
    trap shutdown INT TERM

    write_state starting
    start_health_server

    local missing=()
    for var in GH_APP_ID GH_ORG GH_APP_PRIVATE_KEY SPACE_ID; do
        [[ -n "${!var:-}" ]] || missing+=("$var")
    done

    if ((${#missing[@]})); then
        # Not an exit: a Space that dies is restarted until the platform gives up
        # and its logs are gone. One that answers `misconfigured` says what it is
        # missing, and the scheduled check reports it as unhealthy.
        log "missing required environment: ${missing[*]}"
        write_state misconfigured
        wait "$health_pid"
        exit 1
    fi

    key_file=$(mktemp)
    chmod 600 "$key_file"
    if ! printf '%s' "$GH_APP_PRIVATE_KEY" | base64 -d >"$key_file" 2>/dev/null \
        || ! grep -q "PRIVATE KEY" "$key_file"; then
        log "GH_APP_PRIVATE_KEY is not the base64 of a PEM private key"
        write_state misconfigured
        wait "$health_pid"
        exit 1
    fi

    # `SPACE_ID` is `<namespace>/<space>`; the space part is what tells the three
    # Spaces apart, and it needs no variable of its own to say so.
    runner_base="${SPACE_ID##*/}"
    log "runner ${runner_base} for organization ${GH_ORG}, labels ${RUNNER_LABELS}"
    log "image revision ${IMAGE_REVISION}"

    local backoff=15
    while true; do
        ensure_health_server
        write_state registering

        local jwt install token name encoded
        if ! jwt=$(app_jwt) \
            || ! install=$(installation_id "$jwt") || [[ -z "$install" ]] \
            || ! token=$(api POST "/app/installations/${install}/access_tokens" "$jwt" | jq -r '.token // empty') \
            || [[ -z "$token" ]]; then
            log "could not mint an installation token for ${GH_ORG}; retrying in ${backoff}s"
            write_state error-backoff
            sleep "$backoff"
            backoff=$((backoff < 300 ? backoff * 2 : 300))
            continue
        fi

        # Unique among registrations that are live at the same moment. A JIT
        # runner removes itself once its job ends, but "the job ended" and "the
        # registration is gone" are not the same instant, and the next turn of
        # this loop can land in between — so the job counter goes in the name,
        # and the epoch this container started at keeps a restarted Space from
        # reusing the names the previous one left behind.
        name="${runner_base}-${boot_epoch}-${jobs_taken}"
        if ! encoded=$(jit_config "$token" "$name") || [[ -z "$encoded" ]]; then
            log "could not get a just-in-time configuration; retrying in ${backoff}s"
            write_state error-backoff
            sleep "$backoff"
            backoff=$((backoff < 300 ? backoff * 2 : 300))
            continue
        fi

        backoff=15
        write_state waiting-for-job
        log "registered ${name}; waiting for a job"

        cd /actions-runner || exit 1
        if ./run.sh --jitconfig "$encoded"; then
            jobs_taken=$((jobs_taken + 1))
            log "job finished; ${jobs_taken} taken by this container"
        else
            log "the runner exited non-zero; registering again"
        fi
        write_state registering
    done
}

main "$@"
