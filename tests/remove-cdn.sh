#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
require_root() { :; }
ip() { :; }
ss() { :; }
docker() { echo 'ERROR: Docker must not be changed' >&2; return 99; }
nginx() { return "$NGINX_RC"; }
systemctl() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$1" in
    is-active) [[ "$ACTIVE" == true ]] ;;
    reload) return "$RELOAD_RC" ;;
    disable|stop) return "$STOP_RC" ;;
    *) return 0 ;;
  esac
}

fixture() {
  local name="$1" unit
  BASE="$TMP/$name"
  STATE_DIR="$BASE/state"
  STATE_FILE="$STATE_DIR/state.env"
  WEBROOT="$STATE_DIR/www"
  EXPORT_DIR="$STATE_DIR/exports"
  CERT_DIR="$STATE_DIR/certs"
  BACKUP_ROOT="$BASE/backups"
  NGINX_SITE="$BASE/sites-available/site"
  NGINX_LINK="$BASE/sites-enabled/site"
  NGINX_SNIPPET="$BASE/snippet"
  NGINX_LOG_DIR="$BASE/logs" NGINX_LOG_FORMAT="$BASE/log-format.conf"
  LOGROTATE_FILE="$BASE/logrotate"
  WATCHDOG_STATE_DIR="$BASE/watchdog-state"
  SYSTEMD_DIR="$BASE/systemd"
  WATCHDOG_BIN="$BASE/watchdog"
  CERT_SYNC_BIN="$BASE/cert-sync"
  NGINX_RECOVER_BIN="$BASE/recover"
  CALLS="$BASE/calls"
  mkdir -p "$WEBROOT" "$EXPORT_DIR" "$CERT_DIR" "$WATCHDOG_STATE_DIR" \
    "$SYSTEMD_DIR" "$(dirname "$NGINX_LINK")" "$(dirname "$NGINX_SITE")" "$BASE/remnanode"
  printf '# Managed by xhttp-node.sh v2.3.0\nserver {}\n' > "$NGINX_SITE"
  ln -s "$NGINX_SITE" "$NGINX_LINK"
  printf 'secret compose unchanged\n' > "$BASE/remnanode/docker-compose.yml"
  printf 'unrelated server\n' > "$(dirname "$NGINX_LINK")/other"
  for unit in xhttp-node-logrotate node-ram-watchdog xhttp-node-cert-sync xhttp-node-nginx-recover; do
    touch "$SYSTEMD_DIR/$unit.service" "$SYSTEMD_DIR/$unit.timer"
  done
  printf 'keep certificate\n' > "$CERT_DIR/fullchain.pem"
  printf 'keep key\n' > "$CERT_DIR/privkey.pem"
  touch "$STATE_FILE" "$WEBROOT/index.html" "$EXPORT_DIR/client.json" \
    "$NGINX_SNIPPET" "$NGINX_LOG_FORMAT" "$LOGROTATE_FILE" "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN" \
    "$WATCHDOG_STATE_DIR/last-restart"
  : > "$CALLS"
  ACTIVE=true NGINX_RC=0 RELOAD_RC=0 STOP_RC=0
}
assert_preserved() {
  grep -q 'secret compose unchanged' "$BASE/remnanode/docker-compose.yml"
  grep -q 'keep certificate' "$CERT_DIR/fullchain.pem"
  grep -q 'keep key' "$CERT_DIR/privkey.pem"
  grep -q 'unrelated server' "$(dirname "$NGINX_LINK")/other"
  ! grep -Eq '^(stop|disable|restart).*nginx($| )' "$CALLS"
}
fixture cancel
remove_cdn_managed <<< 'NO'
[[ -e "$NGINX_LINK" && -s "$NGINX_SITE" && ! -e "$BACKUP_ROOT" ]]
[[ ! -s "$CALLS" ]]

fixture success
remove_cdn_managed <<< 'REMOVE-CDN'
[[ ! -e "$NGINX_SITE" && ! -L "$NGINX_LINK" && ! -e "$NGINX_SNIPPET" ]]
[[ ! -e "$STATE_FILE" && ! -e "$WEBROOT" && ! -e "$EXPORT_DIR" ]]
[[ ! -e "$CERT_SYNC_BIN" && ! -e "$NGINX_RECOVER_BIN" && ! -e "$WATCHDOG_BIN" ]]
[[ ! -e "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer" ]]
[[ ! -e "$NGINX_LOG_FORMAT" && ! -e "$SYSTEMD_DIR/xhttp-node-logrotate.timer" ]]
grep -q '^reload nginx$' "$CALLS"
assert_preserved
backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)"
[[ -s "$backup$NGINX_SITE" && -L "$backup$NGINX_LINK" && -s "$backup$CERT_DIR/privkey.pem" ]]
remove_cdn_managed <<< 'REMOVE-CDN'
assert_preserved

fixture inactive
ACTIVE=false
remove_cdn_managed <<< 'REMOVE-CDN'
! grep -Eq '^(start|reload) nginx$' "$CALLS"
assert_preserved

for failure in config reload stop; do
  fixture "$failure"
  case "$failure" in config) NGINX_RC=1 ;; reload) RELOAD_RC=1 ;; stop) STOP_RC=1 ;; esac
  if remove_cdn_managed <<< 'REMOVE-CDN'; then echo "Unexpected success: $failure"; exit 1; fi
  [[ -e "$NGINX_LINK" && -s "$NGINX_SITE" && -e "$NGINX_SNIPPET" ]]
  [[ -e "$STATE_FILE" && -e "$WEBROOT/index.html" ]]
  assert_preserved
done

fixture unowned
printf 'server { unrelated; }\n' > "$NGINX_SITE"
if remove_cdn_managed <<< 'REMOVE-CDN'; then exit 1; fi
[[ -e "$NGINX_LINK" && ! -s "$CALLS" ]]

fixture backup_failure
(
  cp() { return 1; }
  if remove_cdn_managed <<< 'REMOVE-CDN'; then exit 1; fi
  [[ -e "$NGINX_SITE" && -e "$STATE_FILE" && ! -s "$CALLS" ]]
)
printf 'PASS: remove CDN, preserve node/certs, cancel, rollback, backup failure, repeat\n'
