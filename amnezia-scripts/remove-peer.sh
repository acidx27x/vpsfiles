#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

AWG_DIR="/etc/amnezia/amneziawg"

usage() {
  echo "usage: remove-peer.sh [--verbose] [--live-only] <client_name>"
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
    die "run as root: sudo ./remove-peer.sh ..."
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

remove_peer_block() {
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

main() {
  local live_only=0
  local verbose=0

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
  local pub_key_file=""
  local pub_key=""
  local awg_if=""
  local server_config=""

  require_root "$@"
  validate_client_name "${client_name}"

  awg_if="$(read_file_or_default server-interface.txt "awg0")"
  server_config="${AWG_DIR}/${awg_if}.conf"
  client_dir="clients/${client_name}"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${pub_key_file}" ]] || die "client public key is missing: ${pub_key_file}"

  pub_key="$(cat "${pub_key_file}")"

  if [[ "${live_only}" -eq 1 ]]; then
    awg set "${awg_if}" peer "${pub_key}" remove
    info "Removed live peer from ${awg_if}: ${client_name}"
    if [[ "${verbose}" -eq 1 ]]; then
      awg show "${awg_if}"
    fi
    exit 0
  fi

  [[ -f "${server_config}" ]] || die "server config is missing: ${server_config}"
  if grep -qF "${pub_key}" "${server_config}"; then
    remove_peer_block "${server_config}" "${pub_key}"
    info "Removed peer from ${server_config}: ${client_name}"
  else
    info "Peer is already absent from ${server_config}: ${client_name}"
  fi
  if [[ "${verbose}" -eq 1 ]]; then
    echo "Restart awg-quick@${awg_if} to apply this config change, or run remove-peer.sh --live-only ${client_name} to remove it from live ${awg_if} now."
  fi
}

main "$@"
