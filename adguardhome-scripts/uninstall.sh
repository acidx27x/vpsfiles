#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADGUARD_HOME_DIR="/opt/AdGuardHome"
ADGUARD_HOME_BIN="${ADGUARD_HOME_DIR}/AdGuardHome"
ADGUARD_HOME_CONFIG="${ADGUARD_HOME_DIR}/AdGuardHome.yaml"
ADGUARD_HOME_DATA="${ADGUARD_HOME_DIR}/data"
ADGUARD_HOME_BACKUP="${ADGUARD_HOME_DIR}/backup"
ADGUARD_HOME_SERVICE="AdGuardHome"
# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=adguardhome-scripts/adguardhome.sh
. "${SCRIPT_DIR}/adguardhome.sh"

main() {
  local service_exists=0

  [[ $# -eq 0 ]] || vps_die "usage: uninstall.sh"
  vps_require_root "sudo ./uninstall.sh"
  vps_require_systemd
  [[ "${ADGUARD_HOME_DIR}" == "/opt/AdGuardHome" ]] || vps_die "unsafe AdGuard Home installation directory"
  if systemctl cat "${ADGUARD_HOME_SERVICE}" >/dev/null 2>&1; then
    service_exists=1
  fi
  if [[ ! -e "${ADGUARD_HOME_BIN}" && "${service_exists}" -eq 0 ]]; then
    printf 'AdGuard Home service and binary are already removed.\n'
    printf 'Retained configuration/data, if present, remains under %s.\n' "${ADGUARD_HOME_DIR}"
    exit 0
  fi
  [[ -x "${ADGUARD_HOME_BIN}" ]] || vps_die "AdGuard Home service exists but its managed binary is missing"

  printf 'This will remove the AdGuard Home service and binary:\n\n'
  printf '  Systemd service: %s\n' "${ADGUARD_HOME_SERVICE}"
  printf '  Binary:          %s\n\n' "${ADGUARD_HOME_BIN}"
  printf 'The following application data will be retained for reinstall:\n\n'
  printf '  Configuration:   %s\n' "${ADGUARD_HOME_CONFIG}"
  printf '  Query/work data: %s\n' "${ADGUARD_HOME_DATA}"
  printf '  Update backups:  %s\n\n' "${ADGUARD_HOME_BACKUP}"
  printf 'Retained data may contain DNS query history and other private information.\n'
  printf 'Apt packages, UFW, the host resolver, and other script bundles will not be changed.\n\n'
  if ! vps_confirm "Continue with uninstall?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  if [[ "${service_exists}" -eq 1 ]]; then
    (cd "${ADGUARD_HOME_DIR}" && "${ADGUARD_HOME_BIN}" -s stop) >/dev/null 2>&1 || true
    (cd "${ADGUARD_HOME_DIR}" && "${ADGUARD_HOME_BIN}" -s uninstall) \
      || vps_die "AdGuard Home service could not be unregistered; the binary was retained"
  fi
  systemctl daemon-reload 2>/dev/null || true
  if systemctl cat "${ADGUARD_HOME_SERVICE}" >/dev/null 2>&1; then
    vps_die "AdGuard Home service is still registered; the binary was retained"
  fi
  vps_safe_remove_file_path "${ADGUARD_HOME_BIN}"

  printf 'AdGuard Home uninstall complete.\n'
  printf 'Retained configuration/data remains under %s and will be reused by install.sh.\n' "${ADGUARD_HOME_DIR}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
