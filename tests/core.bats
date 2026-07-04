#!/usr/bin/env bats

load test_helper

setup() {
  load_core
}

@test "client names allow simple safe identifiers" {
  run vps_validate_client_name "phone-1.main"
  [ "$status" -eq 0 ]
}

@test "client names reject path separators" {
  run vps_validate_client_name "../phone"
  [ "$status" -ne 0 ]
  [[ "$output" == *"client name may only contain"* ]]
}

@test "ports reject out of range values" {
  run vps_validate_port "70000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"port must be between 1 and 65535"* ]]
}

@test "endpoint formatting preserves host ports and brackets IPv6" {
  run vps_format_endpoint "vpn.example.com" "51820"
  [ "$status" -eq 0 ]
  [ "$output" = "vpn.example.com:51820" ]

  run vps_format_endpoint "2001:db8::10" "51820"
  [ "$status" -eq 0 ]
  [ "$output" = "[2001:db8::10]:51820" ]

  run vps_format_endpoint "[2001:db8::10]:52820" "51820"
  [ "$status" -eq 0 ]
  [ "$output" = "[2001:db8::10]:52820" ]
}

@test "read file returns contents or default" {
  make_temp_dir
  printf 'custom\n' > "${TEST_TMPDIR}/state.txt"

  run vps_read_file_or_default "${TEST_TMPDIR}/state.txt" "default"
  [ "$status" -eq 0 ]
  [ "$output" = "custom" ]

  run vps_read_file_or_default "${TEST_TMPDIR}/missing.txt" "default"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

@test "safe file removal refuses directories" {
  make_temp_dir
  printf 'state\n' > "${TEST_TMPDIR}/state.txt"
  mkdir -p "${TEST_TMPDIR}/config-dir"

  run vps_safe_remove_file_path "${TEST_TMPDIR}/state.txt"
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_TMPDIR}/state.txt" ]

  run vps_safe_remove_file_path "${TEST_TMPDIR}/config-dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to remove directory as file path"* ]]
  [ -d "${TEST_TMPDIR}/config-dir" ]
}

teardown() {
  remove_temp_dir
}
