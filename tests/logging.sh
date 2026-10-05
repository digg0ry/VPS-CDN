#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${NODE_SCRIPT:-$ROOT/xhttp-node.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
require_root() { :; }
load_state() { :; }
local_ipv4() { printf '192.0.2.1\n'; }
ss() { :; }
nginx() {
  if [[ "$1" == -v ]]; then printf 'nginx version: nginx/1.28.3\n'; return 0; fi
  return "$NGINX_RC"
}
logrotate() { printf 'logrotate %s\n' "$*" >> "$CALLS"; return "$LOGROTATE_RC"; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  if [[ "$1" == is-active ]]; then
    [[ "${*: -1}" == nginx ]] && return 0
    return 1
  fi
  return 0
}
fixture() {
  BASE="$TMP/$1"
  STATE_DIR="$BASE/state" STATE_FILE="$STATE_DIR/state.env"
  WEBROOT="$STATE_DIR/www" CERT_DIR="$STATE_DIR/certs"
  NGINX_SITE="$BASE/sites-available/xhttp-node.conf"
  NGINX_LINK="$BASE/sites-enabled/xhttp-node.conf"
  NGINX_SNIPPET="$BASE/snippets/proxy.conf"
  NGINX_LOG_DIR="$BASE/var/log/xhttp-node"
  NGINX_LOG_FORMAT="$BASE/conf.d/logging.conf"
  LOGROTATE_FILE="$BASE/logrotate.d/xhttp-node"
  SYSTEMD_DIR="$BASE/systemd" BACKUP_ROOT="$BASE/backups"
  CALLS="$BASE/calls"
  DOMAIN=cdn.example.com ORIGIN_HOST=cdn.example.com XHTTP_PORT=7443
  CERT_FULLCHAIN="$BASE/fullchain.pem" CERT_KEY="$BASE/privkey.pem"
  NGINX_RC=0 LOGROTATE_RC=0
  mkdir -p "$STATE_DIR" "$(dirname "$NGINX_SITE")" "$(dirname "$NGINX_LINK")" \
    "$(dirname "$NGINX_SNIPPET")" "$(dirname "$NGINX_LOG_FORMAT")" "$(dirname "$LOGROTATE_FILE")" "$SYSTEMD_DIR"
  printf '# Managed by xhttp-node.sh v2.3.2\nold site\n' > "$NGINX_SITE"
  ln -s "$NGINX_SITE" "$NGINX_LINK"
  printf 'old proxy\n' > "$NGINX_SNIPPET"
  printf 'old rotation\n' > "$LOGROTATE_FILE"
  printf 'old format\n' > "$NGINX_LOG_FORMAT"
  printf 'DOMAIN=cdn.example.com\n' > "$STATE_FILE"
  printf 'unrelated rotation\n' > "$BASE/logrotate.d/nginx"
  : > "$CALLS"
}
if ! declare -F write_nginx_logging >/dev/null; then
  printf 'FAIL: compact logging migration absent\n' >&2
  exit 1
fi
fixture success
write_nginx
write_logrotate
grep -Fq "access_log $NGINX_LOG_DIR/access.log xhttp_node buffer=64k flush=5s;" "$NGINX_SITE"
grep -Fq "$NGINX_LOG_DIR/*.log" "$LOGROTATE_FILE"
! grep -v '^#' "$LOGROTATE_FILE" | grep -Fq '/var/log/nginx/'
grep -qx '    maxsize 20M' "$LOGROTATE_FILE"
grep -qx '    rotate 6' "$LOGROTATE_FILE"
grep -qx '    nodelaycompress' "$LOGROTATE_FILE"
! grep -qx '    delaycompress' "$LOGROTATE_FILE"
grep -Fq 'kill -USR1' "$LOGROTATE_FILE"
grep -Fq 'OnCalendar=*-*-* *:0/5:00' "$SYSTEMD_DIR/xhttp-node-logrotate.timer"
grep -Fq "ExecStart=/usr/sbin/logrotate $LOGROTATE_FILE" "$SYSTEMD_DIR/xhttp-node-logrotate.service"
grep -Fqx 'systemctl enable --now xhttp-node-logrotate.timer' "$CALLS"
! grep -qE '\$(request|args|http_referer|http_user_agent)([^_a-z]|$)' "$NGINX_LOG_FORMAT"
grep -q 'unrelated rotation' "$BASE/logrotate.d/nginx"
cp "$LOGROTATE_FILE" "$BASE/expected"
write_logrotate
cmp "$BASE/expected" "$LOGROTATE_FILE"

fixture invalid
LOGROTATE_RC=1
if write_logrotate; then echo 'Unexpected invalid rotation success' >&2; exit 1; fi
grep -q '^old rotation$' "$LOGROTATE_FILE"
! grep -q '^systemctl ' "$CALLS"

fixture repair
repair_logging
grep -q 'xhttp_node buffer=64k' "$NGINX_SITE"
! grep -qE 'restart|docker|stop nginx' "$CALLS"

fixture rollback
NGINX_RC=1
if repair_logging; then echo 'Unexpected invalid Nginx success' >&2; exit 1; fi
grep -q '^old site$' "$NGINX_SITE"
grep -q '^old proxy$' "$NGINX_SNIPPET"
grep -q '^old rotation$' "$LOGROTATE_FILE"
grep -q '^old format$' "$NGINX_LOG_FORMAT"
[[ ! -e "$SYSTEMD_DIR/xhttp-node-logrotate.timer" ]]
printf 'PASS: compact logging, disjoint rotation, timer, idempotence, validation failure, repair and rollback\n'
