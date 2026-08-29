#!/usr/bin/env bash

[[ -n "${VPS_XRAY_SH:-}" ]] && return 0
VPS_XRAY_SH=1

XRAY_INBOUND_TAG_DEFAULT="vless-reality-vision-443"
XRAY_CLIENTS_DIR_DEFAULT="${SCRIPT_DIR}/clients"
XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
XRAY_NEXT_HOP_OUTBOUND_TAG="next-hop"
XRAY_CLIENT_NEXT_HOP_RULE_TAG="client-next-hop"
XRAY_LOCAL_SOCKS_INBOUND_TAG="local-socks"
XRAY_LOCAL_SOCKS_RULE_TAG="local-socks-next-hop"
XRAY_RUSSIAN_DOMAIN_RULE_TAG="russian-domain-direct"
XRAY_RUSSIAN_IP_RULE_TAG="russian-ip-direct"
XRAY_GEODATA_CRON="30 4 * * 5"
XRAY_GEODATA_DIR_DEFAULT="/usr/local/share/xray"
XRAY_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
XRAY_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

XRAY_NEXT_HOP_ADDRESS=""
XRAY_NEXT_HOP_PORT=""
XRAY_NEXT_HOP_UUID=""
XRAY_NEXT_HOP_SERVER_NAME=""
XRAY_NEXT_HOP_FINGERPRINT=""
XRAY_NEXT_HOP_PUBLIC_KEY=""
XRAY_NEXT_HOP_SHORT_ID=""
XRAY_NEXT_HOP_SPIDER_X=""

xray_inbound_tag() {
  printf '%s\n' "${INBOUND_TAG:-${XRAY_INBOUND_TAG_DEFAULT}}"
}

xray_require_inbound_tag() {
  local config_file="$1"
  local tag=""

  tag="$(xray_inbound_tag)"
  jq -e --arg tag "${tag}" 'any(.inbounds[]?; .tag == $tag)' "${config_file}" >/dev/null || vps_die "inbound tag is missing from ${config_file}: ${tag}"
}

xray_validate_client_route() {
  local route="$1"

  [[ "${route}" == "direct" || "${route}" == "next-hop" ]] || vps_die "route must be direct or next-hop: ${route}"
}

xray_validate_russian_split_routing() {
  local enabled="$1"

  [[ "${enabled}" == "0" || "${enabled}" == "1" ]] || vps_die "XRAY_RUSSIAN_SPLIT_ROUTING must be 0 or 1"
}

xray_require_next_hop_outbound() {
  local config_file="$1"

  jq -e --arg tag "${XRAY_NEXT_HOP_OUTBOUND_TAG}" 'any(.outbounds[]?; .tag == $tag)' "${config_file}" >/dev/null \
    || vps_die "next-hop outbound is missing from ${config_file}; run install.sh again with a next-hop URI"
}

xray_require_client_in_inbound() {
  local config_file="$1"
  local client_name="$2"
  local tag=""

  tag="$(xray_inbound_tag)"
  jq -e \
    --arg tag "${tag}" \
    --arg name "${client_name}" \
    'any(.inbounds[]?; .tag == $tag and any(.settings.clients[]?; .email == $name))' \
    "${config_file}" >/dev/null \
    || vps_die "client is missing from inbound ${tag}: ${client_name}"
}

xray_generate_uuid() {
  xray uuid | tr -d '\r\n'
}

xray_generate_short_id() {
  openssl rand -hex 8
}

xray_validate_local_socks_port() {
  local socks_port="$1"
  local vless_port="$2"

  vps_validate_port "${socks_port}"
  vps_validate_port "${vless_port}"
  (( 10#${socks_port} != 10#${vless_port} )) \
    || vps_die "local SOCKS5 port must differ from the Xray VLESS port"
}

xray_run_installer() {
  local action="$1"
  local installer=""

  shift

  case "${action}" in
    install|install-geodata) ;;
    *) vps_die "unsupported Xray installer action: ${action}" ;;
  esac

  installer="$(mktemp)"
  if ! curl -fsSL "${XRAY_INSTALLER_URL}" -o "${installer}"; then
    rm -f "${installer}"
    return 1
  fi
  if ! bash "${installer}" "${action}" "$@"; then
    rm -f "${installer}"
    return 1
  fi
  rm -f "${installer}"
}

xray_uri_decode() {
  local encoded="$1"
  local decoded=""
  local hex=""
  local byte=""
  local byte_value=0

  while [[ -n "${encoded}" ]]; do
    if [[ "${encoded}" == %* ]]; then
      [[ "${encoded}" =~ ^%([0-9A-Fa-f]{2}) ]] || vps_die "next-hop URI contains invalid percent encoding"
      hex="${BASH_REMATCH[1]}"
      byte_value=$((16#${hex^^}))
      (( byte_value >= 32 && byte_value != 127 )) || vps_die "next-hop URI contains a control character"
      printf -v byte '%b' "\\x${hex}"
      decoded+="${byte}"
      encoded="${encoded:3}"
    else
      decoded+="${encoded:0:1}"
      encoded="${encoded:1}"
    fi
  done

  printf '%s' "${decoded}"
}

xray_parse_next_hop_uri() {
  local uri="$1"
  local payload=""
  local authority=""
  local query=""
  local uuid_encoded=""
  local host_port=""
  local remainder=""
  local pair=""
  local key=""
  local value=""
  local -a query_parts=()
  local -A query_values=()
  local -A query_seen=()

  XRAY_NEXT_HOP_ADDRESS=""
  XRAY_NEXT_HOP_PORT=""
  XRAY_NEXT_HOP_UUID=""
  XRAY_NEXT_HOP_SERVER_NAME=""
  XRAY_NEXT_HOP_FINGERPRINT=""
  XRAY_NEXT_HOP_PUBLIC_KEY=""
  XRAY_NEXT_HOP_SHORT_ID=""
  XRAY_NEXT_HOP_SPIDER_X=""

  [[ "${uri}" == vless://* ]] || vps_die "next-hop URI must start with vless://"
  payload="${uri#vless://}"
  payload="${payload%%#*}"
  [[ "${payload}" == *\?* ]] || vps_die "next-hop URI is missing query settings"
  authority="${payload%%\?*}"
  query="${payload#*\?}"
  [[ "${authority}" == *@* && -n "${query}" ]] || vps_die "next-hop URI is missing authority or query settings"

  uuid_encoded="${authority%%@*}"
  host_port="${authority#*@}"
  [[ -n "${uuid_encoded}" && -n "${host_port}" && "${host_port}" != *@* ]] || vps_die "next-hop URI authority is invalid"

  XRAY_NEXT_HOP_UUID="$(xray_uri_decode "${uuid_encoded}")"
  if [[ "${host_port}" == \[* ]]; then
    [[ "${host_port}" == *\]:* ]] || vps_die "next-hop IPv6 endpoint must use [address]:port"
    XRAY_NEXT_HOP_ADDRESS="${host_port#\[}"
    XRAY_NEXT_HOP_ADDRESS="${XRAY_NEXT_HOP_ADDRESS%%\]*}"
    remainder="${host_port#*\]}"
    [[ "${remainder}" == :* ]] || vps_die "next-hop IPv6 endpoint is missing a port"
    XRAY_NEXT_HOP_PORT="${remainder#:}"
  else
    [[ "${host_port}" == *:* ]] || vps_die "next-hop endpoint is missing a port"
    XRAY_NEXT_HOP_ADDRESS="${host_port%:*}"
    XRAY_NEXT_HOP_PORT="${host_port##*:}"
    [[ "${XRAY_NEXT_HOP_ADDRESS}" != *:* ]] || vps_die "next-hop IPv6 endpoint must be enclosed in brackets"
  fi

  XRAY_NEXT_HOP_ADDRESS="$(xray_uri_decode "${XRAY_NEXT_HOP_ADDRESS}")"
  [[ -n "${XRAY_NEXT_HOP_ADDRESS}" && "${XRAY_NEXT_HOP_ADDRESS}" =~ ^[^][[:space:]/]+$ ]] || vps_die "next-hop address is invalid"
  vps_validate_port "${XRAY_NEXT_HOP_PORT}"
  [[ "${XRAY_NEXT_HOP_UUID}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || vps_die "next-hop URI must contain a generated UUID"

  IFS='&' read -r -a query_parts <<< "${query}"
  for pair in "${query_parts[@]}"; do
    [[ "${pair}" == *=* ]] || vps_die "next-hop URI contains a malformed query setting"
    key="$(xray_uri_decode "${pair%%=*}")"
    value="$(xray_uri_decode "${pair#*=}")"
    [[ "${key}" =~ ^[A-Za-z0-9._-]+$ ]] || vps_die "next-hop URI contains an invalid query key"
    [[ -z "${query_seen[${key}]+set}" ]] || vps_die "next-hop URI contains a duplicate query setting: ${key}"
    query_seen["${key}"]=1
    query_values["${key}"]="${value}"
  done

  [[ "${query_values[type]:-}" == "raw" ]] || vps_die "next-hop URI must use type=raw"
  [[ "${query_values[security]:-}" == "reality" ]] || vps_die "next-hop URI must use security=reality"
  [[ "${query_values[encryption]:-}" == "none" ]] || vps_die "next-hop URI must use encryption=none"
  [[ "${query_values[flow]:-}" == "xtls-rprx-vision" ]] || vps_die "next-hop URI must use flow=xtls-rprx-vision"

  XRAY_NEXT_HOP_SERVER_NAME="${query_values[sni]:-}"
  XRAY_NEXT_HOP_FINGERPRINT="${query_values[fp]:-}"
  XRAY_NEXT_HOP_PUBLIC_KEY="${query_values[pbk]:-}"
  XRAY_NEXT_HOP_SHORT_ID="${query_values[sid]:-}"
  XRAY_NEXT_HOP_SPIDER_X="${query_values[spx]:-}"

  [[ "${XRAY_NEXT_HOP_SERVER_NAME}" =~ ^[^[:space:]/]+$ ]] || vps_die "next-hop URI has an invalid or missing SNI"
  [[ "${XRAY_NEXT_HOP_FINGERPRINT}" =~ ^[A-Za-z0-9_-]+$ ]] || vps_die "next-hop URI has an invalid or missing fingerprint"
  [[ "${XRAY_NEXT_HOP_PUBLIC_KEY}" =~ ^[A-Za-z0-9_-]+$ ]] || vps_die "next-hop URI has an invalid or missing REALITY public key"
  [[ "${XRAY_NEXT_HOP_SHORT_ID}" =~ ^[0-9A-Fa-f]{2,16}$ ]] || vps_die "next-hop URI has an invalid or missing REALITY short ID"
  (( ${#XRAY_NEXT_HOP_SHORT_ID} % 2 == 0 )) || vps_die "next-hop REALITY short ID must have an even number of characters"
  [[ "${XRAY_NEXT_HOP_SPIDER_X}" == /* ]] || vps_die "next-hop URI has an invalid or missing spider path"
}

xray_render_next_hop_config() {
  local source_file="$1"
  local output_file="$2"

  jq \
    --arg address "${XRAY_NEXT_HOP_ADDRESS}" \
    --argjson port "${XRAY_NEXT_HOP_PORT}" \
    --arg uuid "${XRAY_NEXT_HOP_UUID}" \
    --arg server_name "${XRAY_NEXT_HOP_SERVER_NAME}" \
    --arg fingerprint "${XRAY_NEXT_HOP_FINGERPRINT}" \
    --arg public_key "${XRAY_NEXT_HOP_PUBLIC_KEY}" \
    --arg short_id "${XRAY_NEXT_HOP_SHORT_ID}" \
    --arg spider_x "${XRAY_NEXT_HOP_SPIDER_X}" \
    '.outbounds += [{
      "tag": "next-hop",
      "protocol": "vless",
      "settings": {
        "address": $address,
        "port": $port,
        "id": $uuid,
        "encryption": "none",
        "flow": "xtls-rprx-vision"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "minClientVer": "0.0.0",
          "serverName": $server_name,
          "fingerprint": $fingerprint,
          "password": $public_key,
          "shortId": $short_id,
          "spiderX": $spider_x
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        }
      }
    }]' \
    "${source_file}" > "${output_file}"
}

xray_render_russian_split_config() {
  local source_file="$1"
  local output_file="$2"
  local inbound_tag=""

  xray_require_next_hop_outbound "${source_file}"
  inbound_tag="$(xray_inbound_tag)"
  jq \
    --arg inbound_tag "${inbound_tag}" \
    --arg dns_tag "dns-next-hop" \
    --arg domain_rule_tag "${XRAY_RUSSIAN_DOMAIN_RULE_TAG}" \
    --arg ip_rule_tag "${XRAY_RUSSIAN_IP_RULE_TAG}" \
    --arg direct_tag "direct" \
    --arg next_hop_tag "${XRAY_NEXT_HOP_OUTBOUND_TAG}" \
    --arg cron "${XRAY_GEODATA_CRON}" \
    --arg geoip_url "${XRAY_GEOIP_URL}" \
    --arg geosite_url "${XRAY_GEOSITE_URL}" \
    '.dns = {
      "servers": [
        "https://1.1.1.1/dns-query",
        "https://8.8.8.8/dns-query"
      ],
      "queryStrategy": "UseIP",
      "tag": $dns_tag
    }
    | .routing.domainStrategy = "IPOnDemand"
    | .routing.rules = ([
      {
        "ruleTag": $dns_tag,
        "type": "field",
        "inboundTag": [$dns_tag],
        "outboundTag": $next_hop_tag
      }
    ] + .routing.rules + [
      {
        "ruleTag": $domain_rule_tag,
        "type": "field",
        "inboundTag": [$inbound_tag],
        "domain": ["geosite:tld-ru", "geosite:category-gov-ru"],
        "outboundTag": $direct_tag
      },
      {
        "ruleTag": $ip_rule_tag,
        "type": "field",
        "inboundTag": [$inbound_tag],
        "ip": ["geoip:ru"],
        "outboundTag": $direct_tag
      }
    ])
    | .geodata = {
      "cron": $cron,
      "outbound": $next_hop_tag,
      "assets": [
        {"url": $geoip_url, "file": "geoip.dat"},
        {"url": $geosite_url, "file": "geosite.dat"}
      ]
    }' \
    "${source_file}" > "${output_file}"
}

xray_render_local_socks_config() {
  local source_file="$1"
  local output_file="$2"
  local port="$3"

  vps_validate_port "${port}"
  xray_require_next_hop_outbound "${source_file}"
  jq \
    --arg inbound_tag "${XRAY_LOCAL_SOCKS_INBOUND_TAG}" \
    --arg rule_tag "${XRAY_LOCAL_SOCKS_RULE_TAG}" \
    --arg outbound_tag "${XRAY_NEXT_HOP_OUTBOUND_TAG}" \
    --argjson port "${port}" \
    '.inbounds += [{
      "tag": $inbound_tag,
      "listen": "127.0.0.1",
      "port": $port,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": false
      }
    }]
    | .routing.rules += [{
      "ruleTag": $rule_tag,
      "type": "field",
      "inboundTag": [$inbound_tag],
      "outboundTag": $outbound_tag
    }]' \
    "${source_file}" > "${output_file}"
}

xray_short_id_exists() {
  local config_file="$1"
  local short_id="$2"

  jq -e --arg sid "${short_id}" '[.inbounds[].streamSettings.realitySettings.shortIds[]?] | index($sid) != null' "${config_file}" >/dev/null
}

xray_uuid_exists() {
  local config_file="$1"
  local uuid="$2"

  jq -e --arg uuid "${uuid}" '[.inbounds[].settings.clients[]?.id] | index($uuid) != null' "${config_file}" >/dev/null
}

xray_service_user() {
  local service="$1"
  local user=""

  user="$(systemctl cat "${service}" 2>/dev/null | awk -F= '
    $1 ~ /^[[:space:]]*User[[:space:]]*$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      user = $2
    }
    END { print user }
  ')"
  printf '%s\n' "${user:-root}"
}

xray_config_uses_managed_geodata() {
  local config_file="$1"

  jq -e '(.geodata.assets // []) | length > 0' "${config_file}" >/dev/null
}

xray_prepare_geodata_permissions() {
  local config_file="$1"
  local service="$2"
  local asset_dir="${3:-${XRAY_GEODATA_DIR_DEFAULT}}"
  local service_group=""
  local service_user=""

  xray_config_uses_managed_geodata "${config_file}" \
    || { printf 'ERROR: scheduled Xray geodata is missing from %s\n' "${config_file}" >&2; return 1; }
  [[ "${asset_dir}" == /* && "${asset_dir}" != "/" && -d "${asset_dir}" ]] \
    || { printf 'ERROR: Xray geodata directory is missing or unsafe: %s\n' "${asset_dir}" >&2; return 1; }
  [[ -f "${asset_dir}/geoip.dat" ]] \
    || { printf 'ERROR: Xray geodata file is missing: %s/geoip.dat\n' "${asset_dir}" >&2; return 1; }
  [[ -f "${asset_dir}/geosite.dat" ]] \
    || { printf 'ERROR: Xray geodata file is missing: %s/geosite.dat\n' "${asset_dir}" >&2; return 1; }

  service_user="$(xray_service_user "${service}")"
  id "${service_user}" >/dev/null 2>&1 \
    || { printf 'ERROR: Xray service user does not exist: %s\n' "${service_user}" >&2; return 1; }
  service_group="$(id -gn "${service_user}")" || return 1
  chown "${service_user}:${service_group}" "${asset_dir}" || return 1
  chown "${service_user}:${service_group}" "${asset_dir}/geoip.dat" "${asset_dir}/geosite.dat" || return 1
  chmod 700 "${asset_dir}" || return 1
  chmod 600 "${asset_dir}/geoip.dat" "${asset_dir}/geosite.dat" || return 1
}

xray_install_config() {
  local source_file="$1"
  local dest_file="$2"
  local service="$3"
  local service_user=""
  local service_group=""

  service_user="$(xray_service_user "${service}")"
  if id "${service_user}" >/dev/null 2>&1; then
    service_group="$(id -gn "${service_user}")"
    install -o "${service_user}" -g "${service_group}" -m 600 "${source_file}" "${dest_file}"
  else
    install -m 600 "${source_file}" "${dest_file}"
  fi
}

xray_apply_rendered_config() {
  local config_file="$1"
  local rendered_file="$2"
  local service="$3"

  if cmp -s "${config_file}" "${rendered_file}"; then
    rm -f "${rendered_file}"
    return 0
  fi
  if ! xray run -test -config "${rendered_file}" >/dev/null; then
    rm -f "${rendered_file}"
    return 1
  fi
  if ! xray_install_config "${rendered_file}" "${config_file}" "${service}"; then
    rm -f "${rendered_file}"
    return 1
  fi
  rm -f "${rendered_file}"
  systemctl restart "${service}"
}

xray_change_client_config() {
  local config_file="$1"
  local action="$2"
  local client_name="$3"
  local client_uuid="$4"
  local short_id="$5"
  local route="$6"
  local service="$7"
  local tag=""
  local tmp_file=""

  [[ "${action}" == "add" || "${action}" == "remove" || "${action}" == "route" ]] || vps_die "invalid Xray client config action: ${action}"
  tag="$(xray_inbound_tag)"
  tmp_file="$(mktemp --suffix=.json)"
  if ! jq \
    --arg tag "${tag}" \
    --arg rule_tag "${XRAY_CLIENT_NEXT_HOP_RULE_TAG}" \
    --arg outbound_tag "${XRAY_NEXT_HOP_OUTBOUND_TAG}" \
    --arg action "${action}" \
    --arg route "${route}" \
    --arg name "${client_name}" \
    --arg uuid "${client_uuid}" \
    --arg sid "${short_id}" \
    '(
      (
        [.routing.rules[]? | select(.ruleTag == $rule_tag) | .user[]? | select(. != $name)]
        + (if $action != "remove" and $route == "next-hop" then [$name] else [] end)
      )
      | reduce .[] as $user ([]; if index($user) == null then . + [$user] else . end)
    ) as $next_hop_users
    | .inbounds |= map(
      if .tag == $tag then
        if $action == "add" then
          .settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $name}]
          | .streamSettings.realitySettings.shortIds += [$sid]
        elif $action == "remove" then
          .settings.clients = [.settings.clients[]? | select(.id != $uuid)]
          | .streamSettings.realitySettings.shortIds = [.streamSettings.realitySettings.shortIds[]? | select(. != $sid)]
        else
          .
        end
      else
        .
      end
    )
    | .routing.rules = [.routing.rules[]? | select(.ruleTag != $rule_tag)]
    | if ($next_hop_users | length) > 0 then
        .routing.rules += [{
          "ruleTag": $rule_tag,
          "type": "field",
          "inboundTag": [$tag],
          "user": $next_hop_users,
          "outboundTag": $outbound_tag
        }]
      else
        .
      end' \
    "${config_file}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi

  xray_apply_rendered_config "${config_file}" "${tmp_file}" "${service}"
}

xray_add_client_to_config() {
  local config_file="$1"
  local client_name="$2"
  local client_uuid="$3"
  local short_id="$4"
  local service="$5"
  local route="${6:-direct}"

  xray_validate_client_route "${route}"
  if [[ "${route}" == "next-hop" ]]; then
    xray_require_next_hop_outbound "${config_file}"
  fi
  xray_change_client_config "${config_file}" "add" "${client_name}" "${client_uuid}" "${short_id}" "${route}" "${service}"
}

xray_remove_client_from_config() {
  local config_file="$1"
  local client_name="$2"
  local client_uuid="$3"
  local short_id="$4"
  local service="$5"

  xray_change_client_config "${config_file}" "remove" "${client_name}" "${client_uuid}" "${short_id}" "direct" "${service}"
}

xray_set_client_route_in_config() {
  local config_file="$1"
  local client_name="$2"
  local route="$3"
  local service="$4"

  xray_validate_client_route "${route}"
  xray_require_client_in_inbound "${config_file}" "${client_name}"
  if [[ "${route}" == "next-hop" ]]; then
    xray_require_next_hop_outbound "${config_file}"
  fi
  xray_change_client_config "${config_file}" "route" "${client_name}" "" "" "${route}" "${service}"
}

xray_write_client_artifacts() {
  local client_name="$1"
  local client_uuid="$2"
  local short_id="$3"
  local endpoint="$4"
  local port="$5"
  local server_name="$6"
  local public_key="$7"
  local clients_dir="${CLIENTS_DIR:-${XRAY_CLIENTS_DIR_DEFAULT}}"
  local client_dir=""
  local uri_host=""
  local uri=""

  client_dir="${clients_dir}/${client_name}"
  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  printf '%s\n' "${client_uuid}" > "${client_dir}/${client_name}.uuid"
  printf '%s\n' "${short_id}" > "${client_dir}/${client_name}.short-id"

  uri_host="$(vps_format_uri_host "${endpoint}")"
  uri="vless://${client_uuid}@${uri_host}:${port}?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=$(vps_url_encode "${server_name}")&fp=firefox&pbk=$(vps_url_encode "${public_key}")&sid=${short_id}&spx=%2F#$(vps_url_encode "${client_name}")"
  printf '%s\n' "${uri}" > "${client_dir}/vless-${client_name}.txt"

  chmod 600 "${client_dir}/${client_name}.uuid" "${client_dir}/${client_name}.short-id" "${client_dir}/vless-${client_name}.txt"
}
