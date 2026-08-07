# 🧭 Step-by-Step Guide (for people who have never used a terminal)

This is the long version of the readme. It assumes **no Linux experience**. Every
command is written out, and every screen you'll see is shown below so you can
check you're in the right place.

⏱ Budget about **45–60 minutes**, most of it waiting on downloads and copying.

> ⚠️ **This erases the entire disk you select.** Not one partition — the whole
> drive. Read [Step 5](#step-5-find-out-which-disk-to-install-to) carefully; it's
> the only step where a mistake is unrecoverable.

---

## What you need before you start

| Thing | Notes |
|---|---|
| A PC or Steam Deck | See [Valve's requirements](https://store.steampowered.com/steamos/buildyourown) |
| A USB stick, 8 GB or larger | **Its contents will be erased** |
| The drive you want SteamOS on | Internal or external. Its contents will be erased too |
| A USB keyboard | Essential — you'll be typing. A mouse helps |
| A second computer | To download and flash the USB stick |

---

## Step 1 — Download the recovery image

Download Valve's official recovery image:
👉 https://store.steampowered.com/steamos/download/?ver=custom

You'll get a file ending in `.img.zip` — roughly 3 GB. **Don't unzip it**; the
flashing tools in the next step read the `.zip` directly.

---

## Step 2 — Write the image to your USB stick

Use [Balena Etcher](https://www.balena.io/etcher/) (Windows/Mac/Linux) or
[Rufus](https://rufus.ie/en/) (Windows).

In Etcher:
1. **Flash from file** → pick the `.img.zip` you downloaded
2. **Select target** → pick your USB stick — *double-check the size matches your
   stick, not your hard drive*
3. **Flash!** → wait for "Flash Complete"

If Windows pops up "You need to format the disk before you can use it" when it's
done, **click Cancel**. The stick is fine; Windows just can't read Linux
filesystems.

---

## Step 3 — Boot from the USB stick

Plug the stick into the machine you're installing on, then:

**On a Steam Deck:** hold **Volume Down**, tap **Power**, keep holding Volume
Down until the boot menu appears. Choose your USB stick (usually listed as
"EFI USB Device").

**On a PC:** power on and immediately tap the boot-menu key — commonly `F12`,
`F11`, `F8` or `Esc`, depending on the manufacturer. Choose the USB stick.

If the USB doesn't appear, go into the BIOS/UEFI settings and:
- Turn **Secure Boot** off
- Set storage mode to **AHCI**, not RAID/Intel RST

After a minute or two you'll land on a desktop with a few icons. You're in the
recovery environment. **Nothing has been changed on your machine yet.**

---

## Step 4 — Open the terminal

Double-click **Konsole** on the desktop, or press `Ctrl + Alt + T`.

A window opens with a line of text ending in `$`. That's the prompt — it's
waiting for you to type. Everything below gets typed here, one line at a time,
pressing `Enter` after each.

> 💡 In a terminal, **nothing appears when you type a password**. No dots, no
> stars. That's normal — just type it and press Enter.

---

## Step 5 — Find out which disk to install to

**This is the step that matters.** Type:

```bash
lsblk
```

You'll get something like:

```
NAME        SIZE TYPE MOUNTPOINTS
sda       953.9G disk
├─sda1        1G part
└─sda2      952G part
nvme0n1   476.9G disk
├─nvme0n1p1 512M part
└─nvme0n1p2 476G part
sdb        28.7G disk /run/media/deck
└─sdb1     28.7G part
```

How to read it:

- Lines with **`disk`** in the TYPE column are whole drives — those are what you
  choose from. Lines starting with `├─` or `└─` are partitions *inside* a drive;
  **never pass those to the script.**
- Match by **SIZE**. A 953.9G `sda` is a 1 TB drive; `nvme0n1` at 476.9G is a
  512 GB one.
- The one showing a **MOUNTPOINT like `/run/media/...`** is almost certainly your
  USB installer stick (`sdb` above). **Don't pick that one** — you're running
  from it.

So in the example above, to install to the 1 TB SATA drive you'd use `/dev/sda`
— the name from the NAME column with `/dev/` in front.

✅ Correct: `/dev/sda`, `/dev/nvme0n1`, `/dev/sdb`
❌ Wrong: `/dev/sda1`, `/dev/nvme0n1p2` — those are partitions, not disks

Still unsure which is which? Unplug the drive you're *not* installing to, run
`lsblk` again, and see which line disappeared.

---

## Step 6 — (Recommended) Protect your internal drive

If you're installing to an **external** drive, make the internal one
unwriteable for the rest of this session, so a typo can't destroy it:

```bash
sudo chmod 000 /dev/nvme0n1
```

This is temporary and undone by a reboot.

---

## Step 7 — Download and run the installer

Three commands, one at a time:

```bash
git clone https://github.com/louij2/steamos_custom_install.git
```
```bash
cd steamos_custom_install
```
```bash
sudo ./repair_device.sh all
```

> The word `all` on the end is **required**. Without it the script just prints
> its help text and stops.

---

## Step 8 — What you'll see, prompt by prompt

Here's the whole conversation. Lines you type are marked 👉.

```
Enter target disk (e.g., /dev/sda): 
```
👉 Type the disk name from Step 5, e.g. `/dev/sda`, and press Enter.

```
Target disk: /dev/sda
Will use partitions like: /dev/sda1, /dev/sda2, ...
Are you SURE you want to use this disk? (type YES to continue): 
```
👉 Type `YES` — **capital letters, all three**. Lowercase `yes` will abort.

**Last chance to back out.** Check that the disk on screen is the one you meant.

Next you'll either get a pop-up window titled *Reimage Steam Deck* — click
**Proceed** — or, if the pop-up can't be displayed, the same question in the
terminal:

```
== Reimage Steam Deck ==
This action will reimage the Steam Deck.
This will permanently destroy all data on your Steam Deck and reinstall SteamOS.

This cannot be undone.

Choose Proceed only if you wish to clear and reimage this device.

Proceed? (type YES to continue): 
```
👉 Type `YES` again.

Both are normal — which one you get depends on whether the graphical session is
reachable. Then it runs, printing progress as it goes:

```
:: Write known partition table
:: Creating var partitions
:: Creating home partition...
:: Remove the reserved blocks on the home partition...
:: Staging a BIOS update for next boot if necessary
:: Updating controller firmware if necessary
:: Creating boot partitions
:: Freezing rootfs
:: Imaging OS partition A
5368709120 bytes (5.4 GB, 5.0 GiB) copied, 94 s, 57.1 MB/s
:: Imaging OS partition B
:: Finalizing boot configurations
:: Finalizing install part A
:: Finalizing install part B
:: Finalizing EFI system partition
```

**The two "Imaging OS partition" steps are the slow part** — several minutes each,
and longer over USB 2.0. The byte counter should keep climbing; as long as it's
moving, it hasn't frozen. This is a good moment to leave it alone.

Finally you'll be asked whether to reboot. Say yes, and **remove the USB stick**
as the machine restarts.

---

## Step 9 — First boot

SteamOS starts its setup wizard: language, timezone, Wi-Fi, Steam login. From
here it's the normal out-of-the-box experience.

If it hangs on "applying update" during first run, see the note about the
nightly recovery image at the bottom of the [readme](../readme.md).

---

## 🆘 If something goes wrong

**The script stops and prints a line like this:**
```
!! Failed at line 273 (exit 127): sfdisk "$DISK"
!! Imaging error occured, see above and restart process.
```
That's the script telling you exactly where it broke. Copy that line into a
[new issue](https://github.com/louij2/steamos_custom_install/issues) — it's the
single most useful thing you can include.

**Nothing happens after you type YES** — you're on an old copy of the script.
Run `cd steamos_custom_install && git pull` and try again. (Fixed in
[#6](https://github.com/louij2/steamos_custom_install/issues/6).)

**"does not exist" or "is not a block device"** — you passed a partition or made
a typo. Re-read Step 5; you want `/dev/sda`, not `/dev/sda1`.

**"Please run as root"** — you left off `sudo`.

**The pop-up dialog never appears** — expected under `sudo`; the script asks in
the terminal instead. Force that behaviour with `NOZENITY=1 sudo -E ./repair_device.sh all`.

**It's been sitting on "Imaging OS partition A" for ages** — normal if the byte
counter is still rising. Over USB 2.0 this can take 20+ minutes.

---

## 📖 Terminal terms, briefly

| Term | Meaning |
|---|---|
| `sudo` | "run this as administrator" |
| `/dev/sda` | How Linux names a whole disk |
| `/dev/sda1` | Partition 1 *inside* that disk |
| `lsblk` | "list block devices" — shows your disks |
| `git clone` | Downloads this project |
| `cd` | "change directory" — moves into a folder |
| Root | The administrator account |

---

*Something here unclear or wrong? Please
[open an issue](https://github.com/louij2/steamos_custom_install/issues) — a
confusing step is a bug in this guide.*
