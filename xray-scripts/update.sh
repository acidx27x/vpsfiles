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

main() {
  local config_file=""
  local service=""
  local xray_bin=""
  local backup_bin=""
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
  backup_bin="$(mktemp)"
  trap '[[ -z "${backup_bin:-}" ]] || rm -f -- "${backup_bin}"' EXIT
  cp -a "${xray_bin}" "${backup_bin}"
  if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ update \
    || ! command -v xray >/dev/null 2>&1 \
    || ! xray run -test -config "${config_file}" >/dev/null; then
    install -m 755 "${backup_bin}" "${xray_bin}"
    if [[ "${was_active}" -eq 1 ]]; then
      systemctl restart "${service}" || true
    fi
    vps_die "Xray update or configuration validation failed; the previous binary was restored"
  fi
  if [[ "${was_active}" -eq 1 ]] && ! vps_restart_active_service "${service}"; then
    install -m 755 "${backup_bin}" "${xray_bin}"
    systemctl restart "${service}" || true
    vps_die "updated Xray service did not become active; the previous binary was restored"
  fi
  if [[ "${was_active}" -eq 0 ]]; then
    printf 'Xray service was inactive; it was left stopped.\n'
  fi
  printf 'Xray update complete.\n'
}

main "$@"
