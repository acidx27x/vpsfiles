#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLIENTS_DIR="${SCRIPT_DIR}/clients"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=telemt-scripts/telemt.sh
. "${SCRIPT_DIR}/telemt.sh"

main() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: remove-client.sh <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local clients_dir="${CLIENTS_DIR:-${TELEMT_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local exists_in_config=0
  local user_count=0

  vps_require_root "sudo ./remove-client.sh ..."
  vps_validate_client_name "${client_name}"

  config_file="$(vps_read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(vps_read_file_or_default telemt-service.txt "telemt")"
  client_dir="${clients_dir}/${client_name}"

  [[ -f "${config_file}" ]] || vps_die "Telemt config is missing: ${config_file}"
  if telemt_key_exists "${config_file}" "access.users" "${client_name}"; then
    exists_in_config=1
  fi
  if [[ "${exists_in_config}" -eq 0 && ! -d "${client_dir}" ]]; then
    vps_die "client does not exist: ${client_name}"
  fi
  user_count="$(telemt_count_keys "${config_file}" "access.users")"
  if [[ "${exists_in_config}" -eq 1 && "${user_count}" -le 1 ]]; then
    vps_die "refusing to remove the last Telemt client; Telemt requires at least one configured user"
  fi

  vps_info "Removing Telemt client: ${client_name}"
  telemt_remove_key "${config_file}" "access.users" "${client_name}"
  telemt_remove_key "${config_file}" "access.user_max_unique_ips" "${client_name}"
  vps_systemctl_restart "${service}"
  vps_safe_remove_client_dir "${client_dir}" "${clients_dir}"
  vps_info "Removed client files for: ${client_name}"
}

main "$@"
