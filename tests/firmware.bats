#!/usr/bin/env bats
# Tests for lib/firmware.sh - the UEFI preflight check behind issue #12.
#
# EFI_SYSFS is injectable precisely so these can run: /sys/firmware/efi cannot be
# moved, so each firmware state is staged as an ordinary directory instead.

load helper

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export LIBDIR="$REPO/lib"
  # shellcheck source=../lib/firmware.sh
  source "$LIBDIR/firmware.sh"

  # A machine that booted via UEFI and has EFI variable services.
  UEFI_OK="$BATS_TEST_TMPDIR/uefi"
  mkdir -p "$UEFI_OK/efivars"
  # UEFI-booted, but no EFI runtime variable services (efi=noruntime and friends).
  UEFI_NORUNTIME="$BATS_TEST_TMPDIR/noruntime"
  mkdir -p "$UEFI_NORUNTIME"
  # A legacy-BIOS/CSM boot: the kernel never creates the directory at all.
  LEGACY_BIOS="$BATS_TEST_TMPDIR/absent"
}

# A findmnt that reports whatever filesystem type the test wants, so the
# "is efivarfs mounted" branch can be driven both ways without root.
stub_findmnt() {
  local fstype="$1" dir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho %s\n' "$fstype" > "$dir/findmnt"
  chmod 755 "$dir/findmnt"
  PATH="$dir:$PATH"
  export PATH
}

@test "booted_uefi: true only when the EFI sysfs tree exists" {
  EFI_SYSFS="$UEFI_OK"     run booted_uefi
  [ "$status" -eq 0 ]
  EFI_SYSFS="$LEGACY_BIOS" run booted_uefi
  [ "$status" -ne 0 ]
}

@test "have_efivars_dir: distinguishes a UEFI boot with no variable services" {
  EFI_SYSFS="$UEFI_OK"        run have_efivars_dir
  [ "$status" -eq 0 ]
  EFI_SYSFS="$UEFI_NORUNTIME" run have_efivars_dir
  [ "$status" -ne 0 ]
}

@test "efivarfs_mounted: reads the filesystem type, not just the directory" {
  stub_findmnt efivarfs
  EFI_SYSFS="$UEFI_OK" run efivarfs_mounted
  [ "$status" -eq 0 ]
}

@test "efivarfs_mounted: a bare sysfs directory does not count as mounted" {
  stub_findmnt sysfs
  EFI_SYSFS="$UEFI_OK" run efivarfs_mounted
  [ "$status" -ne 0 ]
}

@test "require_uefi: a legacy-BIOS boot is refused, by name" {
  # The whole point of issue #12: this must fail here, not after the disk has
  # been repartitioned and 10 GB written to it.
  EFI_SYSFS="$LEGACY_BIOS" run require_uefi
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not boot via UEFI"* ]]
  [[ "$output" == *"issue #12"* ]]
}

@test "require_uefi: the legacy-BIOS message says what to actually do" {
  EFI_SYSFS="$LEGACY_BIOS" run require_uefi
  [[ "$output" == *"CSM"* ]]
  [[ "$output" == *"Ventoy"* ]]
  [[ "$output" == *"UEFI: "* ]]
}

@test "require_uefi: no EFI variable services gets its own diagnosis" {
  # Same failure in steamos-chroot, completely different remedy - so the two
  # must not share a message.
  EFI_SYSFS="$UEFI_NORUNTIME" run require_uefi
  [ "$status" -ne 0 ]
  [[ "$output" == *"no EFI variable"* ]]
  [[ "$output" == *"efi=noruntime"* ]]
  [[ "$output" == *"/proc/cmdline"* ]]
  [[ "$output" != *"did not boot via UEFI"* ]]
}

@test "require_uefi: a dry run warns loudly but still completes" {
  # Issue #12's reporter said "dry-run output seemed fine". It must not be fine:
  # the dry run has to flag this, while staying runnable end to end.
  EFI_SYSFS="$LEGACY_BIOS" DRY_RUN=1 run require_uefi
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not boot via UEFI"* ]]
  [[ "$output" == *"dry run"* ]]
}

@test "require_uefi: DOUEFIVERIFY=0 skips the check entirely and says nothing" {
  EFI_SYSFS="$LEGACY_BIOS" DOUEFIVERIFY=0 run require_uefi
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_uefi: the failure names the override rather than hiding it" {
  EFI_SYSFS="$LEGACY_BIOS" run require_uefi
  [[ "$output" == *"DOUEFIVERIFY=0"* ]]
}

@test "require_uefi: a healthy UEFI machine passes silently" {
  stub_findmnt efivarfs
  EFI_SYSFS="$UEFI_OK" run require_uefi
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_uefi: an unmounted efivarfs is mounted rather than left broken" {
  # steamos-chroot would succeed here - it binds the empty sysfs directory - and
  # the install would finish with no NVRAM boot entry. DRY_RUN keeps the test
  # hermetic while still proving the mount is attempted.
  stub_findmnt sysfs
  EFI_SYSFS="$UEFI_OK" DRY_RUN=1 run require_uefi
  [ "$status" -eq 0 ]
  [[ "$output" == *"efivarfs is not mounted"* ]]
  [[ "$output" == *"mount"*"efivarfs"* ]]
}

@test "require_uefi: a failed efivarfs mount warns but does not abort" {
  # Not being able to mount it is a degraded install, not a dead one, so this
  # must not take down a run that would otherwise have worked.
  stub_findmnt sysfs
  local dir="$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 1\n' > "$dir/mount"
  chmod 755 "$dir/mount"
  EFI_SYSFS="$UEFI_OK" run require_uefi
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not mount efivarfs"* ]]
  [[ "$output" == *"boot menu"* ]]
}

@test "the firmware preflight is errexit-safe" {
  # Same guard as the disk preflight: a bare failing test inside these helpers
  # must not abort a script running under set -e.
  require_modern_bash
  run "$BASH44" -c '
    set -euEo pipefail
    export LIBDIR="'"$LIBDIR"'"
    source "$LIBDIR/firmware.sh"
    EFI_SYSFS="'"$LEGACY_BIOS"'"
    booted_uefi      || true
    have_efivars_dir || true
    efivarfs_mounted || true
    DOUEFIVERIFY=0 require_uefi
    DRY_RUN=1 require_uefi
    echo REACHED-END
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED-END"* ]]
}

@test "a failed efivarfs mount does not trip the ERR trap" {
  # The warn-don't-die path runs `cmd mount` inside an `if !`. If errexit or the
  # inherited ERR trap fired there, a cosmetic problem on an otherwise healthy
  # UEFI machine would abort a real install - the exact failure mode
  # CONTRIBUTING.md warns about. Exercised under a live trap, not with `run`.
  require_modern_bash
  stub_findmnt sysfs
  local dir="$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nexit 1\n' > "$dir/mount"
  chmod 755 "$dir/mount"
  run "$BASH44" -c '
    set -euEo pipefail
    export LIBDIR="'"$LIBDIR"'"
    trap "echo ERR-TRAP-FIRED; exit 99" ERR
    source "$LIBDIR/firmware.sh"
    EFI_SYSFS="'"$UEFI_OK"'"
    require_uefi
    echo REACHED-END
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not mount efivarfs"* ]]
  [[ "$output" == *"REACHED-END"* ]]
  [[ "$output" != *"ERR-TRAP-FIRED"* ]]
}
