#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TELEMT_VERSION="${TELEMT_VERSION:-latest}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/update.sh
. "${REPO_ROOT}/core/update.sh"
# shellcheck source=telemt-scripts/telemt.sh
. "${SCRIPT_DIR}/telemt.sh"

restore_previous_telemt_update() {
  local backup_bin="$1"
  local bin_path="$2"
  local service="$3"
  local was_active="$4"

  install -m 755 "${backup_bin}" "${bin_path}" || return 1
  if [[ "${was_active}" -eq 1 ]]; then
    vps_restart_active_service "${service}" || return 1
  fi
}

main() {
  local config_file=""
  local service=""
  local bin_path=""
  local backup_bin=""
  local new_bin=""
  local was_active=0

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_require_root "sudo ./update.sh"
  vps_require_systemd
  vps_require_commands systemctl tar
  [[ -f telemt-config-path.txt && -f telemt-service.txt && -f telemt-bin-path.txt ]] || vps_die "Telemt state is missing; run install.sh first"
  config_file="$(<telemt-config-path.txt)"
  service="$(<telemt-service.txt)"
  bin_path="$(<telemt-bin-path.txt)"
  [[ "${config_file}" == /* && -f "${config_file}" ]] || vps_die "Telemt config is missing or unsafe: ${config_file}"
  [[ "${bin_path}" == /* && -x "${bin_path}" ]] || vps_die "Telemt binary is missing or unsafe: ${bin_path}"
  [[ "${service}" =~ ^[A-Za-z0-9_.@-]+$ ]] || vps_die "saved Telemt service name is invalid"
  telemt_validate_version "${TELEMT_VERSION}"
  if vps_service_is_active "${service}"; then
    was_active=1
  fi

  printf 'This will upgrade Telemt %s and required packages without changing its configuration, TLS data, clients, endpoints, UFW, or sysctl state.\n' "${TELEMT_VERSION}"
  printf 'Active service: %s\n' "${service}"
  if ! vps_confirm "Continue with update?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  vps_update_packages ca-certificates curl tar gzip
  backup_bin="$(mktemp)"
  new_bin="$(mktemp)"
  trap '[[ -z "${backup_bin:-}" ]] || rm -f -- "${backup_bin}"; [[ -z "${new_bin:-}" ]] || rm -f -- "${new_bin}"' EXIT
  cp -a "${bin_path}" "${backup_bin}"
  telemt_download_binary "${TELEMT_VERSION}" "${new_bin}"
  if ! install -m 755 "${new_bin}" "${bin_path}"; then
    restore_previous_telemt_update "${backup_bin}" "${bin_path}" "${service}" "${was_active}" \
      || vps_die "Telemt update and automatic rollback both failed; inspect the service immediately"
    vps_die "Telemt binary update failed; the previous binary was restored"
  fi
  if [[ "${was_active}" -eq 1 ]] && ! vps_restart_active_service "${service}"; then
    restore_previous_telemt_update "${backup_bin}" "${bin_path}" "${service}" "${was_active}" \
      || vps_die "Telemt update and automatic rollback both failed; inspect the service immediately"
    vps_die "updated Telemt service did not become active; the previous binary was restored"
  fi
  if [[ "${was_active}" -eq 0 ]]; then
    printf 'Telemt service was inactive; it was left stopped.\n'
  fi
  printf 'Telemt update complete.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
