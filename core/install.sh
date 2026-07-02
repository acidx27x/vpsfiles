#!/usr/bin/env bash

[[ -n "${VPS_INSTALL_SH:-}" ]] && return 0
VPS_INSTALL_SH=1

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
