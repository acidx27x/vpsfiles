#!/usr/bin/env bats

load test_helper

setup() {
  load_wg_family
  make_temp_dir
}

teardown() {
  remove_temp_dir
}

setup_wg_family_env() {
  local bundle_dir="$1"
  local server_dir="$2"

  export SCRIPT_DIR="${bundle_dir}"
  export WG_FAMILY_NAME="WireGuard"
  export WG_FAMILY_TOOL="wg"
  export WG_FAMILY_QUICK="wg-quick"
  export WG_FAMILY_DIR="${server_dir}"
  export WG_FAMILY_DEFAULT_IF="wg0"
  export WG_FAMILY_CLIENT_PREFIX="wg0"
  export WG_FAMILY_DEFAULT_PORT="51820"
  export WG_FAMILY_DEFAULT_NET="10.8.0.0/24"
  export WG_FAMILY_DEFAULT_NET6="fd42:42:42::/64"
  export CLIENTS_DIR="${bundle_dir}/clients"
  # shellcheck disable=SC2317
  vps_require_root() { :; }
}

setup_wg_hosts_file() {
  export WG_FAMILY_HOSTS_FILE="$1"
}

setup_wg_peer_fixture() {
  local peer_state="${1:-absent}"

  WG_FIXTURE_BUNDLE_DIR="${TEST_TMPDIR}/bundle"
  WG_FIXTURE_SERVER_DIR="${TEST_TMPDIR}/server"
  WG_FIXTURE_SERVER_CONFIG="${WG_FIXTURE_SERVER_DIR}/wg0.conf"
  WG_STUB_LOG="${TEST_TMPDIR}/wg-calls.log"
  WG_STUB_FAIL_SET_FILE="${TEST_TMPDIR}/wg-fail-set"
  export WG_STUB_LOG
  export WG_STUB_FAIL_SET_FILE

  mkdir -p "${WG_FIXTURE_BUNDLE_DIR}/clients/phone" "${WG_FIXTURE_SERVER_DIR}" "${TEST_TMPDIR}/bin"
  cat > "${WG_FIXTURE_BUNDLE_DIR}/clients/phone/wg0-phone.conf" <<'EOF'
[Interface]
Address = 10.8.0.2/32, fd42:42:42::2/128
EOF
  printf 'client-public\n' > "${WG_FIXTURE_BUNDLE_DIR}/clients/phone/phone.pub"
  printf 'client-psk\n' > "${WG_FIXTURE_BUNDLE_DIR}/clients/phone/phone.psk"
  printf 'wg0\n' > "${WG_FIXTURE_BUNDLE_DIR}/server-interface.txt"

  if [[ "${peer_state}" = "present" ]]; then
    cat > "${WG_FIXTURE_SERVER_CONFIG}" <<'EOF'
[Interface]
PrivateKey = server-private

[Peer]
# Client: phone
PublicKey = client-public
PresharedKey = client-psk
AllowedIPs = 10.8.0.2/32,fd42:42:42::2/128
EOF
  else
    printf '[Interface]\nPrivateKey = server-private\n' > "${WG_FIXTURE_SERVER_CONFIG}"
  fi

  cat > "${TEST_TMPDIR}/bin/wg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${WG_STUB_LOG}"
if [[ "$1" = "set" && -f "${WG_STUB_FAIL_SET_FILE}" ]]; then
  exit 47
fi
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/wg"

  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  setup_wg_family_env "${WG_FIXTURE_BUNDLE_DIR}" "${WG_FIXTURE_SERVER_DIR}"
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

@test "hosts entry add is idempotent" {
  local hosts_file="${TEST_TMPDIR}/hosts"

  printf '127.0.0.1 localhost\n10.8.0.2 phone alias\n' > "${hosts_file}"
  setup_wg_hosts_file "${hosts_file}"

  run wg_family_add_hosts_entry "10.8.0.2" "phone"
  [ "$status" -eq 0 ]
  run wg_family_add_hosts_entry "10.8.0.2" "phone"
  [ "$status" -eq 0 ]

  [ "$(awk '$0 == "10.8.0.2 phone" { count++ } END { print count + 0 }' "${hosts_file}")" -eq 1 ]
  assert_file_contains "${hosts_file}" "10.8.0.2 phone alias"
}

@test "hosts entry removal deletes only exact generated row" {
  local hosts_file="${TEST_TMPDIR}/hosts"

  cat > "${hosts_file}" <<'EOF'
127.0.0.1 localhost
10.8.0.2 phone
10.8.0.2 tablet
10.8.0.3 phone
10.8.0.2 phone alias
EOF
  setup_wg_hosts_file "${hosts_file}"

  run wg_family_remove_hosts_entry "10.8.0.2" "phone"
  [ "$status" -eq 0 ]

  [ "$(awk '$0 == "10.8.0.2 phone" { count++ } END { print count + 0 }' "${hosts_file}")" -eq 0 ]
  assert_file_contains "${hosts_file}" "10.8.0.2 tablet"
  assert_file_contains "${hosts_file}" "10.8.0.3 phone"
  assert_file_contains "${hosts_file}" "10.8.0.2 phone alias"
}

@test "default add-peer updates server config and live interface" {
  setup_wg_peer_fixture "absent"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_add_peer_main phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "# Client: phone"
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "AllowedIPs = 10.8.0.2/32,fd42:42:42::2/128"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public preshared-key clients/phone/phone.psk allowed-ips 10.8.0.2/32,fd42:42:42::2/128"
}

@test "default add-peer attempts live update when config peer already exists" {
  setup_wg_peer_fixture "present"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_add_peer_main phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public preshared-key clients/phone/phone.psk allowed-ips 10.8.0.2/32,fd42:42:42::2/128"
}

@test "default remove-peer updates server config and live interface" {
  setup_wg_peer_fixture "present"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_remove_peer_main phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_not_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public remove"
}

@test "default remove-peer attempts live update when config peer is already absent" {
  setup_wg_peer_fixture "absent"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_remove_peer_main phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_not_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public remove"
}

@test "add-peer config-only updates server config without live interface call" {
  setup_wg_peer_fixture "absent"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_add_peer_main --config-only phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  [ ! -e "${WG_STUB_LOG}" ]
}

@test "remove-peer config-only updates server config without live interface call" {
  setup_wg_peer_fixture "present"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_remove_peer_main --config-only phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  assert_file_not_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  [ ! -e "${WG_STUB_LOG}" ]
}

@test "default add-peer keeps config update when live update fails" {
  setup_wg_peer_fixture "absent"
  touch "${WG_STUB_FAIL_SET_FILE}"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_add_peer_main phone
  popd >/dev/null

  [ "$status" -ne 0 ]
  assert_file_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public preshared-key clients/phone/phone.psk allowed-ips 10.8.0.2/32,fd42:42:42::2/128"
  [[ "$output" == *"live update failed"* ]]
  [[ "$output" == *"peer config was updated in"* ]]
}

@test "default remove-peer keeps config update when live update fails" {
  setup_wg_peer_fixture "present"
  touch "${WG_STUB_FAIL_SET_FILE}"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_remove_peer_main phone
  popd >/dev/null

  [ "$status" -ne 0 ]
  assert_file_not_contains "${WG_FIXTURE_SERVER_CONFIG}" "PublicKey = client-public"
  assert_file_contains "${WG_STUB_LOG}" "set wg0 peer client-public remove"
  [[ "$output" == *"live update failed"* ]]
  [[ "$output" == *"peer config was removed from"* ]]
}

@test "peer commands reject live-only with config-only" {
  setup_wg_peer_fixture "absent"

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_add_peer_main --live-only --config-only phone
  popd >/dev/null

  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: add-peer.sh"* ]]

  pushd "${WG_FIXTURE_BUNDLE_DIR}" >/dev/null
  run wg_family_remove_peer_main --live-only --config-only phone
  popd >/dev/null

  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: remove-peer.sh"* ]]
  [ ! -e "${WG_STUB_LOG}" ]
}

@test "new WireGuard client output excludes separate private key and QR text" {
  local bundle_dir="${TEST_TMPDIR}/bundle"
  local server_dir="${TEST_TMPDIR}/server"
  local add_peer_log="${TEST_TMPDIR}/add-peer-calls.log"

  mkdir -p "${bundle_dir}" "${server_dir}" "${TEST_TMPDIR}/bin"
  cat > "${bundle_dir}/wg0-client.example.conf" <<'EOF'
[Interface]
Address = :CLIENT_IP:/32, :CLIENT_IP6:/128
PrivateKey = :CLIENT_KEY:

[Peer]
PublicKey = :SERVER_PUB_KEY:
PresharedKey = :PRESHARED_KEY:
Endpoint = :SERVER_ENDPOINT:
EOF
  cat > "${bundle_dir}/add-peer.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ADD_PEER_LOG}"
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/wg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  genkey) printf 'client-private\n' ;;
  pubkey) cat >/dev/null; printf 'client-public\n' ;;
  genpsk) printf 'client-psk\n' ;;
esac
EOF
  cat > "${TEST_TMPDIR}/bin/awk" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == "/etc/hosts" ]]; then
    exit 0
  fi
done
exec /usr/bin/awk "$@"
EOF
  chmod +x "${bundle_dir}/add-peer.sh" "${TEST_TMPDIR}/bin/wg" "${TEST_TMPDIR}/bin/awk"
  printf 'server-public\n' > "${server_dir}/server_public_key"
  printf '[Interface]\nPrivateKey = server-private\n' > "${server_dir}/wg0.conf"
  printf '10.8.0.1\n' > "${bundle_dir}/last-ip.txt"
  printf 'fd42:42:42::1\n' > "${bundle_dir}/last-ip6.txt"
  printf '198.51.100.10\n' > "${bundle_dir}/server-endpoint.txt"
  printf '51820\n' > "${bundle_dir}/server-port.txt"
  printf '10.8.0.0/24\n' > "${bundle_dir}/server-net.txt"
  printf 'fd42:42:42::/64\n' > "${bundle_dir}/server-net6.txt"
  printf 'wg0\n' > "${bundle_dir}/server-interface.txt"

  export ADD_PEER_LOG="${add_peer_log}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  setup_wg_family_env "${bundle_dir}" "${server_dir}"

  pushd "${bundle_dir}" >/dev/null
  wg_family_add_client_main phone
  popd >/dev/null

  [ -f "${bundle_dir}/clients/phone/wg0-phone.conf" ]
  [ -f "${bundle_dir}/clients/phone/phone.pub" ]
  [ -f "${bundle_dir}/clients/phone/phone.psk" ]
  [ ! -e "${bundle_dir}/clients/phone/phone.priv" ]
  [ ! -e "${bundle_dir}/clients/phone/wg0-phone-qrcode.txt" ]
  [ "$(sed -n '1p' "${add_peer_log}")" = "--config-only phone" ]
  [ "$(sed -n '2p' "${add_peer_log}")" = "--live-only phone" ]
}

@test "remove-client removes config peer before tolerant live peer" {
  local bundle_dir="${TEST_TMPDIR}/bundle"
  local server_dir="${TEST_TMPDIR}/server"
  local remove_peer_log="${TEST_TMPDIR}/remove-peer-calls.log"
  local hosts_file="${TEST_TMPDIR}/hosts"

  mkdir -p "${bundle_dir}/clients/phone" "${server_dir}"
  printf 'client-public\n' > "${bundle_dir}/clients/phone/phone.pub"
  cat > "${bundle_dir}/clients/phone/wg0-phone.conf" <<'EOF'
[Interface]
Address = 10.8.0.2/32, fd42:42:42::2/128
EOF
  printf '10.8.0.2 phone\n10.8.0.3 other\n' > "${hosts_file}"
  cat > "${bundle_dir}/remove-peer.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REMOVE_PEER_LOG}"
if [[ "$1" = "--live-only" ]]; then
  exit 47
fi
exit 0
EOF
  chmod +x "${bundle_dir}/remove-peer.sh"

  export REMOVE_PEER_LOG="${remove_peer_log}"
  setup_wg_hosts_file "${hosts_file}"
  setup_wg_family_env "${bundle_dir}" "${server_dir}"

  pushd "${bundle_dir}" >/dev/null
  run wg_family_remove_client_main phone
  popd >/dev/null

  [ "$status" -eq 0 ]
  [ ! -d "${bundle_dir}/clients/phone" ]
  [ "$(sed -n '1p' "${remove_peer_log}")" = "--config-only phone" ]
  [ "$(sed -n '2p' "${remove_peer_log}")" = "--live-only phone" ]
  [ "$(awk '$0 == "10.8.0.2 phone" { count++ } END { print count + 0 }' "${hosts_file}")" -eq 0 ]
  assert_file_contains "${hosts_file}" "10.8.0.3 other"
}

@test "generated hosts cleanup removes exact entries for existing client configs" {
  local bundle_dir="${TEST_TMPDIR}/bundle"
  local server_dir="${TEST_TMPDIR}/server"
  local hosts_file="${TEST_TMPDIR}/hosts"

  mkdir -p "${bundle_dir}/clients/phone" "${bundle_dir}/clients/laptop" "${bundle_dir}/clients/broken" "${server_dir}"
  cat > "${bundle_dir}/clients/phone/wg0-phone.conf" <<'EOF'
[Interface]
Address = 10.8.0.2/32, fd42:42:42::2/128
EOF
  cat > "${bundle_dir}/clients/laptop/wg0-laptop.conf" <<'EOF'
[Interface]
Address = 10.8.0.3/32
EOF
  cat > "${bundle_dir}/clients/broken/wg0-broken.conf" <<'EOF'
[Interface]
PrivateKey = missing-address
EOF
  cat > "${hosts_file}" <<'EOF'
127.0.0.1 localhost
10.8.0.2 phone
10.8.0.3 laptop
10.8.0.4 phone
10.8.0.2 phone alias
10.8.0.5 broken
EOF

  setup_wg_hosts_file "${hosts_file}"
  setup_wg_family_env "${bundle_dir}" "${server_dir}"

  run wg_family_remove_generated_hosts_entries
  [ "$status" -eq 0 ]

  [ "$(awk '$0 == "10.8.0.2 phone" { count++ } END { print count + 0 }' "${hosts_file}")" -eq 0 ]
  [ "$(awk '$0 == "10.8.0.3 laptop" { count++ } END { print count + 0 }' "${hosts_file}")" -eq 0 ]
  assert_file_contains "${hosts_file}" "127.0.0.1 localhost"
  assert_file_contains "${hosts_file}" "10.8.0.4 phone"
  assert_file_contains "${hosts_file}" "10.8.0.2 phone alias"
  assert_file_contains "${hosts_file}" "10.8.0.5 broken"
}
