#!/usr/bin/env bash

[[ -n "${VPS_TG_WS_SH:-}" ]] && return 0
VPS_TG_WS_SH=1

TG_WS_GITHUB_REPOSITORY="Flowseal/tg-ws-proxy"
TG_WS_BUNDLE_LABEL="io.vpsfiles.bundle=tg-ws-proxy"
TG_WS_DC_IPS_DEFAULT="2:149.154.167.220 4:149.154.167.220"

tg_ws_validate_version() {
  local version="$1"

  [[ "${version}" == "latest" || "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || vps_die "TG_WS_PROXY_VERSION must be latest or a stable tag such as v1.8.1"
}

tg_ws_validate_secret() {
  local secret="$1"

  [[ "${secret}" =~ ^[0-9A-Fa-f]{32}$ ]] || vps_die "tg-ws-proxy secret must contain exactly 32 hexadecimal characters"
}

tg_ws_validate_ipv4() {
  local address="$1"
  local octet=""
  local -a octets=()

  [[ "${address}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || vps_die "public IPv4 address is invalid: ${address}"
  IFS='.' read -r -a octets <<< "${address}"
  for octet in "${octets[@]}"; do
    (( 10#${octet} <= 255 )) || vps_die "public IPv4 address is invalid: ${address}"
  done
}

tg_ws_validate_ipv6() {
  local address="$1"

  [[ "${address}" == *:* && "${address}" =~ ^[0-9A-Fa-f:]+$ ]] || vps_die "public IPv6 address is invalid: ${address}"
}

tg_ws_validate_optional_ipv6() {
  local address="$1"

  [[ -z "${address}" ]] || tg_ws_validate_ipv6 "${address}"
}

tg_ws_require_local_global_ipv6() {
  local address="$1"

  [[ -z "${address}" ]] && return 0
  tg_ws_validate_ipv6 "${address}"
  ip -6 -o address show scope global \
    | awk -v address="${address}" '$4 == address "/128" || index($4, address "/") == 1 {found = 1} END {exit !found}' \
    || vps_die "public IPv6 address is not assigned globally on this VPS: ${address}"
}

tg_ws_validate_public_host() {
  local host="$1"

  [[ -n "${host}" && ${#host} -le 253 ]] || vps_die "public Telegram endpoint is empty or too long"
  if [[ "${host}" == *:* ]]; then
    tg_ws_validate_ipv6 "${host}"
  else
    [[ "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || vps_die "public Telegram endpoint contains unsafe characters"
  fi
}

tg_ws_validate_domain() {
  local domain="$1"
  local description="${2:-domain}"
  local label=""
  local -a labels=()

  [[ -z "${domain}" ]] && return 0
  [[ ${#domain} -le 253 && "${domain}" == *.* && "${domain}" != *. ]] || vps_die "${description} is invalid"
  IFS='.' read -r -a labels <<< "${domain}"
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
      || vps_die "${description} contains an invalid DNS label: ${label}"
  done
}

tg_ws_resolve_version() {
  local requested="$1"
  local version=""

  tg_ws_validate_version "${requested}"
  if [[ "${requested}" != "latest" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  if ! version="$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${TG_WS_GITHUB_REPOSITORY}/releases/latest" \
    | jq -r '.tag_name // empty')"; then
    vps_die "could not resolve the latest tg-ws-proxy release from GitHub"
  fi
  tg_ws_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "GitHub returned an invalid tg-ws-proxy release"
  printf '%s\n' "${version}"
}

tg_ws_download_source() {
  local version="$1"
  local destination="$2"
  local archive=""
  local archive_list=""
  local source_version=""

  tg_ws_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "resolve latest before downloading tg-ws-proxy"
  [[ "${destination}" == /* && "${destination}" != "/" && ! -e "${destination}" ]] \
    || vps_die "tg-ws-proxy source destination is unsafe or already exists: ${destination}"

  archive="$(mktemp --suffix=.tar.gz)"
  archive_list="$(mktemp)"
  if ! curl -fL \
    "https://github.com/${TG_WS_GITHUB_REPOSITORY}/archive/refs/tags/${version}.tar.gz" \
    -o "${archive}"; then
    rm -f -- "${archive}" "${archive_list}"
    vps_die "could not download tg-ws-proxy ${version}"
  fi
  if ! tar -tzf "${archive}" > "${archive_list}"; then
    rm -f -- "${archive}" "${archive_list}"
    vps_die "tg-ws-proxy release archive is invalid"
  fi
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "${archive_list}"; then
    rm -f -- "${archive}" "${archive_list}"
    vps_die "tg-ws-proxy release archive contains an unsafe path"
  fi
  rm -f -- "${archive_list}"

  mkdir -p "${destination}"
  if ! tar -xzf "${archive}" -C "${destination}" --strip-components=1; then
    rm -f -- "${archive}"
    rm -rf -- "${destination}"
    vps_die "tg-ws-proxy release archive is invalid"
  fi
  rm -f -- "${archive}"

  [[ -f "${destination}/Dockerfile" && -f "${destination}/proxy/tg_ws_proxy.py" && -f "${destination}/proxy/__init__.py" ]] \
    || vps_die "tg-ws-proxy release is missing required Docker source files"
  source_version="$(sed -n 's/^__version__ = "\([^"]*\)"$/v\1/p' "${destination}/proxy/__init__.py" | head -n 1)"
  [[ "${source_version}" == "${version}" ]] || vps_die "tg-ws-proxy source version ${source_version:-unknown} does not match ${version}"
}

tg_ws_image_ref() {
  local version="$1"
  local image_repository="$2"

  tg_ws_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "image references require a resolved tg-ws-proxy version"
  [[ "${image_repository}" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || vps_die "tg-ws-proxy image repository is invalid"
  printf '%s:%s\n' "${image_repository}" "${version}"
}

tg_ws_cleanup_old_images() {
  if ! docker image prune \
    --all \
    --force \
    --filter "label=${TG_WS_BUNDLE_LABEL}"; then
    printf 'WARNING: tg-ws-proxy was updated, but unused old bundle images could not be removed.\n' >&2
  fi
}

tg_ws_build_image() {
  local source_directory="$1"
  local version="$2"
  local image_repository="$3"
  local image=""

  tg_ws_validate_version "${version}"
  [[ "${version}" != "latest" ]] || vps_die "image builds require a resolved tg-ws-proxy version"
  [[ -f "${source_directory}/Dockerfile" ]] || vps_die "tg-ws-proxy Dockerfile is missing: ${source_directory}"
  image="$(tg_ws_image_ref "${version}" "${image_repository}")"
  docker build \
    --pull \
    --label "${TG_WS_BUNDLE_LABEL}" \
    --label "org.opencontainers.image.source=https://github.com/${TG_WS_GITHUB_REPOSITORY}" \
    --label "org.opencontainers.image.version=${version}" \
    --tag "${image}" \
    "${source_directory}"
}

tg_ws_validate_image() {
  local image="$1"
  local help_output=""
  local image_user=""
  local option=""

  if ! help_output="$(docker run --rm "${image}" --no-cfproxy --help 2>&1)"; then
    vps_die "tg-ws-proxy image failed its command-line validation"
  fi
  for option in --host --secret --cfproxy-worker-domain --fake-tls-domain --no-cfproxy; do
    [[ "${help_output}" == *"${option}"* ]] || vps_die "tg-ws-proxy image does not support required option: ${option}"
  done
  image_user="$(docker image inspect --format '{{.Config.User}}' "${image}")"
  [[ -n "${image_user}" && "${image_user}" != "0" && "${image_user}" != "root" ]] \
    || vps_die "tg-ws-proxy image must run as a non-root user"
}

tg_ws_write_env() {
  local compose_directory="$1"
  local image="$2"
  local version="$3"
  local public_host="$4"
  local ipv4="$5"
  local ipv6="$6"
  local port="$7"
  local secret="$8"
  local worker_domain="$9"
  local fake_tls_domain="${10:-}"
  local temp_file=""

  worker_domain="${worker_domain,,}"
  fake_tls_domain="${fake_tls_domain,,}"
  tg_ws_validate_version "${version}"
  tg_ws_validate_public_host "${public_host}"
  tg_ws_validate_ipv4 "${ipv4}"
  tg_ws_validate_optional_ipv6 "${ipv6}"
  vps_validate_port "${port}"
  tg_ws_validate_secret "${secret}"
  tg_ws_validate_domain "${worker_domain}" "Cloudflare Worker domain"
  tg_ws_validate_domain "${fake_tls_domain}" "FakeTLS/SNI domain"
  [[ "${compose_directory}" == /* && "${compose_directory}" != "/" && -d "${compose_directory}" ]] \
    || vps_die "tg-ws-proxy Compose directory is missing or unsafe"

  temp_file="$(mktemp "${compose_directory}/.env.XXXXXX")"
  printf '%s\n' \
    "TG_WS_PROXY_IMAGE=${image}" \
    "TG_WS_PROXY_VERSION=${version}" \
    "TG_WS_PROXY_PUBLIC_HOST=${public_host}" \
    "TG_WS_PROXY_PUBLIC_IPV4=${ipv4}" \
    "TG_WS_PROXY_IPV6=${ipv6}" \
    "COMPOSE_PROFILES=${ipv6:+ipv6}" \
    "TG_WS_PROXY_PORT=${port}" \
    "TG_WS_PROXY_SECRET=${secret}" \
    "TG_WS_PROXY_DC_IPS='${TG_WS_DC_IPS_DEFAULT}'" \
    "TG_WS_PROXY_FAKE_TLS_DOMAIN=${fake_tls_domain}" \
    "TG_WS_PROXY_CF_WORKER=${worker_domain}" > "${temp_file}"
  install -m 600 "${temp_file}" "${compose_directory}/.env"
  rm -f -- "${temp_file}"
}

tg_ws_env_get() {
  local env_file="$1"
  local key="$2"
  local value=""

  [[ "${key}" =~ ^[A-Z0-9_]+$ ]] || vps_die "tg-ws-proxy environment key is invalid"
  [[ -f "${env_file}" ]] || vps_die "tg-ws-proxy environment file is missing: ${env_file}"
  value="$(awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${env_file}")"
  value="${value#\'}"
  value="${value%\'}"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "${value}"
}

tg_ws_client_url() {
  local public_host="$1"
  local port="$2"
  local secret="$3"
  local fake_tls_domain="${4:-}"
  local domain_hex=""
  local encoded_host=""
  local transport_prefix="dd"

  fake_tls_domain="${fake_tls_domain,,}"
  tg_ws_validate_public_host "${public_host}"
  vps_validate_port "${port}"
  tg_ws_validate_secret "${secret}"
  tg_ws_validate_domain "${fake_tls_domain}" "FakeTLS/SNI domain"
  encoded_host="$(vps_url_encode "${public_host}")"
  if [[ -n "${fake_tls_domain}" ]]; then
    domain_hex="$(printf '%s' "${fake_tls_domain}" | LC_ALL=C od -An -v -tx1 | tr -d '[:space:]')"
    transport_prefix="ee"
  fi
  printf 'tg://proxy?server=%s&port=%s&secret=%s%s%s\n' \
    "${encoded_host}" "${port}" "${transport_prefix}" "${secret,,}" "${domain_hex}"
}

tg_ws_render_worker() {
  local template="$1"
  local ipv4="$2"
  local ipv6="$3"

  [[ -f "${template}" ]] || vps_die "Cloudflare Worker template is missing: ${template}"
  tg_ws_validate_ipv4 "${ipv4}"
  tg_ws_validate_optional_ipv6 "${ipv6}"
  if [[ -z "${ipv6}" ]]; then
    sed \
      -e "s|:VPS_IPV4:|${ipv4}|g" \
      -e '/:VPS_IPV6:/d' \
      "${template}"
  else
    sed \
      -e "s|:VPS_IPV4:|${ipv4}|g" \
      -e "s|:VPS_IPV6:|${ipv6}|g" \
      "${template}"
  fi
}

tg_ws_require_port_available() {
  local port="$1"
  local listeners=""

  vps_validate_port "${port}"
  listeners="$(ss -H -ltn "sport = :${port}" 2>/dev/null || true)"
  [[ -z "${listeners}" ]] || vps_die "TCP port ${port} is already in use"
}

tg_ws_project_state() {
  local compose_directory="$1"
  local project="$2"
  local ipv6="$3"
  local ipv4_id=""
  local ipv6_id=""
  local ipv4_running=""
  local ipv6_running=""

  ipv4_id="$(vps_docker_compose "${compose_directory}" "${project}" ps --all --quiet proxy-ipv4)"
  if [[ -n "${ipv6}" ]]; then
    ipv6_id="$(vps_docker_compose "${compose_directory}" "${project}" ps --all --quiet proxy-ipv6)"
  fi
  if [[ -z "${ipv4_id}" && ( -z "${ipv6}" || -z "${ipv6_id}" ) ]]; then
    printf 'missing\n'
    return 0
  fi
  if [[ -z "${ipv4_id}" || ( -n "${ipv6}" && -z "${ipv6_id}" ) ]]; then
    printf 'mixed\n'
    return 0
  fi

  ipv4_running="$(docker inspect --format '{{.State.Running}}' "${ipv4_id}")"
  if [[ -z "${ipv6}" ]]; then
    case "${ipv4_running}" in
      true) printf 'running\n' ;;
      false) printf 'stopped\n' ;;
      *) printf 'mixed\n' ;;
    esac
    return 0
  fi

  ipv6_running="$(docker inspect --format '{{.State.Running}}' "${ipv6_id}")"
  if [[ "${ipv4_running}" == "true" && "${ipv6_running}" == "true" ]]; then
    printf 'running\n'
  elif [[ "${ipv4_running}" == "false" && "${ipv6_running}" == "false" ]]; then
    printf 'stopped\n'
  else
    printf 'mixed\n'
  fi
}

tg_ws_verify_running() {
  local compose_directory="$1"
  local project="$2"
  local ipv6="$3"
  local port="$4"
  local attempt=0

  while (( attempt < 10 )); do
    if [[ "$(tg_ws_project_state "${compose_directory}" "${project}" "${ipv6}")" == "running" ]] \
      && nc -4 -z -w 2 127.0.0.1 "${port}" >/dev/null 2>&1; then
      if [[ -z "${ipv6}" ]] || nc -6 -z -w 2 "${ipv6}" "${port}" >/dev/null 2>&1; then
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}
