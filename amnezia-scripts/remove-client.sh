#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  echo "usage: remove-client.sh [--verbose] <client_name>"
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

remove_client_dir() {
  local client_dir="$1"

  [[ "${client_dir}" == clients/* ]] || die "refusing to remove unexpected path: ${client_dir}"
  [[ -d "${client_dir}" ]] || return 0
  rm -rf "${client_dir}"
}

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

client_ip() {
  local client_conf="$1"

  awk -F'[ =/]+' '$1 == "Address" {print $2; exit}' "${client_conf}"
}

remove_hosts_entry() {
  local ip="$1"
  local client_name="$2"
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk -v ip="${ip}" -v name="${client_name}" '$1 == ip && $2 == name { next } { print }' /etc/hosts > "${tmp_file}"
  install -m 644 "${tmp_file}" /etc/hosts
  rm -f "${tmp_file}"
}

main() {
  local verbose=0

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
  local ip=""
  local remove_peer_args=()

  require_root "$@"
  validate_client_name "${client_name}"

  client_dir="clients/${client_name}"
  client_conf="${client_dir}/awg0.conf"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${pub_key_file}" ]] || die "client public key is missing: ${pub_key_file}"

  if [[ -f "${client_conf}" ]]; then
    ip="$(client_ip "${client_conf}")"
  fi

  if [[ "${verbose}" -eq 1 ]]; then
    remove_peer_args+=(--verbose)
  fi

  info "Removing peer from server config"
  bash "${SCRIPT_DIR}/remove-peer.sh" "${remove_peer_args[@]}" "${client_name}"
  info "Removing live peer if present"
  bash "${SCRIPT_DIR}/remove-peer.sh" "${remove_peer_args[@]}" --live-only "${client_name}" || true

  if [[ -n "${ip}" ]]; then
    remove_hosts_entry "${ip}" "${client_name}" || true
  fi

  remove_client_dir "${client_dir}"
  info "Removed client files for: ${client_name}"
}

main "$@"
