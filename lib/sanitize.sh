#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# NVMe sanitize / secure-format support.

[[ -n ${__LIB_SANITIZE_SH:-} ]] && return 0
__LIB_SANITIZE_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"

# Return sanitize state, echoing the current percentage when in progress.
#   0 : ready to sanitize
#   1 : sanitize in progress
#   2 : drive does not support sanitize
get_sanitize_progress() {
  local status progress
  status=$(nvme sanitize-log "$DISK" | grep "(SSTAT)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  [[ $(( status % 8 )) -eq 2 ]] || return 0

  progress=$(nvme sanitize-log "$DISK" | grep "(SPROG)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  echo "sanitize progress: $(( (progress * 100) / 65535 ))%"
  return 1
}

# Call nvme sanitize blockwise and wait for completion.
sanitize_all() {
  local sres=0
  get_sanitize_progress || sres=$?

  case $sres in
    0)
      ewarn "This action irrevocably clears *all* user data from $DISK"
      einfo "Pausing five seconds in case you didn't mean to do this..."
      sleep 5
      estat "Sanitizing $DISK"
      cmd nvme sanitize -a 2 "$DISK"
      estat "Sanitize action started."
      ;;
    1)
      einfo "An NVMe sanitize action is already in progress."
      ;;
    2)
      ewarn "$DISK does not support sanitize; falling back to secure format."
      cmd nvme format "$DISK" -n 1 -s 1 -r
      return 0
      ;;
    *)
      die "Unexpected result from nvme sanitize-log (rc=$sres)"
      ;;
  esac

  while ! get_sanitize_progress; do
    sleep 5
  done

  estat "Sanitize done."
}
