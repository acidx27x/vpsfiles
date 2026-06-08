#!/usr/bin/env bash
set -euo pipefail

# Remove Xray state created by this script bundle.
# This does not uninstall Xray packages or binaries.

XRAY_CONFIG_DEFAULT="/usr/local/etc/xray/config.json"
XRAY_SERVICE_DEFAULT="xray"
SYSCTL_FILE="/etc/sysctl.d/99-xray-bbr.conf"

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

remove_client_files() {
  [[ -d "${CLIENTS_DIR}" ]] || return 0
  [[ "${CLIENTS_DIR}" == "${SCRIPT_DIR}/clients" ]] || {
    echo "ERROR: refusing to clean unexpected clients path: ${CLIENTS_DIR}" >&2
    exit 1
  }

  find "${CLIENTS_DIR}" -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
  echo "Removed generated client files from: ${CLIENTS_DIR}"
}

stop_xray() {
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

  echo "This will remove Xray data created by this script bundle:"
  echo
  echo "  Systemd service:   ${service}"
  echo "  Server config:     ${config_file}"
  echo "  Sysctl file:       ${SYSCTL_FILE}"
  echo "  Client files:      ${CLIENTS_DIR} contents except .gitkeep"
  echo "  Install backups:   ${BACKUP_ROOT}"
  echo "  Script state:      server-endpoint.txt, server-endpoint6.txt,"
  echo "                     server-port.txt,"
  echo "                     reality-target.txt, reality-server-name.txt,"
  echo "                     reality-private-key.txt, reality-public-key.txt,"
  echo "                     xray-config-path.txt, xray-service.txt"
  echo
  echo "It will also try to remove the UFW allow rule for the saved Xray TCP port."
  echo "It will not uninstall Xray packages or binaries."
}

main() {
  local config_file=""
  local service=""

  require_root

  config_file="$(read_file_or_default "${SCRIPT_DIR}/xray-config-path.txt" "${XRAY_CONFIG_DEFAULT}")"
  service="$(read_file_or_default "${SCRIPT_DIR}/xray-service.txt" "${XRAY_SERVICE_DEFAULT}")"

  print_plan "${config_file}" "${service}"
  echo
  if ! confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  stop_xray "${service}"
  remove_ufw_rule
  remove_path "${config_file}"
  remove_path "${SYSCTL_FILE}"
  remove_client_files
  remove_path "${BACKUP_ROOT}"
  remove_path "${SCRIPT_DIR}/server-endpoint.txt"
  remove_path "${SCRIPT_DIR}/server-endpoint6.txt"
  remove_path "${SCRIPT_DIR}/server-port.txt"
  remove_path "${SCRIPT_DIR}/reality-target.txt"
  remove_path "${SCRIPT_DIR}/reality-server-name.txt"
  remove_path "${SCRIPT_DIR}/reality-private-key.txt"
  remove_path "${SCRIPT_DIR}/reality-public-key.txt"
  remove_path "${SCRIPT_DIR}/xray-config-path.txt"
  remove_path "${SCRIPT_DIR}/xray-service.txt"

  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi

  echo "Uninstall complete."
}

main "$@"
