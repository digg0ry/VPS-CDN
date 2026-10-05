#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
CALLS="$TMP/calls"
export CALLS

ss() { printf '%s' "$LISTENERS"; return "$SS_RC"; }
nginx() { printf 'nginx %s\n' "$*" >> "$CALLS"; return "$NGINX_RC"; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  case "$1" in
    is-active) [[ "$ACTIVE" == active ]] ;;
    show) printf '%s\n' "$ACTIVE" ;;
    start)
      (( START_RC == 0 )) || return "$START_RC"
      ACTIVE=active
      ;;
    reload) return "$RELOAD_RC" ;;
  esac
}
reset_mocks() {
  LISTENERS=""
  SS_RC=0 NGINX_RC=0 START_RC=0 RELOAD_RC=0
  ACTIVE=inactive
  : > "$CALLS"
}
expect_failure() {
  if "$@"; then
    printf 'Unexpected success: %s\n' "$*" >&2
    exit 1
  fi
}
assert_called() { grep -Fqx "$1" "$CALLS"; }
assert_not_called() { ! grep -Fqx "$1" "$CALLS"; }

reset_mocks
apply_nginx_service
assert_called "systemctl start nginx"
assert_not_called "systemctl reload nginx"

reset_mocks
ACTIVE=active
LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=10,fd=8))'
apply_nginx_service
assert_called "systemctl reload nginx"
assert_not_called "systemctl start nginx"

reset_mocks
LISTENERS='LISTEN 0 4096 127.0.0.1:443 0.0.0.0:* users:(("rw-core",pid=20,fd=7))'
expect_failure apply_nginx_service
assert_not_called "systemctl start nginx"
reset_mocks
LISTENERS='LISTEN 0 511 [::]:443 [::]:* users:(("caddy",pid=30,fd=7))'
expect_failure apply_nginx_service
reset_mocks
LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:*'
expect_failure apply_nginx_service
reset_mocks
SS_RC=1
expect_failure apply_nginx_service
assert_not_called "systemctl start nginx"
reset_mocks
NGINX_RC=1
expect_failure apply_nginx_service
assert_not_called "systemctl start nginx"
reset_mocks
START_RC=1
expect_failure apply_nginx_service
reset_mocks
ACTIVE=active RELOAD_RC=1
expect_failure apply_nginx_service

# Both Nginx syntaxes must work, including origin IP-specific virtual hosts.
(
  local_ipv4() { printf '192.0.2.1\n'; }
  nginx() { printf 'nginx version: nginx/%s\n' "$VERSION"; }
  for VERSION in 1.18.0 1.24.0 1.25.0; do
    output="$(nginx_tls_listeners)"
    grep -q 'listen 192.0.2.1:443 ssl http2;' <<< "$output"
    ! grep -q 'http2 on;' <<< "$output"
  done
  for VERSION in 1.25.1 1.28.3; do
    output="$(nginx_tls_listeners)"
    grep -q 'listen 192.0.2.1:443 ssl;' <<< "$output"
    grep -q 'http2 on;' <<< "$output"
    ! grep -q 'ssl http2;' <<< "$output"
  done
  local_ipv4() { return 1; }
  output="$(nginx_tls_listeners)"
  grep -q 'listen 443 ssl;' <<< "$output"
  grep -q 'listen \[::\]:443 ssl;' <<< "$output"
)

DOMAIN=cdn.example.com ORIGIN_HOST=cdn.example.com CLIENT_ADDRESS=cdn.example.com
ORIGIN_TARGET=192.0.2.1 CDN_PROVIDER=yandex XHTTP_PORT=7443 NODE_PORT=34534
check_inputs
for port in 80 443 34534; do
  expect_failure bash -c 'source "$1/xhttp-node.sh"; DOMAIN=cdn.example.com; ORIGIN_TARGET=192.0.2.1; CDN_PROVIDER=yandex; XHTTP_PORT="$2"; check_inputs' _ "$ROOT" "$port"
done

NGINX_SITE="$TMP/sites-available/node.conf"
NGINX_LINK="$TMP/sites-enabled/node.conf"
NGINX_SNIPPET="$TMP/snippets/proxy.conf"
NGINX_LOG_DIR="$TMP/logs"
NGINX_LOG_FORMAT="$TMP/conf.d/logging.conf"
NGINX_RECOVER_BIN="$TMP/recover"
SYSTEMD_DIR="$TMP/systemd"
BACKUP_ROOT="$TMP/backups"
STATE_DIR="$TMP/state"
STATE_FILE="$STATE_DIR/state.env"
EXPORT_DIR="$STATE_DIR/exports"
WEBROOT="$STATE_DIR/www"
CERT_FULLCHAIN="$TMP/fullchain.pem"
CERT_KEY="$TMP/privkey.pem"
mkdir -p "$STATE_DIR"

# A conflict must not prevent generation of state, templates, or recovery units.
reset_mocks
LISTENERS='LISTEN 0 4096 127.0.0.1:443 0.0.0.0:* users:(("rw-core",pid=20,fd=7))'
write_nginx
write_nginx_recovery
write_exports
save_state
grep -q '127.0.0.1:7443' "$NGINX_SITE"
grep -q '^XHTTP_PORT=7443$' "$STATE_FILE"
jq -e '.inbounds[0].port == 7443' "$EXPORT_DIR/server-inbound.json" >/dev/null
assert_not_called "systemctl start nginx"
assert_called "systemctl enable --now xhttp-node-nginx-recover.timer"
bash -n "$NGINX_RECOVER_BIN"
if command -v shellcheck >/dev/null; then shellcheck -S error "$NGINX_RECOVER_BIN"; fi

export -f ss nginx systemctl
export LISTENERS SS_RC NGINX_RC START_RC RELOAD_RC ACTIVE
expect_failure bash "$NGINX_RECOVER_BIN"
assert_not_called "systemctl start nginx"
reset_mocks
bash "$NGINX_RECOVER_BIN"
assert_called "systemctl start nginx"
for state in active activating deactivating; do
  reset_mocks
  ACTIVE="$state"
  bash "$NGINX_RECOVER_BIN"
  assert_not_called "systemctl start nginx"
  assert_not_called "systemctl reload nginx"
done
reset_mocks
ACTIVE=failed
bash "$NGINX_RECOVER_BIN"
assert_called "systemctl start nginx"
reset_mocks
NGINX_RC=1
expect_failure bash "$NGINX_RECOVER_BIN"
assert_not_called "systemctl start nginx"

# Exercise install/reinstall orchestration without apt, Docker or host changes.
(
  reset_mocks
  load_state() { :; }
  require_root() { :; }
  select_provider() { CDN_PROVIDER=yandex; }
  check_inputs() { :; }
  clean_managed() { printf 'clean\n' >> "$CALLS"; }
  command_exists() { return 1; }
  install_packages() { printf 'packages\n' >> "$CALLS"; }
  install_remnanode() { printf 'node\n' >> "$CALLS"; }
  prepare_certificate() { :; }
  write_fake_site() { :; }
  stop_nginx_recovery() { printf 'stop recovery\n' >> "$CALLS"; }
  write_nginx() { printf 'config\n' >> "$CALLS"; }
  write_nginx_recovery() { printf 'recovery\n' >> "$CALLS"; }
  write_cert_sync() { :; }
  write_watchdog() { :; }
  write_logrotate() { printf 'rotation\n' >> "$CALLS"; }
  check_dns() { :; }
  report_nginx_readiness() { :; }
  # Existing temp state triggers the REINSTALL confirmation in Setup.
  printf '\n\n\n\n\n\n\n\n\n\n\nn\nREINSTALL\nn\n' | write_setup
  assert_called recovery
  assert_called config
  assert_called 'stop recovery'
  assert_called rotation
  reset_mocks
  printf '\n\n\n\n\n\n\n\n\n\n\nn\nREINSTALL\nn\n' | reinstall_clean
  assert_called clean
  assert_called recovery
  assert_called rotation
  reset_mocks
  STATE_FILE="$TMP/fresh-state.env" NGINX_SITE="$TMP/fresh-site.conf" NODE_DIR="$TMP/fresh-node"
  has_legacy_cdn() { return 1; }
  printf '\n\n\n\n\n\n\n\n\n\n\nn\n' | write_setup
  assert_called rotation
  assert_called config
  assert_not_called clean
)
printf 'PASS: Nginx activation, conflicts, recovery, ports, setup/reinstall and exports\n'
