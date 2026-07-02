#!/usr/bin/env bash

[[ -n "${VPS_UNINSTALL_SH:-}" ]] && return 0
VPS_UNINSTALL_SH=1

vps_uninstall_stop_quick_service() {
  local service="$1"
  local quick_cmd="$2"
  local iface="$3"

  vps_systemctl_stop_disable "${service}"
  if command -v "${quick_cmd}" >/dev/null 2>&1; then
    "${quick_cmd}" down "${iface}" 2>/dev/null || true
  fi
}

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
