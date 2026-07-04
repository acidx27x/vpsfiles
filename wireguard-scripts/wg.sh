#!/usr/bin/env bash

[[ -n "${VPS_WG_FAMILY_SH:-}" ]] && return 0
VPS_WG_FAMILY_SH=1

wg_family_require_settings() {
  : "${WG_FAMILY_NAME:?WG_FAMILY_NAME is required}"
  : "${WG_FAMILY_TOOL:?WG_FAMILY_TOOL is required}"
  : "${WG_FAMILY_QUICK:?WG_FAMILY_QUICK is required}"
  : "${WG_FAMILY_DIR:?WG_FAMILY_DIR is required}"
  : "${WG_FAMILY_DEFAULT_IF:?WG_FAMILY_DEFAULT_IF is required}"
  : "${WG_FAMILY_CLIENT_PREFIX:?WG_FAMILY_CLIENT_PREFIX is required}"
  : "${WG_FAMILY_DEFAULT_PORT:?WG_FAMILY_DEFAULT_PORT is required}"
  : "${WG_FAMILY_DEFAULT_NET:?WG_FAMILY_DEFAULT_NET is required}"
  : "${WG_FAMILY_DEFAULT_NET6:?WG_FAMILY_DEFAULT_NET6 is required}"
  : "${SCRIPT_DIR:?SCRIPT_DIR is required}"
}

wg_family_next_ip() {
  local last_ip="$1"
  local oct1=""
  local oct2=""
  local oct3=""
  local oct4=""

  IFS=. read -r oct1 oct2 oct3 oct4 <<< "${last_ip}"
  [[ "${oct1}" =~ ^[0-9]+$ && "${oct2}" =~ ^[0-9]+$ && "${oct3}" =~ ^[0-9]+$ && "${oct4}" =~ ^[0-9]+$ ]] || vps_die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct1 >= 0 && oct1 <= 255 && oct2 >= 0 && oct2 <= 255 && oct3 >= 0 && oct3 <= 255 )) || vps_die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct4 >= 1 && oct4 < 254 )) || vps_die "no usable client IPs remain after ${last_ip}"

  printf '%s.%s.%s.%s\n' "${oct1}" "${oct2}" "${oct3}" "$((oct4 + 1))"
}

wg_family_next_ip6() {
  local last_ip="$1"
  local prefix=""
  local suffix=""
  local next_suffix=""

  [[ "${last_ip}" == *:* ]] || vps_die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"

  prefix="${last_ip%:*}"
  suffix="${last_ip##*:}"

  if [[ -z "${suffix}" ]]; then
    vps_die "last-ip6.txt must include a host segment, for example fd42:42:42::1"
  fi
  [[ "${suffix}" =~ ^[0-9A-Fa-f]+$ ]] || vps_die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"
  (( 16#${suffix} < 16#ffff )) || vps_die "no usable IPv6 client IPs remain after ${last_ip}"

  printf -v next_suffix '%x' "$((16#${suffix} + 1))"
  printf '%s:%s\n' "${prefix}" "${next_suffix}"
}

wg_family_client_exists_with_ip() {
  local ip="$1"
  local conf_file=""

  while IFS= read -r conf_file; do
    if grep -qF "${ip}/" "${conf_file}"; then
      return 0
    fi
  done < <(find clients -mindepth 2 -maxdepth 2 -name "${WG_FAMILY_CLIENT_PREFIX}*conf" -type f 2>/dev/null)

  return 1
}

wg_family_client_ip() {
  local client_conf="$1"

  awk -F= '
    $1 ~ /^[[:space:]]*Address[[:space:]]*$/ {
      split($2, addresses, ",")
      for (i in addresses) {
        address = addresses[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", address)
        split(address, parts, "/")
        if (index(parts[1], ":") == 0) {
          print parts[1]
          exit
        }
      }
    }
  ' "${client_conf}"
}

wg_family_client_ip6() {
  local client_conf="$1"

  awk -F= '
    $1 ~ /^[[:space:]]*Address[[:space:]]*$/ {
      split($2, addresses, ",")
      for (i in addresses) {
        address = addresses[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", address)
        split(address, parts, "/")
        if (index(parts[1], ":") > 0) {
          print parts[1]
          exit
        }
      }
    }
  ' "${client_conf}"
}

wg_family_add_peer_block() {
  local server_config="$1"
  local client_name="$2"
  local pub_key="$3"
  local psk="$4"
  local allowed_ips="$5"
  local tmp_file=""

  tmp_file="$(mktemp)"
  cp "${server_config}" "${tmp_file}"
  {
    printf '\n[Peer]\n'
    printf '# Client: %s\n' "${client_name}"
    printf 'PublicKey = %s\n' "${pub_key}"
    printf 'PresharedKey = %s\n' "${psk}"
    printf 'AllowedIPs = %s\n' "${allowed_ips}"
  } >> "${tmp_file}"

  install -m 600 "${tmp_file}" "${server_config}"
  rm -f "${tmp_file}"
}

wg_family_remove_peer_block() {
  local server_config="$1"
  local pub_key="$2"
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk -v pub_key="${pub_key}" '
    /^\[Peer\]$/ {
      if (block != "" && index(block, pub_key) == 0) {
        printf "%s", block
      }
      block = $0 "\n"
      in_peer = 1
      next
    }
    in_peer {
      block = block $0 "\n"
      next
    }
    {
      printf "%s\n", $0
    }
    END {
      if (in_peer && block != "" && index(block, pub_key) == 0) {
        printf "%s", block
      }
    }
  ' "${server_config}" > "${tmp_file}"

  install -m 600 "${tmp_file}" "${server_config}"
  rm -f "${tmp_file}"
}

wg_family_load_optional_client_state() {
  if declare -F wg_family_protocol_load_client_state >/dev/null; then
    wg_family_protocol_load_client_state
  fi
}

wg_family_add_protocol_sed_args() {
  if declare -F wg_family_protocol_add_client_sed_args >/dev/null; then
    wg_family_protocol_add_client_sed_args
  fi
}

wg_family_hosts_file() {
  printf '%s\n' "${WG_FAMILY_HOSTS_FILE:-/etc/hosts}"
}

wg_family_add_hosts_entry() {
  local ip="$1"
  local client_name="$2"
  local hosts_file=""

  hosts_file="$(wg_family_hosts_file)"
  if ! awk -v ip="${ip}" -v name="${client_name}" '$1 == ip && $2 == name && NF == 2 { found = 1 } END { exit !found }' "${hosts_file}" 2>/dev/null; then
    printf '%s %s\n' "${ip}" "${client_name}" >> "${hosts_file}"
  fi
}

wg_family_remove_hosts_entry() {
  local ip="$1"
  local client_name="$2"
  local hosts_file=""
  local tmp_file=""

  hosts_file="$(wg_family_hosts_file)"
  [[ -f "${hosts_file}" ]] || return 0

  tmp_file="$(mktemp)"
  awk -v ip="${ip}" -v name="${client_name}" '$1 == ip && $2 == name && NF == 2 { next } { print }' "${hosts_file}" > "${tmp_file}"
  install -m 644 "${tmp_file}" "${hosts_file}"
  rm -f "${tmp_file}"
}

wg_family_remove_generated_hosts_entries() {
  local clients_dir="${CLIENTS_DIR:-clients}"
  local client_conf=""
  local client_dir=""
  local client_name=""
  local ip=""

  [[ -d "${clients_dir}" ]] || return 0

  while IFS= read -r client_conf; do
    client_dir="$(dirname "${client_conf}")"
    client_name="$(basename "${client_dir}")"
    ip="$(wg_family_client_ip "${client_conf}")"
    if [[ -n "${ip}" ]]; then
      wg_family_remove_hosts_entry "${ip}" "${client_name}" || true
    fi
  done < <(find "${clients_dir}" -mindepth 2 -maxdepth 2 -name "${WG_FAMILY_CLIENT_PREFIX}-*.conf" -type f 2>/dev/null)
}

wg_family_add_client_main() {
  local endpoint_source="ipv4"
  VERBOSE=0

  wg_family_require_settings

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        VERBOSE=1
        shift
        ;;
      --ipv6-endpoint)
        endpoint_source="ipv6"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'usage: add-client.sh [--verbose] [--ipv6-endpoint] <client_name>\n'
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    printf 'usage: add-client.sh [--verbose] [--ipv6-endpoint] <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local key=""
  local psk=""
  local last_ip=""
  local last_ip6=""
  local ip=""
  local ip6=""
  local endpoint=""
  local server_endpoint=""
  local server_port=""
  local server_net=""
  local server_net6=""
  local server_pub_key=""
  local iface=""
  local server_config=""
  local client_template="${SCRIPT_DIR}/${WG_FAMILY_CLIENT_PREFIX}-client.example.conf"
  local client_conf=""
  local add_peer_args=()
  local sed_args=()

  vps_require_root "sudo ./add-client.sh ..."
  vps_validate_client_name "${client_name}"
  wg_family_load_optional_client_state

  iface="$(vps_read_file_or_default server-interface.txt "${WG_FAMILY_DEFAULT_IF}")"
  server_config="${WG_FAMILY_DIR}/${iface}.conf"
  [[ -f last-ip.txt ]] || vps_die "last-ip.txt is missing; run install.sh first or create it with the server VPN IP"
  [[ -f last-ip6.txt ]] || vps_die "last-ip6.txt is missing; run install.sh first or create it with the server IPv6 VPN IP"
  [[ -f "${client_template}" ]] || vps_die "$(basename "${client_template}") is missing"
  [[ -f "${WG_FAMILY_DIR}/server_public_key" ]] || vps_die "${WG_FAMILY_DIR}/server_public_key is missing"
  [[ -f "${server_config}" ]] || vps_die "${server_config} is missing"

  client_dir="clients/${client_name}"
  [[ ! -e "${client_dir}" ]] || vps_die "client already exists: ${client_name}"

  vps_info "Creating client config for: ${client_name}"
  last_ip="$(cat last-ip.txt)"
  last_ip6="$(cat last-ip6.txt)"
  ip="$(wg_family_next_ip "${last_ip}")"
  ip6="$(wg_family_next_ip6 "${last_ip6}")"

  wg_family_client_exists_with_ip "${ip}" && vps_die "next IP is already used by another client: ${ip}"
  wg_family_client_exists_with_ip "${ip6}" && vps_die "next IPv6 is already used by another client: ${ip6}"

  server_port="$(vps_read_file_or_default server-port.txt "${WG_FAMILY_DEFAULT_PORT}")"
  vps_validate_port "${server_port}"
  case "${endpoint_source}" in
    ipv6)
      [[ -f server-endpoint6.txt ]] || vps_die "server-endpoint6.txt is missing; run install.sh again or create it with the public IPv6 endpoint"
      endpoint="$(cat server-endpoint6.txt)"
      [[ -n "${endpoint}" ]] || vps_die "server-endpoint6.txt is empty"
      ;;
    *)
      endpoint="$(vps_read_file_or_default server-endpoint.txt "$(hostname -f)")"
      [[ -n "${endpoint}" ]] || vps_die "server endpoint is empty; run install.sh again or create server-endpoint.txt with the public endpoint"
      ;;
  esac
  server_endpoint="$(vps_format_endpoint "${endpoint}" "${server_port}")"
  server_net="$(vps_read_file_or_default server-net.txt "${WG_FAMILY_DEFAULT_NET}")"
  server_net6="$(vps_read_file_or_default server-net6.txt "${WG_FAMILY_DEFAULT_NET6}")"
  server_pub_key="$(cat "${WG_FAMILY_DIR}/server_public_key")"

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  (
    umask 077
    "${WG_FAMILY_TOOL}" genkey | tee "${client_dir}/${client_name}.priv" | "${WG_FAMILY_TOOL}" pubkey > "${client_dir}/${client_name}.pub"
    "${WG_FAMILY_TOOL}" genpsk > "${client_dir}/${client_name}.psk"
  )
  key="$(cat "${client_dir}/${client_name}.priv")"
  psk="$(cat "${client_dir}/${client_name}.psk")"

  sed_args=(
    -e "s|:CLIENT_NAME:|$(vps_sed_escape "${client_name}")|g"
    -e "s|:CLIENT_IP:|$(vps_sed_escape "${ip}")|g"
    -e "s|:CLIENT_IP6:|$(vps_sed_escape "${ip6}")|g"
    -e "s|:CLIENT_KEY:|$(vps_sed_escape "${key}")|g"
    -e "s|:SERVER_PUB_KEY:|$(vps_sed_escape "${server_pub_key}")|g"
    -e "s|:PRESHARED_KEY:|$(vps_sed_escape "${psk}")|g"
    -e "s|:SERVER_ENDPOINT:|$(vps_sed_escape "${server_endpoint}")|g"
    -e "s|:SERVER_NET:|$(vps_sed_escape "${server_net}")|g"
    -e "s|:SERVER_NET6:|$(vps_sed_escape "${server_net6}")|g"
  )
  WG_FAMILY_CLIENT_SED_ARGS=("${sed_args[@]}")
  wg_family_add_protocol_sed_args

  client_conf="${client_dir}/${WG_FAMILY_CLIENT_PREFIX}-${client_name}.conf"
  sed "${WG_FAMILY_CLIENT_SED_ARGS[@]}" "${client_template}" > "${client_conf}"
  chmod 600 "${client_conf}"
  rm -f "${client_dir}/${client_name}.priv"

  add_peer_args=()
  if [[ "${VERBOSE}" -eq 1 ]]; then
    add_peer_args+=(--verbose)
  fi

  vps_info "Adding peer to ${server_config}"
  bash "${SCRIPT_DIR}/add-peer.sh" "${add_peer_args[@]}" --config-only "${client_name}"

  printf '%s\n' "${ip}" > last-ip.txt
  printf '%s\n' "${ip6}" > last-ip6.txt

  if ! bash "${SCRIPT_DIR}/add-peer.sh" "${add_peer_args[@]}" --live-only "${client_name}"; then
    printf 'WARNING: peer was added to %s but not to live %s\n' "${server_config}" "${iface}"
  fi

  vps_info "Adding client to hosts file"
  wg_family_add_hosts_entry "${ip}" "${client_name}"

  vps_info "Created config: ${client_conf}"
  vps_verbose "${WG_FAMILY_NAME} interface: ${iface}"
}

wg_family_add_peer_main() {
  local live_only=0
  local config_only=0
  local usage='usage: add-peer.sh [--verbose] [--config-only|--live-only] <client_name>'
  VERBOSE=0

  wg_family_require_settings

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        VERBOSE=1
        shift
        ;;
      --live-only)
        live_only=1
        shift
        ;;
      --config-only)
        config_only=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf '%s\n' "${usage}"
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${live_only}" -eq 1 && "${config_only}" -eq 1 ]]; then
    printf '%s\n' "${usage}"
    exit 1
  fi

  if [[ $# -ne 1 ]]; then
    printf '%s\n' "${usage}"
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local client_conf=""
  local pub_key_file=""
  local psk_file=""
  local pub_key=""
  local psk=""
  local ip=""
  local ip6=""
  local allowed_ips=""
  local iface=""
  local server_config=""
  local config_status=""

  vps_require_root "sudo ./add-peer.sh ..."
  vps_validate_client_name "${client_name}"

  iface="$(vps_read_file_or_default server-interface.txt "${WG_FAMILY_DEFAULT_IF}")"
  server_config="${WG_FAMILY_DIR}/${iface}.conf"
  client_dir="clients/${client_name}"
  client_conf="${client_dir}/${WG_FAMILY_CLIENT_PREFIX}-${client_name}.conf"
  pub_key_file="${client_dir}/${client_name}.pub"
  psk_file="${client_dir}/${client_name}.psk"

  [[ -d "${client_dir}" ]] || vps_die "client does not exist: ${client_name}"
  [[ -f "${client_conf}" ]] || vps_die "client config is missing: ${client_conf}"
  [[ -f "${pub_key_file}" ]] || vps_die "client public key is missing: ${pub_key_file}"
  [[ -f "${psk_file}" ]] || vps_die "client preshared key is missing: ${psk_file}; recreate the client with add-client.sh"

  pub_key="$(cat "${pub_key_file}")"
  psk="$(cat "${psk_file}")"
  ip="$(wg_family_client_ip "${client_conf}")"
  ip6="$(wg_family_client_ip6 "${client_conf}")"
  [[ -n "${ip}" ]] || vps_die "could not read client IP from ${client_conf}"
  allowed_ips="${ip}/32"
  if [[ -n "${ip6}" ]]; then
    allowed_ips="${allowed_ips},${ip6}/128"
  fi

  if [[ "${live_only}" -eq 1 ]]; then
    "${WG_FAMILY_TOOL}" set "${iface}" peer "${pub_key}" preshared-key "${psk_file}" allowed-ips "${allowed_ips}"
    vps_info "Added live peer to ${iface}: ${client_name}"
    if [[ "${VERBOSE}" -eq 1 ]]; then
      "${WG_FAMILY_TOOL}" show "${iface}"
    fi
    exit 0
  fi

  [[ -f "${server_config}" ]] || vps_die "server config is missing: ${server_config}"

  if grep -qF "${pub_key}" "${server_config}"; then
    vps_info "Peer is already present in ${server_config}"
    config_status="already present in ${server_config}"
  else
    grep -qF "AllowedIPs = ${ip}/32" "${server_config}" && vps_die "another peer already uses ${ip}/32 in ${server_config}"
    [[ -n "${ip6}" ]] && grep -qF "${ip6}/128" "${server_config}" && vps_die "another peer already uses ${ip6}/128 in ${server_config}"

    wg_family_add_peer_block "${server_config}" "${client_name}" "${pub_key}" "${psk}" "${allowed_ips}"
    vps_info "Added peer to ${server_config}: ${client_name}"
    config_status="updated in ${server_config}"
  fi

  if [[ "${config_only}" -eq 1 ]]; then
    vps_verbose "Restart ${WG_FAMILY_QUICK}@${iface} to apply this config change, or run add-peer.sh --live-only ${client_name} to add it to live ${iface} now."
    return 0
  fi

  if ! "${WG_FAMILY_TOOL}" set "${iface}" peer "${pub_key}" preshared-key "${psk_file}" allowed-ips "${allowed_ips}"; then
    vps_die "peer config was ${config_status}, but live update failed for ${iface}: ${client_name}"
  fi
  vps_info "Added live peer to ${iface}: ${client_name}"
  if [[ "${VERBOSE}" -eq 1 ]]; then
    "${WG_FAMILY_TOOL}" show "${iface}"
  fi
}

wg_family_remove_peer_main() {
  local live_only=0
  local config_only=0
  local verbose=0
  local usage='usage: remove-peer.sh [--verbose] [--config-only|--live-only] <client_name>'

  wg_family_require_settings

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        verbose=1
        shift
        ;;
      --live-only)
        live_only=1
        shift
        ;;
      --config-only)
        config_only=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf '%s\n' "${usage}"
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "${live_only}" -eq 1 && "${config_only}" -eq 1 ]]; then
    printf '%s\n' "${usage}"
    exit 1
  fi

  if [[ $# -ne 1 ]]; then
    printf '%s\n' "${usage}"
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local pub_key_file=""
  local pub_key=""
  local iface=""
  local server_config=""
  local config_status=""

  vps_require_root "sudo ./remove-peer.sh ..."
  vps_validate_client_name "${client_name}"

  iface="$(vps_read_file_or_default server-interface.txt "${WG_FAMILY_DEFAULT_IF}")"
  server_config="${WG_FAMILY_DIR}/${iface}.conf"
  client_dir="clients/${client_name}"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || vps_die "client does not exist: ${client_name}"
  [[ -f "${pub_key_file}" ]] || vps_die "client public key is missing: ${pub_key_file}"

  pub_key="$(cat "${pub_key_file}")"

  if [[ "${live_only}" -eq 1 ]]; then
    "${WG_FAMILY_TOOL}" set "${iface}" peer "${pub_key}" remove
    vps_info "Removed live peer from ${iface}: ${client_name}"
    if [[ "${verbose}" -eq 1 ]]; then
      "${WG_FAMILY_TOOL}" show "${iface}"
    fi
    exit 0
  fi

  [[ -f "${server_config}" ]] || vps_die "server config is missing: ${server_config}"
  if grep -qF "${pub_key}" "${server_config}"; then
    wg_family_remove_peer_block "${server_config}" "${pub_key}"
    vps_info "Removed peer from ${server_config}: ${client_name}"
    config_status="removed from ${server_config}"
  else
    vps_info "Peer is already absent from ${server_config}: ${client_name}"
    config_status="already absent from ${server_config}"
  fi

  if [[ "${config_only}" -eq 1 ]]; then
    if [[ "${verbose}" -eq 1 ]]; then
      printf 'Restart %s@%s to apply this config change, or run remove-peer.sh --live-only %s to remove it from live %s now.\n' "${WG_FAMILY_QUICK}" "${iface}" "${client_name}" "${iface}"
    fi
    return 0
  fi

  if ! "${WG_FAMILY_TOOL}" set "${iface}" peer "${pub_key}" remove; then
    vps_die "peer config was ${config_status}, but live update failed for ${iface}: ${client_name}"
  fi
  vps_info "Removed live peer from ${iface}: ${client_name}"
  if [[ "${verbose}" -eq 1 ]]; then
    "${WG_FAMILY_TOOL}" show "${iface}"
  fi
}

wg_family_remove_client_main() {
  local verbose=0

  wg_family_require_settings

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        verbose=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        printf 'usage: remove-client.sh [--verbose] <client_name>\n'
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    printf 'usage: remove-client.sh [--verbose] <client_name>\n'
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local client_conf=""
  local pub_key_file=""
  local ip=""
  local remove_peer_args=()

  vps_require_root "sudo ./remove-client.sh ..."
  vps_validate_client_name "${client_name}"

  client_dir="clients/${client_name}"
  client_conf="${client_dir}/${WG_FAMILY_CLIENT_PREFIX}-${client_name}.conf"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || vps_die "client does not exist: ${client_name}"
  [[ -f "${pub_key_file}" ]] || vps_die "client public key is missing: ${pub_key_file}"

  if [[ -f "${client_conf}" ]]; then
    ip="$(awk -F'[ =/]+' '$1 == "Address" {print $2; exit}' "${client_conf}")"
  fi

  if [[ "${verbose}" -eq 1 ]]; then
    remove_peer_args+=(--verbose)
  fi

  vps_info "Removing peer from server config"
  bash "${SCRIPT_DIR}/remove-peer.sh" "${remove_peer_args[@]}" --config-only "${client_name}"
  vps_info "Removing live peer if present"
  bash "${SCRIPT_DIR}/remove-peer.sh" "${remove_peer_args[@]}" --live-only "${client_name}" || true

  if [[ -n "${ip}" ]]; then
    wg_family_remove_hosts_entry "${ip}" "${client_name}" || true
  fi

  vps_safe_remove_client_dir "${client_dir}" "clients"
  vps_info "Removed client files for: ${client_name}"
}
