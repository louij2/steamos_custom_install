#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# The actual imaging work: partitioning, formatting, rootfs copy, boot config.

[[ -n ${__LIB_STEPS_SH:-} ]] && return 0
__LIB_STEPS_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"
# shellcheck source=lib/disk.sh
source "${LIBDIR}/disk.sh"

# If these directories exist they hold a newer BIOS / controller payload than
# the base image, and the vendored tool is used in preference to the system one.
VENDORED_BIOS_UPDATE="${VENDORED_BIOS_UPDATE:-/home/deck/jupiter-bios}"
VENDORED_CONTROLLER_UPDATE="${VENDORED_CONTROLLER_UPDATE:-/home/deck/jupiter-controller-fw}"

# Replace the device rootfs (btrfs). Source must be frozen before calling.
#   $1 source device  $2 target device
imageroot() {
  local srcroot="$1" newroot="$2"
  # Copy, then randomise the target UUID. Careful: duplicate btrfs ids are a
  # real problem, which is why btrfstune runs before anything mounts this.
  cmd dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$newroot"
  cmd btrfs check "$newroot"
}

# Set up boot configuration in the target partition set.
#   $1 partset name (A or B)
finalize_part() {
  local partset="$1"
  estat "Finalizing install part $partset"
  local -a chroot=(steamos-chroot --no-overlay --disk "$DISK" --partset "$partset" --)
  cmd "${chroot[@]}" mkdir -p /efi/SteamOS
  cmd "${chroot[@]}" mkdir -p /esp/SteamOS/conf
  cmd "${chroot[@]}" steamos-partsets /efi/SteamOS/partsets
  cmd "${chroot[@]}" steamos-bootconf create --image "$partset" \
      --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$partset"
  cmd "${chroot[@]}" grub-mkimage
  cmd "${chroot[@]}" update-grub
}

# Stage a BIOS update for next reboot. OOBE images do not auto-update on boot.
#
# NOTE: this is deliberately inert. Valve's original calls jupiter-biosupdate
# here; this fork targets machines that are frequently NOT Steam Decks, where
# flashing Deck firmware would be actively harmful. Set FORCEBIOS=1 to opt in.
stage_bios_update() {
  estat "Staging a BIOS update for next boot if necessary"
  local biostool=/usr/bin/jupiter-biosupdate
  if [[ -d $VENDORED_BIOS_UPDATE ]]; then
    biostool="$VENDORED_BIOS_UPDATE/jupiter-biosupdate"
    export JUPITER_BIOS_DIR="$VENDORED_BIOS_UPDATE"
  fi

  if [[ -z ${FORCEBIOS:-} ]]; then
    einfo "Skipping BIOS update (set FORCEBIOS=1 to enable; only safe on real Steam Deck hardware)"
    return 0
  fi
  cmd "$biostool"
}

# Update controller firmware. Same reasoning as the BIOS update above.
stage_controller_update() {
  estat "Updating controller firmware if necessary"
  local controller_tool=/usr/bin/jupiter-controller-update
  if [[ -d $VENDORED_CONTROLLER_UPDATE ]]; then
    controller_tool="$VENDORED_CONTROLLER_UPDATE/jupiter-controller-update"
    export JUPITER_CONTROLLER_UPDATE_FIRMWARE_DIR="$VENDORED_CONTROLLER_UPDATE"
  fi

  if [[ -z ${FORCECONTROLLER:-} ]]; then
    einfo "Skipping controller firmware update (set FORCECONTROLLER=1 to enable)"
    return 0
  fi
  cmd env JUPITER_CONTROLLER_UPDATE_IN_OOBE=1 "$controller_tool"
}

# Reinstall a fresh SteamOS copy. Driven by the writeX flags set by the caller.
repair_steps() {
  # Nothing below can get exclusive access to a disk whose partitions the
  # desktop has auto-mounted, so clear that up front rather than letting sfdisk
  # or mkfs fail with a message that never mentions mounting (issues #9, #10).
  release_disk "$DISK"

  if [[ ${writePartitionTable:-0} = 1 ]]; then
    estat "Write known partition table"
    if [[ -n ${DRY_RUN:-} ]]; then
      showcmd_unquoted "sfdisk $DISK <<< (partition table)"
      partition_table >&2
    else
      # Deliberately NOT a pipeline. If sfdisk fails, the writer feeding it gets
      # SIGPIPE, and the ERR trap then reports *the writer* - "exit 1 in
      # partition_table" - while the real cause (say sfdisk exiting 126) is
      # thrown away. Staging the table in a file keeps the failure attributable,
      # and routing sfdisk through cmd() means the error names it.
      local table
      table="$(mktemp)"
      partition_table > "$table"
      # --wipe always clears stale filesystem/RAID signatures that would
      # otherwise make sfdisk stop and ask an interactive question.
      cmd sfdisk --wipe always --wipe-partitions always "$DISK" < "$table"
      rm -f "$table"
    fi
    # The kernel does not publish the new partition nodes synchronously.
    settle_disk "$DISK" 8

  elif [[ ${writeOS:-0} = 1 || ${writeHome:-0} = 1 ]]; then
    # Verify partition settings before a partial repair. After writing the
    # table we know we are fine, and the partitions are unlabelled anyway.
    verifypart "$(diskpart "$FS_ESP")"   vfat esp
    verifypart "$(diskpart "$FS_EFI_A")" vfat efi-A
    verifypart "$(diskpart "$FS_EFI_B")" vfat efi-B
    verifypart "$(diskpart "$FS_VAR_A")" ext4 var-A
    verifypart "$(diskpart "$FS_VAR_B")" ext4 var-B
    verifypart "$(diskpart "$FS_HOME")"  ext4 home
  fi

  # Clear the var partition (user data). Also needed when reinstalling the OS:
  # a fresh system partition has overlay problems otherwise.
  if [[ ${writeOS:-0} = 1 || ${writeHome:-0} = 1 ]]; then
    estat "Creating var partitions"
    fmt_ext4 var "$(diskpart "$FS_VAR_A")"
    fmt_ext4 var "$(diskpart "$FS_VAR_B")"
  fi

  if [[ ${writeHome:-0} = 1 ]]; then
    estat "Creating home partition..."
    cmd mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart "$FS_HOME")"
    estat "Removing the reserved blocks on the home partition..."
    cmd tune2fs -m 0 "$(diskpart "$FS_HOME")"
  fi

  [[ ${writeOS:-0} = 1 ]] || return 0

  stage_bios_update
  stage_controller_update

  # Find the rootfs we are running from - that is what gets copied across.
  local rootdevice
  rootdevice="$(findmnt -n -o source / || true)"
  if [[ -z $rootdevice || ! -e $rootdevice ]]; then
    die "Could not find the USB installer root -- USB hub issue? (findmnt returned '${rootdevice:-<empty>}')"
  fi

  estat "Creating boot partitions"
  fmt_fat32 esp "$(diskpart "$FS_ESP")"
  fmt_fat32 efi "$(diskpart "$FS_EFI_A")"
  fmt_fat32 efi "$(diskpart "$FS_EFI_B")"

  estat "Freezing rootfs"
  # Invoked indirectly via the onexit trap array in the entrypoint, so static
  # analysis cannot see the call. Different shellcheck versions flag this as
  # SC2329 (never invoked) or SC2317 (unreachable); disable both.
  # shellcheck disable=SC2329,SC2317
  unfreeze() { fsfreeze -u / 2>/dev/null || true; }
  onexit+=(unfreeze)
  cmd fsfreeze -f /

  estat "Imaging OS partition A"
  imageroot "$rootdevice" "$(diskpart "$FS_ROOT_A")"

  estat "Imaging OS partition B"
  imageroot "$rootdevice" "$(diskpart "$FS_ROOT_B")"

  estat "Finalizing boot configurations"
  finalize_part A
  finalize_part B

  estat "Finalizing EFI system partition"
  cmd steamos-chroot --no-overlay --disk "$DISK" --partset A -- \
      steamcl-install --flags restricted --force-extra-removable
}

# Drop into the primary OS partset.
chroot_primary() {
  local partset
  partset="$(steamos-chroot --no-overlay --disk "$DISK" --partset A -- steamos-bootconf selected-image)"
  estat "Dropping into a chroot on the $partset partition set."
  estat "You can make any needed changes here, and exit when done."
  cmd steamos-chroot --disk "$DISK" --partset "$partset"
}
