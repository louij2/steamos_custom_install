#!/usr/bin/env bash
# Build the burst runner image and start the autoscaler, on an Unraid host.
#
# Run this ON the libvirt host. It builds two images and leaves one small
# always-on container (the autoscaler); runners themselves exist only while
# there is a job to run.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

GITHUB_REPO="${GITHUB_REPO:-louij2/steamos_custom_install}"
RUNNER_LABEL="${RUNNER_LABEL:-kvm}"
MAX_RUNNERS="${MAX_RUNNERS:-3}"
POLL_SECONDS="${POLL_SECONDS:-30}"
METRICS_PORT="${METRICS_PORT:-9826}"
APPDATA="${APPDATA:-/mnt/user/appdata/gh-autoscaler}"
PAT_FILE="${PAT_FILE:-$APPDATA/gh_pat}"
VM_WORKDIR="${VM_WORKDIR:-/mnt/user/isos/steamos-vm-test}"
LIBVIRT_SOCK="${LIBVIRT_SOCK:-/var/run/libvirt/libvirt-sock}"
OVMF_DIR="${OVMF_DIR:-/usr/share/qemu/ovmf-x64}"
NVRAM_DIR="${NVRAM_DIR:-/var/lib/libvirt/qemu/nvram}"

die()  { echo >&2 "!! $*"; exit 1; }
info() { echo ":: $*"; }

[[ $EUID -eq 0 ]] || die "run as root on the libvirt host"
command -v docker >/dev/null || die "docker not found - run this on the host, not your laptop"
[[ -S $LIBVIRT_SOCK ]] || die "no libvirt socket at $LIBVIRT_SOCK"
[[ -e /dev/kvm ]] || die "/dev/kvm is absent"
[[ -d $OVMF_DIR ]] || die "no OVMF firmware directory at $OVMF_DIR"

if [[ ! -r $PAT_FILE ]]; then
  die "no credential at $PAT_FILE.

   The autoscaler needs a GitHub token with 'Administration: read and write'
   on ${GITHUB_REPO}, so it can mint runner registration tokens.

   Create a fine-grained PAT scoped to that ONE repository at
     https://github.com/settings/personal-access-tokens/new
   then put it in place yourself - do not paste it into a chat:

     install -d -m 700 $APPDATA
     printf '%s' 'YOUR_TOKEN' > $PAT_FILE
     chmod 600 $PAT_FILE

   Then re-run this script."
fi
[[ "$(stat -c %a "$PAT_FILE")" == "600" ]] || info "WARNING: $PAT_FILE is not chmod 600"

mkdir -p "$VM_WORKDIR" "$NVRAM_DIR"

info "building the burst runner image"
docker build -q -t gha-runner-burst:latest -f "$HERE/Dockerfile.runner" "$HERE"

info "building the autoscaler image"
docker build -q -t gha-autoscaler:latest -f "$HERE/Dockerfile.autoscaler" "$HERE"

# Arguments handed to each spawned runner. The runner drives libvirt over the
# socket, so the VM runs on the host; the container only needs the disk
# plumbing. Image paths must be IDENTICAL inside and out, because libvirt
# resolves them on the host.
DOCKER_RUN_ARGS="--privileged \
 --volume ${LIBVIRT_SOCK}:${LIBVIRT_SOCK} \
 --volume /dev:/dev \
 --volume ${VM_WORKDIR}:${VM_WORKDIR} \
 --volume ${OVMF_DIR}:${OVMF_DIR}:ro \
 --volume ${NVRAM_DIR}:${NVRAM_DIR} \
 --env VM_TEST_WORKDIR=${VM_WORKDIR} \
 --env OVMF_CODE=${OVMF_DIR}/OVMF_CODE-pure-efi.fd \
 --env OVMF_VARS=${OVMF_DIR}/OVMF_VARS-pure-efi.fd"

info "restarting the autoscaler"
docker rm -f gh-autoscaler >/dev/null 2>&1 || true
docker run -d \
  --name gh-autoscaler \
  --restart unless-stopped \
  --label net.unraid.docker.managed=cli \
  --publish "${METRICS_PORT}:${METRICS_PORT}" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume "${PAT_FILE}:${PAT_FILE}:ro" \
  --env "GITHUB_REPO=${GITHUB_REPO}" \
  --env "GH_PAT_FILE=${PAT_FILE}" \
  --env "RUNNER_LABEL=${RUNNER_LABEL}" \
  --env "MAX_RUNNERS=${MAX_RUNNERS}" \
  --env "POLL_SECONDS=${POLL_SECONDS}" \
  --env "METRICS_PORT=${METRICS_PORT}" \
  --env "RUNNER_IMAGE=gha-runner-burst:latest" \
  --env "DOCKER_RUN_ARGS=${DOCKER_RUN_ARGS}" \
  gha-autoscaler:latest >/dev/null

sleep 3
docker logs gh-autoscaler 2>&1 | tail -5
info "autoscaler up: metrics on :${METRICS_PORT}/metrics, ceiling ${MAX_RUNNERS}"
