#!/usr/bin/env bash
# End-to-end test: boot Valve's real SteamOS recovery image in a VM and install
# SteamOS onto a virtual disk, then check what landed.
#
# This is the only test that covers steamos-chroot, the btrfs rootfs copy and
# the bootloader install, and it is how the bugs fixed in c4d9b23 were found.
# The bats suite and tests/integration cover everything that does NOT need a
# SteamOS userland; this covers the rest.
#
# Needs: root, KVM, libvirt (virsh), ~25 GB free, and about 30 minutes.
# Downloads ~3.3 GB the first time and caches it.
#
#   sudo tools/vm-test/run-vm-test.sh
#   sudo tools/vm-test/run-vm-test.sh --build 20260618.10 --keep
set -euEo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"

WORKDIR="${WORKDIR:-/var/tmp/steamos-vm-test}"
BUILD="${BUILD:-20260707.10}"
VERSION="${VERSION:-3.8.14}"
DOMAIN="${DOMAIN:-steamos-install-test}"
MEM="${MEM:-8}"
VCPU="${VCPU:-4}"
TARGET_SIZE="${TARGET_SIZE:-64G}"
TIMEOUT_MIN="${TIMEOUT_MIN:-45}"
KEEP=0

die()  { echo >&2 "!! $*"; exit 1; }
info() { echo ":: $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)   BUILD="${2:?--build needs a value}"; shift 2 ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)         die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root (needs loop mounts and libvirt)"
for t in virsh losetup mount umount btrfs unzip curl tar sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
[[ -e /dev/kvm ]] || die "/dev/kvm is absent - this needs hardware virtualisation"

IMG_NAME="steamdeck-oobe-repair-${BUILD}-${VERSION}.img"
URL="https://steamdeck-images.steamos.cloud/recovery/${IMG_NAME}.zip"
RECOVERY="$WORKDIR/recovery.img"
TARGET="$WORKDIR/target.img"
CONSOLE="$WORKDIR/console.log"

mkdir -p "$WORKDIR"

# The work directory holds ~21 GB of disk images. On some hosts the obvious
# temp locations are RAM-backed - Unraid's whole rootfs is, so the default
# /var/tmp there would quietly consume 21 GB of memory. Refuse rather than
# discover that at 3am.
wd_fs="$(stat -f -c %T "$WORKDIR" 2>/dev/null || echo unknown)"
case "$wd_fs" in
  tmpfs|ramfs|rootfs)
    die "$WORKDIR is on a RAM-backed filesystem ($wd_fs) and needs ~21 GB.
   Pass --workdir with a path on real storage, e.g.
     sudo $0 --workdir /mnt/user/isos/steamos-vm-test" ;;
esac

wd_free_gb="$(( $(df -Pk "$WORKDIR" | awk 'NR==2 {print $4}') / 1024 / 1024 ))"
if [[ $wd_free_gb -lt 25 ]]; then
  die "$WORKDIR has only ${wd_free_gb} GB free; this needs about 25 GB"
fi
info "work directory: $WORKDIR (${wd_fs}, ${wd_free_gb} GB free)"

cd "$WORKDIR"

# --- teardown -------------------------------------------------------------
LOOP=""
MNT="$WORKDIR/mnt"
cleanup() {
  set +e
  mountpoint -q "$MNT" && umount "$MNT"
  [[ -n $LOOP ]] && losetup -d "$LOOP"
  if [[ $KEEP -eq 0 ]]; then
    virsh destroy "$DOMAIN" >/dev/null 2>&1
    virsh undefine "$DOMAIN" --nvram >/dev/null 2>&1
  fi
}
trap cleanup EXIT

# --- 1. fetch -------------------------------------------------------------
if [[ ! -f $RECOVERY ]]; then
  if [[ ! -f ${IMG_NAME}.zip ]]; then
    info "downloading $URL (~3.3 GB, cached for later runs)"
    curl -fL --retry 3 -C - -o "${IMG_NAME}.zip" "$URL"
  fi
  info "verifying the archive"
  unzip -tq "${IMG_NAME}.zip" || die "the downloaded archive is corrupt"
  info "unpacking"
  unzip -o -q "${IMG_NAME}.zip"
  mv -f "$IMG_NAME" "$RECOVERY"
fi
info "recovery image: $RECOVERY ($(du -h "$RECOVERY" | cut -f1))"

# --- 2. blank target disk -------------------------------------------------
info "creating a blank ${TARGET_SIZE} target disk"
rm -f "$TARGET"
truncate -s "$TARGET_SIZE" "$TARGET"

# --- 3. inject the harness into the image ---------------------------------
info "injecting the test harness"
LOOP="$(losetup --find --show --partscan "$RECOVERY")"
udevadm settle --timeout=30 || true

ROOTPART=""
for p in "$LOOP"p*; do
  [[ "$(blkid -o value -s TYPE "$p" 2>/dev/null)" == btrfs ]] && { ROOTPART="$p"; break; }
done
[[ -n $ROOTPART ]] || die "no btrfs rootfs found in the recovery image"
info "rootfs partition: $ROOTPART"

mkdir -p "$MNT"
mount -o rw "$ROOTPART" "$MNT"
# SteamOS ships the root subvolume flagged read-only; that is a btrfs property,
# not a mount option, so `mount -o rw` alone is not enough.
btrfs property set -ts "$MNT" ro false

# Clear any harness left behind by an earlier run against this same image.
# Two enabled units means two harnesses racing for the target disk, and the
# install fails in a way that looks like a product bug but is not.
rm -f "$MNT"/etc/systemd/system/multi-user.target.wants/*steamos*test*.service
rm -f "$MNT"/etc/systemd/system/*steamos*test*.service
rm -rf "$MNT/usr/local/steamos_custom_install" "$MNT/usr/local/steamos-vm-test" \
       "$MNT/usr/local/steamos_custom_install-test"
mkdir -p "$MNT/usr/local/steamos_custom_install" "$MNT/usr/local/steamos-vm-test"
tar -C "$REPO_ROOT" -cf - \
    --exclude='.git' --exclude='*.img' --exclude='*.zip' . \
  | tar -C "$MNT/usr/local/steamos_custom_install" -xf -
install -m 0755 "$HERE/guest-tests.sh" "$MNT/usr/local/steamos-vm-test/guest-tests.sh"

cat > "$MNT/etc/systemd/system/steamos-vm-test.service" <<'UNIT'
[Unit]
Description=Automated end-to-end test of the custom SteamOS installer
After=multi-user.target systemd-udevd.service local-fs.target
Wants=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=3600
ExecStartPre=/usr/bin/udevadm settle --timeout=30
ExecStart=/usr/local/steamos-vm-test/guest-tests.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../steamos-vm-test.service \
       "$MNT/etc/systemd/system/multi-user.target.wants/steamos-vm-test.service"

sync
btrfs property set -ts "$MNT" ro true
umount "$MNT"
losetup -d "$LOOP"; LOOP=""

# --- 4. define and boot ---------------------------------------------------
# Firmware and emulator live on the LIBVIRT HOST, which is not necessarily this
# machine - a containerised CI runner drives libvirt over its socket. So these
# are overridable, and the emulator is asked of libvirt itself rather than
# looked for locally.
OVMF_CODE="${OVMF_CODE:-}"; OVMF_VARS="${OVMF_VARS:-}"
for d in /usr/share/qemu/ovmf-x64 /usr/share/OVMF /usr/share/edk2/ovmf /usr/share/edk2-ovmf/x64; do
  for c in OVMF_CODE-pure-efi.fd OVMF_CODE.fd OVMF_CODE.secboot.fd; do
    [[ -f "$d/$c" && -z $OVMF_CODE ]] && OVMF_CODE="$d/$c"
  done
  for v in OVMF_VARS-pure-efi.fd OVMF_VARS.fd; do
    [[ -f "$d/$v" && -z $OVMF_VARS ]] && OVMF_VARS="$d/$v"
  done
done
[[ -n $OVMF_CODE && -n $OVMF_VARS ]] || die "no OVMF firmware found.
   Install edk2-ovmf, or set OVMF_CODE and OVMF_VARS to paths on the libvirt host."
info "firmware: $OVMF_CODE"

# Ask libvirt for the host's emulator rather than assuming this machine has it.
# Must be domcapabilities for the x86_64 guest specifically: plain
# `virsh capabilities` lists every guest arch the host can emulate, and taking
# the first one happily hands back qemu-system-aarch64.
if [[ -z ${EMULATOR:-} ]]; then
  EMULATOR="$(virsh domcapabilities --arch x86_64 --virttype kvm 2>/dev/null \
    | sed -n 's|.*<path>\(.*\)</path>.*|\1|p' | head -1)"
fi
[[ -n ${EMULATOR:-} ]] || EMULATOR="$(command -v qemu-system-x86_64 || echo /usr/local/sbin/qemu)"
[[ -n $EMULATOR ]] || die "could not determine the qemu emulator; set EMULATOR"
info "emulator: $EMULATOR"

: > "$CONSOLE"
virsh destroy "$DOMAIN" >/dev/null 2>&1 || true
virsh undefine "$DOMAIN" --nvram >/dev/null 2>&1 || true
sed -e "s|@NAME@|$DOMAIN|g" -e "s|@MEM@|$MEM|g" -e "s|@VCPU@|$VCPU|g" \
    -e "s|@OVMF_CODE@|$OVMF_CODE|g" -e "s|@OVMF_VARS@|$OVMF_VARS|g" \
    -e "s|@NVRAM@|/var/lib/libvirt/qemu/nvram/${DOMAIN}_VARS.fd|g" \
    -e "s|@EMULATOR@|$EMULATOR|g" -e "s|@RECOVERY@|$RECOVERY|g" \
    -e "s|@TARGET@|$TARGET|g" -e "s|@CONSOLE@|$CONSOLE|g" \
    "$HERE/domain.xml.in" > "$WORKDIR/domain.xml"
mkdir -p /var/lib/libvirt/qemu/nvram
virsh define "$WORKDIR/domain.xml" >/dev/null
virsh start "$DOMAIN" >/dev/null
info "VM started; waiting up to ${TIMEOUT_MIN}m for the guest to finish"

# --- 5. wait --------------------------------------------------------------
deadline=$(( SECONDS + TIMEOUT_MIN * 60 ))
while (( SECONDS < deadline )); do
  grep -q "TEST-RUN-COMPLETE" "$CONSOLE" 2>/dev/null && break
  sleep 15
done

if ! grep -q "TEST-RUN-COMPLETE" "$CONSOLE" 2>/dev/null; then
  echo "----- guest console (tail) -----"
  tr -d '\r' < "$CONSOLE" | tail -40
  die "timed out after ${TIMEOUT_MIN}m without the guest completing"
fi

# --- 6. report ------------------------------------------------------------
echo
echo "================= GUEST OUTPUT ================="
tr -d '\r' < "$CONSOLE" | sed -n '/TEST-RUN-BEGIN/,$p'
echo "================================================"

results="$(tr -d '\r' < "$CONSOLE" | grep -oE 'RESULTS: [0-9]+ passed, [0-9]+ failed' | tail -1)"
[[ -n $results ]] || die "could not find a RESULTS line in the guest output"
info "$results"
failed="$(echo "$results" | sed -E 's/.* ([0-9]+) failed/\1/')"
[[ $failed -eq 0 ]] || die "$failed guest assertion(s) failed"
info "VM end-to-end test PASSED"
