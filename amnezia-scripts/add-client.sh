#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

AWG_DIR="/etc/amnezia/amneziawg"

usage() {
  echo "usage: add-client.sh [--verbose] [--ipv6-endpoint] <client_name>"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "$*"
}

verbose() {
  if [[ "${VERBOSE}" -eq 1 ]]; then
    echo "$*"
  fi
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

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

next_ip() {
  local last_ip="$1"
  local oct1=""
  local oct2=""
  local oct3=""
  local oct4=""

  IFS=. read -r oct1 oct2 oct3 oct4 <<< "${last_ip}"
  [[ "${oct1}" =~ ^[0-9]+$ && "${oct2}" =~ ^[0-9]+$ && "${oct3}" =~ ^[0-9]+$ && "${oct4}" =~ ^[0-9]+$ ]] || die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct1 >= 0 && oct1 <= 255 && oct2 >= 0 && oct2 <= 255 && oct3 >= 0 && oct3 <= 255 )) || die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct4 >= 1 && oct4 < 254 )) || die "no usable client IPs remain after ${last_ip}"

  printf '%s.%s.%s.%s\n' "${oct1}" "${oct2}" "${oct3}" "$((oct4 + 1))"
}

next_ip6() {
  local last_ip="$1"
  local prefix=""
  local suffix=""
  local next_suffix=""

  [[ "${last_ip}" == *:* ]] || die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"

  prefix="${last_ip%:*}"
  suffix="${last_ip##*:}"

  if [[ -z "${suffix}" ]]; then
    die "last-ip6.txt must include a host segment, for example fd52:52:52::1"
  fi
  [[ "${suffix}" =~ ^[0-9A-Fa-f]+$ ]] || die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"
  (( 16#${suffix} < 16#ffff )) || die "no usable IPv6 client IPs remain after ${last_ip}"

  printf -v next_suffix '%x' "$((16#${suffix} + 1))"
  printf '%s:%s\n' "${prefix}" "${next_suffix}"
}

client_exists_with_ip() {
  local ip="$1"
  local conf_file=""

  while IFS= read -r conf_file; do
    if grep -qF "${ip}/" "${conf_file}"; then
      return 0
    fi
  done < <(find clients -mindepth 2 -maxdepth 2 -name 'awg0*conf' -type f 2>/dev/null)

  return 1
}

format_endpoint() {
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

load_obfuscation_params() {
  [[ -f obfuscation.env ]] || die "obfuscation.env is missing; run install.sh first"
  # shellcheck source=/dev/null
  . ./obfuscation.env
}

sed_escape() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

main() {
  local endpoint_source="ipv4"
  VERBOSE=0

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
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    usage
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
  local awg_if=""
  local server_config=""
  local add_peer_args=()

  require_root "$@"
  validate_client_name "${client_name}"
  load_obfuscation_params

  awg_if="$(read_file_or_default server-interface.txt "awg0")"
  server_config="${AWG_DIR}/${awg_if}.conf"
  [[ -f last-ip.txt ]] || die "last-ip.txt is missing; run install.sh first or create it with the server VPN IP"
  [[ -f last-ip6.txt ]] || die "last-ip6.txt is missing; run install.sh first or create it with the server IPv6 VPN IP"
  [[ -f awg0-client.example.conf ]] || die "awg0-client.example.conf is missing"
  [[ -f "${AWG_DIR}/server_public_key" ]] || die "${AWG_DIR}/server_public_key is missing"
  [[ -f "${server_config}" ]] || die "${server_config} is missing"

  client_dir="clients/${client_name}"
  [[ ! -e "${client_dir}" ]] || die "client already exists: ${client_name}"

  info "Creating client config for: ${client_name}"
  last_ip="$(cat last-ip.txt)"
  last_ip6="$(cat last-ip6.txt)"
  ip="$(next_ip "${last_ip}")"
  ip6="$(next_ip6 "${last_ip6}")"

  if client_exists_with_ip "${ip}" >/dev/null; then
    die "next IP is already used by another client: ${ip}"
  fi
  if client_exists_with_ip "${ip6}" >/dev/null; then
    die "next IPv6 is already used by another client: ${ip6}"
  fi

  server_port="$(read_file_or_default server-port.txt "52820")"
  case "${endpoint_source}" in
    ipv6)
      [[ -f server-endpoint6.txt ]] || die "server-endpoint6.txt is missing; run install.sh again or create it with the public IPv6 endpoint"
      endpoint="$(cat server-endpoint6.txt)"
      [[ -n "${endpoint}" ]] || die "server-endpoint6.txt is empty"
      ;;
    *)
      endpoint="$(read_file_or_default server-endpoint.txt "$(hostname -f)")"
      ;;
  esac
  server_endpoint="$(format_endpoint "${endpoint}" "${server_port}")"
  server_net="$(read_file_or_default server-net.txt "10.9.0.0/24")"
  server_net6="$(read_file_or_default server-net6.txt "fd52:52:52::/64")"
  server_pub_key="$(cat "${AWG_DIR}/server_public_key")"

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  (
    umask 077
    awg genkey | tee "${client_dir}/${client_name}.priv" | awg pubkey > "${client_dir}/${client_name}.pub"
    awg genpsk > "${client_dir}/${client_name}.psk"
  )
  key="$(cat "${client_dir}/${client_name}.priv")"
  psk="$(cat "${client_dir}/${client_name}.psk")"

  sed \
    -e "s|:CLIENT_NAME:|$(sed_escape "${client_name}")|g" \
    -e "s|:CLIENT_IP:|$(sed_escape "${ip}")|g" \
    -e "s|:CLIENT_IP6:|$(sed_escape "${ip6}")|g" \
    -e "s|:CLIENT_KEY:|$(sed_escape "${key}")|g" \
    -e "s|:SERVER_PUB_KEY:|$(sed_escape "${server_pub_key}")|g" \
    -e "s|:PRESHARED_KEY:|$(sed_escape "${psk}")|g" \
    -e "s|:SERVER_ENDPOINT:|$(sed_escape "${server_endpoint}")|g" \
    -e "s|:SERVER_NET:|$(sed_escape "${server_net}")|g" \
    -e "s|:SERVER_NET6:|$(sed_escape "${server_net6}")|g" \
    -e "s|:AWG_MTU:|$(sed_escape "${AWG_MTU}")|g" \
    -e "s|:AWG_JC:|$(sed_escape "${AWG_JC}")|g" \
    -e "s|:AWG_JMIN:|$(sed_escape "${AWG_JMIN}")|g" \
    -e "s|:AWG_JMAX:|$(sed_escape "${AWG_JMAX}")|g" \
    -e "s|:AWG_S1:|$(sed_escape "${AWG_S1}")|g" \
    -e "s|:AWG_S2:|$(sed_escape "${AWG_S2}")|g" \
    -e "s|:AWG_S3:|$(sed_escape "${AWG_S3}")|g" \
    -e "s|:AWG_S4:|$(sed_escape "${AWG_S4}")|g" \
    -e "s|:AWG_H1:|$(sed_escape "${AWG_H1}")|g" \
    -e "s|:AWG_H2:|$(sed_escape "${AWG_H2}")|g" \
    -e "s|:AWG_H3:|$(sed_escape "${AWG_H3}")|g" \
    -e "s|:AWG_H4:|$(sed_escape "${AWG_H4}")|g" \
    -e "s|:AWG_I1:|$(sed_escape "${AWG_I1}")|g" \
    awg0-client.example.conf > "${client_dir}/awg0-${client_name}.conf"
  chmod 600 "${client_dir}/awg0-${client_name}.conf"

  add_peer_args=()
  if [[ "${VERBOSE}" -eq 1 ]]; then
    add_peer_args+=(--verbose)
  fi

  info "Adding peer to ${server_config}"
  bash "${SCRIPT_DIR}/add-peer.sh" "${add_peer_args[@]}" "${client_name}"

  printf '%s\n' "${ip}" > last-ip.txt
  printf '%s\n' "${ip6}" > last-ip6.txt

  if ! bash "${SCRIPT_DIR}/add-peer.sh" "${add_peer_args[@]}" --live-only "${client_name}"; then
    echo "WARNING: peer was added to ${server_config} but not to live ${awg_if}"
  fi

  info "Adding client to hosts file"
  if ! awk -v ip="${ip}" -v name="${client_name}" '$1 == ip && $2 == name { found = 1 } END { exit !found }' /etc/hosts 2>/dev/null; then
    printf '%s %s\n' "${ip}" "${client_name}" >> /etc/hosts
  fi

  info "Created config: ${client_dir}/awg0-${client_name}.conf"
  if command -v qrencode >/dev/null 2>&1; then
    if [[ "${VERBOSE}" -eq 1 ]]; then
      qrencode -t ansiutf8 < "${client_dir}/awg0-${client_name}.conf" | tee "${client_dir}/awg0-${client_name}-qrcode.txt"
    else
      qrencode -t ansiutf8 < "${client_dir}/awg0-${client_name}.conf" > "${client_dir}/awg0-${client_name}-qrcode.txt"
    fi
    chmod 600 "${client_dir}/awg0-${client_name}-qrcode.txt"
    info "Created QR code text: ${client_dir}/awg0-${client_name}-qrcode.txt"
  fi
  verbose "AmneziaWG interface: ${awg_if}"
}

main "$@"
