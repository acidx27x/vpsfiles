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

@test "Xray update uses the official install action" {
  local update_script="${REPO_ROOT}/xray-scripts/update.sh"

  assert_file_contains "${update_script}" "xray_run_installer install --no-update-service"
  assert_file_not_contains "${update_script}" "xray_run_installer update"
}

@test "Xray update rollback restores the binary and geodata" {
  local asset_dir="${TEST_TMPDIR}/assets"
  local backup_dir="${TEST_TMPDIR}/backup"
  local xray_bin="${TEST_TMPDIR}/xray"

  # shellcheck source=xray-scripts/update.sh
  . "${REPO_ROOT}/xray-scripts/update.sh"
  mkdir -p "${asset_dir}" "${backup_dir}"
  printf 'old binary\n' > "${backup_dir}/xray"
  printf 'old geoip\n' > "${backup_dir}/geoip.dat"
  printf 'old geosite\n' > "${backup_dir}/geosite.dat"
  printf 'new binary\n' > "${xray_bin}"
  printf 'new geoip\n' > "${asset_dir}/geoip.dat"
  printf 'new geosite\n' > "${asset_dir}/geosite.dat"

  restore_previous_xray_update "${backup_dir}" "${xray_bin}" "${asset_dir}"

  [ "$(<"${xray_bin}")" = "old binary" ]
  [ "$(<"${asset_dir}/geoip.dat")" = "old geoip" ]
  [ "$(<"${asset_dir}/geosite.dat")" = "old geosite" ]
  [ -x "${xray_bin}" ]
}
