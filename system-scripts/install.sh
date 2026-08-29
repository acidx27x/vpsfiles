#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VPS_JOURNALD_CONFIG="${VPS_JOURNALD_CONFIG:-/etc/systemd/journald.conf.d/60-vpsfiles-limits.conf}"
VPS_COREDUMP_CONFIG="${VPS_COREDUMP_CONFIG:-/etc/systemd/coredump.conf.d/60-vpsfiles-limits.conf}"
VPS_ZRAM_CONFIG="${VPS_ZRAM_CONFIG:-/etc/systemd/zram-generator.conf.d/60-vpsfiles.conf}"
VPS_MAINTENANCE_BIN="${VPS_MAINTENANCE_BIN:-/usr/local/sbin/vpsfiles-maintenance}"
VPS_MAINTENANCE_SERVICE="${VPS_MAINTENANCE_SERVICE:-/etc/systemd/system/vpsfiles-maintenance.service}"
VPS_MAINTENANCE_TIMER="${VPS_MAINTENANCE_TIMER:-/etc/systemd/system/vpsfiles-maintenance.timer}"
VPS_MEMINFO="${VPS_MEMINFO:-/proc/meminfo}"
VPS_LOG_FILESYSTEM_PATH="${VPS_LOG_FILESYSTEM_PATH:-/var/log}"
VPS_ZRAM_DEVICE_PATH="${VPS_ZRAM_DEVICE_PATH:-/sys/block/zram0}"
VPS_ZRAM_MAIN_CONFIG="${VPS_ZRAM_MAIN_CONFIG:-/etc/systemd/zram-generator.conf}"
VPS_ZRAM_CONFIG_DIR="${VPS_ZRAM_CONFIG_DIR:-/etc/systemd/zram-generator.conf.d}"
VPS_SYSTEM_STATE_DIR="${VPS_SYSTEM_STATE_DIR:-/var/lib/vpsfiles-system}"
VPS_APT_PERIODIC_CONFIG="${VPS_APT_PERIODIC_CONFIG:-/etc/apt/apt.conf.d/99-vpsfiles-disable-auto-updates}"
VPS_AUTO_UPDATE_STATE_DIR="${VPS_AUTO_UPDATE_STATE_DIR:-${VPS_SYSTEM_STATE_DIR}/auto-updates}"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=system-scripts/system.sh
. "${SCRIPT_DIR}/system.sh"

vps_system_require_files() {
  local file=""

  for file in "${SCRIPT_DIR}/cleanup.sh" "${SCRIPT_DIR}/uninstall.sh"; do
    [[ -f "${file}" ]] || vps_die "required file is missing: ${file}"
  done
}

vps_system_validate_paths() {
  local path=""

  for path in \
    "${VPS_JOURNALD_CONFIG}" \
    "${VPS_COREDUMP_CONFIG}" \
    "${VPS_ZRAM_CONFIG}" \
    "${VPS_MAINTENANCE_BIN}" \
    "${VPS_MAINTENANCE_SERVICE}" \
    "${VPS_MAINTENANCE_TIMER}"; do
    [[ "${path}" == /* && "${path}" != "/" ]] || vps_die "managed path is unsafe: ${path}"
    vps_system_require_managed_or_absent "${path}"
  done
  vps_system_validate_state_dir "${VPS_SYSTEM_STATE_DIR}"
}

vps_system_initialize_state() {
  local logrotate_was_active=0
  local logrotate_was_enabled=0
  local parent_directory=""
  local temporary_directory=""
  local zram_package_was_installed=0

  [[ ! -d "${VPS_SYSTEM_STATE_DIR}" ]] || return 0
  systemctl is-enabled --quiet logrotate.timer >/dev/null 2>&1 && logrotate_was_enabled=1
  systemctl is-active --quiet logrotate.timer >/dev/null 2>&1 && logrotate_was_active=1
  vps_system_package_is_installed systemd-zram-generator && zram_package_was_installed=1

  parent_directory="$(dirname "${VPS_SYSTEM_STATE_DIR}")"
  install -d -m 755 "${parent_directory}"
  temporary_directory="$(mktemp -d "${parent_directory}/.vpsfiles-system.XXXXXX")"
  printf '1\n' > "${temporary_directory}/state-version"
  printf '%s\n' "${logrotate_was_enabled}" > "${temporary_directory}/logrotate-was-enabled"
  printf '%s\n' "${logrotate_was_active}" > "${temporary_directory}/logrotate-was-active"
  printf '%s\n' "${zram_package_was_installed}" > "${temporary_directory}/zram-package-was-installed"
  printf '0\n' > "${temporary_directory}/zram-package-installed-by-bundle"
  chmod 600 "${temporary_directory}/"*
  mv -- "${temporary_directory}" "${VPS_SYSTEM_STATE_DIR}"
}

vps_system_validate_auto_update_paths() {
  [[ "${VPS_APT_PERIODIC_CONFIG}" == /* && "${VPS_APT_PERIODIC_CONFIG}" != "/" ]] \
    || vps_die "managed APT periodic configuration path is unsafe: ${VPS_APT_PERIODIC_CONFIG}"
  vps_system_require_managed_or_absent "${VPS_APT_PERIODIC_CONFIG}"
  vps_system_validate_auto_update_state "${VPS_AUTO_UPDATE_STATE_DIR}"
}

vps_system_initialize_auto_update_state() {
  local temporary_directory=""
  local unit=""
  local unit_file_state=""
  local unit_state_dir=""
  local was_active=0
  local was_masked=0

  if [[ -e "${VPS_AUTO_UPDATE_STATE_DIR}" ]]; then
    vps_system_validate_auto_update_state "${VPS_AUTO_UPDATE_STATE_DIR}"
    return 0
  fi
  [[ -d "${VPS_SYSTEM_STATE_DIR}" ]] \
    || vps_die "system-scripts state must be initialized before automatic-update state"
  temporary_directory="$(mktemp -d "${VPS_SYSTEM_STATE_DIR}/.auto-updates.XXXXXX")"
  if ! install -d -m 700 "${temporary_directory}/units"; then
    vps_safe_remove_path "${temporary_directory}"
    return 1
  fi
  printf '1\n' > "${temporary_directory}/state-version"
  : > "${temporary_directory}/kernel-holds-added"
  chmod 600 "${temporary_directory}/state-version" "${temporary_directory}/kernel-holds-added"
  for unit in "${VPS_SYSTEM_AUTO_UPDATE_UNITS[@]}"; do
    was_active=0
    was_masked=0
    systemctl is-active --quiet "${unit}" >/dev/null 2>&1 && was_active=1
    unit_file_state="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    if [[ "${unit_file_state}" == "masked" || "${unit_file_state}" == "masked-runtime" ]]; then
      was_masked=1
    fi
    unit_state_dir="${temporary_directory}/units/${unit}"
    install -d -m 700 "${unit_state_dir}"
    printf '%s\n' "${was_masked}" > "${unit_state_dir}/was-masked"
    printf '%s\n' "${was_active}" > "${unit_state_dir}/was-active"
    chmod 600 "${unit_state_dir}/was-masked" "${unit_state_dir}/was-active"
  done
  mv -- "${temporary_directory}" "${VPS_AUTO_UPDATE_STATE_DIR}"
}

vps_system_disable_auto_updates() {
  local apt_config=""
  local current_holds=""
  local package=""
  local unit=""
  local unit_file_state=""
  local -a kernel_packages=()

  vps_require_commands apt-config apt-mark sort
  vps_system_validate_auto_update_paths
  vps_system_initialize_auto_update_state
  vps_system_install_rendered_file \
    "${VPS_APT_PERIODIC_CONFIG}" 644 vps_system_render_apt_periodic_config
  for unit in "${VPS_SYSTEM_AUTO_UPDATE_UNITS[@]}"; do
    systemctl mask "${unit}" >/dev/null
    if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
      systemctl stop "${unit}"
    fi
  done
  mapfile -t kernel_packages < <(vps_system_detect_kernel_meta_packages)
  current_holds="$(apt-mark showhold)"
  if (( ${#kernel_packages[@]} == 0 )); then
    printf 'No installed Ubuntu kernel meta-packages were detected; no kernel holds were added.\n'
  else
    for package in "${kernel_packages[@]}"; do
      if ! grep -qxF -- "${package}" <<< "${current_holds}"; then
        vps_system_record_added_kernel_hold \
          "${VPS_AUTO_UPDATE_STATE_DIR}/kernel-holds-added" "${package}"
        apt-mark hold "${package}"
        current_holds="${current_holds}"$'\n'"${package}"
      fi
    done
  fi
  apt_config="$(apt-config dump)"
  for package in \
    'APT::Periodic::Enable "0";' \
    'APT::Periodic::Update-Package-Lists "0";' \
    'APT::Periodic::Unattended-Upgrade "0";'; do
    grep -qxF -- "${package}" <<< "${apt_config}" \
      || vps_die "APT periodic updates were not disabled: ${package}"
  done
  for unit in "${VPS_SYSTEM_AUTO_UPDATE_UNITS[@]}"; do
    unit_file_state="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    [[ "${unit_file_state}" == "masked" || "${unit_file_state}" == "masked-runtime" ]] \
      || vps_die "automatic-update unit was not masked: ${unit}"
    if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
      vps_die "automatic-update unit is still active: ${unit}"
    fi
  done
  current_holds="$(apt-mark showhold)"
  for package in "${kernel_packages[@]}"; do
    grep -qxF -- "${package}" <<< "${current_holds}" \
      || vps_die "kernel meta-package was not held: ${package}"
  done
  printf 'Automatic APT activity is disabled and its systemd units are masked.\n'
  if (( ${#kernel_packages[@]} > 0 )); then
    printf 'Held kernel meta-packages:\n'
    printf '  %s\n' "${kernel_packages[@]}"
  fi
}

vps_system_detect_memory_mib() {
  local memory_kib=""

  [[ -f "${VPS_MEMINFO}" ]] || vps_die "memory information is unavailable: ${VPS_MEMINFO}"
  memory_kib="$(awk '$1 == "MemTotal:" {print $2; exit}' "${VPS_MEMINFO}")"
  vps_validate_positive_int "detected memory" "${memory_kib}"
  printf '%s\n' "$(( memory_kib / 1024 ))"
}

vps_system_detect_filesystem_mib() {
  local filesystem_kib=""

  [[ -d "${VPS_LOG_FILESYSTEM_PATH}" ]] || vps_die "log filesystem path is missing: ${VPS_LOG_FILESYSTEM_PATH}"
  filesystem_kib="$(df -Pk -- "${VPS_LOG_FILESYSTEM_PATH}" | awk 'NR == 2 {print $2; exit}')"
  vps_validate_positive_int "detected filesystem size" "${filesystem_kib}"
  printf '%s\n' "$(( filesystem_kib / 1024 ))"
}

vps_system_install_rendered_file() {
  local destination="$1"
  local mode="$2"
  shift 2
  local temporary_file=""

  temporary_file="$(mktemp)"
  if ! "$@" > "${temporary_file}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
  if ! install -D -m "${mode}" "${temporary_file}" "${destination}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
  rm -f -- "${temporary_file}"
}

vps_system_has_other_zram_configuration() {
  local path=""

  if [[ -e "${VPS_ZRAM_DEVICE_PATH}" ]] && ! vps_system_is_managed_file "${VPS_ZRAM_CONFIG}"; then
    return 0
  fi
  for path in \
    "${VPS_ZRAM_MAIN_CONFIG}" \
    "${VPS_ZRAM_CONFIG_DIR}"/*.conf; do
    [[ -e "${path}" ]] || continue
    [[ "${path}" == "${VPS_ZRAM_CONFIG}" ]] && continue
    return 0
  done
  return 1
}

vps_system_configure_zram() {
  local zram_package_was_installed=""

  if vps_system_has_other_zram_configuration; then
    printf 'Existing zram configuration was found; leaving it unchanged.\n'
    return 0
  fi
  if systemd-detect-virt --quiet --container; then
    printf 'Container virtualization detected; skipping host zram configuration.\n'
    return 0
  fi
  if ! apt-cache show systemd-zram-generator >/dev/null 2>&1; then
    printf 'systemd-zram-generator is unavailable from configured APT repositories; skipping zram.\n'
    return 0
  fi
  if ! modprobe zram; then
    printf 'The running kernel does not provide zram; skipping compressed swap.\n'
    return 0
  fi

  zram_package_was_installed="$(vps_system_read_binary_state "${VPS_SYSTEM_STATE_DIR}/zram-package-was-installed")"
  DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator
  if [[ "${zram_package_was_installed}" == "0" ]]; then
    vps_system_write_binary_state "${VPS_SYSTEM_STATE_DIR}/zram-package-installed-by-bundle" 1
  fi
  vps_system_install_rendered_file "${VPS_ZRAM_CONFIG}" 644 vps_system_render_zram_config
  systemctl daemon-reload
  if swapon --noheadings --show=NAME | grep -qxF /dev/zram0; then
    printf 'zram swap is already active; the managed size will apply after the next reboot.\n'
  else
    systemctl start systemd-zram-setup@zram0.service \
      || vps_die "zram configuration was installed but /dev/zram0 could not be started"
  fi
}

vps_system_main() {
  local coredump_limit_mib=""
  local disable_auto_updates=0
  local filesystem_mib=""
  local journal_limit_mib=""
  local keep_free_mib=""
  local memory_mib=""
  local runtime_limit_mib=""

  [[ $# -eq 0 ]] || vps_die "usage: install.sh"
  vps_require_root "sudo ./install.sh"
  vps_require_supported_apt_os
  vps_require_systemd
  vps_system_require_files
  vps_system_validate_paths
  vps_require_commands apt-get awk df dpkg-query grep install mktemp mv stat systemctl

  memory_mib="$(vps_system_detect_memory_mib)"
  filesystem_mib="$(vps_system_detect_filesystem_mib)"
  journal_limit_mib="$(vps_system_journal_limit_mib "${filesystem_mib}")"
  runtime_limit_mib="$(vps_system_runtime_journal_limit_mib "${memory_mib}")"
  keep_free_mib="$(vps_system_keep_free_mib "${filesystem_mib}")"
  coredump_limit_mib="$(vps_system_coredump_limit_mib "${filesystem_mib}")"

  printf '%s\n' \
    'Resource-constrained VPS maintenance setup' \
    '' \
    "Detected RAM:                  ${memory_mib} MiB" \
    "Detected log filesystem:       ${filesystem_mib} MiB" \
    "Persistent journal cap:        ${journal_limit_mib} MiB" \
    "Runtime journal cap:           ${runtime_limit_mib} MiB" \
    "Journal/coredump free reserve: ${keep_free_mib} MiB" \
    "Coredump cap:                  ${coredump_limit_mib} MiB" \
    '' \
    'This will install bounded journal and coredump settings, enable daily safe cleanup,' \
    'enable log rotation, and configure compressed zram swap when the host supports it.' \
    'It will not remove packages, application data, user files, or unrelated Docker data.'
  if ! vps_confirm "Continue?"; then
    printf 'Aborted before making changes.\n'
    return 1
  fi

  if [[ -d "${VPS_AUTO_UPDATE_STATE_DIR}" ]]; then
    disable_auto_updates=1
    printf 'Automatic updates were disabled by an earlier run and will remain disabled.\n'
  elif vps_system_is_ubuntu; then
    printf '%s\n' \
      '' \
      'Optional Ubuntu update lock:' \
      'This stops automatic userspace and kernel security updates.' \
      'You must run and review manual updates to keep the VPS secure.'
    if vps_confirm "Disable automatic APT and kernel updates?"; then
      disable_auto_updates=1
    else
      printf 'Automatic APT and kernel updates will remain unchanged.\n'
    fi
  fi
  if [[ "${disable_auto_updates}" == "1" ]]; then
    vps_system_validate_auto_update_paths
  fi
  vps_system_initialize_state
  vps_install_packages kmod logrotate util-linux
  if [[ "${disable_auto_updates}" == "1" ]]; then
    vps_system_disable_auto_updates
  fi
  vps_require_commands apt-cache flock journalctl modprobe swapon systemd-analyze systemd-detect-virt systemd-tmpfiles

  vps_system_install_rendered_file \
    "${VPS_JOURNALD_CONFIG}" 644 vps_system_render_journald_config \
    "${journal_limit_mib}" "${runtime_limit_mib}" "${keep_free_mib}"
  vps_system_install_rendered_file \
    "${VPS_COREDUMP_CONFIG}" 644 vps_system_render_coredump_config \
    "${coredump_limit_mib}" "${keep_free_mib}"
  install -D -m 755 "${SCRIPT_DIR}/cleanup.sh" "${VPS_MAINTENANCE_BIN}"
  vps_system_install_rendered_file \
    "${VPS_MAINTENANCE_SERVICE}" 644 vps_system_render_maintenance_service "${VPS_MAINTENANCE_BIN}"
  vps_system_install_rendered_file \
    "${VPS_MAINTENANCE_TIMER}" 644 vps_system_render_maintenance_timer

  systemd-analyze verify "${VPS_MAINTENANCE_SERVICE}" "${VPS_MAINTENANCE_TIMER}"
  systemctl daemon-reload
  systemctl restart systemd-journald
  systemctl enable --now logrotate.timer >/dev/null
  systemctl enable --now vpsfiles-maintenance.timer >/dev/null
  vps_system_configure_zram
  journalctl --rotate
  journalctl --vacuum-size="${journal_limit_mib}M" --vacuum-time=7d
  "${VPS_MAINTENANCE_BIN}" --scheduled

  systemctl is-enabled --quiet vpsfiles-maintenance.timer \
    || vps_die "maintenance timer was not enabled"
  systemctl is-active --quiet vpsfiles-maintenance.timer \
    || vps_die "maintenance timer is not active"
  printf '\nSystem maintenance setup complete.\n'
  printf 'Next scheduled run:\n'
  systemctl list-timers vpsfiles-maintenance.timer --no-pager
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  vps_system_main "$@"
fi
