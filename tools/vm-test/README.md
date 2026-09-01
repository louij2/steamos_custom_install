# `tools/vm-test/` — end-to-end test in a VM

Boots **Valve's real SteamOS recovery image** in a KVM guest and installs SteamOS
onto a virtual disk, then checks what landed on it.

A VM is not a second-best stand-in here. This project exists for hardware that
is *not* a Steam Deck, and a VM is exactly that case: no NVMe, no Deck firmware,
a target disk the desktop happily auto-mounts.

## Why this exists

The `bats` suite and `tests/integration/` cover everything that does not need a
SteamOS userland. They cannot reach `steamos-chroot`, the btrfs rootfs copy, or
the bootloader install — and they cannot reproduce the conditions behind the two
reported bugs.

This test found two real defects that every other layer passed:

1. `partition_table | sfdisk` was a pipeline. When `sfdisk` failed, the writer
   feeding it took `SIGPIPE`, so the error trap reported **the writer**
   (`exit 1 in partition_table`) and threw away the real cause (`sfdisk`
   exiting 126). Exactly the misleading-error class this fork exists to remove.
2. `require_tools` asked only `command -v`, which as root can resolve a path
   with no execute bit — preflight passed, and the run died later at the point
   of use.

## Running it

```bash
sudo tools/vm-test/run-vm-test.sh
```

Needs root, `/dev/kvm`, libvirt, ~25 GB free and about 30 minutes. The ~3.3 GB
recovery image is downloaded once and cached in the work directory.

| Option | Meaning |
|---|---|
| `--build 20260618.10` | Test against a different recovery build |
| `--version 3.8.10` | The SteamOS version part of the filename |
| `--workdir DIR` | Where images and the console log live (default `/var/tmp/steamos-vm-test`) |
| `--keep` | Leave the VM defined afterwards, for poking at |

Environment overrides: `MEM`, `VCPU`, `TARGET_SIZE`, `TIMEOUT_MIN`, `DOMAIN`.

## What it does

1. Downloads and unpacks the recovery image.
2. Injects this repo plus `guest-tests.sh` into the image's btrfs rootfs, and
   enables a systemd unit to run it on boot. SteamOS flags the root subvolume
   read-only as a *btrfs property*, so `mount -o rw` alone is not enough —
   the script clears the property and restores it afterwards.
3. Defines a UEFI VM: the recovery image as `vda`, a blank disk as `vdb`, and a
   serial port written to `console.log` on the host.
4. Boots it, waits for `TEST-RUN-COMPLETE`, and fails on any guest assertion.

## What the guest checks

| | Check |
|---|---|
| T1 | A present-but-unrunnable `sfdisk` is caught by preflight, and named |
| T2 | A missing `steamos-chroot` explains that you are on the wrong boot media |
| T3 | A failing `sfdisk` is blamed on `sfdisk`, with its real exit code — not on the table writer |
| T4 | A full install onto a disk that **starts out mounted** (the issue #9 scenario) succeeds |
| T5 | All 8 partitions have the right type and label, the A/B rootfs UUIDs differ, and `bootx64.efi` is written |

## Verifying that the result actually boots

The install test leaves `target.img` behind. To prove the installed disk boots
on its own, define a second VM with **only** that disk attached and no recovery
media. It should reach multi-user with `/` on the `rootfs-A` or `rootfs-B`
partition of that disk.

Note that the Deck kernel has no QXL driver, so the VM console stays black even
on a successful boot. Judge it by disk I/O and by adding `console=ttyS0,115200`
to the kernel command line in `EFI/steamos/grub.cfg` on the `efi-A` partition —
not by the screen.

## CI

`.github/workflows/vm-test.yml` runs this on a self-hosted runner labelled
`kvm`, on manual dispatch. It is deliberately not on GitHub's hosted runners:
they have neither nested virtualisation nor the disk budget.
