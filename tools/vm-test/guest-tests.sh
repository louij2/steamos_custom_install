#!/usr/bin/env bash
# Runs INSIDE the test VM, booted from Valve's SteamOS recovery image.
#
# Driven by a systemd unit that tools/vm-test/run-vm-test.sh injects into the
# image. Everything is reported over the serial port, which libvirt writes to a
# file on the host; the host script greps that for the result.
#
# Order matters: the preflight checks are non-destructive and run first, then
# the full install, then verification of what landed on the disk.

exec > >(tee -a /dev/ttyS0) 2>&1

REPO="${REPO:-/usr/local/steamos_custom_install}"
TARGET="${TARGET:-/dev/vdb}"
PASS=0
FAIL=0

banner() { echo; echo "################ $* ################"; }
ok()     { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad()    { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
# assert <condition-as-string-match> — keeps the checks readable and avoids the
# `A && ok || bad` shape, which runs `bad` when `ok` itself fails.

banner "TEST-RUN-BEGIN"
echo "date:         $(date -u '+%F %T UTC')"
echo "kernel:       $(uname -sr)"
echo "bash:         $BASH_VERSION"
echo "os:           $(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null)"
echo "steps.sh sha: $(sha256sum "$REPO/lib/steps.sh" | cut -c1-16)"
echo "target:       $TARGET"
echo "PATH:         $PATH"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

# ---------------------------------------------------------------------------
banner "T1: a present-but-unrunnable sfdisk is caught by preflight"
# /dev/null has no execute bit, so this is 'the tool is there but cannot run' -
# which `command -v` alone does not catch.
mount --bind /dev/null /usr/bin/sfdisk
out="$(bash "$REPO/bin/steamos-install" --yes --disk "$TARGET" all 2>&1)" || true
umount /usr/bin/sfdisk
echo "$out" | head -8
if [[ $out == *"Missing required command"* && $out == *sfdisk* ]]; then ok "preflight named sfdisk"; else bad "preflight named sfdisk"; fi
if [[ $out == *"PATH is:"* ]]; then ok "reported the PATH it searched"; else bad "reported the PATH it searched"; fi
if [[ $out != *"Write known partition table"* ]]; then ok "aborted before the destructive step"; else bad "aborted before the destructive step"; fi

# ---------------------------------------------------------------------------
banner "T2: a missing steamos-chroot explains the wrong boot media"
mount --bind /dev/null /usr/bin/steamos-chroot
out2="$(bash "$REPO/bin/steamos-install" --yes --disk "$TARGET" all 2>&1)" || true
umount /usr/bin/steamos-chroot
echo "$out2" | head -8
if [[ $out2 == *"recovery image"* ]]; then ok "told the user about the boot media"; else bad "told the user about the boot media"; fi
if [[ $out2 != *"Write known partition table"* ]]; then ok "aborted before partitioning"; else bad "aborted before partitioning"; fi

# ---------------------------------------------------------------------------
banner "T3: a failing sfdisk is blamed on sfdisk, not on the table writer"
# Regression guard. This used to be a pipeline, so a dying sfdisk sent SIGPIPE
# to the writer and the ERR trap reported the writer instead.
cat > /tmp/fake-sfdisk <<'FAKE'
#!/bin/bash
cat > /dev/null
echo "fake sfdisk: deliberate failure" >&2
exit 33
FAKE
chmod +x /tmp/fake-sfdisk
mount --bind /tmp/fake-sfdisk /usr/bin/sfdisk
out3="$(bash "$REPO/bin/steamos-install" --yes --disk "$TARGET" all 2>&1)"
rc3=$?
umount /usr/bin/sfdisk
echo "$out3" | tail -12
echo "rc=$rc3"
if [[ $out3 == *"Last command run:"*sfdisk* ]]; then ok "the error names sfdisk"; else bad "the error names sfdisk"; fi
if [[ $out3 != *"cat <<END_PARTITION_TABLE"* ]]; then ok "no longer blames the table writer"; else bad "no longer blames the table writer"; fi
if [[ $rc3 -eq 33 ]]; then ok "propagated sfdisk's real exit code (33)"; else bad "propagated sfdisk's real exit code (33)"; fi

# ---------------------------------------------------------------------------
banner "T4: full install onto a MOUNTED disk (the issue #9 scenario)"
wipefs -a "$TARGET" >/dev/null 2>&1 || true
printf 'label: gpt\nstart=2048, size=204800, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' \
  | sfdisk "$TARGET" >/dev/null 2>&1 || true
udevadm settle --timeout=20 || true
mkfs.ext4 -F -q "${TARGET}1" >/dev/null 2>&1
mkdir -p /mnt/decoy && mount "${TARGET}1" /mnt/decoy
echo "target starts out mounted at: $(findmnt -rno TARGET --source "${TARGET}1")"

# Suppress the installer's closing reboot so verification below can run.
mount --bind /bin/true /usr/bin/systemctl
bash "$REPO/bin/steamos-install" --yes --disk "$TARGET" all > /tmp/install.log 2>&1
rc4=$?
umount /usr/bin/systemctl
tail -25 /tmp/install.log
echo "installer rc=$rc4"
if [[ $rc4 -eq 0 ]]; then ok "installed onto a disk that began mounted"; else bad "installed onto a disk that began mounted"; fi

# ---------------------------------------------------------------------------
banner "T5: verify what landed on the disk"
udevadm settle --timeout=20 || true
allgood=1
chk() {
  local d="${TARGET}$1" t p
  t="$(blkid -o value -s TYPE "$d" 2>/dev/null)"
  p="$(blkid -o value -s PARTLABEL "$d" 2>/dev/null)"
  printf '  p%-2s %-6s %-9s ' "$1" "${t:-none}" "${p:-none}"
  # shellcheck disable=SC2034  # allgood is read by the check() call after the chk block
  if [[ $t == "$2" && $p == "$3" ]]; then echo OK; else echo "WRONG (want $2/$3)"; allgood=0; fi
}
chk 1 vfat esp;      chk 2 vfat efi-A;  chk 3 vfat efi-B; chk 4 btrfs rootfs-A
chk 5 btrfs rootfs-B; chk 6 ext4 var-A; chk 7 ext4 var-B; chk 8 ext4 home
if [[ $allgood == 1 ]]; then ok "all 8 partitions have the expected type and label"; else bad "all 8 partitions have the expected type and label"; fi

ua="$(blkid -o value -s UUID "${TARGET}4")"
ub="$(blkid -o value -s UUID "${TARGET}5")"
echo "  rootfs-A UUID=$ua"
echo "  rootfs-B UUID=$ub"
if [[ -n $ua && $ua != "$ub" ]]; then ok "btrfstune re-randomised the B copy"; else bad "btrfstune re-randomised the B copy"; fi

mkdir -p /mnt/vesp && mount "${TARGET}1" /mnt/vesp 2>/dev/null
if [[ -f /mnt/vesp/efi/boot/bootx64.efi ]]; then ok "removable-path bootloader written"; else bad "removable-path bootloader written"; fi
umount /mnt/vesp 2>/dev/null || true

banner "RESULTS: $PASS passed, $FAIL failed"
banner "TEST-RUN-COMPLETE"
sync
