#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

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

toml_key_exists() {
  local config_file="$1"
  local table="$2"
  local key="$3"

  awk -v table="${table}" -v key="${key}" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function parsed_key(line, left) {
      left = trim(substr(line, 1, index(line, "=") - 1))
      if (left ~ /^".*"$/) {
        return substr(left, 2, length(left) - 2)
      }
      return left
    }
    BEGIN { target = "[" table "]"; in_table = 0; found = 1 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      in_table = (current == target)
      next
    }
    in_table && /^[[:space:]]*#/ { next }
    in_table && index($0, "=") > 0 && parsed_key($0) == key { found = 0; exit }
    END { exit found }
  ' "${config_file}"
}

count_toml_keys() {
  local config_file="$1"
  local table="$2"

  awk -v table="${table}" '
    BEGIN { target = "[" table "]"; in_table = 0; count = 0 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      in_table = (current == target)
      next
    }
    in_table && /^[[:space:]]*#/ { next }
    in_table && index($0, "=") > 0 { count++ }
    END { print count }
  ' "${config_file}"
}

remove_toml_key() {
  local config_file="$1"
  local table="$2"
  local key="$3"
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk -v table="${table}" -v key="${key}" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function parsed_key(line, left) {
      left = trim(substr(line, 1, index(line, "=") - 1))
      if (left ~ /^".*"$/) {
        return substr(left, 2, length(left) - 2)
      }
      return left
    }
    BEGIN { target = "[" table "]"; in_table = 0 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      in_table = (current == target)
    }
    in_table && index($0, "=") > 0 && parsed_key($0) == key { next }
    { print }
  ' "${config_file}" > "${tmp_file}"

  cat "${tmp_file}" > "${config_file}"
  rm -f "${tmp_file}"
  chmod 640 "${config_file}"
  if getent passwd telemt >/dev/null 2>&1; then
    chown telemt:telemt "${config_file}"
  fi
}

restart_service() {
  local service="$1"

  systemctl restart "${service}" || die "failed to restart ${service}; check service logs"
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
  local exists_in_config=0
  local user_count=0

  require_root
  validate_client_name "${client_name}"

  config_file="$(read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(read_file_or_default telemt-service.txt "telemt")"
  client_dir="${CLIENTS_DIR}/${client_name}"

  [[ -f "${config_file}" ]] || die "Telemt config is missing: ${config_file}"
  if toml_key_exists "${config_file}" "access.users" "${client_name}"; then
    exists_in_config=1
  fi
  if [[ "${exists_in_config}" -eq 0 && ! -d "${client_dir}" ]]; then
    die "client does not exist: ${client_name}"
  fi
  user_count="$(count_toml_keys "${config_file}" "access.users")"
  if [[ "${exists_in_config}" -eq 1 && "${user_count}" -le 1 ]]; then
    die "refusing to remove the last Telemt client; Telemt requires at least one configured user"
  fi

  info "Removing Telemt client: ${client_name}"
  remove_toml_key "${config_file}" "access.users" "${client_name}"
  remove_toml_key "${config_file}" "access.user_max_unique_ips" "${client_name}"
  restart_service "${service}"
  remove_client_dir "${client_dir}"
  info "Removed client files for: ${client_name}"
}

main "$@"
