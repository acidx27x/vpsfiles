#!/usr/bin/env bash
set -euo pipefail

# Full Telemt installer for this script bundle.
# Run from vpsfiles/telemt-scripts, then add clients with ./add-client.sh.

TELEMT_PORT_DEFAULT="10443"
TELEMT_PUBLIC_HOST_DEFAULT=""
TELEMT_TLS_DOMAIN_DEFAULT="www.google.com"
TELEMT_MAX_CONNECTIONS_DEFAULT="1000"
TELEMT_INITIAL_CLIENT_DEFAULT="main"
TELEMT_INITIAL_MAX_UNIQUE_IPS_DEFAULT="2"
TELEMT_CONFIG_DEFAULT="/etc/telemt/telemt.toml"
TELEMT_SERVICE_DEFAULT="telemt"
TELEMT_BIN_DEFAULT="/bin/telemt"
TELEMT_WORK_DIR="/opt/telemt"
TELEMT_DATA_DIR="/var/lib/telemt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_TEMPLATE="${SCRIPT_DIR}/telemt.toml.example"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

TELEMT_PORT="${TELEMT_PORT:-${TELEMT_PORT_DEFAULT}}"
TELEMT_PUBLIC_HOST="${TELEMT_PUBLIC_HOST:-${TELEMT_PUBLIC_HOST_DEFAULT}}"
TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-${TELEMT_TLS_DOMAIN_DEFAULT}}"
TELEMT_MAX_CONNECTIONS="${TELEMT_MAX_CONNECTIONS:-${TELEMT_MAX_CONNECTIONS_DEFAULT}}"
TELEMT_INITIAL_CLIENT="${TELEMT_INITIAL_CLIENT:-${TELEMT_INITIAL_CLIENT_DEFAULT}}"
TELEMT_INITIAL_MAX_UNIQUE_IPS="${TELEMT_INITIAL_MAX_UNIQUE_IPS:-${TELEMT_INITIAL_MAX_UNIQUE_IPS_DEFAULT}}"
TELEMT_CONFIG="${TELEMT_CONFIG:-${TELEMT_CONFIG_DEFAULT}}"
TELEMT_SERVICE="${TELEMT_SERVICE:-${TELEMT_SERVICE_DEFAULT}}"
TELEMT_BIN="${TELEMT_BIN:-${TELEMT_BIN_DEFAULT}}"
TELEMT_VERSION="${TELEMT_VERSION:-latest}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=telemt-scripts/telemt.sh
. "${SCRIPT_DIR}/telemt.sh"

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

validate_non_negative_int() {
  vps_validate_non_negative_int "$@"
}

validate_positive_int() {
  vps_validate_positive_int "$@"
}

validate_client_name() {
  vps_validate_client_name "$1"
}

detect_public_ip() {
  vps_detect_public_ip
}

detect_public_ip6() {
  vps_detect_public_ip6
}

sed_escape() {
  vps_sed_escape "$1"
}

generate_secret() {
  openssl rand -hex 16 | tr -d '\r\n'
}

install_packages() {
  vps_install_packages \
    ca-certificates \
    curl \
    gzip \
    jq \
    openssl \
    tar \
    ufw \
    wget
}

install_telemt() {
  local temp_dir=""

  temp_dir="$(mktemp -d)"
  telemt_download_binary "${TELEMT_VERSION}" "${temp_dir}/telemt"

  install -d -m 755 "$(dirname "${TELEMT_BIN}")"
  install -m 755 "${temp_dir}/telemt" "${TELEMT_BIN}"
  rm -rf "${temp_dir}"
  command -v "${TELEMT_BIN}" >/dev/null 2>&1 || [[ -x "${TELEMT_BIN}" ]] || die "telemt is missing after installation"
}

ensure_user_group() {
  local nologin_bin=""

  nologin_bin="$(command -v nologin 2>/dev/null || command -v false 2>/dev/null || echo /bin/false)"

  if ! getent group telemt >/dev/null 2>&1; then
    groupadd -r telemt
  fi
  if ! getent passwd telemt >/dev/null 2>&1; then
    useradd -r -g telemt -d "${TELEMT_WORK_DIR}" -s "${nologin_bin}" -c "Telemt Proxy" telemt
  fi
}

setup_dirs() {
  install -d -m 750 -o telemt -g telemt "${TELEMT_WORK_DIR}"
  install -d -m 750 -o telemt -g telemt "$(dirname "${TELEMT_CONFIG}")"
  install -d -m 750 -o telemt -g telemt "${TELEMT_DATA_DIR}/tlsfront"
}

backup_existing_configs() {
  local timestamp=""
  local backup_dir=""
  local found=0
  local path=""

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"

  for path in \
    "${TELEMT_CONFIG}" \
    "/etc/systemd/system/${TELEMT_SERVICE}.service" \
    "/etc/systemd/system/${TELEMT_SERVICE}.service.d/override.conf" \
    "${SCRIPT_DIR}/public-host.txt" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/tls-domain.txt" \
    "${SCRIPT_DIR}/telemt-config-path.txt" \
    "${SCRIPT_DIR}/telemt-service.txt" \
    "${SCRIPT_DIR}/telemt-bin-path.txt"; do
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
  echo "Existing Telemt/script config was found."
  echo "Backup destination: ${backup_dir}"
  if ! confirm "Back up existing config before continuing?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  mkdir -p "${backup_dir}/telemt-config" "${backup_dir}/systemd" "${backup_dir}/script-files"

  if [[ -e "${TELEMT_CONFIG}" ]]; then
    cp -a "${TELEMT_CONFIG}" "${backup_dir}/telemt-config/"
  fi
  for path in "/etc/systemd/system/${TELEMT_SERVICE}.service" "/etc/systemd/system/${TELEMT_SERVICE}.service.d/override.conf"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/systemd/"
    fi
  done
  for path in \
    "${SCRIPT_DIR}/public-host.txt" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/tls-domain.txt" \
    "${SCRIPT_DIR}/telemt-config-path.txt" \
    "${SCRIPT_DIR}/telemt-service.txt" \
    "${SCRIPT_DIR}/telemt-bin-path.txt"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/script-files/"
    fi
  done
  if [[ -d "${CLIENTS_DIR}" ]]; then
    cp -a "${CLIENTS_DIR}" "${backup_dir}/script-files/"
  fi

  echo "Backup complete: ${backup_dir}"
}

render_server_config() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  sed \
    -e "s|:PUBLIC_HOST:|$(sed_escape "${TELEMT_PUBLIC_HOST}")|g" \
    -e "s|:SERVER_PORT:|$(sed_escape "${TELEMT_PORT}")|g" \
    -e "s|:TLS_DOMAIN:|$(sed_escape "${TELEMT_TLS_DOMAIN}")|g" \
    -e "s|:MAX_CONNECTIONS:|$(sed_escape "${TELEMT_MAX_CONNECTIONS}")|g" \
    -e "s|:INITIAL_CLIENT:|$(sed_escape "${TELEMT_INITIAL_CLIENT}")|g" \
    -e "s|:INITIAL_SECRET:|$(sed_escape "${TELEMT_INITIAL_SECRET}")|g" \
    -e "s|:INITIAL_MAX_UNIQUE_IPS:|$(sed_escape "${TELEMT_INITIAL_MAX_UNIQUE_IPS}")|g" \
    "${SERVER_TEMPLATE}" > "${tmp_file}"

  install -m 640 -o telemt -g telemt "${tmp_file}" "${TELEMT_CONFIG}"
  rm -f "${tmp_file}"
}

write_initial_client_artifacts() {
  telemt_write_client_artifacts \
    "${TELEMT_INITIAL_CLIENT}" \
    "${TELEMT_INITIAL_SECRET}" \
    "${TELEMT_INITIAL_MAX_UNIQUE_IPS}"
}

install_systemd_service() {
  local service_file="/etc/systemd/system/${TELEMT_SERVICE}.service"
  local override_dir="/etc/systemd/system/${TELEMT_SERVICE}.service.d"
  local override_file="${override_dir}/override.conf"

  cat > "${service_file}" <<EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=${TELEMT_WORK_DIR}
ExecStart=${TELEMT_BIN} ${TELEMT_CONFIG}
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  install -d -m 755 "${override_dir}"
  cat > "${override_file}" <<EOF
[Service]
LimitNOFILE=1048576
Restart=always
RestartSec=3
EOF

  systemctl daemon-reload
}

prepare_script_state() {
  mkdir -p "${CLIENTS_DIR}"

  printf '%s\n' "${TELEMT_PUBLIC_HOST}" > "${SCRIPT_DIR}/public-host.txt"
  printf '%s\n' "${TELEMT_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${TELEMT_TLS_DOMAIN}" > "${SCRIPT_DIR}/tls-domain.txt"
  printf '%s\n' "${TELEMT_CONFIG}" > "${SCRIPT_DIR}/telemt-config-path.txt"
  printf '%s\n' "${TELEMT_SERVICE}" > "${SCRIPT_DIR}/telemt-service.txt"
  printf '%s\n' "${TELEMT_BIN}" > "${SCRIPT_DIR}/telemt-bin-path.txt"

  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  vps_ufw_allow "${TELEMT_PORT}" "tcp"
  vps_enable_ufw_if_needed "Skipped enabling UFW. The Telemt TCP port was still added to UFW rules."
}

start_telemt() {
  vps_systemctl_enable_restart "${TELEMT_SERVICE}"
}

collect_settings() {
  local detected_host=""
  local detected_host6=""

  detected_host="$(detect_public_ip)"
  detected_host6="$(detect_public_ip6)"
  prompt TELEMT_PORT "Telemt TCP port" "${TELEMT_PORT}"
  validate_port "${TELEMT_PORT}"
  prompt TELEMT_PUBLIC_HOST "Public host for generated tg:// links (domain, IPv4, or bare IPv6)" "${TELEMT_PUBLIC_HOST:-${detected_host:-${detected_host6:-$(hostname -f)}}}"
  prompt TELEMT_TLS_DOMAIN "Fake-TLS/SNI masking domain" "${TELEMT_TLS_DOMAIN}"
  prompt TELEMT_MAX_CONNECTIONS "Global Telemt max_connections (0 = unlimited)" "${TELEMT_MAX_CONNECTIONS}"
  validate_non_negative_int "max_connections" "${TELEMT_MAX_CONNECTIONS}"
  prompt TELEMT_INITIAL_CLIENT "Initial Telemt client name" "${TELEMT_INITIAL_CLIENT}"
  validate_client_name "${TELEMT_INITIAL_CLIENT}"
  prompt TELEMT_INITIAL_MAX_UNIQUE_IPS "Initial client max simultaneous unique IPs" "${TELEMT_INITIAL_MAX_UNIQUE_IPS}"
  validate_positive_int "initial client max unique IPs" "${TELEMT_INITIAL_MAX_UNIQUE_IPS}"

  [[ -n "${TELEMT_PUBLIC_HOST}" ]] || die "public host cannot be empty"
  [[ -n "${TELEMT_TLS_DOMAIN}" ]] || die "TLS domain cannot be empty"
}

print_summary() {
  echo
  echo "============================================================"
  echo "Telemt installation complete."
  echo "============================================================"
  echo
  echo "Server config:       ${TELEMT_CONFIG}"
  echo "Systemd service:     ${TELEMT_SERVICE}"
  echo "Binary:              ${TELEMT_BIN}"
  echo "TCP port:            ${TELEMT_PORT}"
  echo "Public host:         ${TELEMT_PUBLIC_HOST}"
  echo "TLS masking domain:  ${TELEMT_TLS_DOMAIN}"
  echo "Max connections:     ${TELEMT_MAX_CONNECTIONS}"
  echo "Initial client:      ${TELEMT_INITIAL_CLIENT}"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone"
  echo "  sudo ./remove-client.sh phone"
  echo "  sudo ./uninstall.sh"
  echo
  echo "Generated initial client files:"
  echo "  ${CLIENTS_DIR}/${TELEMT_INITIAL_CLIENT}/telemt-${TELEMT_INITIAL_CLIENT}-links.txt"
  echo
  echo "Check status with:"
  echo "  sudo systemctl status ${TELEMT_SERVICE}"
  echo "  sudo journalctl -u ${TELEMT_SERVICE} -n 100 --no-pager"
}

main() {
  require_root
  require_files
  require_supported_os

  echo "Telemt MTProxy full installation"
  echo
  collect_settings

  echo
  echo "This will install packages, download Telemt ${TELEMT_VERSION} from GitHub releases,"
  echo "back up existing config if present, write ${TELEMT_CONFIG}, install a systemd"
  echo "service, configure UFW, and start ${TELEMT_SERVICE} with an initial client."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  install_telemt
  ensure_user_group
  setup_dirs
  TELEMT_INITIAL_SECRET="$(generate_secret)"
  render_server_config
  install_systemd_service
  prepare_script_state
  setup_firewall
  start_telemt
  write_initial_client_artifacts
  print_summary
}

main "$@"
