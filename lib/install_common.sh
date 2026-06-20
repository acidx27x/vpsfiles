#!/usr/bin/env bash

[[ -n "${VPS_INSTALL_COMMON_SH:-}" ]] && return 0
VPS_INSTALL_COMMON_SH=1

vps_require_supported_apt_os() {
  command -v apt-get >/dev/null 2>&1 || vps_die "this installer currently supports Debian/Ubuntu systems with apt"
}

vps_require_systemd() {
  command -v systemctl >/dev/null 2>&1 || vps_die "this installer expects systemd"
}

vps_install_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

vps_enable_sysctl_file() {
  local sysctl_file="$1"
  local contents="$2"

  printf '%s' "${contents}" > "${sysctl_file}"
  sysctl --system >/dev/null
}

vps_copy_existing_paths() {
  local backup_dir="$1"
  shift
  local path=""

  mkdir -p "${backup_dir}"
  for path in "$@"; do
    if [[ -e "${path}" ]]; then
      cp -a "${path}" "${backup_dir}/"
    fi
  done
}

vps_any_path_exists() {
  local path=""

  for path in "$@"; do
    if [[ -e "${path}" ]]; then
      return 0
    fi
  done

  return 1
}

vps_clients_dir_has_generated_files() {
  local clients_dir="$1"

  [[ -d "${clients_dir}" ]] || return 1
  [[ -n "$(find "${clients_dir}" -mindepth 1 -maxdepth 1 ! -name .gitkeep -print -quit 2>/dev/null)" ]]
}

vps_write_state_file() {
  local file="$1"
  local value="$2"

  printf '%s\n' "${value}" > "${file}"
}
