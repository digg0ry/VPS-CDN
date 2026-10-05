#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
require_root() { :; }
load_state() { :; }
systemctl() { echo 'Unexpected service change' >&2; return 1; }
docker() { echo 'Unexpected container change' >&2; return 1; }
nginx() { echo 'Unexpected Nginx change' >&2; return 1; }
fixture() {
  STATE_DIR="$TMP/$1/state"
  STATE_FILE="$STATE_DIR/state.env"
  EXPORT_DIR="$STATE_DIR/exports"
  BACKUP_ROOT="$TMP/$1/backups"
  DOMAIN=cdn.example.com CDN_PROVIDER=yandex
  ORIGIN_TARGET=192.0.2.1 ORIGIN_HOST=origin.example.com CLIENT_ADDRESS=192.0.2.2
  XHTTP_PATH=/keep/exact/path XHTTP_PORT=17443 NODE_PORT=34534
  CERT_FULLCHAIN=/keep/fullchain.pem CERT_KEY=/keep/privkey.pem
  mkdir -p "$EXPORT_DIR"
  printf 'existing state\n' > "$STATE_FILE"
  printf '{"old":true}\n' > "$EXPORT_DIR/host-extra.json"
  cp "$STATE_FILE" "$TMP/$1/state.before"
}

fixture success
refresh_exports
[[ "$EXPORT_DIR" == "$STATE_DIR/exports" ]]
[[ "$XHTTP_PATH" == /keep/exact/path && "$XHTTP_PORT" == 17443 ]]
[[ "$CERT_FULLCHAIN" == /keep/fullchain.pem && "$CERT_KEY" == /keep/privkey.pem ]]
cmp "$STATE_FILE" "$TMP/success/state.before"
jq -e '.sessionIDPlacement == "path" and .xmux.maxConcurrency == "8-16"' "$EXPORT_DIR/host-extra.json" >/dev/null
jq -e '.inbounds[0].port == 17443 and .inbounds[0].streamSettings.xhttpSettings.path == "/keep/exact/path"' "$EXPORT_DIR/server-inbound.json" >/dev/null
backup="$(find "$BACKUP_ROOT" -type f -name host-extra.json)"
jq -e '.old == true' "$backup" >/dev/null
first="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)"
refresh_exports
second="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)"
(( second == first + 1 ))

fixture failure
write_exports() { printf '{invalid\n' > "$EXPORT_DIR/host-extra.json"; return 1; }
if refresh_exports; then echo 'Unexpected failed export success' >&2; exit 1; fi
jq -e '.old == true' "$EXPORT_DIR/host-extra.json" >/dev/null
cmp "$STATE_FILE" "$TMP/failure/state.before"
[[ -z "$(find "$STATE_DIR" -maxdepth 1 -name '.exports.*' -print)" ]]

fixture empty
write_exports() {
  : > "$EXPORT_DIR/host-extra.json"
  for name in server-inbound client-template host-config connection-info; do
    printf '{}\n' > "$EXPORT_DIR/$name.json"
  done
}
if refresh_exports; then echo 'Unexpected empty JSON success' >&2; exit 1; fi
jq -e '.old == true' "$EXPORT_DIR/host-extra.json" >/dev/null
cmp "$STATE_FILE" "$TMP/empty/state.before"
printf 'PASS: export refresh, private backup, preserved domain/path/port/cert/state, no service changes, repeat and failure recovery\n'
