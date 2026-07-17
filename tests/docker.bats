#!/usr/bin/env bats

load test_helper

setup() {
  make_temp_dir
  mkdir -p "${TEST_TMPDIR}/bin"
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
  export VPS_DOCKER_OS_RELEASE="${TEST_TMPDIR}/os-release"
  export VPS_DOCKER_KEYRING="${TEST_TMPDIR}/apt/keyrings/docker.asc"
  export VPS_DOCKER_SOURCE="${TEST_TMPDIR}/apt/sources.list.d/docker.sources"
  load_docker
}

teardown() {
  remove_temp_dir
}

@test "Docker readiness requires Engine and Compose v2" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  info|"compose version") exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run vps_docker_is_ready
  [ "${status}" -eq 0 ]

  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "info" ]]
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run vps_docker_is_ready
  [ "${status}" -ne 0 ]
}

@test "Docker ensure reuses a ready installation" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  info|"compose version") exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"
  vps_docker_install_official() {
    return 99
  }

  run vps_docker_ensure_ready
  [ "${status}" -eq 0 ]
}

@test "Docker ensure refuses a partial installation" {
  cat > "${TEST_TMPDIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run vps_docker_ensure_ready
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"partially installed or unavailable"* ]]
}

@test "Docker ensure refuses conflicting runtime packages without a Docker command" {
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "containerd" ]]; then
  printf 'ii \n'
  exit 0
fi
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query"

  run vps_docker_ensure_ready
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"partially installed or unavailable"* ]]
}

@test "Docker distribution accepts Debian and rejects derivatives" {
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "${VPS_DOCKER_OS_RELEASE}"

  run vps_docker_distribution
  [ "${status}" -eq 0 ]
  [ "${output}" = "debian" ]
  run vps_docker_codename
  [ "${status}" -eq 0 ]
  [ "${output}" = "bookworm" ]

  printf 'ID=linuxmint\nVERSION_CODENAME=wilma\n' > "${VPS_DOCKER_OS_RELEASE}"
  run vps_docker_distribution
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"only on Debian or Ubuntu"* ]]
}

@test "official Docker install writes a scoped apt source" {
  local apt_log="${TEST_TMPDIR}/apt.log"
  local systemctl_log="${TEST_TMPDIR}/systemctl.log"

  export TEST_DOCKER_BIN="${TEST_TMPDIR}/bin/docker"
  export TEST_SYSTEMCTL_LOG="${systemctl_log}"

  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "${VPS_DOCKER_OS_RELEASE}"
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
printf 'docker-key\n' > "${output}"
EOF
  cat > "${TEST_TMPDIR}/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--print-architecture" ]] || exit 1
printf 'amd64\n'
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${apt_log}"
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SYSTEMCTL_LOG}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  info|"compose version") exit 0 ;;' \
  '  *) exit 1 ;;' \
  'esac' > "${TEST_DOCKER_BIN}"
chmod +x "${TEST_DOCKER_BIN}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  vps_require_root() {
    return 0
  }
  vps_require_systemd() {
    return 0
  }

  run vps_docker_install_official
  [ "${status}" -eq 0 ]
  assert_file_contains "${VPS_DOCKER_SOURCE}" "URIs: https://download.docker.com/linux/ubuntu"
  assert_file_contains "${VPS_DOCKER_SOURCE}" "Suites: noble"
  assert_file_contains "${VPS_DOCKER_SOURCE}" "Architectures: amd64"
  [ "$(sed -n '1p' "${apt_log}")" = "update" ]
  [[ "$(sed -n '2p' "${apt_log}")" == "install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" ]]
  [ "$(cat "${systemctl_log}")" = "enable --now docker" ]
}

@test "Compose wrapper validates ownership inputs and forwards arguments" {
  local docker_log="${TEST_TMPDIR}/docker.log"
  local project_dir="${TEST_TMPDIR}/project"

  mkdir -p "${project_dir}"
  cat > "${TEST_TMPDIR}/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${docker_log}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/docker"

  run vps_docker_compose "${project_dir}" "example-proxy" up -d
  [ "${status}" -eq 0 ]
  [ "$(cat "${docker_log}")" = "compose --project-directory ${project_dir} --project-name example-proxy up -d" ]

  run vps_docker_compose "${project_dir}" "../unsafe" config
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"project name is invalid"* ]]
}
