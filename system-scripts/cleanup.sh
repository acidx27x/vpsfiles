#!/usr/bin/env bash
set -Eeuo pipefail

# Managed by vpsfiles system-scripts.

VPS_MAINTENANCE_LOCK_FILE="${VPS_MAINTENANCE_LOCK_FILE:-/run/lock/vpsfiles-maintenance.lock}"
VPS_MAINTENANCE_FILESYSTEM="${VPS_MAINTENANCE_FILESYSTEM:-/}"
VPS_APT_CACHE_DIR="${VPS_APT_CACHE_DIR:-/var/cache/apt/archives}"
VPS_COREDUMP_DIR="${VPS_COREDUMP_DIR:-/var/lib/systemd/coredump}"

vps_maintenance_die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

vps_maintenance_require_root() {
  [[ "${EUID}" -eq 0 ]] || vps_maintenance_die "run as root: sudo ./cleanup.sh"
}

vps_maintenance_require_commands() {
  local command_name=""

  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 \
      || vps_maintenance_die "${command_name} is required"
  done
}

vps_maintenance_report_usage() {
  printf 'Filesystem usage:\n'
  df -h -- "${VPS_MAINTENANCE_FILESYSTEM}" || true
  printf '\nJournal usage:\n'
  journalctl --disk-usage || true
  printf '\nDisposable file usage:\n'
  if [[ -d "${VPS_APT_CACHE_DIR}" ]]; then
    du -sh -- "${VPS_APT_CACHE_DIR}" || true
  else
    printf '0\t%s\n' "${VPS_APT_CACHE_DIR}"
  fi
  if [[ -d "${VPS_COREDUMP_DIR}" ]]; then
    du -sh -- "${VPS_COREDUMP_DIR}" || true
  else
    printf '0\t%s\n' "${VPS_COREDUMP_DIR}"
  fi
}

vps_maintenance_print_actions() {
  printf '%s\n' \
    'Maintenance actions:' \
    '  Rotate the systemd journal and discard archived entries older than 7 days.' \
    '  Remove downloaded APT package archives with apt-get clean.' \
    '  Remove temporary files only when systemd-tmpfiles policy says they expired.'
}

vps_maintenance_acquire_lock() {
  local scheduled="$1"

  install -d -m 755 "$(dirname "${VPS_MAINTENANCE_LOCK_FILE}")"
  exec {VPS_MAINTENANCE_LOCK_FD}>"${VPS_MAINTENANCE_LOCK_FILE}"
  if ! flock -n "${VPS_MAINTENANCE_LOCK_FD}"; then
    if [[ "${scheduled}" -eq 1 ]]; then
      printf 'Another maintenance or update process is active; scheduled cleanup skipped.\n'
      return 2
    fi
    vps_maintenance_die "another maintenance or update process is active"
  fi
}

vps_maintenance_run_cleanup() {
  journalctl --rotate
  journalctl --vacuum-time=7d
  apt-get clean
  systemd-tmpfiles --clean
}

vps_maintenance_main() {
  local dry_run=0
  local scheduled=0

  if [[ $# -gt 1 ]]; then
    vps_maintenance_die "usage: cleanup.sh [--dry-run]"
    return 1
  fi
  case "${1:-}" in
    "") ;;
    --dry-run) dry_run=1 ;;
    --scheduled) scheduled=1 ;;
    *)
      vps_maintenance_die "usage: cleanup.sh [--dry-run]"
      return 1
      ;;
  esac

  vps_maintenance_require_root
  if [[ "${dry_run}" -eq 1 ]]; then
    vps_maintenance_require_commands df du journalctl
    vps_maintenance_report_usage
    printf '\n'
    vps_maintenance_print_actions
    printf '\nDry run complete; nothing was changed.\n'
    return 0
  fi

  vps_maintenance_require_commands apt-get df du flock install journalctl systemd-tmpfiles
  if ! vps_maintenance_acquire_lock "${scheduled}"; then
    [[ "${scheduled}" -eq 1 ]] && return 0
    return 1
  fi

  vps_maintenance_report_usage
  printf '\n'
  vps_maintenance_print_actions
  if [[ "${scheduled}" -eq 0 ]]; then
    local answer=""

    read -r -p "Continue with cleanup? [y/N]: " answer
    case "${answer}" in
      y|Y|yes|YES) ;;
      *)
        printf 'Aborted before making changes.\n'
        return 1
        ;;
    esac
  fi

  printf '\nRunning maintenance...\n'
  vps_maintenance_run_cleanup
  printf '\nMaintenance complete.\n\n'
  vps_maintenance_report_usage
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  vps_maintenance_main "$@"
fi
