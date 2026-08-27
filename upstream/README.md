# `upstream/` — Valve's pristine script

This directory holds an **unmodified** copy of Valve's `repair_device.sh`,
extracted from a SteamOS recovery image. It exists purely as a diff baseline so
we can see what Valve changes.

- **Nothing here is executed.** The installer users run is `bin/steamos-install`.
- **Do not edit these files by hand.** They are overwritten by
  `tools/extract-upstream.sh`.
- `VERSION` records the recovery build the copy came from.
- Extracted from `/deck/tools/repair_device.sh` on the **home** partition of a
  `steamdeck-oobe-repair-*` image — read with `debugfs`, because that partition
  uses ext4 `casefold` and will not mount without `CONFIG_UNICODE`.
- CI deliberately does not lint this directory — it is not our code, and
  "fixing" it would defeat the purpose of a clean diff.

Populate it with:

```bash
sudo ./tools/extract-upstream.sh
```

…or run the **Upstream sync** workflow from the Actions tab. See
[`docs/upstream-sync.md`](../docs/upstream-sync.md) for how the approval flow
works and what our deliberate divergences are.
