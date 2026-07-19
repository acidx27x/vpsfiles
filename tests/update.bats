#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats test cases run in isolated subshells.

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

@test "failed package metadata refresh prevents package installation" {
  local log_file="${TEST_TMPDIR}/apt.log"

  load_update
  cat > "${TEST_TMPDIR}/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${log_file}"
[[ "\$1" != "update" ]]
EOF
  chmod +x "${TEST_TMPDIR}/bin/apt-get"

  run vps_update_packages wireguard wireguard-tools

  [ "${status}" -ne 0 ]
  [ "$(<"${log_file}")" = "update" ]
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

@test "Xray rollback restores artifacts and verifies an originally active service" {
  local asset_dir="${TEST_TMPDIR}/assets"
  local backup_dir="${TEST_TMPDIR}/backup"
  local config_file="${TEST_TMPDIR}/config.json"
  local permission_log="${TEST_TMPDIR}/permissions.log"
  local service_log="${TEST_TMPDIR}/service.log"
  local xray_bin="${TEST_TMPDIR}/xray"

  # shellcheck source=xray-scripts/update.sh
  . "${REPO_ROOT}/xray-scripts/update.sh"
  mkdir -p "${asset_dir}" "${backup_dir}"
  printf '{}\n' > "${config_file}"
  printf 'old binary\n' > "${backup_dir}/xray"
  printf 'old geoip\n' > "${backup_dir}/geoip.dat"
  printf 'old geosite\n' > "${backup_dir}/geosite.dat"
  printf 'new binary\n' > "${xray_bin}"
  printf 'new geoip\n' > "${asset_dir}/geoip.dat"
  printf 'new geosite\n' > "${asset_dir}/geosite.dat"
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  xray_config_uses_managed_geodata() {
    return 0
  }
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  xray_prepare_geodata_permissions() {
    printf '%s\n' "$*" >> "${permission_log}"
  }
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  vps_restart_active_service() {
    printf '%s\n' "$1" >> "${service_log}"
  }

  restore_previous_xray_update \
    "${backup_dir}" "${xray_bin}" "${asset_dir}" "${config_file}" "xray" 1

  [ "$(<"${xray_bin}")" = "old binary" ]
  [ "$(<"${asset_dir}/geoip.dat")" = "old geoip" ]
  [ "$(<"${asset_dir}/geosite.dat")" = "old geosite" ]
  [ -x "${xray_bin}" ]
  [ "$(<"${permission_log}")" = "${config_file} xray ${asset_dir}" ]
  [ "$(<"${service_log}")" = "xray" ]
}

@test "Xray rollback leaves an originally inactive service stopped" {
  local asset_dir="${TEST_TMPDIR}/assets"
  local backup_dir="${TEST_TMPDIR}/backup"
  local config_file="${TEST_TMPDIR}/config.json"
  local service_log="${TEST_TMPDIR}/service.log"
  local xray_bin="${TEST_TMPDIR}/xray"

  # shellcheck source=xray-scripts/update.sh
  . "${REPO_ROOT}/xray-scripts/update.sh"
  mkdir -p "${asset_dir}" "${backup_dir}"
  printf '{}\n' > "${config_file}"
  printf 'old binary\n' > "${backup_dir}/xray"
  printf 'new binary\n' > "${xray_bin}"
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  xray_config_uses_managed_geodata() {
    return 1
  }
  # shellcheck disable=SC2317 # Must not be invoked for an inactive service.
  vps_restart_active_service() {
    printf '%s\n' "$1" >> "${service_log}"
  }

  restore_previous_xray_update \
    "${backup_dir}" "${xray_bin}" "${asset_dir}" "${config_file}" "xray" 0

  [ "$(<"${xray_bin}")" = "old binary" ]
  [ ! -e "${service_log}" ]
}

@test "Xray rollback propagates service recovery failure" {
  local asset_dir="${TEST_TMPDIR}/assets"
  local backup_dir="${TEST_TMPDIR}/backup"
  local config_file="${TEST_TMPDIR}/config.json"
  local xray_bin="${TEST_TMPDIR}/xray"

  # shellcheck source=xray-scripts/update.sh
  . "${REPO_ROOT}/xray-scripts/update.sh"
  mkdir -p "${asset_dir}" "${backup_dir}"
  printf '{}\n' > "${config_file}"
  printf 'old binary\n' > "${backup_dir}/xray"
  printf 'new binary\n' > "${xray_bin}"
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  xray_config_uses_managed_geodata() {
    return 1
  }
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  vps_restart_active_service() {
    return 1
  }

  run restore_previous_xray_update \
    "${backup_dir}" "${xray_bin}" "${asset_dir}" "${config_file}" "xray" 1

  [ "${status}" -ne 0 ]
}

@test "Telemt failed update restores its binary and verifies service recovery" {
  local bin_path="${TEST_TMPDIR}/telemt"
  local config_file="${TEST_TMPDIR}/telemt.toml"
  local restart_count_file="${TEST_TMPDIR}/restart-count"

  # shellcheck source=telemt-scripts/update.sh
  . "${REPO_ROOT}/telemt-scripts/update.sh"
  cd "${TEST_TMPDIR}"
  printf 'config\n' > "${config_file}"
  printf '#!/usr/bin/env bash\nprintf old\n' > "${bin_path}"
  chmod +x "${bin_path}"
  printf '%s\n' "${config_file}" > telemt-config-path.txt
  printf 'telemt\n' > telemt-service.txt
  printf '%s\n' "${bin_path}" > telemt-bin-path.txt
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_root() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_systemd() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_commands() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_confirm() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_update_packages() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  telemt_validate_version() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  telemt_download_binary() {
    printf '#!/usr/bin/env bash\nprintf new\n' > "$2"
  }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_service_is_active() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main and rollback helper.
  vps_restart_active_service() {
    local count=0

    [[ ! -f "${restart_count_file}" ]] || count="$(<"${restart_count_file}")"
    ((count += 1))
    printf '%s\n' "${count}" > "${restart_count_file}"
    [[ "${count}" -gt 1 ]]
  }

  run main

  [ "${status}" -ne 0 ]
  [ "$(<"${restart_count_file}")" -eq 2 ]
  [[ "$(<"${bin_path}")" == *"printf old"* ]]
  [[ "${output}" == *"previous binary was restored"* ]]
}

@test "Telemt rollback leaves an originally inactive service stopped" {
  local backup_bin="${TEST_TMPDIR}/telemt.backup"
  local bin_path="${TEST_TMPDIR}/telemt"
  local service_log="${TEST_TMPDIR}/service.log"

  # shellcheck source=telemt-scripts/update.sh
  . "${REPO_ROOT}/telemt-scripts/update.sh"
  printf 'old binary\n' > "${backup_bin}"
  printf 'new binary\n' > "${bin_path}"
  # shellcheck disable=SC2317 # Must not be invoked for an inactive service.
  vps_restart_active_service() {
    printf '%s\n' "$1" >> "${service_log}"
  }

  restore_previous_telemt_update "${backup_bin}" "${bin_path}" "telemt" 0

  [ "$(<"${bin_path}")" = "old binary" ]
  [ ! -e "${service_log}" ]
}

@test "Telemt rollback propagates service recovery failure" {
  local backup_bin="${TEST_TMPDIR}/telemt.backup"
  local bin_path="${TEST_TMPDIR}/telemt"

  # shellcheck source=telemt-scripts/update.sh
  . "${REPO_ROOT}/telemt-scripts/update.sh"
  printf 'old binary\n' > "${backup_bin}"
  printf 'new binary\n' > "${bin_path}"
  # shellcheck disable=SC2317 # Invoked indirectly by the rollback helper.
  vps_restart_active_service() {
    return 1
  }

  run restore_previous_telemt_update "${backup_bin}" "${bin_path}" "telemt" 1

  [ "${status}" -ne 0 ]
}

@test "WireGuard validates before and after APT and warns about snapshot rollback" {
  local action_log="${TEST_TMPDIR}/actions.log"
  local config_dir="${TEST_TMPDIR}/wireguard"

  # shellcheck source=wireguard-scripts/update.sh
  . "${REPO_ROOT}/wireguard-scripts/update.sh"
  cd "${TEST_TMPDIR}"
  WG_DIR="${config_dir}"
  mkdir -p "${WG_DIR}"
  printf 'wg0\n' > server-interface.txt
  printf '[Interface]\n' > "${WG_DIR}/wg0.conf"
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_root() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_systemd() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_commands() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_service_is_active() { return 1; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_confirm() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_update_packages() {
    printf 'apt\n' >> "${action_log}"
  }
  wg-quick() {
    printf 'validate\n' >> "${action_log}"
    [[ "${TEST_CONFIG_VALID}" -eq 1 ]]
  }

  TEST_CONFIG_VALID=0
  run main
  [ "${status}" -ne 0 ]
  [ "$(<"${action_log}")" = "validate" ]

  : > "${action_log}"
  TEST_CONFIG_VALID=1
  run main
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${action_log}")" = "validate" ]
  [ "$(sed -n '2p' "${action_log}")" = "apt" ]
  [ "$(sed -n '3p' "${action_log}")" = "validate" ]
  [[ "${output}" == *"cannot be automatically downgraded"* ]]
  [[ "${output}" == *"provider snapshot"*"full rollback"* ]]
}

@test "AmneziaWG validates before and after APT and warns about snapshot rollback" {
  local action_log="${TEST_TMPDIR}/actions.log"
  local config_dir="${TEST_TMPDIR}/amneziawg"

  # shellcheck source=amnezia-scripts/update.sh
  . "${REPO_ROOT}/amnezia-scripts/update.sh"
  cd "${TEST_TMPDIR}"
  AWG_DIR="${config_dir}"
  mkdir -p "${AWG_DIR}"
  printf 'awg0\n' > server-interface.txt
  printf '[Interface]\n' > "${AWG_DIR}/awg0.conf"
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_root() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_systemd() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_require_commands() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_service_is_active() { return 1; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_confirm() { return 0; }
  # shellcheck disable=SC2317 # Invoked indirectly by main.
  vps_update_packages() {
    printf 'apt\n' >> "${action_log}"
  }
  awg-quick() {
    printf 'validate\n' >> "${action_log}"
    [[ "${TEST_CONFIG_VALID}" -eq 1 ]]
  }

  TEST_CONFIG_VALID=0
  run main
  [ "${status}" -ne 0 ]
  [ "$(<"${action_log}")" = "validate" ]

  : > "${action_log}"
  TEST_CONFIG_VALID=1
  run main
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${action_log}")" = "validate" ]
  [ "$(sed -n '2p' "${action_log}")" = "apt" ]
  [ "$(sed -n '3p' "${action_log}")" = "validate" ]
  [[ "${output}" == *"cannot be automatically downgraded"* ]]
  [[ "${output}" == *"provider snapshot"*"full rollback"* ]]
}
