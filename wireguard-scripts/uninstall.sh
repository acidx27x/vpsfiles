#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wireguard-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
WG_IF="${WG_IF:-${WG_IF_DEFAULT}}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/uninstall.sh
. "${REPO_ROOT}/core/uninstall.sh"

main() {
  vps_require_root "sudo bash ${0}"
  WG_IF="$(vps_read_file_or_default "${SCRIPT_DIR}/server-interface.txt" "${WG_IF}")"
  [[ "${WG_IF}" =~ ^[A-Za-z0-9_.-]+$ ]] || vps_die "saved WireGuard interface is invalid"

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
