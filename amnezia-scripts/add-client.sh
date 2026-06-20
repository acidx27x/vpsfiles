#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/core.sh
. "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/wg_family.sh
. "${REPO_ROOT}/lib/wg_family.sh"

WG_FAMILY_NAME="AmneziaWG"
WG_FAMILY_TOOL="awg"
WG_FAMILY_QUICK="awg-quick"
WG_FAMILY_DIR="/etc/amnezia/amneziawg"
WG_FAMILY_DEFAULT_IF="awg0"
WG_FAMILY_CLIENT_PREFIX="awg0"
WG_FAMILY_DEFAULT_PORT="52820"
WG_FAMILY_DEFAULT_NET="10.9.0.0/24"
WG_FAMILY_DEFAULT_NET6="fd52:52:52::/64"

wg_family_protocol_load_client_state() {
  [[ -f obfuscation.env ]] || vps_die "obfuscation.env is missing; run install.sh first"
  # shellcheck source=/dev/null
  . ./obfuscation.env
}

wg_family_protocol_add_client_sed_args() {
  WG_FAMILY_CLIENT_SED_ARGS+=(
    -e "s|:AWG_MTU:|$(vps_sed_escape "${AWG_MTU}")|g"
    -e "s|:AWG_JC:|$(vps_sed_escape "${AWG_JC}")|g"
    -e "s|:AWG_JMIN:|$(vps_sed_escape "${AWG_JMIN}")|g"
    -e "s|:AWG_JMAX:|$(vps_sed_escape "${AWG_JMAX}")|g"
    -e "s|:AWG_S1:|$(vps_sed_escape "${AWG_S1}")|g"
    -e "s|:AWG_S2:|$(vps_sed_escape "${AWG_S2}")|g"
    -e "s|:AWG_S3:|$(vps_sed_escape "${AWG_S3}")|g"
    -e "s|:AWG_S4:|$(vps_sed_escape "${AWG_S4}")|g"
    -e "s|:AWG_H1:|$(vps_sed_escape "${AWG_H1}")|g"
    -e "s|:AWG_H2:|$(vps_sed_escape "${AWG_H2}")|g"
    -e "s|:AWG_H3:|$(vps_sed_escape "${AWG_H3}")|g"
    -e "s|:AWG_H4:|$(vps_sed_escape "${AWG_H4}")|g"
    -e "s|:AWG_I1:|$(vps_sed_escape "${AWG_I1}")|g"
  )
}

wg_family_add_client_main "$@"
