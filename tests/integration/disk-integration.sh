#!/usr/bin/env bash
# Integration test against a REAL loopback block device.
#
# The bats suite cannot reach the code paths behind issues #9 and #10: they only
# misbehave when there is an actual disk with actual mounted partitions and
# actual kernel-published device nodes. This covers exactly that, and needs
# nothing from SteamOS, so it runs in ordinary CI.
#
# Requires root and a Linux kernel with loop support.
set -euEo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export LIBDIR="$REPO/lib"
# shellcheck source-path=SCRIPTDIR/../..
# shellcheck source=lib/log.sh
source "$LIBDIR/log.sh"
# shellcheck source=lib/disk.sh
source "$LIBDIR/disk.sh"

PASS=0; FAIL=0
ok()  { echo ":: PASS  $*"; PASS=$((PASS+1)); }
bad() { echo ":: FAIL  $*"; FAIL=$((FAIL+1)); }

IMG="$(mktemp -u /tmp/steamos-itest-XXXX.img)"
LOOP=""
cleanup() {
  [[ -n $LOOP ]] || { rm -f "$IMG"; return 0; }
  umount -R /mnt/itest-decoy 2>/dev/null || true
  rmdir /mnt/itest-decoy 2>/dev/null || true
  losetup -d "$LOOP" 2>/dev/null || true
  rm -f "$IMG"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "!! must run as root"; exit 1; }

truncate -s 512M "$IMG"
LOOP="$(losetup --find --show --partscan "$IMG")"
echo ":: loop device: $LOOP"
export DISK="$LOOP"
DISK_SUFFIX="$(disk_suffix "$LOOP")"
export DISK_SUFFIX
if [[ $DISK_SUFFIX == p ]]; then
  ok "loop device takes the 'p' partition suffix"
else
  bad "expected suffix p, got '$DISK_SUFFIX'"
fi

# ---------------------------------------------------------------------------
echo; echo "=== issue #9: a mounted target disk must be released ==="
printf 'label: gpt\nstart=2048, size=204800, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' \
  | sfdisk --wipe always "$LOOP" >/dev/null
udevadm settle --timeout=30 || true
mkfs.ext4 -F -q "${LOOP}p1"
mkdir -p /mnt/itest-decoy
mount "${LOOP}p1" /mnt/itest-decoy
echo ":: mounted ${LOOP}p1 at /mnt/itest-decoy (this is what breaks Valve's script)"

# disk_in_use must SEE it
if disk_in_use "$LOOP" | grep -q "${LOOP}p1"; then
  ok "disk_in_use detected the mounted partition"
else
  bad "disk_in_use missed a mounted partition"
fi

# Prove the failure is real: raw sfdisk refuses while it is mounted.
if printf 'label: gpt\n' | sfdisk "$LOOP" >/dev/null 2>&1; then
  echo ":: NOTE: this kernel allowed repartitioning a mounted disk; skipping the"
  echo "::       'reproduce the reported failure' assertion"
else
  ok "reproduced the reported busy-disk failure without the fix"
fi

# release_disk must clear it
release_disk "$LOOP"
if [[ -z "$(disk_in_use "$LOOP")" ]]; then
  ok "release_disk unmounted the target"
else
  bad "release_disk left the disk busy"
fi

# ...and sfdisk must now succeed where it just failed
if printf 'label: gpt\n' | sfdisk --wipe always "$LOOP" >/dev/null 2>&1; then
  ok "sfdisk succeeds after release_disk"
else
  bad "sfdisk still fails after release_disk"
fi

# ---------------------------------------------------------------------------
echo; echo "=== issue #10: partition nodes must exist before mkfs runs ==="
partition_table_small() {
  cat <<END
label: gpt
${LOOP}p1: name="esp",   size=32MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
${LOOP}p2: name="var-A", size=32MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
${LOOP}p3: name="home",             type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
END
}
table="$(mktemp)"
partition_table_small > "$table"
sfdisk --wipe always --wipe-partitions always "$LOOP" < "$table" >/dev/null
rm -f "$table"

if settle_disk "$LOOP" 3; then
  ok "settle_disk waited for all 3 partition nodes"
else
  bad "settle_disk failed"
fi
for i in 1 2 3; do
  [[ -b "${LOOP}p$i" ]] || bad "partition node ${LOOP}p$i missing after settle"
done
# The point of the fix: mkfs immediately afterwards must not fail.
if mkfs.ext4 -F -q "${LOOP}p2" 2>/dev/null; then
  ok "mkfs succeeds immediately after settle_disk"
else
  bad "mkfs failed right after partitioning - the issue #10 symptom"
fi

# ---------------------------------------------------------------------------
echo; echo "=== issue #9: preflight names a missing tool ==="
if out="$(require_tools ls definitely-not-a-real-binary 2>&1)"; then
  bad "require_tools accepted a missing binary"
else
  if [[ "$out" == *definitely-not-a-real-binary* ]]; then
    ok "require_tools named the missing binary"
  else
    bad "did not name it"
  fi
fi

# NOTE: require_tools ends in `die`, which is a plain `exit`. Call it inside a
# command substitution so that exit ends the subshell and not this script.
shim="$(mktemp -d)"; printf '#!/bin/sh\n' > "$shim/unrunnable"; chmod 644 "$shim/unrunnable"
if out="$(PATH="$shim:$PATH" require_tools unrunnable 2>&1)"; then
  bad "require_tools accepted a non-executable binary"
else
  if [[ "$out" == *unrunnable* ]]; then
    ok "require_tools rejected a present-but-non-executable binary"
  else
    bad "rejected it, but did not name it: $out"
  fi
fi
rm -rf "$shim"

# ---------------------------------------------------------------------------
echo; echo "=== issue #12: a non-UEFI boot is refused before the disk is touched ==="
# steamos-chroot bind-mounts /sys/firmware/efi/efivars unconditionally, so on a
# machine that did not boot via UEFI it dies with "mount point does not exist".
# That happens in the LAST step of the install, with the partition table already
# rewritten and 10 GB written. This proves the preflight check fires first, with
# a real block device in play.
#
# EFI_SYSFS pointing at a path that does not exist is exactly what a legacy
# BIOS/CSM boot looks like to the installer. Only the genuinely absent tools get
# shimmed - so require_tools passes and the firmware check is actually reached,
# while sfdisk stays real and the table below is a real witness.
sentinel="$(mktemp)"
printf 'label: gpt\n%sp1: name="sentinel", size=32MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' \
  "$LOOP" > "$sentinel"
sfdisk --wipe always --wipe-partitions always "$LOOP" < "$sentinel" >/dev/null
rm -f "$sentinel"
settle_disk "$LOOP" 1 >/dev/null 2>&1 || true
before="$(sfdisk -d "$LOOP" 2>/dev/null | grep -c sentinel || true)"

shimdir="$(mktemp -d)"
shimmed=()
for t in $(tools_for_target all); do
  command -v "$t" >/dev/null 2>&1 && continue
  printf '#!/bin/sh\nexit 0\n' > "$shimdir/$t"
  chmod 755 "$shimdir/$t"
  shimmed+=("$t")
done
echo ":: shimmed the tools this host lacks: ${shimmed[*]+${shimmed[*]}}"

rc12=0
out12="$(PATH="$shimdir:$PATH" EFI_SYSFS="$shimdir/no-such-efi" \
         bash "$REPO/bin/steamos-install" --yes --disk "$LOOP" all 2>&1)" || rc12=$?
echo "$out12" | tail -12
echo ":: installer rc=$rc12"
rm -rf "$shimdir"

if [[ $rc12 -ne 0 ]]; then
  ok "the installer refused to run on a machine that is not UEFI-booted"
else
  bad "the installer proceeded on a non-UEFI machine"
fi
if [[ "$out12" == *"did not boot via UEFI"* ]]; then
  ok "named the firmware as the reason"
else
  bad "did not name the firmware: $out12"
fi
if [[ "$out12" != *"Write known partition table"* ]]; then
  ok "aborted before the first destructive step"
else
  bad "reached the partition table write before failing"
fi
after="$(sfdisk -d "$LOOP" 2>/dev/null | grep -c sentinel || true)"
if [[ $before -eq 1 && $after -eq 1 ]]; then
  ok "the target disk is byte-for-byte untouched"
else
  bad "the sentinel partition table changed (before=$before after=$after)"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
