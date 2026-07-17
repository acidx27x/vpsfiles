#!/usr/bin/env bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

load_core() {
  # shellcheck source=core/core.sh
  . "${REPO_ROOT}/core/core.sh"
}

load_update() {
  load_core
  # shellcheck source=core/install.sh
  . "${REPO_ROOT}/core/install.sh"
  # shellcheck source=core/update.sh
  . "${REPO_ROOT}/core/update.sh"
}

load_wg_family() {
  load_core
  # shellcheck source=wireguard-scripts/wg.sh
  . "${REPO_ROOT}/wireguard-scripts/wg.sh"
}

load_telemt() {
  load_core
  # shellcheck source=telemt-scripts/telemt.sh
  . "${REPO_ROOT}/telemt-scripts/telemt.sh"
}

load_xray() {
  load_core
  # shellcheck source=xray-scripts/xray.sh
  . "${REPO_ROOT}/xray-scripts/xray.sh"
}

load_nginx() {
  load_core
  # shellcheck source=nginx-scripts/nginx.sh
  . "${REPO_ROOT}/nginx-scripts/nginx.sh"
}

load_docker() {
  load_core
  # shellcheck source=core/install.sh
  . "${REPO_ROOT}/core/install.sh"
  # shellcheck source=core/docker.sh
  . "${REPO_ROOT}/core/docker.sh"
}

load_tg_ws() {
  load_docker
  # shellcheck source=tg-ws-scripts/tg-ws.sh
  . "${REPO_ROOT}/tg-ws-scripts/tg-ws.sh"
}

load_system() {
  load_core
  # shellcheck source=system-scripts/system.sh
  . "${REPO_ROOT}/system-scripts/system.sh"
}

load_maintenance() {
  # shellcheck source=system-scripts/cleanup.sh
  . "${REPO_ROOT}/system-scripts/cleanup.sh"
}

load_system_update() {
  # shellcheck source=system-scripts/update.sh
  . "${REPO_ROOT}/system-scripts/update.sh"
}

load_system_install() {
  # shellcheck source=system-scripts/install.sh
  . "${REPO_ROOT}/system-scripts/install.sh"
}

load_system_uninstall() {
  # shellcheck source=system-scripts/uninstall.sh
  . "${REPO_ROOT}/system-scripts/uninstall.sh"
}

make_temp_dir() {
  TEST_TMPDIR="$(mktemp -d)"
}

remove_temp_dir() {
  if [[ -n "${TEST_TMPDIR:-}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

assert_file_contains() {
  local file="$1"
  local text="$2"

  grep -qF -- "${text}" "${file}"
}

assert_file_not_contains() {
  local file="$1"
  local text="$2"

  ! grep -qF -- "${text}" "${file}"
}
