#!/usr/bin/env bats

load test_helper

setup() {
  load_core
  # shellcheck source=adguardhome-scripts/adguardhome.sh
  . "${REPO_ROOT}/adguardhome-scripts/adguardhome.sh"
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
