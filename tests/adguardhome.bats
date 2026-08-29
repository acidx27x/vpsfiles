#!/usr/bin/env bats

load test_helper

setup() {
  load_core
  # shellcheck source=adguardhome-scripts/adguardhome.sh
  . "${REPO_ROOT}/adguardhome-scripts/adguardhome.sh"
  # shellcheck source=adguardhome-scripts/unbound.sh
  . "${REPO_ROOT}/adguardhome-scripts/unbound.sh"
  make_temp_dir
}

teardown() {
  remove_temp_dir
}

write_release_metadata() {
  local output="$1"
  local tag="${2:-v0.107.79}"
  local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  cat > "${output}" <<EOF
{
  "tag_name": "${tag}",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "AdGuardHome_linux_amd64.tar.gz",
      "browser_download_url": "https://github.com/AdguardTeam/AdGuardHome/releases/download/${tag}/AdGuardHome_linux_amd64.tar.gz",
      "digest": "${digest}"
    }
  ]
}
EOF
}

@test "adguardhome accepts latest and exact stable versions only" {
  run adguardhome_validate_version latest
  [ "${status}" -eq 0 ]
  run adguardhome_validate_version v0.107.79
  [ "${status}" -eq 0 ]

  run adguardhome_validate_version beta
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"latest or a stable tag"* ]]
  run adguardhome_validate_version v0.108.0-b.1
  [ "${status}" -ne 0 ]
}

@test "adguardhome maps supported Linux release architectures" {
  run adguardhome_architecture x86_64
  [ "${status}" -eq 0 ]
  [ "${output}" = "amd64" ]
  run adguardhome_architecture aarch64
  [ "${status}" -eq 0 ]
  [ "${output}" = "arm64" ]
  run adguardhome_architecture armv7l
  [ "${status}" -eq 0 ]
  [ "${output}" = "armv7" ]
  run adguardhome_architecture unknown-cpu
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unsupported AdGuard Home CPU architecture"* ]]
}

@test "adguardhome selects one stable release and its exact architecture asset" {
  local metadata="${TEST_TMPDIR}/release.json"
  local digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  write_release_metadata "${metadata}"

  run adguardhome_release_version "${metadata}" latest
  [ "${status}" -eq 0 ]
  [ "${output}" = "v0.107.79" ]
  run adguardhome_release_version "${metadata}" v0.107.79
  [ "${status}" -eq 0 ]
  [ "${output}" = "v0.107.79" ]
  run adguardhome_release_asset "${metadata}" amd64
  [ "${status}" -eq 0 ]
  [ "${output}" = $'https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.79/AdGuardHome_linux_amd64.tar.gz\t'"${digest}" ]
}

@test "adguardhome rejects mismatched prerelease and incomplete metadata" {
  local metadata="${TEST_TMPDIR}/release.json"
  write_release_metadata "${metadata}"

  run adguardhome_release_version "${metadata}" v0.107.78
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected v0.107.78"* ]]

  sed -i 's/"prerelease": false/"prerelease": true/' "${metadata}"
  run adguardhome_release_version "${metadata}" latest
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid or unstable"* ]]

  write_release_metadata "${metadata}"
  sed -i 's/sha256:[a-f0-9]*/sha256:short/' "${metadata}"
  run adguardhome_release_asset "${metadata}" amd64
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"valid SHA-256 digest"* ]]
}

@test "adguardhome verifies archive SHA-256 digests" {
  local archive="${TEST_TMPDIR}/archive"
  printf 'hello' > "${archive}"

  run adguardhome_verify_sha256 \
    "${archive}" \
    "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  [ "${status}" -eq 0 ]
  run adguardhome_verify_sha256 \
    "${archive}" \
    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"verification failed"* ]]
}

@test "adguardhome rejects unsafe or ambiguous archive layouts" {
  local listing="${TEST_TMPDIR}/archive.list"

  printf '%s\n' AdGuardHome/ AdGuardHome/AdGuardHome AdGuardHome/LICENSE.txt > "${listing}"
  run adguardhome_validate_archive_listing "${listing}"
  [ "${status}" -eq 0 ]

  printf '%s\n' AdGuardHome/AdGuardHome ../outside > "${listing}"
  run adguardhome_validate_archive_listing "${listing}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unsafe path"* ]]

  printf '%s\n' AdGuardHome/AdGuardHome AdGuardHome/AdGuardHome > "${listing}"
  run adguardhome_validate_archive_listing "${listing}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"invalid binary layout"* ]]
}

@test "adguardhome reads and validates the installed binary version" {
  local binary="${TEST_TMPDIR}/AdGuardHome"
  cat > "${binary}" <<'EOF'
#!/usr/bin/env bash
printf 'AdGuard Home, version v0.107.79\n'
EOF
  chmod +x "${binary}"

  run adguardhome_version_from_binary "${binary}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "v0.107.79" ]
}

@test "adguardhome scripts keep firewall host DNS and other bundles out of scope" {
  local script=""

  for script in install.sh update.sh uninstall.sh; do
    run grep -E 'ufw|/etc/resolv\.conf|/etc/systemd/resolved\.conf' \
      "${REPO_ROOT}/adguardhome-scripts/${script}"
    [ "${status}" -eq 1 ]
  done
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/install.sh" \
    '"${ADGUARD_HOME_BIN}" -s install --web-addr "${ADGUARD_HOME_WEB_ADDR}"'
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/uninstall.sh" \
    'Retained configuration/data remains under %s and will be reused by install.sh.'
}

@test "adguardhome rollback restores binary and config without starting an inactive service" {
  local backup_binary="${TEST_TMPDIR}/backup-binary"
  local backup_config="${TEST_TMPDIR}/backup-config"
  local binary="${TEST_TMPDIR}/AdGuardHome"
  local config="${TEST_TMPDIR}/AdGuardHome.yaml"
  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl"
  PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
  SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  export SYSTEMCTL_LOG
  printf 'old-binary' > "${backup_binary}"
  printf 'old-config' > "${backup_config}"
  printf 'new-binary' > "${binary}"
  printf 'new-config' > "${config}"
  chmod +x "${backup_binary}" "${binary}"
  # shellcheck source=adguardhome-scripts/update.sh
  . "${REPO_ROOT}/adguardhome-scripts/update.sh"

  run adguardhome_restore_release \
    "${backup_binary}" "${backup_config}" "${binary}" "${config}" AdGuardHome 0
  [ "${status}" -eq 0 ]
  [ "$(<"${binary}")" = "old-binary" ]
  [ "$(<"${config}")" = "old-config" ]
  assert_file_contains "${SYSTEMCTL_LOG}" 'stop AdGuardHome'
  assert_file_not_contains "${SYSTEMCTL_LOG}" 'start AdGuardHome'
}

@test "unbound renders the exact loopback-only recursive configuration" {
  local expected=""
  expected=$'server:\n    interface: 127.0.0.1@5335\n    access-control: 127.0.0.0/8 allow\n    do-ip4: yes\n    do-ip6: no\n    do-udp: yes\n    do-tcp: yes\n    hide-identity: yes\n    hide-version: yes\n    edns-buffer-size: 1232\n    prefetch: yes'

  run unbound_render_config
  [ "${status}" -eq 0 ]
  [ "${output}" = "${expected}" ]
  [[ "${output}" != *"forward-zone"* ]]
  [[ "${output}" != *"forward-addr"* ]]
  [[ "${output}" != *"1.1.1.1"* ]]
  [[ "${output}" != *"8.8.8.8"* ]]
  [[ "${output}" != *"9.9.9.9"* ]]
}

@test "unbound rejects a TCP or UDP conflict on its loopback port" {
  ss() {
    if [[ "$*" == *"-ltn"* ]]; then
      printf 'LISTEN 0 4096 127.0.0.1:5335 0.0.0.0:*\n'
    fi
  }

  run unbound_loopback_port_is_available
  [ "${status}" -ne 0 ]

  ss() {
    if [[ "$*" == *"-lun"* ]]; then
      printf 'UNCONN 0 0 0.0.0.0:5335 0.0.0.0:*\n'
    fi
  }
  run unbound_loopback_port_is_available
  [ "${status}" -ne 0 ]
}

@test "unbound preflight rejects active and custom existing resolvers" {
  UNBOUND_ETC_DIR="${TEST_TMPDIR}/etc/unbound"
  UNBOUND_MANAGED_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/vpsfiles-adguardhome.conf"
  UNBOUND_RESOLVCONF_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/resolvconf_resolvers.conf"
  UNBOUND_RESOLVCONF_CONF="${TEST_TMPDIR}/etc/resolvconf.conf"
  UNBOUND_STATE_DIR="${TEST_TMPDIR}/state/unbound"
  mkdir -p "${UNBOUND_ETC_DIR}"
  ss() { return 0; }
  systemctl() {
    [[ "$1" == "is-active" ]]
  }

  run unbound_preflight
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"active Unbound service"* ]]

  systemctl() { return 1; }
  dpkg-query() { return 1; }
  printf 'server:\n    interface: 192.0.2.1\n' > "${UNBOUND_ETC_DIR}/custom.conf"
  run unbound_preflight
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"custom Unbound configuration"* ]]

  rm -f "${UNBOUND_ETC_DIR}/custom.conf"
  mkdir -p "$(dirname "${UNBOUND_RESOLVCONF_CONFIG}")"
  printf 'forward-zone:\n' > "${UNBOUND_RESOLVCONF_CONFIG}"
  run unbound_preflight
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"is not explained by unbound_conf"* ]]
}

@test "unbound disables and restores resolvconf integration and service state" {
  UNBOUND_ETC_DIR="${TEST_TMPDIR}/etc/unbound"
  UNBOUND_MANAGED_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/vpsfiles-adguardhome.conf"
  UNBOUND_RESOLVCONF_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/resolvconf_resolvers.conf"
  UNBOUND_RESOLVCONF_CONF="${TEST_TMPDIR}/etc/resolvconf.conf"
  UNBOUND_STATE_DIR="${TEST_TMPDIR}/state/unbound"
  SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  export SYSTEMCTL_LOG
  mkdir -p "$(dirname "${UNBOUND_RESOLVCONF_CONFIG}")"
  printf 'name_servers=127.0.0.1\nunbound_conf=%s\n' \
    "${UNBOUND_RESOLVCONF_CONFIG}" > "${UNBOUND_RESOLVCONF_CONF}"
  printf 'forward-zone:\n    name: .\n' > "${UNBOUND_RESOLVCONF_CONFIG}"
  cp "${UNBOUND_RESOLVCONF_CONF}" "${TEST_TMPDIR}/resolvconf.before"
  cp "${UNBOUND_RESOLVCONF_CONFIG}" "${TEST_TMPDIR}/generated.before"
  systemctl() {
    printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
    case "$1" in
      cat) return 0 ;;
      is-active) return 1 ;;
      is-enabled) printf 'disabled\n'; return 1 ;;
      *) return 0 ;;
    esac
  }

  unbound_initialize_state
  unbound_deactivate_resolvconf
  assert_file_contains "${UNBOUND_RESOLVCONF_CONF}" \
    '# Disabled by vpsfiles adguardhome-scripts: unbound_conf='
  [ ! -e "${UNBOUND_RESOLVCONF_CONFIG}" ]
  assert_file_contains "${SYSTEMCTL_LOG}" "stop ${UNBOUND_RESOLVCONF_SERVICE}"
  assert_file_contains "${SYSTEMCTL_LOG}" "disable ${UNBOUND_RESOLVCONF_SERVICE}"
  assert_file_contains "${SYSTEMCTL_LOG}" "mask ${UNBOUND_RESOLVCONF_SERVICE}"

  unbound_restore_bundle_state
  cmp -s "${UNBOUND_RESOLVCONF_CONF}" "${TEST_TMPDIR}/resolvconf.before"
  cmp -s "${UNBOUND_RESOLVCONF_CONFIG}" "${TEST_TMPDIR}/generated.before"
  [ ! -e "${UNBOUND_STATE_DIR}" ]
  assert_file_contains "${SYSTEMCTL_LOG}" "unmask ${UNBOUND_RESOLVCONF_SERVICE}"
}

@test "unbound distinguishes configuration startup UDP and TCP failures" {
  UNBOUND_ETC_DIR="${TEST_TMPDIR}/etc/unbound"
  UNBOUND_MANAGED_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/vpsfiles-adguardhome.conf"
  UNBOUND_RESOLVCONF_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/resolvconf_resolvers.conf"
  UNBOUND_RESOLVCONF_CONF="${TEST_TMPDIR}/etc/resolvconf.conf"
  UNBOUND_STATE_DIR="${TEST_TMPDIR}/state/unbound"
  mkdir -p "$(dirname "${UNBOUND_MANAGED_CONFIG}")"
  unbound-checkconf() {
    [[ "${FAIL_STAGE}" != "config" ]]
  }
  systemctl() {
    if [[ "$1" == "restart" && "${FAIL_STAGE}" == "startup" ]]; then
      return 1
    fi
    return 0
  }
  dig() {
    if [[ "${FAIL_STAGE}" == "udp" && "$*" == *"+notcp"* ]]; then
      return 1
    fi
    if [[ "${FAIL_STAGE}" == "tcp" && "$*" == *"+tcp"* ]]; then
      return 1
    fi
    printf '192.0.2.1\n'
  }

  FAIL_STAGE=none
  unbound_initialize_state
  FAIL_STAGE=config
  run unbound_activate
  [ "${status}" -eq 20 ]
  unbound_restore_bundle_state
  [ ! -e "${UNBOUND_MANAGED_CONFIG}" ]
  [ ! -e "${UNBOUND_STATE_DIR}" ]

  unbound_initialize_state
  FAIL_STAGE=startup
  run unbound_activate
  [ "${status}" -eq 21 ]
  unbound_restore_bundle_state
  [ ! -e "${UNBOUND_MANAGED_CONFIG}" ]
  [ ! -e "${UNBOUND_STATE_DIR}" ]

  unbound_initialize_state
  FAIL_STAGE=udp
  run unbound_activate
  [ "${status}" -eq 22 ]
  unbound_restore_bundle_state
  [ ! -e "${UNBOUND_MANAGED_CONFIG}" ]
  [ ! -e "${UNBOUND_STATE_DIR}" ]

  unbound_initialize_state
  FAIL_STAGE=tcp
  run unbound_activate
  [ "${status}" -eq 23 ]
  unbound_restore_bundle_state
  [ ! -e "${UNBOUND_MANAGED_CONFIG}" ]
  [ ! -e "${UNBOUND_STATE_DIR}" ]
}

@test "unbound update preserves stopped state and validates active UDP and TCP" {
  UNBOUND_ETC_DIR="${TEST_TMPDIR}/etc/unbound"
  UNBOUND_MANAGED_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/vpsfiles-adguardhome.conf"
  UNBOUND_RESOLVCONF_CONFIG="${UNBOUND_ETC_DIR}/unbound.conf.d/resolvconf_resolvers.conf"
  UNBOUND_RESOLVCONF_CONF="${TEST_TMPDIR}/etc/resolvconf.conf"
  UNBOUND_STATE_DIR="${TEST_TMPDIR}/state/unbound"
  SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  DIG_LOG="${TEST_TMPDIR}/dig.log"
  export SYSTEMCTL_LOG DIG_LOG
  systemctl() {
    printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
    case "$1" in
      cat) return 0 ;;
      is-enabled) printf 'disabled\n'; return 1 ;;
      *) return 0 ;;
    esac
  }
  unbound-checkconf() { return 0; }
  dig() {
    printf '%s\n' "$*" >> "${DIG_LOG}"
    printf '192.0.2.1\n'
  }
  unbound_initialize_state
  # shellcheck source=adguardhome-scripts/update.sh
  . "${REPO_ROOT}/adguardhome-scripts/update.sh"

  unbound_update_runtime 0
  assert_file_contains "${SYSTEMCTL_LOG}" "stop ${UNBOUND_SERVICE}"
  [ ! -e "${DIG_LOG}" ]

  : > "${SYSTEMCTL_LOG}"
  unbound_update_runtime 1
  assert_file_contains "${SYSTEMCTL_LOG}" "restart ${UNBOUND_SERVICE}"
  assert_file_contains "${DIG_LOG}" '+notcp'
  assert_file_contains "${DIG_LOG}" '+tcp'
}

@test "adguardhome uninstall removes only managed Unbound state and retains packages" {
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/install.sh" \
    'trap cleanup_install EXIT'
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/install.sh" \
    'unbound_restore_bundle_state'
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/uninstall.sh" \
    'unbound_restore_bundle_state'
  assert_file_contains "${REPO_ROOT}/adguardhome-scripts/uninstall.sh" \
    'Unbound, dns-root-data, and dnsutils packages were retained.'
  assert_file_not_contains "${REPO_ROOT}/adguardhome-scripts/uninstall.sh" \
    'apt-get remove'
}
