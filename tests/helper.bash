#!/usr/bin/env bash
# Shared test helpers.
#
# The installer needs bash 4.4+ (${var@Q}, ${var,,}) and says so up front. macOS
# ships bash 3.2, so on a dev Mac the tests that actually execute the entrypoint
# have nothing to run under. Find a modern bash if one is installed, and skip
# rather than report a false pass or a false failure. CI runs on bash 5.
modern_bash() {
  local candidate
  for candidate in "${BASH_BIN:-}" bash /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [[ -n $candidate ]] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' 2>/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

require_modern_bash() {
  BASH44="$(modern_bash)" || skip "needs bash 4.4+; found ${BASH_VERSION}"
  export BASH44
}
