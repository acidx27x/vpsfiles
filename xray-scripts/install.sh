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

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/install_common.sh
. "${REPO_ROOT}/lib/install_common.sh"

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
    qrencode \
    ufw
}

install_xray() {
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null 2>&1 || die "xray is missing after installation"
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

install_xray_config() {
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

render_server_config() {
  local tmp_file=""

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

  xray run -test -config "${tmp_file}" >/dev/null
  install -d -m 755 "$(dirname "${XRAY_CONFIG}")"
  install_xray_config "${tmp_file}" "${XRAY_CONFIG}" "${XRAY_SERVICE}"
  rm -f "${tmp_file}"
}

prepare_script_state() {
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

  chmod 600 "${SCRIPT_DIR}/reality-private-key.txt" "${SCRIPT_DIR}/reality-public-key.txt"
  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  vps_ufw_allow "${XRAY_PORT}" "tcp"
  vps_enable_ufw_if_needed "Skipped enabling UFW. The Xray TCP port was still added to UFW rules."
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

  [[ -n "${XRAY_ENDPOINT}" ]] || die "public endpoint cannot be empty"
  [[ -n "${XRAY_TARGET}" ]] || die "REALITY target cannot be empty"
  [[ -n "${XRAY_SERVER_NAME}" ]] || die "REALITY serverName cannot be empty"
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
  echo "Clients:           none"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone"
  echo "  sudo ./add-client.sh --ipv6-endpoint phone"
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

  echo
  echo "This will install packages, install or update Xray with the official XTLS installer,"
  echo "back up existing config if present, write ${XRAY_CONFIG}, enable BBR sysctl tuning,"
  echo "configure UFW, and start ${XRAY_SERVICE}."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  install_xray
  generate_reality_keys
  XRAY_SERVER_SHORT_ID="$(generate_short_id)"
  render_server_config
  prepare_script_state
  enable_bbr_tuning
  setup_firewall
  start_xray
  print_summary
}

main "$@"
