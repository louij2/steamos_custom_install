#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Firmware preflight: did this machine boot via UEFI, with usable EFI variables?
#
# This exists for the same reason as the preflight block in lib/disk.sh - a
# precondition that is knowable before the first destructive command, but which
# currently only surfaces as an unactionable failure at the very end of the
# install (issue #12).

[[ -n ${__LIB_FIRMWARE_SH:-} ]] && return 0
__LIB_FIRMWARE_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"

# Where the kernel publishes EFI state. Overridable only so the tests can stage
# each firmware case in a temp directory - /sys itself cannot be moved.
EFI_SYSFS="${EFI_SYSFS:-/sys/firmware/efi}"

# The kernel creates /sys/firmware/efi only when it booted via UEFI, and the
# efivars/ directory under it only when EFI runtime *variable* services are
# usable. Both are reliable tells, and neither costs anything to read.
booted_uefi()      { [[ -d $EFI_SYSFS ]]; }
have_efivars_dir() { [[ -d $EFI_SYSFS/efivars ]]; }

# Is efivarfs actually mounted on efivars/, as opposed to the bare sysfs
# directory merely being present? --target reports the filesystem *containing*
# the path, which answers it either way: efivarfs when mounted, sysfs when not.
efivarfs_mounted() {
  local fstype
  fstype="$(findmnt -rno FSTYPE --target "$EFI_SYSFS/efivars" 2>/dev/null || true)"
  [[ $fstype == efivarfs ]]
}

# Refuse to start an install this machine cannot finish - before anything is
# destroyed.
#
# SteamOS is UEFI-only: Valve's grub-mkimage builds an x86_64-efi image and
# there is no i386-pc/BIOS path anywhere in their tooling. Worse, steamos-chroot
# bind-mounts /sys/firmware/efi/efivars unconditionally:
#
#   mount --bind /sys  $dir/sys
#   mount --bind /sys/firmware/efi/efivars $dir/sys/firmware/efi/efivars
#
# The bind of /sys is not recursive, so that second target exists only if the
# host kernel created the directory in the first place. On a machine that did
# not boot via UEFI it never did, and the chroot dies with
#
#   mount: /tmp/tmp.XXXXXXXX/sys/firmware/efi/efivars: mount point does not exist.
#
# exiting 32. That happens in finalize_part - the very last step, after the
# partition table has been rewritten, six filesystems created and both 5 GB
# rootfs copies written. The disk is already unusable by then, and the error
# names neither UEFI nor the firmware. That is issue #12.
require_uefi() {
  [[ ${DOUEFIVERIFY:-1} = 1 ]] || return 0

  local problem=""
  if ! booted_uefi; then
    problem=bios
  elif ! have_efivars_dir; then
    problem=noruntime
  fi

  if [[ -z $problem ]]; then
    # UEFI-booted with EFI variables available. If efivarfs is not mounted the
    # chroot still starts - it binds the empty sysfs directory - but
    # steamcl-install then cannot register a boot entry in NVRAM, and the
    # install ends up reachable only through the removable fallback path.
    # Mount it rather than letting that happen silently.
    if ! efivarfs_mounted; then
      ewarn "efivarfs is not mounted on $EFI_SYSFS/efivars; mounting it"
      if ! cmd mount -t efivarfs efivarfs "$EFI_SYSFS/efivars"; then
        ewarn "Could not mount efivarfs. The install should still complete, but"
        ewarn "the firmware may not get a SteamOS boot entry - you would then have"
        ewarn "to pick the drive from the boot menu by hand."
      fi
    fi
    return 0
  fi

  if [[ $problem == bios ]]; then
    eerr "This machine did not boot via UEFI - $EFI_SYSFS does not exist."
    eerr "SteamOS can only boot via UEFI, and the install would fail at the very"
    eerr "last step, long after the target disk had been erased (issue #12)."
    eerr "Stopping now instead."
    eerr ""
    eerr "To fix it:"
    eerr "  1. If you booted the recovery image through Ventoy, choose its UEFI"
    eerr "     boot entry rather than the legacy/BIOS one - or write the image"
    eerr "     straight to the stick with Rufus (GPT/UEFI) or Balena Etcher."
    eerr "  2. In firmware setup, turn OFF 'CSM', 'Legacy Boot' or 'Legacy"
    eerr "     Support', and set the boot mode to UEFI."
    eerr "  3. Boot the stick again from the entry listed as 'UEFI: <your stick>'."
  else
    eerr "This machine booted via UEFI, but the kernel has no EFI variable"
    eerr "services: $EFI_SYSFS exists and $EFI_SYSFS/efivars does not."
    eerr "steamos-chroot bind-mounts that path unconditionally, so the install"
    eerr "would fail at the very last step with 'mount point does not exist'"
    eerr "(exit 32), long after the target disk had been erased (issue #12)."
    eerr ""
    eerr "The usual causes:"
    eerr "  - 'efi=noruntime' or 'noefi' on the kernel command line - check"
    eerr "    'cat /proc/cmdline'."
    eerr "  - 32-bit firmware with a 64-bit kernel, common on older tablets."
    eerr "  - Firmware whose runtime services the kernel refused to use - check"
    eerr "    'dmesg | grep -i efi'."
  fi

  if [[ -n ${DRY_RUN:-} ]]; then
    eerr ""
    ewarn "Continuing anyway because this is a dry run."
    ewarn "A real run on this machine would stop here."
    return 0
  fi

  eerr ""
  ewarn "DOUEFIVERIFY=0 skips this check, but expect steamos-chroot to fail."
  die "Cannot install SteamOS on a machine that is not UEFI-booted."
}
