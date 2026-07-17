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

nginx_certificate_name_from_config() {
  local config_file="$1"
  local letsencrypt_root="${2%/}"

  [[ -f "${config_file}" ]] || return 1
  awk -v prefix="${letsencrypt_root}/live/" '
    $1 == "ssl_certificate" {
      path = $2
      sub(/;$/, "", path)
      if (index(path, prefix) != 1 || path !~ /\/fullchain\.pem$/) {
        next
      }
      path = substr(path, length(prefix) + 1)
      sub(/\/fullchain\.pem$/, "", path)
      if (path != "" && path !~ /\//) {
        print path
        exit
      }
    }
  ' "${config_file}"
}

nginx_find_certificate_references() {
  local certificate_dir="${1%/}"
  local reference_roots="$2"
  local root=""
  local match=""
  local -a roots=()

  IFS=':' read -r -a roots <<< "${reference_roots}"
  for root in "${roots[@]}"; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r match; do
      [[ -n "${match}" ]] && printf '%s\n' "${match}"
    done < <(grep -R -l -F -- "${certificate_dir}/" "${root}" 2>/dev/null || true)
  done
}

nginx_has_port_80_listener() {
  local nginx_config_root="$1"

  [[ -d "${nginx_config_root}" ]] || return 1
  grep -R -E -q -- '(^|[[:space:]{;])listen[[:space:]]+([^;[:space:]]*:)?80([[:space:];]|$)' "${nginx_config_root}" 2>/dev/null
}
