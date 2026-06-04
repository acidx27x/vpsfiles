#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

AWG_DIR="/etc/amnezia/amneziawg"

usage() {
  echo "usage: add-peer.sh [--verbose] [--live-only] <client_name>"
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
    die "run as root: sudo ./add-peer.sh ..."
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

client_ip() {
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

client_ip6() {
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

add_peer_block() {
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
    printf '# %s\n' "${client_name}"
    printf 'PublicKey = %s\n' "${pub_key}"
    printf 'PresharedKey = %s\n' "${psk}"
    printf 'AllowedIPs = %s\n' "${allowed_ips}"
  } >> "${tmp_file}"

  install -m 600 "${tmp_file}" "${server_config}"
  rm -f "${tmp_file}"
}

main() {
  local live_only=0
  VERBOSE=0

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
  local client_conf=""
  local pub_key_file=""
  local psk_file=""
  local pub_key=""
  local psk=""
  local ip=""
  local ip6=""
  local allowed_ips=""
  local awg_if=""
  local server_config=""

  require_root "$@"
  validate_client_name "${client_name}"

  awg_if="$(read_file_or_default server-interface.txt "awg0")"
  server_config="${AWG_DIR}/${awg_if}.conf"
  client_dir="clients/${client_name}"
  client_conf="${client_dir}/awg0.conf"
  pub_key_file="${client_dir}/${client_name}.pub"
  psk_file="${client_dir}/${client_name}.psk"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${client_conf}" ]] || die "client config is missing: ${client_conf}"
  [[ -f "${pub_key_file}" ]] || die "client public key is missing: ${pub_key_file}"
  [[ -f "${psk_file}" ]] || die "client preshared key is missing: ${psk_file}; recreate the client with add-client.sh"

  pub_key="$(cat "${pub_key_file}")"
  psk="$(cat "${psk_file}")"
  ip="$(client_ip "${client_conf}")"
  ip6="$(client_ip6 "${client_conf}")"
  [[ -n "${ip}" ]] || die "could not read client IP from ${client_conf}"
  allowed_ips="${ip}/32"
  if [[ -n "${ip6}" ]]; then
    allowed_ips="${allowed_ips},${ip6}/128"
  fi

  if [[ "${live_only}" -eq 1 ]]; then
    awg set "${awg_if}" peer "${pub_key}" preshared-key "${psk_file}" allowed-ips "${allowed_ips}"
    info "Added live peer to ${awg_if}: ${client_name}"
    if [[ "${VERBOSE}" -eq 1 ]]; then
      awg show "${awg_if}"
    fi
    exit 0
  fi

  [[ -f "${server_config}" ]] || die "server config is missing: ${server_config}"

  if grep -qF "${pub_key}" "${server_config}"; then
    info "Peer is already present in ${server_config}"
  else
    if grep -qF "AllowedIPs = ${ip}/32" "${server_config}"; then
      die "another peer already uses ${ip}/32 in ${server_config}"
    fi
    if [[ -n "${ip6}" ]] && grep -qF "${ip6}/128" "${server_config}"; then
      die "another peer already uses ${ip6}/128 in ${server_config}"
    fi

    add_peer_block "${server_config}" "${client_name}" "${pub_key}" "${psk}" "${allowed_ips}"
    info "Added peer to ${server_config}: ${client_name}"
  fi

  verbose "Restart awg-quick@${awg_if} to apply this config change, or run add-peer.sh --live-only ${client_name} to add it to live ${awg_if} now."
}

main "$@"
