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

@test "new WireGuard client output excludes separate private key and QR text" {
  local bundle_dir="${TEST_TMPDIR}/bundle"
  local server_dir="${TEST_TMPDIR}/server"

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
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  vps_require_root() { :; }

  pushd "${bundle_dir}" >/dev/null
  wg_family_add_client_main phone
  popd >/dev/null

  [ -f "${bundle_dir}/clients/phone/wg0-phone.conf" ]
  [ -f "${bundle_dir}/clients/phone/phone.pub" ]
  [ -f "${bundle_dir}/clients/phone/phone.psk" ]
  [ ! -e "${bundle_dir}/clients/phone/phone.priv" ]
  [ ! -e "${bundle_dir}/clients/phone/wg0-phone-qrcode.txt" ]
}
