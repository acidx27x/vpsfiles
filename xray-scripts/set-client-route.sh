#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INBOUND_TAG="vless-reality-vision-443"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=xray-scripts/xray.sh
. "${SCRIPT_DIR}/xray.sh"

main() {
  if [[ $# -ne 2 ]]; then
    printf 'usage: set-client-route.sh (--next-hop|--direct) <client_name>\n'
    exit 1
  fi

  local route=""
  case "$1" in
    --next-hop)
      route="next-hop"
      ;;
    --direct)
      route="direct"
      ;;
    *)
      printf 'usage: set-client-route.sh (--next-hop|--direct) <client_name>\n'
      exit 1
      ;;
  esac

  local client_name="$2"
  local config_file=""
  local service=""

  vps_require_root "sudo ./set-client-route.sh ..."
  vps_validate_client_name "${client_name}"
  xray_validate_client_route "${route}"
  vps_require_commands jq xray

  config_file="$(vps_read_file_or_default xray-config-path.txt "/usr/local/etc/xray/config.json")"
  service="$(vps_read_file_or_default xray-service.txt "xray")"
  [[ -f "${config_file}" ]] || vps_die "server config is missing: ${config_file}"
  xray_require_inbound_tag "${config_file}"

  vps_info "Setting Xray VLESS client route: ${client_name} (${route})"
  xray_set_client_route_in_config "${config_file}" "${client_name}" "${route}" "${service}"
  vps_info "Client route is ${route}: ${client_name}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
