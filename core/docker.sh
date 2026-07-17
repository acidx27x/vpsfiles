#!/usr/bin/env bash

[[ -n "${VPS_DOCKER_SH:-}" ]] && return 0
VPS_DOCKER_SH=1

VPS_DOCKER_OS_RELEASE="${VPS_DOCKER_OS_RELEASE:-/etc/os-release}"
VPS_DOCKER_KEYRING="${VPS_DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
VPS_DOCKER_SOURCE="${VPS_DOCKER_SOURCE:-/etc/apt/sources.list.d/docker.sources}"
VPS_DOCKER_REPO_BASE="${VPS_DOCKER_REPO_BASE:-https://download.docker.com/linux}"

vps_docker_is_ready() {
  command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1
}

vps_docker_packages_present() {
  local package=""

  command -v dpkg-query >/dev/null 2>&1 || return 1
  for package in \
    docker-ce \
    docker-ce-cli \
    docker.io \
    docker-compose \
    docker-compose-plugin \
    docker-compose-v2 \
    docker-buildx-plugin \
    docker-ce-rootless-extras \
    containerd \
    containerd.io \
    moby-engine \
    podman-docker \
    runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}\n' "${package}" 2>/dev/null | grep -q '^ii'; then
      return 0
    fi
  done
  return 1
}

vps_docker_os_release_value() {
  local key="$1"
  local value=""

  [[ -f "${VPS_DOCKER_OS_RELEASE}" ]] || vps_die "OS release file is missing: ${VPS_DOCKER_OS_RELEASE}"
  value="$(awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${VPS_DOCKER_OS_RELEASE}")"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "${value}"
}

vps_docker_distribution() {
  local distribution=""

  distribution="$(vps_docker_os_release_value ID)"
  case "${distribution}" in
    debian|ubuntu) printf '%s\n' "${distribution}" ;;
    *) vps_die "official Docker installation is supported only on Debian or Ubuntu: ${distribution:-unknown}" ;;
  esac
}

vps_docker_codename() {
  local codename=""

  codename="$(vps_docker_os_release_value VERSION_CODENAME)"
  if [[ -z "${codename}" ]]; then
    codename="$(vps_docker_os_release_value UBUNTU_CODENAME)"
  fi
  [[ "${codename}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || vps_die "could not determine a safe Debian/Ubuntu codename"
  printf '%s\n' "${codename}"
}

vps_docker_install_official() {
  local architecture=""
  local codename=""
  local distribution=""
  local keyring_tmp=""
  local source_tmp=""

  vps_require_root "sudo bash ${0}"
  if vps_docker_is_ready; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1 || vps_docker_packages_present; then
    vps_die "refusing to replace a partial or conflicting Docker/container runtime installation"
  fi
  vps_require_supported_apt_os
  vps_require_systemd
  vps_require_commands apt-get curl dpkg dpkg-query install mktemp systemctl

  distribution="$(vps_docker_distribution)"
  codename="$(vps_docker_codename)"
  architecture="$(dpkg --print-architecture)"
  [[ "${architecture}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || vps_die "Docker apt architecture is invalid: ${architecture}"
  [[ "${VPS_DOCKER_KEYRING}" == /* && "${VPS_DOCKER_KEYRING}" != "/" ]] || vps_die "Docker keyring path is unsafe"
  [[ "${VPS_DOCKER_SOURCE}" == /* && "${VPS_DOCKER_SOURCE}" != "/" ]] || vps_die "Docker apt source path is unsafe"

  keyring_tmp="$(mktemp)"
  source_tmp="$(mktemp)"
  if ! curl -fsSL "${VPS_DOCKER_REPO_BASE}/${distribution}/gpg" -o "${keyring_tmp}"; then
    rm -f -- "${keyring_tmp}" "${source_tmp}"
    vps_die "could not download Docker's apt signing key"
  fi
  printf '%s\n' \
    'Types: deb' \
    "URIs: ${VPS_DOCKER_REPO_BASE}/${distribution}" \
    "Suites: ${codename}" \
    'Components: stable' \
    "Architectures: ${architecture}" \
    "Signed-By: ${VPS_DOCKER_KEYRING}" > "${source_tmp}"

  install -d -m 755 "$(dirname "${VPS_DOCKER_KEYRING}")" "$(dirname "${VPS_DOCKER_SOURCE}")"
  install -m 644 "${keyring_tmp}" "${VPS_DOCKER_KEYRING}"
  install -m 644 "${source_tmp}" "${VPS_DOCKER_SOURCE}"
  rm -f -- "${keyring_tmp}" "${source_tmp}"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  systemctl enable --now docker >/dev/null
  vps_docker_is_ready || vps_die "Docker Engine or Docker Compose did not become ready after installation"
}

vps_docker_ensure_ready() {
  if vps_docker_is_ready; then
    return 0
  fi

  if command -v docker >/dev/null 2>&1 || vps_docker_packages_present; then
    vps_die "Docker is partially installed or unavailable; repair the existing Engine and Compose v2 installation before continuing"
  fi

  vps_docker_install_official
}

vps_docker_compose() {
  local project_directory="${1:-}"
  local project_name="${2:-}"

  (( $# >= 3 )) || vps_die "vps_docker_compose requires a project directory, project name, and Compose arguments"
  [[ "${project_directory}" == /* && "${project_directory}" != "/" && -d "${project_directory}" ]] \
    || vps_die "Docker Compose project directory is missing or unsafe: ${project_directory}"
  [[ "${project_name}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || vps_die "Docker Compose project name is invalid: ${project_name}"
  shift 2
  docker compose \
    --project-directory "${project_directory}" \
    --project-name "${project_name}" \
    "$@"
}
