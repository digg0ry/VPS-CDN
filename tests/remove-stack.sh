#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'command rm -rf -- "$TMP"' EXIT
require_root() { :; }
hostname() { printf 'fixture-node\n'; }
ip() { :; }
pgrep() { return "$PGREP_RC"; }
command_exists() { [[ "$1" != nginx || "$PACKAGES_INSTALLED" == true ]]; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  case "$1" in
    show) printf 'loaded\n' ;;
    is-active) return 1 ;;
    stop|disable) return "$STOP_RC" ;;
  esac
  return 0
}
dpkg-query() {
  if [[ "$PACKAGES_INSTALLED" == true ]]; then printf 'nginx installed\nnginx-common installed\n'; fi
  printf 'openssh-server installed\ndocker-ce installed\ncurl installed\n'
}
apt-get() {
  printf 'apt-get %s\n' "$*" >> "$CALLS"
  if [[ "$1" == -s ]]; then
    printf 'Remv nginx [1.26]\nPurg nginx-common [1.26]\n'
    [[ "$APT_EXTRA" == false ]] || printf 'Remv openssh-server [1.0]\n'
    return 0
  fi
  (( APT_RC == 0 )) || return "$APT_RC"
  [[ "$APT_STALE" == true ]] || PACKAGES_INSTALLED=false
}
docker() {
  printf 'docker %s\n' "$*" >> "$CALLS"
  case "$1" in
    info) return "$DOCKER_INFO_RC" ;;
    ps) jq -r '.[].Id' "$GRAPH" ;;
    inspect) cat "$GRAPH" ;;
    stop)
      [[ "$4" != remna || "$DOCKER_STOP_RC" == 0 ]] || return "$DOCKER_STOP_RC"
      return 0 ;;
    rm)
      (( DOCKER_RM_RC == 0 )) || return "$DOCKER_RM_RC"
      jq --arg id "$2" 'map(select(.Id != $id))' "$GRAPH" > "$GRAPH.next"
      mv "$GRAPH.next" "$GRAPH" ;;
    image)
      if [[ "$2" == ls ]]; then printf 'remnawave/node:latest\n'
      else return 0; fi ;;
    *) return 98 ;;
  esac
}
rm() {
  [[ "$1" != -rf ]] || compgen -G "$BACKUP_ROOT/*/containers.json" >/dev/null || {
    printf 'Deletion before backup\n' >&2; return 99;
  }
  printf 'rm %s\n' "$*" >> "$CALLS"
  command rm "$@"
}
fixture() {
  BASE="$TMP/$1"
  STATE_DIR="$BASE/state" STATE_FILE="$STATE_DIR/state.env"
  WEBROOT="$STATE_DIR/www" EXPORT_DIR="$STATE_DIR/exports" CERT_DIR="$STATE_DIR/certs"
  NODE_DIR="$BASE/remnanode" WATCHDOG_STATE_DIR="$BASE/watchdog-state"
  NGINX_ROOT="$BASE/nginx"
  NGINX_SITE="$NGINX_ROOT/sites-available/xhttp-node.conf" NGINX_LINK="$NGINX_ROOT/sites-enabled/xhttp-node.conf"
  NGINX_SNIPPET="$NGINX_ROOT/proxy.conf" NGINX_CONF_DIR="$NGINX_ROOT/conf.d"
  NGINX_LOG_DIR="$BASE/logs/managed" NGINX_LOG_FORMAT="$NGINX_CONF_DIR/xhttp-node-logging.conf"
  NGINX_SYSTEM_LOG_DIR="$BASE/logs/nginx" NGINX_CACHE_DIR="$BASE/cache/nginx"
  NGINX_LIB_DIR="$BASE/lib/nginx" NODE_LOG_DIR="$BASE/logs/remnanode"
  SYSTEMD_DIR="$BASE/systemd" BACKUP_ROOT="$BASE/backups"
  LEGACY_WEBROOT_BASE="$BASE/legacy-www"
  WATCHDOG_BIN="$BASE/bin/watchdog" CERT_SYNC_BIN="$BASE/bin/sync" NGINX_RECOVER_BIN="$BASE/bin/recover"
  LOGROTATE_FILE="$BASE/logrotate/xhttp-node" CADDY_DIR="$BASE/caddy" CERTBOT_DIR="$BASE/certbot"
  CALLS="$BASE/calls" GRAPH="$BASE/containers.json"
  mkdir -p "$WEBROOT" "$EXPORT_DIR" "$CERT_DIR" "$NODE_DIR" "$WATCHDOG_STATE_DIR" \
    "$(dirname "$NGINX_SITE")" "$(dirname "$NGINX_LINK")" "$NGINX_CONF_DIR" "$SYSTEMD_DIR" \
    "$LEGACY_WEBROOT_BASE/old.example.com" "$(dirname "$LOGROTATE_FILE")" "$BASE/bin" \
    "$NGINX_LOG_DIR" "$NGINX_SYSTEM_LOG_DIR" "$NODE_LOG_DIR" "$NGINX_CACHE_DIR" "$NGINX_LIB_DIR"
  printf '# Managed by xhttp-node.sh v2.3.4\n' > "$NGINX_SITE"
  ln -s "$NGINX_SITE" "$NGINX_LINK"
  printf 'proxy_pass http://cdn_xhttp_xray;\nroot %s/old.example.com;\n' "$LEGACY_WEBROOT_BASE" > "$NGINX_CONF_DIR/old.conf"
  printf 'legacy web\n' > "$LEGACY_WEBROOT_BASE/old.example.com/index.html"
  printf 'SECRET_KEY=fixture\n' > "$NODE_DIR/docker-compose.yml"
  printf 'state fixture\n' > "$STATE_FILE"
  printf 'private key fixture\n' > "$CERT_DIR/privkey.pem"
  printf 'cert fixture\n' > "$CERT_DIR/fullchain.pem"
  touch "$WEBROOT/index.html" "$EXPORT_DIR/server-inbound.json" "$NGINX_LOG_FORMAT" \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN" "$LOGROTATE_FILE" \
    "$SYSTEMD_DIR/remnanode.service"
  for unit in xhttp-node-logrotate xhttp-node-nginx-recover xhttp-node-cert-sync node-ram-watchdog; do
    touch "$SYSTEMD_DIR/$unit.timer" "$SYSTEMD_DIR/$unit.service"
  done
  for unit in "$NGINX_LOG_DIR" "$NGINX_SYSTEM_LOG_DIR" "$NODE_LOG_DIR"; do printf 'old log\n' > "$unit/access.log"; done
  mkdir -p "$BASE/unrelated" "$BASE/external-cert"
  printf 'keep unrelated service\n' > "$BASE/unrelated/data"
  printf 'keep external cert\n' > "$BASE/external-cert/privkey.pem"
  jq -n --arg node "$NODE_DIR" --arg other "$BASE/unrelated" '[
    {Id:"remna",Name:"/remnanode",Config:{Image:"remnawave/node:latest"},Mounts:[{Type:"bind",Source:$node}]},
    {Id:"other",Name:"/other",Config:{Image:"postgres:latest"},Mounts:[{Type:"bind",Source:$other}]}
  ]' > "$GRAPH"
  PACKAGES_INSTALLED=true STOP_RC=0 APT_RC=0 APT_EXTRA=false APT_STALE=false
  DOCKER_INFO_RC=0 DOCKER_STOP_RC=0 DOCKER_RM_RC=0 PGREP_RC=1
  : > "$CALLS"
}
assert_intact() {
  [[ -s "$NODE_DIR/docker-compose.yml" && -s "$STATE_FILE" && -L "$NGINX_LINK" ]]
  jq -e 'any(.[]; .Name == "/remnanode")' "$GRAPH" >/dev/null
}
assert_no_mutation() {
  assert_intact
  ! grep -Eq '^(rm |docker (stop|rm)|systemctl (disable|stop)|apt-get -y)' "$CALLS"
}
fixture cancel
remove_full_stack <<< 'NO' > "$BASE/output" 2>&1
assert_no_mutation
[[ ! -d "$BACKUP_ROOT" ]]
fixture wrong_host
remove_full_stack <<< 'REMOVE-STACK@different-node' > "$BASE/output" 2>&1
assert_no_mutation
fixture success
remove_full_stack <<< 'REMOVE-STACK@fixture-node' > "$BASE/output" 2>&1
[[ ! -e "$NODE_DIR" && ! -e "$STATE_DIR" && ! -e "$NGINX_ROOT" && ! -e "$WATCHDOG_STATE_DIR" ]]
[[ ! -e "$NGINX_SYSTEM_LOG_DIR" && ! -e "$NODE_LOG_DIR" && ! -e "$NGINX_LOG_DIR" ]]
[[ ! -e "$LEGACY_WEBROOT_BASE/old.example.com" && ! -e "$SYSTEMD_DIR/node-ram-watchdog.timer" ]]
jq -e 'length == 1 and .[0].Name == "/other"' "$GRAPH" >/dev/null
grep -q '^apt-get -y purge nginx nginx-common$' "$CALLS"
! grep -Eq 'autoremove|prune|docker rm other|systemctl.*(ssh|docker)' "$CALLS"
grep -q 'keep unrelated service' "$BASE/unrelated/data"
grep -q 'keep external cert' "$BASE/external-cert/privkey.pem"
backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)"
[[ -s "$backup$NODE_DIR/docker-compose.yml" && -s "$backup$CERT_DIR/privkey.pem" ]]
[[ ! -e "$backup$NODE_LOG_DIR" && ! -e "$backup$NGINX_SYSTEM_LOG_DIR" ]]
jq -e 'length == 1 and .[0].Name == "/remnanode"' "$backup/containers.json" >/dev/null
[[ "$(stat -c %a "$backup" 2>/dev/null || stat -f %Lp "$backup")" == 700 ]]
! grep -q 'SECRET_KEY=fixture' "$BASE/output"
stop_line="$(grep -n '^docker stop -t 20 remna$' "$CALLS" | cut -d: -f1)"
purge_line="$(grep -n '^apt-get -y purge' "$CALLS" | cut -d: -f1)"
delete_line="$(grep -n '^docker rm remna$' "$CALLS" | cut -d: -f1)"
(( stop_line < purge_line && purge_line < delete_line ))
remove_full_stack <<< 'REMOVE-STACK@fixture-node' > "$BASE/repeat-output" 2>&1

fixture extras
mkdir -p "$CADDY_DIR/ssl" "$CERTBOT_DIR/certs"
printf 'cert\n' > "$CERTBOT_DIR/certs/cert.pem"
printf 'key\n' > "$CADDY_DIR/ssl/key.pem"
jq --arg caddy "$CADDY_DIR" '. + [{Id:"caddy",Name:"/caddy-selfsteal",Config:{Image:"caddy:2"},Mounts:[{Type:"bind",Source:$caddy}]}]' "$GRAPH" > "$GRAPH.next"
mv "$GRAPH.next" "$GRAPH"
jq --arg certbot "$CERTBOT_DIR/certs" '. + [{Id:"certbot",Name:"/origin-renewal",Config:{Image:"certbot/certbot:latest"},Mounts:[{Type:"bind",Source:$certbot}]}]' "$GRAPH" > "$GRAPH.next"
mv "$GRAPH.next" "$GRAPH"
remove_full_stack <<< $'y\ny\nREMOVE-STACK@fixture-node' > "$BASE/output" 2>&1
[[ ! -e "$CADDY_DIR" && ! -e "$CERTBOT_DIR" ]]
jq -e 'length == 1 and .[0].Name == "/other"' "$GRAPH" >/dev/null
backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)"
[[ -s "$backup$CADDY_DIR/ssl/key.pem" && -s "$backup$CERTBOT_DIR/certs/cert.pem" ]]
jq -e 'length == 3' "$backup/containers.json" >/dev/null
grep -q '^docker stop -t 20 certbot$' "$CALLS"
grep -q '^docker rm certbot$' "$CALLS"

fixture shared_image
jq '.[1].Config.Image="remnawave/node:latest"' "$GRAPH" > "$GRAPH.next"; mv "$GRAPH.next" "$GRAPH"
remove_full_stack <<< 'REMOVE-STACK@fixture-node' > "$BASE/output" 2>&1
! grep -q '^docker image rm remnawave/node:latest$' "$CALLS"
jq -e 'length == 1 and .[0].Name == "/other"' "$GRAPH" >/dev/null

fixture keep_extras
mkdir -p "$CADDY_DIR" "$CERTBOT_DIR"
remove_full_stack <<< $'n\nn\nREMOVE-STACK@fixture-node' > "$BASE/output" 2>&1
[[ -d "$CADDY_DIR" && -d "$CERTBOT_DIR" ]]

for failure in docker_info shared_mount parent_mount named_volume wrong_image apt_extra symlink backup stop container_stop apt apt_stale container_rm unmanaged_nginx lingering_nginx; do
  fixture "$failure"
  case "$failure" in
    docker_info) DOCKER_INFO_RC=1 ;;
    shared_mount|parent_mount)
      mount="$STATE_DIR"; [[ "$failure" != parent_mount ]] || mount="$BASE"
      jq --arg source "$mount" '.[1].Mounts = [{Type:"bind",Source:$source}]' "$GRAPH" > "$GRAPH.next"; mv "$GRAPH.next" "$GRAPH" ;;
    named_volume) jq '.[0].Mounts += [{Type:"volume",Source:"/var/lib/docker/volumes/test/_data"}]' "$GRAPH" > "$GRAPH.next"; mv "$GRAPH.next" "$GRAPH" ;;
    wrong_image) jq '.[0].Config.Image="other:image"' "$GRAPH" > "$GRAPH.next"; mv "$GRAPH.next" "$GRAPH" ;;
    apt_extra) APT_EXTRA=true ;;
    symlink) command rm -rf "$STATE_DIR"; ln -s "$BASE/unrelated" "$STATE_DIR" ;;
    stop) STOP_RC=1 ;;
    container_stop) DOCKER_STOP_RC=1 ;;
    apt) APT_RC=1 ;;
    apt_stale) APT_STALE=true ;;
    container_rm) DOCKER_RM_RC=1 ;;
    unmanaged_nginx) PACKAGES_INSTALLED=false; command_exists() { return 0; } ;;
    lingering_nginx) PGREP_RC=0 ;;
  esac
  (
    if [[ "$failure" == backup ]]; then cp() { return 1; }; fi
    if remove_full_stack <<< 'REMOVE-STACK@fixture-node' > "$BASE/output" 2>&1; then
      printf 'Unexpected success: %s\n' "$failure" >&2; cat "$BASE/output" >&2; exit 1
    fi
    if [[ "$failure" == symlink ]]; then [[ -L "$STATE_DIR" && -s "$BASE/unrelated/data" ]]; else assert_intact; fi
    [[ "$failure" != backup ]] || assert_no_mutation
  )
  command_exists() { [[ "$1" != nginx || "$PACKAGES_INSTALLED" == true ]]; }
done
(
  remove_full_stack() { printf 'full-stack\n'; }
  remove_cdn_managed() { printf 'cdn-only\n'; }
  [[ "$(remove_stack_menu <<< '1' 2>/dev/null)" == full-stack ]]
  [[ "$(remove_stack_menu <<< '2' 2>/dev/null)" == cdn-only ]]
  [[ -z "$(remove_stack_menu <<< '3' 2>/dev/null)" ]]
)
printf 'PASS: full stack removal, private backup, cancel/host confirmation, optional cert/Caddy, shared mounts/volumes, purge/stop failures, unrelated data, repeat, menu\n'
