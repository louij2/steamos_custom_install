# Tracking Valve's `repair_device.sh`

This project is a fork. Valve keeps changing the original, and the whole point
of the automation in `.github/workflows/upstream-sync.yml` is that **no upstream
change reaches users without a human reading the diff first.**

## Where Valve's script actually lives

There is no tidy source to poll. Checked, and ruled out:

| Source | Result |
|---|---|
| `jupiter-main` package repo | No package ships `repair_device.sh` |
| `holo-main` package repo | `steamos-customizations-git` ships the helper tools it *calls* (`steamos-chroot`, `steamos-bootconf`, `steamos-partsets`) but not the script |
| `gitlab.steamos.cloud` | Returns `302` — no anonymous access |
| Recovery image | **The only authoritative copy** |

So the sync job downloads a recovery image (~3.3 GB), loop-mounts it, and
extracts the script. That cost is why it runs **monthly and on demand**, never
on push.

`tools/extract-upstream.sh` *searches* the image rather than assuming a path —
Valve has moved the file before. If it cannot find it the job fails loudly
rather than silently producing an empty diff.

## How the approval gate works

```
schedule / manual dispatch
        │
        ▼
  download newest recovery image
        │
        ▼
  extract repair_device.sh  ──►  upstream/repair_device.sh
        │
        ▼
  sha256 differs from vendored copy?
        │
   no ──┴── yes
   │         │
  done       ▼
        open a PULL REQUEST  ◄── the approval gate
                │
                ▼
        a human reads the diff and decides, per hunk:
        port it / consciously skip it
```

The PR touches **only** `upstream/`. It never edits `bin/` or `lib/`, because
deciding whether a Valve change should be adopted is a judgement call, not a
merge. Merging the PR untouched means: *"Valve changed something, and we have
deliberately chosen not to follow it."*

## Our divergences from Valve

This is the checklist to read a Valve diff against. If a hunk touches one of
these areas, it needs thought rather than a straight port.

| # | Valve's behaviour | Ours | Why |
|---|---|---|---|
| 1 | Hardcodes `/dev/nvme0n1` | `--disk`, or prompts, and validates | The entire reason this fork exists — external SSDs and USB drives |
| 2 | Hardcodes `nvme0n1p<N>` partition names | Computes the separator from the device name | `sda1` vs `nvme0n1p1`. Now uses the real kernel rule (name ends in a digit), not a substring match on `nvme`/`mmcblk` |
| 3 | Requires `zenity` and a desktop session | Falls back to terminal prompts | Under `sudo`, `XAUTHORITY`/`WAYLAND_DISPLAY` are stripped, so zenity is present but cannot reach the display |
| 4 | `sleep infinity` on error | Reports the failing line and exits | Valve runs under an OOBE image with no shell to return to; we are launched from a terminal |
| 5 | `sleep infinity` in `verifypart` | `die` with an actionable message | Same reasoning |
| 6 | Runs `jupiter-biosupdate` | Skipped unless `FORCEBIOS=1` | Flashing Steam Deck firmware onto non-Deck hardware is actively harmful, and that is most of our users |
| 7 | Runs `jupiter-controller-update` | Skipped unless `FORCECONTROLLER=1` | Same |
| 8 | Prompts, then validates the target | Validates the target first | Never ask someone to confirm a destructive operation that is going to fail on a typo anyway |
| 9 | No dry run | `--dry-run` prints every destructive command | Makes the whole path testable in CI without a disk |
| 10 | One 469-line script | `bin/` + `lib/` modules | Reviewable, and unit-testable with bats |
| 11 | `set -eu` | `set -euEo pipefail` | `-E` propagates the ERR trap into functions; without it a failure inside a function aborted with **no output at all** |

## Running it by hand

```bash
# newest build
sudo ./tools/extract-upstream.sh

# a specific build
sudo ./tools/extract-upstream.sh --build 20260826.1000

# an image you already downloaded
sudo ./tools/extract-upstream.sh --image ~/Downloads/steamdeck-recovery.img.zst

# keep the mount to poke around if the search fails
sudo ./tools/extract-upstream.sh --keep
```

Or trigger the workflow from the Actions tab — **Upstream sync** → *Run
workflow*, optionally naming a build.
