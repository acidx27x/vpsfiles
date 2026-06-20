#!/usr/bin/env bash
set -euo pipefail

XRAY_CONFIG_DEFAULT="/usr/local/etc/xray/config.json"
XRAY_SERVICE_DEFAULT="xray"
SYSCTL_FILE="/etc/sysctl.d/99-xray-bbr.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/uninstall_common.sh
. "${REPO_ROOT}/lib/uninstall_common.sh"

main() {
  local config_file=""
  local service=""

  vps_require_root "sudo bash ${0}"

  config_file="$(vps_read_file_or_default "${SCRIPT_DIR}/xray-config-path.txt" "${XRAY_CONFIG_DEFAULT}")"
  service="$(vps_read_file_or_default "${SCRIPT_DIR}/xray-service.txt" "${XRAY_SERVICE_DEFAULT}")"

  vps_uninstall_print_plan "Xray" \
    "  Systemd service:   ${service}" \
    "  Server config:     ${config_file}" \
    "  Sysctl file:       ${SYSCTL_FILE}" \
    "  Client files:      ${CLIENTS_DIR} contents except .gitkeep" \
    "  Install backups:   ${BACKUP_ROOT}" \
    "  Script state:      server-endpoint.txt, server-endpoint6.txt," \
    "                     server-port.txt, server-short-id.txt," \
    "                     reality-target.txt, reality-server-name.txt," \
    "                     reality-private-key.txt, reality-public-key.txt," \
    "                     xray-config-path.txt, xray-service.txt" \
    "" \
    "It will also try to remove the UFW allow rule for the saved Xray TCP port." \
    "It will not uninstall Xray packages or binaries."
  echo
  if ! vps_confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  vps_systemctl_stop_disable "${service}"
  vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" "tcp"
  vps_safe_remove_path "${config_file}"
  vps_safe_remove_path "${SYSCTL_FILE}"
  vps_clean_clients_dir "${CLIENTS_DIR}" "${SCRIPT_DIR}/clients"
  vps_safe_remove_path "${BACKUP_ROOT}"

  for state_file in server-endpoint.txt server-endpoint6.txt server-port.txt server-short-id.txt reality-target.txt reality-server-name.txt reality-private-key.txt reality-public-key.txt xray-config-path.txt xray-service.txt; do
    vps_safe_remove_path "${SCRIPT_DIR}/${state_file}"
  done

  vps_uninstall_finish_sysctl
  echo "Uninstall complete."
}

main "$@"
