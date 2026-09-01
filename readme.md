# 🔧 Custom SteamOS Recovery Installer (External Drive–Friendly)

This tool lets you install or repair SteamOS using **Valve’s official recovery image** — but with added support for external SSDs, USB drives, and non-NVMe devices.

### ✅ Features:
- A patched version of `repair_device.sh`
- A prompt to choose your install disk (e.g. `/dev/sda`) — or pass `--disk`
- Fixes the partition naming issue (`p` vs no-`p`) on non-NVMe drives
- Works with or without a graphical session — falls back to terminal prompts when the zenity dialogs can't be shown
- `--dry-run` shows you every destructive command **without running any of them**
- Checks every tool it needs **before** doing anything destructive, and names what is missing
- Unmounts the target disk for you, so `sfdisk` can actually get exclusive access
- Waits for the new partition devices to appear before formatting them
- Skips the Steam Deck BIOS and controller firmware flashing by default, which is the right call on non-Deck hardware
- A [catalogue of Valve's recovery images](docs/images.md) with notes on which ones work where

> 🧭 **New to Linux or the terminal?** Follow the
> **[step-by-step guide](docs/step-by-step-guide.md)** instead of this page. It
> spells out every command, shows exactly what each prompt looks like, and
> explains how to identify the right disk.

---

## 💿 What You Need

- A Steam Deck or compatible PC 
  👉 [Valve's Requirments](https://store.steampowered.com/steamos/buildyourown)
- Valve’s official SteamOS recovery image  
  👉 [Pick one from the image catalogue](docs/images.md) — it lists the latest builds,
  flags which are **Steam Deck** (`main`) vs **SteamOS for PC** (`pc`), and carries
  notes on images confirmed to work on awkward hardware
  👉 Or [download from Valve directly](https://store.steampowered.com/steamos/download/?ver=custom)
- A USB stick flashed with the image using [Balena Etcher](https://www.balena.io/etcher/) or [Rufus](https://rufus.ie/en/)
- A keyboard and mouse
- The target drive you want to install SteamOS on (internal or external)

---

## 🚀 How to Use

### 1. Boot Into the SteamOS Recovery USB

- Plug in the USB stick
- On a Steam Deck, hold **Volume Down + Power** to open the boot menu
- Select the USB and boot into the recovery environment

---

### 2. Open a Terminal

Launch **Konsole** from the desktop, or press `Ctrl + Alt + T`.

---

### 3. Clone This Repo

```bash
git clone https://github.com/louij2/steamos_custom_install.git
cd steamos_custom_install 
```
---

### 4. Make the Script Executable

```bash
chmod +x repair_device.sh
```
---
### 5. Run the Installer Script

**See what it would do first — this touches nothing:**

```bash
sudo ./repair_device.sh --disk /dev/sda --dry-run all
```

**Then do it for real:**

```bash
sudo ./repair_device.sh all
```

Not sure which disk? `sudo ./repair_device.sh --list-disks` prints what's attached.

You’ll be prompted to:
- Enter the target disk (e.g. `/dev/sda`)
- Confirm that you really want to wipe and reinstall SteamOS
- Confirm the action a second time, either in a zenity dialog or — if no desktop
  session is reachable — right in the terminal

> The target (`all`, `system`, `home`, `chroot`, `sanitize`) is **required**.
> Running `sudo ./repair_device.sh` with no target just prints the help text.

<details>
<summary>All options</summary>

| Option | Effect |
|---|---|
| `-d`, `--disk DEVICE` | Target disk, e.g. `/dev/sda`. Prompted for if omitted |
| `-n`, `--dry-run` | Print every destructive command instead of running it |
| `-y`, `--yes` | Skip all confirmation prompts (unattended) |
| `--no-zenity` | Always use terminal prompts, never GUI dialogs |
| `--poweroff` | Power off instead of rebooting when finished |
| `--list-disks` | Show attached disks and exit |
| `-h`, `--help` | Full help |

</details>

---

## 📦 What It Does

This script will:

1. Wipe and repartition the selected drive  
2. Format system, boot, and home partitions  
3. Copy SteamOS rootfs  
4. Configure GRUB and EFI  
5. Reboot (or let you stay in the live session)

---

## 🧠 Tips & Safety Notes

- If you're installing to an **external SSD**, it’s highly recommended to unplug your internal NVMe drive — or lock it down like this:

```bash
sudo chmod 000 /dev/nvme0n1
```

- The script automatically detects whether your disk needs \`p\` in partition names (e.g. \`nvme0n1p1\` vs \`sda1\`)
- You can tweak the script to skip formatting \`/home\`, disable BIOS updates, or jump into a chroot after install

### Environment variables

| Variable | Effect |
|---|---|
| `NOPROMPT=1` | Skip the confirmation dialogs entirely (unattended runs) |
| `NOZENITY=1` | Always use terminal prompts, never zenity dialogs |
| `POWEROFF=1` | Power off instead of rebooting when finished |
| `HANG_ON_ERROR=1` | Stay on screen after an error instead of exiting (Valve's original behaviour) |
| `DRY_RUN=1` | Same as `--dry-run` |
| `FORCEBIOS=1` | Enable the BIOS update step — **Steam Deck hardware only** |
| `FORCECONTROLLER=1` | Enable the controller firmware update step |

---

## 🩺 Troubleshooting

### "Nothing happens after I pick my disk and type YES"

Fixed. Older copies of this script exited without printing anything at that
point, because the confirmation dialog is drawn by `zenity` and `zenity` cannot
reach your desktop session when the script runs under `sudo` (`sudo` drops
`XAUTHORITY` / `WAYLAND_DISPLAY`). The script ran with `set -e` but no `set -E`,
so the failure aborted everything **without any error message at all**.

The script now detects that case and asks for confirmation in the terminal
instead. If you cloned the repo before this fix, just update:

```bash
cd steamos_custom_install
git pull
```

You can also force terminal prompts at any time with `NOZENITY=1`.

### The script fails part-way through

Errors are reported with the file and line, the **exact command that failed**,
and a call stack showing how it got there. Paste the whole block when opening an
issue.

Earlier versions reported a failure inside the command wrapper as
`!! Failed at line 137 (exit 1): "$@"`, which pointed at the wrapper rather than
the step that broke. That is fixed.

### "Checking that no-one is using this disk right now ... FAILED"

`sfdisk` says this when something still has the target disk open — almost always
because the recovery image's desktop auto-mounted a partition on it the moment
you plugged it in. Reformatting the drive beforehand does not help; mounting it
to check is what causes it.

The installer now unmounts the target disk itself before partitioning, so this
should not happen any more. If it still does, the error names what is holding
the disk. To check by hand:

```bash
lsblk -o NAME,SIZE,MOUNTPOINTS /dev/sda
```

and unmount anything with a mountpoint:

```bash
sudo umount -R /dev/sda1
```

If the disk is held by LUKS or LVM rather than a plain mount, close that first
(`sudo cryptsetup close <name>`, or `sudo vgchange -an`).

### "exit 127" partway through

Exit 127 means a command was **not found**. The two usual causes:

- `sudo` replaced `PATH` with a `secure_path` that has no `/usr/sbin`, which is
  where `sfdisk` and `mkfs.*` live. The installer now puts the admin
  directories back on `PATH` itself.
- You are not booted from a **SteamOS recovery image**. An ordinary Linux live
  USB has no `steamos-chroot`, and this script cannot install SteamOS without
  it. The installer now checks for every tool it needs up front and names the
  missing one instead of failing halfway through.

### Formatting fails immediately after the partition table is written

The kernel does not publish `/dev/sda1`, `/dev/sda2`… the instant `sfdisk`
returns. On USB and SATA SSDs it can lag by a second or more, and `mkfs` then
fails with a bare `exit 1`. The installer now re-reads the partition table and
waits (up to 30s) for every partition node to appear before formatting anything.

### "does not exist" / "is not a block device"

Pass a **whole disk**, not a partition — `/dev/sda`, not `/dev/sda1`. Run
`lsblk` to see what's attached.

---

## 🛠 What This Fixes (Compared to Valve’s Script)

| Valve's Script                      | This Script                               |
|------------------------------------|-------------------------------------------|
| Hardcoded to `/dev/nvme0n1pX`      | Prompts for any disk (e.g. `/dev/sda`)    |
| Crashes on external drives         | Handles non-NVMe partition naming         |
| Requires zenity + a desktop session | Falls back to terminal prompts            |
| Hangs forever on error             | Reports the failing command, line and call stack, then exits |
| Fails at exit 127/1 with no context | Preflights every required tool and names what is missing |
| Trips over auto-mounted partitions | Unmounts the target disk before partitioning |
| Wipes disks with no confirmation   | Prompts before doing anything destructive |
| No way to preview                  | `--dry-run` prints every command, runs none |
| Flashes Deck BIOS + controller FW  | Skipped unless you opt in — safer on non-Deck hardware |

The full list, kept as a review checklist for upstream changes, is in
[docs/upstream-sync.md](docs/upstream-sync.md).

---

## 📂 File Overview

| File                          | Description                                    |
|-------------------------------|------------------------------------------------|
| `repair_device.sh`            | Compatibility shim — forwards to `bin/steamos-install` |
| `bin/steamos-install`         | The installer entrypoint (argument parsing, prompts, flow) |
| `lib/`                        | `log` · `ui` · `disk` · `steps` · `sanitize` modules |
| `upstream/`                   | Valve's pristine script, vendored as a diff baseline — never executed |
| `data/images.yaml`            | Recovery image catalogue + hand-written end-user notes |
| `tools/`                      | Upstream extraction and catalogue refresh tooling |
| `tests/`                      | `bats` unit tests |
| `docs/step-by-step-guide.md`  | Beginner walkthrough with annotated prompts    |
| `docs/images.md`              | Generated image catalogue |
| `docs/upstream-sync.md`       | How Valve's changes are tracked, and our deliberate divergences |

---

## ⚠️ Disclaimer

- **This will completely erase the selected disk.**  
- Triple-check that you’ve chosen the correct device before continuing.  
- Use at your own risk — know that this hasn't been properly tested to avoid surprises.
- It seems that if you enable `SSHD` from the installer then it will fail to install SteamOS.
- Some people have reported that after installing, the SteamOS `first run` gets stuck trying to apply an update. On some "unsupported" machines, [nightly build of Recovery USB](https://steamdeck-images.steamos.cloud/steamdeck/20251027.1000/steamdeck-repair-main-20251027.1000-3.8.0.img.zip) is more likely to work.
