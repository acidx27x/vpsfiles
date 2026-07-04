#!/usr/bin/env bats

load test_helper

setup() {
  make_temp_dir
  mkdir -p "${TEST_TMPDIR}/bin"
  PATH="${TEST_TMPDIR}/bin:${PATH}"
}

teardown() {
  remove_temp_dir
}

@test "package updates are scoped to explicitly named packages" {
  local log_file="${TEST_TMPDIR}/apt.log"

  load_update
  cat > "${TEST_TMPDIR}/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log_file}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/apt-get"

  vps_update_packages wireguard wireguard-tools

  [ "$(sed -n '1p' "${log_file}")" = "update" ]
  [ "$(sed -n '2p' "${log_file}")" = "install -y --only-upgrade wireguard wireguard-tools" ]
}

@test "active service restart verifies final active state" {
  local log_file="${TEST_TMPDIR}/systemctl.log"

  load_update
  cat > "${TEST_TMPDIR}/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log_file}"
case "\$1" in
  restart|is-active) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl"

  run vps_restart_active_service "xray"
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${log_file}")" = "restart xray" ]
  [ "$(sed -n '2p' "${log_file}")" = "is-active --quiet xray" ]
}

@test "active service restart fails when restart command fails" {
  load_update
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  restart) exit 1 ;;
  is-active) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl"

  run vps_restart_active_service "xray"
  [ "${status}" -ne 0 ]
}

@test "Telemt release URLs support latest and pinned versions" {
  load_telemt
  cat > "${TEST_TMPDIR}/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'x86_64\n'
EOF
  cat > "${TEST_TMPDIR}/bin/ldd" <<'EOF'
#!/usr/bin/env bash
printf 'musl libc\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/uname" "${TEST_TMPDIR}/bin/ldd"

  [ "$(telemt_release_url latest)" = "https://github.com/telemt/telemt/releases/latest/download/telemt-x86_64-linux-musl.tar.gz" ]
  [ "$(telemt_release_url v1.2.3)" = "https://github.com/telemt/telemt/releases/download/v1.2.3/telemt-x86_64-linux-musl.tar.gz" ]
}

@test "update commands require root before package updates" {
  local log_file="${TEST_TMPDIR}/apt.log"

  cat > "${TEST_TMPDIR}/bin/wg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/wg-quick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log_file}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/wg" "${TEST_TMPDIR}/bin/wg-quick" "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/apt-get"

  run bash "${REPO_ROOT}/wireguard-scripts/update.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]
  [ ! -e "${log_file}" ]
}
