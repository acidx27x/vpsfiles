#!/usr/bin/env bats

load test_helper

setup() {
  load_xray
  make_temp_dir
  PATH="${TEST_TMPDIR}/bin:${PATH}"
  mkdir -p "${TEST_TMPDIR}/bin"
  XRAY_TEST_FAIL_FILE="${TEST_TMPDIR}/xray-test-fail"
  XRAY_SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  export XRAY_TEST_FAIL_FILE XRAY_SYSTEMCTL_LOG
  cat > "${TEST_TMPDIR}/bin/xray" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "run" && "$2" == "-test" ]]; then
  [[ ! -f "${XRAY_TEST_FAIL_FILE}" ]] || exit 23
  exit 0
fi
if [[ "$1" == "uuid" ]]; then
  printf '123e4567-e89b-12d3-a456-426614174001\n'
  exit 0
fi
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "cat" ]]; then
  exit 1
fi
printf '%s\n' "$*" >> "${XRAY_SYSTEMCTL_LOG}"
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/id" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/xray" "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/id"

  XRAY_CONFIG="${TEST_TMPDIR}/config.json"
  cat > "${XRAY_CONFIG}" <<'EOF'
{
  "inbounds": [
    {
      "tag": "vless-reality-vision-443",
      "settings": { "clients": [] },
      "streamSettings": { "realitySettings": { "shortIds": ["server"] } }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
}

xray_test_enable_next_hop() {
  local output="${TEST_TMPDIR}/next-hop.json"
  local uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%2F#relay"

  xray_parse_next_hop_uri "${uri}"
  xray_render_next_hop_config "${XRAY_CONFIG}" "${output}"
  mv "${output}" "${XRAY_CONFIG}"
}

teardown() {
  remove_temp_dir
}

@test "xray validates inbound tag" {
  run xray_require_inbound_tag "${XRAY_CONFIG}"
  [ "$status" -eq 0 ]
}

@test "xray installer runner fails when download fails" {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  run xray_run_installer install
  [ "$status" -ne 0 ]
}

@test "xray installer runner forwards supported actions and rejects obsolete ones" {
  local action_log="${TEST_TMPDIR}/installer-action.log"
  local curl_log="${TEST_TMPDIR}/curl.log"

  export action_log curl_log
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
printf 'called\n' >> "${curl_log}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
cat > "${output}" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${action_log}"
INSTALLER
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  run xray_run_installer install --no-update-service
  [ "$status" -eq 0 ]
  [ "$(<"${action_log}")" = "install --no-update-service" ]

  rm -f "${curl_log}"
  run xray_run_installer update
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported Xray installer action: update"* ]]
  [ ! -e "${curl_log}" ]
}

@test "xray add and remove client mutate target inbound" {
  run xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-1" "sid-1" "xray"
  [ "$status" -eq 0 ]
  jq -e '.inbounds[0].settings.clients[] | select(.id == "uuid-1" and .email == "phone")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.inbounds[0].streamSettings.realitySettings.shortIds[] | select(. == "sid-1")' "${XRAY_CONFIG}" >/dev/null

  run xray_remove_client_from_config "${XRAY_CONFIG}" "phone" "uuid-1" "sid-1" "xray"
  [ "$status" -eq 0 ]
  run jq -e '.inbounds[0].settings.clients[]? | select(.id == "uuid-1")' "${XRAY_CONFIG}"
  [ "$status" -ne 0 ]
  run jq -e '.inbounds[0].streamSettings.realitySettings.shortIds[]? | select(. == "sid-1")' "${XRAY_CONFIG}"
  [ "$status" -ne 0 ]
}

@test "xray client output keeps URI and removal metadata only" {
  CLIENTS_DIR="${TEST_TMPDIR}/clients"

  xray_write_client_artifacts "phone" "uuid-1" "sid-1" "198.51.100.10" 443 "www.example.com" "public-key"

  [ -f "${CLIENTS_DIR}/phone/phone.uuid" ]
  [ -f "${CLIENTS_DIR}/phone/phone.short-id" ]
  [ -f "${CLIENTS_DIR}/phone/vless-phone.txt" ]
  [ ! -e "${CLIENTS_DIR}/phone/xray-client-phone.json" ]
  [ ! -e "${CLIENTS_DIR}/phone/vless-phone-qrcode.txt" ]
}

@test "xray server template remains a direct exit by default" {
  run jq -e '([.outbounds[].tag] | index("next-hop")) == null
    and ([.routing.rules[].outboundTag] | index("next-hop")) == null
    and ([.routing.rules[].ruleTag] | index("dns-next-hop")) == null
    and ([.routing.rules[].ruleTag] | index("russian-domain-direct")) == null
    and ([.routing.rules[].ruleTag] | index("russian-ip-direct")) == null
    and ([.inbounds[].tag] | index("local-socks")) == null
    and .routing.domainStrategy == "IPIfNonMatch"
    and (has("dns") | not)
    and (.geodata | not)
    and .outbounds[0].tag == "direct"' "${REPO_ROOT}/xray-scripts/config-server.example.json"

  [ "${status}" -eq 0 ]
}

@test "xray renders a loopback-only SOCKS5 inbound routed through next hop" {
  local rendered="${TEST_TMPDIR}/local-socks.json"

  xray_test_enable_next_hop
  xray_render_local_socks_config "${XRAY_CONFIG}" "${rendered}" 1080

  jq -e '.inbounds[] | select(
    .tag == "local-socks"
    and .listen == "127.0.0.1"
    and .port == 1080
    and .protocol == "socks"
    and .settings.auth == "noauth"
    and .settings.udp == false
    and (.settings.users | not)
  )' "${rendered}" >/dev/null
  jq -e '.routing.rules[2] | select(
    .ruleTag == "local-socks-next-hop"
    and .inboundTag == ["local-socks"]
    and .outboundTag == "next-hop"
  )' "${rendered}" >/dev/null
  [ "$(jq '[.inbounds[] | select(.tag == "vless-reality-vision-443")] | length' "${rendered}")" -eq 1 ]
  [ "$(jq '[.outbounds[] | select(.tag == "next-hop")] | length' "${rendered}")" -eq 1 ]
  [ "$(jq -r '.routing.rules[0].outboundTag' "${rendered}")" = "block" ]
  [ "$(jq -r '.routing.rules[1].outboundTag' "${rendered}")" = "block" ]
}

@test "xray local SOCKS5 requires next hop and a separate port" {
  local rendered="${TEST_TMPDIR}/local-socks.json"

  run xray_render_local_socks_config "${XRAY_CONFIG}" "${rendered}" 1080
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"next-hop outbound is missing"* ]]

  run xray_validate_local_socks_port 443 443
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must differ from the Xray VLESS port"* ]]

  run xray_validate_local_socks_port 1080 443
  [ "${status}" -eq 0 ]
}

@test "xray keeps local SOCKS5 optional and off the firewall" {
  local install_script="${REPO_ROOT}/xray-scripts/install.sh"
  local uninstall_script="${REPO_ROOT}/xray-scripts/uninstall.sh"

  assert_file_contains "${install_script}" "XRAY_LOCAL_SOCKS_PORT=\"\${XRAY_LOCAL_SOCKS_PORT:-}\""
  assert_file_contains "${install_script}" "prompt XRAY_LOCAL_SOCKS_PORT"
  assert_file_not_contains "${install_script}" "vps_ufw_allow \"\${XRAY_LOCAL_SOCKS_PORT}\""
  assert_file_not_contains "${uninstall_script}" "local-socks"
}

@test "xray parses generated VLESS REALITY next-hop URI" {
  local uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%2Frelay%20path#relay"

  xray_parse_next_hop_uri "${uri}"

  [ "${XRAY_NEXT_HOP_ADDRESS}" = "exit.example.com" ]
  [ "${XRAY_NEXT_HOP_PORT}" = "443" ]
  [ "${XRAY_NEXT_HOP_UUID}" = "123e4567-e89b-12d3-a456-426614174000" ]
  [ "${XRAY_NEXT_HOP_SERVER_NAME}" = "nl.example.com" ]
  [ "${XRAY_NEXT_HOP_FINGERPRINT}" = "firefox" ]
  [ "${XRAY_NEXT_HOP_PUBLIC_KEY}" = "public_key-1" ]
  [ "${XRAY_NEXT_HOP_SHORT_ID}" = "0123456789abcdef" ]
  [ "${XRAY_NEXT_HOP_SPIDER_X}" = "/relay path" ]
}

@test "xray parses bracketed IPv6 next-hop endpoint" {
  local uri="vless://123e4567-e89b-12d3-a456-426614174000@[2001:db8::10]:8443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%2F#relay"

  xray_parse_next_hop_uri "${uri}"

  [ "${XRAY_NEXT_HOP_ADDRESS}" = "2001:db8::10" ]
  [ "${XRAY_NEXT_HOP_PORT}" = "8443" ]
}

@test "xray rejects incompatible next-hop URI" {
  local uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=ws&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%2F"

  run xray_parse_next_hop_uri "${uri}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"type=raw"* ]]
}

@test "xray rejects incomplete and malformed next-hop URI" {
  local missing_key_uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&sid=0123456789abcdef&spx=%2F"
  local bad_encoding_uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%ZZ"

  run xray_parse_next_hop_uri "${missing_key_uri}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"public key"* ]]

  run xray_parse_next_hop_uri "${bad_encoding_uri}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"percent encoding"* ]]
}

@test "xray next-hop installation adds only the outbound" {
  local rendered="${TEST_TMPDIR}/relay.json"
  local uri="vless://123e4567-e89b-12d3-a456-426614174000@exit.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&sni=nl.example.com&fp=firefox&pbk=public_key-1&sid=0123456789abcdef&spx=%2F#relay"

  xray_parse_next_hop_uri "${uri}"
  xray_render_next_hop_config "${REPO_ROOT}/xray-scripts/config-server.example.json" "${rendered}"

  jq -e '.outbounds[] | select(
    .tag == "next-hop"
    and .protocol == "vless"
    and .settings.address == "exit.example.com"
    and .settings.port == 443
    and .settings.id == "123e4567-e89b-12d3-a456-426614174000"
    and .streamSettings.network == "raw"
    and .streamSettings.security == "reality"
    and .streamSettings.realitySettings.serverName == "nl.example.com"
    and .streamSettings.realitySettings.password == "public_key-1"
  )' "${rendered}" >/dev/null
  run jq -e '.routing.rules[] | select(.outboundTag == "next-hop")' "${rendered}"
  [ "${status}" -ne 0 ]
  run jq -e 'has("dns") or any(.routing.rules[]; .ruleTag == "dns-next-hop")' "${rendered}"
  [ "${status}" -ne 0 ]
  [ "$(jq -r '.routing.rules[0].outboundTag' "${rendered}")" = "block" ]
  [ "$(jq -r '.routing.rules[1].outboundTag' "${rendered}")" = "block" ]
}

@test "xray renders Russian split routing with next-hop DNS and Friday geodata updates" {
  local rendered="${TEST_TMPDIR}/russian-split.json"

  xray_test_enable_next_hop
  xray_render_russian_split_config "${XRAY_CONFIG}" "${rendered}"

  jq -e '
    .dns.servers == [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query"
    ]
    and .dns.queryStrategy == "UseIP"
    and .dns.tag == "dns-next-hop"
    and (.dns | has("disableFallback") | not)
    and .routing.domainStrategy == "IPOnDemand"
    and .routing.rules[0].ruleTag == "dns-next-hop"
    and .routing.rules[0].type == "field"
    and .routing.rules[0].inboundTag == ["dns-next-hop"]
    and .routing.rules[0].outboundTag == "next-hop"
    and .routing.rules[3].ruleTag == "russian-domain-direct"
    and .routing.rules[3].inboundTag == ["vless-reality-vision-443"]
    and .routing.rules[3].domain == ["geosite:tld-ru", "geosite:category-gov-ru"]
    and .routing.rules[3].outboundTag == "direct"
    and .routing.rules[4].ruleTag == "russian-ip-direct"
    and .routing.rules[4].inboundTag == ["vless-reality-vision-443"]
    and .routing.rules[4].ip == ["geoip:ru"]
    and .routing.rules[4].outboundTag == "direct"
    and .geodata.cron == "30 4 * * 5"
    and .geodata.outbound == "next-hop"
    and .geodata.assets == [
      {
        "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
        "file": "geoip.dat"
      },
      {
        "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
        "file": "geosite.dat"
      }
    ]
  ' "${rendered}" >/dev/null
  [ "$(jq -r '.routing.rules[1].outboundTag' "${rendered}")" = "block" ]
  [ "$(jq -r '.routing.rules[2].outboundTag' "${rendered}")" = "block" ]
}

@test "xray keeps Russian split rules before strict SOCKS and client next-hop rules" {
  local rendered="${TEST_TMPDIR}/russian-split.json"
  local with_socks="${TEST_TMPDIR}/russian-split-socks.json"

  xray_test_enable_next_hop
  xray_render_russian_split_config "${XRAY_CONFIG}" "${rendered}"
  xray_render_local_socks_config "${rendered}" "${with_socks}" 1080
  mv "${with_socks}" "${XRAY_CONFIG}"
  xray_add_client_to_config "${XRAY_CONFIG}" "tablet" "uuid-tablet" "sid-tablet" "xray" "next-hop"

  jq -e '
    [
      .routing.rules[]
      | if .ip == ["geoip:private"] and .outboundTag == "block" then
          "private-ip-block"
        elif .protocol == ["bittorrent"] and .outboundTag == "block" then
          "bittorrent-block"
        else
          .ruleTag
        end
    ] == [
      "dns-next-hop",
      "private-ip-block",
      "bittorrent-block",
      "russian-domain-direct",
      "russian-ip-direct",
      "local-socks-next-hop",
      "client-next-hop"
    ]
    and .routing.rules[5].inboundTag == ["local-socks"]
    and .routing.rules[5].outboundTag == "next-hop"
    and .routing.rules[6].user == ["tablet"]
  ' "${XRAY_CONFIG}" >/dev/null
}

@test "xray Russian split routing requires a next hop and a boolean setting" {
  local rendered="${TEST_TMPDIR}/russian-split.json"

  run xray_render_russian_split_config "${XRAY_CONFIG}" "${rendered}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"next-hop outbound is missing"* ]]

  run xray_validate_russian_split_routing 0
  [ "$status" -eq 0 ]
  run xray_validate_russian_split_routing 1
  [ "$status" -eq 0 ]
  run xray_validate_russian_split_routing yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be 0 or 1"* ]]
}

@test "xray prepares scheduled geodata for only the configured service user" {
  local asset_dir="${TEST_TMPDIR}/assets"
  local command_log="${TEST_TMPDIR}/permissions.log"
  local rendered="${TEST_TMPDIR}/russian-split.json"

  xray_test_enable_next_hop
  xray_render_russian_split_config "${XRAY_CONFIG}" "${rendered}"
  mkdir -p "${asset_dir}"
  printf 'geoip\n' > "${asset_dir}/geoip.dat"
  printf 'geosite\n' > "${asset_dir}/geosite.dat"

  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "cat" ]]; then
  printf '[Service]\nUser=xray-test\n'
  exit 0
fi
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-gn" ]]; then
  printf 'xray-test-group\n'
fi
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/id"
  cat > "${TEST_TMPDIR}/bin/chown" <<EOF
#!/usr/bin/env bash
printf 'chown %s\n' "\$*" >> "${command_log}"
EOF
  cat > "${TEST_TMPDIR}/bin/chmod" <<EOF
#!/usr/bin/env bash
printf 'chmod %s\n' "\$*" >> "${command_log}"
EOF
  /usr/bin/chmod +x "${TEST_TMPDIR}/bin/chown" "${TEST_TMPDIR}/bin/chmod"
  hash -r

  xray_prepare_geodata_permissions "${rendered}" "xray" "${asset_dir}"

  assert_file_contains "${command_log}" "chown xray-test:xray-test-group ${asset_dir}"
  assert_file_contains "${command_log}" "chown xray-test:xray-test-group ${asset_dir}/geoip.dat ${asset_dir}/geosite.dat"
  assert_file_contains "${command_log}" "chmod 700 ${asset_dir}"
  assert_file_contains "${command_log}" "chmod 600 ${asset_dir}/geoip.dat ${asset_dir}/geosite.dat"

  rm -f "${asset_dir}/geoip.dat"
  run xray_prepare_geodata_permissions "${rendered}" "xray" "${asset_dir}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Xray geodata file is missing"* ]]
}

@test "xray installer exposes optional Russian split routing only with a next hop" {
  local install_script="${REPO_ROOT}/xray-scripts/install.sh"

  assert_file_contains "${install_script}" "XRAY_RUSSIAN_SPLIT_ROUTING=\"\${XRAY_RUSSIAN_SPLIT_ROUTING:-}\""
  assert_file_contains "${install_script}" 'Route Russian destinations directly from this VPS?'
  assert_file_contains "${install_script}" 'xray_render_russian_split_config'
  assert_file_contains "${install_script}" 'xray_prepare_geodata_permissions'
}

@test "xray routes only explicitly selected clients through next hop" {
  xray_test_enable_next_hop

  xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "direct"
  xray_add_client_to_config "${XRAY_CONFIG}" "tablet" "uuid-tablet" "sid-tablet" "xray" "next-hop"

  jq -e '.inbounds[0].settings.clients[] | select(.id == "uuid-phone" and .email == "phone")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.inbounds[0].settings.clients[] | select(.id == "uuid-tablet" and .email == "tablet")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.routing.rules[] | select(
    .ruleTag == "client-next-hop"
    and .inboundTag == ["vless-reality-vision-443"]
    and .user == ["tablet"]
    and .outboundTag == "next-hop"
  )' "${XRAY_CONFIG}" >/dev/null
  [ "$(jq '[.routing.rules[] | select(.ruleTag == "client-next-hop")] | length' "${XRAY_CONFIG}")" -eq 1 ]
  [ "$(jq -r '.outbounds[0].tag' "${XRAY_CONFIG}")" = "direct" ]
  [ "$(jq -r '.routing.rules[0].outboundTag' "${XRAY_CONFIG}")" = "block" ]
  [ "$(jq -r '.routing.rules[1].outboundTag' "${XRAY_CONFIG}")" = "block" ]
}

@test "xray rejects a next-hop client when the outbound is unavailable" {
  local before="${TEST_TMPDIR}/before.json"

  cp "${XRAY_CONFIG}" "${before}"
  run xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "next-hop"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"next-hop outbound is missing"* ]]
  cmp "${before}" "${XRAY_CONFIG}"
  [ ! -e "${XRAY_SYSTEMCTL_LOG}" ]
}

@test "xray switches client routes idempotently without changing credentials or URI" {
  local clients_dir="${TEST_TMPDIR}/clients"
  local uri_checksum=""
  local config_checksum=""
  local restart_count=0

  xray_test_enable_next_hop
  xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "direct"
  CLIENTS_DIR="${clients_dir}"
  xray_write_client_artifacts "phone" "uuid-phone" "sid-phone" "198.51.100.10" 443 "www.example.com" "public-key"
  uri_checksum="$(sha256sum "${clients_dir}/phone/vless-phone.txt")"

  xray_set_client_route_in_config "${XRAY_CONFIG}" "phone" "next-hop" "xray"
  jq -e '.routing.rules[] | select(.ruleTag == "client-next-hop" and .user == ["phone"] and .outboundTag == "next-hop")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.inbounds[0].settings.clients[] | select(.email == "phone" and .id == "uuid-phone")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.inbounds[0].streamSettings.realitySettings.shortIds | index("sid-phone") != null' "${XRAY_CONFIG}" >/dev/null
  [ "$(sha256sum "${clients_dir}/phone/vless-phone.txt")" = "${uri_checksum}" ]

  config_checksum="$(sha256sum "${XRAY_CONFIG}")"
  restart_count="$(wc -l < "${XRAY_SYSTEMCTL_LOG}")"
  xray_set_client_route_in_config "${XRAY_CONFIG}" "phone" "next-hop" "xray"
  [ "$(sha256sum "${XRAY_CONFIG}")" = "${config_checksum}" ]
  [ "$(wc -l < "${XRAY_SYSTEMCTL_LOG}")" -eq "${restart_count}" ]

  xray_set_client_route_in_config "${XRAY_CONFIG}" "phone" "direct" "xray"
  [ "$(jq '[.routing.rules[] | select(.ruleTag == "client-next-hop")] | length' "${XRAY_CONFIG}")" -eq 0 ]
  jq -e '.inbounds[0].settings.clients[] | select(.email == "phone" and .id == "uuid-phone")' "${XRAY_CONFIG}" >/dev/null
  [ "$(sha256sum "${clients_dir}/phone/vless-phone.txt")" = "${uri_checksum}" ]

  config_checksum="$(sha256sum "${XRAY_CONFIG}")"
  restart_count="$(wc -l < "${XRAY_SYSTEMCTL_LOG}")"
  xray_set_client_route_in_config "${XRAY_CONFIG}" "phone" "direct" "xray"
  [ "$(sha256sum "${XRAY_CONFIG}")" = "${config_checksum}" ]
  [ "$(wc -l < "${XRAY_SYSTEMCTL_LOG}")" -eq "${restart_count}" ]
}

@test "xray route changes reject invalid routes and missing clients" {
  local before="${TEST_TMPDIR}/before.json"

  xray_test_enable_next_hop
  xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "direct"
  cp "${XRAY_CONFIG}" "${before}"

  run xray_set_client_route_in_config "${XRAY_CONFIG}" "phone" "relay" "xray"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"route must be direct or next-hop"* ]]

  run xray_set_client_route_in_config "${XRAY_CONFIG}" "missing" "next-hop" "xray"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"client is missing from inbound"* ]]
  cmp "${before}" "${XRAY_CONFIG}"
}

@test "xray removal cleans the managed route without changing other rules" {
  local local_socks_config="${TEST_TMPDIR}/local-socks.json"
  local rules_before="${TEST_TMPDIR}/rules-before.json"

  xray_test_enable_next_hop
  xray_render_local_socks_config "${XRAY_CONFIG}" "${local_socks_config}" 1080
  mv "${local_socks_config}" "${XRAY_CONFIG}"
  jq -S '[.routing.rules[] | select(.ruleTag != "client-next-hop")]' "${XRAY_CONFIG}" > "${rules_before}"
  xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "next-hop"
  xray_add_client_to_config "${XRAY_CONFIG}" "tablet" "uuid-tablet" "sid-tablet" "xray" "next-hop"

  xray_remove_client_from_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray"
  jq -e '.routing.rules[] | select(.ruleTag == "client-next-hop" and .user == ["tablet"])' "${XRAY_CONFIG}" >/dev/null

  xray_remove_client_from_config "${XRAY_CONFIG}" "tablet" "uuid-tablet" "sid-tablet" "xray"
  [ "$(jq '[.routing.rules[] | select(.ruleTag == "client-next-hop")] | length' "${XRAY_CONFIG}")" -eq 0 ]
  jq -S '[.routing.rules[] | select(.ruleTag != "client-next-hop")]' "${XRAY_CONFIG}" | cmp "${rules_before}" -
}

@test "xray validates client config changes before installation and restart" {
  local before="${TEST_TMPDIR}/before.json"

  cp "${XRAY_CONFIG}" "${before}"
  touch "${XRAY_TEST_FAIL_FILE}"
  run xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "direct"

  [ "${status}" -ne 0 ]
  cmp "${before}" "${XRAY_CONFIG}"
  [ ! -e "${XRAY_SYSTEMCTL_LOG}" ]
}

@test "add-client combines next-hop routing with the IPv6 endpoint" {
  cat > "${TEST_TMPDIR}/bin/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "rand" && "$2" == "-hex" ]]; then
  printf '0123456789abcdef\n'
  exit 0
fi
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/openssl"
  xray_test_enable_next_hop
  printf '%s\n' "${XRAY_CONFIG}" > "${TEST_TMPDIR}/xray-config-path.txt"
  printf 'xray\n' > "${TEST_TMPDIR}/xray-service.txt"
  printf '2001:db8::20\n' > "${TEST_TMPDIR}/server-endpoint6.txt"
  printf '443\n' > "${TEST_TMPDIR}/server-port.txt"
  printf 'www.example.com\n' > "${TEST_TMPDIR}/reality-server-name.txt"
  printf 'public-key\n' > "${TEST_TMPDIR}/reality-public-key.txt"

  # shellcheck source=xray-scripts/add-client.sh
  . "${REPO_ROOT}/xray-scripts/add-client.sh"
  # shellcheck disable=SC2317
  vps_require_root() { :; }
  CLIENTS_DIR="${TEST_TMPDIR}/clients"
  pushd "${TEST_TMPDIR}" >/dev/null
  run main --next-hop --ipv6-endpoint phone
  popd >/dev/null

  [ "${status}" -eq 0 ]
  jq -e '.routing.rules[] | select(.ruleTag == "client-next-hop" and .user == ["phone"])' "${XRAY_CONFIG}" >/dev/null
  [[ "$(<"${CLIENTS_DIR}/phone/vless-phone.txt")" == *"@[2001:db8::20]:443"* ]]
}

@test "set-client-route accepts a route flag before the client name" {
  xray_test_enable_next_hop
  xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-phone" "sid-phone" "xray" "direct"
  printf '%s\n' "${XRAY_CONFIG}" > "${TEST_TMPDIR}/xray-config-path.txt"
  printf 'xray\n' > "${TEST_TMPDIR}/xray-service.txt"

  # shellcheck source=xray-scripts/set-client-route.sh
  . "${BATS_TEST_DIRNAME}/../xray-scripts/set-client-route.sh"
  # shellcheck disable=SC2317
  vps_require_root() { :; }
  pushd "${TEST_TMPDIR}" >/dev/null

  run main --next-hop phone
  [ "${status}" -eq 0 ]
  jq -e '.routing.rules[] | select(.ruleTag == "client-next-hop" and .user == ["phone"])' "${XRAY_CONFIG}" >/dev/null

  run main --direct phone
  [ "${status}" -eq 0 ]
  [ "$(jq '[.routing.rules[] | select(.ruleTag == "client-next-hop")] | length' "${XRAY_CONFIG}")" -eq 0 ]

  run main phone next-hop
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"usage: set-client-route.sh (--next-hop|--direct) <client_name>"* ]]
  popd >/dev/null
}
