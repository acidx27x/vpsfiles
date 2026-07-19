#!/usr/bin/env bash
set -Eeuo pipefail

NGINX_CONFIG_DEFAULT="/etc/nginx/sites-available/xray-fallback"
NGINX_ENABLED_CONFIG_DEFAULT="/etc/nginx/sites-enabled/xray-fallback"
NGINX_WEB_ROOT_DEFAULT="/var/www/xray-fallback"
NGINX_RENEWAL_HOOK_DEFAULT="/etc/letsencrypt/renewal-hooks/deploy/reload-xray-fallback-nginx"
NGINX_LETSENCRYPT_ROOT_DEFAULT="/etc/letsencrypt"
NGINX_REFERENCE_ROOTS_DEFAULT="/etc/nginx:/etc/apache2:/etc/httpd:/etc/postfix"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NGINX_STATE_DIR="${NGINX_STATE_DIR:-${SCRIPT_DIR}}"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

NGINX_DOMAIN="${NGINX_DOMAIN:-}"
NGINX_CONFIG="${NGINX_CONFIG:-}"
NGINX_ENABLED_CONFIG="${NGINX_ENABLED_CONFIG:-}"
NGINX_WEB_ROOT="${NGINX_WEB_ROOT:-}"
NGINX_RENEWAL_HOOK="${NGINX_RENEWAL_HOOK:-}"
NGINX_LETSENCRYPT_ROOT="${NGINX_LETSENCRYPT_ROOT:-${NGINX_LETSENCRYPT_ROOT_DEFAULT}}"
NGINX_REFERENCE_ROOTS="${NGINX_REFERENCE_ROOTS:-${NGINX_REFERENCE_ROOTS_DEFAULT}}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/uninstall.sh
. "${REPO_ROOT}/core/uninstall.sh"
# shellcheck source=nginx-scripts/nginx.sh
. "${SCRIPT_DIR}/nginx.sh"

nginx_uninstall_read_binary_state() {
  local state_file="$1"
  local value=""

  [[ -f "${state_file}" ]] || return 1
  value="$(<"${state_file}")"
  [[ "${value}" == "0" || "${value}" == "1" ]] || vps_die "invalid Nginx installer state: ${state_file}"
  printf '%s\n' "${value}"
}

nginx_uninstall_load_settings() {
  if [[ -z "${NGINX_CONFIG}" ]]; then
    NGINX_CONFIG="$(vps_read_file_or_default "${NGINX_STATE_DIR}/nginx-config-path.txt" "${NGINX_CONFIG_DEFAULT}")"
  fi
  if [[ -z "${NGINX_ENABLED_CONFIG}" ]]; then
    NGINX_ENABLED_CONFIG="$(vps_read_file_or_default "${NGINX_STATE_DIR}/nginx-enabled-config-path.txt" "${NGINX_ENABLED_CONFIG_DEFAULT}")"
  fi
  if [[ -z "${NGINX_WEB_ROOT}" ]]; then
    NGINX_WEB_ROOT="$(vps_read_file_or_default "${NGINX_STATE_DIR}/nginx-web-root-path.txt" "${NGINX_WEB_ROOT_DEFAULT}")"
  fi
  if [[ -z "${NGINX_RENEWAL_HOOK}" ]]; then
    NGINX_RENEWAL_HOOK="$(vps_read_file_or_default "${NGINX_STATE_DIR}/nginx-renewal-hook-path.txt" "${NGINX_RENEWAL_HOOK_DEFAULT}")"
  fi
  if [[ -z "${NGINX_DOMAIN}" ]]; then
    NGINX_DOMAIN="$(vps_read_file_or_default "${NGINX_STATE_DIR}/fallback-domain.txt" "")"
  fi
  if [[ -z "${NGINX_DOMAIN}" ]]; then
    NGINX_DOMAIN="$(nginx_certificate_name_from_config "${NGINX_CONFIG}" "${NGINX_LETSENCRYPT_ROOT}" || true)"
  fi
}

nginx_uninstall_validate_paths() {
  local path=""

  for path in \
    "${NGINX_STATE_DIR}" \
    "${BACKUP_ROOT}" \
    "${NGINX_CONFIG}" \
    "${NGINX_ENABLED_CONFIG}" \
    "${NGINX_WEB_ROOT}" \
    "${NGINX_RENEWAL_HOOK}" \
    "${NGINX_LETSENCRYPT_ROOT}"; do
    [[ "${path}" == /* && "${path}" != "/" ]] || vps_die "Nginx managed path is unsafe: ${path}"
  done
  [[ "${NGINX_CONFIG}" != "${NGINX_ENABLED_CONFIG}" ]] || vps_die "available and enabled Nginx config paths must differ"
  if [[ -n "${NGINX_DOMAIN}" ]]; then
    nginx_validate_domain "${NGINX_DOMAIN}"
  fi
}

nginx_uninstall_unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

nginx_uninstall_stop_services() {
  if nginx_uninstall_unit_exists certbot.timer; then
    systemctl disable --now certbot.timer >/dev/null \
      || vps_die "could not stop and disable certbot.timer"
  fi
  if nginx_uninstall_unit_exists certbot.service; then
    systemctl stop certbot.service \
      || vps_die "could not stop certbot.service"
  fi
  if nginx_uninstall_unit_exists nginx.service; then
    systemctl disable --now nginx.service >/dev/null \
      || vps_die "could not stop and disable nginx.service"
  fi
}

nginx_uninstall_certificate_exists() {
  local certificate_name="$1"

  [[ -e "${NGINX_LETSENCRYPT_ROOT}/live/${certificate_name}" \
    || -L "${NGINX_LETSENCRYPT_ROOT}/live/${certificate_name}" \
    || -d "${NGINX_LETSENCRYPT_ROOT}/archive/${certificate_name}" \
    || -f "${NGINX_LETSENCRYPT_ROOT}/renewal/${certificate_name}.conf" ]]
}

nginx_uninstall_remove_state() {
  local state_file=""

  for state_file in \
    fallback-domain.txt \
    reality-target.txt \
    reality-server-name.txt \
    nginx-config-path.txt \
    nginx-enabled-config-path.txt \
    nginx-web-root-path.txt \
    nginx-renewal-hook-path.txt \
    firewall-rule-added.txt \
    server-port.txt; do
    vps_safe_remove_file_path "${NGINX_STATE_DIR}/${state_file}"
  done
  vps_remove_empty_dir "${NGINX_STATE_DIR}"
}

nginx_uninstall_main() {
  local certificate_references=""
  local enabled_entry_is_owned=0
  local firewall_rule_added=""
  local had_managed_resources=0
  local nginx_config_root=""
  local partial_cleanup=0
  local saved_port=""

  [[ $# -eq 0 ]] || vps_die "usage: uninstall.sh"
  vps_require_root "sudo ./uninstall.sh"
  vps_require_commands awk grep readlink systemctl
  nginx_uninstall_load_settings
  nginx_uninstall_validate_paths

  if [[ -e "${NGINX_CONFIG}" || -L "${NGINX_ENABLED_CONFIG}" || -e "${NGINX_ENABLED_CONFIG}" \
    || -e "${NGINX_WEB_ROOT}" || -e "${NGINX_RENEWAL_HOOK}" ]]; then
    had_managed_resources=1
  fi
  if [[ -L "${NGINX_ENABLED_CONFIG}" && "$(readlink "${NGINX_ENABLED_CONFIG}")" == "${NGINX_CONFIG}" ]]; then
    enabled_entry_is_owned=1
  elif [[ -e "${NGINX_ENABLED_CONFIG}" || -L "${NGINX_ENABLED_CONFIG}" ]]; then
    partial_cleanup=1
  fi
  if [[ -f "${NGINX_STATE_DIR}/firewall-rule-added.txt" ]]; then
    firewall_rule_added="$(nginx_uninstall_read_binary_state "${NGINX_STATE_DIR}/firewall-rule-added.txt")"
  fi
  if [[ -f "${NGINX_STATE_DIR}/server-port.txt" ]]; then
    saved_port="$(<"${NGINX_STATE_DIR}/server-port.txt")"
    [[ "${saved_port}" == "80" ]] || vps_die "saved Nginx firewall port must be 80"
  fi

  vps_uninstall_print_plan "Nginx REALITY fallback" \
    "  Nginx config:       ${NGINX_CONFIG}" \
    "  Enabled entry:      ${NGINX_ENABLED_CONFIG}" \
    "  Web root:           ${NGINX_WEB_ROOT}" \
    "  Renewal hook:       ${NGINX_RENEWAL_HOOK}" \
    "  Certificate name:   ${NGINX_DOMAIN:-unknown; will be retained}" \
    "  Install backups:    ${BACKUP_ROOT}" \
    "  Shared services:    stop and disable nginx.service and certbot.timer"
  printf '\nNginx and Certbot apt packages and the shared Certbot account will be retained.\n'
  printf 'WARNING: stopping these shared services can affect unrelated sites and certificates.\n'
  if [[ "${partial_cleanup}" -eq 1 ]]; then
    printf 'WARNING: the enabled Nginx entry is not the expected bundle symlink and will be retained.\n'
  fi
  if ! vps_confirm "Continue with uninstall?"; then
    printf 'Aborted before making changes.\n'
    return 1
  fi

  nginx_uninstall_stop_services

  if [[ "${enabled_entry_is_owned}" -eq 1 ]]; then
    vps_safe_remove_file_path "${NGINX_ENABLED_CONFIG}"
  elif [[ -e "${NGINX_ENABLED_CONFIG}" || -L "${NGINX_ENABLED_CONFIG}" ]]; then
    printf 'Retained unexpected enabled Nginx entry: %s\n' "${NGINX_ENABLED_CONFIG}" >&2
  fi
  vps_safe_remove_file_path "${NGINX_CONFIG}"
  vps_safe_remove_path "${NGINX_WEB_ROOT}"
  vps_safe_remove_file_path "${NGINX_RENEWAL_HOOK}"
  vps_safe_remove_path "${BACKUP_ROOT}"

  if [[ -n "${NGINX_DOMAIN}" ]] && nginx_uninstall_certificate_exists "${NGINX_DOMAIN}"; then
    certificate_references="$(nginx_find_certificate_references \
      "${NGINX_LETSENCRYPT_ROOT}/live/${NGINX_DOMAIN}" \
      "${NGINX_REFERENCE_ROOTS}")"
    if [[ -n "${certificate_references}" ]]; then
      partial_cleanup=1
      printf 'Retained certificate because the certificate is still referenced by:\n%s\n' "${certificate_references}" >&2
    elif ! command -v certbot >/dev/null 2>&1; then
      partial_cleanup=1
      printf 'Retained certificate because certbot is unavailable: %s\n' "${NGINX_DOMAIN}" >&2
    elif ! certbot delete --non-interactive --cert-name "${NGINX_DOMAIN}"; then
      partial_cleanup=1
      printf 'Certbot could not delete certificate: %s\n' "${NGINX_DOMAIN}" >&2
    fi
  elif [[ -z "${NGINX_DOMAIN}" && "${had_managed_resources}" -eq 1 ]]; then
    partial_cleanup=1
    printf 'Certificate name could not be determined; any certificate lineage was retained.\n' >&2
  fi

  nginx_config_root="${NGINX_REFERENCE_ROOTS%%:*}"
  case "${firewall_rule_added}" in
    1)
      if [[ -z "${saved_port}" ]]; then
        partial_cleanup=1
        printf 'Retained TCP/80 firewall ownership state because the saved port is missing.\n' >&2
      elif nginx_has_port_80_listener "${nginx_config_root}"; then
        partial_cleanup=1
        printf 'Retained TCP/80 firewall rule because another Nginx configuration listens on port 80.\n' >&2
      elif ! command -v ufw >/dev/null 2>&1; then
        partial_cleanup=1
        printf 'Retained TCP/80 firewall ownership state because ufw is unavailable.\n' >&2
      elif ! ufw delete allow "${saved_port}/tcp" >/dev/null; then
        partial_cleanup=1
        printf 'UFW could not remove the saved TCP/80 allow rule.\n' >&2
      else
        printf 'Removed UFW allow rule: %s/tcp\n' "${saved_port}"
      fi
      ;;
    0)
      ;;
    *)
      printf 'TCP/80 firewall ownership is unknown; the rule was left unchanged.\n'
      ;;
  esac

  if [[ "${partial_cleanup}" -eq 0 ]]; then
    nginx_uninstall_remove_state
    printf 'Nginx fallback uninstall complete. Shared apt packages were retained.\n'
    return 0
  fi

  printf 'Nginx fallback cleanup is partial; installer state was retained for a later retry.\n' >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  nginx_uninstall_main "$@"
fi
