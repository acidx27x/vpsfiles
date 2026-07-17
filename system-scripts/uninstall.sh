#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VPS_JOURNALD_CONFIG="${VPS_JOURNALD_CONFIG:-/etc/systemd/journald.conf.d/60-vpsfiles-limits.conf}"
VPS_COREDUMP_CONFIG="${VPS_COREDUMP_CONFIG:-/etc/systemd/coredump.conf.d/60-vpsfiles-limits.conf}"
VPS_ZRAM_CONFIG="${VPS_ZRAM_CONFIG:-/etc/systemd/zram-generator.conf.d/60-vpsfiles.conf}"
VPS_MAINTENANCE_BIN="${VPS_MAINTENANCE_BIN:-/usr/local/sbin/vpsfiles-maintenance}"
VPS_MAINTENANCE_SERVICE="${VPS_MAINTENANCE_SERVICE:-/etc/systemd/system/vpsfiles-maintenance.service}"
VPS_MAINTENANCE_TIMER="${VPS_MAINTENANCE_TIMER:-/etc/systemd/system/vpsfiles-maintenance.timer}"
VPS_SYSTEM_STATE_DIR="${VPS_SYSTEM_STATE_DIR:-/var/lib/vpsfiles-system}"
VPS_MAINTENANCE_LOCK_FILE="${VPS_MAINTENANCE_LOCK_FILE:-/run/lock/vpsfiles-maintenance.lock}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/uninstall.sh
. "${REPO_ROOT}/core/uninstall.sh"
# shellcheck source=system-scripts/system.sh
. "${SCRIPT_DIR}/system.sh"

vps_system_uninstall_validate() {
  local path=""

  for path in \
    "${VPS_JOURNALD_CONFIG}" \
    "${VPS_COREDUMP_CONFIG}" \
    "${VPS_ZRAM_CONFIG}" \
    "${VPS_MAINTENANCE_BIN}" \
    "${VPS_MAINTENANCE_SERVICE}" \
    "${VPS_MAINTENANCE_TIMER}"; do
    [[ "${path}" == /* && "${path}" != "/" ]] || vps_die "managed path is unsafe: ${path}"
    vps_system_require_managed_or_absent "${path}"
  done
  vps_system_validate_state_dir "${VPS_SYSTEM_STATE_DIR}"
  [[ "${VPS_MAINTENANCE_LOCK_FILE}" == /* && "${VPS_MAINTENANCE_LOCK_FILE}" != "/" ]] \
    || vps_die "maintenance lock path is unsafe: ${VPS_MAINTENANCE_LOCK_FILE}"
}

vps_system_uninstall_acquire_lock() {
  install -d -m 755 "$(dirname "${VPS_MAINTENANCE_LOCK_FILE}")"
  exec {VPS_SYSTEM_UNINSTALL_LOCK_FD}>"${VPS_MAINTENANCE_LOCK_FILE}"
  flock -n "${VPS_SYSTEM_UNINSTALL_LOCK_FD}" \
    || vps_die "another maintenance or update process is active"
}

vps_system_restore_logrotate() {
  local was_enabled="$1"
  local was_active="$2"

  if [[ "${was_enabled}" == "1" ]]; then
    systemctl enable logrotate.timer >/dev/null
  else
    systemctl disable logrotate.timer >/dev/null
  fi
  if [[ "${was_active}" == "1" ]]; then
    systemctl start logrotate.timer
  else
    systemctl stop logrotate.timer
  fi
}

vps_system_uninstall_main() {
  local has_state=0
  local logrotate_was_active=""
  local logrotate_was_enabled=""
  local remove_zram_package=0
  local zram_active=0
  local zram_package_installed_by_bundle=""

  [[ $# -eq 0 ]] || vps_die "usage: uninstall.sh"
  vps_require_root "sudo ./uninstall.sh"
  vps_require_supported_apt_os
  vps_require_systemd
  vps_require_commands apt-get dpkg-query flock grep install stat swapon systemctl
  vps_system_uninstall_validate

  if [[ -d "${VPS_SYSTEM_STATE_DIR}" ]]; then
    has_state=1
    logrotate_was_enabled="$(vps_system_read_binary_state "${VPS_SYSTEM_STATE_DIR}/logrotate-was-enabled")"
    logrotate_was_active="$(vps_system_read_binary_state "${VPS_SYSTEM_STATE_DIR}/logrotate-was-active")"
    zram_package_installed_by_bundle="$(vps_system_read_binary_state "${VPS_SYSTEM_STATE_DIR}/zram-package-installed-by-bundle")"
    if [[ "${zram_package_installed_by_bundle}" == "1" ]] \
      && vps_system_package_is_installed systemd-zram-generator; then
      remove_zram_package=1
    fi
  fi
  if swapon --noheadings --show=NAME | grep -qxF /dev/zram0; then
    zram_active=1
  fi

  vps_uninstall_print_plan "system maintenance" \
    "  Journal limits:       ${VPS_JOURNALD_CONFIG}" \
    "  Coredump limits:      ${VPS_COREDUMP_CONFIG}" \
    "  Zram limits:          ${VPS_ZRAM_CONFIG}" \
    "  Maintenance command:  ${VPS_MAINTENANCE_BIN}" \
    "  Maintenance units:    ${VPS_MAINTENANCE_SERVICE}, ${VPS_MAINTENANCE_TIMER}" \
    "  Installer state:      ${VPS_SYSTEM_STATE_DIR}" \
    "  Zram package removal: $([[ "${remove_zram_package}" == "1" ]] && printf yes || printf no)"
  if [[ "${has_state}" == "1" ]]; then
    printf 'The previous logrotate.timer enabled and active states will be restored.\n'
  else
    printf 'No installer baseline state was found; logrotate.timer and shared packages will be left unchanged.\n'
  fi
  if [[ "${zram_active}" == "1" ]]; then
    printf 'Active zram swap will not be forced off; reboot after uninstall to remove it safely.\n'
  fi
  printf 'Previously deleted logs, caches, and temporary files cannot be restored.\n\n'
  if ! vps_confirm "Continue with uninstall?"; then
    printf 'Aborted before making changes.\n'
    return 1
  fi

  vps_system_uninstall_acquire_lock
  systemctl disable --now vpsfiles-maintenance.timer >/dev/null 2>&1 || true
  vps_safe_remove_file_path "${VPS_MAINTENANCE_TIMER}"
  vps_safe_remove_file_path "${VPS_MAINTENANCE_SERVICE}"
  vps_safe_remove_file_path "${VPS_MAINTENANCE_BIN}"
  vps_safe_remove_file_path "${VPS_JOURNALD_CONFIG}"
  vps_safe_remove_file_path "${VPS_COREDUMP_CONFIG}"
  vps_safe_remove_file_path "${VPS_ZRAM_CONFIG}"
  systemctl daemon-reload
  systemctl restart systemd-journald

  if [[ "${has_state}" == "1" ]]; then
    vps_system_restore_logrotate "${logrotate_was_enabled}" "${logrotate_was_active}"
  fi
  if [[ "${remove_zram_package}" == "1" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y systemd-zram-generator
    systemctl daemon-reload
  fi
  if [[ "${has_state}" == "1" ]]; then
    vps_safe_remove_path "${VPS_SYSTEM_STATE_DIR}"
  fi

  printf '\nSystem maintenance uninstall complete.\n'
  if [[ "${zram_active}" == "1" ]]; then
    printf 'Reboot the VPS when convenient so the active zram device is released without forcing swapoff.\n'
  fi
  printf 'Shared packages kmod, logrotate, and util-linux were retained.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  vps_system_uninstall_main "$@"
fi
