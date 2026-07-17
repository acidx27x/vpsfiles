#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VPS_MAINTENANCE_LOCK_FILE="${VPS_MAINTENANCE_LOCK_FILE:-/run/lock/vpsfiles-maintenance.lock}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"

vps_system_update_require_root() {
  vps_require_root "sudo ./update.sh"
}

vps_system_update_acquire_lock() {
  install -d -m 755 "$(dirname "${VPS_MAINTENANCE_LOCK_FILE}")"
  exec {VPS_SYSTEM_UPDATE_LOCK_FD}>"${VPS_MAINTENANCE_LOCK_FILE}"
  flock -n "${VPS_SYSTEM_UPDATE_LOCK_FD}" \
    || vps_die "another maintenance or update process is active"
}

vps_system_update_main() {
  local held_packages=""

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_system_update_require_root
  vps_require_supported_apt_os
  vps_require_commands apt-get apt-mark flock install

  printf '%s\n' \
    'This will refresh APT metadata and safely upgrade installed packages.' \
    'New dependencies may be installed, but packages will not be removed and the VPS will not reboot.'
  if ! vps_confirm "Continue with system update?"; then
    printf 'Aborted before making changes.\n'
    return 1
  fi

  vps_system_update_acquire_lock
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs
  apt-get clean

  held_packages="$(apt-mark showhold)"
  if [[ -n "${held_packages}" ]]; then
    printf '\nHeld packages:\n%s\n' "${held_packages}"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    printf '\nA reboot is required to finish applying updates. Reboot manually when convenient.\n'
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      printf 'Packages requesting the reboot:\n'
      cat /var/run/reboot-required.pkgs
    fi
  fi
  printf '\nSystem update complete.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  vps_system_update_main "$@"
fi
