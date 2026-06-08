#!/usr/bin/env bash
set -euo pipefail

# Remove Telemt state created by this script bundle.
# This does not uninstall apt packages or remove the telemt system user.

TELEMT_CONFIG_DEFAULT="/etc/telemt/telemt.toml"
TELEMT_SERVICE_DEFAULT="telemt"
TELEMT_BIN_DEFAULT="/bin/telemt"
TELEMT_WORK_DIR="/opt/telemt"
TELEMT_DATA_DIR="/var/lib/telemt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root:"
    echo "  sudo bash ${0}"
    exit 1
  fi
}

confirm() {
  local message="$1"
  local answer=""

  read -r -p "${message} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
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

remove_path() {
  local path="$1"

  [[ -n "${path}" && "${path}" != "/" ]] || {
    echo "ERROR: refusing to remove unsafe path: ${path}" >&2
    exit 1
  }

  if [[ -e "${path}" ]]; then
    rm -rf "${path}"
    echo "Removed: ${path}"
  fi
}

remove_empty_dir() {
  local path="$1"

  [[ -d "${path}" ]] || return 0
  rmdir "${path}" 2>/dev/null || true
}

remove_client_files() {
  [[ -d "${CLIENTS_DIR}" ]] || return 0
  [[ "${CLIENTS_DIR}" == "${SCRIPT_DIR}/clients" ]] || {
    echo "ERROR: refusing to clean unexpected clients path: ${CLIENTS_DIR}" >&2
    exit 1
  }

  find "${CLIENTS_DIR}" -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
  echo "Removed generated client files from: ${CLIENTS_DIR}"
}

stop_telemt() {
  local service="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${service}" 2>/dev/null || true
    systemctl disable "${service}" 2>/dev/null || true
  fi
}

remove_ufw_rule() {
  local port_file="${SCRIPT_DIR}/server-port.txt"
  local port=""

  [[ -f "${port_file}" ]] || return 0
  port="$(cat "${port_file}")"
  [[ -n "${port}" ]] || return 0

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
}

print_plan() {
  local config_file="$1"
  local service="$2"
  local bin_path="$3"

  echo "This will remove Telemt data created by this script bundle:"
  echo
  echo "  Systemd service:   ${service}"
  echo "  Server config:     ${config_file}"
  echo "  Binary:            ${bin_path}"
  echo "  Work directory:    ${TELEMT_WORK_DIR}"
  echo "  Data directory:    ${TELEMT_DATA_DIR}"
  echo "  Client files:      ${CLIENTS_DIR} contents except .gitkeep"
  echo "  Install backups:   ${BACKUP_ROOT}"
  echo "  Script state:      public-host.txt, server-port.txt, tls-domain.txt,"
  echo "                     telemt-config-path.txt, telemt-service.txt,"
  echo "                     telemt-bin-path.txt"
  echo
  echo "It will also try to remove the UFW allow rule for the saved Telemt TCP port."
  echo "It will not uninstall apt packages or remove the telemt system user."
}

main() {
  local config_file=""
  local service=""
  local bin_path=""
  local service_file=""
  local override_dir=""

  require_root

  config_file="$(read_file_or_default "${SCRIPT_DIR}/telemt-config-path.txt" "${TELEMT_CONFIG_DEFAULT}")"
  service="$(read_file_or_default "${SCRIPT_DIR}/telemt-service.txt" "${TELEMT_SERVICE_DEFAULT}")"
  bin_path="$(read_file_or_default "${SCRIPT_DIR}/telemt-bin-path.txt" "${TELEMT_BIN_DEFAULT}")"
  service_file="/etc/systemd/system/${service}.service"
  override_dir="/etc/systemd/system/${service}.service.d"

  print_plan "${config_file}" "${service}" "${bin_path}"
  echo
  if ! confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  stop_telemt "${service}"
  remove_ufw_rule

  remove_path "${service_file}"
  remove_path "${override_dir}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  remove_path "${config_file}"
  remove_empty_dir "$(dirname "${config_file}")"
  remove_path "${TELEMT_WORK_DIR}"
  remove_path "${TELEMT_DATA_DIR}"
  remove_path "${bin_path}"

  remove_client_files
  remove_path "${BACKUP_ROOT}"
  remove_path "${SCRIPT_DIR}/public-host.txt"
  remove_path "${SCRIPT_DIR}/server-port.txt"
  remove_path "${SCRIPT_DIR}/tls-domain.txt"
  remove_path "${SCRIPT_DIR}/telemt-config-path.txt"
  remove_path "${SCRIPT_DIR}/telemt-service.txt"
  remove_path "${SCRIPT_DIR}/telemt-bin-path.txt"

  echo "Uninstall complete."
}

main "$@"
