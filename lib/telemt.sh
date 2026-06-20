#!/usr/bin/env bash

[[ -n "${VPS_TELEMT_SH:-}" ]] && return 0
VPS_TELEMT_SH=1

TELEMT_CLIENTS_DIR_DEFAULT="${SCRIPT_DIR}/clients"
TELEMT_MAX_UNIQUE_IPS_DEFAULT="2"

telemt_generate_secret() {
  openssl rand -hex 16 | tr -d '\r\n'
}

telemt_key_exists() {
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

telemt_count_keys() {
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

telemt_fix_config_permissions() {
  local config_file="$1"

  chmod 640 "${config_file}"
  if getent passwd telemt >/dev/null 2>&1; then
    chown telemt:telemt "${config_file}"
  fi
}

telemt_upsert_key() {
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
  telemt_fix_config_permissions "${config_file}"
}

telemt_remove_key() {
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
  telemt_fix_config_permissions "${config_file}"
}

telemt_fetch_client_api() {
  local client_name="$1"
  local output_file="$2"
  local api_url="${TELEMT_API_URL:-http://127.0.0.1:9091/v1/users}"
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
  vps_die "could not fetch generated Telemt links for ${client_name} from ${api_url}"
}

telemt_write_client_artifacts() {
  local client_name="$1"
  local secret="$2"
  local max_unique_ips="$3"
  local clients_dir="${CLIENTS_DIR:-${TELEMT_CLIENTS_DIR_DEFAULT}}"
  local client_dir="${clients_dir}/${client_name}"
  local api_file="${client_dir}/telemt-${client_name}-api.json"
  local links_file="${client_dir}/telemt-${client_name}-links.txt"
  local first_link=""

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${secret}" > "${client_dir}/${client_name}.secret"
  printf '%s\n' "${max_unique_ips}" > "${client_dir}/${client_name}.max-unique-ips"
  chmod 600 "${client_dir}/${client_name}.secret" "${client_dir}/${client_name}.max-unique-ips"

  telemt_fetch_client_api "${client_name}" "${api_file}"
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

telemt_add_client_main() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: add-client.sh <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local clients_dir="${CLIENTS_DIR:-${TELEMT_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local secret=""
  local max_unique_ips="${TELEMT_CLIENT_MAX_UNIQUE_IPS:-${MAX_UNIQUE_IPS_DEFAULT:-${TELEMT_MAX_UNIQUE_IPS_DEFAULT}}}"

  vps_require_root "sudo ./add-client.sh ..."
  vps_validate_client_name "${client_name}"

  vps_require_commands curl jq openssl systemctl

  config_file="$(vps_read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(vps_read_file_or_default telemt-service.txt "telemt")"
  client_dir="${clients_dir}/${client_name}"

  [[ -f "${config_file}" ]] || vps_die "Telemt config is missing: ${config_file}"
  [[ ! -e "${client_dir}" ]] || vps_die "client already exists: ${client_name}"
  if telemt_key_exists "${config_file}" "access.users" "${client_name}"; then
    vps_die "client already exists in Telemt config: ${client_name}"
  fi

  vps_prompt max_unique_ips "Max simultaneous unique IPs for this client" "${max_unique_ips}"
  vps_validate_positive_int "max unique IPs" "${max_unique_ips}"

  secret="$(telemt_generate_secret)"
  [[ -n "${secret}" ]] || vps_die "could not generate Telemt secret"

  vps_info "Adding Telemt client: ${client_name}"
  telemt_upsert_key "${config_file}" "access.users" "${client_name}" "\"${secret}\""
  telemt_upsert_key "${config_file}" "access.user_max_unique_ips" "${client_name}" "${max_unique_ips}"
  vps_systemctl_restart "${service}"
  telemt_write_client_artifacts "${client_name}" "${secret}" "${max_unique_ips}"
  vps_info "Created Telemt links: ${client_dir}/telemt-${client_name}-links.txt"
}

telemt_remove_client_main() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: remove-client.sh <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local config_file=""
  local service=""
  local clients_dir="${CLIENTS_DIR:-${TELEMT_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local exists_in_config=0
  local user_count=0

  vps_require_root "sudo ./remove-client.sh ..."
  vps_validate_client_name "${client_name}"

  config_file="$(vps_read_file_or_default telemt-config-path.txt "/etc/telemt/telemt.toml")"
  service="$(vps_read_file_or_default telemt-service.txt "telemt")"
  client_dir="${clients_dir}/${client_name}"

  [[ -f "${config_file}" ]] || vps_die "Telemt config is missing: ${config_file}"
  if telemt_key_exists "${config_file}" "access.users" "${client_name}"; then
    exists_in_config=1
  fi
  if [[ "${exists_in_config}" -eq 0 && ! -d "${client_dir}" ]]; then
    vps_die "client does not exist: ${client_name}"
  fi
  user_count="$(telemt_count_keys "${config_file}" "access.users")"
  if [[ "${exists_in_config}" -eq 1 && "${user_count}" -le 1 ]]; then
    vps_die "refusing to remove the last Telemt client; Telemt requires at least one configured user"
  fi

  vps_info "Removing Telemt client: ${client_name}"
  telemt_remove_key "${config_file}" "access.users" "${client_name}"
  telemt_remove_key "${config_file}" "access.user_max_unique_ips" "${client_name}"
  vps_systemctl_restart "${service}"
  vps_safe_remove_client_dir "${client_dir}" "${clients_dir}"
  vps_info "Removed client files for: ${client_name}"
}
