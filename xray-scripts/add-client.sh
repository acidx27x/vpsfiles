#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

INBOUND_TAG="vless-reality-vision-443"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
CLIENT_TEMPLATE="${SCRIPT_DIR}/config-client.example.json"

usage() {
  echo "usage: add-client.sh [--ipv6-endpoint] <client_name>"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run as root: sudo ./add-client.sh ..."
  fi
}

read_file_or_default() {
  local file="$1"
  local default="$2"

  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    printf '%s\n' "${default}"
  fi
}

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

generate_uuid() {
  xray uuid | tr -d '\r\n'
}

generate_short_id() {
  openssl rand -hex 8
}

short_id_exists() {
  local config_file="$1"
  local short_id="$2"

  jq -e --arg sid "${short_id}" '[.inbounds[].streamSettings.realitySettings.shortIds[]?] | index($sid) != null' "${config_file}" >/dev/null
}

uuid_exists() {
  local config_file="$1"
  local uuid="$2"

  jq -e --arg uuid "${uuid}" '[.inbounds[].settings.clients[]?.id] | index($uuid) != null' "${config_file}" >/dev/null
}

require_inbound_tag() {
  local config_file="$1"

  jq -e --arg tag "${INBOUND_TAG}" 'any(.inbounds[]?; .tag == $tag)' "${config_file}" >/dev/null || die "inbound tag is missing from ${config_file}: ${INBOUND_TAG}"
}

url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

format_uri_host() {
  local endpoint="$1"

  if [[ "${endpoint}" == \[*\] ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == *:* ]]; then
    printf '[%s]\n' "${endpoint}"
  else
    printf '%s\n' "${endpoint}"
  fi
}

format_config_address() {
  local endpoint="$1"

  if [[ "${endpoint}" == \[*\] ]]; then
    endpoint="${endpoint#[}"
    endpoint="${endpoint%]}"
  fi

  printf '%s\n' "${endpoint}"
}

add_client_to_config() {
  local config_file="$1"
  local client_name="$2"
  local client_uuid="$3"
  local short_id="$4"
  local service="$5"
  local tmp_file=""

  tmp_file="$(mktemp --suffix=.json)"
  jq \
    --arg tag "${INBOUND_TAG}" \
    --arg name "${client_name}" \
    --arg uuid "${client_uuid}" \
    --arg sid "${short_id}" \
    '.inbounds |= map(
      if .tag == $tag then
        .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $name}]
        | .streamSettings.realitySettings.shortIds += [$sid]
      else
        .
      end
    )' \
    "${config_file}" > "${tmp_file}"

  xray run -test -config "${tmp_file}" >/dev/null
  install -m 600 "${tmp_file}" "${config_file}"
  rm -f "${tmp_file}"
  systemctl restart "${service}"
}

write_client_artifacts() {
  local client_name="$1"
  local client_uuid="$2"
  local short_id="$3"
  local endpoint="$4"
  local port="$5"
  local server_name="$6"
  local public_key="$7"
  local client_dir=""
  local uri_host=""
  local config_address=""
  local uri=""
  local tmp_file=""

  client_dir="${CLIENTS_DIR}/${client_name}"
  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${client_uuid}" > "${client_dir}/${client_name}.uuid"
  printf '%s\n' "${short_id}" > "${client_dir}/${client_name}.short-id"

  uri_host="$(format_uri_host "${endpoint}")"
  config_address="$(format_config_address "${endpoint}")"
  uri="vless://${client_uuid}@${uri_host}:${port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=$(url_encode "${server_name}")&fp=firefox&pbk=$(url_encode "${public_key}")&sid=${short_id}&spx=%2F#$(url_encode "${client_name}")"
  printf '%s\n' "${uri}" > "${client_dir}/vless-${client_name}.txt"

  tmp_file="$(mktemp --suffix=.json)"
  jq \
    --arg endpoint "${config_address}" \
    --argjson port "${port}" \
    --arg uuid "${client_uuid}" \
    --arg server_name "${server_name}" \
    --arg public_key "${public_key}" \
    --arg short_id "${short_id}" \
    '.outbounds[0].settings.vnext[0].address = $endpoint
      | .outbounds[0].settings.vnext[0].port = $port
      | .outbounds[0].settings.vnext[0].users[0].id = $uuid
      | .outbounds[0].streamSettings.realitySettings.serverName = $server_name
      | .outbounds[0].streamSettings.realitySettings.password = $public_key
      | .outbounds[0].streamSettings.realitySettings.shortId = $short_id' \
    "${CLIENT_TEMPLATE}" > "${tmp_file}"
  install -m 600 "${tmp_file}" "${client_dir}/xray-client-${client_name}.json"
  rm -f "${tmp_file}"

  chmod 600 "${client_dir}/${client_name}.uuid" "${client_dir}/${client_name}.short-id" "${client_dir}/vless-${client_name}.txt"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${client_dir}/vless-${client_name}.txt" > "${client_dir}/vless-${client_name}-qrcode.txt"
    chmod 600 "${client_dir}/vless-${client_name}-qrcode.txt"
  fi
}

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
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local endpoint=""
  local port=""
  local server_name=""
  local public_key=""
  local client_dir=""
  local client_uuid=""
  local short_id=""
  local attempts=0

  require_root "$@"
  validate_client_name "${client_name}"

  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v xray >/dev/null 2>&1 || die "xray is required; run install.sh first"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  [[ -f "${CLIENT_TEMPLATE}" ]] || die "config-client.example.json is missing"

  config_file="$(read_file_or_default xray-config-path.txt "/usr/local/etc/xray/config.json")"
  service="$(read_file_or_default xray-service.txt "xray")"
  case "${endpoint_source}" in
    ipv6)
      [[ -f server-endpoint6.txt ]] || die "server-endpoint6.txt is missing; run install.sh again or create it with the public IPv6 endpoint"
      endpoint="$(cat server-endpoint6.txt)"
      [[ -n "${endpoint}" ]] || die "server-endpoint6.txt is empty"
      ;;
    *)
      endpoint="$(read_file_or_default server-endpoint.txt "$(hostname -f)")"
      ;;
  esac
  port="$(read_file_or_default server-port.txt "443")"
  server_name="$(read_file_or_default reality-server-name.txt "www.microsoft.com")"
  [[ -f reality-public-key.txt ]] || die "reality-public-key.txt is missing; run install.sh first"
  public_key="$(cat reality-public-key.txt)"

  [[ -f "${config_file}" ]] || die "server config is missing: ${config_file}"
  [[ -n "${endpoint}" ]] || die "server endpoint is empty"
  [[ -n "${public_key}" ]] || die "REALITY public key is empty"
  require_inbound_tag "${config_file}"

  client_dir="${CLIENTS_DIR}/${client_name}"
  [[ ! -e "${client_dir}" ]] || die "client already exists: ${client_name}"

  client_uuid="$(generate_uuid)"
  while uuid_exists "${config_file}" "${client_uuid}"; do
    client_uuid="$(generate_uuid)"
    attempts=$((attempts + 1))
    (( attempts < 10 )) || die "could not generate a unique UUID"
  done

  attempts=0
  short_id="$(generate_short_id)"
  while short_id_exists "${config_file}" "${short_id}"; do
    short_id="$(generate_short_id)"
    attempts=$((attempts + 1))
    (( attempts < 10 )) || die "could not generate a unique shortId"
  done

  info "Adding Xray VLESS client: ${client_name}"
  add_client_to_config "${config_file}" "${client_name}" "${client_uuid}" "${short_id}" "${service}"
  write_client_artifacts "${client_name}" "${client_uuid}" "${short_id}" "${endpoint}" "${port}" "${server_name}" "${public_key}"
  info "Created VLESS URI: ${client_dir}/vless-${client_name}.txt"
  info "Created Xray client config: ${client_dir}/xray-client-${client_name}.json"
}

main "$@"
