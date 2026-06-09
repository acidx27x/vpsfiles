#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

CLIENTS_DIR="${SCRIPT_DIR}/clients"
MAX_UNIQUE_IPS_DEFAULT="2"

usage() {
  echo "usage: add-client.sh <client_name>"
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
    die "run as root: sudo ./add-client.sh ..."
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

prompt() {
  local name="$1"
  local label="$2"
  local default="$3"
  local value=""

  read -r -p "${label} [${default}]: " value
  printf -v "${name}" '%s' "${value:-${default}}"
}

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

validate_positive_int() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be a positive integer"
  (( value >= 1 )) || die "${name} must be at least 1"
}

generate_secret() {
  openssl rand -hex 16 | tr -d '\r\n'
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

upsert_toml_key() {
  local config_file="$1"
  local table="$2"
  local key="$3"
  local value="$4"
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk -v table="${table}" -v key="${key}" -v value="${value}" '
    function trim(item) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
      return item
    }
    function parsed_key(line, left) {
      left = trim(substr(line, 1, index(line, "=") - 1))
      if (left ~ /^".*"$/) {
        return substr(left, 2, length(left) - 2)
      }
      return left
    }
    BEGIN {
      target = "[" table "]"
      in_table = 0
      found_table = 0
      wrote = 0
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      if (in_table && !wrote) {
        print "\"" key "\" = " value
        wrote = 1
      }
      in_table = (current == target)
      if (in_table) {
        found_table = 1
      }
    }
    in_table && index($0, "=") > 0 && parsed_key($0) == key {
      print "\"" key "\" = " value
      wrote = 1
      next
    }
    { print }
    END {
      if (!found_table) {
        print ""
        print target
        print "\"" key "\" = " value
      } else if (in_table && !wrote) {
        print "\"" key "\" = " value
      }
    }
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

fetch_client_api() {
  local client_name="$1"
  local output_file="$2"
  local api_url="http://127.0.0.1:9091/v1/users"
  local attempt=0
  local tmp_file=""

  tmp_file="$(mktemp)"
  while (( attempt < 10 )); do
    if curl -fsS "${api_url}" > "${tmp_file}" 2>/dev/null \
      && jq -e --arg name "${client_name}" '.data[]? | select(.username == $name)' "${tmp_file}" >/dev/null; then
      install -m 600 "${tmp_file}" "${output_file}"
      rm -f "${tmp_file}"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  rm -f "${tmp_file}"
  die "could not fetch generated Telemt links for ${client_name} from ${api_url}"
}

write_client_artifacts() {
  local client_name="$1"
  local secret="$2"
  local max_unique_ips="$3"
  local client_dir="${CLIENTS_DIR}/${client_name}"
  local api_file="${client_dir}/telemt-${client_name}-api.json"
  local links_file="${client_dir}/telemt-${client_name}-links.txt"
  local first_link=""

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${secret}" > "${client_dir}/${client_name}.secret"
  printf '%s\n' "${max_unique_ips}" > "${client_dir}/${client_name}.max-unique-ips"
  chmod 600 "${client_dir}/${client_name}.secret" "${client_dir}/${client_name}.max-unique-ips"

  fetch_client_api "${client_name}" "${api_file}"
  jq -r --arg name "${client_name}" '
    .data[]? | select(.username == $name) |
    (.links.tls[]? | "tls: \(.)"),
    (.links.secure[]? | "secure: \(.)"),
    (.links.classic[]? | "classic: \(.)")
  ' "${api_file}" > "${links_file}"
  chmod 600 "${links_file}"

  first_link="$(jq -r --arg name "${client_name}" '.data[]? | select(.username == $name) | (.links.tls[0] // .links.secure[0] // .links.classic[0] // empty)' "${api_file}")"
  if [[ -n "${first_link}" ]] && command -v qrencode >/dev/null 2>&1; then
    printf '%s\n' "${first_link}" | qrencode -t ansiutf8 > "${client_dir}/telemt-${client_name}-qrcode.txt"
    chmod 600 "${client_dir}/telemt-${client_name}-qrcode.txt"
  fi
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
  local secret=""
  local max_unique_ips="${TELEMT_CLIENT_MAX_UNIQUE_IPS:-${MAX_UNIQUE_IPS_DEFAULT}}"

  require_root
  validate_client_name "${client_name}"

  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

  config_file="$(read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(read_file_or_default telemt-service.txt "telemt")"
  client_dir="${CLIENTS_DIR}/${client_name}"

  [[ -f "${config_file}" ]] || die "Telemt config is missing: ${config_file}"
  [[ ! -e "${client_dir}" ]] || die "client already exists: ${client_name}"
  if toml_key_exists "${config_file}" "access.users" "${client_name}"; then
    die "client already exists in Telemt config: ${client_name}"
  fi

  prompt max_unique_ips "Max simultaneous unique IPs for this client" "${max_unique_ips}"
  validate_positive_int "max unique IPs" "${max_unique_ips}"

  secret="$(generate_secret)"
  [[ -n "${secret}" ]] || die "could not generate Telemt secret"

  info "Adding Telemt client: ${client_name}"
  upsert_toml_key "${config_file}" "access.users" "${client_name}" "\"${secret}\""
  upsert_toml_key "${config_file}" "access.user_max_unique_ips" "${client_name}" "${max_unique_ips}"
  restart_service "${service}"
  write_client_artifacts "${client_name}" "${secret}" "${max_unique_ips}"
  info "Created Telemt links: ${client_dir}/telemt-${client_name}-links.txt"
}

main "$@"
