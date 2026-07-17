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
