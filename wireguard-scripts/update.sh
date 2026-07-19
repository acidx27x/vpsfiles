#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wireguard-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
cd "${SCRIPT_DIR}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/update.sh
. "${REPO_ROOT}/core/update.sh"

main() {
  local iface=""
  local service=""
  local config_file=""
  local was_active=0

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_require_root "sudo ./update.sh"
  vps_require_systemd
  vps_require_commands wg wg-quick systemctl
  [[ -f server-interface.txt ]] || vps_die "server-interface.txt is missing; run install.sh first"
  iface="$(<server-interface.txt)"
  [[ "${iface}" =~ ^[A-Za-z0-9_.-]+$ ]] || vps_die "saved WireGuard interface is invalid"
  config_file="${WG_DIR}/${iface}.conf"
  [[ -f "${config_file}" ]] || vps_die "WireGuard server config is missing: ${config_file}"
  service="wg-quick@${iface}"
  wg-quick strip "${config_file}" >/dev/null || vps_die "current WireGuard config validation failed; update not started"
  if vps_service_is_active "${service}"; then
    was_active=1
  fi

  printf 'This will upgrade WireGuard packages and dependencies without changing server configuration, keys, clients, endpoints, UFW, or sysctl state.\n'
  printf 'WARNING: APT package and dependency changes cannot be automatically downgraded by this updater.\n'
  printf 'Create a provider snapshot before continuing if full rollback is required.\n'
  printf 'Active service: %s\n' "${service}"
  if ! vps_confirm "Continue with update?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  vps_update_packages wireguard wireguard-tools
  vps_require_commands wg wg-quick
  wg-quick strip "${config_file}" >/dev/null || vps_die "WireGuard config validation failed after package update"
  if [[ "${was_active}" -eq 1 ]]; then
    vps_restart_active_service "${service}" || vps_die "updated WireGuard service did not become active: ${service}"
  else
    printf 'WireGuard service was inactive; it was left stopped.\n'
  fi
  printf 'WireGuard update complete.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
