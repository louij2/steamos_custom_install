#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Extract Valve's pristine repair_device.sh from a SteamOS recovery image.
#
# Valve does not publish this script on its own anywhere: it is not in any
# package in jupiter-main or holo-main (checked), and gitlab.steamos.cloud does
# not serve anonymously. The only authoritative source is the recovery image
# itself, which is ~3.3 GB compressed. That is why upstream sync runs on a
# schedule and on demand, never per-push.
#
# Requires: curl, zstd (or unzip), and root for the loop mount.

set -euEo pipefail

PROGNAME="${0##*/}"
INDEX="https://steamdeck-images.steamos.cloud/steamdeck/"
OUT="${OUT:-upstream/repair_device.sh}"
VERSION_FILE="${VERSION_FILE:-upstream/VERSION}"
WORK="${WORK:-$(mktemp -d)}"
KEEP="${KEEP:-}"

usage() {
  cat >&2 <<EOD
Extract Valve's repair_device.sh from a SteamOS recovery image.

Usage: sudo $PROGNAME [--build BUILD] [--image PATH|URL]

  --build BUILD   Recovery build to use, e.g. 20260826.1000.
                  Defaults to the newest build in Valve's index.
  --image SRC     Use a local .img/.img.zst file (or an explicit URL) instead
                  of downloading the newest build.
  --out PATH      Where to write the extracted script (default: $OUT).
  --keep          Do not delete the work directory on exit.
  -h, --help      This help.

Writes the script to --out and the originating build id to $VERSION_FILE.
EOD
}

log()  { echo >&2 ":: $*"; }
warn() { echo >&2 ";; $*"; }
die()  { echo >&2 "!! $*"; exit 1; }

cleanup() {
  set +e
  if [[ -n ${MOUNTED:-} ]]; then umount "$WORK/mnt" 2>/dev/null; fi
  if [[ -n ${LOOPDEV:-} ]]; then losetup -d "$LOOPDEV" 2>/dev/null; fi
  if [[ -z $KEEP ]]; then rm -rf "$WORK"; else warn "work dir kept: $WORK"; fi
}
trap cleanup EXIT

BUILD=""; IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --out)   OUT="${2:?}"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null || die "curl is required"
[[ $EUID -eq 0 ]] || die "Must run as root - this loop-mounts a disk image."

mkdir -p "$WORK" "$WORK/mnt"

# Resolve which image to use.
if [[ -z $IMAGE ]]; then
  if [[ -z $BUILD ]]; then
    log "Finding the newest build in Valve's index"
    BUILD="$(curl -fsSL "$INDEX" \
      | grep -oE 'href="[0-9]{8}\.[0-9]+/"' \
      | grep -oE '[0-9]{8}\.[0-9]+' \
      | sort -V | tail -1)"
    [[ -n $BUILD ]] || die "Could not determine the newest build - has the index format changed?"
  fi
  log "Using build $BUILD"
  FILE="$(curl -fsSL "$INDEX$BUILD/" \
    | grep -oE 'href="[^"]+\.img\.(zst|zip)"' \
    | grep -oE '[^"]+\.img\.(zst|zip)' | head -1)"
  [[ -n $FILE ]] || die "No image artefact found in $INDEX$BUILD/"
  IMAGE="$INDEX$BUILD/$FILE"
fi

# Fetch if remote.
if [[ $IMAGE =~ ^https?:// ]]; then
  LOCAL="$WORK/$(basename "$IMAGE")"
  log "Downloading $IMAGE"
  log "(this is a multi-GB download; it is why this job is not run per-push)"
  curl -fL --retry 3 --progress-bar -o "$LOCAL" "$IMAGE"
else
  LOCAL="$IMAGE"
  [[ -f $LOCAL ]] || die "$LOCAL does not exist"
fi

# Decompress to a raw image.
RAW="$WORK/recovery.img"
case "$LOCAL" in
  *.zst) command -v zstd >/dev/null || die "zstd is required for .zst images"
         log "Decompressing (zstd)"; zstd -d -f -o "$RAW" "$LOCAL" ;;
  *.zip) command -v unzip >/dev/null || die "unzip is required for .zip images"
         log "Decompressing (unzip)"; unzip -p "$LOCAL" > "$RAW" ;;
  *.img) RAW="$LOCAL" ;;
  *)     die "Don't know how to decompress $LOCAL" ;;
esac

# Loop-mount each partition and hunt for the script. Valve has moved it before,
# so search rather than assuming a path - and say so loudly if it is gone.
log "Attaching loop device"
LOOPDEV="$(losetup --find --show --partscan --read-only "$RAW")"
log "Loop device: $LOOPDEV"

FOUND=""
for part in "$LOOPDEV"p* "$LOOPDEV"; do
  [[ -b $part ]] || continue
  umount "$WORK/mnt" 2>/dev/null || true
  MOUNTED=""
  mount -o ro "$part" "$WORK/mnt" 2>/dev/null || continue
  MOUNTED=1
  log "Searching $part"
  hit="$(find "$WORK/mnt" -maxdepth 6 -name 'repair_device.sh' -type f -print -quit 2>/dev/null || true)"
  if [[ -n $hit ]]; then
    FOUND="$hit"
    log "Found: ${hit#"$WORK/mnt"}"
    break
  fi
done

[[ -n $FOUND ]] || die "repair_device.sh not found in any partition of $IMAGE.
Valve may have renamed or removed it. Re-run with --keep and inspect the mount,
then update this script's search."

mkdir -p "$(dirname "$OUT")"
install -m 0644 "$FOUND" "$OUT"
if [[ -n ${BUILD:-} ]]; then
  printf '%s\n' "$BUILD" > "$VERSION_FILE"
fi

log "Wrote $OUT ($(wc -l < "$OUT") lines)"
[[ -n ${BUILD:-} ]] && log "Wrote $VERSION_FILE ($BUILD)"
