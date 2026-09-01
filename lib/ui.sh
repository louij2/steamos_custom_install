#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Confirmation prompts. Uses zenity when a desktop session is genuinely
# reachable and falls back to the terminal otherwise.

[[ -n ${__LIB_UI_SH:-} ]] && return 0
__LIB_UI_SH=1

# shellcheck source=lib/log.sh
source "${LIBDIR:?LIBDIR must be set}/log.sh"

# Can we actually put a GUI dialog on screen? Running under sudo strips
# XAUTHORITY / WAYLAND_DISPLAY / XDG_RUNTIME_DIR, so zenity is frequently
# installed but unable to reach the display. Probing once here means we fall
# back cleanly instead of dying mid-run.
can_use_zenity() {
  [[ -z ${NOZENITY:-} ]] || return 1
  command -v zenity >/dev/null 2>&1 || return 1
  [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]] || return 1
  zenity --version >/dev/null 2>&1 || return 1
}

# Give the user a choice between Proceed, or Cancel (which exits).
#   $1 Title
#   $2 Text
prompt_step() {
  local title="$1" msg="$2"

  if [[ -n ${NOPROMPT:-} ]]; then
    echo -e "$msg"
    return 0
  fi

  if can_use_zenity; then
    if zenity --title "$title" --question --ok-label "Proceed" \
              --cancel-label "Cancel" --no-wrap --text "$msg"; then
      return 0
    fi
    die "Aborted by user"
  fi

  # Terminal fallback. The explicit `|| true` on read matters: without it, EOF
  # on stdin trips errexit and aborts with no explanation.
  local reply=""
  echo
  echo "== $title =="
  echo -e "$msg"
  echo
  read -rp "Proceed? (type YES to continue): " reply || true
  [[ $reply == "YES" ]] || die "Aborted by user"
}

prompt_reboot() {
  prompt_step "Action Complete" \
    "${1}\n\nChoose Proceed to reboot now, or Cancel to stay in the repair image."
  if [[ -n ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}
