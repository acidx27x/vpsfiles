#!/usr/bin/env bash

[[ -n "${VPS_SYSTEM_SH:-}" ]] && return 0
VPS_SYSTEM_SH=1

VPS_SYSTEM_MANAGED_MARKER="# Managed by vpsfiles system-scripts."
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

vps_system_validate_state_dir() {
  local state_dir="$1"
  local auto_update_state_dir="${VPS_AUTO_UPDATE_STATE_DIR:-${state_dir}/auto-updates}"

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
}
