#!/usr/bin/env bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# Terminal output helpers. Everything goes to stderr so that stdout stays
# clean for anything that wants to capture a value from these scripts.

[[ -n ${__LIB_LOG_SH:-} ]] && return 0
__LIB_LOG_SH=1

_sh_c_colors=0
if [[ -n ${TERM:-} && -t 2 && ${TERM,,} != dumb ]]; then
  _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
fi

sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && printf '\e[%sm' "${*:-0}"; ); }

estat() { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()  { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn() { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo() { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()  { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }

die() {
  local msg="$*"
  [[ -n $msg ]] || msg="script terminated"
  eerr "$msg"
  exit 1
}

showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
showcmd() { showcmd_unquoted "${@@Q}"; }

# Run a command, echoing it first. Honours DRY_RUN=1, which is what makes the
# destructive paths testable without a disk attached.
cmd() {
  showcmd "$@"
  if [[ -n ${DRY_RUN:-} ]]; then
    echo >&2 "$(sh_c 33 1);;$(sh_c) dry-run: not executed"
    return 0
  fi
  "$@"
}
