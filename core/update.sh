#!/usr/bin/env bash

[[ -n "${VPS_UPDATE_SH:-}" ]] && return 0
VPS_UPDATE_SH=1

vps_update_packages() {
  vps_require_supported_apt_os
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$@"
}

vps_service_is_active() {
  local service="$1"

  systemctl is-active --quiet "${service}"
}

vps_restart_active_service() {
  local service="$1"

  systemctl restart "${service}" || return 1
  systemctl is-active --quiet "${service}"
}
