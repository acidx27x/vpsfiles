#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=amnezia-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
cd "${SCRIPT_DIR}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=wireguard-scripts/wg.sh
. "${REPO_ROOT}/wireguard-scripts/wg.sh"

wg_family_remove_client_main "$@"
