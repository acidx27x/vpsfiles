#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADGUARD_HOME_VERSION="${ADGUARD_HOME_VERSION:-latest}"
ADGUARD_HOME_DIR="/opt/AdGuardHome"
ADGUARD_HOME_BIN="${ADGUARD_HOME_DIR}/AdGuardHome"
ADGUARD_HOME_CONFIG="${ADGUARD_HOME_DIR}/AdGuardHome.yaml"
ADGUARD_HOME_DATA="${ADGUARD_HOME_DIR}/data"
ADGUARD_HOME_BACKUP="${ADGUARD_HOME_DIR}/backup"
ADGUARD_HOME_SERVICE="AdGuardHome"
ADGUARD_HOME_WEB_ADDR="127.0.0.1:3000"
# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=adguardhome-scripts/adguardhome.sh
. "${SCRIPT_DIR}/adguardhome.sh"

require_files() {
  local file=""
  for file in "${SCRIPT_DIR}/adguardhome.sh" "${SCRIPT_DIR}/update.sh" "${SCRIPT_DIR}/uninstall.sh"; do
    [[ -f "${file}" ]] || vps_die "required file is missing: ${file}"
  done
}

rollback_failed_install() {
  local had_config="$1"
  local had_data="$2"
  local had_backup="$3"

  if [[ -x "${ADGUARD_HOME_BIN}" ]]; then
    (cd "${ADGUARD_HOME_DIR}" && "${ADGUARD_HOME_BIN}" -s uninstall) >/dev/null 2>&1 || true
  fi
  vps_systemctl_stop_disable "${ADGUARD_HOME_SERVICE}"
  vps_safe_remove_file_path "${ADGUARD_HOME_BIN}"
  if [[ "${had_config}" -eq 0 ]]; then
    vps_safe_remove_file_path "${ADGUARD_HOME_CONFIG}"
  fi
  if [[ "${had_data}" -eq 0 ]]; then
    vps_safe_remove_path "${ADGUARD_HOME_DATA}"
  fi
  if [[ "${had_backup}" -eq 0 ]]; then
    vps_safe_remove_path "${ADGUARD_HOME_BACKUP}"
  fi
  vps_remove_empty_dir "${ADGUARD_HOME_DIR}"
}

print_summary() {
  local version="$1"

  printf '\n============================================================\n'
  printf 'AdGuard Home installation complete.\n'
  printf '============================================================\n\n'
  printf 'Version:           %s\n' "${version}"
  printf 'Installation:      %s\n' "${ADGUARD_HOME_DIR}"
  printf 'Systemd service:   %s\n' "${ADGUARD_HOME_SERVICE}"
  printf 'Admin UI:          http://%s (loopback only)\n' "${ADGUARD_HOME_WEB_ADDR}"
  printf 'Firewall:          unchanged\n'
  printf 'Host DNS resolver: unchanged\n\n'
  printf 'From your workstation, create an SSH tunnel:\n'
  printf '  ssh -L 3000:127.0.0.1:3000 <user>@<server>\n\n'
  printf 'Then open http://127.0.0.1:3000 and complete the AdGuard Home wizard.\n'
  printf 'Choose only the loopback or private VPN address(es) that you intend to use.\n'
  printf 'Do not select All interfaces unless you secure public DNS access yourself.\n'
  printf 'To keep the VPS resolver unchanged, do not use the wizard DNSStubListener autofix.\n\n'
  printf 'Check status and logs with:\n'
  printf '  sudo systemctl status %s\n' "${ADGUARD_HOME_SERVICE}"
  printf '  sudo journalctl -u %s -n 100 --no-pager\n' "${ADGUARD_HOME_SERVICE}"
}

main() {
  local had_backup=0
  local had_config=0
  local had_data=0
  local resolved_version=""
  local temp_dir=""

  [[ $# -eq 0 ]] || vps_die "usage: install.sh"
  vps_require_root "sudo ./install.sh"
  require_files
  vps_require_supported_apt_os
  vps_require_systemd
  adguardhome_validate_version "${ADGUARD_HOME_VERSION}"
  [[ "${ADGUARD_HOME_DIR}" == "/opt/AdGuardHome" ]] || vps_die "unsafe AdGuard Home installation directory"
  [[ ! -e "${ADGUARD_HOME_BIN}" ]] || vps_die "AdGuard Home is already installed; use update.sh or uninstall.sh"
  if systemctl cat "${ADGUARD_HOME_SERVICE}" >/dev/null 2>&1; then
    vps_die "AdGuard Home service exists without its managed binary; repair or remove it before installing"
  fi
  [[ -f "${ADGUARD_HOME_CONFIG}" ]] && had_config=1
  [[ -d "${ADGUARD_HOME_DATA}" ]] && had_data=1
  [[ -d "${ADGUARD_HOME_BACKUP}" ]] && had_backup=1

  printf 'Native AdGuard Home installation\n\n'
  printf 'This will download AdGuard Home %s, install it under %s, register its\n' \
    "${ADGUARD_HOME_VERSION}" "${ADGUARD_HOME_DIR}"
  printf 'native systemd service, and keep the admin UI on %s.\n' "${ADGUARD_HOME_WEB_ADDR}"
  printf 'It will not modify UFW, the host DNS resolver, WireGuard, AmneziaWG, Xray, or other bundles.\n'
  if [[ "${had_config}" -eq 1 || "${had_data}" -eq 1 ]]; then
    printf 'Retained AdGuard Home configuration/data was found and will be reused.\n'
  fi
  if ! vps_confirm "Continue?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  vps_install_packages ca-certificates curl jq tar
  vps_require_commands awk curl grep install jq sed sha256sum tar
  resolved_version="$(adguardhome_resolve_version "${ADGUARD_HOME_VERSION}")"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  adguardhome_download_binary "${resolved_version}" "${temp_dir}/AdGuardHome"

  if ! install -d -m 755 -o root -g root "${ADGUARD_HOME_DIR}" \
    || ! install -m 755 -o root -g root "${temp_dir}/AdGuardHome" "${ADGUARD_HOME_BIN}"; then
    rollback_failed_install "${had_config}" "${had_data}" "${had_backup}"
    vps_die "could not install the AdGuard Home binary; installation changes were rolled back"
  fi
  if ! (cd "${ADGUARD_HOME_DIR}" && "${ADGUARD_HOME_BIN}" -s install --web-addr "${ADGUARD_HOME_WEB_ADDR}") \
    || ! systemctl is-active --quiet "${ADGUARD_HOME_SERVICE}" \
    || ! adguardhome_wait_for_web "${ADGUARD_HOME_WEB_ADDR}"; then
    rollback_failed_install "${had_config}" "${had_data}" "${had_backup}"
    vps_die "AdGuard Home service did not become ready; installation changes were rolled back"
  fi
  print_summary "${resolved_version}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
