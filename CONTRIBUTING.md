# Contributing

## Layout

```
bin/steamos-install     the entrypoint: argument parsing, prompts, flow
lib/log.sh              output helpers, and cmd() which honours DRY_RUN
lib/ui.sh               zenity-or-terminal confirmation prompts
lib/disk.sh             target validation, partition naming, partition table
lib/steps.sh            the actual imaging work
lib/sanitize.sh         NVMe sanitize / secure format
repair_device.sh        compatibility shim -> bin/steamos-install
upstream/               Valve's pristine script. Never executed, never edited
tools/                  upstream extraction + image catalogue refresh
data/images.yaml        image catalogue; `pinned` is hand-written
tests/                  bats; helper.bash finds a bash 4.4+ to run under
```

## The three test tiers

| Tier | Command | Covers | Runs |
|---|---|---|---|
| Unit | `bats tests/` | argument handling, partition naming, preflight logic, error reporting | every push |
| Integration | `sudo bash tests/integration/disk-integration.sh` | a **real** block device: mounted-disk release, partition settling, `mkfs` right after `sfdisk` | every push (Linux + root) |
| End-to-end | `sudo tools/vm-test/run-vm-test.sh` | a VM booted from Valve's real recovery image: `steamos-chroot`, the btrfs rootfs copy, the bootloader | on demand |

The tiers exist because each one reaches something the one above cannot. The
integration tier is where the issue #9 and #10 *mechanics* live — they only
misbehave with real mounts and real udev. The VM tier is the only place the
SteamOS-specific half of the installer runs at all, and it is where two real
bugs were found that every other tier passed. See
[tools/vm-test/README.md](tools/vm-test/README.md).

## Before you open a PR

```bash
shellcheck -x bin/steamos-install lib/*.sh tools/*.sh tools/vm-test/*.sh tests/integration/*.sh repair_device.sh
bats tests/
sudo bash tests/integration/disk-integration.sh                  # Linux only
sudo ./bin/steamos-install --dry-run --yes --disk /dev/sdX all   # eyeball it
```

CI runs all of that, plus a dry run against a loopback device. Run the VM tier
too if you touched `lib/steps.sh` or anything to do with tools, mounts or
partition devices.

## The one rule that matters

**Every destructive command goes through `cmd`.** That is what makes `--dry-run`
honest, and `--dry-run` is what makes this whole thing testable without feeding
a real disk to it. If you add a `mkfs`, `dd`, `sfdisk` or `nvme` call that
bypasses `cmd`, dry run will silently destroy someone's drive.

Two related traps, both of which have bitten this repo already:

- **`set -E` is not optional.** Without it the `ERR` trap is not inherited by
  functions, and a failure inside one aborts with *no output at all*.
- **Anything inside the `EXIT` trap must be errexit-safe.** A bare failing test
  in there re-triggers `ERR` and replaces the real error message with a
  meaningless one from the handler. Use `|| continue`, not `&&`.
- **Preflight, don't discover.** Anything environmental — a binary that must
  exist, a disk that must not be mounted, a device node that must have appeared
  — gets checked before the destructive work, with a message that says what to
  do about it. Both #9 and #10 were environmental failures surfaced as a bare
  exit code halfway through an install. See `require_tools`, `release_disk` and
  `settle_disk` in `lib/disk.sh`.

## Testing on macOS

The installer needs **bash 4.4+** (`${var@Q}`, `${var,,}`) and checks for it at
startup. macOS ships bash 3.2, so `tests/helper.bash` looks for a modern bash
and **skips** the tests that execute the entrypoint if it can't find one.

Take those skips seriously: bash 3.2 does not error on `${*@Q}`, it silently
degrades it to an unquoted expansion. A test written against that output passes
locally and fails on CI. `brew install bash` if you want the full suite.

## Adding a note about an image

This is the most useful contribution, and it needs no code. Edit the `pinned`
section of [`data/images.yaml`](data/images.yaml), then run:

```bash
python3 tools/refresh-images.py
```

…which regenerates `docs/images.md`. Commit both.

**Say which machine you tested on.** "Works" is not useful; "installs cleanly on
a ThinkPad T480, external USB SSD" is what someone else actually needs. The
`tracked` section is regenerated automatically — do not hand-edit it.

## Upstream changes

Do not edit `upstream/` by hand. See [docs/upstream-sync.md](docs/upstream-sync.md).
