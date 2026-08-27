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
# IMPORTANT: the image must come from the /recovery/ tree, NOT /steamdeck/.
# /steamdeck/ holds the OS images that get written to the internal drive; they
# do not contain repair_device.sh (verified - all four partitions searched).
# /recovery/ holds the bootable repair media, in three generations:
#
#   steamdeck-oobe-repair-<build>-<ver>   current (2026-)
#   steamdeck-repair-<build>-<ver>        2023-2025
#   steamdeck-recovery-<N>                original 2022 series
#
# Requires: curl, root for the loop mount, and unzip / bzip2 / zstd depending
# on the artefact.

set -euEo pipefail

PROGNAME="${0##*/}"
INDEX="https://steamdeck-images.steamos.cloud/recovery/"
OUT="${OUT:-upstream/repair_device.sh}"
VERSION_FILE="${VERSION_FILE:-upstream/VERSION}"
WORK="${WORK:-$(mktemp -d)}"
KEEP="${KEEP:-}"

usage() {
  cat >&2 <<EOD
Extract Valve's repair_device.sh from a SteamOS recovery image.

Usage: sudo $PROGNAME [--build BUILD] [--image PATH|URL]

  --build BUILD   Recovery build to use, e.g. 20260707.10.
                  Defaults to the newest oobe-repair image in Valve's index.
  --image SRC     Use a local .img/.img.zip/.img.bz2/.img.zst file (or an
                  explicit URL) instead of downloading the newest image.
  --list          List the recovery images Valve currently publishes, and exit.
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

# Recovery artefacts, newest-preferred first. Prefer .zip over .bz2: same
# content, same size, and unzip is far more likely to be present than bzip2.
list_recovery_images() {
  curl -fsSL "$INDEX" \
    | grep -oE 'steamdeck-(oobe-repair|repair|recovery)-[0-9A-Za-z.-]+\.img\.(zip|bz2|zst)' \
    | sort -u
}

# Echo the best candidate filename, or empty.
pick_recovery_image() {
  local want_build="$1" all
  all="$(list_recovery_images)"
  [[ -n $all ]] || return 1

  if [[ -n $want_build ]]; then
    printf '%s\n' "$all" | grep -- "-$want_build-" | grep '\.zip$' | head -1 && return 0
    printf '%s\n' "$all" | grep -- "-$want_build-" | head -1 && return 0
    return 1
  fi

  # Newest generation first. Version-sort puts the highest build last.
  local prefix
  for prefix in steamdeck-oobe-repair steamdeck-repair steamdeck-recovery; do
    local hit
    hit="$(printf '%s\n' "$all" | grep "^$prefix-" | grep '\.zip$' | sort -V | tail -1)"
    [[ -n $hit ]] && { printf '%s\n' "$hit"; return 0; }
  done
  return 1
}

BUILD=""; IMAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_recovery_images; exit 0 ;;
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
  log "Querying Valve's recovery index"
  FILE="$(pick_recovery_image "$BUILD" || true)"
  [[ -n $FILE ]] || die "No recovery image found${BUILD:+ for build $BUILD}.
Available:
$(list_recovery_images | sed 's/^/  /')"
  log "Selected $FILE"
  IMAGE="$INDEX$FILE"
  # Derive the build id from the filename for VERSION.
  if [[ -z $BUILD ]]; then
    BUILD="$(printf '%s' "$FILE" | grep -oE '[0-9]{8}\.[0-9]+' | head -1)"
    [[ -n $BUILD ]] || BUILD="$(printf '%s' "$FILE" | sed -E 's/\.img\..*$//')"
  fi
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
  *.bz2) command -v bunzip2 >/dev/null || die "bzip2 is required for .bz2 images"
         log "Decompressing (bunzip2)"; bunzip2 -c "$LOCAL" > "$RAW" ;;
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
  hit="$(find "$WORK/mnt" -name 'repair_device.sh' -type f -print -quit 2>/dev/null || true)"
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
