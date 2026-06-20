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

@test "telemt upsert creates a missing table" {
  local config="${TEST_TMPDIR}/empty.toml"
  printf '# empty\n' > "${config}"

  run telemt_upsert_key "${config}" "access.users" "main" '"secret"'
  [ "$status" -eq 0 ]
  assert_file_contains "${config}" "[access.users]"
  assert_file_contains "${config}" '"main" = "secret"'
}
