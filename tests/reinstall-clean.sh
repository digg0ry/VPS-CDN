#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
trap 'command rm -rf -- "$TMP"' EXIT
require_root() { :; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  case "$1" in
    is-active) [[ "$ACTIVE" == active ]] ;;
    stop|disable)
      (( STOP_RC == 0 )) || return "$STOP_RC"
      [[ "$2" != nginx ]] || ACTIVE=inactive
      ;;
    *) return 0 ;;
  esac
}
docker() {
  printf 'docker %s\n' "$*" >> "$CALLS"
  case "$1" in
    inspect) return 0 ;;
    stop) return "$DOCKER_STOP_RC" ;;
    rm) return "$DOCKER_RM_RC" ;;
    *) return 99 ;;
  esac
}
rm() {
  [[ "$ACTIVE" == inactive ]] || { echo 'Deletion before stopping Nginx' >&2; return 99; }
  printf 'rm %s\n' "$*" >> "$CALLS"
  command rm "$@"
}
fixture() {
  local unit
  BASE="$TMP/$1"
  STATE_DIR="$BASE/state" STATE_FILE="$BASE/state/state.env"
  WEBROOT="$STATE_DIR/www" EXPORT_DIR="$STATE_DIR/exports" CERT_DIR="$STATE_DIR/certs"
  NODE_DIR="$BASE/remnanode" WATCHDOG_STATE_DIR="$BASE/watchdog-state"
  NGINX_SITE="$BASE/sites-available/xhttp-node.conf" NGINX_LINK="$BASE/sites-enabled/xhttp-node.conf"
  NGINX_SNIPPET="$BASE/proxy.conf" NGINX_CONF_DIR="$BASE/conf.d"
  SYSTEMD_DIR="$BASE/systemd" BACKUP_ROOT="$BASE/backups"
  LEGACY_WEBROOT_BASE="$BASE/legacy-www"
  WATCHDOG_BIN="$BASE/watchdog" CERT_SYNC_BIN="$BASE/sync" NGINX_RECOVER_BIN="$BASE/recover"
  LOGROTATE_FILE="$BASE/logrotate" CALLS="$BASE/calls"
  mkdir -p "$WEBROOT" "$EXPORT_DIR" "$CERT_DIR" "$NODE_DIR" "$WATCHDOG_STATE_DIR" \
    "$(dirname "$NGINX_SITE")" "$(dirname "$NGINX_LINK")" "$NGINX_CONF_DIR" "$SYSTEMD_DIR" "$LEGACY_WEBROOT_BASE/old.example.com"
  printf '# Managed by xhttp-node.sh v2.3.0\n' > "$NGINX_SITE"
  ln -s "$NGINX_SITE" "$NGINX_LINK"
  printf 'proxy_pass http://cdn_xhttp_xray;\n' > "$(dirname "$NGINX_SITE")/old.example.com"
  printf 'root %s/old.example.com;\n' "$LEGACY_WEBROOT_BASE" >> "$(dirname "$NGINX_SITE")/old.example.com"
  printf 'legacy web\n' > "$LEGACY_WEBROOT_BASE/old.example.com/index.html"
  ln -s "$(dirname "$NGINX_SITE")/old.example.com" "$(dirname "$NGINX_LINK")/old.example.com"
  printf 'upstream cdn_xhttp_xray { server 127.0.0.1:443; }\n' > "$NGINX_CONF_DIR/cdn-xhttp-upstream.conf"
  printf 'log_format cdn_json escape=json "test";\n' > "$NGINX_CONF_DIR/cdn-log-format.conf"
  printf 'server { unrelated; }\n' > "$NGINX_CONF_DIR/cdn-unrelated.conf"
  printf 'old compose\n' > "$NODE_DIR/docker-compose.yml"
  printf 'keep cert\n' > "$CERT_DIR/fullchain.pem"
  printf 'keep key\n' > "$CERT_DIR/privkey.pem"
  touch "$STATE_FILE" "$WEBROOT/index.html" "$WATCHDOG_STATE_DIR/last-restart" \
    "$NGINX_SNIPPET" "$LOGROTATE_FILE" "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN"
  for unit in xhttp-node-nginx-recover xhttp-node-cert-sync node-ram-watchdog; do
    touch "$SYSTEMD_DIR/$unit.timer" "$SYSTEMD_DIR/$unit.service"
  done
  ACTIVE=active STOP_RC=0 DOCKER_STOP_RC=0 DOCKER_RM_RC=0
  : > "$CALLS"
}
assert_intact() {
  [[ -s "$NODE_DIR/docker-compose.yml" && -e "$WEBROOT/index.html" && -L "$NGINX_LINK" ]]
  [[ -L "$(dirname "$NGINX_LINK")/old.example.com" && -f "$NGINX_CONF_DIR/cdn-xhttp-upstream.conf" ]]
}
fixture success
clean_managed
backup=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)
[[ -s "$backup$NODE_DIR/docker-compose.yml" && -L "$backup$(dirname "$NGINX_LINK")/old.example.com" ]]
[[ -s "$backup$NGINX_CONF_DIR/cdn-log-format.conf" ]]
[[ -s "$backup$LEGACY_WEBROOT_BASE/old.example.com/index.html" ]]
[[ ! -d "$backup$LEGACY_WEBROOT_BASE/old.example.com/old.example.com" && ! -d "$LEGACY_WEBROOT_BASE/old.example.com" ]]
[[ ! -e "$NODE_DIR" && ! -e "$STATE_FILE" && ! -e "$NGINX_SITE" && ! -L "$NGINX_LINK" ]]
[[ ! -f "$NGINX_CONF_DIR/cdn-xhttp-upstream.conf" && ! -f "$NGINX_CONF_DIR/cdn-log-format.conf" ]]
[[ ! -L "$(dirname "$NGINX_LINK")/old.example.com" && ! -e "$(dirname "$NGINX_SITE")/old.example.com" ]]
[[ -s "$CERT_DIR/fullchain.pem" && -f "$NGINX_CONF_DIR/cdn-unrelated.conf" ]]
[[ "$ACTIVE" == inactive ]]
grep -q '^docker stop -t 20 remnanode$' "$CALLS"
grep -q '^docker rm remnanode$' "$CALLS"
! grep -q '^systemctl start nginx$' "$CALLS"

fixture keep_node
clean_managed n
[[ -s "$NODE_DIR/docker-compose.yml" && -s "$CERT_DIR/privkey.pem" ]]
! grep -q '^docker ' "$CALLS"

fixture shared_log
printf 'access_log /tmp/other.log cdn_json;\n' > "$NGINX_CONF_DIR/unrelated-site.conf"
clean_managed
[[ -s "$NGINX_CONF_DIR/cdn-log-format.conf" ]]

fixture shared_webroot
printf 'root %s/old.example.com;\n' "$LEGACY_WEBROOT_BASE" > "$NGINX_CONF_DIR/unrelated-site.conf"
clean_managed
[[ -s "$LEGACY_WEBROOT_BASE/old.example.com/index.html" ]]

for failure in stop docker_stop docker_rm; do
  fixture "$failure"
  case "$failure" in stop) STOP_RC=1 ;; docker_stop) DOCKER_STOP_RC=1 ;; docker_rm) DOCKER_RM_RC=1 ;; esac
  if clean_managed; then echo "Unexpected cleanup success: $failure" >&2; exit 1; fi
  assert_intact
done

fixture backup_failure
(
  cp() { return 1; }
  if clean_managed; then exit 1; fi
  assert_intact
  [[ ! -s "$CALLS" ]]
)
fixture symlink_outside
printf 'proxy_pass http://cdn_xhttp_xray;\n' > "$BASE/external-config"
ln -s "$BASE/external-config" "$(dirname "$NGINX_LINK")/external"
if clean_managed; then exit 1; fi
assert_intact
[[ -s "$BASE/external-config" && ! -s "$CALLS" ]]
printf 'PASS: legacy discovery, private backup, stop before delete, preserve unrelated/certs/node, failure handling\n'
