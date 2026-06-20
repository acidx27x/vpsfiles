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

teardown() {
  remove_temp_dir
}
