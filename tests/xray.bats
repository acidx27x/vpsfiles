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

  run xray_run_installer update
  [ "$status" -ne 0 ]
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
    and ([.inbounds[].tag] | index("shadowsocks-2022")) == null
    and .outbounds[0].tag == "direct"' "${REPO_ROOT}/xray-scripts/config-server.example.json"

  [ "${status}" -eq 0 ]
}

@test "xray renders the optional Shadowsocks 2022 inbound" {
  local rendered="${TEST_TMPDIR}/shadowsocks.json"
  local key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  xray_render_shadowsocks_inbound "${XRAY_CONFIG}" "${rendered}" 8388 "${key}"

  jq -e --arg key "${key}" '.inbounds[] | select(
    .tag == "shadowsocks-2022"
    and .listen == "::"
    and .port == 8388
    and .protocol == "shadowsocks"
    and .settings.network == "tcp,udp"
    and .settings.method == "2022-blake3-aes-256-gcm"
    and .settings.password == $key
  )' "${rendered}" >/dev/null
  [ "$(jq '[.inbounds[] | select(.tag == "vless-reality-vision-443")] | length' "${rendered}")" -eq 1 ]
  [ "$(jq '.outbounds | length' "${rendered}")" -eq 2 ]
  [ "$(jq '.routing.rules | length' "${rendered}")" -eq 2 ]
}

@test "xray writes a private Telemt-compatible Shadowsocks URI" {
  local key="3SYJ/f8nmVuzKvKglykRQDSgg10e/ADilkdRWrrY9HU="
  local artifact=""

  CLIENTS_DIR="${TEST_TMPDIR}/clients"
  artifact="$(xray_write_shadowsocks_artifact "2001:db8::20" 8388 "${key}")"

  [ "${artifact}" = "${CLIENTS_DIR}/ss/shadowsocks-upstream.txt" ]
  [ "$(<"${artifact}")" = "ss://2022-blake3-aes-256-gcm:3SYJ%2Ff8nmVuzKvKglykRQDSgg10e%2FADilkdRWrrY9HU%3D@[2001:db8::20]:8388" ]
  [ "$(stat -c '%a' "${CLIENTS_DIR}/ss")" = "700" ]
  [ "$(stat -c '%a' "${artifact}")" = "600" ]
}

@test "xray rejects unsafe Shadowsocks endpoints and an occupied ss artifact directory" {
  CLIENTS_DIR="${TEST_TMPDIR}/clients"

  run xray_validate_shadowsocks_endpoint 'https://exit.example.com'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"host name, IPv4, or IPv6"* ]]

  mkdir -p "${CLIENTS_DIR}/ss"
  printf 'existing client\n' > "${CLIENTS_DIR}/ss/ss.uuid"
  run xray_require_shadowsocks_artifact_path "${CLIENTS_DIR}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"reserved Shadowsocks artifact directory"* ]]
}

@test "xray generates a 32-byte Shadowsocks key and rejects a VLESS port collision" {
  local key=""

  key="$(xray_generate_shadowsocks_key)"
  xray_validate_shadowsocks_key "${key}"
  [ "$(printf '%s' "${key}" | base64 --decode | wc -c | tr -d '[:space:]')" = "32" ]

  run xray_validate_shadowsocks_port 443 443
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must differ"* ]]

  run xray_validate_shadowsocks_port 8388 443
  [ "${status}" -eq 0 ]
}

@test "xray installer and uninstaller own Shadowsocks firewall state" {
  local install_script="${REPO_ROOT}/xray-scripts/install.sh"
  local uninstall_script="${REPO_ROOT}/xray-scripts/uninstall.sh"

  assert_file_contains "${install_script}" "vps_ufw_allow \"\${XRAY_SS_PORT}\" \"tcp\""
  assert_file_contains "${install_script}" "vps_ufw_allow \"\${XRAY_SS_PORT}\" \"udp\""
  assert_file_contains "${install_script}" "\"\${SCRIPT_DIR}/shadowsocks-port.txt\""
  assert_file_contains "${uninstall_script}" "vps_ufw_delete_saved_rule \"\${SCRIPT_DIR}/shadowsocks-port.txt\" \"tcp\""
  assert_file_contains "${uninstall_script}" "vps_ufw_delete_saved_rule \"\${SCRIPT_DIR}/shadowsocks-port.txt\" \"udp\""
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
  [ "$(jq -r '.routing.rules[0].outboundTag' "${rendered}")" = "block" ]
  [ "$(jq -r '.routing.rules[1].outboundTag' "${rendered}")" = "block" ]
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
  local rules_before="${TEST_TMPDIR}/rules-before.json"

  xray_test_enable_next_hop
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
