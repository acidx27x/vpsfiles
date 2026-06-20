#!/usr/bin/env bats

load test_helper

setup() {
  load_xray
  make_temp_dir
  PATH="${TEST_TMPDIR}/bin:${PATH}"
  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/xray" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "run" && "$2" == "-test" ]]; then
  exit 0
fi
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "cat" ]]; then
  exit 1
fi
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
  ]
}
EOF
}

teardown() {
  remove_temp_dir
}

@test "xray validates inbound tag" {
  run xray_require_inbound_tag "${XRAY_CONFIG}"
  [ "$status" -eq 0 ]
}

@test "xray add and remove client mutate target inbound" {
  run xray_add_client_to_config "${XRAY_CONFIG}" "phone" "uuid-1" "sid-1" "xray"
  [ "$status" -eq 0 ]
  jq -e '.inbounds[0].settings.clients[] | select(.id == "uuid-1" and .email == "phone")' "${XRAY_CONFIG}" >/dev/null
  jq -e '.inbounds[0].streamSettings.realitySettings.shortIds[] | select(. == "sid-1")' "${XRAY_CONFIG}" >/dev/null

  run xray_remove_client_from_config "${XRAY_CONFIG}" "uuid-1" "sid-1" "xray"
  [ "$status" -eq 0 ]
  run jq -e '.inbounds[0].settings.clients[]? | select(.id == "uuid-1")' "${XRAY_CONFIG}"
  [ "$status" -ne 0 ]
  run jq -e '.inbounds[0].streamSettings.realitySettings.shortIds[]? | select(. == "sid-1")' "${XRAY_CONFIG}"
  [ "$status" -ne 0 ]
}
