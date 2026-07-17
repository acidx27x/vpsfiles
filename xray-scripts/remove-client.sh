#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INBOUND_TAG="vless-reality-vision-443"
CLIENTS_DIR="${SCRIPT_DIR}/clients"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=xray-scripts/xray.sh
. "${SCRIPT_DIR}/xray.sh"

main() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: remove-client.sh <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local clients_dir="${CLIENTS_DIR:-${XRAY_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local uuid_file=""
  local short_id_file=""
  local client_uuid=""
  local short_id=""

  vps_require_root "sudo ./remove-client.sh ..."
  vps_validate_client_name "${client_name}"

  vps_require_commands jq xray

  config_file="$(vps_read_file_or_default xray-config-path.txt "/usr/local/etc/xray/config.json")"
  service="$(vps_read_file_or_default xray-service.txt "xray")"
  client_dir="${clients_dir}/${client_name}"
  uuid_file="${client_dir}/${client_name}.uuid"
  short_id_file="${client_dir}/${client_name}.short-id"

  [[ -d "${client_dir}" ]] || vps_die "client does not exist: ${client_name}"
  [[ -f "${uuid_file}" ]] || vps_die "client UUID is missing: ${uuid_file}"
  [[ -f "${short_id_file}" ]] || vps_die "client shortId is missing: ${short_id_file}"
  [[ -f "${config_file}" ]] || vps_die "server config is missing: ${config_file}"
  xray_require_inbound_tag "${config_file}"

  client_uuid="$(cat "${uuid_file}")"
  short_id="$(cat "${short_id_file}")"
  [[ -n "${client_uuid}" ]] || vps_die "client UUID is empty"
  [[ -n "${short_id}" ]] || vps_die "client shortId is empty"

  vps_info "Removing Xray VLESS client: ${client_name}"
  xray_remove_client_from_config "${config_file}" "${client_name}" "${client_uuid}" "${short_id}" "${service}"
  vps_safe_remove_client_dir "${client_dir}" "${clients_dir}"
  vps_info "Removed client files for: ${client_name}"
}

main "$@"
