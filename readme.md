# 🔧 Custom SteamOS Recovery Installer (External Drive–Friendly)

This tool lets you install or repair SteamOS using **Valve’s official recovery image** — but with added support for external SSDs, USB drives, and non-NVMe devices.

### ✅ Features:
- A patched version of `repair_device.sh`
- A prompt to choose your install disk (e.g. `/dev/sda`)
- Fixes the partition naming issue (`p` vs no-`p`) on non-NVMe drives

---

## 💿 What You Need

- A Steam Deck or compatible PC 
  👉 [Valve's Requirments](https://store.steampowered.com/steamos/buildyourown)
- Valve’s official SteamOS recovery image  
  👉 [Download here](https://store.steampowered.com/steamos/download/?ver=custom)
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

```bash
sudo ./repair_device.sh all
```

You’ll be prompted to:
- Enter the target disk (e.g. `/dev/sda`)
- Confirm that you really want to wipe and reinstall SteamOS

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

---

## 🛠 What This Fixes (Compared to Valve’s Script)

| Valve's Script                      | This Script                               |
|------------------------------------|-------------------------------------------|
| Hardcoded to `/dev/nvme0n1pX`      | Prompts for any disk (e.g. `/dev/sda`)    |
| Crashes on external drives         | Fully stable on all device types          |
| GUI-based (zenity)                 | Clean CLI interface                       |
| Wipes disks with no confirmation   | Prompts before doing anything destructive |

---

## 📂 File Overview

| File                | Description                                       |
|---------------------|---------------------------------------------------|
| `repair_device.sh`  | Main patched installer script with disk prompt    |
| `repair_reimage.sh` | Simple wrapper for running `repair_device.sh all` |

---

## ⚠️ Disclaimer

- **This will completely erase the selected disk.**  
- Triple-check that you’ve chosen the correct device before continuing.  
- Use at your own risk — know that this hasn't been properly tested to avoid surprises.
- It seems that if you enable `SSHD` from the installer then it will fail to install SteamOS.
- Some people have reported that after installing, the SteamOS `first run` gets stuck trying to apply an update. On some "unsupported" machines, [nightly build of Recovery USB](https://steamdeck-images.steamos.cloud/steamdeck/20251027.1000/steamdeck-repair-main-20251027.1000-3.8.0.img.zip) is more likely to work.
