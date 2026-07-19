#!/usr/bin/env bash
set -euo pipefail

# Full Xray VLESS REALITY installer for this script bundle.
# Run from vpsfiles/xray-scripts, then add clients with ./add-client.sh.

XRAY_PORT_DEFAULT="443"
XRAY_TARGET_DEFAULT="www.firefox.com:443"
XRAY_SERVER_NAME_DEFAULT="www.firefox.com"
XRAY_CONFIG_DEFAULT="/usr/local/etc/xray/config.json"
XRAY_SERVICE_DEFAULT="xray"
SYSCTL_FILE="/etc/sysctl.d/99-xray-bbr.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_TEMPLATE="${SCRIPT_DIR}/config-server.example.json"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

XRAY_PORT="${XRAY_PORT:-${XRAY_PORT_DEFAULT}}"
XRAY_ENDPOINT="${XRAY_ENDPOINT:-}"
XRAY_ENDPOINT6="${XRAY_ENDPOINT6:-}"
XRAY_TARGET="${XRAY_TARGET:-${XRAY_TARGET_DEFAULT}}"
XRAY_SERVER_NAME="${XRAY_SERVER_NAME:-${XRAY_SERVER_NAME_DEFAULT}}"
XRAY_CONFIG="${XRAY_CONFIG:-${XRAY_CONFIG_DEFAULT}}"
XRAY_SERVICE="${XRAY_SERVICE:-${XRAY_SERVICE_DEFAULT}}"
XRAY_NEXT_HOP_URI="${XRAY_NEXT_HOP_URI:-}"
XRAY_SS_PORT="${XRAY_SS_PORT:-}"
XRAY_SS_KEY=""
XRAY_PREVIOUS_SS_PORT=""

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=xray-scripts/xray.sh
. "${SCRIPT_DIR}/xray.sh"

require_root() {
  vps_require_root "sudo bash ${0}"
}

die() {
  vps_die "$@"
}

require_files() {
  local missing=0

  for file in \
    "${SERVER_TEMPLATE}" \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/set-client-route.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: required file is missing: ${file}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require_supported_os() {
  vps_require_supported_apt_os
  vps_require_systemd
}

prompt() {
  vps_prompt "$@"
}

confirm() {
  vps_confirm "$@"
}

validate_port() {
  vps_validate_port "$1"
}

detect_public_ip() {
  vps_detect_public_ip
}

detect_public_ip6() {
  vps_detect_public_ip6
}

install_packages() {
  vps_install_packages \
    curl \
    jq \
    openssl \
    ufw
}

install_xray() {
  xray_run_installer install || die "Xray installer failed"
  vps_require_commands xray
}

backup_existing_configs() {
  local timestamp=""
  local backup_dir=""
  local found=0
  local path=""

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"

  for path in \
    "${XRAY_CONFIG}" \
    "${SYSCTL_FILE}" \
    "${SCRIPT_DIR}/server-endpoint.txt" \
    "${SCRIPT_DIR}/server-endpoint6.txt" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-short-id.txt" \
    "${SCRIPT_DIR}/reality-target.txt" \
    "${SCRIPT_DIR}/reality-server-name.txt" \
    "${SCRIPT_DIR}/reality-private-key.txt" \
    "${SCRIPT_DIR}/reality-public-key.txt" \
    "${SCRIPT_DIR}/shadowsocks-port.txt" \
    "${SCRIPT_DIR}/xray-config-path.txt" \
    "${SCRIPT_DIR}/xray-service.txt"; do
    if [[ -e "${path}" ]]; then
      found=1
      break
    fi
  done
  if [[ -d "${CLIENTS_DIR}" && -n "$(find "${CLIENTS_DIR}" -mindepth 1 -maxdepth 1 ! -name .gitkeep -print -quit 2>/dev/null)" ]]; then
    found=1
  fi

  if [[ "${found}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Existing Xray/script config was found."
  echo "Backup destination: ${backup_dir}"
  if ! confirm "Back up existing config before continuing?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  mkdir -p "${backup_dir}/xray-config" "${backup_dir}/script-files"

  if [[ -e "${XRAY_CONFIG}" ]]; then
    cp -a "${XRAY_CONFIG}" "${backup_dir}/xray-config/"
  fi
  if [[ -e "${SYSCTL_FILE}" ]]; then
    cp -a "${SYSCTL_FILE}" "${backup_dir}/script-files/"
  fi
  for path in \
    "${SCRIPT_DIR}/server-endpoint.txt" \
    "${SCRIPT_DIR}/server-endpoint6.txt" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-short-id.txt" \
    "${SCRIPT_DIR}/reality-target.txt" \
    "${SCRIPT_DIR}/reality-server-name.txt" \
    "${SCRIPT_DIR}/reality-private-key.txt" \
    "${SCRIPT_DIR}/reality-public-key.txt" \
    "${SCRIPT_DIR}/shadowsocks-port.txt" \
    "${SCRIPT_DIR}/xray-config-path.txt" \
    "${SCRIPT_DIR}/xray-service.txt"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/script-files/"
    fi
  done
  if [[ -d "${CLIENTS_DIR}" ]]; then
    cp -a "${CLIENTS_DIR}" "${backup_dir}/script-files/"
  fi

  echo "Backup complete: ${backup_dir}"
}

enable_bbr_tuning() {
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.tcp_fastopen=3\n' > "${SYSCTL_FILE}"
  sysctl --system >/dev/null
}

generate_reality_keys() {
  local key_output=""

  key_output="$(xray x25519)"
  XRAY_PRIVATE_KEY="$(printf '%s\n' "${key_output}" | awk -F': *' '/Private key|PrivateKey/ {print $2; exit}')"
  XRAY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | awk -F': *' '/Public key|PublicKey|Password/ {print $2; exit}')"

  [[ -n "${XRAY_PRIVATE_KEY}" ]] || die "could not parse REALITY private key from xray x25519 output"
  [[ -n "${XRAY_PUBLIC_KEY}" ]] || die "could not parse REALITY public key from xray x25519 output"
}

generate_short_id() {
  openssl rand -hex 8
}

read_previous_shadowsocks_port() {
  local state_file="${SCRIPT_DIR}/shadowsocks-port.txt"

  [[ -f "${state_file}" ]] || return 0
  XRAY_PREVIOUS_SS_PORT="$(cat "${state_file}")"
  vps_validate_port "${XRAY_PREVIOUS_SS_PORT}"
  if [[ -f "${CLIENTS_DIR}/ss/shadowsocks-upstream.txt" ]]; then
    xray_require_shadowsocks_artifact_path "${CLIENTS_DIR}"
  fi
}

render_server_config() {
  local tmp_file=""
  local next_hop_file=""
  local shadowsocks_file=""

  tmp_file="$(mktemp --suffix=.json)"
  jq \
    --argjson port "${XRAY_PORT}" \
    --arg target "${XRAY_TARGET}" \
    --arg server_name "${XRAY_SERVER_NAME}" \
    --arg private_key "${XRAY_PRIVATE_KEY}" \
    --arg short_id "${XRAY_SERVER_SHORT_ID}" \
    '.inbounds[0].port = $port
      | .inbounds[0].settings.clients = []
      | .inbounds[0].streamSettings.realitySettings.target = $target
      | .inbounds[0].streamSettings.realitySettings.serverNames = [$server_name]
      | .inbounds[0].streamSettings.realitySettings.privateKey = $private_key
      | .inbounds[0].streamSettings.realitySettings.shortIds = [$short_id]' \
    "${SERVER_TEMPLATE}" > "${tmp_file}"

  if [[ -n "${XRAY_NEXT_HOP_URI}" ]]; then
    next_hop_file="$(mktemp --suffix=.json)"
    xray_render_next_hop_config "${tmp_file}" "${next_hop_file}"
    mv "${next_hop_file}" "${tmp_file}"
  fi

  if [[ -n "${XRAY_SS_PORT}" ]]; then
    shadowsocks_file="$(mktemp --suffix=.json)"
    xray_render_shadowsocks_inbound "${tmp_file}" "${shadowsocks_file}" "${XRAY_SS_PORT}" "${XRAY_SS_KEY}"
    mv "${shadowsocks_file}" "${tmp_file}"
  fi

  xray run -test -config "${tmp_file}" >/dev/null
  install -d -m 755 "$(dirname "${XRAY_CONFIG}")"
  xray_install_config "${tmp_file}" "${XRAY_CONFIG}" "${XRAY_SERVICE}"
  rm -f "${tmp_file}"
}

prepare_script_state() {
  local shadowsocks_artifact="${CLIENTS_DIR}/ss/shadowsocks-upstream.txt"

  mkdir -p "${CLIENTS_DIR}"

  printf '%s\n' "${XRAY_ENDPOINT}" > "${SCRIPT_DIR}/server-endpoint.txt"
  printf '%s\n' "${XRAY_ENDPOINT6}" > "${SCRIPT_DIR}/server-endpoint6.txt"
  printf '%s\n' "${XRAY_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${XRAY_SERVER_SHORT_ID}" > "${SCRIPT_DIR}/server-short-id.txt"
  printf '%s\n' "${XRAY_TARGET}" > "${SCRIPT_DIR}/reality-target.txt"
  printf '%s\n' "${XRAY_SERVER_NAME}" > "${SCRIPT_DIR}/reality-server-name.txt"
  printf '%s\n' "${XRAY_PRIVATE_KEY}" > "${SCRIPT_DIR}/reality-private-key.txt"
  printf '%s\n' "${XRAY_PUBLIC_KEY}" > "${SCRIPT_DIR}/reality-public-key.txt"
  printf '%s\n' "${XRAY_CONFIG}" > "${SCRIPT_DIR}/xray-config-path.txt"
  printf '%s\n' "${XRAY_SERVICE}" > "${SCRIPT_DIR}/xray-service.txt"

  if [[ -n "${XRAY_SS_PORT}" ]]; then
    xray_write_shadowsocks_artifact "${XRAY_ENDPOINT}" "${XRAY_SS_PORT}" "${XRAY_SS_KEY}" >/dev/null
    printf '%s\n' "${XRAY_SS_PORT}" > "${SCRIPT_DIR}/shadowsocks-port.txt"
  else
    if [[ -f "${shadowsocks_artifact}" ]]; then
      xray_require_shadowsocks_artifact_path "${CLIENTS_DIR}"
      vps_safe_remove_client_dir "${CLIENTS_DIR}/ss" "${CLIENTS_DIR}"
    fi
    vps_safe_remove_file_path "${SCRIPT_DIR}/shadowsocks-port.txt"
  fi

  chmod 600 "${SCRIPT_DIR}/reality-private-key.txt" "${SCRIPT_DIR}/reality-public-key.txt"
  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/set-client-route.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  vps_ufw_allow "${XRAY_PORT}" "tcp"
  if [[ -n "${XRAY_PREVIOUS_SS_PORT}" && "${XRAY_PREVIOUS_SS_PORT}" != "${XRAY_SS_PORT}" ]]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw delete allow "${XRAY_PREVIOUS_SS_PORT}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${XRAY_PREVIOUS_SS_PORT}/udp" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${XRAY_SS_PORT}" ]]; then
    vps_ufw_allow "${XRAY_SS_PORT}" "tcp"
    vps_ufw_allow "${XRAY_SS_PORT}" "udp"
  fi
  vps_enable_ufw_if_needed "Skipped enabling UFW. The configured Xray and Shadowsocks rules were still added to UFW."
}

start_xray() {
  vps_systemctl_enable_restart "${XRAY_SERVICE}"
}

collect_settings() {
  local detected_endpoint=""
  local detected_endpoint6=""
  local default_server_name=""

  detected_endpoint="$(detect_public_ip)"
  detected_endpoint6="$(detect_public_ip6)"
  default_server_name="${XRAY_TARGET%%:*}"

  prompt XRAY_PORT "Xray VLESS REALITY TCP port" "${XRAY_PORT}"
  validate_port "${XRAY_PORT}"
  prompt XRAY_ENDPOINT "Public endpoint clients should connect to" "${XRAY_ENDPOINT:-${detected_endpoint:-$(hostname -f)}}"
  prompt XRAY_ENDPOINT6 "Public IPv6 endpoint clients can connect to" "${XRAY_ENDPOINT6:-${detected_endpoint6}}"
  prompt XRAY_TARGET "REALITY target host:port" "${XRAY_TARGET}"
  prompt XRAY_SERVER_NAME "REALITY serverName/SNI" "${XRAY_SERVER_NAME:-${default_server_name}}"
  prompt XRAY_NEXT_HOP_URI "Next-hop VLESS URI (leave empty for direct exit)" "${XRAY_NEXT_HOP_URI}"
  prompt XRAY_SS_PORT "Shadowsocks 2022 port for Telemt upstream (leave empty to disable)" "${XRAY_SS_PORT}"

  [[ -n "${XRAY_ENDPOINT}" ]] || die "public endpoint cannot be empty"
  [[ -n "${XRAY_TARGET}" ]] || die "REALITY target cannot be empty"
  [[ -n "${XRAY_SERVER_NAME}" ]] || die "REALITY serverName cannot be empty"
  if [[ -n "${XRAY_NEXT_HOP_URI}" ]]; then
    xray_parse_next_hop_uri "${XRAY_NEXT_HOP_URI}"
  fi
  if [[ -n "${XRAY_SS_PORT}" ]]; then
    xray_validate_shadowsocks_port "${XRAY_SS_PORT}" "${XRAY_PORT}"
    xray_validate_shadowsocks_endpoint "${XRAY_ENDPOINT}"
    xray_require_shadowsocks_artifact_path "${CLIENTS_DIR}"
  fi
}

print_summary() {
  echo
  echo "============================================================"
  echo "Xray VLESS REALITY installation complete."
  echo "============================================================"
  echo
  echo "Server config:     ${XRAY_CONFIG}"
  echo "Systemd service:   ${XRAY_SERVICE}"
  echo "TCP port:          ${XRAY_PORT}"
  echo "Client endpoint:   ${XRAY_ENDPOINT}"
  echo "IPv6 endpoint:     ${XRAY_ENDPOINT6}"
  echo "REALITY target:    ${XRAY_TARGET}"
  echo "REALITY SNI:       ${XRAY_SERVER_NAME}"
  echo "Server shortId:    ${XRAY_SERVER_SHORT_ID}"
  if [[ -n "${XRAY_NEXT_HOP_URI}" ]]; then
    echo "Next-hop outbound: available (${XRAY_NEXT_HOP_ADDRESS}:${XRAY_NEXT_HOP_PORT})"
    echo "Client routing:    direct by default; next hop by explicit selection"
  else
    echo "Next-hop outbound: not configured"
    echo "Client routing:    direct exit"
  fi
  if [[ -n "${XRAY_SS_PORT}" ]]; then
    echo "Shadowsocks:       $(vps_format_endpoint "${XRAY_ENDPOINT}" "${XRAY_SS_PORT}") (TCP and UDP)"
    echo "SS upstream URI:   ${CLIENTS_DIR}/ss/shadowsocks-upstream.txt"
  else
    echo "Shadowsocks:       not configured"
  fi
  echo "VLESS clients:     none"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone"
  echo "  sudo ./add-client.sh --next-hop tablet"
  echo "  sudo ./add-client.sh --ipv6-endpoint phone"
  echo "  sudo ./set-client-route.sh --next-hop phone"
  echo "  sudo ./set-client-route.sh --direct phone"
  echo "  sudo ./remove-client.sh phone"
  echo "  sudo ./uninstall.sh"
  echo
  echo "Check status with:"
  echo "  sudo systemctl status ${XRAY_SERVICE}"
  echo "  sudo journalctl -u ${XRAY_SERVICE} -n 100 --no-pager"
}

main() {
  require_root
  require_files
  require_supported_os

  echo "Xray VLESS REALITY full installation"
  echo
  collect_settings
  read_previous_shadowsocks_port

  echo
  echo "This will install packages, install or update Xray with the official XTLS installer,"
  echo "back up existing config if present, write ${XRAY_CONFIG}, enable BBR sysctl tuning,"
  echo "configure UFW, optionally create a Shadowsocks 2022 endpoint, and start ${XRAY_SERVICE}."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  install_xray
  generate_reality_keys
  XRAY_SERVER_SHORT_ID="$(generate_short_id)"
  if [[ -n "${XRAY_SS_PORT}" ]]; then
    XRAY_SS_KEY="$(xray_generate_shadowsocks_key)"
    xray_validate_shadowsocks_key "${XRAY_SS_KEY}"
  fi
  render_server_config
  prepare_script_state
  enable_bbr_tuning
  setup_firewall
  start_xray
  print_summary
}

main "$@"
