#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats test cases run in isolated subshells.

load test_helper

setup() {
  make_temp_dir
  mkdir -p "${TEST_TMPDIR}/bin"
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
  load_system
}

teardown() {
  remove_temp_dir
}

install_root_stat_mock() {
  cat > "${TEST_TMPDIR}/bin/stat" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-c" && "$2" == "%u" ]] || exit 1
printf '0\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/stat"
}

write_fail2ban_state() {
  local active="$4"
  local enabled="$3"
  local installed_by_bundle="$2"
  local masked="$5"
  local state_dir="$1"

  mkdir -p "${state_dir}"
  printf '1\n' > "${state_dir}/state-version"
  printf '%s\n' "${installed_by_bundle}" > "${state_dir}/package-installed-by-bundle"
  printf '%s\n' "${enabled}" > "${state_dir}/service-was-enabled"
  printf '%s\n' "${active}" > "${state_dir}/service-was-active"
  printf '%s\n' "${masked}" > "${state_dir}/service-was-masked"
}

@test "Fail2ban renderer installs the balanced marker-owned all-ports jail" {
  local jail_config="${TEST_TMPDIR}/jail.d/60-vpsfiles.local"

  load_system_install
  vps_system_install_rendered_file \
    "${jail_config}" 644 vps_system_render_fail2ban_jail

  [ "$(stat -c '%a' "${jail_config}")" = "644" ]
  assert_file_contains "${jail_config}" "${VPS_SYSTEM_MANAGED_MARKER}"
  assert_file_contains "${jail_config}" "[sshd]"
  assert_file_contains "${jail_config}" "enabled = true"
  assert_file_contains "${jail_config}" "backend = systemd"
  assert_file_contains "${jail_config}" "bantime = 1h"
  assert_file_contains "${jail_config}" "findtime = 10m"
  assert_file_contains "${jail_config}" "maxretry = 5"
  assert_file_contains "${jail_config}" 'banaction = %(banaction_allports)s'
}

@test "Fail2ban managed path rejects an unowned file and a symlink" {
  local jail_config="${TEST_TMPDIR}/60-vpsfiles.local"
  local jail_symlink="${TEST_TMPDIR}/60-vpsfiles-link.local"

  printf '[sshd]\nenabled = false\n' > "${jail_config}"
  ln -s "${jail_config}" "${jail_symlink}"

  run vps_system_require_managed_or_absent "${jail_config}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not owned by system-scripts"* ]]

  run vps_system_require_managed_or_absent "${jail_symlink}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing to replace symlink"* ]]
}

@test "fresh Fail2ban state records a masked inactive baseline once" {
  local state_dir="${TEST_TMPDIR}/state/fail2ban"

  install_root_stat_mock
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet fail2ban.service") exit 1 ;;
  "is-enabled fail2ban.service") printf 'masked\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" "${TEST_TMPDIR}/bin/systemctl"

  vps_system_initialize_fail2ban_state "${state_dir}"
  [ "$(cat "${state_dir}/package-installed-by-bundle")" = "1" ]
  [ "$(cat "${state_dir}/service-was-enabled")" = "0" ]
  [ "$(cat "${state_dir}/service-was-active")" = "0" ]
  [ "$(cat "${state_dir}/service-was-masked")" = "1" ]

  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet fail2ban.service") exit 0 ;;
  "is-enabled fail2ban.service") printf 'enabled\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" "${TEST_TMPDIR}/bin/systemctl"

  vps_system_initialize_fail2ban_state "${state_dir}"
  [ "$(cat "${state_dir}/package-installed-by-bundle")" = "1" ]
  [ "$(cat "${state_dir}/service-was-active")" = "0" ]
  [ "$(cat "${state_dir}/service-was-masked")" = "1" ]
}

@test "preinstalled Fail2ban state records its enabled active baseline" {
  local state_dir="${TEST_TMPDIR}/state/fail2ban"

  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet fail2ban.service") exit 0 ;;
  "is-enabled fail2ban.service") printf 'enabled\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" "${TEST_TMPDIR}/bin/systemctl"

  vps_system_initialize_fail2ban_state "${state_dir}"
  [ "$(cat "${state_dir}/package-installed-by-bundle")" = "0" ]
  [ "$(cat "${state_dir}/service-was-enabled")" = "1" ]
  [ "$(cat "${state_dir}/service-was-active")" = "1" ]
  [ "$(cat "${state_dir}/service-was-masked")" = "0" ]
}

@test "Fail2ban state validation rejects invalid state and symlinks" {
  local state_dir="${TEST_TMPDIR}/state/fail2ban"
  local state_symlink="${TEST_TMPDIR}/state/fail2ban-link"

  install_root_stat_mock
  write_fail2ban_state "${state_dir}" 0 1 0 0
  run vps_system_validate_fail2ban_state "${state_dir}"
  [ "${status}" -eq 0 ]

  printf '2\n' > "${state_dir}/service-was-active"
  run vps_system_validate_fail2ban_state "${state_dir}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"state is invalid"* ]]

  ln -s "${state_dir}" "${state_symlink}"
  run vps_system_validate_fail2ban_state "${state_symlink}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not a safe directory"* ]]
}

@test "Fail2ban activation validates daemon jail and effective thresholds" {
  local client_log="${TEST_TMPDIR}/fail2ban-client.log"
  local systemctl_log="${TEST_TMPDIR}/systemctl.log"
  export TEST_CLIENT_LOG="${client_log}"
  export TEST_SYSTEMCTL_LOG="${systemctl_log}"

  cat > "${TEST_TMPDIR}/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_CLIENT_LOG}"
case "$*" in
  "get sshd bantime") printf '3600\n' ;;
  "get sshd findtime") printf '600\n' ;;
  "get sshd maxretry") printf '5\n' ;;
esac
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SYSTEMCTL_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/fail2ban-client" "${TEST_TMPDIR}/bin/systemctl"

  run vps_system_activate_fail2ban
  [ "${status}" -eq 0 ]
  assert_file_contains "${client_log}" "-t"
  assert_file_contains "${client_log}" "ping"
  assert_file_contains "${client_log}" "status sshd"
  assert_file_contains "${client_log}" "get sshd bantime"
  assert_file_contains "${client_log}" "get sshd findtime"
  assert_file_contains "${client_log}" "get sshd maxretry"
  assert_file_contains "${systemctl_log}" "unmask fail2ban.service"
  assert_file_contains "${systemctl_log}" "enable fail2ban.service"
  assert_file_contains "${systemctl_log}" "restart fail2ban.service"
  assert_file_contains "${systemctl_log}" "is-active --quiet fail2ban.service"
}

@test "Fail2ban activation waits for its daemon socket" {
  local ping_count="${TEST_TMPDIR}/ping-count"
  local sleep_log="${TEST_TMPDIR}/sleep.log"
  export TEST_PING_COUNT="${ping_count}"
  export TEST_SLEEP_LOG="${sleep_log}"

  cat > "${TEST_TMPDIR}/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  ping)
    count=0
    [[ ! -e "${TEST_PING_COUNT}" ]] || count="$(cat "${TEST_PING_COUNT}")"
    count="$(( count + 1 ))"
    printf '%s\n' "${count}" > "${TEST_PING_COUNT}"
    (( count >= 3 ))
    ;;
  "get sshd bantime") printf '3600\n' ;;
  "get sshd findtime") printf '600\n' ;;
  "get sshd maxretry") printf '5\n' ;;
esac
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SLEEP_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/fail2ban-client" \
    "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/sleep"

  run vps_system_activate_fail2ban
  [ "${status}" -eq 0 ]
  [ "$(cat "${ping_count}")" = "3" ]
  [ "$(wc -l < "${sleep_log}")" -eq 2 ]
}

@test "Fail2ban activation reports each validation and health failure" {
  local expected=""
  local phase=""
  export TEST_FAIL_PHASE=""

  cat > "${TEST_TMPDIR}/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  -t) [[ "${TEST_FAIL_PHASE}" != "config" ]] ;;
  ping) [[ "${TEST_FAIL_PHASE}" != "ping" ]] ;;
  "status sshd") [[ "${TEST_FAIL_PHASE}" != "jail" ]] ;;
  "get sshd bantime") printf '3600\n' ;;
  "get sshd findtime") printf '600\n' ;;
  "get sshd maxretry")
    if [[ "${TEST_FAIL_PHASE}" == "threshold" ]]; then
      printf '6\n'
    else
      printf '5\n'
    fi
    ;;
esac
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "restart fail2ban.service" && "${TEST_FAIL_PHASE}" == "start" ]]; then
  exit 1
fi
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/fail2ban-client" \
    "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/sleep"

  for phase in config start ping jail threshold; do
    case "${phase}" in
      config) expected="configuration validation failed" ;;
      start) expected="could not be started" ;;
      ping) expected="daemon socket did not become ready" ;;
      jail) expected="sshd jail is not active" ;;
      threshold) expected="effective Fail2ban maxretry is 6, expected 5" ;;
    esac
    export TEST_FAIL_PHASE="${phase}"
    run vps_system_activate_fail2ban
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"${expected}"* ]]
  done
}

@test "system installer records Fail2ban state before installing required packages" {
  local lifecycle_log="${TEST_TMPDIR}/lifecycle.log"
  export TEST_LIFECYCLE_LOG="${lifecycle_log}"
  export VPS_SYSTEM_STATE_DIR="${TEST_TMPDIR}/state"
  export VPS_FAIL2BAN_STATE_DIR="${VPS_SYSTEM_STATE_DIR}/fail2ban"
  export VPS_FAIL2BAN_JAIL_CONFIG="${TEST_TMPDIR}/etc/fail2ban/60-vpsfiles.local"
  export VPS_MAINTENANCE_BIN="/bin/true"
  export VPS_AUTO_UPDATE_STATE_DIR="${VPS_SYSTEM_STATE_DIR}/auto-updates"
  load_system_install

  vps_require_root() { return 0; }
  vps_require_supported_apt_os() { return 0; }
  vps_require_systemd() { return 0; }
  vps_require_commands() { return 0; }
  vps_system_validate_paths() { return 0; }
  vps_system_detect_memory_mib() { printf '1024\n'; }
  vps_system_detect_filesystem_mib() { printf '10240\n'; }
  vps_confirm() { return 0; }
  vps_system_is_ubuntu() { return 1; }
  vps_system_initialize_state() { printf 'system-state\n' >> "${TEST_LIFECYCLE_LOG}"; }
  vps_system_initialize_fail2ban_state() {
    printf 'fail2ban-state:%s\n' "$1" >> "${TEST_LIFECYCLE_LOG}"
  }
  vps_install_packages() { printf 'packages:%s\n' "$*" >> "${TEST_LIFECYCLE_LOG}"; }
  vps_system_install_rendered_file() {
    printf 'rendered:%s:%s:%s\n' "$1" "$2" "$3" >> "${TEST_LIFECYCLE_LOG}"
  }
  vps_system_activate_fail2ban() { printf 'fail2ban-active\n' >> "${TEST_LIFECYCLE_LOG}"; }
  vps_system_configure_zram() { return 0; }
  install() { return 0; }
  systemd-analyze() { return 0; }
  systemctl() {
    if [[ "$*" == "list-timers vpsfiles-maintenance.timer --no-pager" ]]; then
      printf 'timer listed\n'
    fi
    return 0
  }
  journalctl() { return 0; }

  run vps_system_main
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${lifecycle_log}")" = "system-state" ]
  [ "$(sed -n '2p' "${lifecycle_log}")" = "fail2ban-state:${VPS_FAIL2BAN_STATE_DIR}" ]
  [ "$(sed -n '3p' "${lifecycle_log}")" = "packages:kmod logrotate util-linux fail2ban python3-systemd" ]
  assert_file_contains "${lifecycle_log}" "fail2ban-active"
  assert_file_contains "${lifecycle_log}" \
    "rendered:${VPS_FAIL2BAN_JAIL_CONFIG}:644:vps_system_render_fail2ban_jail"
  [[ "${output}" == *"enable Fail2ban SSH protection with all-ports bans"* ]]
}

@test "Fail2ban uninstall removes only a bundle-attributed package" {
  local apt_log="${TEST_TMPDIR}/apt.log"
  local jail_config="${TEST_TMPDIR}/jail.d/60-vpsfiles.local"
  local state_dir="${TEST_TMPDIR}/state/fail2ban"
  export TEST_APT_LOG="${apt_log}"

  install_root_stat_mock
  mkdir -p "$(dirname "${jail_config}")"
  printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${jail_config}"
  write_fail2ban_state "${state_dir}" 1 0 0 0
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_APT_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" "${TEST_TMPDIR}/bin/apt-get"

  run vps_system_uninstall_fail2ban "${jail_config}" "${state_dir}"
  [ "${status}" -eq 0 ]
  [ ! -e "${jail_config}" ]
  [ ! -e "${state_dir}" ]
  [ "$(cat "${apt_log}")" = "remove -y fail2ban" ]
  assert_file_not_contains "${apt_log}" "autoremove"
  assert_file_not_contains "${apt_log}" "python3-systemd"
}

@test "Fail2ban uninstall restores a pre-existing masked inactive service" {
  local client_log="${TEST_TMPDIR}/client.log"
  local jail_config="${TEST_TMPDIR}/jail.d/60-vpsfiles.local"
  local state_dir="${TEST_TMPDIR}/state/fail2ban"
  local systemctl_log="${TEST_TMPDIR}/systemctl.log"
  export TEST_CLIENT_LOG="${client_log}"
  export TEST_SYSTEMCTL_LOG="${systemctl_log}"

  install_root_stat_mock
  mkdir -p "$(dirname "${jail_config}")"
  printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${jail_config}"
  write_fail2ban_state "${state_dir}" 0 0 0 1
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_CLIENT_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SYSTEMCTL_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" \
    "${TEST_TMPDIR}/bin/fail2ban-client" "${TEST_TMPDIR}/bin/systemctl"

  run vps_system_uninstall_fail2ban "${jail_config}" "${state_dir}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${client_log}")" = "-t" ]
  grep -qxF "unmask fail2ban.service" "${systemctl_log}"
  grep -qxF "disable fail2ban.service" "${systemctl_log}"
  grep -qxF "stop fail2ban.service" "${systemctl_log}"
  grep -qxF "mask fail2ban.service" "${systemctl_log}"
  [ ! -e "${state_dir}" ]
}

@test "Fail2ban uninstall restores a pre-existing enabled active service" {
  local jail_config="${TEST_TMPDIR}/jail.d/60-vpsfiles.local"
  local state_dir="${TEST_TMPDIR}/state/fail2ban"
  local systemctl_log="${TEST_TMPDIR}/systemctl.log"
  export TEST_SYSTEMCTL_LOG="${systemctl_log}"

  install_root_stat_mock
  mkdir -p "$(dirname "${jail_config}")"
  printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${jail_config}"
  write_fail2ban_state "${state_dir}" 0 1 1 0
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_SYSTEMCTL_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/dpkg-query" \
    "${TEST_TMPDIR}/bin/fail2ban-client" "${TEST_TMPDIR}/bin/systemctl"

  run vps_system_uninstall_fail2ban "${jail_config}" "${state_dir}"
  [ "${status}" -eq 0 ]
  grep -qxF "enable fail2ban.service" "${systemctl_log}"
  grep -qxF "restart fail2ban.service" "${systemctl_log}"
  run grep -qxF "disable fail2ban.service" "${systemctl_log}"
  [ "${status}" -ne 0 ]
  run grep -qxF "stop fail2ban.service" "${systemctl_log}"
  [ "${status}" -ne 0 ]
  run grep -qxF "mask fail2ban.service" "${systemctl_log}"
  [ "${status}" -ne 0 ]
}

@test "legacy Fail2ban uninstall removes only the owned jail" {
  local jail_config="${TEST_TMPDIR}/jail.d/60-vpsfiles.local"
  local state_dir="${TEST_TMPDIR}/missing-state/fail2ban"

  mkdir -p "$(dirname "${jail_config}")"
  printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${jail_config}"

  run vps_system_uninstall_fail2ban "${jail_config}" "${state_dir}"
  [ "${status}" -eq 0 ]
  [ ! -e "${jail_config}" ]
  [[ "${output}" == *"package and service were left unchanged"* ]]
}
