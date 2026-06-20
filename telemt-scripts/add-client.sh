#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLIENTS_DIR="${SCRIPT_DIR}/clients"
MAX_UNIQUE_IPS_DEFAULT="2"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/telemt.sh
. "${REPO_ROOT}/lib/telemt.sh"

telemt_add_client_main "$@"
