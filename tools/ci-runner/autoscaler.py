#!/usr/bin/env python3
"""Spawn-per-job autoscaler for self-hosted GitHub Actions runners.

Polls the repository for queued jobs that ask for our runner label, and starts
one ephemeral runner container per queued job, up to a ceiling. Each runner
takes a single job, deregisters itself and exits; the container is discarded.
Nothing is left running when the queue is empty, so this costs nothing idle.

Standard library only, on purpose: it runs in a small container and must not
need a package index at start-up.

Config, all via environment:
  GITHUB_REPO       owner/repo (required)
  GH_PAT_FILE       file holding a token with repo Administration: read+write
  RUNNER_LABEL      the label a job must request to count (default: kvm)
  RUNNER_IMAGE      image to spawn (default: gha-runner-burst:latest)
  MAX_RUNNERS       ceiling on concurrent burst runners (default: 3)
  POLL_SECONDS      seconds between ticks (default: 30)
  METRICS_PORT      Prometheus endpoint (default: 9826)
  DOCKER_RUN_ARGS   extra args for `docker run`, shell-quoted
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.environ.get("GITHUB_REPO", "")
PAT_FILE = os.environ.get("GH_PAT_FILE", "/run/secrets/gh_pat")
LABEL = os.environ.get("RUNNER_LABEL", "kvm")
IMAGE = os.environ.get("RUNNER_IMAGE", "gha-runner-burst:latest")
MAX_RUNNERS = int(os.environ.get("MAX_RUNNERS", "3"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "30"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9826"))
EXTRA_ARGS = shlex.split(os.environ.get("DOCKER_RUN_ARGS", ""))
CONTAINER_LABEL = "gha-burst=1"

API = "https://api.github.com"

STATE = {
    "queued": 0,
    "running": 0,
    "spawned_total": 0,
    "errors_total": 0,
    "last_tick": 0.0,
    "last_error": "",
}
LOCK = threading.Lock()


def log(msg: str) -> None:
    print(f":: {msg}", flush=True)


def err(msg: str) -> None:
    print(f"!! {msg}", file=sys.stderr, flush=True)


def read_token() -> str:
    """Read the token on every use so rotating the file needs no restart."""
    try:
        with open(PAT_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as exc:
        raise RuntimeError(f"cannot read {PAT_FILE}: {exc}") from exc


def api_get(path: str) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {read_token()}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "gha-burst-autoscaler",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def queued_jobs() -> int:
    """Count queued jobs that actually want our label.

    GitHub has no 'list queued jobs' endpoint, so this walks the runs that are
    queued or in progress and inspects their jobs. A run can be in progress
    while one of its jobs still waits for a runner, which is exactly the case
    that matters here.
    """
    total = 0
    for status in ("queued", "in_progress"):
        runs = api_get(f"/repos/{REPO}/actions/runs?status={status}&per_page=30")
        for run in runs.get("workflow_runs", []):
            jobs = api_get(f"/repos/{REPO}/actions/runs/{run['id']}/jobs?per_page=100")
            for job in jobs.get("jobs", []):
                if job.get("status") != "queued":
                    continue
                if LABEL in (job.get("labels") or []):
                    total += 1
    return total


def running_burst() -> int:
    out = subprocess.run(
        ["docker", "ps", "--filter", f"label={CONTAINER_LABEL}", "--quiet"],
        capture_output=True, text=True, check=True,
    ).stdout
    return len([line for line in out.splitlines() if line.strip()])


def spawn(index: int) -> None:
    name = f"gha-burst-{int(time.time())}-{index}"
    cmd = [
        "docker", "run", "--rm", "--detach",
        "--name", name,
        "--label", CONTAINER_LABEL,
        "--env", f"GITHUB_REPO={REPO}",
        "--env", f"RUNNER_LABELS=self-hosted,linux,{LABEL}",
        "--env", f"RUNNER_NAME={name}",
        "--env", f"GH_PAT_FILE={PAT_FILE}",
        # the credential is bind-mounted read-only, never baked in or passed
        # as an environment variable that `docker inspect` would reveal
        "--volume", f"{PAT_FILE}:{PAT_FILE}:ro",
        *EXTRA_ARGS,
        IMAGE,
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    log(f"spawned {name}")


def tick() -> None:
    q = queued_jobs()
    r = running_burst()
    want = min(q, MAX_RUNNERS)
    deficit = max(0, want - r)

    with LOCK:
        STATE["queued"] = q
        STATE["running"] = r
        STATE["last_tick"] = time.time()

    if deficit:
        log(f"queued={q} running={r} max={MAX_RUNNERS} -> spawning {deficit}")
    for i in range(deficit):
        try:
            spawn(i)
            with LOCK:
                STATE["spawned_total"] += 1
                STATE["running"] += 1
        except subprocess.CalledProcessError as exc:
            with LOCK:
                STATE["errors_total"] += 1
                STATE["last_error"] = (exc.stderr or "")[:200]
            err(f"spawn failed: {exc.stderr}")


METRIC_HELP = [
    ("gha_ci_queued_jobs", "gauge", "Queued jobs requesting the burst label"),
    ("gha_ci_burst_running", "gauge", "Burst runner containers currently running"),
    ("gha_ci_max_runners", "gauge", "Configured ceiling on burst runners"),
    ("gha_ci_spawned_total", "counter", "Burst runners spawned since start"),
    ("gha_ci_errors_total", "counter", "Spawn or poll errors since start"),
    ("gha_ci_last_tick_timestamp_seconds", "gauge", "Unix time of the last successful tick"),
]


class Metrics(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path not in ("/metrics", "/"):
            self.send_response(404)
            self.end_headers()
            return
        with LOCK:
            values = {
                "gha_ci_queued_jobs": STATE["queued"],
                "gha_ci_burst_running": STATE["running"],
                "gha_ci_max_runners": MAX_RUNNERS,
                "gha_ci_spawned_total": STATE["spawned_total"],
                "gha_ci_errors_total": STATE["errors_total"],
                "gha_ci_last_tick_timestamp_seconds": STATE["last_tick"],
            }
        lines = []
        for name, kind, help_text in METRIC_HELP:
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {kind}")
            lines.append(f'{name}{{repo="{REPO}",label="{LABEL}"}} {values[name]}')
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass  # scrape traffic is noise


def main() -> int:
    if not REPO:
        err("GITHUB_REPO is required")
        return 1
    try:
        read_token()
    except RuntimeError as exc:
        err(str(exc))
        err("Create the token file before starting; see tools/ci-runner/README.md")
        return 1

    threading.Thread(
        target=lambda: HTTPServer(("", METRICS_PORT), Metrics).serve_forever(),
        daemon=True,
    ).start()
    log(f"metrics on :{METRICS_PORT}/metrics")
    log(f"watching {REPO} for queued '{LABEL}' jobs, max {MAX_RUNNERS}, every {POLL_SECONDS}s")

    while True:
        try:
            tick()
        except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError,
                subprocess.CalledProcessError, json.JSONDecodeError) as exc:
            with LOCK:
                STATE["errors_total"] += 1
                STATE["last_error"] = str(exc)[:200]
            err(f"tick failed: {exc}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
