#!/usr/bin/env bash

[[ -n "${VPS_XRAY_SH:-}" ]] && return 0
VPS_XRAY_SH=1

XRAY_INBOUND_TAG_DEFAULT="vless-reality-vision-443"
XRAY_CLIENTS_DIR_DEFAULT="${SCRIPT_DIR}/clients"
XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

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

xray_run_installer() {
  local action="$1"
  local installer=""

  installer="$(mktemp)"
  if ! curl -fsSL "${XRAY_INSTALLER_URL}" -o "${installer}"; then
    rm -f "${installer}"
    return 1
  fi
  if ! bash "${installer}" "${action}"; then
    rm -f "${installer}"
    return 1
  fi
  rm -f "${installer}"
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
  local client_dir=""
  local uri_host=""
  local uri=""

  client_dir="${clients_dir}/${client_name}"
  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${client_uuid}" > "${client_dir}/${client_name}.uuid"
  printf '%s\n' "${short_id}" > "${client_dir}/${client_name}.short-id"

  uri_host="$(vps_format_uri_host "${endpoint}")"
  uri="vless://${client_uuid}@${uri_host}:${port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=$(vps_url_encode "${server_name}")&fp=firefox&pbk=$(vps_url_encode "${public_key}")&sid=${short_id}&spx=%2F#$(vps_url_encode "${client_name}")"
  printf '%s\n' "${uri}" > "${client_dir}/vless-${client_name}.txt"

  chmod 600 "${client_dir}/${client_name}.uuid" "${client_dir}/${client_name}.short-id" "${client_dir}/vless-${client_name}.txt"
}
