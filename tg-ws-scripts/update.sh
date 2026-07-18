#!/usr/bin/env bash
set -euo pipefail
umask 077

TG_WS_COMPOSE_DIR_DEFAULT="/etc/tg-ws-proxy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
TG_WS_PROXY_VERSION="${TG_WS_PROXY_VERSION:-latest}"
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

restore_previous_release() {
  local env_backup="$1"
  local previous_state="$2"
  local ipv6="$3"
  local port="$4"

  install -m 600 "${env_backup}" "${TG_WS_COMPOSE_DIR}/.env"
  if [[ "${previous_state}" == "running" ]]; then
    vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" up -d --force-recreate --remove-orphans \
      && tg_ws_verify_running "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${ipv6}" "${port}"
  else
    vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" create --force-recreate \
      && [[ "$(tg_ws_project_state "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${ipv6}")" == "stopped" ]]
  fi
}

main() {
  local backup_directory=""
  local current_image=""
  local current_version=""
  local env_file="${TG_WS_COMPOSE_DIR}/.env"
  local fake_tls_domain=""
  local image=""
  local ipv4=""
  local ipv6=""
  local port=""
  local previous_state=""
  local public_host=""
  local secret=""
  local source_root=""
  local version=""
  local worker_domain=""

  [[ $# -eq 0 ]] || vps_die "usage: update.sh"
  vps_require_root "sudo ./update.sh"
  tg_ws_validate_version "${TG_WS_PROXY_VERSION}"
  [[ "${TG_WS_COMPOSE_DIR}" == /* && "${TG_WS_COMPOSE_DIR}" != "/" && -f "${TG_WS_COMPOSE_DIR}/compose.yaml" && -f "${env_file}" ]] \
    || vps_die "tg-ws-proxy state is missing; run install.sh first"
  vps_docker_is_ready || vps_die "Docker Engine and Compose v2 must be working before updating tg-ws-proxy"

  current_image="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_IMAGE)"
  current_version="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_VERSION)"
  public_host="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_PUBLIC_HOST)"
  ipv4="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_PUBLIC_IPV4)"
  ipv6="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_IPV6)"
  port="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_PORT)"
  secret="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_SECRET)"
  fake_tls_domain="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_FAKE_TLS_DOMAIN)"
  worker_domain="$(tg_ws_env_get "${env_file}" TG_WS_PROXY_CF_WORKER)"
  previous_state="$(tg_ws_project_state "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${ipv6}")"
  [[ "${previous_state}" == "running" || "${previous_state}" == "stopped" ]] \
    || vps_die "tg-ws-proxy containers are incomplete or have mixed running state; repair them before updating"
  docker image inspect "${current_image}" >/dev/null 2>&1 || vps_die "currently configured tg-ws-proxy image is missing: ${current_image}"

  version="$(tg_ws_resolve_version "${TG_WS_PROXY_VERSION}")"
  if [[ "${version}" == "${current_version}" ]]; then
    printf 'tg-ws-proxy is already at %s.\n' "${version}"
    exit 0
  fi
  image="$(tg_ws_image_ref "${version}" "${TG_WS_IMAGE_REPOSITORY}")"

  printf 'This will build tg-ws-proxy %s, preserve its addresses, port, secret, FakeTLS, Worker, and UFW state,\n' "${version}"
  printf 'then recreate its configured containers. Current state: %s.\n' "${previous_state}"
  if ! vps_confirm "Continue with update?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  source_root="$(mktemp -d)"
  trap '[[ -z "${source_root:-}" ]] || rm -rf -- "${source_root}"' EXIT
  tg_ws_download_source "${version}" "${source_root}/source"
  tg_ws_build_image "${source_root}/source" "${version}" "${TG_WS_IMAGE_REPOSITORY}"
  tg_ws_validate_image "${image}"

  backup_directory="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "${backup_directory}"
  install -m 600 "${env_file}" "${backup_directory}/.env"
  tg_ws_write_env \
    "${TG_WS_COMPOSE_DIR}" \
    "${image}" \
    "${version}" \
    "${public_host}" \
    "${ipv4}" \
    "${ipv6}" \
    "${port}" \
    "${secret}" \
    "${worker_domain}" \
    "${fake_tls_domain}"

  if ! vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" config --quiet; then
    install -m 600 "${backup_directory}/.env" "${env_file}"
    vps_die "updated Compose configuration is invalid; the previous environment was restored"
  fi

  if [[ "${previous_state}" == "running" ]]; then
    if ! vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" up -d --force-recreate --remove-orphans \
      || ! tg_ws_verify_running "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${ipv6}" "${port}"; then
      restore_previous_release "${backup_directory}/.env" "${previous_state}" "${ipv6}" "${port}" \
        || vps_die "tg-ws-proxy update and rollback both failed; inspect the Compose project immediately"
      vps_die "tg-ws-proxy update failed; the previous image and running containers were restored"
    fi
  else
    if ! vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" create --force-recreate \
      || [[ "$(tg_ws_project_state "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" "${ipv6}")" != "stopped" ]]; then
      restore_previous_release "${backup_directory}/.env" "${previous_state}" "${ipv6}" "${port}" \
        || vps_die "tg-ws-proxy update and rollback both failed; inspect the Compose project immediately"
      vps_die "tg-ws-proxy update failed; the previous stopped containers were restored"
    fi
  fi

  printf '%s\n' "${version}" > "${SCRIPT_DIR}/installed-version.txt"
  tg_ws_cleanup_old_images
  printf 'tg-ws-proxy update complete: %s -> %s.\n' "${current_version}" "${version}"
  if [[ "${previous_state}" == "stopped" ]]; then
    printf 'The containers were stopped before the update and remain stopped.\n'
  fi
  printf 'Previous environment backup: %s\n' "${backup_directory}"
}

main "$@"
