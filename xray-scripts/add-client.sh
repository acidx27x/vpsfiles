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
  local endpoint_source="ipv4"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ipv6-endpoint)
        endpoint_source="ipv6"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'usage: add-client.sh [--ipv6-endpoint] <client_name>\n'
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    printf 'usage: add-client.sh [--ipv6-endpoint] <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local endpoint=""
  local port=""
  local server_name=""
  local public_key=""
  local clients_dir="${CLIENTS_DIR:-${XRAY_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local client_uuid=""
  local short_id=""
  local attempts=0

  vps_require_root "sudo ./add-client.sh ..."
  vps_validate_client_name "${client_name}"

  vps_require_commands jq xray openssl
  config_file="$(vps_read_file_or_default xray-config-path.txt "/usr/local/etc/xray/config.json")"
  service="$(vps_read_file_or_default xray-service.txt "xray")"
  case "${endpoint_source}" in
    ipv6)
      [[ -f server-endpoint6.txt ]] || vps_die "server-endpoint6.txt is missing; run install.sh again or create it with the public IPv6 endpoint"
      endpoint="$(cat server-endpoint6.txt)"
      [[ -n "${endpoint}" ]] || vps_die "server-endpoint6.txt is empty"
      ;;
    *)
      endpoint="$(vps_read_file_or_default server-endpoint.txt "$(hostname -f)")"
      ;;
  esac
  port="$(vps_read_file_or_default server-port.txt "443")"
  server_name="$(vps_read_file_or_default reality-server-name.txt "www.firefox.com")"
  [[ -f reality-public-key.txt ]] || vps_die "reality-public-key.txt is missing; run install.sh first"
  public_key="$(cat reality-public-key.txt)"

  [[ -f "${config_file}" ]] || vps_die "server config is missing: ${config_file}"
  [[ -n "${endpoint}" ]] || vps_die "server endpoint is empty"
  [[ -n "${public_key}" ]] || vps_die "REALITY public key is empty"
  xray_require_inbound_tag "${config_file}"

  client_dir="${clients_dir}/${client_name}"
  [[ ! -e "${client_dir}" ]] || vps_die "client already exists: ${client_name}"

  client_uuid="$(xray_generate_uuid)"
  while xray_uuid_exists "${config_file}" "${client_uuid}"; do
    client_uuid="$(xray_generate_uuid)"
    attempts=$((attempts + 1))
    (( attempts < 10 )) || vps_die "could not generate a unique UUID"
  done

  attempts=0
  short_id="$(xray_generate_short_id)"
  while xray_short_id_exists "${config_file}" "${short_id}"; do
    short_id="$(xray_generate_short_id)"
    attempts=$((attempts + 1))
    (( attempts < 10 )) || vps_die "could not generate a unique shortId"
  done

  vps_info "Adding Xray VLESS client: ${client_name}"
  xray_add_client_to_config "${config_file}" "${client_name}" "${client_uuid}" "${short_id}" "${service}"
  xray_write_client_artifacts "${client_name}" "${client_uuid}" "${short_id}" "${endpoint}" "${port}" "${server_name}" "${public_key}"
  vps_info "Created VLESS URI: ${client_dir}/vless-${client_name}.txt"
}

main "$@"
