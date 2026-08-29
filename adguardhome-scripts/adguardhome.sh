#!/usr/bin/env bash

[[ -n "${VPS_ADGUARDHOME_SH:-}" ]] && return 0
VPS_ADGUARDHOME_SH=1

ADGUARD_HOME_GITHUB_REPOSITORY="AdguardTeam/AdGuardHome"

adguardhome_validate_version() {
  local version="$1"

  [[ "${version}" == "latest" || "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || vps_die "ADGUARD_HOME_VERSION must be latest or a stable tag such as v0.107.79"
}

adguardhome_architecture() {
  local machine="${1:-$(uname -m)}"

  case "${machine}" in
    x86_64|x86-64|x64|amd64) printf '%s\n' amd64 ;;
    i386|i486|i586|i686|i786|x86) printf '%s\n' 386 ;;
    armv5l) printf '%s\n' armv5 ;;
    armv6l) printf '%s\n' armv6 ;;
    armv7l|armv8l) printf '%s\n' armv7 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    riscv64) printf '%s\n' riscv64 ;;
    *) vps_die "unsupported AdGuard Home CPU architecture: ${machine}" ;;
  esac
}

adguardhome_release_api_url() {
  local requested="$1"

  adguardhome_validate_version "${requested}"
  if [[ "${requested}" == "latest" ]]; then
    printf 'https://api.github.com/repos/%s/releases/latest\n' "${ADGUARD_HOME_GITHUB_REPOSITORY}"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' \
      "${ADGUARD_HOME_GITHUB_REPOSITORY}" "${requested}"
  fi
}

adguardhome_fetch_release() {
  local requested="$1"
  local output="$2"
  local api_url=""

  [[ "${output}" == /* && "${output}" != "/" ]] || vps_die "unsafe AdGuard Home metadata path: ${output}"
  api_url="$(adguardhome_release_api_url "${requested}")"
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${api_url}" \
    -o "${output}" \
    || vps_die "could not resolve AdGuard Home ${requested} from GitHub"
}

adguardhome_release_version() {
  local metadata="$1"
  local requested="$2"
  local version=""

  [[ -f "${metadata}" ]] || vps_die "AdGuard Home release metadata is missing"
  adguardhome_validate_version "${requested}"
  version="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "${metadata}")" \
    || vps_die "GitHub returned an invalid or unstable AdGuard Home release"
  adguardhome_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "GitHub returned an invalid AdGuard Home release tag"
  if [[ "${requested}" != "latest" && "${version}" != "${requested}" ]]; then
    vps_die "GitHub returned AdGuard Home ${version}, expected ${requested}"
  fi
  printf '%s\n' "${version}"
}

adguardhome_release_asset() {
  local metadata="$1"
  local architecture="$2"
  local asset_name="AdGuardHome_linux_${architecture}.tar.gz"
  local asset=""
  local digest=""
  local url=""

  [[ -f "${metadata}" ]] || vps_die "AdGuard Home release metadata is missing"
  asset="$(jq -er --arg name "${asset_name}" '
    [.assets[]? | select(.name == $name)]
    | select(length == 1)
    | .[0]
    | [.browser_download_url, .digest]
    | @tsv
  ' "${metadata}")" || vps_die "AdGuard Home release is missing ${asset_name}"
  IFS=$'\t' read -r url digest <<< "${asset}"
  [[ "${url}" == "https://github.com/${ADGUARD_HOME_GITHUB_REPOSITORY}/releases/download/"*"/${asset_name}" ]] \
    || vps_die "GitHub returned an unsafe AdGuard Home asset URL"
  [[ "${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]] \
    || vps_die "AdGuard Home release asset is missing a valid SHA-256 digest"
  printf '%s\t%s\n' "${url}" "${digest,,}"
}

adguardhome_resolve_version() (
  set -euo pipefail
  local requested="$1"
  local temp_dir=""
  local metadata=""

  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  metadata="${temp_dir}/release.json"
  adguardhome_fetch_release "${requested}" "${metadata}"
  adguardhome_release_version "${metadata}" "${requested}"
)

adguardhome_verify_sha256() {
  local file="$1"
  local digest="$2"
  local actual=""
  local expected=""

  [[ -f "${file}" ]] || vps_die "AdGuard Home archive is missing"
  [[ "${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || vps_die "invalid AdGuard Home SHA-256 digest"
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  expected="${digest#sha256:}"
  [[ "${actual,,}" == "${expected,,}" ]] || vps_die "AdGuard Home archive SHA-256 verification failed"
}

adguardhome_validate_archive_listing() {
  local listing="$1"
  local binary_count=""

  [[ -s "${listing}" ]] || vps_die "AdGuard Home release archive is empty"
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "${listing}"; then
    vps_die "AdGuard Home release archive contains an unsafe path"
  fi
  binary_count="$(grep -Fxc './AdGuardHome/AdGuardHome' "${listing}" || true)"
  [[ "${binary_count}" -eq 1 ]] \
    || vps_die "AdGuard Home release archive must contain exactly one AdGuardHome/AdGuardHome binary"
}

adguardhome_version_from_binary() {
  local binary="$1"
  local output=""
  local version=""

  [[ -x "${binary}" && ! -L "${binary}" ]] || vps_die "AdGuard Home binary is missing or unsafe: ${binary}"
  output="$("${binary}" --version)" || vps_die "AdGuard Home binary failed version validation"
  version="$(sed -nE 's/.*(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<< "${output}" | head -n 1)"
  adguardhome_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "AdGuard Home binary returned an invalid version"
  printf '%s\n' "${version}"
}

adguardhome_download_binary() (
  set -euo pipefail
  local version="$1"
  local destination="$2"
  local architecture=""
  local archive=""
  local asset=""
  local digest=""
  local extracted=""
  local installed_version=""
  local listing=""
  local metadata=""
  local temp_dir=""
  local url=""

  adguardhome_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "resolve latest before downloading AdGuard Home"
  [[ "${destination}" == /* && "${destination}" != "/" ]] || vps_die "unsafe AdGuard Home binary destination: ${destination}"

  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  metadata="${temp_dir}/release.json"
  archive="${temp_dir}/adguardhome.tar.gz"
  listing="${temp_dir}/archive.list"
  extracted="${temp_dir}/extracted"
  architecture="$(adguardhome_architecture)"

  adguardhome_fetch_release "${version}" "${metadata}"
  [[ "$(adguardhome_release_version "${metadata}" "${version}")" == "${version}" ]] \
    || vps_die "resolved AdGuard Home release changed unexpectedly"
  asset="$(adguardhome_release_asset "${metadata}" "${architecture}")"
  IFS=$'\t' read -r url digest <<< "${asset}"
  curl -fsSL "${url}" -o "${archive}" || vps_die "could not download AdGuard Home ${version}"
  adguardhome_verify_sha256 "${archive}" "${digest}"
  tar -tzf "${archive}" > "${listing}" || vps_die "AdGuard Home release archive is invalid"
  adguardhome_validate_archive_listing "${listing}"

  install -d -m 700 "${extracted}"
  tar -xzf "${archive}" \
    -C "${extracted}" \
    --transform='s|.*/||' \
    --no-same-owner \
    --no-same-permissions \
    ./AdGuardHome/AdGuardHome \
    || vps_die "could not extract the AdGuard Home binary"
  [[ -f "${extracted}/AdGuardHome" && ! -L "${extracted}/AdGuardHome" ]] \
    || vps_die "AdGuard Home release binary is missing or unsafe"
  install -m 755 "${extracted}/AdGuardHome" "${destination}"
  installed_version="$(adguardhome_version_from_binary "${destination}")"
  [[ "${installed_version}" == "${version}" ]] \
    || vps_die "AdGuard Home binary version ${installed_version} does not match ${version}"
)

adguardhome_check_config() {
  local binary="$1"
  local install_dir="$2"

  [[ -x "${binary}" ]] || return 1
  [[ -f "${install_dir}/AdGuardHome.yaml" ]] || return 1
  (cd "${install_dir}" && "${binary}" --check-config)
}

adguardhome_wait_for_web() {
  local web_addr="$1"
  local attempt=0

  while (( attempt < 15 )); do
    if curl -fsS --max-time 2 "http://${web_addr}/" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}
