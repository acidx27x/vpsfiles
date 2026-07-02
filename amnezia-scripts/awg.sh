#!/usr/bin/env bash

[[ -n "${VPS_AWG_SH:-}" ]] && return 0
VPS_AWG_SH=1

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
