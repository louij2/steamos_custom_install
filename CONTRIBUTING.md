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
tests/                  bats
```

## Before you open a PR

```bash
shellcheck -x bin/steamos-install lib/*.sh tools/*.sh repair_device.sh
bats tests/
sudo ./bin/steamos-install --dry-run --yes --disk /dev/sdX all   # eyeball it
```

CI runs all of that, plus a dry run against a loopback device.

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
