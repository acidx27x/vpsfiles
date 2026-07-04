#!/usr/bin/env bash

[[ -n "${VPS_UNINSTALL_SH:-}" ]] && return 0
VPS_UNINSTALL_SH=1

vps_uninstall_print_plan() {
  local title="$1"
  shift
  local line=""

  printf 'This will remove %s data created by this script bundle:\n\n' "${title}"
  for line in "$@"; do
    printf '%s\n' "${line}"
  done
}

vps_uninstall_finish_sysctl() {
  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi
}
