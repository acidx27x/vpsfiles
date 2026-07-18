#!/usr/bin/env bats

load test_helper

setup() {
  make_temp_dir
  mkdir -p "${TEST_TMPDIR}/bin"
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
  load_tg_ws
}

teardown() {
  remove_temp_dir
}

@test "tg-ws accepts stable releases and rejects mutable refs" {
  run tg_ws_validate_version latest
  [ "${status}" -eq 0 ]
  run tg_ws_validate_version v1.8.1
  [ "${status}" -eq 0 ]
  run tg_ws_validate_version main
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"latest or a stable tag"* ]]
}

@test "tg-ws validates permanent secrets and both public address families" {
  run tg_ws_validate_secret 0123456789abcdef0123456789abcdef
  [ "${status}" -eq 0 ]
  run tg_ws_validate_ipv4 203.0.113.10
  [ "${status}" -eq 0 ]
  run tg_ws_validate_ipv6 2001:db8::10
  [ "${status}" -eq 0 ]

  run tg_ws_validate_secret short
  [ "${status}" -ne 0 ]
  run tg_ws_validate_ipv4 203.0.113.999
  [ "${status}" -ne 0 ]
  run tg_ws_validate_ipv6 not-an-ip
  [ "${status}" -ne 0 ]
}

@test "tg-ws requires the IPv6 listener address on a global host interface" {
  cat > "${TEST_TMPDIR}/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '2: eth0    inet6 2001:db8::10/64 scope global dynamic\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/ip"

  run tg_ws_require_local_global_ipv6 2001:db8::10
  [ "${status}" -eq 0 ]
  run tg_ws_require_local_global_ipv6 ""
  [ "${status}" -eq 0 ]
  run tg_ws_require_local_global_ipv6 2001:db8::11
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not assigned globally"* ]]
}

@test "tg-ws accepts an omitted IPv6 address but rejects a malformed configured address" {
  run tg_ws_validate_optional_ipv6 ""
  [ "${status}" -eq 0 ]

  run tg_ws_validate_optional_ipv6 not-an-ip
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"public IPv6 address is invalid"* ]]
}

@test "tg-ws validates optional Worker and FakeTLS domains with specific errors" {
  run tg_ws_validate_domain "" "FakeTLS/SNI domain"
  [ "${status}" -eq 0 ]
  run tg_ws_validate_domain proxy.example.com "FakeTLS/SNI domain"
  [ "${status}" -eq 0 ]

  run tg_ws_validate_domain bad_domain "FakeTLS/SNI domain"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"FakeTLS/SNI domain is invalid"* ]]

  run tg_ws_validate_domain bad_domain "Cloudflare Worker domain"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Cloudflare Worker domain is invalid"* ]]
}

@test "latest tg-ws release resolves to an immutable stable tag" {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"tag_name":"v1.8.1"}\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  run tg_ws_resolve_version latest
  [ "${status}" -eq 0 ]
  [ "${output}" = "v1.8.1" ]
  run tg_ws_resolve_version v1.7.0
  [ "${status}" -eq 0 ]
  [ "${output}" = "v1.7.0" ]
}

@test "tagged source download validates the embedded release version" {
  local archive="${TEST_TMPDIR}/release.tar.gz"
  local fixture="${TEST_TMPDIR}/fixture/tg-ws-proxy-1.8.1"
  local destination="${TEST_TMPDIR}/source"

  mkdir -p "${fixture}/proxy"
  printf 'FROM scratch\n' > "${fixture}/Dockerfile"
  printf '# proxy\n' > "${fixture}/proxy/tg_ws_proxy.py"
  printf '__version__ = "1.8.1"\n' > "${fixture}/proxy/__init__.py"
  tar -czf "${archive}" -C "${TEST_TMPDIR}/fixture" tg-ws-proxy-1.8.1
  export TEST_RELEASE_ARCHIVE="${archive}"
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while (( $# > 0 )); do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
cp "${TEST_RELEASE_ARCHIVE}" "${output}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  run tg_ws_download_source v1.8.1 "${destination}"
  [ "${status}" -eq 0 ]
  [ -f "${destination}/Dockerfile" ]
  [ -f "${destination}/proxy/tg_ws_proxy.py" ]
}

@test "tg-ws environment and client link preserve one shared credential" {
  local compose_dir="${TEST_TMPDIR}/compose"
  local secret="0123456789abcdef0123456789abcdef"

  mkdir -p "${compose_dir}"
  tg_ws_write_env \
    "${compose_dir}" \
    "vpsfiles/tg-ws-proxy:v1.8.1" \
    "v1.8.1" \
    "proxy.example.com" \
    "203.0.113.10" \
    "2001:db8::10" \
    "1443" \
    "${secret}" \
    "random-name.example.workers.dev" \
    "Proxy.Example.Com"

  [ "$(tg_ws_env_get "${compose_dir}/.env" TG_WS_PROXY_SECRET)" = "${secret}" ]
  [ "$(tg_ws_env_get "${compose_dir}/.env" TG_WS_PROXY_DC_IPS)" = "${TG_WS_DC_IPS_DEFAULT}" ]
  [ "$(tg_ws_env_get "${compose_dir}/.env" TG_WS_PROXY_FAKE_TLS_DOMAIN)" = "proxy.example.com" ]
  [ "$(tg_ws_env_get "${compose_dir}/.env" COMPOSE_PROFILES)" = "ipv6" ]
  [ "$(stat -c '%a' "${compose_dir}/.env")" = "600" ]

  run tg_ws_client_url proxy.example.com 1443 "${secret}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "tg://proxy?server=proxy.example.com&port=1443&secret=dd${secret}" ]

  run tg_ws_client_url proxy.example.com 1443 "${secret}" Proxy.Example.Com
  [ "${status}" -eq 0 ]
  [ "${output}" = "tg://proxy?server=proxy.example.com&port=1443&secret=ee${secret}70726f78792e6578616d706c652e636f6d" ]
}

@test "tg-ws installer exports and cleans up its repository client link" {
  local gitignore="${REPO_ROOT}/tg-ws-scripts/.gitignore"
  local install_script="${REPO_ROOT}/tg-ws-scripts/install.sh"
  local uninstall_script="${REPO_ROOT}/tg-ws-scripts/uninstall.sh"

  assert_file_contains "${gitignore}" '/tg-ws-link.txt'
  assert_file_contains "${install_script}" 'install -m 600 "${TG_WS_COMPOSE_DIR}/client.txt" "${SCRIPT_DIR}/tg-ws-link.txt"'
  assert_file_contains "${install_script}" '"${SCRIPT_DIR}/tg-ws-link.txt"'
  assert_file_contains "${uninstall_script}" '"${SCRIPT_DIR}/tg-ws-link.txt"'
}

@test "tg-ws environment disables the IPv6 Compose profile when IPv6 is omitted" {
  local compose_dir="${TEST_TMPDIR}/compose"
  local secret="0123456789abcdef0123456789abcdef"

  mkdir -p "${compose_dir}"
  tg_ws_write_env \
    "${compose_dir}" \
    "vpsfiles/tg-ws-proxy:v1.8.1" \
    "v1.8.1" \
    "203.0.113.10" \
    "203.0.113.10" \
    "" \
    "1443" \
    "${secret}" \
    "" \
    ""

  [ -z "$(tg_ws_env_get "${compose_dir}/.env" TG_WS_PROXY_IPV6)" ]
  [ -z "$(tg_ws_env_get "${compose_dir}/.env" COMPOSE_PROFILES)" ]
}

@test "restricted Worker allows only installed VPS sources and Telegram DCs" {
  local worker_file="${TEST_TMPDIR}/worker.js"

  tg_ws_render_worker \
    "${REPO_ROOT}/tg-ws-scripts/cf-worker.js.example" \
    "203.0.113.10" \
    "2001:db8::10" > "${worker_file}"

  assert_file_contains "${worker_file}" '"203.0.113.10"'
  assert_file_contains "${worker_file}" '"2001:db8::10"'
  assert_file_contains "${worker_file}" 'request.headers.get("CF-Connecting-IP")'
  assert_file_contains "${worker_file}" 'ALLOWED_DESTINATIONS.has(destination)'
  assert_file_contains "${worker_file}" 'connect({ hostname: destination, port: 443 })'
  assert_file_not_contains "${worker_file}" ':VPS_IPV4:'
}

@test "restricted Worker omits an empty IPv6 source" {
  local worker_file="${TEST_TMPDIR}/worker.js"

  tg_ws_render_worker \
    "${REPO_ROOT}/tg-ws-scripts/cf-worker.js.example" \
    "203.0.113.10" \
    "" > "${worker_file}"

  assert_file_contains "${worker_file}" '"203.0.113.10"'
  assert_file_not_contains "${worker_file}" ':VPS_IPV6:'
  assert_file_not_contains "${worker_file}" $'\t"",'
}

@test "Compose template uses hardened host networking with optional FakeTLS and no published ports" {
  local compose_file="${REPO_ROOT}/tg-ws-scripts/compose.yaml.example"

  assert_file_contains "${compose_file}" "network_mode: host"
  assert_file_contains "${compose_file}" "restart: unless-stopped"
  assert_file_contains "${compose_file}" "read_only: true"
  assert_file_contains "${compose_file}" "no-new-privileges:true"
  assert_file_contains "${compose_file}" "--no-cfproxy"
  assert_file_contains "${compose_file}" "profiles:"
  assert_file_contains "${compose_file}" "- ipv6"
  assert_file_contains "${compose_file}" "TG_WS_PROXY_HOST: \"\${TG_WS_PROXY_IPV6}\""
  assert_file_contains "${compose_file}" '--fake-tls-domain=${TG_WS_PROXY_FAKE_TLS_DOMAIN:-}'
  assert_file_not_contains "${compose_file}" "ports:"
}

@test "image validation requires tg-ws options and a non-root runtime user" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "run --rm test:v1 --no-cfproxy --help")
    printf '%s\n' '--host --secret --cfproxy-worker-domain --fake-tls-domain --no-cfproxy'
    ;;
  "image inspect --format {{.Config.User}} test:v1")
    printf 'app\n'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run tg_ws_validate_image test:v1
  [ "${status}" -eq 0 ]
}

@test "image validation rejects a release without FakeTLS support" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "run --rm test:v1 --no-cfproxy --help")
    printf '%s\n' '--host --secret --cfproxy-worker-domain --no-cfproxy'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run tg_ws_validate_image test:v1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not support required option: --fake-tls-domain"* ]]
}

@test "old image cleanup is limited to unused tg-ws bundle images" {
  local docker_log="${TEST_TMPDIR}/docker-prune.log"

  export TEST_DOCKER_PRUNE_LOG="${docker_log}"
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_DOCKER_PRUNE_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run tg_ws_cleanup_old_images
  [ "${status}" -eq 0 ]
  [ "$(cat "${docker_log}")" = "image prune --all --force --filter label=${TG_WS_BUNDLE_LABEL}" ]
}

@test "old image cleanup failure does not turn a verified update into a failure" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run tg_ws_cleanup_old_images
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"updated, but unused old bundle images could not be removed"* ]]
}

@test "project state rejects one-running one-stopped containers" {
  vps_docker_compose() {
    case "${*: -1}" in
      proxy-ipv4) printf 'ipv4-id\n' ;;
      proxy-ipv6) printf 'ipv6-id\n' ;;
    esac
  }
  docker() {
    case "${*: -1}" in
      ipv4-id) printf 'true\n' ;;
      ipv6-id) printf 'false\n' ;;
    esac
  }
  mkdir -p "${TEST_TMPDIR}/compose"

  run tg_ws_project_state "${TEST_TMPDIR}/compose" tg-ws-proxy 2001:db8::10
  [ "${status}" -eq 0 ]
  [ "${output}" = "mixed" ]
}

@test "project state and health check require only IPv4 when IPv6 is omitted" {
  vps_docker_compose() {
    case "${*: -1}" in
      proxy-ipv4) printf 'ipv4-id\n' ;;
      proxy-ipv6) return 1 ;;
    esac
  }
  docker() {
    printf 'true\n'
  }
  nc() {
    [[ "$1" == "-4" ]]
  }
  mkdir -p "${TEST_TMPDIR}/compose"

  run tg_ws_project_state "${TEST_TMPDIR}/compose" tg-ws-proxy ""
  [ "${status}" -eq 0 ]
  [ "${output}" = "running" ]

  run tg_ws_verify_running "${TEST_TMPDIR}/compose" tg-ws-proxy "" 1443
  [ "${status}" -eq 0 ]
}

@test "port preflight rejects an existing listener" {
  cat > "${TEST_TMPDIR}/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:1443 0.0.0.0:*\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/ss"

  run tg_ws_require_port_available 1443
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already in use"* ]]
}

@test "tg-ws public commands require root before deployment work" {
  run bash "${REPO_ROOT}/tg-ws-scripts/install.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]

  run bash "${REPO_ROOT}/tg-ws-scripts/update.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]

  run bash "${REPO_ROOT}/tg-ws-scripts/uninstall.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]
}
