#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INBOUND_TAG="vless-reality-vision-443"
CLIENTS_DIR="${SCRIPT_DIR}/clients"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/xray.sh
. "${REPO_ROOT}/lib/xray.sh"

xray_remove_client_main "$@"
