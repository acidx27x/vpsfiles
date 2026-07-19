#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/update.sh
. "${REPO_ROOT}/core/update.sh"
# shellcheck source=xray-scripts/xray.sh
. "${SCRIPT_DIR}/xray.sh"

restore_previous_xray_update() {
  local backup_dir="$1"
  local xray_bin="$2"
  local asset_dir="$3"
  local asset=""

  install -m 755 "${backup_dir}/xray" "${xray_bin}" || return 1
  for asset in geoip.dat geosite.dat; do
    if [[ -f "${backup_dir}/${asset}" ]]; then
      cp -a "${backup_dir}/${asset}" "${asset_dir}/${asset}" || return 1
    fi
  done
}

main() {
  local config_file=""
  local service=""
  local xray_bin=""
  local asset=""
  local asset_dir="${XRAY_GEODATA_DIR_DEFAULT}"
  local backup_dir=""
  local backup_bin=""
  local update_failed=0
  local was_active=0

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_require_root "sudo ./update.sh"
  vps_require_systemd
  vps_require_commands xray curl systemctl
  [[ -f xray-config-path.txt && -f xray-service.txt ]] || vps_die "Xray state is missing; run install.sh first"
  config_file="$(<xray-config-path.txt)"
  service="$(<xray-service.txt)"
  [[ -f "${config_file}" ]] || vps_die "Xray server config is missing: ${config_file}"
  [[ "${service}" =~ ^[A-Za-z0-9_.@-]+$ ]] || vps_die "saved Xray service name is invalid"
  xray_bin="$(command -v xray)"
  if vps_service_is_active "${service}"; then
    was_active=1
  fi

  printf 'This will upgrade Xray and its required packages without changing server configuration, keys, clients, endpoints, UFW, or sysctl state.\n'
  printf 'Active service: %s\n' "${service}"
  if ! vps_confirm "Continue with update?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  vps_update_packages ca-certificates curl jq openssl
  backup_dir="$(mktemp -d)"
  backup_bin="${backup_dir}/xray"
  trap '[[ -z "${backup_dir:-}" ]] || rm -rf -- "${backup_dir}"' EXIT
  cp -a "${xray_bin}" "${backup_bin}"
  if [[ -d "${asset_dir}" ]]; then
    for asset in geoip.dat geosite.dat; do
      if [[ -f "${asset_dir}/${asset}" ]]; then
        cp -a "${asset_dir}/${asset}" "${backup_dir}/${asset}"
      fi
    done
  fi

  if ! xray_run_installer install --no-update-service; then
    update_failed=1
  elif ! command -v xray >/dev/null 2>&1; then
    update_failed=1
  elif xray_config_uses_managed_geodata "${config_file}" \
    && ! xray_prepare_geodata_permissions "${config_file}" "${service}" "${asset_dir}"; then
    update_failed=1
  elif ! xray run -test -config "${config_file}" >/dev/null; then
    update_failed=1
  fi
  if [[ "${update_failed}" -eq 1 ]]; then
    restore_previous_xray_update "${backup_dir}" "${xray_bin}" "${asset_dir}" \
      || vps_die "Xray update failed and the previous binary or geodata could not be restored"
    if xray_config_uses_managed_geodata "${config_file}"; then
      xray_prepare_geodata_permissions "${config_file}" "${service}" "${asset_dir}" \
        || vps_die "Xray update failed and scheduled-geodata permissions could not be restored"
    fi
    if [[ "${was_active}" -eq 1 ]]; then
      systemctl restart "${service}" || true
    fi
    vps_die "Xray update or configuration validation failed; the previous binary and geodata were restored"
  fi
  if [[ "${was_active}" -eq 1 ]] && ! vps_restart_active_service "${service}"; then
    restore_previous_xray_update "${backup_dir}" "${xray_bin}" "${asset_dir}" \
      || vps_die "Xray service failed after update and rollback could not restore the previous binary or geodata"
    if xray_config_uses_managed_geodata "${config_file}"; then
      xray_prepare_geodata_permissions "${config_file}" "${service}" "${asset_dir}" \
        || vps_die "Xray service failed after update and scheduled-geodata permissions could not be restored"
    fi
    systemctl restart "${service}" || true
    vps_die "updated Xray service did not become active; the previous binary and geodata were restored"
  fi
  if [[ "${was_active}" -eq 0 ]]; then
    printf 'Xray service was inactive; it was left stopped.\n'
  fi
  printf 'Xray update complete.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
