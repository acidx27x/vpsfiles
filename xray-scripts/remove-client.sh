#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

INBOUND_TAG="vless-reality-vision-443"
CLIENTS_DIR="${SCRIPT_DIR}/clients"

usage() {
  echo "usage: remove-client.sh <client_name>"
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
    die "run as root: sudo ./remove-client.sh ..."
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

require_inbound_tag() {
  local config_file="$1"

  jq -e --arg tag "${INBOUND_TAG}" 'any(.inbounds[]?; .tag == $tag)' "${config_file}" >/dev/null || die "inbound tag is missing from ${config_file}: ${INBOUND_TAG}"
}

remove_client_from_config() {
  local config_file="$1"
  local client_uuid="$2"
  local short_id="$3"
  local service="$4"
  local tmp_file=""

  tmp_file="$(mktemp)"
  jq \
    --arg tag "${INBOUND_TAG}" \
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
  install -m 600 "${tmp_file}" "${config_file}"
  rm -f "${tmp_file}"
  systemctl restart "${service}"
}

remove_client_dir() {
  local client_dir="$1"

  [[ "${client_dir}" == "${CLIENTS_DIR}/"* ]] || die "refusing to remove unexpected path: ${client_dir}"
  [[ -d "${client_dir}" ]] || return 0
  rm -rf "${client_dir}"
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local client_dir=""
  local uuid_file=""
  local short_id_file=""
  local client_uuid=""
  local short_id=""

  require_root "$@"
  validate_client_name "${client_name}"

  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v xray >/dev/null 2>&1 || die "xray is required"

  config_file="$(read_file_or_default xray-config-path.txt "/usr/local/etc/xray/config.json")"
  service="$(read_file_or_default xray-service.txt "xray")"
  client_dir="${CLIENTS_DIR}/${client_name}"
  uuid_file="${client_dir}/${client_name}.uuid"
  short_id_file="${client_dir}/${client_name}.short-id"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${uuid_file}" ]] || die "client UUID is missing: ${uuid_file}"
  [[ -f "${short_id_file}" ]] || die "client shortId is missing: ${short_id_file}"
  [[ -f "${config_file}" ]] || die "server config is missing: ${config_file}"
  require_inbound_tag "${config_file}"

  client_uuid="$(cat "${uuid_file}")"
  short_id="$(cat "${short_id_file}")"
  [[ -n "${client_uuid}" ]] || die "client UUID is empty"
  [[ -n "${short_id}" ]] || die "client shortId is empty"

  info "Removing Xray VLESS client: ${client_name}"
  remove_client_from_config "${config_file}" "${client_uuid}" "${short_id}" "${service}"
  remove_client_dir "${client_dir}"
  info "Removed client files for: ${client_name}"
}

main "$@"
