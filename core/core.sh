#!/usr/bin/env bash

[[ -n "${VPS_CORE_SH:-}" ]] && return 0
VPS_CORE_SH=1

vps_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

vps_info() {
  printf '%s\n' "$*"
}

vps_verbose() {
  if [[ "${VERBOSE:-0}" -eq 1 ]]; then
    printf '%s\n' "$*"
  fi
}

vps_require_root() {
  local command_hint="${1:-sudo bash ${0}}"

  if [[ "${EUID}" -ne 0 ]]; then
    vps_die "run as root: ${command_hint}"
  fi
}

vps_require_commands() {
  local command_name=""

  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || vps_die "${command_name} is required"
  done
}

vps_read_file_or_default() {
  local file="$1"
  local default="$2"

  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    printf '%s\n' "${default}"
  fi
}

vps_validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || vps_die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || vps_die "invalid client name"
}

vps_validate_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || vps_die "port must be a number: ${port}"
  (( port >= 1 && port <= 65535 )) || vps_die "port must be between 1 and 65535: ${port}"
}

vps_validate_non_negative_int() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+$ ]] || vps_die "${name} must be a non-negative integer"
}

vps_validate_positive_int() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+$ ]] || vps_die "${name} must be a positive integer"
  (( value >= 1 )) || vps_die "${name} must be at least 1"
}

vps_prompt() {
  local name="$1"
  local label="$2"
  local default="$3"
  local value=""

  read -r -p "${label} [${default}]: " value
  printf -v "${name}" '%s' "${value:-${default}}"
}

vps_confirm() {
  local message="$1"
  local answer=""

  read -r -p "${message} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

vps_detect_server_if() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

vps_detect_public_ip() {
  local ip_addr=""

  if command -v curl >/dev/null 2>&1; then
    ip_addr="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${ip_addr}" ]]; then
      ip_addr="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi

  printf '%s\n' "${ip_addr}"
}

vps_detect_public_ip6() {
  local ip_addr=""

  if command -v curl >/dev/null 2>&1; then
    ip_addr="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    if [[ -z "${ip_addr}" ]]; then
      ip_addr="$(curl -6 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi

  printf '%s\n' "${ip_addr}"
}

vps_sed_escape() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

vps_format_endpoint() {
  local endpoint="$1"
  local port="$2"

  if [[ "${endpoint}" == \[*\]:* ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == \[*\] ]]; then
    printf '%s:%s\n' "${endpoint}" "${port}"
  elif [[ "${endpoint}" =~ ^[^:]+:[0-9]+$ ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == *:* ]]; then
    printf '[%s]:%s\n' "${endpoint}" "${port}"
  else
    printf '%s:%s\n' "${endpoint}" "${port}"
  fi
}

vps_format_uri_host() {
  local endpoint="$1"

  if [[ "${endpoint}" == \[*\] ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == *:* ]]; then
    printf '[%s]\n' "${endpoint}"
  else
    printf '%s\n' "${endpoint}"
  fi
}

vps_url_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

vps_safe_remove_path() {
  local path="$1"

  [[ -n "${path}" && "${path}" != "/" ]] || vps_die "refusing to remove unsafe path: ${path}"

  if [[ -e "${path}" ]]; then
    rm -rf -- "${path}"
    printf 'Removed: %s\n' "${path}"
  fi
}

vps_safe_remove_file_path() {
  local path="$1"

  [[ -n "${path}" && "${path}" == /* && "${path}" != "/" ]] || vps_die "refusing to remove unsafe file path: ${path}"
  [[ ! -d "${path}" ]] || vps_die "refusing to remove directory as file path: ${path}"
  vps_safe_remove_path "${path}"
}

vps_remove_empty_dir() {
  local path="$1"

  [[ -d "${path}" ]] || return 0
  rmdir "${path}" 2>/dev/null || true
}

vps_safe_remove_client_dir() {
  local client_dir="$1"
  local clients_dir="$2"

  [[ "${client_dir}" == "${clients_dir}/"* ]] || vps_die "refusing to remove unexpected path: ${client_dir}"
  [[ -d "${client_dir}" ]] || return 0
  rm -rf -- "${client_dir}"
}

vps_clean_clients_dir() {
  local clients_dir="$1"
  local expected_dir="$2"

  [[ -d "${clients_dir}" ]] || return 0
  [[ "${clients_dir}" == "${expected_dir}" ]] || vps_die "refusing to clean unexpected clients path: ${clients_dir}"

  find "${clients_dir}" -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
  printf 'Removed generated client files from: %s\n' "${clients_dir}"
}

vps_ufw_allow() {
  local port="$1"
  local proto="$2"

  ufw allow "${port}/${proto}" >/dev/null || true
}

vps_ufw_delete_saved_rule() {
  local port_file="$1"
  local proto="$2"
  local port=""

  [[ -f "${port_file}" ]] || return 0
  port="$(cat "${port_file}")"
  [[ -n "${port}" ]] || return 0

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
  fi
}

vps_enable_ufw_if_needed() {
  local skipped_message="$1"

  if ! ufw status | grep -q "Status: active"; then
    if vps_confirm "UFW is not active. Enable it now?"; then
      ufw --force enable >/dev/null
    else
      printf '%s\n' "${skipped_message}"
    fi
  fi
}

vps_systemctl_restart() {
  local service="$1"

  systemctl restart "${service}" || vps_die "failed to restart ${service}; check service logs"
}

vps_systemctl_enable_restart() {
  local service="$1"

  systemctl enable "${service}" >/dev/null
  systemctl restart "${service}"
}

vps_systemctl_stop_disable() {
  local service="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${service}" 2>/dev/null || true
    systemctl disable "${service}" 2>/dev/null || true
  fi
}
