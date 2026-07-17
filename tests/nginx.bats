#!/usr/bin/env bats

load test_helper

setup() {
  load_nginx
  make_temp_dir
  export NGINX_TEMPLATE="${REPO_ROOT}/nginx-scripts/fallback-site.conf.example"
}

teardown() {
  remove_temp_dir
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
