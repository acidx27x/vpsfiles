#!/usr/bin/env bash
set -euo pipefail

TG_WS_COMPOSE_DIR_DEFAULT="/etc/tg-ws-proxy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
TG_WS_COMPOSE_DIR="${TG_WS_COMPOSE_DIR_DEFAULT}"
TG_WS_PROJECT="tg-ws-proxy"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/docker.sh
. "${REPO_ROOT}/core/docker.sh"
# shellcheck source=core/uninstall.sh
. "${REPO_ROOT}/core/uninstall.sh"
# shellcheck source=tg-ws-scripts/tg-ws.sh
. "${SCRIPT_DIR}/tg-ws.sh"

main() {
  local image_id=""
  local -a image_ids=()

  [[ $# -eq 0 ]] || vps_die "usage: uninstall.sh"
  vps_require_root "sudo ./uninstall.sh"
  [[ "${TG_WS_COMPOSE_DIR}" == /* && "${TG_WS_COMPOSE_DIR}" != "/" ]] || vps_die "tg-ws-proxy Compose directory is unsafe"
  [[ "${TG_WS_PROJECT}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || vps_die "tg-ws-proxy Compose project name is invalid"
  [[ "${BACKUP_ROOT}" == "${SCRIPT_DIR}/"* ]] || vps_die "tg-ws-proxy backup directory is outside the bundle: ${BACKUP_ROOT}"

  if vps_docker_is_ready; then
    mapfile -t image_ids < <(docker image ls --filter "label=${TG_WS_BUNDLE_LABEL}" --format '{{.ID}}' | sort -u)
  elif [[ -d "${TG_WS_COMPOSE_DIR}" ]]; then
    vps_docker_is_ready || vps_die "Docker must be working so tg-ws-proxy containers can be removed safely before deleting configuration"
  fi

  vps_uninstall_print_plan "TG WS Proxy" \
    "  Compose project:    ${TG_WS_PROJECT}" \
    "  Configuration:      ${TG_WS_COMPOSE_DIR}" \
    "  UFW rule:           tg-ws-proxy TCP rule, only if added by this bundle" \
    "  Bundle images:      ${#image_ids[@]} labeled image(s)" \
    "  Update backups:     ${BACKUP_ROOT}" \
    "  Script state:       exported link, port, Compose directory, firewall ownership, installed version"
  printf '\nDocker Engine, its apt repository, daemon settings, global cache, and unrelated Docker resources will remain installed.\n\n'
  if ! vps_confirm "Continue with uninstall?"; then
    printf 'Aborted before making changes.\n'
    exit 1
  fi

  if [[ -d "${TG_WS_COMPOSE_DIR}" ]]; then
    vps_docker_compose "${TG_WS_COMPOSE_DIR}" "${TG_WS_PROJECT}" down --remove-orphans
  fi
  if [[ -f "${SCRIPT_DIR}/firewall-rule-added.txt" && "$(<"${SCRIPT_DIR}/firewall-rule-added.txt")" == "1" ]]; then
    vps_ufw_delete_saved_rule "${SCRIPT_DIR}/server-port.txt" tcp
  fi
  vps_safe_remove_path "${TG_WS_COMPOSE_DIR}"
  vps_safe_remove_path "${BACKUP_ROOT}"
  for image_id in "${image_ids[@]}"; do
    if ! docker image rm "${image_id}"; then
      printf 'Kept image still used by another container: %s\n' "${image_id}" >&2
    fi
  done
  rm -f -- \
    "${SCRIPT_DIR}/tg-ws-link.txt" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/compose-dir.txt" \
    "${SCRIPT_DIR}/firewall-rule-added.txt" \
    "${SCRIPT_DIR}/installed-version.txt"

  printf 'TG WS Proxy uninstall complete. Generated configuration and client credentials are not recoverable unless separately backed up.\n'
}

main "$@"
