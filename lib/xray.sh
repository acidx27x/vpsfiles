#!/usr/bin/env bash

[[ -n "${VPS_XRAY_SH:-}" ]] && return 0
VPS_XRAY_SH=1

XRAY_INBOUND_TAG_DEFAULT="vless-reality-vision-443"
XRAY_CLIENTS_DIR_DEFAULT="${SCRIPT_DIR}/clients"
XRAY_CLIENT_TEMPLATE_DEFAULT="${SCRIPT_DIR}/config-client.example.json"

xray_inbound_tag() {
  printf '%s\n' "${INBOUND_TAG:-${XRAY_INBOUND_TAG_DEFAULT}}"
}

xray_require_inbound_tag() {
  local config_file="$1"
  local tag=""

  tag="$(xray_inbound_tag)"
  jq -e --arg tag "${tag}" 'any(.inbounds[]?; .tag == $tag)' "${config_file}" >/dev/null || vps_die "inbound tag is missing from ${config_file}: ${tag}"
}

xray_generate_uuid() {
  xray uuid | tr -d '\r\n'
}

xray_generate_short_id() {
  openssl rand -hex 8
}

xray_short_id_exists() {
  local config_file="$1"
  local short_id="$2"

  jq -e --arg sid "${short_id}" '[.inbounds[].streamSettings.realitySettings.shortIds[]?] | index($sid) != null' "${config_file}" >/dev/null
}

xray_uuid_exists() {
  local config_file="$1"
  local uuid="$2"

  jq -e --arg uuid "${uuid}" '[.inbounds[].settings.clients[]?.id] | index($uuid) != null' "${config_file}" >/dev/null
}

xray_service_user() {
  local service="$1"
  local user=""

  user="$(systemctl cat "${service}" 2>/dev/null | awk -F= '
    $1 ~ /^[[:space:]]*User[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      user = $2
    }
    END { print user }
  ')"
  printf '%s\n' "${user:-root}"
}

xray_install_config() {
  local source_file="$1"
  local dest_file="$2"
  local service="$3"
  local service_user=""
  local service_group=""

  service_user="$(xray_service_user "${service}")"
  if id "${service_user}" >/dev/null 2>&1; then
    service_group="$(id -gn "${service_user}")"
    install -o "${service_user}" -g "${service_group}" -m 600 "${source_file}" "${dest_file}"
  else
    install -m 600 "${source_file}" "${dest_file}"
  fi
}

xray_add_client_to_config() {
  local config_file="$1"
  local client_name="$2"
  local client_uuid="$3"
  local short_id="$4"
  local service="$5"
  local tag=""
  local tmp_file=""

  tag="$(xray_inbound_tag)"
  tmp_file="$(mktemp --suffix=.json)"
  jq \
    --arg tag "${tag}" \
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
  xray_install_config "${tmp_file}" "${config_file}" "${service}"
  rm -f "${tmp_file}"
  systemctl restart "${service}"
}

xray_remove_client_from_config() {
  local config_file="$1"
  local client_uuid="$2"
  local short_id="$3"
  local service="$4"
  local tag=""
  local tmp_file=""

  tag="$(xray_inbound_tag)"
  tmp_file="$(mktemp --suffix=.json)"
  jq \
    --arg tag "${tag}" \
    --arg uuid "${client_uuid}" \
    --arg sid "${short_id}" \
    '.inbounds |= map(
      if .tag == $tag then
        .settings.clients = [.settings.clients[]? | select(.id != $uuid)]
        | .streamSettings.realitySettings.shortIds = [.streamSettings.realitySettings.shortIds[]? | select(. != $sid)]
      else
        .
      end
    )' \
    "${config_file}" > "${tmp_file}"

  xray run -test -config "${tmp_file}" >/dev/null
  xray_install_config "${tmp_file}" "${config_file}" "${service}"
  rm -f "${tmp_file}"
  systemctl restart "${service}"
}

xray_write_client_artifacts() {
  local client_name="$1"
  local client_uuid="$2"
  local short_id="$3"
  local endpoint="$4"
  local port="$5"
  local server_name="$6"
  local public_key="$7"
  local clients_dir="${CLIENTS_DIR:-${XRAY_CLIENTS_DIR_DEFAULT}}"
  local client_template="${CLIENT_TEMPLATE:-${XRAY_CLIENT_TEMPLATE_DEFAULT}}"
  local client_dir=""
  local uri_host=""
  local config_address=""
  local uri=""
  local tmp_file=""

  client_dir="${clients_dir}/${client_name}"
  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${client_uuid}" > "${client_dir}/${client_name}.uuid"
  printf '%s\n' "${short_id}" > "${client_dir}/${client_name}.short-id"

  uri_host="$(vps_format_uri_host "${endpoint}")"
  config_address="$(vps_format_config_address "${endpoint}")"
  uri="vless://${client_uuid}@${uri_host}:${port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=$(vps_url_encode "${server_name}")&fp=firefox&pbk=$(vps_url_encode "${public_key}")&sid=${short_id}&spx=%2F#$(vps_url_encode "${client_name}")"
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
    "${client_template}" > "${tmp_file}"
  install -m 600 "${tmp_file}" "${client_dir}/xray-client-${client_name}.json"
  rm -f "${tmp_file}"

  chmod 600 "${client_dir}/${client_name}.uuid" "${client_dir}/${client_name}.short-id" "${client_dir}/vless-${client_name}.txt"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${client_dir}/vless-${client_name}.txt" > "${client_dir}/vless-${client_name}-qrcode.txt"
    chmod 600 "${client_dir}/vless-${client_name}-qrcode.txt"
  fi
}

xray_add_client_main() {
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
  [[ -f "${CLIENT_TEMPLATE:-${XRAY_CLIENT_TEMPLATE_DEFAULT}}" ]] || vps_die "config-client.example.json is missing"

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
  server_name="$(vps_read_file_or_default reality-server-name.txt "www.microsoft.com")"
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
  vps_info "Created Xray client config: ${client_dir}/xray-client-${client_name}.json"
}

xray_remove_client_main() {
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
  xray_remove_client_from_config "${config_file}" "${client_uuid}" "${short_id}" "${service}"
  vps_safe_remove_client_dir "${client_dir}" "${clients_dir}"
  vps_info "Removed client files for: ${client_name}"
}
