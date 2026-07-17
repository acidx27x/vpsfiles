#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats test cases run in isolated subshells.

load test_helper

setup() {
  make_temp_dir
  mkdir -p "${TEST_TMPDIR}/bin"
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
  export VPS_MAINTENANCE_LOCK_FILE="${TEST_TMPDIR}/run/maintenance.lock"
  export VPS_APT_CACHE_DIR="${TEST_TMPDIR}/apt-cache"
  export VPS_COREDUMP_DIR="${TEST_TMPDIR}/coredump"
  export VPS_MAINTENANCE_FILESYSTEM="${TEST_TMPDIR}"
  load_system
}

teardown() {
  remove_temp_dir
}

@test "system limits scale and clamp for mixed VPS sizes" {
  [ "$(vps_system_journal_limit_mib 5120)" = "64" ]
  [ "$(vps_system_journal_limit_mib 10240)" = "102" ]
  [ "$(vps_system_journal_limit_mib 102400)" = "256" ]

  [ "$(vps_system_runtime_journal_limit_mib 256)" = "16" ]
  [ "$(vps_system_runtime_journal_limit_mib 1024)" = "40" ]
  [ "$(vps_system_runtime_journal_limit_mib 4096)" = "64" ]

  [ "$(vps_system_keep_free_mib 5120)" = "256" ]
  [ "$(vps_system_keep_free_mib 10240)" = "512" ]
  [ "$(vps_system_keep_free_mib 102400)" = "1024" ]

  [ "$(vps_system_coredump_limit_mib 5120)" = "32" ]
  [ "$(vps_system_coredump_limit_mib 10240)" = "51" ]
  [ "$(vps_system_coredump_limit_mib 102400)" = "128" ]
}

@test "system configuration renderers apply bounded policies" {
  local journal_config="${TEST_TMPDIR}/journald.conf"
  local coredump_config="${TEST_TMPDIR}/coredump.conf"
  local zram_config="${TEST_TMPDIR}/zram.conf"

  vps_system_render_journald_config 100 40 512 > "${journal_config}"
  vps_system_render_coredump_config 50 512 > "${coredump_config}"
  vps_system_render_zram_config > "${zram_config}"

  assert_file_contains "${journal_config}" "SystemMaxUse=100M"
  assert_file_contains "${journal_config}" "RuntimeMaxUse=40M"
  assert_file_contains "${journal_config}" "SystemKeepFree=512M"
  assert_file_contains "${journal_config}" "MaxRetentionSec=7day"
  assert_file_contains "${coredump_config}" "ProcessSizeMax=50M"
  assert_file_contains "${coredump_config}" "ExternalSizeMax=50M"
  assert_file_contains "${coredump_config}" "MaxUse=50M"
  assert_file_contains "${zram_config}" "zram-size = min(ram / 2, 1024)"
  assert_file_contains "${zram_config}" "swap-priority = 100"
}

@test "system units schedule low-priority persistent daily cleanup" {
  local service="${TEST_TMPDIR}/maintenance.service"
  local timer="${TEST_TMPDIR}/maintenance.timer"

  vps_system_render_maintenance_service /usr/local/sbin/vpsfiles-maintenance > "${service}"
  vps_system_render_maintenance_timer > "${timer}"

  assert_file_contains "${service}" "ExecStart=/usr/local/sbin/vpsfiles-maintenance --scheduled"
  assert_file_contains "${service}" "Nice=10"
  assert_file_contains "${service}" "IOSchedulingClass=idle"
  assert_file_contains "${timer}" "OnCalendar=daily"
  assert_file_contains "${timer}" "RandomizedDelaySec=1h"
  assert_file_contains "${timer}" "Persistent=true"
}

@test "system ownership check accepts managed files and rejects other files and symlinks" {
  local managed="${TEST_TMPDIR}/managed.conf"
  local unrelated="${TEST_TMPDIR}/unrelated.conf"
  local symlink="${TEST_TMPDIR}/link.conf"

  printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${managed}"
  printf 'administrator config\n' > "${unrelated}"
  ln -s "${managed}" "${symlink}"

  run vps_system_require_managed_or_absent "${managed}"
  [ "${status}" -eq 0 ]

  run vps_system_require_managed_or_absent "${unrelated}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not owned"* ]]

  run vps_system_require_managed_or_absent "${symlink}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refusing to replace symlink"* ]]
}

@test "maintenance dry run does not execute cleanup commands" {
  local action_log="${TEST_TMPDIR}/actions.log"

  export TEST_DRY_ACTION_LOG="${action_log}"
  cat > "${TEST_TMPDIR}/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--disk-usage" ]]; then
  printf 'Archived and active journals take up 1M.\n'
else
  printf 'journalctl %s\n' "$*" >> "${TEST_DRY_ACTION_LOG}"
fi
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_DRY_ACTION_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-tmpfiles %s\n' "$*" >> "${TEST_DRY_ACTION_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  load_maintenance
  # shellcheck disable=SC2317 # Invoked indirectly by vps_maintenance_main.
  vps_maintenance_require_root() {
    return 0
  }

  run vps_maintenance_main --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Dry run complete"* ]]
  [ ! -e "${action_log}" ]
  [ ! -e "${VPS_MAINTENANCE_LOCK_FILE}" ]
}

@test "scheduled maintenance performs only bounded cleanup commands" {
  local action_log="${TEST_TMPDIR}/actions.log"

  export TEST_SCHEDULED_ACTION_LOG="${action_log}"
  cat > "${TEST_TMPDIR}/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" != "--disk-usage" ]]; then
  printf 'journalctl %s\n' "$*" >> "${TEST_SCHEDULED_ACTION_LOG}"
fi
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${TEST_SCHEDULED_ACTION_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-tmpfiles %s\n' "$*" >> "${TEST_SCHEDULED_ACTION_LOG}"
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  load_maintenance
  # shellcheck disable=SC2317 # Invoked indirectly by vps_maintenance_main.
  vps_maintenance_require_root() {
    return 0
  }

  run vps_maintenance_main --scheduled
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${action_log}")" = "journalctl --rotate" ]
  [ "$(sed -n '2p' "${action_log}")" = "journalctl --vacuum-time=7d" ]
  [ "$(sed -n '3p' "${action_log}")" = "apt-get clean" ]
  [ "$(sed -n '4p' "${action_log}")" = "systemd-tmpfiles --clean" ]
  [ "$(wc -l < "${action_log}")" -eq 4 ]
}

@test "system updater safely upgrades without package removal" {
  local apt_log="${TEST_TMPDIR}/apt.log"

  export TEST_APT_LOG="${apt_log}"
  cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_APT_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/apt-mark" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "showhold" ]] || exit 1
printf 'held-example\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  load_system_update
  # shellcheck disable=SC2317 # Invoked indirectly by vps_system_update_main.
  vps_system_update_require_root() {
    return 0
  }
  # shellcheck disable=SC2317 # Invoked indirectly by vps_system_update_main.
  vps_confirm() {
    return 0
  }

  run vps_system_update_main
  [ "${status}" -eq 0 ]
  [ "$(sed -n '1p' "${apt_log}")" = "update" ]
  [ "$(sed -n '2p' "${apt_log}")" = "upgrade -y --with-new-pkgs" ]
  [ "$(sed -n '3p' "${apt_log}")" = "clean" ]
  [ "$(wc -l < "${apt_log}")" -eq 3 ]
  [[ "${output}" == *"held-example"* ]]
}

@test "existing zram configuration is detected without modifying it" {
  export VPS_ZRAM_DEVICE_PATH="${TEST_TMPDIR}/sys/block/zram0"
  export VPS_ZRAM_MAIN_CONFIG="${TEST_TMPDIR}/etc/zram-generator.conf"
  export VPS_ZRAM_CONFIG_DIR="${TEST_TMPDIR}/etc/zram-generator.conf.d"
  export VPS_ZRAM_CONFIG="${VPS_ZRAM_CONFIG_DIR}/60-vpsfiles.conf"
  mkdir -p "${VPS_ZRAM_CONFIG_DIR}"
  printf '[zram0]\n' > "${VPS_ZRAM_MAIN_CONFIG}"
  load_system_install

  run vps_system_has_other_zram_configuration
  [ "${status}" -eq 0 ]
}

@test "installer state preserves the original service and package baseline across reruns" {
  export VPS_SYSTEM_STATE_DIR="${TEST_TMPDIR}/state"
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-enabled --quiet logrotate.timer") exit 0 ;;
  "is-active --quiet logrotate.timer") exit 1 ;;
  *) exit 1 ;;
esac
EOF
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  load_system_install

  vps_system_initialize_state
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/logrotate-was-enabled")" = "1" ]
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/logrotate-was-active")" = "0" ]
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/zram-package-was-installed")" = "0" ]
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/zram-package-installed-by-bundle")" = "0" ]

  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*

  vps_system_initialize_state
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/logrotate-was-enabled")" = "1" ]
  [ "$(cat "${VPS_SYSTEM_STATE_DIR}/zram-package-was-installed")" = "0" ]
}

@test "uninstall removes owned setup and restores recorded host state" {
  local apt_log="${TEST_TMPDIR}/uninstall-apt.log"
  local systemctl_log="${TEST_TMPDIR}/uninstall-systemctl.log"
  local path=""

  export VPS_JOURNALD_CONFIG="${TEST_TMPDIR}/etc/journald.conf"
  export VPS_COREDUMP_CONFIG="${TEST_TMPDIR}/etc/coredump.conf"
  export VPS_ZRAM_CONFIG="${TEST_TMPDIR}/etc/zram.conf"
  export VPS_MAINTENANCE_BIN="${TEST_TMPDIR}/usr/vpsfiles-maintenance"
  export VPS_MAINTENANCE_SERVICE="${TEST_TMPDIR}/etc/vpsfiles-maintenance.service"
  export VPS_MAINTENANCE_TIMER="${TEST_TMPDIR}/etc/vpsfiles-maintenance.timer"
  export VPS_SYSTEM_STATE_DIR="${TEST_TMPDIR}/state"
  export TEST_UNINSTALL_APT_LOG="${apt_log}"
  export TEST_UNINSTALL_SYSTEMCTL_LOG="${systemctl_log}"

  mkdir -p "${TEST_TMPDIR}/etc" "${TEST_TMPDIR}/usr" "${VPS_SYSTEM_STATE_DIR}"
  for path in \
    "${VPS_JOURNALD_CONFIG}" \
    "${VPS_COREDUMP_CONFIG}" \
    "${VPS_ZRAM_CONFIG}" \
    "${VPS_MAINTENANCE_BIN}" \
    "${VPS_MAINTENANCE_SERVICE}" \
    "${VPS_MAINTENANCE_TIMER}"; do
    printf '%s\n' "${VPS_SYSTEM_MANAGED_MARKER}" > "${path}"
  done
  printf '1\n' > "${VPS_SYSTEM_STATE_DIR}/state-version"
  printf '0\n' > "${VPS_SYSTEM_STATE_DIR}/logrotate-was-enabled"
  printf '1\n' > "${VPS_SYSTEM_STATE_DIR}/logrotate-was-active"
  printf '0\n' > "${VPS_SYSTEM_STATE_DIR}/zram-package-was-installed"
  printf '1\n' > "${VPS_SYSTEM_STATE_DIR}/zram-package-installed-by-bundle"

  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_UNINSTALL_SYSTEMCTL_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_UNINSTALL_APT_LOG}"
EOF
  cat > "${TEST_TMPDIR}/bin/swapon" <<'EOF'
#!/usr/bin/env bash
printf '/dev/zram0\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/"*
  load_system_uninstall
  # shellcheck disable=SC2317 # Invoked indirectly by vps_system_uninstall_main.
  vps_require_root() {
    return 0
  }
  # shellcheck disable=SC2317 # Invoked indirectly by vps_system_uninstall_main.
  vps_confirm() {
    return 0
  }
  # shellcheck disable=SC2317 # Test state is owned by the unprivileged test process.
  vps_system_validate_state_dir() {
    return 0
  }

  run vps_system_uninstall_main
  [ "${status}" -eq 0 ]
  for path in \
    "${VPS_JOURNALD_CONFIG}" \
    "${VPS_COREDUMP_CONFIG}" \
    "${VPS_ZRAM_CONFIG}" \
    "${VPS_MAINTENANCE_BIN}" \
    "${VPS_MAINTENANCE_SERVICE}" \
    "${VPS_MAINTENANCE_TIMER}" \
    "${VPS_SYSTEM_STATE_DIR}"; do
    [ ! -e "${path}" ]
  done
  [ "$(cat "${apt_log}")" = "remove -y systemd-zram-generator" ]
  assert_file_contains "${systemctl_log}" "disable --now vpsfiles-maintenance.timer"
  assert_file_contains "${systemctl_log}" "restart systemd-journald"
  assert_file_contains "${systemctl_log}" "disable logrotate.timer"
  assert_file_contains "${systemctl_log}" "start logrotate.timer"
  [[ "${output}" == *"Reboot the VPS"* ]]
  [[ "${output}" == *"kmod, logrotate, and util-linux were retained"* ]]
}

@test "system public commands reject non-root execution" {
  run bash "${REPO_ROOT}/system-scripts/install.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]

  run bash "${REPO_ROOT}/system-scripts/cleanup.sh" --dry-run
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]

  run bash "${REPO_ROOT}/system-scripts/update.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]

  run bash "${REPO_ROOT}/system-scripts/uninstall.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"run as root"* ]]
}
