#!/usr/bin/env bats

load test_helper

setup() {
  load_telemt
  make_temp_dir
  TELEMT_CONFIG="${TEST_TMPDIR}/telemt.toml"
  cat > "${TELEMT_CONFIG}" <<'EOF'
[access.users]
"main" = "secret"

[access.user_max_unique_ips]
"main" = 2
EOF
}

teardown() {
  remove_temp_dir
}

@test "telemt detects, counts, upserts, and removes table keys" {
  run telemt_key_exists "${TELEMT_CONFIG}" "access.users" "main"
  [ "$status" -eq 0 ]

  run telemt_count_keys "${TELEMT_CONFIG}" "access.users"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run telemt_upsert_key "${TELEMT_CONFIG}" "access.users" "phone" '"new-secret"'
  [ "$status" -eq 0 ]
  assert_file_contains "${TELEMT_CONFIG}" '"phone" = "new-secret"'

  run telemt_remove_key "${TELEMT_CONFIG}" "access.users" "phone"
  [ "$status" -eq 0 ]
  assert_file_not_contains "${TELEMT_CONFIG}" '"phone" = "new-secret"'
}

@test "telemt upsert keeps table entries together" {
  cat > "${TELEMT_CONFIG}" <<'EOF'
[access.users]
"main" = "secret"



[access.user_max_unique_ips]
"main" = 2
EOF

  telemt_upsert_key "${TELEMT_CONFIG}" "access.users" "family" '"family-secret"'
  telemt_upsert_key "${TELEMT_CONFIG}" "access.user_max_unique_ips" "family" "1"

  run diff -u - "${TELEMT_CONFIG}" <<'EOF'
[access.users]
"main" = "secret"
"family" = "family-secret"

[access.user_max_unique_ips]
"main" = 2
"family" = 1
EOF
  [ "$status" -eq 0 ]
}

@test "telemt upsert creates a missing table" {
  local config="${TEST_TMPDIR}/empty.toml"
  printf '# empty\n' > "${config}"

  run telemt_upsert_key "${config}" "access.users" "main" '"secret"'
  [ "$status" -eq 0 ]
  assert_file_contains "${config}" "[access.users]"
  assert_file_contains "${config}" '"main" = "secret"'
}

@test "telemt client output excludes raw API and QR files" {
  CLIENTS_DIR="${TEST_TMPDIR}/clients"
  telemt_fetch_client_api() {
    local _client_name="$1"
    local output_file="$2"
    cat > "${output_file}" <<'EOF'
{"data":[{"username":"phone","links":{"tls":["tm://phone"],"secure":[],"classic":[]}}]}
EOF
  }

  telemt_write_client_artifacts "phone" "secret" 2

  [ -f "${CLIENTS_DIR}/phone/phone.secret" ]
  [ -f "${CLIENTS_DIR}/phone/phone.max-unique-ips" ]
  [ -f "${CLIENTS_DIR}/phone/telemt-phone-links.txt" ]
  [ ! -e "${CLIENTS_DIR}/phone/telemt-phone-api.json" ]
  [ ! -e "${CLIENTS_DIR}/phone/telemt-phone-qrcode.txt" ]
}

@test "telemt parses canonical Shadowsocks upstream URIs" {
  local key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  telemt_parse_shadowsocks_upstream_uri "ss://2022-blake3-aes-256-gcm:${key}@exit.example.com:8388"
  [ "${TELEMT_SS_UPSTREAM_ADDRESS}" = "exit.example.com" ]
  [ "${TELEMT_SS_UPSTREAM_PORT}" = "8388" ]

  telemt_parse_shadowsocks_upstream_uri "ss://2022-blake3-aes-256-gcm:${key}@[2001:db8::20]:8443"
  [ "${TELEMT_SS_UPSTREAM_ADDRESS}" = "2001:db8::20" ]
  [ "${TELEMT_SS_UPSTREAM_PORT}" = "8443" ]
  [ "${TELEMT_SS_UPSTREAM_URI}" = "ss://2022-blake3-aes-256-gcm:${key}@[2001:db8::20]:8443" ]
}

@test "telemt rejects incompatible or malformed Shadowsocks upstream URIs" {
  local key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  local uri=""

  for uri in \
    "ss://aes-256-gcm:${key}@exit.example.com:8388" \
    "ss://2022-blake3-aes-256-gcm:short@exit.example.com:8388" \
    "ss://2022-blake3-aes-256-gcm:${key}@2001:db8::20:8388" \
    "ss://2022-blake3-aes-256-gcm:${key}@exit.example.com:0" \
    "ss://2022-blake3-aes-256-gcm:${key}@exit.example.com:8388#name" \
    "ss://2022-blake3-aes-256-gcm:${key}@exit.example.com:8388?plugin=x" \
    "ss://2022-blake3-aes-256-gcm:${key}@exit\".example.com:8388"; do
    run telemt_parse_shadowsocks_upstream_uri "${uri}"
    [ "${status}" -ne 0 ]
  done
}

@test "telemt appends exactly one optional Shadowsocks upstream" {
  local key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  local uri="ss://2022-blake3-aes-256-gcm:${key}@exit.example.com:8388"
  local direct_config="${TEST_TMPDIR}/direct.toml"
  local upstream_config="${TEST_TMPDIR}/upstream.toml"

  printf '[general]\nuse_middle_proxy = false\n' > "${direct_config}"
  cp "${direct_config}" "${upstream_config}"

  telemt_append_shadowsocks_upstream "${direct_config}" ""
  [ "$(<"${direct_config}")" = $'[general]\nuse_middle_proxy = false' ]

  telemt_append_shadowsocks_upstream "${upstream_config}" "${uri}"
  [ "$(grep -cF '[[upstreams]]' "${upstream_config}")" -eq 1 ]
  assert_file_contains "${upstream_config}" 'type = "shadowsocks"'
  assert_file_contains "${upstream_config}" "url = \"${uri}\""
  assert_file_contains "${upstream_config}" 'weight = 1'
  assert_file_contains "${upstream_config}" 'enabled = true'
}

@test "telemt installer keeps the upstream optional and private" {
  local install_script="${REPO_ROOT}/telemt-scripts/install.sh"

  assert_file_contains "${install_script}" "TELEMT_SS_UPSTREAM_URI=\"\${TELEMT_SS_UPSTREAM_URI:-}\""
  assert_file_contains "${install_script}" "prompt_private TELEMT_SS_UPSTREAM_URI"
  assert_file_contains "${install_script}" "telemt_append_shadowsocks_upstream \"\${tmp_file}\" \"\${TELEMT_SS_UPSTREAM_URI}\""
}
