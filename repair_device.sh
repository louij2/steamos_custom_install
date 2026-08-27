#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
#
# Compatibility shim.
#
# The installer moved to bin/steamos-install (see readme.md). This wrapper stays
# because the published instructions, and a good few forks and bookmarks, all
# say `sudo ./repair_device.sh <target>`. It forwards every argument unchanged.
#
# The pristine copy of Valve's own repair_device.sh - the thing this project is
# a fork of - is vendored at upstream/repair_device.sh. Do not confuse the two.

set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/bin/steamos-install" "$@"
