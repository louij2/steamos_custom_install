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
