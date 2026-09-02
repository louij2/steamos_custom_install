#!/usr/bin/env bash
# Register as an EPHEMERAL GitHub Actions runner, take exactly one job, exit.
#
# Ephemeral is the whole security model here: the runner deregisters itself
# after a single job and the container is discarded, so nothing one job leaves
# behind is visible to the next.
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO to owner/repo}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,kvm}"
RUNNER_NAME="${RUNNER_NAME:-burst-$(hostname)-$RANDOM}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"

# A registration token is valid for an hour. Either one is handed in (for a
# one-off runner), or we mint one from a credential that never leaves this
# container. Read it from a file when possible so it stays out of the
# environment and out of `docker inspect`.
if [[ -z ${RUNNER_TOKEN:-} ]]; then
  if [[ -z ${GH_PAT:-} && -n ${GH_PAT_FILE:-} && -r ${GH_PAT_FILE:-} ]]; then
    GH_PAT="$(< "$GH_PAT_FILE")"
  fi
  [[ -n ${GH_PAT:-} ]] || { echo >&2 "!! set RUNNER_TOKEN, or GH_PAT / GH_PAT_FILE"; exit 1; }

  RUNNER_TOKEN="$(curl -fsSL -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token" \
    | jq -r .token)"
  unset GH_PAT

  if [[ -z $RUNNER_TOKEN || $RUNNER_TOKEN == null ]]; then
    echo >&2 "!! could not mint a registration token."
    echo >&2 "!! The credential needs 'Administration: read and write' on ${GITHUB_REPO}."
    exit 1
  fi
fi

cleanup() {
  # Ephemeral runners deregister themselves after a job. This covers a crash
  # before that happens, so dead entries do not pile up in repo settings.
  ./config.sh remove --token "$RUNNER_TOKEN" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cd /actions-runner
./config.sh \
  --url "https://github.com/${GITHUB_REPO}" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --runnergroup "$RUNNER_GROUP" \
  --work _work \
  --unattended \
  --replace \
  --ephemeral

echo ":: runner ${RUNNER_NAME} online, labels ${RUNNER_LABELS}; waiting for one job"
exec ./run.sh
