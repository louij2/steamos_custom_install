#!/usr/bin/env bats
# Tests for lib/disk.sh - partition naming and target validation.

load helper

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export LIBDIR="$REPO/lib"
  # shellcheck source=../lib/disk.sh
  source "$LIBDIR/disk.sh"
}

@test "disk_suffix: SATA and USB disks take no separator" {
  [ "$(disk_suffix /dev/sda)" = "" ]
  [ "$(disk_suffix /dev/sdb)" = "" ]
  [ "$(disk_suffix /dev/vda)" = "" ]
  [ "$(disk_suffix /dev/hda)" = "" ]
}

@test "disk_suffix: NVMe and eMMC take a p separator" {
  [ "$(disk_suffix /dev/nvme0n1)" = "p" ]
  [ "$(disk_suffix /dev/nvme1n1)" = "p" ]
  [ "$(disk_suffix /dev/mmcblk0)" = "p" ]
}

@test "disk_suffix: any name ending in a digit takes p (the real kernel rule)" {
  # This is the regression the old nvme/mmcblk substring check got wrong:
  # loop4 partitions are loop4p1, not loop41.
  [ "$(disk_suffix /dev/loop4)" = "p" ]
}

@test "disk_suffix: works on bare names as well as paths" {
  [ "$(disk_suffix sda)" = "" ]
  [ "$(disk_suffix nvme0n1)" = "p" ]
}

@test "disk_suffix: a path containing 'nvme' elsewhere does not fool it" {
  # The old check was a substring match on the whole path.
  [ "$(disk_suffix /dev/disk/by-id/usb-nvme-enclosure-sda)" = "" ]
}

@test "diskpart: composes partition paths correctly" {
  DISK=/dev/sda DISK_SUFFIX="" run diskpart 1
  [ "$output" = "/dev/sda1" ]
  DISK=/dev/nvme0n1 DISK_SUFFIX="p" run diskpart 3
  [ "$output" = "/dev/nvme0n1p3" ]
}

@test "validate_disk: rejects a path that does not exist" {
  run validate_disk /dev/definitely-not-a-real-disk
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate_disk: rejects a regular file with an actionable message" {
  run validate_disk /etc/hosts
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a block device"* ]]
  [[ "$output" == *"lsblk"* ]]
}

@test "validate_disk: rejects an empty argument" {
  run validate_disk ""
  [ "$status" -ne 0 ]
}

@test "partition_table: emits a gpt label and all eight partitions" {
  DISK=/dev/sda DISK_SUFFIX="" run partition_table
  [ "$status" -eq 0 ]
  [[ "$output" == *"label: gpt"* ]]
  for want in esp efi-A efi-B rootfs-A rootfs-B var-A var-B home; do
    [[ "$output" == *"name=\"$want\""* ]]
  done
}

@test "partition_table: honours the NVMe suffix throughout" {
  DISK=/dev/nvme0n1 DISK_SUFFIX="p" run partition_table
  [[ "$output" == *"/dev/nvme0n1p1:"* ]]
  [[ "$output" == *"/dev/nvme0n1p8:"* ]]
  [[ "$output" != *"/dev/nvme0n11:"* ]]
}

# --- preflight: tools, busy disks, settling (issues #9 and #10) -------------

@test "tools_for_target: every install target requires steamos-chroot" {
  for t in all system chroot; do
    [[ "$(tools_for_target "$t")" == *"steamos-chroot"* ]]
  done
}

@test "tools_for_target: 'all' requires sfdisk, and 'sanitize' does not" {
  [[ "$(tools_for_target all)" == *"sfdisk"* ]]
  [[ "$(tools_for_target sanitize)" != *"sfdisk"* ]]
  [[ "$(tools_for_target sanitize)" == *"nvme"* ]]
}

@test "require_tools: passes when everything is present" {
  run require_tools ls cat
  [ "$status" -eq 0 ]
}

@test "require_tools: names the missing tool rather than failing with 127 later" {
  # The whole point of issue #9: exit 127 partway through said nothing useful.
  run require_tools ls definitely-not-a-real-binary
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitely-not-a-real-binary"* ]]
  [[ "$output" == *"PATH is:"* ]]
}

@test "require_tools: explains that steamos-chroot means the wrong boot media" {
  run require_tools steamos-chroot-definitely-absent steamos-chroot
  [ "$status" -ne 0 ]
  [[ "$output" == *"recovery image"* ]]
}

@test "require_tools: a dry run warns but does not abort" {
  DRY_RUN=1 run require_tools definitely-not-a-real-binary
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
}

@test "disk_partitions: a disk with no partitions in sysfs yields nothing" {
  run disk_partitions /dev/definitely-not-a-real-disk
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "disk_in_use: reports nothing for a disk that does not exist" {
  run disk_in_use /dev/definitely-not-a-real-disk
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "release_disk: a free disk is a no-op, not an error" {
  run release_disk /dev/definitely-not-a-real-disk
  [ "$status" -eq 0 ]
}

@test "settle_disk: skipped under DRY_RUN so the dry path stays runnable" {
  DRY_RUN=1 DISK=/dev/definitely-not-a-real-disk DISK_SUFFIX="" run settle_disk /dev/definitely-not-a-real-disk 8
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
}

@test "the preflight helpers are errexit-safe" {
  # These run under 'set -euEo pipefail' in the real entrypoint. A helper that
  # returns non-zero on the ordinary path would abort the install with the
  # meaningless trap output this fork exists to eliminate.
  require_modern_bash
  run "$BASH44" -c '
    set -euEo pipefail
    export LIBDIR="'"$LIBDIR"'"
    source "$LIBDIR/disk.sh"
    DRY_RUN=1
    require_tools ls cat
    release_disk /dev/definitely-not-a-real-disk
    settle_disk /dev/definitely-not-a-real-disk 8
    disk_partitions /dev/definitely-not-a-real-disk
    disk_in_use /dev/definitely-not-a-real-disk
    disk_holders /dev/definitely-not-a-real-disk
    echo REACHED-END
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-END"* ]]
}

@test "require_tools: a present but non-executable tool counts as missing" {
  # Regression from the VM test: `command -v` resolved sfdisk to a path with no
  # execute bit, preflight passed, and it failed later with exit 126.
  local dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$dir"
  printf '#!/bin/sh\n' > "$dir/notexec-tool"
  chmod 644 "$dir/notexec-tool"
  PATH="$dir:$PATH" run require_tools notexec-tool
  [ "$status" -ne 0 ]
  [[ "$output" == *"notexec-tool"* ]]
}

@test "require_tools: an executable tool on PATH still passes" {
  local dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$dir"
  printf '#!/bin/sh\n' > "$dir/yesexec-tool"
  chmod 755 "$dir/yesexec-tool"
  PATH="$dir:$PATH" run require_tools yesexec-tool
  [ "$status" -eq 0 ]
}
