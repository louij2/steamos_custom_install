#!/usr/bin/env bats
# Tests for the bin/steamos-install command line and its guard rails.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$REPO/bin/steamos-install"
  SHIM="$REPO/repair_device.sh"
}

@test "--help exits 0 and documents every target" {
  run bash "$BIN" --help
  [ "$status" -eq 0 ]
  for t in all system home chroot sanitize; do
    [[ "$output" == *"$t"* ]]
  done
}

@test "no target prints usage and exits non-zero" {
  run bash "$BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "an unknown target is refused by name" {
  run bash "$BIN" banana
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target: banana"* ]]
}

@test "two targets are refused rather than silently picking one" {
  run bash "$BIN" all system
  [ "$status" -ne 0 ]
  [[ "$output" == *"More than one target"* ]]
}

@test "an unknown option is refused" {
  run bash "$BIN" --definitely-not-an-option all
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "the target is validated before any disk is touched" {
  # A bad target must fail even when the disk is nonsense: order matters, since
  # the point is not to prompt about a destructive op that will never run.
  run bash "$BIN" --disk /dev/definitely-not-here banana
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown target"* ]]
  [[ "$output" != *"does not exist"* ]]
}

@test "a bad disk reports the real reason, not a trap artefact" {
  # Regression: the EXIT trap used to trip errexit and replace this message
  # with a meaningless failure from the handler itself.
  run bash "$BIN" --dry-run --yes --disk /dev/definitely-not-here all
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" != *"[[ -n \$func ]]"* ]]
}

@test "--disk=VALUE form is accepted" {
  run bash "$BIN" --disk=/dev/definitely-not-here --yes --dry-run all
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "the repair_device.sh shim forwards to the new entrypoint" {
  run bash "$SHIM" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install or repair SteamOS"* ]]
}

@test "dry-run refuses to run as non-root without complaining about root" {
  # --dry-run is explicitly allowed unprivileged so the path can be tested.
  run bash "$BIN" --dry-run --yes --disk /etc/hosts all
  [[ "$output" != *"Please run as root"* ]]
}
