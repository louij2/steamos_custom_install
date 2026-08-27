#!/usr/bin/env bats
# Tests for lib/disk.sh - partition naming and target validation.

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
