#!/usr/bin/env python3
"""Refresh the catalogue of Valve SteamOS recovery images.

Scrapes Valve's /recovery/ index and merges the result into data/images.yaml
without touching the hand-written notes, then regenerates docs/images.md.

IMPORTANT: the source is /recovery/, NOT /steamdeck/. The /steamdeck/ tree
holds OS images that get written to the internal drive - they are not bootable
repair media and do not contain repair_device.sh (verified by extraction).
Users of this project need the /recovery/ artefacts, which come in three
generations: steamdeck-oobe-repair-* (current), steamdeck-repair-*, and the
original steamdeck-recovery-N series.

Standard library only - CI needs no pip install.

Usage:
    tools/refresh-images.py                # refresh + regenerate docs
    tools/refresh-images.py --check        # exit 1 if anything would change
    tools/refresh-images.py --limit 5      # only look at the newest N builds
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

INDEX = "https://steamdeck-images.steamos.cloud/recovery/"
ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "images.yaml"
DOCS = ROOT / "docs" / "images.md"
UA = "steamos_custom_install-image-refresh/1.0 (+https://github.com/louij2/steamos_custom_install)"
TIMEOUT = 30

# The index is an nginx autoindex table: filename, size, date.
ROW_RE = re.compile(
    r'href="(?P<file>steamdeck-(?:oobe-repair|repair|recovery)-[0-9A-Za-z.-]+\.img\.(?:zip|bz2|zst))"'
    r'.*?<td[^>]*>\s*(?P<size>[\d.]+\s*[KMGT]iB)\s*</td>'
    r'.*?<td[^>]*>\s*(?P<date>[0-9]{4}-[A-Za-z]{3}-[0-9]{2}[^<]*?)\s*</td>',
    re.S,
)
NAME_RE = re.compile(
    r'^steamdeck-(?P<gen>oobe-repair|repair|recovery)-'
    r'(?P<build>[0-9]{8}\.[0-9]+|[0-9]+)'
    r'(?:-(?P<version>[0-9][0-9.]*))?\.img\.(?P<ext>zip|bz2|zst)$'
)
# Prefer .zip: same content and size as .bz2, but unzip is far more widely
# available - notably it is what Rufus and Etcher accept directly.
EXT_PREFERENCE = {"zip": 0, "zst": 1, "bz2": 2}
GEN_ORDER = {"oobe-repair": 0, "repair": 1, "recovery": 2}


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def head(url: str) -> int | None:
    """Content-Length for a build artefact, or None if the server won't say."""
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            v = r.headers.get("Content-Length")
            return int(v) if v else None
    except (urllib.error.URLError, ValueError):
        return None


def list_recovery_images() -> list[dict]:
    """Every recovery artefact Valve currently publishes, newest first."""
    html = fetch(INDEX)
    seen: dict[str, dict] = {}

    for m in ROW_RE.finditer(html):
        fname = m.group("file")
        nm = NAME_RE.match(fname)
        if not nm:
            continue
        gen = nm.group("gen")
        build = nm.group("build")
        ext = nm.group("ext")

        entry = {
            "build": build,
            "generation": gen,
            "file": fname,
            "url": INDEX + fname,
            "size_human": m.group("size").replace("\u00a0", " ").strip(),
            "published": m.group("date").strip(),
        }
        if nm.group("version"):
            entry["version"] = nm.group("version")

        # One row per build+generation; keep the most usable extension.
        key = f"{gen}-{build}"
        if key not in seen or EXT_PREFERENCE[ext] < EXT_PREFERENCE[
            NAME_RE.match(seen[key]["file"]).group("ext")
        ]:
            entry["label"] = _label(entry)
            seen[key] = entry

    if not seen:
        raise SystemExit(
            "!! No recovery images found - has the index format changed?\n"
            f"   Check {INDEX} by hand."
        )

    def sort_key(e: dict):
        b = e["build"]
        numeric = [int(x) for x in b.split(".")] if "." in b else [int(b)]
        return (GEN_ORDER[e["generation"]], [-n for n in numeric])

    return sorted(seen.values(), key=sort_key)


def _label(e: dict) -> str:
    pretty = {"oobe-repair": "OOBE repair", "repair": "Repair", "recovery": "Recovery"}
    gen = pretty[e["generation"]]
    ver = f" {e['version']}" if e.get("version") else ""
    return f"{gen} {e['build']}{ver}"


# --- minimal YAML I/O -------------------------------------------------------
# The file is a fixed, flat shape that we own, so a tiny reader/writer beats a
# PyYAML dependency in CI. If the schema ever grows, swap this for PyYAML.

def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {"pinned": [], "tracked": []}
    data: dict = {"pinned": [], "tracked": []}
    section, cur = None, None
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if re.match(r"^(pinned|tracked):", raw):
            section = raw.split(":")[0]
            continue
        if section is None:
            continue
        if raw.lstrip().startswith("- "):
            cur = {}
            data[section].append(cur)
            raw = "  " + raw.lstrip()[2:]
        if cur is None:
            continue
        m = re.match(r"^\s+([a-z_]+):\s*(.*)$", raw)
        if m:
            k, v = m.group(1), m.group(2).strip()
            if v.startswith('"') and v.endswith('"') and len(v) > 1:
                v = v[1:-1]
            cur[k] = int(v) if re.fullmatch(r"-?\d+", v) else v
    return data


def dump_yaml(data: dict, path: Path) -> str:
    out = [
        "# Catalogue of Valve SteamOS recovery images.",
        "#",
        "# `pinned`  - hand-curated entries. Edit these freely; the refresh tool",
        "#             never rewrites them. This is where end-user notes live.",
        "# `tracked` - regenerated by tools/refresh-images.py. Do not hand-edit;",
        "#             your changes will be overwritten on the next refresh.",
        "",
        "pinned:",
    ]
    def emit(e: dict) -> None:
        keys = [k for k in ("build", "generation", "version", "file", "url",
                            "size_bytes", "size_human", "published", "variant",
                            "branch", "release", "arch", "label", "note") if k in e]
        first = True
        for k in keys:
            v = e[k]
            v = v if isinstance(v, int) else f'"{v}"'
            out.append(f"{'  - ' if first else '    '}{k}: {v}")
            first = False

    for e in data.get("pinned", []):
        emit(e)
    if not data.get("pinned"):
        out.append("  []")
    out += ["", "tracked:"]
    for e in data.get("tracked", []):
        emit(e)
    if not data.get("tracked"):
        out.append("  []")
    return "\n".join(out) + "\n"


def render_docs(data: dict) -> str:
    def row(e: dict) -> str:
        name = e.get("label") or e.get("version") or e.get("build", "?")
        size = e.get("size_human", "-")
        note = e.get("note", "")
        gen = e.get("generation", e.get("branch", "-"))
        return (f"| [{name}]({e['url']}) | `{e.get('build','?')}` | {e.get('version','-')} "
                f"| {gen} | {size} | {e.get('published','-')} | {note} |")

    lines = [
        "# SteamOS recovery images",
        "",
        "<!-- GENERATED by tools/refresh-images.py from data/images.yaml. Do not edit by hand. -->",
        "",
        "Every image below is hosted by Valve at",
        "`steamdeck-images.steamos.cloud/recovery/` - the bootable repair media.",
        "(The `/steamdeck/` tree on the same host holds OS images that are written",
        "to the internal drive; those are *not* what you boot, and do not carry the",
        "installer script.)",
        "",
        "",
        "Download one, write it to a USB stick with [Balena Etcher](https://www.balena.io/etcher/)",
        "or [Rufus](https://rufus.ie/en/), boot it, then follow the",
        "[step-by-step guide](step-by-step-guide.md).",
        "",
        "> Prefer the `.zip` files - Etcher and Rufus read them directly. The `.bz2`",
        "> variants are the same image at the same size, just less convenient.",
        "",
        "## Recommended / known-good",
        "",
        "These are chosen by hand because someone confirmed they work on specific",
        "hardware. Start here.",
        "",
        "| Image | Build | Version | Kind | Size | Published | Notes |",
        "|---|---|---|---|---|---|---|",
    ]
    lines += [row(e) for e in data.get("pinned", [])] or ["| _none yet_ | | | | | | |"]
    lines += [
        "",
        "## Latest builds",
        "",
        "Newest images Valve has published, refreshed automatically. These are not",
        "vetted - if one fails, try a pinned image above and please open an issue",
        "saying which build and what hardware.",
        "",
        "**Which kind?** `oobe-repair` is the current generation and what you want",
        "unless you have a reason otherwise. `repair` is the 2023-2025 line, and",
        "`recovery` is the original 2022 series - both still boot, and an older one",
        "is worth trying if the newest will not install on your hardware.",
        "",
        "| Image | Build | Version | Kind | Size | Published | Notes |",
        "|---|---|---|---|---|---|---|",
    ]
    lines += [row(e) for e in data.get("tracked", [])] or ["| _none_ | | | | | | |"]
    lines += [
        "",
        "---",
        "",
        "**Adding a note:** edit the `pinned` section of",
        "[`data/images.yaml`](../data/images.yaml) and open a PR. Say which machine",
        "you tested on - that is the part other people actually need.",
        "",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=8,
                    help="how many recovery images to track (default: 8)")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the catalogue or docs are out of date")
    args = ap.parse_args()

    data = load_yaml(DATA)
    images = list_recovery_images()
    print(f":: index lists {len(images)} recovery images; tracking newest {args.limit}",
          file=sys.stderr)

    tracked = images[: args.limit]
    for e in tracked:
        print(f"   {e['label']:32} {e['size_human']:>10}  {e['file']}", file=sys.stderr)
    data["tracked"] = tracked

    new_yaml, new_docs = dump_yaml(data, DATA), render_docs(data)
    old_yaml = DATA.read_text() if DATA.exists() else ""
    old_docs = DOCS.read_text() if DOCS.exists() else ""

    if args.check:
        if new_yaml != old_yaml or new_docs != old_docs:
            print("!! catalogue is out of date - run tools/refresh-images.py", file=sys.stderr)
            return 1
        print(":: catalogue up to date", file=sys.stderr)
        return 0

    DATA.parent.mkdir(parents=True, exist_ok=True)
    DOCS.parent.mkdir(parents=True, exist_ok=True)
    DATA.write_text(new_yaml)
    DOCS.write_text(new_docs)
    changed = (new_yaml != old_yaml) or (new_docs != old_docs)
    print(f":: {'updated' if changed else 'no change to'} {DATA.name} and {DOCS.name}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
