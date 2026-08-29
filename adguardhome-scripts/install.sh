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
# shellcheck source=adguardhome-scripts/unbound.sh
. "${SCRIPT_DIR}/unbound.sh"

ADGUARD_INSTALL_HAD_BACKUP=0
ADGUARD_INSTALL_HAD_CONFIG=0
ADGUARD_INSTALL_HAD_DATA=0
ADGUARD_INSTALL_ROLLBACK_ARMED=0
ADGUARD_INSTALL_COMMITTED=0
ADGUARD_INSTALL_TEMP_DIR=""

require_files() {
  local file=""
  for file in \
    "${SCRIPT_DIR}/adguardhome.sh" \
    "${SCRIPT_DIR}/unbound.sh" \
    "${SCRIPT_DIR}/update.sh" \
    "${SCRIPT_DIR}/uninstall.sh"; do
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
  unbound_restore_bundle_state
}

cleanup_install() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "${ADGUARD_INSTALL_TEMP_DIR}" ]]; then
    rm -rf -- "${ADGUARD_INSTALL_TEMP_DIR}"
  fi
  if [[ "${ADGUARD_INSTALL_ROLLBACK_ARMED}" -eq 1 \
    && "${ADGUARD_INSTALL_COMMITTED}" -eq 0 ]]; then
    if rollback_failed_install \
      "${ADGUARD_INSTALL_HAD_CONFIG}" \
      "${ADGUARD_INSTALL_HAD_DATA}" \
      "${ADGUARD_INSTALL_HAD_BACKUP}"; then
      printf 'Installation changes were rolled back; installed APT packages were retained.\n' >&2
    else
      printf 'ERROR: automatic installation rollback was incomplete; inspect AdGuard Home and Unbound immediately.\n' >&2
    fi
  fi
  exit "${exit_status}"
}

print_summary() {
  local version="$1"

  printf '\n============================================================\n'
  printf 'AdGuard Home installation complete.\n'
  printf '============================================================\n\n'
  printf 'Version:           %s\n' "${version}"
  printf 'Installation:      %s\n' "${ADGUARD_HOME_DIR}"
  printf 'Systemd service:   %s\n' "${ADGUARD_HOME_SERVICE}"
  printf 'Recursive backend: 127.0.0.1:%s (%s)\n' "${UNBOUND_PORT}" "${UNBOUND_SERVICE}"
  printf 'Admin UI:          http://%s (loopback only)\n' "${ADGUARD_HOME_WEB_ADDR}"
  printf 'Firewall:          unchanged\n'
  printf 'Host DNS resolver: unchanged\n\n'
  printf 'From your workstation, create an SSH tunnel:\n'
  printf '  ssh -L 3000:127.0.0.1:3000 <user>@<server>\n\n'
  printf 'Then open http://127.0.0.1:3000 and complete the AdGuard Home wizard.\n'
  printf 'Choose only the loopback or private VPN address(es) that you intend to use.\n'
  printf 'Do not select All interfaces unless you secure public DNS access yourself.\n'
  printf 'To keep the VPS resolver unchanged, do not use the wizard DNSStubListener autofix.\n\n'
  printf 'After the wizard, set the only upstream DNS server to 127.0.0.1:%s.\n' "${UNBOUND_PORT}"
  printf 'Leave fallback and bootstrap DNS servers empty. See README.md for all DNS settings.\n\n'
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
  local unbound_status=0

  [[ $# -eq 0 ]] || vps_die "usage: install.sh"
  vps_require_root "sudo ./install.sh"
  require_files
  vps_require_supported_apt_os
  vps_require_systemd
  vps_require_commands awk cmp dpkg-query find grep md5sum ss stat systemctl
  adguardhome_validate_version "${ADGUARD_HOME_VERSION}"
  [[ "${ADGUARD_HOME_DIR}" == "/opt/AdGuardHome" ]] || vps_die "unsafe AdGuard Home installation directory"
  [[ ! -e "${ADGUARD_HOME_BIN}" ]] || vps_die "AdGuard Home is already installed; use update.sh or uninstall.sh"
  if systemctl cat "${ADGUARD_HOME_SERVICE}" >/dev/null 2>&1; then
    vps_die "AdGuard Home service exists without its managed binary; repair or remove it before installing"
  fi
  unbound_preflight
  [[ -f "${ADGUARD_HOME_CONFIG}" ]] && had_config=1
  [[ -d "${ADGUARD_HOME_DATA}" ]] && had_data=1
  [[ -d "${ADGUARD_HOME_BACKUP}" ]] && had_backup=1

  printf 'Native AdGuard Home installation\n\n'
  printf 'This will download AdGuard Home %s, install it under %s, register its\n' \
    "${ADGUARD_HOME_VERSION}" "${ADGUARD_HOME_DIR}"
  printf 'native systemd service, install a local recursive Unbound backend on 127.0.0.1:%s,\n' \
    "${UNBOUND_PORT}"
  printf 'and keep the admin UI on %s.\n' "${ADGUARD_HOME_WEB_ADDR}"
  printf 'It will not modify UFW, the host DNS resolver, WireGuard, AmneziaWG, Xray, or other bundles.\n'
  if [[ "${had_config}" -eq 1 || "${had_data}" -eq 1 ]]; then
    printf 'Retained AdGuard Home configuration/data was found and will be reused.\n'
  fi
  if ! vps_confirm "Continue?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  ADGUARD_INSTALL_HAD_CONFIG="${had_config}"
  ADGUARD_INSTALL_HAD_DATA="${had_data}"
  ADGUARD_INSTALL_HAD_BACKUP="${had_backup}"
  trap cleanup_install EXIT
  unbound_initialize_state
  ADGUARD_INSTALL_ROLLBACK_ARMED=1
  unbound_deactivate_resolvconf \
    || vps_die "could not disable the unbound-resolvconf integration"
  if ! (set -e; vps_install_packages \
    ca-certificates curl dns-root-data dnsutils jq tar unbound); then
    vps_die "could not install AdGuard Home and Unbound package dependencies"
  fi
  vps_require_commands awk curl dig grep install jq sed sha256sum tar unbound-checkconf
  unbound_deactivate_resolvconf \
    || vps_die "could not keep the unbound-resolvconf integration disabled"
  systemctl stop "${UNBOUND_SERVICE}" >/dev/null 2>&1 \
    || vps_die "could not stop Unbound before installing its managed configuration"
  unbound_activate || unbound_status=$?
  if [[ "${unbound_status}" -ne 0 ]]; then
    vps_die "$(unbound_activation_error "${unbound_status}")"
  fi
  resolved_version="$(adguardhome_resolve_version "${ADGUARD_HOME_VERSION}")"
  temp_dir="$(mktemp -d)"
  ADGUARD_INSTALL_TEMP_DIR="${temp_dir}"
  adguardhome_download_binary "${resolved_version}" "${temp_dir}/AdGuardHome"

  if ! install -d -m 755 -o root -g root "${ADGUARD_HOME_DIR}" \
    || ! install -m 755 -o root -g root "${temp_dir}/AdGuardHome" "${ADGUARD_HOME_BIN}"; then
    vps_die "could not install the AdGuard Home binary"
  fi
  if ! (cd "${ADGUARD_HOME_DIR}" && "${ADGUARD_HOME_BIN}" -s install --web-addr "${ADGUARD_HOME_WEB_ADDR}") \
    || ! systemctl is-active --quiet "${ADGUARD_HOME_SERVICE}" \
    || ! adguardhome_wait_for_web "${ADGUARD_HOME_WEB_ADDR}"; then
    vps_die "AdGuard Home service did not become ready"
  fi
  ADGUARD_INSTALL_COMMITTED=1
  print_summary "${resolved_version}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
