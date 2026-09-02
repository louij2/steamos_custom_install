# `tools/ci-runner/` — self-hosted burst runners

Spawn-per-job GitHub Actions runners for the `kvm` label, so the
[VM end-to-end test](../vm-test/README.md) can run in CI. GitHub's hosted
runners cannot: they have no nested virtualisation and not enough disk.

Nothing runs while the queue is empty. One small autoscaler container watches
for queued jobs and starts an **ephemeral** runner per job; each runner takes
exactly one job, deregisters itself and exits.

```
autoscaler (always on, ~20 MB)
    │  polls the repo for queued jobs asking for 'kvm'
    ▼
gha-burst-<ts>-<n>   ephemeral runner container, one job then gone
    │  drives libvirt over the host socket
    ▼
steamos-install-test  VM on the host, torn down by the test itself
```

## Security: read this before pointing it at a public repo

A self-hosted runner executes whatever the workflow says. On a **public**
repository that is a real risk, because anyone can open a pull request.

The protections here:

- **`vm-test.yml` is `workflow_dispatch` only.** It never triggers on
  `pull_request`, so a fork cannot cause it to run. Nothing else uses the
  `kvm` label — every other job stays on GitHub's hosted runners.
- **Ephemeral runners.** One job per container, then it is discarded. Nothing
  persists between jobs.
- **The credential is never in the image or the environment.** It is
  bind-mounted read-only as a file and read at the moment it is used, so
  `docker inspect` does not reveal it.

Worth also setting, once:

```bash
gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow -f default_workflow_permissions=read
```

and in **Settings → Actions → General → Fork pull request workflows**, choose
*Require approval for all outside collaborators*.

Do not add the `kvm` label to a workflow that runs on `pull_request` unless you
have thought hard about it. The runner is privileged and sits on your LAN.

## Setting it up

On the libvirt host (not your laptop):

```bash
git clone https://github.com/louij2/steamos_custom_install.git
cd steamos_custom_install
sudo ./tools/ci-runner/deploy-unraid.sh
```

It refuses to start without a credential and tells you how to create one. The
token needs **`Administration: read and write`** on the one repository — that
is what mints runner registration tokens. Create a fine-grained PAT scoped to
that single repo at <https://github.com/settings/personal-access-tokens/new>,
then put it in place yourself:

```bash
install -d -m 700 /mnt/user/appdata/gh-autoscaler
printf '%s' 'YOUR_TOKEN' > /mnt/user/appdata/gh-autoscaler/gh_pat
chmod 600 /mnt/user/appdata/gh-autoscaler/gh_pat
```

## Configuration

Every knob is an environment variable on `deploy-unraid.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_REPO` | `louij2/steamos_custom_install` | Repository to serve |
| `RUNNER_LABEL` | `kvm` | Label a job must request |
| `MAX_RUNNERS` | `3` | Ceiling on concurrent burst runners |
| `POLL_SECONDS` | `30` | Seconds between queue checks |
| `METRICS_PORT` | `9826` | Prometheus endpoint |
| `VM_WORKDIR` | `/mnt/user/isos/steamos-vm-test` | Image cache, must be real storage |
| `MAX_RUNNERS=1` | | Effectively serialises, if the host is busy |

Raise `MAX_RUNNERS` only as far as the host can take: each concurrent VM test
wants ~8 GB RAM, 4 vCPU and ~21 GB of disk.

Unlike the Azure DevOps equivalent there is **no billing ceiling** — self-hosted
runners on a public repository have unlimited concurrency, so the only limit is
the hardware.

## Metrics

Prometheus endpoint on `:9826/metrics`:

| Metric | Meaning |
|---|---|
| `gha_ci_queued_jobs` | Queued jobs asking for the label |
| `gha_ci_burst_running` | Burst containers alive now |
| `gha_ci_max_runners` | Configured ceiling |
| `gha_ci_spawned_total` | Runners started since the autoscaler booted |
| `gha_ci_errors_total` | Poll or spawn failures |
| `gha_ci_last_tick_timestamp_seconds` | Staleness check for the loop |

Alert on `time() - gha_ci_last_tick_timestamp_seconds > 300` (the loop is dead)
and on `gha_ci_queued_jobs > 0 and gha_ci_burst_running == 0` sustained (jobs
are queuing but nothing is starting — usually an expired credential).

## Why the runner container is privileged

The VM test needs `losetup`, `mount` and `btrfs property` against real devices
to inject the harness into the recovery image. It does **not** run qemu: it
talks to the host's libvirt over the mounted socket, so the VM belongs to the
host. That is also why the work directory is bind-mounted at the *same path*
inside and out — libvirt resolves the disk image paths on the host, not in the
container.

## Operating it

```bash
docker logs -f gh-autoscaler          # what it is deciding
docker ps --filter label=gha-burst=1  # runners alive right now
curl -s localhost:9826/metrics        # current state
docker rm -f gh-autoscaler            # stop scaling; running jobs finish
```

Runners that vanish mid-job leave a registration behind; they are ephemeral so
GitHub clears them, but `gh api repos/OWNER/REPO/actions/runners` shows what is
registered if you suspect otherwise.
