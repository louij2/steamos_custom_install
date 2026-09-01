#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Target-disk selection, partition naming and partition verification.

[[ -n ${__LIB_DISK_SH:-} ]] && return 0
__LIB_DISK_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"

# Set by the entrypoint once the user has chosen a target.
DISK="${DISK:-}"
DISK_SUFFIX="${DISK_SUFFIX:-}"

# Partition numbers on the ideal target device, by index. These are consumed by
# lib/steps.sh, so shellcheck cannot see the uses from inside this file.
# shellcheck disable=SC2034
{
  FS_ESP=1
  FS_EFI_A=2
  FS_EFI_B=3
  FS_ROOT_A=4
  FS_ROOT_B=5
  FS_VAR_A=6
  FS_VAR_B=7
  FS_HOME=8
}

# Partition naming. The kernel rule is simply: if the disk's device name ends
# in a digit, its partitions get a "p" separator (nvme0n1 -> nvme0n1p1,
# mmcblk0 -> mmcblk0p1, loop4 -> loop4p1); otherwise they do not (sda -> sda1).
#
# Valve's script hardcodes nvme0n1p*, which is the single reason installing to
# an external drive fails. Earlier versions of this fork special-cased "nvme"
# and "mmcblk" by name, which was right for those two but still produced
# nonsense like "loop41" for anything else ending in a digit.
#   $1 whole-disk device path
# Echoes the suffix ("p" or "").
disk_suffix() {
  local disk="$1"
  local base="${disk##*/}"
  if [[ $base =~ [0-9]$ ]]; then
    echo "p"
  else
    echo ""
  fi
}

# Echo the device path for a partition index on $DISK.
#   $1 partition index
diskpart() { echo "${DISK}${DISK_SUFFIX}${1}"; }

# Reject anything that is not a whole block device, with a message that says
# what to do about it.
#   $1 device path
validate_disk() {
  local disk="$1"

  [[ -n $disk ]] || die "No target disk given."

  if [[ ! -b $disk ]]; then
    if [[ -e $disk ]]; then
      die "$disk exists but is not a block device. Pass a whole disk such as /dev/sda (see 'lsblk')."
    fi
    die "$disk does not exist. Run 'lsblk' to list the disks attached to this machine."
  fi

  # A partition has a ../<parent>/ entry in sysfs; a whole disk does not.
  local base; base="$(basename "$disk")"
  if [[ -e /sys/class/block/$base/partition ]]; then
    die "$disk is a partition, not a whole disk. Pass e.g. /dev/sda, not /dev/sda1."
  fi
}

# Print the attached block devices, to help the user pick.
list_disks() {
  if command -v lsblk >/dev/null 2>&1; then
    echo >&2
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null >&2 || lsblk >&2
    echo >&2
  fi
}

# Verify a partition's type and label before a partial repair. On a full
# reimage the table has just been written, so this is skipped.
#   $1 device  $2 expected fs type  $3 expected partlabel
verifypart() {
  [[ ${DOPARTVERIFY:-1} = 1 ]] || return 0

  local dev="$1" want_type="$2" want_label="$3"
  local type label
  type="$(blkid -o value -s TYPE "$dev" || true)"
  label="$(blkid -o value -s PARTLABEL "$dev" || true)"

  if [[ $type != "$want_type" ]]; then
    die "Device $dev is type ${type:-<none>} but expected $want_type - cannot proceed. You may try a full reimage ('all')."
  fi

  if [[ $label != "$want_label" ]]; then
    die "Device $dev has label ${label:-<none>} but expected $want_label - cannot proceed. You may try a full reimage ('all')."
  fi
}

fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die "fmt_ext4: bad arguments"; cmd mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die "fmt_fat32: bad arguments"; cmd mkfs.vfat -n"$1" "$2"; }

# sfdisk-format partition table for the selected disk.
partition_table() {
  cat <<END_PARTITION_TABLE
label: gpt
${DISK}${DISK_SUFFIX}1: name="esp",      size=    64MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
${DISK}${DISK_SUFFIX}2: name="efi-A",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
${DISK}${DISK_SUFFIX}3: name="efi-B",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
${DISK}${DISK_SUFFIX}4: name="rootfs-A", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
${DISK}${DISK_SUFFIX}5: name="rootfs-B", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
${DISK}${DISK_SUFFIX}6: name="var-A",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
${DISK}${DISK_SUFFIX}7: name="var-B",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
${DISK}${DISK_SUFFIX}8: name="home",                     type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
END_PARTITION_TABLE
}

# ---------------------------------------------------------------------------
# Preflight: tools, busy disks, and settling after a partition-table write.
#
# These exist because of two field reports (#9, #10) that both came down to the
# same thing: a command failing for an environmental reason, reported as a bare
# exit code with no indication of what to do about it.
# ---------------------------------------------------------------------------

# External binaries each target needs. steamos-chroot is the tell for "you are
# not running this from a SteamOS recovery image", which is by far the most
# common way this script is misused.
tools_for_target() {
  local target="$1"
  local -a common=(lsblk blkid findmnt udevadm)
  case "$target" in
    all)      echo "${common[*]} sfdisk mkfs.ext4 mkfs.vfat tune2fs dd btrfstune btrfs fsfreeze steamos-chroot" ;;
    system)   echo "${common[*]} mkfs.ext4 mkfs.vfat dd btrfstune btrfs fsfreeze steamos-chroot" ;;
    home)     echo "${common[*]} mkfs.ext4 tune2fs" ;;
    chroot)   echo "${common[*]} steamos-chroot" ;;
    sanitize) echo "${common[*]} nvme" ;;
    *)        echo "${common[*]}" ;;
  esac
}

# Fail early, and by name, when something we are going to call is not there.
# Without this a missing binary surfaces as "exit 127" from whichever line
# happened to reach it first - which is exactly what issue #9 reported.
require_tools() {
  local -a missing=()
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  eerr "Missing required command(s): ${missing[*]}"
  eerr "PATH is: $PATH"
  if [[ " ${missing[*]} " == *" steamos-chroot "* ]]; then
    eerr "steamos-chroot is only present on Valve's SteamOS recovery image."
    eerr "Boot the recovery USB and run this from the Konsole there - it cannot"
    eerr "install SteamOS from an ordinary Linux live USB."
  fi
  if [[ -n ${DRY_RUN:-} ]]; then
    ewarn "Continuing anyway because this is a dry run."
    return 0
  fi
  die "Cannot continue with tools missing."
}

# Echo every partition device belonging to a whole disk, one per line.
#   $1 whole-disk device path
disk_partitions() {
  local base="${1##*/}" p
  for p in "/sys/class/block/$base/$base"*; do
    [[ -e "$p/partition" ]] || continue
    echo "/dev/${p##*/}"
  done
  return 0
}

# Echo "device mountpoint" for every mounted partition of the disk, plus any
# partition that is in use as swap. Empty output means the disk is free.
#   $1 whole-disk device path
disk_in_use() {
  local part mnt
  for part in $(disk_partitions "$1"); do
    while read -r mnt; do
      [[ -n $mnt ]] && echo "$part $mnt"
    done < <(findmnt -rno TARGET --source "$part" 2>/dev/null || true)
    if grep -qE "^${part}[[:space:]]" /proc/swaps 2>/dev/null; then
      echo "$part [swap]"
    fi
  done
  return 0
}

# Echo anything holding a partition open through device-mapper or md - LUKS,
# LVM, a stale RAID member. We report these rather than tearing them down,
# because doing so blind can take out a disk the user did not mean to touch.
disk_holders() {
  local part h
  for part in $(disk_partitions "$1"); do
    for h in "/sys/class/block/${part##*/}/holders"/*; do
      [[ -e "$h" ]] || continue
      echo "$part -> /dev/${h##*/}"
    done
  done
  return 0
}

# Unmount everything on the target disk so that sfdisk and mkfs can get the
# exclusive access they need.
#
# This is the direct cause of sfdisk's "Checking that no-one is using this disk
# right now ... FAILED". The recovery image's desktop auto-mounts partitions on
# any attached drive, so by the time the user runs this the target is very often
# already mounted - and the failure message never says so.
#   $1 whole-disk device path
release_disk() {
  local disk="$1"
  local -a busy=()
  local line
  while IFS= read -r line; do
    [[ -n $line ]] && busy+=("$line")
  done < <(disk_in_use "$disk")
  [[ ${#busy[@]} -eq 0 ]] && return 0

  estat "Target disk has mounted partitions; releasing them first"
  local entry part mnt
  for entry in "${busy[@]}"; do
    part="${entry%% *}"; mnt="${entry#* }"
    if [[ $mnt == "[swap]" ]]; then
      cmd swapoff "$part" || ewarn "swapoff $part failed"
    else
      einfo "unmounting $part from $mnt"
      cmd umount -R "$mnt" || cmd umount -l "$mnt" || ewarn "umount $mnt failed"
    fi
  done

  # Re-check rather than trusting the umount exit codes.
  busy=()
  while IFS= read -r line; do
    [[ -n $line ]] && busy+=("$line")
  done < <(disk_in_use "$disk")
  [[ ${#busy[@]} -eq 0 ]] && return 0

  eerr "$disk is still in use after unmounting:"
  printf '     %s\n' "${busy[@]}" >&2
  local -a held=()
  while IFS= read -r line; do
    [[ -n $line ]] && held+=("$line")
  done < <(disk_holders "$disk")
  if [[ ${#held[@]} -gt 0 ]]; then
    eerr "It is also held open by device-mapper/md:"
    printf '     %s\n' "${held[@]}" >&2
    eerr "Close those first, e.g. 'sudo cryptsetup close <name>' or 'sudo vgchange -an'."
  fi
  die "Cannot get exclusive access to $disk. Unmount it (see 'lsblk') and retry."
}

# Make the kernel re-read the partition table and wait for the new device nodes
# to actually appear.
#
# Without this, mkfs runs against a partition node that does not exist yet and
# dies with a bare exit 1 - the failure reported in issue #10. It is invisible
# on a fast internal NVMe and reproducible on USB and SATA SSDs, which is what
# this fork is mostly used with.
#   $1 whole-disk device path  $2 number of partitions to wait for
settle_disk() {
  local disk="$1" want="${2:-8}"
  [[ -n ${DRY_RUN:-} ]] && { einfo "dry run: skipping partition settle"; return 0; }

  estat "Re-reading the partition table and waiting for the device nodes"
  sync
  partprobe "$disk" >/dev/null 2>&1 || blockdev --rereadpt "$disk" >/dev/null 2>&1 || true
  udevadm settle --timeout=30 >/dev/null 2>&1 || true

  # Bounded wait: poll for the nodes rather than sleeping a fixed guess.
  local deadline=$(( SECONDS + 30 )) i missing
  while (( SECONDS < deadline )); do
    missing=""
    for (( i = 1; i <= want; i++ )); do
      [[ -b "$(diskpart "$i")" ]] || missing="$(diskpart "$i")"
    done
    [[ -z $missing ]] && { einfo "all $want partitions present"; return 0; }
    sleep 1
  done

  eerr "Timed out after 30s waiting for $missing to appear."
  eerr "The partition table was written but the kernel has not published the"
  eerr "partitions. Unplug and replug the drive, or reboot, and run this again."
  die "Partition devices did not appear on $disk."
}
