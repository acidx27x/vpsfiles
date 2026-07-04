#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=amnezia-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
AWG_IF="${AWG_IF:-${AWG_IF_DEFAULT}}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=wireguard-scripts/wg.sh
. "${REPO_ROOT}/wireguard-scripts/wg.sh"
# shellcheck source=core/uninstall.sh
. "${REPO_ROOT}/core/uninstall.sh"

stop_amneziawg_service() {
  vps_systemctl_stop_disable "awg-quick@${AWG_IF}"
  if command -v awg-quick >/dev/null 2>&1; then
    awg-quick down "${AWG_IF}" 2>/dev/null || true
  fi
}

main() {
  vps_require_root "sudo bash ${0}"
  AWG_IF="$(vps_read_file_or_default "${SCRIPT_DIR}/server-interface.txt" "${AWG_IF}")"
  [[ "${AWG_IF}" =~ ^[A-Za-z0-9_.-]+$ ]] || vps_die "saved AmneziaWG interface is invalid"

  vps_uninstall_print_plan "AmneziaWG" \
    "  Interface service: awg-quick@${AWG_IF}" \
    "  Server config:     ${AWG_DIR}/${AWG_IF}.conf" \
    "  Server keys:       ${AWG_DIR}/server_private_key, ${AWG_DIR}/server_public_key" \
    "  Sysctl file:       ${SYSCTL_FILE}" \
    "  Client files:      ${CLIENTS_DIR} contents except .gitkeep" \
    "  Hosts entries:     generated client entries in /etc/hosts" \
    "  Install backups:   ${BACKUP_ROOT}" \
    "  Script state:      last-ip.txt, last-ip6.txt, server-endpoint.txt," \
    "                     server-endpoint6.txt, server-port.txt, server-interface.txt," \
    "                     server-net.txt, server-net6.txt, obfuscation.env" \
    "" \
    "It will also try to remove the UFW allow rule for the saved AmneziaWG UDP port." \
    "It will not uninstall apt packages or remove normal WireGuard files."
  echo
  if ! vps_confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  stop_amneziawg_service
  vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" "udp"

  vps_safe_remove_file_path "${AWG_DIR}/${AWG_IF}.conf"
  vps_safe_remove_file_path "${AWG_DIR}/server_private_key"
  vps_safe_remove_file_path "${AWG_DIR}/server_public_key"
  vps_safe_remove_file_path "${SYSCTL_FILE}"
  wg_family_remove_generated_hosts_entries
  vps_clean_clients_dir "${CLIENTS_DIR}" "${SCRIPT_DIR}/clients"
  vps_safe_remove_path "${BACKUP_ROOT}"

  for state_file in last-ip.txt last-ip6.txt server-endpoint.txt server-endpoint6.txt server-port.txt server-interface.txt server-net.txt server-net6.txt obfuscation.env; do
    vps_safe_remove_file_path "${SCRIPT_DIR}/${state_file}"
  done

  vps_uninstall_finish_sysctl
  echo "Uninstall complete."
}

main "$@"
