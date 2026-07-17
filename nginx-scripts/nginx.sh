#!/usr/bin/env bash

[[ -n "${VPS_NGINX_SH:-}" ]] && return 0
VPS_NGINX_SH=1

nginx_validate_domain() {
  local domain="$1"
  local label=""
  local -a labels=()

  [[ -n "${domain}" && ${#domain} -le 253 ]] || vps_die "fallback domain is empty or too long"
  [[ "${domain}" != *. && "${domain}" == *.* ]] || vps_die "fallback domain must be a fully qualified domain name"
  IFS='.' read -r -a labels <<< "${domain}"
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
      || vps_die "fallback domain contains an invalid DNS label: ${label}"
  done
}

nginx_validate_email() {
  local email="$1"

  [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || vps_die "a valid email address is required for Let's Encrypt"
}

nginx_validate_internal_port() {
  local port="$1"

  vps_validate_port "${port}"
  [[ "${port}" != "80" && "${port}" != "443" ]] \
    || vps_die "internal Nginx TLS port must not be 80 or 443"
}

nginx_render_bootstrap_config() {
  local domain="$1"
  local web_root="$2"

  printf '%s\n' \
    'server {' \
    '    listen 80;' \
    '    listen [::]:80;' \
    "    server_name ${domain};" \
    '' \
    '    location ^~ /.well-known/acme-challenge/ {' \
    "        root ${web_root};" \
    '        default_type text/plain;' \
    "        try_files \$uri =404;" \
    '    }' \
    '' \
    '    location / {' \
    '        return 404;' \
    '    }' \
    '}'
}

nginx_render_site_config() {
  local domain="$1"
  local internal_port="$2"
  local web_root="$3"
  local template="${NGINX_TEMPLATE:?NGINX_TEMPLATE is required}"
  local escaped_domain=""
  local escaped_web_root=""

  escaped_domain="$(vps_sed_escape "${domain}")"
  escaped_web_root="$(vps_sed_escape "${web_root}")"
  sed \
    -e "s|:DOMAIN:|${escaped_domain}|g" \
    -e "s|:INTERNAL_PORT:|${internal_port}|g" \
    -e "s|:WEB_ROOT:|${escaped_web_root}|g" \
    "${template}"
}
