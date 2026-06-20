#!/usr/bin/env bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

load_core() {
  # shellcheck source=lib/core.sh
  . "${REPO_ROOT}/lib/core.sh"
}

load_wg_family() {
  load_core
  # shellcheck source=lib/wg_family.sh
  . "${REPO_ROOT}/lib/wg_family.sh"
}

load_telemt() {
  load_core
  # shellcheck source=lib/telemt.sh
  . "${REPO_ROOT}/lib/telemt.sh"
}

load_xray() {
  load_core
  # shellcheck source=lib/xray.sh
  . "${REPO_ROOT}/lib/xray.sh"
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

  grep -qF "${text}" "${file}"
}

assert_file_not_contains() {
  local file="$1"
  local text="$2"

  ! grep -qF "${text}" "${file}"
}
