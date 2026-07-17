#!/usr/bin/env bash
set -euo pipefail
umask 077

TG_WS_PORT_DEFAULT="1443"
TG_WS_COMPOSE_DIR_DEFAULT="/etc/tg-ws-proxy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_TEMPLATE="${SCRIPT_DIR}/compose.yaml.example"
WORKER_TEMPLATE="${SCRIPT_DIR}/cf-worker.js.example"

TG_WS_PROXY_VERSION="${TG_WS_PROXY_VERSION:-latest}"
TG_WS_PROXY_PORT="${TG_WS_PROXY_PORT:-${TG_WS_PORT_DEFAULT}}"
TG_WS_PROXY_PUBLIC_HOST="${TG_WS_PROXY_PUBLIC_HOST:-}"
TG_WS_PROXY_PUBLIC_IPV4="${TG_WS_PROXY_PUBLIC_IPV4:-}"
TG_WS_PROXY_IPV6="${TG_WS_PROXY_IPV6:-}"
TG_WS_PROXY_CF_WORKER="${TG_WS_PROXY_CF_WORKER:-}"
TG_WS_COMPOSE_DIR="${TG_WS_COMPOSE_DIR_DEFAULT}"
TG_WS_PROJECT="tg-ws-proxy"
TG_WS_IMAGE_REPOSITORY="vpsfiles/tg-ws-proxy"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/docker.sh
. "${REPO_ROOT}/core/docker.sh"
# shellcheck source=tg-ws-scripts/tg-ws.sh
. "${SCRIPT_DIR}/tg-ws.sh"

require_files() {
  local file=""

  for file in "${COMPOSE_TEMPLATE}" "${WORKER_TEMPLATE}" "${SCRIPT_DIR}/update.sh" "${SCRIPT_DIR}/uninstall.sh"; do
    [[ -f "${file}" ]] || vps_die "required file is missing: ${file}"
  done
}

collect_settings() {
  local detected_ipv4=""
  local detected_ipv6=""

  detected_ipv4="$(vps_detect_public_ip)"
  detected_ipv6="$(vps_detect_public_ip6)"
  vps_prompt TG_WS_PROXY_PUBLIC_IPV4 "Public IPv4 address" "${TG_WS_PROXY_PUBLIC_IPV4:-${detected_ipv4}}"
  vps_prompt TG_WS_PROXY_IPV6 "Public IPv6 address" "${TG_WS_PROXY_IPV6:-${detected_ipv6}}"
  vps_prompt TG_WS_PROXY_PUBLIC_HOST "Telegram server address (domain or IP)" "${TG_WS_PROXY_PUBLIC_HOST:-${TG_WS_PROXY_PUBLIC_IPV4}}"
  vps_prompt TG_WS_PROXY_PORT "Public tg-ws-proxy TCP port" "${TG_WS_PROXY_PORT}"
  vps_prompt TG_WS_PROXY_CF_WORKER "Cloudflare Worker domain (blank to skip)" "${TG_WS_PROXY_CF_WORKER}"
  TG_WS_PROXY_CF_WORKER="${TG_WS_PROXY_CF_WORKER,,}"

  tg_ws_validate_version "${TG_WS_PROXY_VERSION}"
  tg_ws_validate_ipv4 "${TG_WS_PROXY_PUBLIC_IPV4}"
  tg_ws_validate_optional_ipv6 "${TG_WS_PROXY_IPV6}"
  tg_ws_validate_public_host "${TG_WS_PROXY_PUBLIC_HOST}"
  vps_validate_port "${TG_WS_PROXY_PORT}"
  tg_ws_validate_domain "${TG_WS_PROXY_CF_WORKER}"
  [[ "${TG_WS_COMPOSE_DIR}" == /* && "${TG_WS_COMPOSE_DIR}" != "/" ]] || vps_die "tg-ws-proxy Compose directory is unsafe"
  [[ "${TG_WS_PROJECT}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || vps_die "tg-ws-proxy Compose project name is invalid"
  [[ ! -e "${TG_WS_COMPOSE_DIR}" ]] || vps_die "tg-ws-proxy is already configured; use update.sh or uninstall.sh first"
}

install_packages() {
  vps_install_packages \
    ca-certificates \
    curl \
    iproute2 \
    jq \
    netcat-openbsd \
    openssl \
    tar \
    ufw
}

write_configuration() {
  local image="$1"
  local version="$2"
  local secret="$3"
  local client_url=""
  local temp_file=""

  install -d -m 700 "${TG_WS_COMPOSE_DIR}"
  install -m 600 "${COMPOSE_TEMPLATE}" "${TG_WS_COMPOSE_DIR}/compose.yaml"
  tg_ws_write_env \
    "${TG_WS_COMPOSE_DIR}" \
    "${image}" \
    "${version}" \
    "${TG_WS_PROXY_PUBLIC_HOST}" \
    "${TG_WS_PROXY_PUBLIC_IPV4}" \
    "${TG_WS_PROXY_IPV6}" \
    "${TG_WS_PROXY_PORT}" \
    "${secret}" \
    "${TG_WS_PROXY_CF_WORKER}"

  temp_file="$(mktemp)"
  tg_ws_render_worker "${WORKER_TEMPLATE}" "${TG_WS_PROXY_PUBLIC_IPV4}" "${TG_WS_PROXY_IPV6}" > "${temp_file}"
  install -m 600 "${temp_file}" "${TG_WS_COMPOSE_DIR}/cf-worker.js"
  rm -f -- "${temp_file}"

  client_url="$(tg_ws_client_url "${TG_WS_PROXY_PUBLIC_HOST}" "${TG_WS_PROXY_PORT}" "${secret}")"
  printf '%s\n' "${client_url}" > "${TG_WS_COMPOSE_DIR}/client.txt"
  chmod 600 "${TG_WS_COMPOSE_DIR}/client.txt"
  printf '%s\n' "${TG_WS_PROXY_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${TG_WS_COMPOSE_DIR}" > "${SCRIPT_DIR}/compose-dir.txt"
  printf '%s\n' "${version}" > "${SCRIPT_DIR}/installed-version.txt"
}

setup_firewall() {
  local added_rule=1

  if ufw show added 2>/dev/null | grep -Eq "^ufw allow ${TG_WS_PROXY_PORT}/tcp$"; then
    added_rule=0
  else
    ufw allow "${TG_WS_PROXY_PORT}/tcp" >/dev/null
  fi
  printf '%s\n' "${added_rule}" > "${SCRIPT_DIR}/firewall-rule-added.txt"
  if ! ufw status | grep -q "Status: active"; then
    printf 'Before enabling UFW, verify that your SSH port already has an allow rule.\n'
  fi
  vps_enable_ufw_if_needed "Skipped enabling UFW. The tg-ws-proxy port was still added to UFW rules."
}

rollback_deployment() {
  if vps_docker_is_ready && [[ -d "${TG_WS_COMPOSE_DIR}" ]]; then
    vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -f "${SCRIPT_DIR}/firewall-rule-added.txt" && "$(<"${SCRIPT_DIR}/firewall-rule-added.txt")" == "1" ]]; then
    vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" tcp
  fi
  vps_safe_remove_path "${TG_WS_COMPOSE_DIR}"
  rm -f -- \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/compose-dir.txt" \
    "${SCRIPT_DIR}/firewall-rule-added.txt" \
    "${SCRIPT_DIR}/installed-version.txt"
}

print_summary() {
  local version="$1"
  local client_url=""

  client_url="$(<"${TG_WS_COMPOSE_DIR}/client.txt")"
  printf '\n============================================================\n'
  printf 'TG WS Proxy installation complete.\n'
  printf '============================================================\n\n'
  printf 'Version:             %s\n' "${version}"
  printf 'IPv4 listener:       0.0.0.0:%s\n' "${TG_WS_PROXY_PORT}"
  if [[ -n "${TG_WS_PROXY_IPV6}" ]]; then
    printf 'IPv6 listener:       [%s]:%s\n' "${TG_WS_PROXY_IPV6}" "${TG_WS_PROXY_PORT}"
  else
    printf 'IPv6 listener:       not configured\n'
  fi
  printf 'Compose directory:   %s\n' "${TG_WS_COMPOSE_DIR}"
  printf 'Cloudflare Worker:   %s\n' "${TG_WS_PROXY_CF_WORKER:-not configured}"
  printf '\nTelegram connection link:\n%s\n' "${client_url}"
  printf '\nContainer status:\n'
  vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" ps
  printf '\nLogs:\n  sudo docker compose --project-directory %s --project-name %s logs -f\n' "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}"
  if [[ -z "${TG_WS_PROXY_CF_WORKER}" ]]; then
    printf '\nA source-IP and Telegram-DC restricted Worker is ready at:\n  %s/cf-worker.js\n' "${TG_WS_COMPOSE_DIR}"
  fi
}

main() {
  local image=""
  local secret=""
  local source_root=""
  local version=""

  [[ $# -eq 0 ]] || vps_die "usage: install.sh"
  vps_require_root "sudo ./install.sh"
  require_files
  vps_require_supported_apt_os
  vps_require_systemd

  printf 'Docker-based TG WS Proxy server installation\n\n'
  collect_settings
  printf '\nThis will install required apt packages and Docker CE if Docker is completely absent,\n'
  printf 'build tg-ws-proxy %s from its tagged source, open TCP port %s, and run\n' "${TG_WS_PROXY_VERSION}" "${TG_WS_PROXY_PORT}"
  if [[ -n "${TG_WS_PROXY_IPV6}" ]]; then
    printf 'separate IPv4 and IPv6 host-network containers sharing one secret.\n'
  else
    printf 'an IPv4 host-network container.\n'
  fi
  printf 'Existing Xray, Nginx, Telemt, and unrelated Docker resources will not be changed.\n'
  if ! vps_confirm "Continue?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  install_packages
  vps_require_commands curl ip jq nc openssl ss tar ufw
  vps_docker_ensure_ready
  vps_require_commands docker
  tg_ws_require_local_global_ipv6 "${TG_WS_PROXY_IPV6}"
  tg_ws_require_port_available "${TG_WS_PROXY_PORT}"

  version="$(tg_ws_resolve_version "${TG_WS_PROXY_VERSION}")"
  image="$(tg_ws_image_ref "${version}" "${TG_WS_IMAGE_REPOSITORY}")"
  source_root="$(mktemp -d)"
  trap '[[ -z "${source_root:-}" ]] || rm -rf -- "${source_root}"' EXIT
  tg_ws_download_source "${version}" "${source_root}/source"
  tg_ws_build_image "${source_root}/source" "${version}" "${TG_WS_IMAGE_REPOSITORY}"
  tg_ws_validate_image "${image}"
  secret="$(openssl rand -hex 16 | tr -d '\r\n')"
  tg_ws_validate_secret "${secret}"

  write_configuration "${image}" "${version}" "${secret}"
  if ! vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" config --quiet; then
    rollback_deployment
    vps_die "generated tg-ws-proxy Compose configuration is invalid"
  fi
  setup_firewall
  if ! vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" up -d --remove-orphans \
    || ! tg_ws_verify_running "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${TG_WS_PROXY_IPV6}" "${TG_WS_PROXY_PORT}"; then
    rollback_deployment
    vps_die "tg-ws-proxy containers did not become reachable; generated configuration was removed"
  fi

  print_summary "${version}"
}

main "$@"
