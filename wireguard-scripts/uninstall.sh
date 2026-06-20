#!/usr/bin/env bash
set -euo pipefail

WG_IF_DEFAULT="wg0"
WG_DIR="/etc/wireguard"
SYSCTL_FILE="/etc/sysctl.d/99-wireguard.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
WG_IF="${WG_IF:-${WG_IF_DEFAULT}}"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/uninstall_common.sh
. "${REPO_ROOT}/lib/uninstall_common.sh"

main() {
  vps_require_root "sudo bash ${0}"

  vps_uninstall_print_plan "WireGuard" \
    "  Interface service: wg-quick@${WG_IF}" \
    "  Server config:     ${WG_DIR}/${WG_IF}.conf" \
    "  Server keys:       ${WG_DIR}/server_private_key, ${WG_DIR}/server_public_key" \
    "  Sysctl file:       ${SYSCTL_FILE}" \
    "  Client files:      ${CLIENTS_DIR} contents except .gitkeep" \
    "  Install backups:   ${BACKUP_ROOT}" \
    "  Script state:      last-ip.txt, last-ip6.txt, server-endpoint.txt," \
    "                     server-endpoint6.txt, server-port.txt, server-interface.txt," \
    "                     server-net.txt, server-net6.txt" \
    "" \
    "It will also try to remove the UFW allow rule for the saved WireGuard UDP port." \
    "It will not uninstall apt packages."
  echo
  if ! vps_confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  vps_uninstall_stop_quick_service "wg-quick@${WG_IF}" "wg-quick" "${WG_IF}"
  vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" "udp"

  vps_safe_remove_path "${WG_DIR}/${WG_IF}.conf"
  vps_safe_remove_path "${WG_DIR}/server_private_key"
  vps_safe_remove_path "${WG_DIR}/server_public_key"
  vps_safe_remove_path "${SYSCTL_FILE}"
  vps_clean_clients_dir "${CLIENTS_DIR}" "${SCRIPT_DIR}/clients"
  vps_safe_remove_path "${BACKUP_ROOT}"

  for state_file in last-ip.txt last-ip6.txt server-endpoint.txt server-endpoint6.txt server-port.txt server-interface.txt server-net.txt server-net6.txt; do
    vps_safe_remove_path "${SCRIPT_DIR}/${state_file}"
  done

  vps_uninstall_finish_sysctl
  echo "Uninstall complete."
}

main "$@"
