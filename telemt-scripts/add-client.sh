#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLIENTS_DIR="${SCRIPT_DIR}/clients"
MAX_UNIQUE_IPS_DEFAULT="2"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=telemt-scripts/telemt.sh
. "${SCRIPT_DIR}/telemt.sh"

generate_secret() {
  openssl rand -hex 16 | tr -d '\r\n'
}

main() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: add-client.sh <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local clients_dir="${CLIENTS_DIR:-${TELEMT_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local secret=""
  local max_unique_ips="${TELEMT_CLIENT_MAX_UNIQUE_IPS:-${MAX_UNIQUE_IPS_DEFAULT}}"

  vps_require_root "sudo ./add-client.sh ..."
  vps_validate_client_name "${client_name}"

  vps_require_commands curl jq openssl systemctl

  config_file="$(vps_read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(vps_read_file_or_default telemt-service.txt "telemt")"
  client_dir="${clients_dir}/${client_name}"

  [[ -f "${config_file}" ]] || vps_die "Telemt config is missing: ${config_file}"
  [[ ! -e "${client_dir}" ]] || vps_die "client already exists: ${client_name}"
  if telemt_key_exists "${config_file}" "access.users" "${client_name}"; then
    vps_die "client already exists in Telemt config: ${client_name}"
  fi

  vps_prompt max_unique_ips "Max simultaneous unique IPs for this client" "${max_unique_ips}"
  vps_validate_positive_int "max unique IPs" "${max_unique_ips}"

  secret="$(generate_secret)"
  [[ -n "${secret}" ]] || vps_die "could not generate Telemt secret"

  vps_info "Adding Telemt client: ${client_name}"
  telemt_upsert_key "${config_file}" "access.users" "${client_name}" "\"${secret}\""
  telemt_upsert_key "${config_file}" "access.user_max_unique_ips" "${client_name}" "${max_unique_ips}"
  vps_systemctl_restart "${service}"
  telemt_write_client_artifacts "${client_name}" "${secret}" "${max_unique_ips}"
  vps_info "Created Telemt links: ${client_dir}/telemt-${client_name}-links.txt"
}

main "$@"
