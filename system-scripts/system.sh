#!/usr/bin/env bash

[[ -n "${VPS_SYSTEM_SH:-}" ]] && return 0
VPS_SYSTEM_SH=1

VPS_SYSTEM_MANAGED_MARKER="# Managed by vpsfiles system-scripts."
VPS_SYSTEM_FAIL2BAN_SERVICE="fail2ban.service"
VPS_SYSTEM_FAIL2BAN_JAIL="sshd"
VPS_SYSTEM_AUTO_UPDATE_UNITS=(
  unattended-upgrades.service
  apt-daily.service
  apt-daily-upgrade.service
  apt-daily.timer
  apt-daily-upgrade.timer
)

vps_system_clamp_mib() {
  local value="$1"
  local minimum="$2"
  local maximum="$3"

  vps_validate_non_negative_int "value" "${value}"
  vps_validate_non_negative_int "minimum" "${minimum}"
  vps_validate_non_negative_int "maximum" "${maximum}"
  (( minimum <= maximum )) || vps_die "minimum must not exceed maximum"

  if (( value < minimum )); then
    printf '%s\n' "${minimum}"
  elif (( value > maximum )); then
    printf '%s\n' "${maximum}"
  else
    printf '%s\n' "${value}"
  fi
}

vps_system_journal_limit_mib() {
  local filesystem_mib="$1"

  vps_validate_positive_int "filesystem size" "${filesystem_mib}"
  vps_system_clamp_mib "$(( filesystem_mib / 100 ))" 64 256
}

vps_system_runtime_journal_limit_mib() {
  local memory_mib="$1"

  vps_validate_positive_int "memory size" "${memory_mib}"
  vps_system_clamp_mib "$(( memory_mib / 25 ))" 16 64
}

vps_system_keep_free_mib() {
  local filesystem_mib="$1"

  vps_validate_positive_int "filesystem size" "${filesystem_mib}"
  vps_system_clamp_mib "$(( filesystem_mib / 20 ))" 256 1024
}

vps_system_coredump_limit_mib() {
  local filesystem_mib="$1"

  vps_validate_positive_int "filesystem size" "${filesystem_mib}"
  vps_system_clamp_mib "$(( filesystem_mib / 200 ))" 32 128
}

vps_system_render_journald_config() {
  local journal_limit_mib="$1"
  local runtime_limit_mib="$2"
  local keep_free_mib="$3"

  vps_validate_positive_int "journal limit" "${journal_limit_mib}"
  vps_validate_positive_int "runtime journal limit" "${runtime_limit_mib}"
  vps_validate_positive_int "journal free-space reserve" "${keep_free_mib}"
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[Journal]' \
    'Compress=yes' \
    "SystemMaxUse=${journal_limit_mib}M" \
    "SystemKeepFree=${keep_free_mib}M" \
    "RuntimeMaxUse=${runtime_limit_mib}M" \
    'MaxRetentionSec=7day'
}

vps_system_render_coredump_config() {
  local coredump_limit_mib="$1"
  local keep_free_mib="$2"

  vps_validate_positive_int "coredump limit" "${coredump_limit_mib}"
  vps_validate_positive_int "coredump free-space reserve" "${keep_free_mib}"
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[Coredump]' \
    'Storage=external' \
    'Compress=yes' \
    "ProcessSizeMax=${coredump_limit_mib}M" \
    "ExternalSizeMax=${coredump_limit_mib}M" \
    "MaxUse=${coredump_limit_mib}M" \
    "KeepFree=${keep_free_mib}M"
}

vps_system_render_zram_config() {
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[zram0]' \
    'zram-size = min(ram / 2, 1024)' \
    'swap-priority = 100' \
    'fs-type = swap'
}

vps_system_render_apt_periodic_config() {
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    'APT::Periodic::Enable "0";' \
    'APT::Periodic::Update-Package-Lists "0";' \
    'APT::Periodic::Unattended-Upgrade "0";'
}

vps_system_render_fail2ban_jail() {
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[sshd]' \
    'enabled = true' \
    'backend = systemd' \
    'bantime = 1h' \
    'findtime = 10m' \
    'maxretry = 5' \
    'banaction = %(banaction_allports)s'
}

vps_system_is_ubuntu() {
  local key=""
  local os_release="${VPS_OS_RELEASE:-/etc/os-release}"
  local value=""

  [[ -r "${os_release}" ]] || return 1
  while IFS='=' read -r key value; do
    [[ "${key}" == "ID" ]] || continue
    value="${value#\"}"
    value="${value%\"}"
    [[ "${value}" == "ubuntu" ]]
    return
  done < "${os_release}"
  return 1
}

vps_system_detect_kernel_meta_packages() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\t${source:Package}\n' 2>/dev/null \
    | awk -F '\t' '
        $2 == "ii " &&
        $3 ~ /^linux-meta/ &&
        $1 ~ /^linux-/ &&
        $1 !~ /^linux-(cloud-)?tools-/ { print $1 }
      ' \
    | sort -u
}

vps_system_validate_kernel_package_name() {
  local package="$1"

  [[ "${package}" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] \
    || vps_die "invalid kernel package name in system-scripts state: ${package}"
}

vps_system_validate_auto_update_state() {
  local package=""
  local state_dir="$1"
  local unit=""
  local unit_state_dir=""

  [[ "${state_dir}" == /* && "${state_dir}" != "/" ]] \
    || vps_die "automatic-update state directory is unsafe: ${state_dir}"
  [[ -e "${state_dir}" ]] || return 0
  [[ -d "${state_dir}" && ! -L "${state_dir}" ]] \
    || vps_die "automatic-update state is not a safe directory: ${state_dir}"
  [[ "$(stat -c '%u' "${state_dir}")" == "0" ]] \
    || vps_die "automatic-update state directory must be owned by root"
  [[ -f "${state_dir}/state-version" && ! -L "${state_dir}/state-version" \
    && "$(<"${state_dir}/state-version")" == "1" ]] \
    || vps_die "automatic-update state is incomplete or incompatible"
  [[ -f "${state_dir}/kernel-holds-added" && ! -L "${state_dir}/kernel-holds-added" ]] \
    || vps_die "automatic-update kernel hold state is missing or unsafe"
  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    vps_system_validate_kernel_package_name "${package}"
  done < "${state_dir}/kernel-holds-added"
  for unit in "${VPS_SYSTEM_AUTO_UPDATE_UNITS[@]}"; do
    unit_state_dir="${state_dir}/units/${unit}"
    [[ -d "${unit_state_dir}" && ! -L "${unit_state_dir}" ]] \
      || vps_die "automatic-update unit state is missing or unsafe: ${unit}"
    vps_system_read_binary_state "${unit_state_dir}/was-masked" >/dev/null
    vps_system_read_binary_state "${unit_state_dir}/was-active" >/dev/null
  done
}

vps_system_record_added_kernel_hold() {
  local holds_file="$1"
  local package="$2"
  local temporary_file=""

  vps_system_validate_kernel_package_name "${package}"
  grep -qxF -- "${package}" "${holds_file}" && return 0
  temporary_file="$(mktemp "$(dirname "${holds_file}")/.kernel-holds.XXXXXX")"
  if ! { cat "${holds_file}"; printf '%s\n' "${package}"; } > "${temporary_file}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
  chmod 600 "${temporary_file}"
  mv -f -- "${temporary_file}" "${holds_file}"
}

vps_system_render_maintenance_service() {
  local maintenance_bin="$1"

  [[ "${maintenance_bin}" == /* && "${maintenance_bin}" != "/" ]] \
    || vps_die "maintenance executable path must be absolute and safe"
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[Unit]' \
    'Description=Bounded VPS housekeeping' \
    'After=apt-daily.service apt-daily-upgrade.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    "ExecStart=${maintenance_bin} --scheduled" \
    'Nice=10' \
    'IOSchedulingClass=idle' \
    'TimeoutStartSec=30min'
}

vps_system_render_maintenance_timer() {
  printf '%s\n' \
    "${VPS_SYSTEM_MANAGED_MARKER}" \
    '[Unit]' \
    'Description=Run bounded VPS housekeeping daily' \
    '' \
    '[Timer]' \
    'OnCalendar=daily' \
    'RandomizedDelaySec=1h' \
    'AccuracySec=15m' \
    'Persistent=true' \
    '' \
    '[Install]' \
    'WantedBy=timers.target'
}

vps_system_is_managed_file() {
  local path="$1"

  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  grep -qF -- "${VPS_SYSTEM_MANAGED_MARKER}" "${path}"
}

vps_system_require_managed_or_absent() {
  local path="$1"

  if [[ -L "${path}" ]]; then
    vps_die "refusing to replace symlink at managed path: ${path}"
  fi
  if [[ -e "${path}" ]] && ! vps_system_is_managed_file "${path}"; then
    vps_die "refusing to replace file not owned by system-scripts: ${path}"
  fi
}

vps_system_package_is_installed() {
  local package="$1"

  dpkg-query -W -f='${Status}\n' "${package}" 2>/dev/null \
    | grep -qxF 'install ok installed'
}

vps_system_read_binary_state() {
  local path="$1"
  local value=""

  [[ -f "${path}" && ! -L "${path}" ]] || vps_die "system-scripts state is missing or unsafe: ${path}"
  value="$(<"${path}")"
  [[ "${value}" == "0" || "${value}" == "1" ]] \
    || vps_die "system-scripts state is invalid: ${path}"
  printf '%s\n' "${value}"
}

vps_system_write_binary_state() {
  local path="$1"
  local value="$2"
  local temporary_file=""

  [[ "${path}" == /* && "${path}" != "/" ]] || vps_die "system-scripts state path is unsafe: ${path}"
  [[ "${value}" == "0" || "${value}" == "1" ]] || vps_die "system-scripts state value must be 0 or 1"
  [[ -d "$(dirname "${path}")" ]] || vps_die "system-scripts state directory is missing"

  temporary_file="$(mktemp "$(dirname "${path}")/.state.XXXXXX")"
  printf '%s\n' "${value}" > "${temporary_file}"
  chmod 600 "${temporary_file}"
  mv -f -- "${temporary_file}" "${path}"
}

vps_system_validate_fail2ban_state() {
  local state_dir="$1"

  [[ "${state_dir}" == /* && "${state_dir}" != "/" ]] \
    || vps_die "Fail2ban state directory is unsafe: ${state_dir}"
  [[ -e "${state_dir}" || -L "${state_dir}" ]] || return 0
  [[ -d "${state_dir}" && ! -L "${state_dir}" ]] \
    || vps_die "Fail2ban state is not a safe directory: ${state_dir}"
  [[ "$(stat -c '%u' "${state_dir}")" == "0" ]] \
    || vps_die "Fail2ban state directory must be owned by root"
  [[ -f "${state_dir}/state-version" && ! -L "${state_dir}/state-version" \
    && "$(<"${state_dir}/state-version")" == "1" ]] \
    || vps_die "Fail2ban state is incomplete or incompatible"
  vps_system_read_binary_state "${state_dir}/package-installed-by-bundle" >/dev/null
  vps_system_read_binary_state "${state_dir}/service-was-enabled" >/dev/null
  vps_system_read_binary_state "${state_dir}/service-was-active" >/dev/null
  vps_system_read_binary_state "${state_dir}/service-was-masked" >/dev/null
}

vps_system_initialize_fail2ban_state() (
  local package_installed_by_bundle=1
  local parent_directory=""
  local service_state=""
  local service_was_active=0
  local service_was_enabled=0
  local service_was_masked=0
  local state_dir="$1"
  local temporary_directory=""

  if [[ -e "${state_dir}" || -L "${state_dir}" ]]; then
    vps_system_validate_fail2ban_state "${state_dir}"
    return 0
  fi
  vps_system_package_is_installed fail2ban && package_installed_by_bundle=0
  systemctl is-active --quiet "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null 2>&1 \
    && service_was_active=1
  service_state="$(systemctl is-enabled "${VPS_SYSTEM_FAIL2BAN_SERVICE}" 2>/dev/null || true)"
  case "${service_state}" in
    enabled|enabled-runtime|linked|linked-runtime|alias) service_was_enabled=1 ;;
    masked|masked-runtime) service_was_masked=1 ;;
  esac

  parent_directory="$(dirname "${state_dir}")"
  install -d -m 755 "${parent_directory}"
  temporary_directory="$(mktemp -d "${parent_directory}/.fail2ban.XXXXXX")"
  trap '[[ -z "${temporary_directory}" ]] || rm -rf -- "${temporary_directory}"' EXIT
  chmod 700 "${temporary_directory}"
  printf '1\n' > "${temporary_directory}/state-version"
  printf '%s\n' "${package_installed_by_bundle}" \
    > "${temporary_directory}/package-installed-by-bundle"
  printf '%s\n' "${service_was_enabled}" > "${temporary_directory}/service-was-enabled"
  printf '%s\n' "${service_was_active}" > "${temporary_directory}/service-was-active"
  printf '%s\n' "${service_was_masked}" > "${temporary_directory}/service-was-masked"
  chmod 600 "${temporary_directory}/"*
  mv -- "${temporary_directory}" "${state_dir}"
  temporary_directory=""
)

vps_system_verify_fail2ban_setting() {
  local actual=""
  local expected="$2"
  local setting="$1"

  actual="$(fail2ban-client get "${VPS_SYSTEM_FAIL2BAN_JAIL}" "${setting}")" \
    || vps_die "could not read effective Fail2ban ${setting}"
  [[ "${actual}" == "${expected}" ]] \
    || vps_die "effective Fail2ban ${setting} is ${actual}, expected ${expected}"
}

vps_system_wait_for_fail2ban() {
  local attempt=0

  for (( attempt = 1; attempt <= 20; attempt++ )); do
    if fail2ban-client ping >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < 20 )); then
      sleep 1
    fi
  done
  return 1
}

vps_system_activate_fail2ban() {
  fail2ban-client -t >/dev/null \
    || vps_die "Fail2ban configuration validation failed"
  systemctl unmask "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
    || vps_die "Fail2ban service could not be unmasked"
  systemctl enable "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
    || vps_die "Fail2ban service could not be enabled"
  systemctl restart "${VPS_SYSTEM_FAIL2BAN_SERVICE}" \
    || vps_die "Fail2ban service could not be started"
  systemctl is-active --quiet "${VPS_SYSTEM_FAIL2BAN_SERVICE}" \
    || vps_die "Fail2ban service is not active"
  vps_system_wait_for_fail2ban \
    || vps_die "Fail2ban daemon socket did not become ready; check systemctl status and journalctl -u fail2ban.service"
  fail2ban-client status "${VPS_SYSTEM_FAIL2BAN_JAIL}" >/dev/null \
    || vps_die "Fail2ban sshd jail is not active"
  vps_system_verify_fail2ban_setting bantime 3600
  vps_system_verify_fail2ban_setting findtime 600
  vps_system_verify_fail2ban_setting maxretry 5
}

vps_system_restore_fail2ban_service_state() {
  local state_dir="$1"
  local was_active=""
  local was_enabled=""
  local was_masked=""

  was_enabled="$(vps_system_read_binary_state "${state_dir}/service-was-enabled")"
  was_active="$(vps_system_read_binary_state "${state_dir}/service-was-active")"
  was_masked="$(vps_system_read_binary_state "${state_dir}/service-was-masked")"

  systemctl unmask "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
    || vps_die "Fail2ban service could not be unmasked during restoration"
  if [[ "${was_enabled}" == "1" ]]; then
    systemctl enable "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
      || vps_die "Fail2ban service enabled state could not be restored"
  else
    systemctl disable "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
      || vps_die "Fail2ban service enabled state could not be restored"
  fi
  if [[ "${was_active}" == "1" ]]; then
    systemctl restart "${VPS_SYSTEM_FAIL2BAN_SERVICE}" \
      || vps_die "Fail2ban service active state could not be restored"
  else
    systemctl stop "${VPS_SYSTEM_FAIL2BAN_SERVICE}" \
      || vps_die "Fail2ban service active state could not be restored"
  fi
  if [[ "${was_masked}" == "1" ]]; then
    systemctl mask "${VPS_SYSTEM_FAIL2BAN_SERVICE}" >/dev/null \
      || vps_die "Fail2ban service mask could not be restored"
  fi
}

vps_system_uninstall_fail2ban() {
  local installed_by_bundle=""
  local jail_config="$1"
  local state_dir="$2"

  vps_system_require_managed_or_absent "${jail_config}"
  vps_safe_remove_file_path "${jail_config}"
  if [[ ! -e "${state_dir}" ]]; then
    printf 'No Fail2ban baseline state was found; its package and service were left unchanged.\n'
    return 0
  fi

  vps_system_validate_fail2ban_state "${state_dir}"
  installed_by_bundle="$(vps_system_read_binary_state \
    "${state_dir}/package-installed-by-bundle")"
  if [[ "${installed_by_bundle}" == "1" ]]; then
    if vps_system_package_is_installed fail2ban; then
      DEBIAN_FRONTEND=noninteractive apt-get remove -y fail2ban
    fi
  elif vps_system_package_is_installed fail2ban; then
    vps_require_commands fail2ban-client
    fail2ban-client -t >/dev/null \
      || vps_die "remaining Fail2ban configuration is invalid"
    vps_system_restore_fail2ban_service_state "${state_dir}"
  fi
  vps_safe_remove_path "${state_dir}"
}

vps_system_validate_state_dir() {
  local state_dir="$1"
  local auto_update_state_dir="${VPS_AUTO_UPDATE_STATE_DIR:-${state_dir}/auto-updates}"
  local fail2ban_state_dir="${VPS_FAIL2BAN_STATE_DIR:-${state_dir}/fail2ban}"

  [[ "${state_dir}" == /* && "${state_dir}" != "/" ]] \
    || vps_die "system-scripts state directory is unsafe: ${state_dir}"
  if [[ -L "${state_dir}" || ( -e "${state_dir}" && ! -d "${state_dir}" ) ]]; then
    vps_die "system-scripts state directory is not a safe directory: ${state_dir}"
  fi
  [[ -d "${state_dir}" ]] || return 0
  [[ "$(stat -c '%u' "${state_dir}")" == "0" ]] \
    || vps_die "system-scripts state directory must be owned by root"
  [[ -f "${state_dir}/state-version" && "$(<"${state_dir}/state-version")" == "1" ]] \
    || vps_die "system-scripts state directory is incomplete or incompatible"
  vps_system_read_binary_state "${state_dir}/logrotate-was-enabled" >/dev/null
  vps_system_read_binary_state "${state_dir}/logrotate-was-active" >/dev/null
  vps_system_read_binary_state "${state_dir}/zram-package-was-installed" >/dev/null
  vps_system_read_binary_state "${state_dir}/zram-package-installed-by-bundle" >/dev/null
  vps_system_validate_auto_update_state "${auto_update_state_dir}"
  vps_system_validate_fail2ban_state "${fail2ban_state_dir}"
}
