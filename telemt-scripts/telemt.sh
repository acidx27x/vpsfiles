#!/usr/bin/env bash

[[ -n "${VPS_TELEMT_SH:-}" ]] && return 0
VPS_TELEMT_SH=1

TELEMT_CLIENTS_DIR_DEFAULT="${SCRIPT_DIR}/clients"
TELEMT_SS_METHOD="2022-blake3-aes-256-gcm"

TELEMT_SS_UPSTREAM_ADDRESS="${TELEMT_SS_UPSTREAM_ADDRESS:-}"
TELEMT_SS_UPSTREAM_PORT="${TELEMT_SS_UPSTREAM_PORT:-}"
TELEMT_SS_UPSTREAM_URI="${TELEMT_SS_UPSTREAM_URI:-}"

telemt_parse_shadowsocks_upstream_uri() {
  local uri="$1"
  local prefix="ss://${TELEMT_SS_METHOD}:"
  local payload=""
  local key=""
  local endpoint=""
  local address=""
  local port=""
  local remainder=""
  local decoded_length=""

  TELEMT_SS_UPSTREAM_ADDRESS=""
  TELEMT_SS_UPSTREAM_PORT=""
  TELEMT_SS_UPSTREAM_URI=""

  [[ "${uri}" == "${prefix}"* ]] \
    || vps_die "Shadowsocks upstream URI must use ${TELEMT_SS_METHOD}"
  payload="${uri#"${prefix}"}"
  [[ "${payload}" == *@* ]] || vps_die "Shadowsocks upstream URI is missing its endpoint"
  key="${payload%%@*}"
  endpoint="${payload#*@}"
  [[ -n "${key}" && -n "${endpoint}" && "${endpoint}" != *@* ]] \
    || vps_die "Shadowsocks upstream URI is malformed"
  [[ "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || vps_die "Shadowsocks upstream URI must contain a 32-byte base64 key"
  if ! decoded_length="$(printf '%s' "${key}" | base64 --decode 2>/dev/null | wc -c | tr -d '[:space:]')"; then
    vps_die "Shadowsocks upstream URI contains invalid base64"
  fi
  [[ "${decoded_length}" == "32" ]] \
    || vps_die "Shadowsocks upstream URI must contain a 32-byte base64 key"

  if [[ "${endpoint}" == \[* ]]; then
    [[ "${endpoint}" == *\]:* ]] || vps_die "Shadowsocks upstream IPv6 endpoint must use [address]:port"
    address="${endpoint#\[}"
    address="${address%%\]*}"
    remainder="${endpoint#*\]}"
    [[ "${remainder}" == :* ]] || vps_die "Shadowsocks upstream IPv6 endpoint is missing a port"
    port="${remainder#:}"
    [[ "${address}" =~ ^[0-9A-Fa-f:.]+$ ]] \
      || vps_die "Shadowsocks upstream IPv6 address is invalid"
  else
    [[ "${endpoint}" == *:* ]] || vps_die "Shadowsocks upstream endpoint is missing a port"
    address="${endpoint%:*}"
    port="${endpoint##*:}"
    [[ "${address}" != *:* ]] || vps_die "Shadowsocks upstream IPv6 endpoint must be enclosed in brackets"
    [[ "${address}" =~ ^[A-Za-z0-9._-]+$ ]] \
      || vps_die "Shadowsocks upstream host is invalid"
  fi

  [[ -n "${address}" ]] || vps_die "Shadowsocks upstream host is empty"
  vps_validate_port "${port}"
  TELEMT_SS_UPSTREAM_ADDRESS="${address}"
  TELEMT_SS_UPSTREAM_PORT="${port}"
  TELEMT_SS_UPSTREAM_URI="ss://${TELEMT_SS_METHOD}:${key}@$(vps_format_uri_host "${address}"):${port}"
}

telemt_append_shadowsocks_upstream() {
  local config_file="$1"
  local uri="$2"

  [[ -n "${uri}" ]] || return 0
  telemt_parse_shadowsocks_upstream_uri "${uri}"
  printf '\n[[upstreams]]\ntype = "shadowsocks"\nurl = "%s"\nweight = 1\nenabled = true\n' \
    "${TELEMT_SS_UPSTREAM_URI}" >> "${config_file}"
}

telemt_validate_version() {
  local version="$1"

  [[ "${version}" =~ ^[A-Za-z0-9._-]+$ ]] || vps_die "TELEMT_VERSION contains invalid characters"
}

telemt_download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "${url}" -o "${output}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${output}" "${url}"
  else
    vps_die "curl or wget is required"
  fi
}

telemt_detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then
    printf '%s\n' musl
  else
    printf '%s\n' gnu
  fi
}

telemt_release_url() {
  local version="$1"
  local arch=""
  local libc=""

  telemt_validate_version "${version}"
  arch="$(uname -m)"
  libc="$(telemt_detect_libc)"
  if [[ "${version}" == "latest" ]]; then
    printf 'https://github.com/telemt/telemt/releases/latest/download/telemt-%s-linux-%s.tar.gz\n' "${arch}" "${libc}"
  else
    printf 'https://github.com/telemt/telemt/releases/download/%s/telemt-%s-linux-%s.tar.gz\n' "${version}" "${arch}" "${libc}"
  fi
}

telemt_download_binary() {
  local version="$1"
  local output="$2"
  local temp_dir=""
  local archive=""
  local url=""

  temp_dir="$(mktemp -d)"
  archive="${temp_dir}/telemt.tar.gz"
  url="$(telemt_release_url "${version}")"
  if ! telemt_download_file "${url}" "${archive}" || ! tar -xzf "${archive}" -C "${temp_dir}" || [[ ! -f "${temp_dir}/telemt" ]]; then
    rm -rf -- "${temp_dir}"
    vps_die "Telemt release archive is invalid or could not be downloaded"
  fi
  install -m 755 "${temp_dir}/telemt" "${output}"
  rm -rf -- "${temp_dir}"
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
    function flush_pending_blanks(normalize, i) {
      if (normalize) {
        print ""
      } else {
        for (i = 0; i < pending_blanks; i++) {
          print ""
        }
      }
      pending_blanks = 0
    }
    BEGIN {
      target = "[" table "]"
      in_table = 0
      found_table = 0
      wrote = 0
      pending_blanks = 0
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
      if (in_table && !wrote) {
        print "\"" key "\" = " value
        wrote = 1
        flush_pending_blanks(1)
      } else if (in_table) {
        flush_pending_blanks(0)
      }
      in_table = (current == target)
      if (in_table) {
        found_table = 1
      }
    }
    in_table && /^[[:space:]]*$/ {
      pending_blanks++
      next
    }
    in_table && pending_blanks > 0 {
      flush_pending_blanks(0)
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
        if (pending_blanks > 0) {
          flush_pending_blanks(1)
        }
      } else if (in_table) {
        flush_pending_blanks(0)
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
  local api_file=""
  local links_file="${client_dir}/telemt-${client_name}-links.txt"

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${secret}" > "${client_dir}/${client_name}.secret"
  printf '%s\n' "${max_unique_ips}" > "${client_dir}/${client_name}.max-unique-ips"
  chmod 600 "${client_dir}/${client_name}.secret" "${client_dir}/${client_name}.max-unique-ips"

  api_file="$(mktemp --suffix=.json)"
  telemt_fetch_client_api "${client_name}" "${api_file}"
  jq -r --arg name "${client_name}" '
    .data[]? | select(.username == $name) |
    (.links.tls[]? | "tls: \(.)"),
    (.links.secure[]? | "secure: \(.)"),
    (.links.classic[]? | "classic: \(.)")
  ' "${api_file}" > "${links_file}"
  chmod 600 "${links_file}"
  rm -f "${api_file}"
}
