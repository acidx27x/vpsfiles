#!/usr/bin/env bash
set -euo pipefail

NGINX_INTERNAL_PORT_DEFAULT="8443"
NGINX_CONFIG_DEFAULT="/etc/nginx/sites-available/xray-fallback"
NGINX_ENABLED_CONFIG_DEFAULT="/etc/nginx/sites-enabled/xray-fallback"
NGINX_WEB_ROOT_DEFAULT="/var/www/xray-fallback"
NGINX_RENEWAL_HOOK_DEFAULT="/etc/letsencrypt/renewal-hooks/deploy/reload-xray-fallback-nginx"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NGINX_STATE_DIR="${NGINX_STATE_DIR:-${SCRIPT_DIR}}"
NGINX_TEMPLATE="${SCRIPT_DIR}/fallback-site.conf.example"
NGINX_RENEWAL_HOOK_SOURCE="${SCRIPT_DIR}/reload-nginx.sh"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

NGINX_DOMAIN="${NGINX_DOMAIN:-}"
NGINX_EMAIL="${NGINX_EMAIL:-}"
NGINX_INTERNAL_PORT="${NGINX_INTERNAL_PORT:-${NGINX_INTERNAL_PORT_DEFAULT}}"
NGINX_CONFIG="${NGINX_CONFIG:-${NGINX_CONFIG_DEFAULT}}"
NGINX_ENABLED_CONFIG="${NGINX_ENABLED_CONFIG:-${NGINX_ENABLED_CONFIG_DEFAULT}}"
NGINX_WEB_ROOT="${NGINX_WEB_ROOT:-${NGINX_WEB_ROOT_DEFAULT}}"
NGINX_RENEWAL_HOOK="${NGINX_RENEWAL_HOOK:-${NGINX_RENEWAL_HOOK_DEFAULT}}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=nginx-scripts/nginx.sh
. "${SCRIPT_DIR}/nginx.sh"

require_files() {
  local file=""

  for file in "${NGINX_TEMPLATE}" "${NGINX_RENEWAL_HOOK_SOURCE}" "${SCRIPT_DIR}/uninstall.sh"; do
    [[ -f "${file}" ]] || vps_die "required file is missing: ${file}"
  done
}

collect_settings() {
  local hostname_default=""

  hostname_default="$(hostname -f 2>/dev/null || true)"
  vps_prompt NGINX_DOMAIN "Fallback site FQDN" "${NGINX_DOMAIN:-${hostname_default}}"
  vps_prompt NGINX_EMAIL "Let's Encrypt email" "${NGINX_EMAIL}"
  vps_prompt NGINX_INTERNAL_PORT "Internal Nginx HTTPS port" "${NGINX_INTERNAL_PORT}"
  NGINX_DOMAIN="${NGINX_DOMAIN,,}"

  nginx_validate_domain "${NGINX_DOMAIN}"
  nginx_validate_email "${NGINX_EMAIL}"
  nginx_validate_internal_port "${NGINX_INTERNAL_PORT}"
  [[ "${NGINX_CONFIG}" == /* && "${NGINX_ENABLED_CONFIG}" == /* && "${NGINX_WEB_ROOT}" == /* && "${NGINX_RENEWAL_HOOK}" == /* ]] \
    || vps_die "Nginx managed paths must be absolute"
  [[ "${NGINX_CONFIG}" != "/" && "${NGINX_ENABLED_CONFIG}" != "/" && "${NGINX_WEB_ROOT}" != "/" && "${NGINX_RENEWAL_HOOK}" != "/" ]] \
    || vps_die "Nginx managed paths must not be the filesystem root"
  [[ "${NGINX_CONFIG}" != "${NGINX_ENABLED_CONFIG}" ]] || vps_die "available and enabled Nginx config paths must differ"
  [[ "${NGINX_STATE_DIR}" == /* && "${NGINX_STATE_DIR}" != "/" ]] || vps_die "Nginx state directory must be absolute and safe"
}

install_packages() {
  vps_install_packages \
    ca-certificates \
    certbot \
    curl \
    nginx \
    ufw
}

backup_managed_files() {
  local timestamp=""
  local backup_dir=""

  if [[ ! -e "${NGINX_CONFIG}" && ! -e "${NGINX_ENABLED_CONFIG}" && ! -L "${NGINX_ENABLED_CONFIG}" && ! -e "${NGINX_RENEWAL_HOOK}" ]]; then
    return 0
  fi

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"
  install -d -m 700 "${backup_dir}"
  [[ ! -e "${NGINX_CONFIG}" ]] || cp -a "${NGINX_CONFIG}" "${backup_dir}/site-config"
  [[ ! -e "${NGINX_ENABLED_CONFIG}" && ! -L "${NGINX_ENABLED_CONFIG}" ]] || cp -a "${NGINX_ENABLED_CONFIG}" "${backup_dir}/enabled-config"
  [[ ! -e "${NGINX_RENEWAL_HOOK}" ]] || cp -a "${NGINX_RENEWAL_HOOK}" "${backup_dir}/renewal-hook"
  printf 'Backed up existing managed Nginx files to: %s\n' "${backup_dir}"
}

write_script_state() {
  install -d -m 755 "${NGINX_STATE_DIR}"
  printf '%s\n' "${NGINX_DOMAIN}" > "${NGINX_STATE_DIR}/fallback-domain.txt"
  printf '%s\n' "${NGINX_CONFIG}" > "${NGINX_STATE_DIR}/nginx-config-path.txt"
  printf '%s\n' "${NGINX_ENABLED_CONFIG}" > "${NGINX_STATE_DIR}/nginx-enabled-config-path.txt"
  printf '%s\n' "${NGINX_WEB_ROOT}" > "${NGINX_STATE_DIR}/nginx-web-root-path.txt"
  printf '%s\n' "${NGINX_RENEWAL_HOOK}" > "${NGINX_STATE_DIR}/nginx-renewal-hook-path.txt"
  printf '80\n' > "${NGINX_STATE_DIR}/server-port.txt"
  chmod 600 \
    "${NGINX_STATE_DIR}/fallback-domain.txt" \
    "${NGINX_STATE_DIR}/nginx-config-path.txt" \
    "${NGINX_STATE_DIR}/nginx-enabled-config-path.txt" \
    "${NGINX_STATE_DIR}/nginx-web-root-path.txt" \
    "${NGINX_STATE_DIR}/nginx-renewal-hook-path.txt" \
    "${NGINX_STATE_DIR}/server-port.txt"
  chmod +x "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

prepare_web_root() {
  local index_file=""

  install -d -m 755 "${NGINX_WEB_ROOT}"
  index_file="$(mktemp)"
  printf '%s\n' \
    '<!doctype html>' \
    '<html lang="en">' \
    '<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>' \
    '<body><main><h1>Welcome</h1><p>This site is available over HTTPS.</p></main></body>' \
    '</html>' > "${index_file}"
  install -m 644 "${index_file}" "${NGINX_WEB_ROOT}/index.html"
  rm -f "${index_file}"
}

activate_nginx_config() {
  local source_file="$1"

  install -d -m 755 "$(dirname "${NGINX_CONFIG}")" "$(dirname "${NGINX_ENABLED_CONFIG}")"
  if [[ -e "${NGINX_ENABLED_CONFIG}" && ! -L "${NGINX_ENABLED_CONFIG}" ]]; then
    vps_die "refusing to replace non-symlink enabled config: ${NGINX_ENABLED_CONFIG}"
  fi
  install -m 644 "${source_file}" "${NGINX_CONFIG}"
  ln -sfn "${NGINX_CONFIG}" "${NGINX_ENABLED_CONFIG}"
  nginx -t
  systemctl enable nginx >/dev/null
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi
}

install_bootstrap_config() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  nginx_render_bootstrap_config "${NGINX_DOMAIN}" "${NGINX_WEB_ROOT}" > "${tmp_file}"
  activate_nginx_config "${tmp_file}"
  rm -f "${tmp_file}"
}

setup_firewall() {
  local added_rule=0
  local previous_state=""

  if [[ -f "${NGINX_STATE_DIR}/firewall-rule-added.txt" ]]; then
    previous_state="$(<"${NGINX_STATE_DIR}/firewall-rule-added.txt")"
    [[ "${previous_state}" == "0" || "${previous_state}" == "1" ]] \
      || vps_die "invalid Nginx firewall ownership state"
    added_rule="${previous_state}"
  fi
  if ! ufw show added 2>/dev/null | grep -Eq '^ufw allow 80/tcp$'; then
    ufw allow 80/tcp >/dev/null
    added_rule=1
  fi
  printf '%s\n' "${added_rule}" > "${NGINX_STATE_DIR}/firewall-rule-added.txt"
  chmod 600 "${NGINX_STATE_DIR}/firewall-rule-added.txt"
  if ! ufw status | grep -q "Status: active"; then
    printf 'Before enabling UFW, verify that your SSH port already has an allow rule.\n'
  fi
  vps_enable_ufw_if_needed "Skipped enabling UFW. The HTTP port was still added to UFW rules."
}

issue_certificate() {
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "${NGINX_EMAIL}" \
    --webroot \
    --webroot-path "${NGINX_WEB_ROOT}" \
    --domains "${NGINX_DOMAIN}" \
    --cert-name "${NGINX_DOMAIN}" \
    --keep-until-expiring
}

install_final_config() {
  local tmp_file=""

  tmp_file="$(mktemp)"
  nginx_render_site_config "${NGINX_DOMAIN}" "${NGINX_INTERNAL_PORT}" "${NGINX_WEB_ROOT}" > "${tmp_file}"
  activate_nginx_config "${tmp_file}"
  rm -f "${tmp_file}"
}

install_renewal_hook() {
  install -d -m 755 "$(dirname "${NGINX_RENEWAL_HOOK}")"
  install -m 755 "${NGINX_RENEWAL_HOOK_SOURCE}" "${NGINX_RENEWAL_HOOK}"
  systemctl enable --now certbot.timer >/dev/null
}

verify_internal_site() {
  curl \
    --fail \
    --silent \
    --show-error \
    --max-time 10 \
    --noproxy '*' \
    --resolve "${NGINX_DOMAIN}:${NGINX_INTERNAL_PORT}:127.0.0.1" \
    "https://${NGINX_DOMAIN}:${NGINX_INTERNAL_PORT}/" >/dev/null
}

print_summary() {
  printf '\n============================================================\n'
  printf 'Nginx REALITY fallback installation complete.\n'
  printf '============================================================\n\n'
  printf 'Fallback domain:    %s\n' "${NGINX_DOMAIN}"
  printf 'Public HTTP:        0.0.0.0:80 (ACME and HTTPS redirect)\n'
  printf 'Internal HTTPS:     127.0.0.1:%s\n' "${NGINX_INTERNAL_PORT}"
  printf 'Nginx config:       %s\n\n' "${NGINX_CONFIG}"
  printf 'Enter these values in xray-scripts/install.sh:\n'
  printf '  REALITY target host:port: 127.0.0.1:%s\n' "${NGINX_INTERNAL_PORT}"
  printf '  REALITY serverName/SNI:   %s\n\n' "${NGINX_DOMAIN}"
  printf 'After Xray owns public port 443, test active probing with:\n'
  printf '  curl -v --resolve %s:443:<VPS_IP> https://%s/\n' "${NGINX_DOMAIN}" "${NGINX_DOMAIN}"
  printf '\nRemove this fallback independently with:\n'
  printf '  cd %s\n' "${SCRIPT_DIR}"
  printf '  sudo ./uninstall.sh\n'
}

nginx_install_main() {
  vps_require_root "sudo ./install.sh"
  require_files
  vps_require_supported_apt_os
  vps_require_systemd

  printf 'Nginx HTTPS fallback installation for Xray REALITY\n\n'
  collect_settings
  printf '\nThis will install Nginx and Certbot, create a minimal site, open TCP port 80,\n'
  printf 'issue a Let\x27s Encrypt certificate, and listen for TLS only on 127.0.0.1:%s.\n' "${NGINX_INTERNAL_PORT}"
  if ! vps_confirm "Continue?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  write_script_state
  backup_managed_files
  install_packages
  vps_require_commands certbot curl nginx systemctl ufw
  prepare_web_root
  install_bootstrap_config
  setup_firewall
  issue_certificate
  install_final_config
  install_renewal_hook
  verify_internal_site
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  nginx_install_main "$@"
fi
