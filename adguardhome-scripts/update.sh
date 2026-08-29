#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADGUARD_HOME_VERSION="${ADGUARD_HOME_VERSION:-latest}"
ADGUARD_HOME_DIR="/opt/AdGuardHome"
ADGUARD_HOME_BIN="${ADGUARD_HOME_DIR}/AdGuardHome"
ADGUARD_HOME_CONFIG="${ADGUARD_HOME_DIR}/AdGuardHome.yaml"
ADGUARD_HOME_BACKUP="${ADGUARD_HOME_DIR}/backup"
ADGUARD_HOME_SERVICE="AdGuardHome"
ADGUARD_HOME_WEB_ADDR="127.0.0.1:3000"
# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/update.sh
. "${REPO_ROOT}/core/update.sh"
# shellcheck source=adguardhome-scripts/adguardhome.sh
. "${SCRIPT_DIR}/adguardhome.sh"

adguardhome_restore_release() {
  local backup_binary="$1"
  local backup_config="$2"
  local binary="$3"
  local config="$4"
  local service="$5"
  local was_active="$6"

  systemctl stop "${service}" >/dev/null 2>&1 || true
  install -m 755 "${backup_binary}" "${binary}" || return 1
  cp -a -- "${backup_config}" "${config}" || return 1
  if [[ "${was_active}" -eq 1 ]]; then
    systemctl start "${service}" || return 1
    systemctl is-active --quiet "${service}" || return 1
    adguardhome_wait_for_web "${ADGUARD_HOME_WEB_ADDR}" || return 1
  fi
}

main() {
  local backup_dir=""
  local current_version=""
  local resolved_version=""
  local temp_dir=""
  local update_ok=1
  local was_active=0

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_require_root "sudo ./update.sh"
  vps_require_supported_apt_os
  vps_require_systemd
  vps_require_commands awk curl grep install jq sed sha256sum tar
  adguardhome_validate_version "${ADGUARD_HOME_VERSION}"
  [[ "${ADGUARD_HOME_DIR}" == "/opt/AdGuardHome" ]] || vps_die "unsafe AdGuard Home installation directory"
  [[ -x "${ADGUARD_HOME_BIN}" && -f "${ADGUARD_HOME_CONFIG}" ]] \
    || vps_die "AdGuard Home installation state is missing; run install.sh first"
  systemctl cat "${ADGUARD_HOME_SERVICE}" >/dev/null 2>&1 \
    || vps_die "AdGuard Home systemd service is missing"
  adguardhome_check_config "${ADGUARD_HOME_BIN}" "${ADGUARD_HOME_DIR}" \
    || vps_die "current AdGuard Home configuration is invalid"

  current_version="$(adguardhome_version_from_binary "${ADGUARD_HOME_BIN}")"
  resolved_version="$(adguardhome_resolve_version "${ADGUARD_HOME_VERSION}")"
  if [[ "${current_version}" == "${resolved_version}" ]]; then
    printf 'AdGuard Home is already at %s.\n' "${current_version}"
    exit 0
  fi
  if vps_service_is_active "${ADGUARD_HOME_SERVICE}"; then
    was_active=1
  fi
  printf 'This will update AdGuard Home %s -> %s, preserve its configuration/data,\n' \
    "${current_version}" "${resolved_version}"
  printf 'and leave an originally stopped service stopped.\n'
  if ! vps_confirm "Continue with update?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  vps_update_packages ca-certificates curl jq tar
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  adguardhome_download_binary "${resolved_version}" "${temp_dir}/AdGuardHome"
  install -d -m 700 -o root -g root "${ADGUARD_HOME_BACKUP}"
  backup_dir="$(mktemp -d "${ADGUARD_HOME_BACKUP}/vpsfiles-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
  cp -a -- "${ADGUARD_HOME_BIN}" "${backup_dir}/AdGuardHome"
  cp -a -- "${ADGUARD_HOME_CONFIG}" "${backup_dir}/AdGuardHome.yaml"

  if [[ "${was_active}" -eq 1 ]] && ! systemctl stop "${ADGUARD_HOME_SERVICE}"; then
    vps_die "could not stop AdGuard Home; no runtime files were changed"
  fi
  if ! install -m 755 -o root -g root "${temp_dir}/AdGuardHome" "${ADGUARD_HOME_BIN}"; then
    update_ok=0
  elif ! adguardhome_check_config "${ADGUARD_HOME_BIN}" "${ADGUARD_HOME_DIR}"; then
    update_ok=0
  elif [[ "${was_active}" -eq 1 ]]; then
    if ! systemctl start "${ADGUARD_HOME_SERVICE}" \
      || ! systemctl is-active --quiet "${ADGUARD_HOME_SERVICE}" \
      || ! adguardhome_wait_for_web "${ADGUARD_HOME_WEB_ADDR}"; then
      update_ok=0
    fi
  fi

  if [[ "${update_ok}" -eq 0 ]]; then
    if ! adguardhome_restore_release \
      "${backup_dir}/AdGuardHome" \
      "${backup_dir}/AdGuardHome.yaml" \
      "${ADGUARD_HOME_BIN}" \
      "${ADGUARD_HOME_CONFIG}" \
      "${ADGUARD_HOME_SERVICE}" \
      "${was_active}"; then
      vps_die "AdGuard Home update and automatic rollback both failed; inspect the service immediately"
    fi
    vps_die "AdGuard Home update failed; the previous binary and configuration were restored"
  fi

  printf 'AdGuard Home update complete: %s -> %s.\n' "${current_version}" "${resolved_version}"
  if [[ "${was_active}" -eq 0 ]]; then
    printf 'AdGuard Home was stopped before the update and remains stopped.\n'
  fi
  printf 'Previous release backup: %s\n' "${backup_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
