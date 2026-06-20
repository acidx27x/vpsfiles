#!/usr/bin/env bats

load test_helper

setup() {
  load_wg_family
  make_temp_dir
}

teardown() {
  remove_temp_dir
}

@test "next IPv4 and IPv6 addresses increment host segment" {
  run wg_family_next_ip "10.8.0.1"
  [ "$status" -eq 0 ]
  [ "$output" = "10.8.0.2" ]

  run wg_family_next_ip6 "fd42:42:42::1"
  [ "$status" -eq 0 ]
  [ "$output" = "fd42:42:42::2" ]
}

@test "next IPv4 rejects exhausted host range" {
  run wg_family_next_ip "10.8.0.254"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no usable client IPs remain"* ]]
}

@test "peer block add and remove are keyed by public key" {
  local server_config="${TEST_TMPDIR}/wg0.conf"
  printf '[Interface]\nPrivateKey = server\n' > "${server_config}"

  run wg_family_add_peer_block "${server_config}" "phone" "pub-a" "psk-a" "10.8.0.2/32,fd42:42:42::2/128"
  [ "$status" -eq 0 ]
  assert_file_contains "${server_config}" "# Client: phone"
  assert_file_contains "${server_config}" "PublicKey = pub-a"
  assert_file_contains "${server_config}" "AllowedIPs = 10.8.0.2/32,fd42:42:42::2/128"

  run wg_family_remove_peer_block "${server_config}" "pub-a"
  [ "$status" -eq 0 ]
  assert_file_not_contains "${server_config}" "PublicKey = pub-a"
  assert_file_contains "${server_config}" "[Interface]"
}
