#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/wg_family.sh
. "${REPO_ROOT}/lib/wg_family.sh"

WG_FAMILY_NAME="WireGuard"
WG_FAMILY_TOOL="wg"
WG_FAMILY_QUICK="wg-quick"
WG_FAMILY_DIR="/etc/wireguard"
WG_FAMILY_DEFAULT_IF="wg0"
WG_FAMILY_CLIENT_PREFIX="wg0"
WG_FAMILY_DEFAULT_PORT="51820"
WG_FAMILY_DEFAULT_NET="10.8.0.0/24"
WG_FAMILY_DEFAULT_NET6="fd42:42:42::/64"

wg_family_remove_client_main "$@"
