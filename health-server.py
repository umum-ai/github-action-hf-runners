#!/usr/bin/env python3
"""Health endpoint of the Hugging Face Space runner.

A Space is reachable on one port and is stopped if nothing answers there, so this
server is started before anything else and outlives every registration. It is a
reader of state, never a writer: `supervisor.sh` owns the state file.

`/` always answers 200 — that is the liveness the Space platform probes, and a
container that cannot register must still be reachable to be diagnosed at all.
`/health` answers 200 only while the runner is actually working, and 503
otherwise; that is what the scheduled check in this repository asserts.

The Spaces are public, so the payload is deliberately four facts and nothing
else: whether the supervisor process is alive, how many jobs this container has
taken, the commit its image was built from, and why it is not working when it is
not — `reason`, one of the fixed sentences `supervisor.sh` writes into the state
file, and null when the supervisor has nothing to report. No organization, no
runner name, no labels, no token, and nothing derived from a credential value.
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/runner-state.json")
PORT = int(os.environ.get("APP_PORT", "7860"))
IMAGE_REVISION = os.environ.get("IMAGE_REVISION", "unknown")

# States in which the supervisor is doing its job: asking for a registration, or
# running the runner under it. `misconfigured` and `error-backoff` are not here,
# because a Space that answers while it can never take a job is the failure this
# endpoint exists to surface.
HEALTHY_STATES = frozenset({"starting", "registering", "waiting-for-job"})

# The longest reason served. The supervisor's sentences are far shorter; this is
# what keeps a state file that somehow says otherwise from being republished
# wholesale on a public endpoint.
REASON_MAX_CHARS = 200

STARTED_AT = time.time()


def snapshot():
    """Return (healthy, payload) from the state file and this process's parent."""
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        state = {}

    # The supervisor starts this server as its child and records its own pid in
    # the state it writes. Being that pid's child and finding the pid still there
    # is the whole liveness check — it costs no timer and cannot go stale, and it
    # holds when the supervisor is pid 1, which inside a container it is.
    supervisor_pid = state.get("supervisor_pid")
    supervisor_alive = isinstance(supervisor_pid, int) and supervisor_pid == os.getppid()
    if supervisor_alive:
        try:
            os.kill(supervisor_pid, 0)
        except OSError:
            supervisor_alive = False

    # Served as written and never rephrased here: the supervisor is the only
    # writer of reasons and its whole catalogue is literals of that script. A
    # value of any other type is no reason at all, and length is bounded because
    # this is a public document.
    reason = state.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        reason = None
    else:
        reason = reason.strip()[:REASON_MAX_CHARS]

    payload = {
        "state": state.get("state", "unknown"),
        "reason": reason,
        "runner_alive": supervisor_alive,
        "jobs_taken": state.get("jobs_taken", 0),
        "image_revision": state.get("image_revision", IMAGE_REVISION),
        "uptime_seconds": int(time.time() - STARTED_AT),
    }
    healthy = supervisor_alive and payload["state"] in HEALTHY_STATES
    payload["healthy"] = healthy
    return healthy, payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hf-space-runner"
    sys_version = ""

    def do_GET(self):  # noqa: N802 - the name is the framework's
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path not in ("/", "/health"):
            self.respond(404, {"error": "not found"})
            return
        healthy, payload = snapshot()
        status = 200 if (path == "/" or healthy) else 503
        self.respond(status, payload)

    def respond(self, status, payload):
        body = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        """Stay quiet: the Space log is for the runner, and the platform probes
        this endpoint continuously."""


if __name__ == "__main__":
    with ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as httpd:  # noqa: S104
        print(f"health server listening on 0.0.0.0:{PORT}", flush=True)
        httpd.serve_forever()
