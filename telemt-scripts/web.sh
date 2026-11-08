#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 1 && "$1" =~ ^(enable|disable|status)$ ]] || { printf 'usage: web.sh enable|disable|status\n' >&2; exit 1; }
exec python3 -B "${SCRIPT_DIR}/web-config.py" "$1"
