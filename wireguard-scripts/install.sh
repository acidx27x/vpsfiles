#!/usr/bin/env bash
set -euo pipefail

# Full WireGuard installer for this script bundle.
# Run from vpsfiles/wireguard-scripts, then add clients with ./add-client.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wireguard-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
SERVER_TEMPLATE="${SCRIPT_DIR}/wg0-server.example.conf"
CLIENT_TEMPLATE="${SCRIPT_DIR}/wg0-client.example.conf"
LAST_IP_FILE="${SCRIPT_DIR}/last-ip.txt"
LAST_IP6_FILE="${SCRIPT_DIR}/last-ip6.txt"
ENDPOINT_FILE="${SCRIPT_DIR}/server-endpoint.txt"
ENDPOINT6_FILE="${SCRIPT_DIR}/server-endpoint6.txt"

WG_IF="${WG_IF:-${WG_IF_DEFAULT}}"
WG_PORT="${WG_PORT:-${WG_PORT_DEFAULT}}"
WG_NET="${WG_NET:-${WG_NET_DEFAULT}}"
WG_NET6="${WG_NET6:-${WG_NET6_DEFAULT}}"
WG_SERVER_IP="${WG_SERVER_IP:-${WG_SERVER_IP_DEFAULT}}"
WG_SERVER_IP6="${WG_SERVER_IP6:-${WG_SERVER_IP6_DEFAULT}}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_ENDPOINT6="${WG_ENDPOINT6:-}"
SERVER_IF="${SERVER_IF:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
WG_PREFIX="24"
WG_PREFIX6="64"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"

require_root() {
  vps_require_root "sudo bash ${0}"
}

require_files() {
  local missing=0

  for file in \
    "${SERVER_TEMPLATE}" \
    "${CLIENT_TEMPLATE}" \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
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
}

prompt() {
  vps_prompt "$@"
}

confirm() {
  vps_confirm "$@"
}

detect_server_if() {
  vps_detect_server_if
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
    iproute2 \
    iptables \
    ufw \
    wireguard \
    wireguard-tools
}

backup_existing_configs() {
  local timestamp=""
  local backup_dir=""
  local found=0
  local path=""

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"

  for path in \
    "${WG_DIR}/${WG_IF}.conf" \
    "${WG_DIR}/server_private_key" \
    "${WG_DIR}/server_public_key" \
    "${LAST_IP_FILE}" \
    "${LAST_IP6_FILE}" \
    "${ENDPOINT_FILE}" \
    "${ENDPOINT6_FILE}" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-interface.txt" \
    "${SCRIPT_DIR}/server-net.txt" \
    "${SCRIPT_DIR}/server-net6.txt"; do
    if [[ -e "${path}" ]]; then
      found=1
      break
    fi
  done
  if [[ -d "${CLIENTS_DIR}" && -n "$(find "${CLIENTS_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    found=1
  fi

  if [[ "${found}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Existing WireGuard/script config was found."
  echo "Backup destination: ${backup_dir}"
  if ! confirm "Back up existing config before continuing?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  mkdir -p "${backup_dir}/etc-wireguard" "${backup_dir}/script-files"

  for path in "${WG_DIR}/${WG_IF}.conf" "${WG_DIR}/server_private_key" "${WG_DIR}/server_public_key"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/etc-wireguard/"
    fi
  done
  for path in \
    "${LAST_IP_FILE}" \
    "${LAST_IP6_FILE}" \
    "${ENDPOINT_FILE}" \
    "${ENDPOINT6_FILE}" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-interface.txt" \
    "${SCRIPT_DIR}/server-net.txt" \
    "${SCRIPT_DIR}/server-net6.txt"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/script-files/"
    fi
  done
  if [[ -d "${CLIENTS_DIR}" ]]; then
    cp -a "${CLIENTS_DIR}" "${backup_dir}/script-files/"
  fi

  echo "Backup complete: ${backup_dir}"
}

stop_existing_wireguard() {
  if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "Stopping active wg-quick@${WG_IF} before replacing config..."
    systemctl stop "wg-quick@${WG_IF}"
  fi
}

enable_ip_forwarding() {
  vps_enable_sysctl_file "${SYSCTL_FILE}" $'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n'
}

generate_server_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"

  (
    umask 077
    wg genkey | tee "${WG_DIR}/server_private_key" | wg pubkey > "${WG_DIR}/server_public_key"
  )
  chmod 600 "${WG_DIR}/server_private_key" "${WG_DIR}/server_public_key"
}

sed_escape() {
  vps_sed_escape "$1"
}

render_server_config() {
  local server_private_key=""

  server_private_key="$(cat "${WG_DIR}/server_private_key")"
  if [[ "${WG_NET}" == */* ]]; then
    WG_PREFIX="${WG_NET##*/}"
  fi
  if [[ "${WG_NET6}" == */* ]]; then
    WG_PREFIX6="${WG_NET6##*/}"
  fi

  sed \
    -e "s|:SERVER_PRIV_KEY:|$(sed_escape "${server_private_key}")|g" \
    -e "s|:SERVER_IP:|$(sed_escape "${WG_SERVER_IP}")|g" \
    -e "s|:SERVER_IP6:|$(sed_escape "${WG_SERVER_IP6}")|g" \
    -e "s|:SERVER_PREFIX:|$(sed_escape "${WG_PREFIX}")|g" \
    -e "s|:SERVER_PREFIX6:|$(sed_escape "${WG_PREFIX6}")|g" \
    -e "s|:SERVER_PORT:|$(sed_escape "${WG_PORT}")|g" \
    -e "s|:SERVER_NET:|$(sed_escape "${WG_NET}")|g" \
    -e "s|:SERVER_NET6:|$(sed_escape "${WG_NET6}")|g" \
    -e "s|:SERVER_IF:|$(sed_escape "${SERVER_IF}")|g" \
    "${SERVER_TEMPLATE}" > "${WG_DIR}/${WG_IF}.conf"

  chmod 600 "${WG_DIR}/${WG_IF}.conf"
}

prepare_script_state() {
  mkdir -p "${CLIENTS_DIR}"

  printf '%s\n' "${WG_SERVER_IP}" > "${LAST_IP_FILE}"
  printf '%s\n' "${WG_SERVER_IP6}" > "${LAST_IP6_FILE}"
  printf '%s\n' "${WG_ENDPOINT}" > "${ENDPOINT_FILE}"
  printf '%s\n' "${WG_ENDPOINT6}" > "${ENDPOINT6_FILE}"
  printf '%s\n' "${WG_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${WG_IF}" > "${SCRIPT_DIR}/server-interface.txt"
  printf '%s\n' "${WG_NET}" > "${SCRIPT_DIR}/server-net.txt"
  printf '%s\n' "${WG_NET6}" > "${SCRIPT_DIR}/server-net6.txt"

  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  vps_ufw_allow "${WG_PORT}" "udp"
  vps_enable_ufw_if_needed "Skipped enabling UFW. The WireGuard UDP port was still added to UFW rules."
}

start_wireguard() {
  vps_systemctl_enable_restart "wg-quick@${WG_IF}"
}

collect_settings() {
  local detected_if=""
  local detected_endpoint=""
  local detected_endpoint6=""

  detected_if="$(detect_server_if)"
  detected_endpoint="$(detect_public_ip)"
  detected_endpoint6="$(detect_public_ip6)"

  prompt WG_IF "WireGuard interface name" "${WG_IF}"
  prompt WG_PORT "WireGuard UDP port" "${WG_PORT}"
  vps_validate_port "${WG_PORT}"
  prompt WG_NET "WireGuard IPv4 VPN subnet" "${WG_NET}"
  prompt WG_SERVER_IP "WireGuard server IPv4 VPN IP" "${WG_SERVER_IP}"
  prompt WG_NET6 "WireGuard IPv6 VPN subnet" "${WG_NET6}"
  prompt WG_SERVER_IP6 "WireGuard server IPv6 VPN IP" "${WG_SERVER_IP6}"
  prompt SERVER_IF "Public network interface for NAT" "${SERVER_IF:-${detected_if:-eth0}}"
  prompt WG_ENDPOINT "Public endpoint clients should connect to" "${WG_ENDPOINT:-${detected_endpoint:-$(hostname -f)}}"
  prompt WG_ENDPOINT6 "Public IPv6 endpoint clients can connect to" "${WG_ENDPOINT6:-${detected_endpoint6}}"
  [[ -n "${WG_ENDPOINT}" ]] || vps_die "public endpoint cannot be empty"
}

print_summary() {
  echo
  echo "============================================================"
  echo "WireGuard installation complete."
  echo "============================================================"
  echo
  echo "Server config:     ${WG_DIR}/${WG_IF}.conf"
  echo "Server IPv4 IP:    ${WG_SERVER_IP}"
  echo "Server IPv6 IP:    ${WG_SERVER_IP6}"
  echo "IPv4 VPN subnet:   ${WG_NET}"
  echo "IPv6 VPN subnet:   ${WG_NET6}"
  echo "UDP port:          ${WG_PORT}"
  echo "Public interface:  ${SERVER_IF}"
  echo "Client IPv4 endpoint: ${WG_ENDPOINT}"
  echo "Client IPv6 endpoint: ${WG_ENDPOINT6}"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone             # create and add client"
  echo "  sudo ./add-client.sh --verbose phone   # also print live interface output"
  echo "  sudo ./add-client.sh --ipv6-endpoint phone # create client using IPv6 endpoint"
  echo "  sudo ./add-peer.sh phone               # add an existing client to ${WG_IF}.conf and live ${WG_IF}"
  echo "  sudo ./add-peer.sh --config-only phone # add an existing client to ${WG_IF}.conf only"
  echo "  sudo ./add-peer.sh --live-only phone   # add an existing client to live ${WG_IF} only"
  echo "  sudo ./remove-client.sh phone          # remove peer and client files"
  echo "  sudo ./remove-peer.sh phone            # remove an existing client from ${WG_IF}.conf and live ${WG_IF}"
  echo "  sudo ./remove-peer.sh --config-only phone # remove an existing client from ${WG_IF}.conf only"
  echo "  sudo ./remove-peer.sh --live-only phone # remove an existing client from live ${WG_IF} only"
  echo "  sudo ./uninstall.sh                    # remove script-created WireGuard data"
  echo
  echo "Check status with:"
  echo "  wg"
  echo "  sudo systemctl status wg-quick@${WG_IF}"
}

main() {
  require_root
  require_files
  require_supported_os

  echo "WireGuard full installation"
  echo
  collect_settings

  echo
  echo "This will install packages, back up existing config if present,"
  echo "write ${WG_DIR}/${WG_IF}.conf, enable IPv4/IPv6 forwarding, configure UFW,"
  echo "and start wg-quick@${WG_IF}."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  stop_existing_wireguard
  enable_ip_forwarding
  generate_server_keys
  render_server_config
  prepare_script_state
  setup_firewall
  start_wireguard
  print_summary
}

main "$@"
