#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats test cases run in isolated subshells.

load test_helper

setup() {
  load_nginx_uninstall
  make_temp_dir
  export NGINX_TEMPLATE="${REPO_ROOT}/nginx-scripts/fallback-site.conf.example"
}

teardown() {
  remove_temp_dir
}

setup_nginx_uninstall_fixture() {
  NGINX_STATE_DIR="${TEST_TMPDIR}/state"
  NGINX_CONFIG="${TEST_TMPDIR}/etc/nginx/sites-available/xray-fallback"
  NGINX_ENABLED_CONFIG="${TEST_TMPDIR}/etc/nginx/sites-enabled/xray-fallback"
  NGINX_WEB_ROOT="${TEST_TMPDIR}/var/www/xray-fallback"
  NGINX_RENEWAL_HOOK="${TEST_TMPDIR}/etc/letsencrypt/renewal-hooks/deploy/reload-xray-fallback-nginx"
  NGINX_LETSENCRYPT_ROOT="${TEST_TMPDIR}/etc/letsencrypt"
  NGINX_REFERENCE_ROOTS="${TEST_TMPDIR}/etc/nginx:${TEST_TMPDIR}/etc/apache2:${TEST_TMPDIR}/etc/httpd:${TEST_TMPDIR}/etc/postfix"
  BACKUP_ROOT="${TEST_TMPDIR}/backups"
  NGINX_DOMAIN=""
  NGINX_SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  NGINX_CERTBOT_LOG="${TEST_TMPDIR}/certbot.log"
  NGINX_UFW_LOG="${TEST_TMPDIR}/ufw.log"
  export NGINX_STATE_DIR NGINX_CONFIG NGINX_ENABLED_CONFIG NGINX_WEB_ROOT
  export NGINX_RENEWAL_HOOK NGINX_LETSENCRYPT_ROOT NGINX_REFERENCE_ROOTS
  export BACKUP_ROOT NGINX_DOMAIN NGINX_SYSTEMCTL_LOG NGINX_CERTBOT_LOG NGINX_UFW_LOG

  mkdir -p \
    "${NGINX_STATE_DIR}" \
    "$(dirname "${NGINX_CONFIG}")" \
    "$(dirname "${NGINX_ENABLED_CONFIG}")" \
    "${NGINX_WEB_ROOT}" \
    "$(dirname "${NGINX_RENEWAL_HOOK}")" \
    "${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com" \
    "${NGINX_LETSENCRYPT_ROOT}/archive/ru.example.com" \
    "${NGINX_LETSENCRYPT_ROOT}/renewal" \
    "${TEST_TMPDIR}/etc/apache2" \
    "${TEST_TMPDIR}/etc/httpd" \
    "${TEST_TMPDIR}/etc/postfix" \
    "${BACKUP_ROOT}" \
    "${TEST_TMPDIR}/bin"
  cat > "${NGINX_CONFIG}" <<EOF
server {
    listen 80;
    ssl_certificate ${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com/fullchain.pem;
    ssl_certificate_key ${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com/privkey.pem;
}
EOF
  ln -s "${NGINX_CONFIG}" "${NGINX_ENABLED_CONFIG}"
  printf 'site\n' > "${NGINX_WEB_ROOT}/index.html"
  printf 'hook\n' > "${NGINX_RENEWAL_HOOK}"
  printf 'certificate\n' > "${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com/fullchain.pem"
  printf 'private-key\n' > "${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com/privkey.pem"
  printf 'renewal\n' > "${NGINX_LETSENCRYPT_ROOT}/renewal/ru.example.com.conf"
  printf 'backup\n' > "${BACKUP_ROOT}/site-config"
  printf 'ru.example.com\n' > "${NGINX_STATE_DIR}/fallback-domain.txt"
  printf '127.0.0.1:8443\n' > "${NGINX_STATE_DIR}/reality-target.txt"
  printf 'ru.example.com\n' > "${NGINX_STATE_DIR}/reality-server-name.txt"
  printf '%s\n' "${NGINX_CONFIG}" > "${NGINX_STATE_DIR}/nginx-config-path.txt"
  printf '%s\n' "${NGINX_ENABLED_CONFIG}" > "${NGINX_STATE_DIR}/nginx-enabled-config-path.txt"
  printf '%s\n' "${NGINX_WEB_ROOT}" > "${NGINX_STATE_DIR}/nginx-web-root-path.txt"
  printf '%s\n' "${NGINX_RENEWAL_HOOK}" > "${NGINX_STATE_DIR}/nginx-renewal-hook-path.txt"
  printf '1\n' > "${NGINX_STATE_DIR}/firewall-rule-added.txt"
  printf '80\n' > "${NGINX_STATE_DIR}/server-port.txt"
  chmod 600 "${NGINX_STATE_DIR}/"*

  cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NGINX_SYSTEMCTL_LOG}"
if [[ "$1" == "cat" ]]; then
  exit 0
fi
exit 0
EOF
  cat > "${TEST_TMPDIR}/bin/certbot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NGINX_CERTBOT_LOG}"
if [[ "$1" == "delete" ]]; then
  cert_name=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--cert-name" ]]; then
      cert_name="$2"
      break
    fi
    shift
  done
  rm -rf -- \
    "${NGINX_LETSENCRYPT_ROOT}/live/${cert_name}" \
    "${NGINX_LETSENCRYPT_ROOT}/archive/${cert_name}"
  rm -f -- "${NGINX_LETSENCRYPT_ROOT}/renewal/${cert_name}.conf"
fi
EOF
  cat > "${TEST_TMPDIR}/bin/ufw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NGINX_UFW_LOG}"
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl" "${TEST_TMPDIR}/bin/certbot" "${TEST_TMPDIR}/bin/ufw"
  PATH="${TEST_TMPDIR}/bin:${PATH}"
  export PATH

  # shellcheck disable=SC2317
  vps_require_root() { :; }
  # shellcheck disable=SC2317
  vps_confirm() { return 0; }
}

@test "nginx validates fallback domains and ports" {
  run nginx_validate_domain "ru.example.com"
  [ "${status}" -eq 0 ]

  run nginx_validate_domain "bad_domain"
  [ "${status}" -ne 0 ]

  run nginx_validate_internal_port "8443"
  [ "${status}" -eq 0 ]

  run nginx_validate_internal_port "443"
  [ "${status}" -ne 0 ]

  run nginx_validate_email "admin@example.com"
  [ "${status}" -eq 0 ]

  run nginx_validate_email "not-an-email"
  [ "${status}" -ne 0 ]
}

@test "nginx renders ACME bootstrap without public TLS" {
  local output="${TEST_TMPDIR}/bootstrap.conf"

  nginx_render_bootstrap_config "ru.example.com" "/var/www/xray-fallback" > "${output}"

  assert_file_contains "${output}" "listen 80;"
  assert_file_contains "${output}" "server_name ru.example.com;"
  assert_file_contains "${output}" "location ^~ /.well-known/acme-challenge/"
  assert_file_not_contains "${output}" "listen 443"
  assert_file_not_contains "${output}" "ssl_certificate"
}

@test "nginx renders internal TLS fallback only" {
  local output="${TEST_TMPDIR}/fallback.conf"

  nginx_render_site_config "ru.example.com" "8443" "/var/www/xray-fallback" > "${output}"

  assert_file_contains "${output}" "listen 127.0.0.1:8443 ssl http2;"
  assert_file_contains "${output}" "ssl_certificate /etc/letsencrypt/live/ru.example.com/fullchain.pem;"
  assert_file_contains "${output}" "ssl_certificate_key /etc/letsencrypt/live/ru.example.com/privkey.pem;"
  assert_file_contains "${output}" "return 301 https://\$host\$request_uri;"
  assert_file_not_contains "${output}" "listen 443"
  assert_file_not_contains "${output}" "listen 0.0.0.0:8443"
}

@test "nginx uninstall removes owned fallback and unreferenced certificate" {
  setup_nginx_uninstall_fixture

  run nginx_uninstall_main

  [ "${status}" -eq 0 ]
  [ ! -e "${NGINX_CONFIG}" ]
  [ ! -e "${NGINX_ENABLED_CONFIG}" ]
  [ ! -e "${NGINX_WEB_ROOT}" ]
  [ ! -e "${NGINX_RENEWAL_HOOK}" ]
  [ ! -e "${NGINX_LETSENCRYPT_ROOT}/renewal/ru.example.com.conf" ]
  [ ! -e "${NGINX_STATE_DIR}" ]
  [ ! -e "${BACKUP_ROOT}" ]
  assert_file_contains "${NGINX_SYSTEMCTL_LOG}" "disable --now certbot.timer"
  assert_file_contains "${NGINX_SYSTEMCTL_LOG}" "stop certbot.service"
  assert_file_contains "${NGINX_SYSTEMCTL_LOG}" "disable --now nginx.service"
  assert_file_contains "${NGINX_CERTBOT_LOG}" "delete --non-interactive --cert-name ru.example.com"
  assert_file_contains "${NGINX_UFW_LOG}" "delete allow 80/tcp"
}

@test "nginx uninstall rejects arguments" {
  run nginx_uninstall_main unexpected

  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: uninstall.sh"* ]]
}

@test "nginx uninstall retains certificate referenced by another service" {
  setup_nginx_uninstall_fixture
  cat > "${TEST_TMPDIR}/etc/postfix/main.cf" <<EOF
smtpd_tls_cert_file = ${NGINX_LETSENCRYPT_ROOT}/live/ru.example.com/fullchain.pem
EOF

  run nginx_uninstall_main

  [ "${status}" -ne 0 ]
  [ -f "${NGINX_LETSENCRYPT_ROOT}/renewal/ru.example.com.conf" ]
  [ -f "${NGINX_STATE_DIR}/fallback-domain.txt" ]
  [ ! -e "${NGINX_CERTBOT_LOG}" ]
  [[ "${output}" == *"certificate is still referenced"* ]]
}

@test "nginx uninstall preserves an unexpected enabled-site entry" {
  setup_nginx_uninstall_fixture
  rm "${NGINX_ENABLED_CONFIG}"
  printf 'user-managed\n' > "${NGINX_ENABLED_CONFIG}"

  run nginx_uninstall_main

  [ "${status}" -ne 0 ]
  [ "$(<"${NGINX_ENABLED_CONFIG}")" = "user-managed" ]
  [ -f "${NGINX_STATE_DIR}/fallback-domain.txt" ]
  [[ "${output}" == *"unexpected enabled Nginx entry"* ]]
}

@test "nginx uninstall derives legacy certificate and leaves unknown firewall ownership" {
  setup_nginx_uninstall_fixture
  rm -rf "${NGINX_STATE_DIR}"

  run nginx_uninstall_main

  [ "${status}" -eq 0 ]
  assert_file_contains "${NGINX_CERTBOT_LOG}" "delete --non-interactive --cert-name ru.example.com"
  [ ! -e "${NGINX_UFW_LOG}" ]
  [[ "${output}" == *"firewall ownership is unknown"* ]]
}

@test "nginx uninstall retains owned firewall rule needed by another listener" {
  setup_nginx_uninstall_fixture
  cat > "${TEST_TMPDIR}/etc/nginx/sites-available/other" <<'EOF'
server { listen 80; }
EOF

  run nginx_uninstall_main

  [ "${status}" -ne 0 ]
  [ ! -e "${NGINX_UFW_LOG}" ]
  [ -f "${NGINX_STATE_DIR}/firewall-rule-added.txt" ]
  [[ "${output}" == *"another Nginx configuration listens on port 80"* ]]
}

@test "nginx uninstall cancellation and repeated cleanup are safe" {
  setup_nginx_uninstall_fixture
  # shellcheck disable=SC2317
  vps_confirm() { return 1; }

  run nginx_uninstall_main
  [ "${status}" -ne 0 ]
  [ -f "${NGINX_CONFIG}" ]
  [ ! -e "${NGINX_SYSTEMCTL_LOG}" ]

  # shellcheck disable=SC2317
  vps_confirm() { return 0; }
  run nginx_uninstall_main
  [ "${status}" -eq 0 ]
  run nginx_uninstall_main
  [ "${status}" -eq 0 ]
}

@test "nginx installer records firewall rule ownership across reruns" {
  local installer_state="${TEST_TMPDIR}/installer-state"
  local ufw_log="${TEST_TMPDIR}/installer-ufw.log"
  local ufw_preexisting=1

  export NGINX_STATE_DIR="${installer_state}"
  export NGINX_INSTALLER_UFW_LOG="${ufw_log}"
  export NGINX_INSTALLER_UFW_PREEXISTING="${ufw_preexisting}"
  mkdir -p "${installer_state}" "${TEST_TMPDIR}/installer-bin"
  cat > "${TEST_TMPDIR}/installer-bin/ufw" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "show" && "$2" == "added" ]]; then
  if [[ "${NGINX_INSTALLER_UFW_PREEXISTING}" == "1" ]]; then
    printf 'ufw allow 80/tcp\n'
  fi
  exit 0
fi
printf '%s\n' "$*" >> "${NGINX_INSTALLER_UFW_LOG}"
if [[ "$1" == "status" ]]; then
  printf 'Status: active\n'
fi
EOF
  chmod +x "${TEST_TMPDIR}/installer-bin/ufw"
  PATH="${TEST_TMPDIR}/installer-bin:${PATH}"
  export PATH
  # shellcheck source=nginx-scripts/install.sh
  . "${BATS_TEST_DIRNAME}/../nginx-scripts/install.sh"

  setup_firewall
  [ "$(<"${installer_state}/firewall-rule-added.txt")" = "0" ]
  assert_file_not_contains "${ufw_log}" "allow 80/tcp"

  NGINX_INSTALLER_UFW_PREEXISTING=0
  export NGINX_INSTALLER_UFW_PREEXISTING
  setup_firewall
  [ "$(<"${installer_state}/firewall-rule-added.txt")" = "1" ]
  assert_file_contains "${ufw_log}" "allow 80/tcp"

  setup_firewall
  [ "$(<"${installer_state}/firewall-rule-added.txt")" = "1" ]
}

@test "nginx installer saves Xray REALITY handoff values privately" {
  local installer_state="${TEST_TMPDIR}/installer-state"

  export NGINX_STATE_DIR="${installer_state}"
  export NGINX_DOMAIN="xbubax.us"
  export NGINX_INTERNAL_PORT="8443"
  # shellcheck source=nginx-scripts/install.sh
  . "${BATS_TEST_DIRNAME}/../nginx-scripts/install.sh"

  write_script_state

  [ "$(<"${installer_state}/reality-target.txt")" = "127.0.0.1:8443" ]
  [ "$(<"${installer_state}/reality-server-name.txt")" = "xbubax.us" ]
  [ "$(stat -c '%a' "${installer_state}/reality-target.txt")" = "600" ]
  [ "$(stat -c '%a' "${installer_state}/reality-server-name.txt")" = "600" ]
}
