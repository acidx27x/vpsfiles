#!/usr/bin/env bash

[[ -n "${VPS_ADGUARDHOME_UNBOUND_SH:-}" ]] && return 0
VPS_ADGUARDHOME_UNBOUND_SH=1

UNBOUND_SERVICE="${UNBOUND_SERVICE:-unbound.service}"
UNBOUND_RESOLVCONF_SERVICE="${UNBOUND_RESOLVCONF_SERVICE:-unbound-resolvconf.service}"
UNBOUND_PORT=5335
UNBOUND_ETC_DIR="${UNBOUND_ETC_DIR:-/etc/unbound}"
UNBOUND_MANAGED_CONFIG="${UNBOUND_MANAGED_CONFIG:-${UNBOUND_ETC_DIR}/unbound.conf.d/vpsfiles-adguardhome.conf}"
UNBOUND_RESOLVCONF_CONFIG="${UNBOUND_RESOLVCONF_CONFIG:-${UNBOUND_ETC_DIR}/unbound.conf.d/resolvconf_resolvers.conf}"
UNBOUND_RESOLVCONF_CONF="${UNBOUND_RESOLVCONF_CONF:-/etc/resolvconf.conf}"
UNBOUND_STATE_DIR="${UNBOUND_STATE_DIR:-/var/lib/vpsfiles-adguardhome/unbound}"

unbound_render_config() {
  printf '%s\n' \
    'server:' \
    '    interface: 127.0.0.1@5335' \
    '    access-control: 127.0.0.0/8 allow' \
    '    do-ip4: yes' \
    '    do-ip6: no' \
    '    do-udp: yes' \
    '    do-tcp: yes' \
    '    hide-identity: yes' \
    '    hide-version: yes' \
    '    edns-buffer-size: 1232' \
    '    prefetch: yes'
}

unbound_validate_paths() {
  [[ "${UNBOUND_ETC_DIR}" == /* && "${UNBOUND_ETC_DIR}" != "/" ]] \
    || vps_die "unsafe Unbound configuration directory: ${UNBOUND_ETC_DIR}"
  [[ "${UNBOUND_MANAGED_CONFIG}" == "${UNBOUND_ETC_DIR}/"* ]] \
    || vps_die "managed Unbound configuration must be under ${UNBOUND_ETC_DIR}"
  [[ "${UNBOUND_RESOLVCONF_CONFIG}" == "${UNBOUND_ETC_DIR}/"* ]] \
    || vps_die "resolvconf Unbound configuration must be under ${UNBOUND_ETC_DIR}"
  [[ "${UNBOUND_RESOLVCONF_CONF}" == /* && "${UNBOUND_RESOLVCONF_CONF}" != "/" ]] \
    || vps_die "unsafe resolvconf configuration path: ${UNBOUND_RESOLVCONF_CONF}"
  [[ "${UNBOUND_STATE_DIR}" == /* && "${UNBOUND_STATE_DIR}" != "/" ]] \
    || vps_die "unsafe Unbound state directory: ${UNBOUND_STATE_DIR}"
}

unbound_config_is_managed() {
  local config="$1"

  [[ -f "${config}" && ! -L "${config}" ]] || return 1
  cmp -s -- "${config}" <(unbound_render_config)
}

unbound_install_managed_config() {
  local config_dir=""
  local temporary_file=""

  config_dir="$(dirname "${UNBOUND_MANAGED_CONFIG}")"
  if [[ -L "${UNBOUND_MANAGED_CONFIG}" ]]; then
    vps_die "refusing to replace symlink at managed Unbound configuration: ${UNBOUND_MANAGED_CONFIG}"
  fi
  if [[ -e "${UNBOUND_MANAGED_CONFIG}" ]] && ! unbound_config_is_managed "${UNBOUND_MANAGED_CONFIG}"; then
    vps_die "refusing to replace Unbound configuration not owned by this bundle: ${UNBOUND_MANAGED_CONFIG}"
  fi
  install -d -m 755 "${config_dir}" || return 1
  temporary_file="$(mktemp "${config_dir}/.vpsfiles-adguardhome.XXXXXX")" || return 1
  if ! unbound_render_config > "${temporary_file}" \
    || ! chmod 644 "${temporary_file}" \
    || ! mv -f -- "${temporary_file}" "${UNBOUND_MANAGED_CONFIG}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
}

unbound_remove_managed_config() {
  [[ -e "${UNBOUND_MANAGED_CONFIG}" ]] || return 0
  unbound_config_is_managed "${UNBOUND_MANAGED_CONFIG}" \
    || vps_die "refusing to remove changed Unbound configuration: ${UNBOUND_MANAGED_CONFIG}"
  rm -f -- "${UNBOUND_MANAGED_CONFIG}" || return 1
  printf 'Removed: %s\n' "${UNBOUND_MANAGED_CONFIG}"
  vps_remove_empty_dir "$(dirname "${UNBOUND_MANAGED_CONFIG}")"
}

unbound_listener_conflicts() {
  local protocol="$1"
  local line=""
  local local_address=""
  local -a ss_arguments=(-H -ltn)

  [[ "${protocol}" == "tcp" || "${protocol}" == "udp" ]] \
    || vps_die "invalid Unbound listener protocol: ${protocol}"
  if [[ "${protocol}" == "udp" ]]; then
    ss_arguments=(-H -lun)
  fi
  while IFS= read -r line; do
    local_address="$(awk '{print $4}' <<< "${line}")"
    case "${local_address}" in
      "127.0.0.1:${UNBOUND_PORT}"|"0.0.0.0:${UNBOUND_PORT}"|"*:${UNBOUND_PORT}"|"[::]:${UNBOUND_PORT}"|":::${UNBOUND_PORT}")
        return 0
        ;;
    esac
  done < <(ss "${ss_arguments[@]}" "sport = :${UNBOUND_PORT}")
  return 1
}

unbound_loopback_port_is_available() {
  ! unbound_listener_conflicts tcp && ! unbound_listener_conflicts udp
}

unbound_resolvconf_targets() {
  [[ -f "${UNBOUND_RESOLVCONF_CONF}" && ! -L "${UNBOUND_RESOLVCONF_CONF}" ]] || return 0
  awk '
    BEGIN { single_quote = sprintf("%c", 39) }
    /^[[:space:]]*unbound_conf[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*unbound_conf[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*#[^#]*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == single_quote && substr(value, length(value), 1) == single_quote)) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
    }
  ' "${UNBOUND_RESOLVCONF_CONF}"
}

unbound_resolvconf_config_is_explained() {
  [[ -e "${UNBOUND_RESOLVCONF_CONFIG}" ]] || return 0
  [[ -f "${UNBOUND_RESOLVCONF_CONFIG}" && ! -L "${UNBOUND_RESOLVCONF_CONFIG}" ]] || return 1
  unbound_resolvconf_targets | grep -qxF -- "${UNBOUND_RESOLVCONF_CONFIG}"
}

unbound_package_file_is_pristine() {
  local config="$1"
  local conffiles=""
  local expected_md5=""
  local owner=""
  local ownership=""

  [[ -f "${config}" && ! -L "${config}" ]] || return 1
  ownership="$(dpkg-query -S "${config}" 2>/dev/null)" || return 1
  ownership="${ownership%%$'\n'*}"
  owner="${ownership%%:*}"
  [[ -n "${owner}" ]] || return 1
  conffiles="$(dpkg-query -W -f='${Conffiles}\n' "${owner}" 2>/dev/null || true)"
  expected_md5="$(awk -v path="${config}" '$1 == path { print $2; exit }' <<< "${conffiles}")"
  if [[ -z "${expected_md5}" ]]; then
    return 0
  fi
  [[ "$(md5sum "${config}" | awk '{print $1}')" == "${expected_md5}" ]]
}

unbound_find_custom_configuration() {
  local config=""

  [[ -d "${UNBOUND_ETC_DIR}" ]] || return 1
  while IFS= read -r -d '' config; do
    if [[ "${config}" == "${UNBOUND_RESOLVCONF_CONFIG}" ]] \
      && unbound_resolvconf_config_is_explained; then
      continue
    fi
    if ! unbound_package_file_is_pristine "${config}"; then
      printf '%s\n' "${config}"
      return 0
    fi
  done < <(find "${UNBOUND_ETC_DIR}" \
    \( -type f -o -type l \) \
    \( -name unbound.conf -o -name '*.conf' \) -print0)
  return 1
}

unbound_preflight() {
  local custom_config=""

  unbound_validate_paths
  [[ ! -e "${UNBOUND_STATE_DIR}" ]] \
    || vps_die "Unbound is already managed by this AdGuard Home bundle"
  [[ ! -L "${UNBOUND_RESOLVCONF_CONF}" ]] \
    || vps_die "refusing resolver integration symlink: ${UNBOUND_RESOLVCONF_CONF}"
  if ! unbound_loopback_port_is_available; then
    vps_die "TCP or UDP port ${UNBOUND_PORT} is already in use on loopback"
  fi
  if systemctl is-active --quiet "${UNBOUND_SERVICE}"; then
    vps_die "an active Unbound service already exists; it will not be taken over"
  fi
  if [[ -e "${UNBOUND_RESOLVCONF_CONFIG}" ]] \
    && ! unbound_resolvconf_config_is_explained; then
    vps_die "existing ${UNBOUND_RESOLVCONF_CONFIG} is not explained by unbound_conf in ${UNBOUND_RESOLVCONF_CONF}"
  fi
  if custom_config="$(unbound_find_custom_configuration)"; then
    vps_die "existing custom Unbound configuration will not be overwritten: ${custom_config}"
  fi
}

unbound_write_binary_state() {
  local path="$1"
  local value="$2"
  local temporary_file=""

  [[ "${value}" == "0" || "${value}" == "1" ]] \
    || vps_die "invalid Unbound state value for ${path}"
  temporary_file="$(mktemp "$(dirname "${path}")/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "${value}" > "${temporary_file}" \
    || ! chmod 600 "${temporary_file}" \
    || ! mv -f -- "${temporary_file}" "${path}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
}

unbound_read_binary_state() {
  local path="$1"
  local value=""

  [[ -f "${path}" && ! -L "${path}" ]] \
    || vps_die "Unbound state is missing or unsafe: ${path}"
  value="$(<"${path}")"
  [[ "${value}" == "0" || "${value}" == "1" ]] \
    || vps_die "Unbound state is invalid: ${path}"
  printf '%s\n' "${value}"
}

unbound_save_service_state() {
  local directory="$1"
  local service="$2"
  local active=0
  local enabled=0
  local enabled_state=""
  local present=0
  local masked=0

  install -d -m 700 "${directory}"
  systemctl cat "${service}" >/dev/null 2>&1 && present=1
  systemctl is-active --quiet "${service}" >/dev/null 2>&1 && active=1
  enabled_state="$(systemctl is-enabled "${service}" 2>/dev/null || true)"
  case "${enabled_state}" in
    enabled|enabled-runtime|linked|linked-runtime|alias) enabled=1 ;;
    masked|masked-runtime) masked=1 ;;
  esac
  printf '%s\n' "${present}" > "${directory}/was-present"
  printf '%s\n' "${active}" > "${directory}/was-active"
  printf '%s\n' "${enabled}" > "${directory}/was-enabled"
  printf '%s\n' "${masked}" > "${directory}/was-masked"
  chmod 600 "${directory}/"*
}

unbound_restore_service_state() {
  local directory="$1"
  local service="$2"
  local was_active=""
  local was_enabled=""
  local was_masked=""
  local was_present=""

  was_present="$(unbound_read_binary_state "${directory}/was-present")"
  was_active="$(unbound_read_binary_state "${directory}/was-active")"
  was_enabled="$(unbound_read_binary_state "${directory}/was-enabled")"
  was_masked="$(unbound_read_binary_state "${directory}/was-masked")"
  if [[ "${was_present}" == "0" ]]; then
    systemctl unmask "${service}" >/dev/null 2>&1 || true
    systemctl disable "${service}" >/dev/null 2>&1 || true
    systemctl stop "${service}" >/dev/null 2>&1 || true
    return 0
  fi
  systemctl unmask "${service}" >/dev/null || return 1
  if [[ "${was_enabled}" == "1" ]]; then
    systemctl enable "${service}" >/dev/null || return 1
  else
    systemctl disable "${service}" >/dev/null || return 1
  fi
  if [[ "${was_active}" == "1" ]]; then
    systemctl start "${service}" || return 1
  else
    systemctl stop "${service}" >/dev/null 2>&1 || true
  fi
  if [[ "${was_masked}" == "1" ]]; then
    systemctl mask "${service}" >/dev/null || return 1
  fi
}

unbound_initialize_state() (
  local generated_existed=0
  local parent_directory=""
  local resolvconf_existed=0
  local temporary_directory=""

  [[ ! -e "${UNBOUND_STATE_DIR}" ]] \
    || vps_die "Unbound state already exists: ${UNBOUND_STATE_DIR}"
  parent_directory="$(dirname "${UNBOUND_STATE_DIR}")"
  install -d -m 755 "${parent_directory}"
  temporary_directory="$(mktemp -d "${parent_directory}/.unbound.XXXXXX")"
  trap '[[ -z "${temporary_directory}" ]] || rm -rf -- "${temporary_directory}"' EXIT
  chmod 700 "${temporary_directory}"
  printf '1\n' > "${temporary_directory}/state-version"
  printf '0\n' > "${temporary_directory}/resolvconf-conf-changed"
  if [[ -f "${UNBOUND_RESOLVCONF_CONF}" && ! -L "${UNBOUND_RESOLVCONF_CONF}" ]]; then
    resolvconf_existed=1
    cp -a -- "${UNBOUND_RESOLVCONF_CONF}" "${temporary_directory}/resolvconf.conf.before"
  fi
  if [[ -f "${UNBOUND_RESOLVCONF_CONFIG}" && ! -L "${UNBOUND_RESOLVCONF_CONFIG}" ]]; then
    generated_existed=1
    cp -a -- "${UNBOUND_RESOLVCONF_CONFIG}" "${temporary_directory}/resolvconf_resolvers.conf.before"
  fi
  printf '%s\n' "${resolvconf_existed}" > "${temporary_directory}/resolvconf-conf-existed"
  printf '%s\n' "${generated_existed}" > "${temporary_directory}/resolvconf-generated-existed"
  unbound_save_service_state "${temporary_directory}/unbound-service" "${UNBOUND_SERVICE}"
  unbound_save_service_state "${temporary_directory}/resolvconf-service" "${UNBOUND_RESOLVCONF_SERVICE}"
  mv -- "${temporary_directory}" "${UNBOUND_STATE_DIR}"
  temporary_directory=""
)

unbound_validate_state() {
  [[ -d "${UNBOUND_STATE_DIR}" && ! -L "${UNBOUND_STATE_DIR}" ]] \
    || vps_die "Unbound bundle state is missing or unsafe: ${UNBOUND_STATE_DIR}"
  [[ -f "${UNBOUND_STATE_DIR}/state-version" \
    && "$(<"${UNBOUND_STATE_DIR}/state-version")" == "1" ]] \
    || vps_die "Unbound bundle state is incomplete or incompatible"
  unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-conf-existed" >/dev/null
  unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-conf-changed" >/dev/null
  unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-generated-existed" >/dev/null
  unbound_read_binary_state "${UNBOUND_STATE_DIR}/unbound-service/was-present" >/dev/null
  unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-service/was-present" >/dev/null
}

unbound_deactivate_resolvconf() {
  local already_changed=""
  local mode=""
  local temporary_file=""

  unbound_validate_state
  if [[ -e "${UNBOUND_RESOLVCONF_CONFIG}" ]]; then
    [[ "$(unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-generated-existed")" == "1" ]] \
      || vps_die "unexpected resolver-generated Unbound configuration appeared: ${UNBOUND_RESOLVCONF_CONFIG}"
    [[ ! -d "${UNBOUND_RESOLVCONF_CONFIG}" ]] \
      || vps_die "refusing to remove resolver-generated directory: ${UNBOUND_RESOLVCONF_CONFIG}"
    rm -f -- "${UNBOUND_RESOLVCONF_CONFIG}" || return 1
    printf 'Removed: %s\n' "${UNBOUND_RESOLVCONF_CONFIG}"
  fi
  if [[ -f "${UNBOUND_RESOLVCONF_CONF}" && ! -L "${UNBOUND_RESOLVCONF_CONF}" ]] \
    && [[ -n "$(unbound_resolvconf_targets)" ]]; then
    already_changed="$(unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-conf-changed")"
    [[ "${already_changed}" == "0" ]] \
      || vps_die "a new unbound_conf integration appeared after this bundle disabled the original"
    mode="$(stat -c '%a' "${UNBOUND_RESOLVCONF_CONF}")"
    temporary_file="$(mktemp "$(dirname "${UNBOUND_RESOLVCONF_CONF}")/.resolvconf.conf.XXXXXX")" \
      || return 1
    if ! awk '
        /^[[:space:]]*unbound_conf[[:space:]]*=/ {
          print "# Disabled by vpsfiles adguardhome-scripts: " $0
          next
        }
        { print }
      ' "${UNBOUND_RESOLVCONF_CONF}" > "${temporary_file}" \
      || ! chmod "${mode}" "${temporary_file}" \
      || ! chown --reference="${UNBOUND_RESOLVCONF_CONF}" "${temporary_file}"; then
      rm -f -- "${temporary_file}"
      return 1
    fi
    if ! cp -a -- "${temporary_file}" "${UNBOUND_STATE_DIR}/resolvconf.conf.managed" \
      || ! unbound_write_binary_state "${UNBOUND_STATE_DIR}/resolvconf-conf-changed" 1 \
      || ! mv -f -- "${temporary_file}" "${UNBOUND_RESOLVCONF_CONF}"; then
      rm -f -- "${temporary_file}"
      return 1
    fi
  fi
  systemctl stop "${UNBOUND_RESOLVCONF_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${UNBOUND_RESOLVCONF_SERVICE}" >/dev/null 2>&1 || true
  systemctl mask "${UNBOUND_RESOLVCONF_SERVICE}" >/dev/null
}

unbound_restore_file_atomically() {
  local backup="$1"
  local destination="$2"
  local temporary_file=""

  temporary_file="$(mktemp "$(dirname "${destination}")/.restore.XXXXXX")" || return 1
  if ! cp -a -- "${backup}" "${temporary_file}" \
    || ! mv -f -- "${temporary_file}" "${destination}"; then
    rm -f -- "${temporary_file}"
    return 1
  fi
}

unbound_restore_resolvconf() {
  local changed=""
  local generated_existed=""

  unbound_validate_state
  changed="$(unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-conf-changed")"
  generated_existed="$(unbound_read_binary_state "${UNBOUND_STATE_DIR}/resolvconf-generated-existed")"
  if [[ "${changed}" == "1" ]]; then
    if ! cmp -s -- "${UNBOUND_RESOLVCONF_CONF}" "${UNBOUND_STATE_DIR}/resolvconf.conf.before"; then
      [[ -f "${UNBOUND_STATE_DIR}/resolvconf.conf.managed" \
        && ! -L "${UNBOUND_STATE_DIR}/resolvconf.conf.managed" ]] \
        || vps_die "managed resolvconf state is missing or unsafe"
      cmp -s -- "${UNBOUND_RESOLVCONF_CONF}" "${UNBOUND_STATE_DIR}/resolvconf.conf.managed" \
        || vps_die "${UNBOUND_RESOLVCONF_CONF} changed after installation; refusing to overwrite it"
      unbound_restore_file_atomically \
        "${UNBOUND_STATE_DIR}/resolvconf.conf.before" "${UNBOUND_RESOLVCONF_CONF}" \
        || return 1
    fi
  fi
  if [[ "${generated_existed}" == "1" ]]; then
    install -d -m 755 "$(dirname "${UNBOUND_RESOLVCONF_CONFIG}")" || return 1
    unbound_restore_file_atomically \
      "${UNBOUND_STATE_DIR}/resolvconf_resolvers.conf.before" "${UNBOUND_RESOLVCONF_CONFIG}" \
      || return 1
  else
    [[ ! -e "${UNBOUND_RESOLVCONF_CONFIG}" ]] \
      || vps_die "unexpected ${UNBOUND_RESOLVCONF_CONFIG} appeared after installation"
  fi
}

unbound_query_udp() {
  [[ -n "$(dig @127.0.0.1 -p "${UNBOUND_PORT}" example.org A +notcp +time=5 +tries=1 +short)" ]]
}

unbound_query_tcp() {
  [[ -n "$(dig @127.0.0.1 -p "${UNBOUND_PORT}" example.org A +tcp +time=5 +tries=1 +short)" ]]
}

unbound_activate() {
  unbound_install_managed_config || return 20
  unbound-checkconf >/dev/null || return 20
  systemctl enable "${UNBOUND_SERVICE}" >/dev/null || return 21
  systemctl restart "${UNBOUND_SERVICE}" || return 21
  systemctl is-active --quiet "${UNBOUND_SERVICE}" || return 21
  unbound_query_udp || return 22
  unbound_query_tcp || return 23
}

unbound_activation_error() {
  case "$1" in
    20) printf '%s\n' 'Unbound configuration validation failed' ;;
    21) printf '%s\n' 'Unbound did not start successfully' ;;
    22) printf '%s\n' 'Unbound UDP recursion test failed' ;;
    23) printf '%s\n' 'Unbound TCP recursion test failed' ;;
    *) printf '%s\n' 'Unbound setup failed' ;;
  esac
}

unbound_restore_bundle_state() {
  [[ -e "${UNBOUND_STATE_DIR}" ]] || return 0
  unbound_validate_state
  systemctl stop "${UNBOUND_SERVICE}" >/dev/null 2>&1 || true
  unbound_remove_managed_config || return 1
  unbound_restore_resolvconf || return 1
  unbound_restore_service_state \
    "${UNBOUND_STATE_DIR}/unbound-service" "${UNBOUND_SERVICE}" || return 1
  unbound_restore_service_state \
    "${UNBOUND_STATE_DIR}/resolvconf-service" "${UNBOUND_RESOLVCONF_SERVICE}" || return 1
  rm -rf -- "${UNBOUND_STATE_DIR}" || return 1
  printf 'Removed: %s\n' "${UNBOUND_STATE_DIR}"
  vps_remove_empty_dir "$(dirname "${UNBOUND_STATE_DIR}")"
}
