#!/usr/bin/env bash
set -euo pipefail

TELEMT_CONFIG_DEFAULT="/etc/telemt/telemt.toml"
TELEMT_SERVICE_DEFAULT="telemt"
TELEMT_BIN_DEFAULT="/bin/telemt"
TELEMT_WORK_DIR="/opt/telemt"
TELEMT_DATA_DIR="/var/lib/telemt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"

main() {
  local config_file=""
  local service=""
  local bin_path=""
  local service_file=""
  local override_dir=""

  vps_require_root "sudo bash ${0}"

  config_file="$(vps_read_file_or_default "${SCRIPT_DIR}/telemt-config-path.txt" "${TELEMT_CONFIG_DEFAULT}")"
  service="$(vps_read_file_or_default "${SCRIPT_DIR}/telemt-service.txt" "${TELEMT_SERVICE_DEFAULT}")"
  bin_path="$(vps_read_file_or_default "${SCRIPT_DIR}/telemt-bin-path.txt" "${TELEMT_BIN_DEFAULT}")"
  [[ "${config_file}" == /* ]] || vps_die "saved Telemt config path is unsafe: ${config_file}"
  [[ "${bin_path}" == /* ]] || vps_die "saved Telemt binary path is unsafe: ${bin_path}"
  [[ "${service}" =~ ^[A-Za-z0-9_.@-]+$ ]] || vps_die "saved Telemt service name is invalid"
  service_file="/etc/systemd/system/${service}.service"
  override_dir="/etc/systemd/system/${service}.service.d"

  echo "This will remove Telemt data created by this script bundle:"
  echo
  echo "  Systemd service:   ${service}"
  echo "  Server config:     ${config_file}"
  echo "  Binary:            ${bin_path}"
  echo "  Work directory:    ${TELEMT_WORK_DIR}"
  echo "  Data directory:    ${TELEMT_DATA_DIR}"
  echo "  Client files:      ${CLIENTS_DIR} contents except .gitkeep"
  echo "  Install backups:   ${BACKUP_ROOT}"
  echo "  Script state:      public-host.txt, server-port.txt, tls-domain.txt,"
  echo "                     telemt-config-path.txt, telemt-service.txt,"
  echo "                     telemt-bin-path.txt"
  echo
  echo "It will also try to remove the UFW allow rule for the saved Telemt TCP port."
  echo "It will not uninstall apt packages or remove the telemt system user."
  echo
  if ! vps_confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  vps_systemctl_stop_disable "${service}"
  vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" "tcp"

  vps_safe_remove_file_path "${service_file}"
  vps_safe_remove_path "${override_dir}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  vps_safe_remove_file_path "${config_file}"
  vps_remove_empty_dir "$(dirname "${config_file}")"
  vps_safe_remove_path "${TELEMT_WORK_DIR}"
  vps_safe_remove_path "${TELEMT_DATA_DIR}"
  vps_safe_remove_file_path "${bin_path}"
  vps_clean_clients_dir "${CLIENTS_DIR}" "${SCRIPT_DIR}/clients"
  vps_safe_remove_path "${BACKUP_ROOT}"

  for state_file in public-host.txt server-port.txt tls-domain.txt telemt-config-path.txt telemt-service.txt telemt-bin-path.txt; do
    vps_safe_remove_file_path "${SCRIPT_DIR}/${state_file}"
  done

  echo "Uninstall complete."
}

main "$@"
