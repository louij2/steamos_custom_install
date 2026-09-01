#!/usr/bin/env bats
# Tests for the bin/steamos-install command line and its guard rails.

load helper

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$REPO/bin/steamos-install"
  SHIM="$REPO/repair_device.sh"
  require_modern_bash
}

@test "--help exits 0 and documents every target" {
  run "$BASH44" "$BIN" --help
  [ "$status" -eq 0 ]
  for t in all system home chroot sanitize; do
    [[ "$output" == *"$t"* ]]
  done
}

@test "no target prints usage and exits non-zero" {
  run "$BASH44" "$BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "an unknown target is refused by name" {
  run "$BASH44" "$BIN" banana
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target: banana"* ]]
}

@test "two targets are refused rather than silently picking one" {
  run "$BASH44" "$BIN" all system
  [ "$status" -ne 0 ]
  [[ "$output" == *"More than one target"* ]]
}

@test "an unknown option is refused" {
  run "$BASH44" "$BIN" --definitely-not-an-option all
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "the target is validated before any disk is touched" {
  # A bad target must fail even when the disk is nonsense: order matters, since
  # the point is not to prompt about a destructive op that will never run.
  run "$BASH44" "$BIN" --disk /dev/definitely-not-here banana
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target"* ]]
  [[ "$output" != *"does not exist"* ]]
}

@test "a bad disk reports the real reason, not a trap artefact" {
  # Regression: the EXIT trap used to trip errexit and replace this message
  # with a meaningless failure from the handler itself.
  run "$BASH44" "$BIN" --dry-run --yes --disk /dev/definitely-not-here all
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" != *"[[ -n \$func ]]"* ]]
}

@test "--disk=VALUE form is accepted" {
  run "$BASH44" "$BIN" --disk=/dev/definitely-not-here --yes --dry-run all
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "the repair_device.sh shim forwards to the new entrypoint" {
  run "$BASH44" "$SHIM" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install or repair SteamOS"* ]]
}

@test "dry-run refuses to run as non-root without complaining about root" {
  # --dry-run is explicitly allowed unprivileged so the path can be tested.
  run "$BASH44" "$BIN" --dry-run --yes --disk /etc/hosts all
  [[ "$output" != *"Please run as root"* ]]
}

@test "the error trap reports the real command, not the literal \$@" {
  # Regression for issue #10: a failure inside cmd() used to be reported as
  # 'line 137 (exit 1): "$@"', which located the wrapper rather than the step.
  run "$BASH44" -c '
    set -euEo pipefail
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/log.sh"
    err() {
      local rc=$?
      eerr "Last command run: ${LAST_CMD:-none}"
      stacktrace 1
      exit "$rc"
    }
    trap err ERR
    boom() { cmd false; }
    boom
  '
  [ "$status" -ne 0 ]
  # bash 4.4+ ${*@Q} renders this as 'false' (shell-quoted); older bash would
  # print it bare. Accept either rather than pinning to one bash's quoting.
  [[ "$output" == *"Last command run: "*"false"* ]]
  [[ "$output" == *"at boom()"* ]]
  [[ "$output" == *"at cmd()"* ]]
  [[ "$output" != *'"$@"'* ]]
}

@test "the entrypoint puts the admin directories back on PATH" {
  # sudo's secure_path can omit /usr/sbin, which is where sfdisk and mkfs live.
  # That is the most likely reading of the exit 127 in issue #9.
  # Read the lines out first: once PATH is clobbered, grep is unreachable too.
  run "$BASH44" -c 'lines="$(grep -E "^(PATH=|export PATH)" "$1")"; PATH=/nonexistent-only; eval "$lines"; echo "$PATH"' _ "$BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/sbin"* ]]
  [[ "$output" == *"/sbin"* ]]
}

@test "a failing sfdisk is attributed to sfdisk, not to the table writer" {
  # Regression: `partition_table | sfdisk` meant a dying sfdisk sent SIGPIPE to
  # the writer, and the ERR trap reported the writer instead - hiding the cause.
  require_modern_bash
  run "$BASH44" -c '
    set -euEo pipefail
    export LIBDIR="'"$REPO"'/lib"
    source "$LIBDIR/log.sh"
    err() { local rc=$?; eerr "cmd=${LAST_CMD:-none} rc=$rc"; exit "$rc"; }
    trap err ERR
    writer() { printf "label: gpt\n"; }
    t="$(mktemp)"; writer > "$t"
    cmd false < "$t"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"cmd="*"false"* ]]
  [[ "$output" != *"writer"* ]]
}
