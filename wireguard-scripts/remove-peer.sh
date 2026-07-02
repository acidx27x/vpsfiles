#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wireguard-scripts/common.sh
. "${SCRIPT_DIR}/common.sh"
cd "${SCRIPT_DIR}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=wireguard-scripts/wg.sh
. "${SCRIPT_DIR}/wg.sh"

wg_family_remove_peer_main "$@"
