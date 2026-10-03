#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2.3.2"
STATE_DIR="/opt/xhttp-node"
STATE_FILE="$STATE_DIR/state.env"
WEBROOT="$STATE_DIR/www"
EXPORT_DIR="$STATE_DIR/exports"
CERT_DIR="$STATE_DIR/certs"
NGINX_SITE="/etc/nginx/sites-available/xhttp-node.conf"
NGINX_LINK="/etc/nginx/sites-enabled/xhttp-node.conf"
NGINX_SNIPPET="/etc/nginx/snippets/xhttp-node-proxy.conf"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NODE_DIR="/opt/remnanode"
LEGACY_WEBROOT_BASE="/var/www"
SYSTEMD_DIR="/etc/systemd/system"
LOGROTATE_FILE="/etc/logrotate.d/xhttp-node"
WATCHDOG_STATE_DIR="/var/lib/xhttp-node"
WATCHDOG_BIN="/usr/local/sbin/node-ram-watchdog"
CERT_SYNC_BIN="/usr/local/sbin/xhttp-node-cert-sync"
NGINX_RECOVER_BIN="/usr/local/sbin/xhttp-node-nginx-recover"
BACKUP_ROOT="/var/backups/xhttp-node"
DEFAULT_PATH="/api/v4/telemetry/collect/"
DEFAULT_XHTTP_PORT="7443"
DEFAULT_NODE_PORT="34534"
DEFAULT_ORIGIN_PROTOCOL="https"
DEFAULT_RAM_THRESHOLD="80"
DEFAULT_COOLDOWN="600"

DOMAIN=""
CDN_PROVIDER=""
ORIGIN_TARGET=""
ORIGIN_HOST=""
CLIENT_ADDRESS=""
XHTTP_PATH="$DEFAULT_PATH"
XHTTP_PORT="$DEFAULT_XHTTP_PORT"
NODE_PORT="$DEFAULT_NODE_PORT"
ORIGIN_PROTOCOL="$DEFAULT_ORIGIN_PROTOCOL"
RAM_THRESHOLD="$DEFAULT_RAM_THRESHOLD"
COOLDOWN="$DEFAULT_COOLDOWN"
CERT_FULLCHAIN=""
CERT_KEY=""

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Chạy bằng root: sudo bash $0"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

valid_domain() {
  local value="$1" label
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  [[ "$value" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "$value"
  [[ ${#labels[@]} -ge 2 ]] || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

valid_ipv4() {
  local value="$1" octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

valid_path() {
  [[ "$1" == /* && "$1" != *'?'* && "$1" != *'#'* && "$1" != *' '* ]] || return 1
}

normalize_path() {
  valid_path "$XHTTP_PATH" || die "Path không hợp lệ: $XHTTP_PATH"
  [[ "$XHTTP_PATH" == */ ]] || XHTTP_PATH="${XHTTP_PATH}/"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      DOMAIN) DOMAIN="$value" ;;
      CDN_PROVIDER) CDN_PROVIDER="$value" ;;
      ORIGIN_TARGET) ORIGIN_TARGET="$value" ;;
      ORIGIN_IP) [[ -z "$ORIGIN_TARGET" ]] && ORIGIN_TARGET="$value" ;;
      ORIGIN_HOST) ORIGIN_HOST="$value" ;;
      CLIENT_ADDRESS) CLIENT_ADDRESS="$value" ;;
      XHTTP_PATH) XHTTP_PATH="$value" ;;
      XHTTP_PORT) XHTTP_PORT="$value" ;;
      NODE_PORT) NODE_PORT="$value" ;;
      ORIGIN_PROTOCOL) ORIGIN_PROTOCOL="$value" ;;
      RAM_THRESHOLD) RAM_THRESHOLD="$value" ;;
      COOLDOWN) COOLDOWN="$value" ;;
      CERT_FULLCHAIN) CERT_FULLCHAIN="$value" ;;
      CERT_KEY) CERT_KEY="$value" ;;
    esac
  done < "$STATE_FILE"
}

save_state() {
  install -d -m 711 "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
DOMAIN=$DOMAIN
CDN_PROVIDER=$CDN_PROVIDER
ORIGIN_TARGET=$ORIGIN_TARGET
ORIGIN_HOST=$ORIGIN_HOST
CLIENT_ADDRESS=$CLIENT_ADDRESS
XHTTP_PATH=$XHTTP_PATH
XHTTP_PORT=$XHTTP_PORT
NODE_PORT=$NODE_PORT
ORIGIN_PROTOCOL=$ORIGIN_PROTOCOL
RAM_THRESHOLD=$RAM_THRESHOLD
COOLDOWN=$COOLDOWN
CERT_FULLCHAIN=$CERT_FULLCHAIN
CERT_KEY=$CERT_KEY
EOF
  chmod 600 "$STATE_FILE"
}

backup_file() {
  local source="$1"
  [[ -e "$source" || -L "$source" ]] || return 0
  local backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup$(dirname "$source")"
  cp -a "$source" "$backup$source"
  printf '%s\n' "$backup"
}

detect_origin_target() {
  local detected=""
  if command_exists ip; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  valid_ipv4 "$detected" || detected="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  valid_ipv4 "$detected" || die "Không lấy được IPv4. Nhập IP thủ công."
  ORIGIN_TARGET="$detected"
}

default_path_for_provider() {
  case "$CDN_PROVIDER" in
    yandex) printf '/api/v4/media/session/poll2/\n' ;;
    vk) printf '/uploadfiles/\n' ;;
    beeline) printf '/xh\n' ;;
    *) printf '%s\n' "$DEFAULT_PATH" ;;
  esac
}

valid_origin_target() {
  valid_ipv4 "$1" || valid_domain "$1"
}

check_inputs() {
  DOMAIN="${DOMAIN,,}"
  ORIGIN_HOST="${ORIGIN_HOST:-$DOMAIN}"
  CLIENT_ADDRESS="${CLIENT_ADDRESS:-$DOMAIN}"
  valid_domain "$DOMAIN" || die "Domain không hợp lệ: $DOMAIN"
  case "$CDN_PROVIDER" in yandex|vk|beeline) ;; *) die "CDN preset không hợp lệ: $CDN_PROVIDER" ;; esac
  valid_origin_target "$CLIENT_ADDRESS" || die "Client address phải là IPv4 hoặc hostname: $CLIENT_ADDRESS"
  valid_origin_target "$ORIGIN_TARGET" || die "Origin phải là IPv4 hoặc hostname: $ORIGIN_TARGET"
  valid_domain "$ORIGIN_HOST" || die "Origin Host/SNI không hợp lệ: $ORIGIN_HOST"
  valid_port "$XHTTP_PORT" || die "XHTTP port không hợp lệ: $XHTTP_PORT"
  valid_port "$NODE_PORT" || die "Node API port không hợp lệ: $NODE_PORT"
  (( XHTTP_PORT != 80 && XHTTP_PORT != 443 && XHTTP_PORT != NODE_PORT )) || die "Cổng XHTTP phải khác 80, 443 và Node API; dùng 7443 trên script và panel."
  (( NODE_PORT != 80 && NODE_PORT != 443 )) || die "Node API không được dùng cổng 80/443 của Nginx."
  [[ "$RAM_THRESHOLD" =~ ^[0-9]+$ ]] && (( RAM_THRESHOLD >= 50 && RAM_THRESHOLD <= 99 )) || die "RAM threshold phải từ 50 đến 99"
  [[ "$COOLDOWN" =~ ^[0-9]+$ ]] && (( COOLDOWN >= 60 )) || die "Cooldown phải >= 60 giây"
  normalize_path
}

install_packages() {
  command_exists apt-get || die "Script cần Ubuntu/Debian có apt-get"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx curl ca-certificates openssl jq dnsutils logrotate iproute2
  # Start Nginx after managed config is written; XHTTP may still occupy 443.
  systemctl enable nginx
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    return 0
  fi
  log "Cài Docker Engine và Compose"
  local installer
  installer="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$installer"
  sh "$installer"
  rm -f "$installer"
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose chưa sẵn sàng"
}

install_remnanode() {
  install_docker
  mkdir -p "$NODE_DIR" /var/log/remnanode
  if docker inspect remnanode >/dev/null 2>&1; then
    log "Đã có container remnanode; giữ nguyên compose hiện tại"
    return 0
  fi
  local secret="${NODE_SECRET_KEY:-}"
  if [[ -z "$secret" ]]; then
    read -r -s -p 'SECRET_KEY từ panel: ' secret
    printf '\n'
  fi
  [[ -n "$secret" && "$secret" != *$'\n'* && "$secret" != *$'\r'* ]] || die "SECRET_KEY rỗng hoặc chứa newline"
  local json_secret
  json_secret="$(printf '%s' "$secret" | jq -Rs .)"
  backup_file "$NODE_DIR/docker-compose.yml" >/dev/null || true
  cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      NODE_PORT: "$NODE_PORT"
      SECRET_KEY: $json_secret
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: 100m
        max-file: "5"
EOF
  chmod 600 "$NODE_DIR/docker-compose.yml"
  docker compose -f "$NODE_DIR/docker-compose.yml" config -q
  docker compose -f "$NODE_DIR/docker-compose.yml" pull
  docker compose -f "$NODE_DIR/docker-compose.yml" up -d
  unset secret json_secret
}

find_certificate() {
  local candidates=(
    "$CERT_DIR/fullchain.pem|$CERT_DIR/privkey.pem"
    "/opt/certbot/certs/live/$DOMAIN/fullchain.pem|/opt/certbot/certs/live/$DOMAIN/privkey.pem"
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem|/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "/opt/certbot/certs/live/$ORIGIN_HOST/fullchain.pem|/opt/certbot/certs/live/$ORIGIN_HOST/privkey.pem"
    "/etc/letsencrypt/live/$ORIGIN_HOST/fullchain.pem|/etc/letsencrypt/live/$ORIGIN_HOST/privkey.pem"
  ) pair cert key
  for pair in "${candidates[@]}"; do
    cert="${pair%%|*}"; key="${pair##*|}"
    if [[ -s "$cert" && -s "$key" ]] && { openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || openssl x509 -in "$cert" -noout -checkhost "$ORIGIN_HOST" >/dev/null 2>&1; }; then
      CERT_FULLCHAIN="$cert"
      CERT_KEY="$key"
      return 0
    fi
  done
  return 1
}

prepare_certificate() {
  install -d -m 700 "$CERT_DIR"
  if [[ -n "$CERT_FULLCHAIN" && -n "$CERT_KEY" ]]; then
    [[ -s "$CERT_FULLCHAIN" && -s "$CERT_KEY" ]] || die "Không tìm thấy cert/key đã nhập"
  elif ! find_certificate; then
    log "Không có cert hợp lệ cho origin; tạo self-signed cert"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
      -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN,DNS:$ORIGIN_HOST" \
      -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/privkey.pem"
    chmod 644 "$CERT_DIR/fullchain.pem"
    CERT_FULLCHAIN="$CERT_DIR/fullchain.pem"
    CERT_KEY="$CERT_DIR/privkey.pem"
    warn "Đang dùng self-signed cert. CDN phải tắt kiểm tra certificate origin."
  fi
  if [[ "$CERT_FULLCHAIN" != "$CERT_DIR/fullchain.pem" || "$CERT_KEY" != "$CERT_DIR/privkey.pem" ]]; then
    install -m 644 "$CERT_FULLCHAIN" "$CERT_DIR/fullchain.pem"
    install -m 600 "$CERT_KEY" "$CERT_DIR/privkey.pem"
    CERT_FULLCHAIN="$CERT_DIR/fullchain.pem"
    CERT_KEY="$CERT_DIR/privkey.pem"
  fi
  { openssl x509 -in "$CERT_FULLCHAIN" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || openssl x509 -in "$CERT_FULLCHAIN" -noout -checkhost "$ORIGIN_HOST" >/dev/null 2>&1; } || die "Cert không khớp CDN domain hoặc Origin Host/SNI"
}

write_fake_site() {
  # Workers need directory traversal; state, keys and exports remain private.
  install -d -m 711 "$STATE_DIR"
  [[ -s "$WEBROOT/index.html" ]] && return 0
  install -d -m 755 "$WEBROOT"
  cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Journal</title>
<style>body{margin:0;background:#f4f5f3;color:#202522;font:18px/1.7 system-ui,sans-serif}main{max-width:820px;margin:auto;padding:52px 24px}h1{font-size:42px;margin:0 0 12px}p{max-width:680px}section{margin-top:38px;padding-top:24px;border-top:1px solid #cdd2cd}footer{margin-top:52px;font-size:14px;color:#65706a}</style></head>
<body><main><h1>Journal</h1><p>A journal of places, photographs and everyday observations.</p><section><h2>A quiet morning</h2><p>The light changes slowly over the water. A few minutes outside can be enough to notice something new.</p></section><footer>Journal · Personal journal</footer></main></body></html>
HTML
  chmod 644 "$WEBROOT/index.html"
}

install_web_template() (
  set -Eeuo pipefail
  local folder="$1" staging source_dir backup revision
  case "$folder" in
    10gag|convertit|converter|downloader|filecloud|games-site|modmanager|speedtest|YouTube|503-1|503-2) ;;
    *) die "Template không hợp lệ" ;;
  esac
  [[ "$WEBROOT" == "$STATE_DIR/www" && ! -L "$WEBROOT" ]] || die "Webroot không hợp lệ"
  install -d -m 711 "$STATE_DIR"
  staging="$(mktemp -d "$STATE_DIR/.web-download.XXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/DigneZzZ/remnawave-scripts.git "$staging/repo"
  git -C "$staging/repo" sparse-checkout set "sni-templates/$folder"
  source_dir="$staging/repo/sni-templates/$folder"
  [[ -s "$source_dir/index.html" ]] || die "Template thiếu index.html; giữ web cũ"
  [[ -z "$(find "$source_dir" -type l -print -quit)" ]] || die "Template chứa symlink; giữ web cũ"
  [[ -s "$staging/repo/LICENSE" ]] || die "Thiếu license template; giữ web cũ"
  revision="$(git -C "$staging/repo" rev-parse HEAD)"
  mkdir "$staging/site"
  cp -R "$source_dir/." "$staging/site/"
  find "$staging/site" -type d -exec chmod 755 {} +
  find "$staging/site" -type f -exec chmod 644 {} +
  install -d -m 700 "$BACKUP_ROOT"
  backup="$(mktemp -d "$BACKUP_ROOT/web-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  if [[ -e "$WEBROOT" ]]; then
    cp -a "$WEBROOT" "$backup/www"
    mv "$WEBROOT" "$staging/previous"
  fi
  if ! mv "$staging/site" "$WEBROOT"; then
    [[ ! -d "$staging/previous" ]] || mv "$staging/previous" "$WEBROOT"
    die "Không thay được web; backup: $backup"
  fi
  install -m 600 "$staging/repo/LICENSE" "$STATE_DIR/web-template-LICENSE"
  printf 'source=https://github.com/DigneZzZ/remnawave-scripts\nrevision=%s\ntemplate=%s\n' \
    "$revision" "$folder" > "$STATE_DIR/web-template-source.txt"
  log "Đã cài template $folder. Backup: $backup"
)

web_template_menu() {
  require_root
  load_state
  if [[ ! -s "$STATE_FILE" || ! -s "$NGINX_SITE" ]]; then
    warn "Cần hoàn tất Setup trước để có domain, cert và Nginx phục vụ web."
    return 0
  fi
  nginx -t || return 0
  local template
  PS3='Chọn mẫu web: '
  select template in "10gag" "convertit" "converter" "downloader" "filecloud" \
    "games-site" "modmanager" "speedtest" "YouTube" "503-1" "503-2" "Quay lại"; do
    case "$template" in
      "Quay lại") return 0 ;;
      "") warn "Lựa chọn không hợp lệ"; continue ;;
    esac
    if ! command_exists git; then
      apt-get update
      apt-get install -y git ca-certificates
    fi
    install_web_template "$template"
    printf 'Web: https://%s/\n' "$DOMAIN"
    return 0
  done
}

proxy_location() {
  cat <<EOF
    location = ${XHTTP_PATH%/} {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        include $NGINX_SNIPPET;
    }
    location ^~ $XHTTP_PATH {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        include $NGINX_SNIPPET;
    }
EOF
}

local_ipv4() {
  local address=""
  if command_exists ip; then
    address="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  valid_ipv4 "$address" && printf '%s\n' "$address"
}

legacy_cdn_paths() {
  local dir item target referenced file selected root
  local -a configs=()
  LEGACY_CDN_PATHS=()
  for dir in "$(dirname "$NGINX_LINK")" "$(dirname "$NGINX_SITE")" "$NGINX_CONF_DIR"; do
    [[ -d "$dir" ]] || continue
    for item in "$dir"/*; do
      [[ -f "$item" ]] || continue
      configs+=("$item")
      [[ "$item" == "$NGINX_SITE" || "$item" == "$NGINX_LINK" ]] && continue
      # Only recognize our marker or the reserved upstream from older installs.
      grep -qsE '^# Managed by xhttp-node.sh |^[[:space:]]*(upstream[[:space:]]+cdn_xhttp_xray[[:space:]]*\{|proxy_pass[[:space:]]+http://cdn_xhttp_xray[[:space:]]*;)' "$item" || continue
      if [[ -L "$item" ]]; then
        target="$(readlink -f "$item")" || return 1
        case "$target" in
          "$(readlink -f "$(dirname "$NGINX_SITE")")"/*|"$(readlink -f "$(dirname "$NGINX_LINK")")"/*|"$(readlink -f "$NGINX_CONF_DIR")"/*) ;;
          *) warn "Site CDN trỏ ra ngoài thư mục Nginx; cần kiểm tra thủ công: $item"; return 1 ;;
        esac
      fi
      LEGACY_CDN_PATHS+=("$item")
    done
  done
  # Retain the shared log format when an unrelated site still uses it.
  item="$NGINX_CONF_DIR/cdn-log-format.conf"
  if [[ -f "$item" ]] && grep -qE '^[[:space:]]*log_format[[:space:]]+cdn_json' "$item"; then
    referenced=false
    for file in "${configs[@]}"; do
      [[ "$file" == "$item" ]] && continue
      selected=false
      for target in "${LEGACY_CDN_PATHS[@]}"; do [[ "$file" != "$target" ]] || selected=true; done
      "$selected" && continue
      if grep -qsE '^[[:space:]]*access_log[[:space:]].*[[:space:]]cdn_json[[:space:]]*;' "$file"; then referenced=true; fi
    done
    "$referenced" || LEGACY_CDN_PATHS+=("$item")
  fi
  # Remove only domain-specific legacy webroots not used by retained sites.
  for file in "${LEGACY_CDN_PATHS[@]}"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r root; do
      [[ "$root" == "$LEGACY_WEBROOT_BASE/"* && ! -L "$root" && -d "$root" ]] || continue
      valid_domain "${root#"$LEGACY_WEBROOT_BASE/"}" || continue
      referenced=false
      for item in "${configs[@]}"; do
        selected=false
        for target in "${LEGACY_CDN_PATHS[@]}"; do [[ "$item" != "$target" ]] || selected=true; done
        "$selected" && continue
        if grep -qF "root $root;" "$item"; then referenced=true; fi
      done
      if ! "$referenced"; then
        selected=false
        for target in "${LEGACY_CDN_PATHS[@]}"; do [[ "$root" != "$target" ]] || selected=true; done
        "$selected" || LEGACY_CDN_PATHS+=("$root")
      fi
    done < <(awk '$1 == "root" && NF == 2 {sub(/;$/, "", $2); print $2}' "$file")
  done
}

has_legacy_cdn() {
  legacy_cdn_paths || return 1
  ((${#LEGACY_CDN_PATHS[@]} > 0))
}

backup_legacy_cdn() {
  local backup="$1" item
  for item in "${LEGACY_CDN_PATHS[@]}"; do
    mkdir -p "$backup$(dirname "$item")" || return 1
    cp -a "$item" "$backup$item" || return 1
  done
}

stop_legacy_cdn_units() {
  local unit
  for unit in xhttp-node-nginx-recover xhttp-node-cert-sync node-ram-watchdog; do
    if [[ -e "$SYSTEMD_DIR/$unit.timer" ]]; then
      systemctl disable --now "$unit.timer" || return 1
    fi
    if [[ -e "$SYSTEMD_DIR/$unit.service" ]]; then
      systemctl stop "$unit.service" || return 1
    fi
  done
}

nginx_tls_listeners() {
  local bind_ip version listen_options="ssl http2" modern=false
  bind_ip="$(local_ipv4 || true)"
  version="$(nginx -v 2>&1)" || return 1
  if [[ "$version" =~ nginx/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    if (( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && (BASH_REMATCH[2] > 25 || (BASH_REMATCH[2] == 25 && BASH_REMATCH[3] >= 1))) )); then
      modern=true
      listen_options=ssl
    fi
  fi
  if [[ -n "$bind_ip" ]]; then
    printf '    listen %s:443 %s;\n' "$bind_ip" "$listen_options"
  else
    printf '    listen 443 %s;\n' "$listen_options"
  fi
  printf '    listen [::]:443 %s;\n' "$listen_options"
  "$modern" && printf '    http2 on;\n'
  return 0
}

nginx_ports_available() {
  local listeners line
  listeners="$(ss -H -ltnp '( sport = :443 )')" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Unknown owners block startup; never kill another service.
    if [[ "$line" != *'("nginx",'* ]]; then
      warn "TCP 443 có listener không thuộc Nginx: $line"
      return 1
    fi
  done <<< "$listeners"
}

apply_nginx_service() {
  nginx_ports_available || return 1
  nginx -t || return 1
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx || return 1
  else
    systemctl start nginx || return 1
  fi
  systemctl is-active --quiet nginx
}

report_nginx_readiness() {
  local listeners
  if ! systemctl is-active --quiet nginx; then
    warn "Đã lưu cấu hình nhưng Nginx chưa chạy. Xem journalctl -u nginx -n 50."
    warn "Nếu core chiếm 443, chuyển inbound trên panel sang 127.0.0.1:$XHTTP_PORT."
    warn "Timer thử bật Nginx mỗi phút khi TCP 443 hết xung đột."
  fi
  listeners="$(ss -H -ltn "sport = :$XHTTP_PORT")" || return 1
  if ! awk -v target="127.0.0.1:$XHTTP_PORT" '$4 == target {found=1} END {exit !found}' <<< "$listeners"; then
    warn "Chưa thấy listener 127.0.0.1:$XHTTP_PORT. Cần áp dụng inbound trên panel."
  fi
  log "Trạng thái service không xác nhận tunnel hoạt động; cần test profile qua CDN."
}

stop_nginx_recovery() {
  systemctl disable --now xhttp-node-nginx-recover.timer >/dev/null 2>&1 || true
  systemctl stop xhttp-node-nginx-recover.service >/dev/null 2>&1 || true
}

write_nginx() {
  install -d -m 755 "$(dirname "$NGINX_SNIPPET")" "$(dirname "$NGINX_SITE")" "$(dirname "$NGINX_LINK")"
  local server_names="$DOMAIN" listeners
  listeners="$(nginx_tls_listeners)" || return 1
  [[ "$ORIGIN_HOST" != "$DOMAIN" ]] && server_names+=" $ORIGIN_HOST"
  cat > "$NGINX_SNIPPET" <<'EOF'
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https;
proxy_buffering off;
proxy_request_buffering off;
proxy_cache off;
proxy_intercept_errors off;
proxy_connect_timeout 15s;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
send_timeout 3600s;
client_max_body_size 0;
EOF
  backup_file "$NGINX_SITE" >/dev/null || true
  cat > "$NGINX_SITE" <<EOF
# Managed by xhttp-node.sh v$SCRIPT_VERSION
server {
$listeners
    server_name $server_names;
    ssl_certificate $CERT_FULLCHAIN;
    ssl_certificate_key $CERT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    root $WEBROOT;
    index index.html;
    access_log /var/log/nginx/xhttp-node.access.log;
    error_log /var/log/nginx/xhttp-node.error.log warn;

    location = /healthz {
        default_type text/plain;
        add_header Cache-Control no-store always;
        return 200 "xhttp-node-origin-ok\\n";
    }

$(proxy_location)
    location / {
        add_header Cache-Control no-store always;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
  ln -sfn "$NGINX_SITE" "$NGINX_LINK"
  nginx -t
  if ! apply_nginx_service; then
    warn "Chưa áp dụng được Nginx; tiếp tục lưu cấu hình và cài timer phục hồi."
  fi
}

write_nginx_recovery() {
  {
    cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EOF
    printf 'managed_site=%q\n' "$NGINX_LINK"
    declare -f warn nginx_ports_available apply_nginx_service
    cat <<'EOF'
[[ -s "$managed_site" ]] || exit 0
# Do not interrupt an active instance or a pending systemd operation.
state="$(systemctl show -p ActiveState --value nginx)" || exit 1
case "$state" in inactive|failed) ;; *) exit 0 ;; esac
apply_nginx_service
EOF
  } > "$NGINX_RECOVER_BIN"
  chmod 700 "$NGINX_RECOVER_BIN"
  install -d -m 755 "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/xhttp-node-nginx-recover.service" <<EOF
[Unit]
Description=Recover XHTTP Nginx listener after port conflict
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$NGINX_RECOVER_BIN
TimeoutStartSec=60
EOF
  cat > "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer" <<'EOF'
[Unit]
Description=Retry XHTTP Nginx every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xhttp-node-nginx-recover.timer
}

write_cert_sync() {
  cat > "$CERT_SYNC_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=/opt/xhttp-node/state.env
[[ -r "$state" ]] || exit 0
source "$state"
ORIGIN_HOST="${ORIGIN_HOST:-$DOMAIN}"
src_cert="/opt/certbot/certs/live/$DOMAIN/fullchain.pem"
src_key="/opt/certbot/certs/live/$DOMAIN/privkey.pem"
if [[ ! -s "$src_cert" || ! -s "$src_key" ]]; then
  src_cert="/opt/certbot/certs/live/$ORIGIN_HOST/fullchain.pem"
  src_key="/opt/certbot/certs/live/$ORIGIN_HOST/privkey.pem"
fi
dst_cert=/opt/xhttp-node/certs/fullchain.pem
dst_key=/opt/xhttp-node/certs/privkey.pem
[[ -s "$src_cert" && -s "$src_key" ]] || exit 0
openssl x509 -in "$src_cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || \
  openssl x509 -in "$src_cert" -noout -checkhost "$ORIGIN_HOST" >/dev/null 2>&1 || exit 0
changed=0
if ! cmp -s "$src_cert" "$dst_cert"; then install -m 644 "$src_cert" "$dst_cert"; changed=1; fi
if ! cmp -s "$src_key" "$dst_key"; then install -m 600 "$src_key" "$dst_key"; changed=1; fi
if (( changed )); then nginx -t >/dev/null && systemctl reload nginx; fi
EOF
  chmod 700 "$CERT_SYNC_BIN"
  cat > /etc/systemd/system/xhttp-node-cert-sync.service <<'EOF'
[Unit]
Description=Sync origin certificate for XHTTP
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xhttp-node-cert-sync
EOF
  cat > /etc/systemd/system/xhttp-node-cert-sync.timer <<'EOF'
[Unit]
Description=Check XHTTP origin certificate every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xhttp-node-cert-sync.timer
}

write_watchdog() {
  cat > "$WATCHDOG_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/node-ram-watchdog.lock
flock -n 9 || exit 0
state=/var/lib/xhttp-node/last-restart
threshold=80
cooldown=600
total=0
available=0
read -r total available < <(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t,a}' /proc/meminfo)
(( total > 0 && available >= 0 )) || exit 1
used=$(( (total - available) * 100 / total ))
(( used >= threshold )) || exit 0
running="$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || true)"
[[ "$running" == true ]] || exit 0
now="$(date +%s)"
last=0
[[ -r "$state" ]] && read -r last < "$state" || true
[[ "$last" =~ ^[0-9]+$ ]] || last=0
(( now - last >= cooldown )) || exit 0
install -d -m 755 "$(dirname "$state")"
printf '%s\n' "$now" > "$state"
logger -t node-ram-watchdog "RAM ${used}% >= ${threshold}%; restarting remnanode only"
timeout 90 docker restart -t 20 remnanode
EOF
  chmod 700 "$WATCHDOG_BIN"
  cat > /etc/systemd/system/node-ram-watchdog.service <<'EOF'
[Unit]
Description=Restart remnanode when host RAM is high
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/node-ram-watchdog
TimeoutStartSec=100
EOF
  cat > /etc/systemd/system/node-ram-watchdog.timer <<'EOF'
[Unit]
Description=Check remnanode RAM every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now node-ram-watchdog.timer
}

write_logrotate() {
  cat > /etc/logrotate.d/xhttp-node <<EOF
/var/log/nginx/xhttp-node*.log {
    daily
    size 50M
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}
EOF
}

write_exports() {
  local cookie extra_file
  cookie="session_id=$(openssl rand -hex 16)"
  install -d -m 700 "$EXPORT_DIR"
  extra_file="$EXPORT_DIR/host-extra.json"
  case "$CDN_PROVIDER" in
    yandex)
      jq -n '{
        xmux: {
          cMaxReuseTimes: "0",
          maxConnections: "1",
          hKeepAlivePeriod: 0,
          hMaxRequestTimes: "0",
          hMaxReusableSecs: "0"
        },
        seqKey: "offset",
        seqPlacement: "query",
        sessionIDKey: "auth",
        sessionIDPlacement: "query",
        sessionIDTable: "",
        sessionIDLength: "16-32",
        uplinkHTTPMethod: "GET",
        uplinkDataPlacement: "header",
        uplinkDataKey: "X-Playback-Token",
        uplinkChunkSize: "2000-3000",
        xPaddingBytes: "100-1000",
        scMaxBufferedPosts: 100,
        scMaxEachPostBytes: 8192,
        scMinPostsIntervalMs: 30,
        serverMaxHeaderBytes: 32768
      }' > "$extra_file"
      ;;
    vk)
      jq -n --arg cookie "$cookie" \
        '{xPaddingKey:"_dc",xPaddingHeader:"X-Cache",xPaddingMethod:"tokenish",uplinkHTTPMethod:"GET",uplinkDataKey:"X-Playback-Token",uplinkDataPlacement:"header",sessionIDKey:"media_sid",sessionIDPlacement:"cookie",seqKey:"offset",seqPlacement:"query",headers:{Accept:"*/*",Cookie:$cookie,Pragma:"no-cache", "Cache-Control":"no-cache"},xPaddingObfsMode:true,xPaddingPlacement:"queryInHeader"}' > "$extra_file"
      ;;
    beeline)
      jq -n --arg domain "$DOMAIN" --arg cookie "$cookie" \
        '{xmux:{maxConcurrency:"1"},seqKey:"chunk_id",seqPlacement:"query",headers:{Accept:"*/*",Cookie:$cookie,Origin:("https://"+$domain+"/"),Referer:("https://"+$domain+"/"),"User-Agent":"Mozilla/5.0(WindowsNT10.0;Win64;x64;rv:151.0)Gecko/20100101Firefox/151.0","Sec-Fetch-Dest":"empty","Sec-Fetch-Mode":"cors","Sec-Fetch-Site":"same-origin","Accept-Language":"ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"},sessionIDKey:"auth",sessionIDPlacement:"query",sessionIDTable:"Base62",sessionIDLength:"16-32",noSSEHeader:true,noGRPCHeader:true,xPaddingBytes:"50-150",xPaddingHeader:"X-Api-Key",xPaddingMethod:"tokenish",xPaddingObfsMode:true,xPaddingPlacement:"header",uplinkHTTPMethod:"POST",downloadHTTPMethod:"GET",uplinkDataPlacement:"body",scMaxBufferedPosts:100,scMaxEachPostBytes:3000000,scMaxConcurrentPosts:10,scMinPostsIntervalMs:"5-10",serverMaxHeaderBytes:32768}' > "$extra_file"
      ;;
  esac
  local outer='{}'
  if [[ "$CDN_PROVIDER" == beeline ]]; then
    outer='{"noSSEHeader":true,"noGRPCHeader":true,"scMaxBufferedPosts":100,"scMaxEachPostBytes":3000000,"scMaxConcurrentPosts":10,"scMinPostsIntervalMs":5,"serverMaxHeaderBytes":32768}'
  fi
  jq -n --slurpfile extra "$EXPORT_DIR/host-extra.json" --arg path "$XHTTP_PATH" --argjson port "$XHTTP_PORT" --argjson outer "$outer" \
    '{log:{loglevel:"warning"},inbounds:[{tag:"CDN_XHTTP",listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]},streamSettings:{network:"xhttp",security:"none",xhttpSettings:(({mode:"packet-up",path:$path,extra:$extra[0]} + $outer))}}],outbounds:[{tag:"DIRECT",protocol:"freedom"},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{type:"field",ip:["geoip:private"],outboundTag:"BLOCK"},{type:"field",domain:["geosite:private"],outboundTag:"BLOCK"},{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}]}}' > "$EXPORT_DIR/server-inbound.json"
  jq -n --slurpfile extra "$EXPORT_DIR/host-extra.json" --arg path "$XHTTP_PATH" --arg address "$CLIENT_ADDRESS" --arg domain "$DOMAIN" \
    '{remarks:"XHTTP test",outbounds:[{tag:"proxy",protocol:"vless",settings:{vnext:[{address:$address,port:443,users:[{id:"REPLACE_WITH_VLESS_UUID",encryption:"none"}]}]},streamSettings:{network:"xhttp",security:"tls",tlsSettings:{serverName:$domain,alpn:["h2","http/1.1"],fingerprint:"firefox",allowInsecure:false},xhttpSettings:{host:$domain,mode:"packet-up",path:$path,extra:$extra[0]} }},{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],routing:{domainStrategy:"AsIs",rules:[{type:"field",network:"tcp,udp",outboundTag:"proxy"}]}}' > "$EXPORT_DIR/client-template.json"
  jq empty "$EXPORT_DIR/host-extra.json" "$EXPORT_DIR/server-inbound.json" "$EXPORT_DIR/client-template.json"
  jq -n --arg path "$XHTTP_PATH" --slurpfile extra "$EXPORT_DIR/host-extra.json" \
    '{mode:"packet-up",path:$path,extra:$extra[0]}' > "$EXPORT_DIR/host-config.json"
  jq empty "$EXPORT_DIR/host-config.json"
  jq -n --arg provider "$CDN_PROVIDER" --arg domain "$DOMAIN" --arg origin "$ORIGIN_TARGET" \
    --arg originHost "$ORIGIN_HOST" --arg clientAddress "$CLIENT_ADDRESS" --arg path "$XHTTP_PATH" --arg protocol "$ORIGIN_PROTOCOL" \
    '{provider:$provider,cdnDomain:$domain,originTarget:$origin,originProtocol:$protocol,originHostSni:$originHost,clientAddress:$clientAddress,path:$path,port:443}' \
    > "$EXPORT_DIR/connection-info.json"
  jq empty "$EXPORT_DIR/connection-info.json"
}

check_dns() {
  local values origin_values
  values="$(dig +short A "$DOMAIN" 2>/dev/null | paste -sd' ' - || true)"
  if [[ -n "$values" ]]; then
    log "A record $DOMAIN: $values"
  else
    warn "Chưa resolve được A record cho $DOMAIN"
  fi
  if valid_ipv4 "$ORIGIN_TARGET"; then
    log "Origin target: $ORIGIN_TARGET"
  else
    origin_values="$(dig +short A "$ORIGIN_TARGET" 2>/dev/null | paste -sd' ' - || true)"
    [[ -n "$origin_values" ]] && log "A record origin $ORIGIN_TARGET: $origin_values" || warn "Chưa resolve được origin hostname $ORIGIN_TARGET"
  fi
}

check_ports() {
  ss -ltnp 2>/dev/null | grep -E ":443[[:space:]]|:${XHTTP_PORT}[[:space:]]|:${NODE_PORT}[[:space:]]" || true
  ss -lunp 2>/dev/null | grep -E ':443[[:space:]]' || true
}

check_status() {
  load_state
  printf '\nXHTTP node %s\n' "$SCRIPT_VERSION"
  printf 'Provider: %s\nCDN domain: %s\nOrigin target: %s\nOrigin Host/SNI: %s\nClient address: %s\nPath: %s\nXHTTP port: %s\n' "$CDN_PROVIDER" "$DOMAIN" "$ORIGIN_TARGET" "$ORIGIN_HOST" "$CLIENT_ADDRESS" "$XHTTP_PATH" "$XHTTP_PORT"
  check_dns
  check_ports
  if systemctl is-active --quiet nginx; then
    log "Nginx: active"
  else
    warn "Nginx: inactive; kiểm tra cổng 443 và log timer xhttp-node-nginx-recover."
  fi
  free -h
  systemctl --no-pager --full status node-ram-watchdog.timer 2>/dev/null || true
  systemctl --no-pager --full status xhttp-node-cert-sync.timer 2>/dev/null || true
  systemctl --no-pager --full status xhttp-node-nginx-recover.timer 2>/dev/null || true
  if [[ -n "$DOMAIN" && -n "$ORIGIN_TARGET" ]]; then
    if valid_ipv4 "$ORIGIN_TARGET"; then
      curl -ksS --noproxy '*' --resolve "$DOMAIN:443:$ORIGIN_TARGET" --max-time 15 -D - -o /dev/null "https://$DOMAIN/healthz" || true
    else
      curl -ksS --noproxy '*' --connect-to "$DOMAIN:443:$ORIGIN_TARGET:443" --max-time 15 -D - -o /dev/null "https://$DOMAIN/healthz" || true
    fi
  fi
  if [[ -f "$EXPORT_DIR/host-config.json" ]]; then jq '{mode,path,extra}' "$EXPORT_DIR/host-config.json"; fi
}

backup_managed() {
  local stamp item
  install -d -m 700 "$BACKUP_ROOT" || return 1
  stamp="$(mktemp -d "$BACKUP_ROOT/reinstall-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  for item in "$STATE_DIR" "$NODE_DIR" "$WATCHDOG_STATE_DIR" "$NGINX_SITE" "$NGINX_LINK" \
    "$NGINX_SNIPPET" "$LOGROTATE_FILE" \
    "$SYSTEMD_DIR/node-ram-watchdog.service" "$SYSTEMD_DIR/node-ram-watchdog.timer" \
    "$SYSTEMD_DIR/xhttp-node-cert-sync.service" "$SYSTEMD_DIR/xhttp-node-cert-sync.timer" \
    "$SYSTEMD_DIR/xhttp-node-nginx-recover.service" "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer" \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN"; do
    [[ -e "$item" || -L "$item" ]] || continue
    mkdir -p "$stamp$(dirname "$item")" || return 1
    cp -a "$item" "$stamp$item" || return 1
  done
  printf '%s\n' "$stamp"
}

backup_cdn_managed() {
  local stamp item
  install -d -m 700 "$BACKUP_ROOT" || return 1
  stamp="$(mktemp -d "$BACKUP_ROOT/cdn-remove-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  for item in "$STATE_DIR" "$NGINX_SITE" "$NGINX_LINK" "$NGINX_SNIPPET" \
    "$LOGROTATE_FILE" "$WATCHDOG_STATE_DIR" \
    "$SYSTEMD_DIR/node-ram-watchdog.service" "$SYSTEMD_DIR/node-ram-watchdog.timer" \
    "$SYSTEMD_DIR/xhttp-node-cert-sync.service" "$SYSTEMD_DIR/xhttp-node-cert-sync.timer" \
    "$SYSTEMD_DIR/xhttp-node-nginx-recover.service" "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer" \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN"; do
    [[ -e "$item" || -L "$item" ]] || continue
    mkdir -p "$stamp$(dirname "$item")" || return 1
    cp -a "$item" "$stamp$item" || return 1
  done
  printf '%s\n' "$stamp"
}

remove_cdn_managed() {
  require_root
  local answer backup item unit
  printf '\nGỡ cấu hình CDN do xhttp-node.sh quản lý.\n'
  printf 'Máy hiện tại: %s\n' "$(hostname)"
  ip -brief address 2>/dev/null || true
  printf 'Giữ remnanode, /opt/certbot, Docker và dịch vụ không do script tạo.\n'
  printf 'Xóa web giả, Nginx origin, exports, watchdog và timer. Giữ cert và backup.\n'
  read -r -p 'Gõ REMOVE-CDN để xác nhận trên máy này: ' answer || return 0
  [[ "$answer" == REMOVE-CDN ]] || { warn "Đã hủy."; return 0; }

  [[ ! -L "$STATE_DIR" && ! -L "$WATCHDOG_STATE_DIR" ]] || return 1
  backup="$(backup_cdn_managed)" || { warn "Backup thất bại; chưa xóa gì."; return 1; }
  log "Backup CDN: $backup"

  if [[ -e "$NGINX_SITE" || -L "$NGINX_SITE" ]]; then
    if [[ -L "$NGINX_SITE" ]] || ! grep -q '^# Managed by xhttp-node.sh ' "$NGINX_SITE"; then
      warn "Không xóa site không do script quản lý: $NGINX_SITE"
      return 1
    fi
  fi
  if [[ -e "$NGINX_LINK" || -L "$NGINX_LINK" ]]; then
    if [[ ! -L "$NGINX_LINK" ]] || [[ "$(readlink -f "$NGINX_LINK" 2>/dev/null || true)" != "$(readlink -f "$NGINX_SITE" 2>/dev/null || true)" ]]; then
      warn "Không xóa site enabled không do script quản lý: $NGINX_LINK"
      return 1
    fi
  fi
  for unit in xhttp-node-nginx-recover xhttp-node-cert-sync node-ram-watchdog; do
    if [[ -e "$SYSTEMD_DIR/$unit.timer" ]]; then
      systemctl disable --now "$unit.timer" || return 1
    fi
    if [[ -e "$SYSTEMD_DIR/$unit.service" ]]; then
      systemctl stop "$unit.service" || return 1
    fi
  done
  rm -f "$NGINX_LINK" "$NGINX_SITE" "$NGINX_SNIPPET" || return 1
  if command_exists nginx; then
    if ! nginx -t || { systemctl is-active --quiet nginx && ! systemctl reload nginx; }; then
      for item in "$NGINX_SITE" "$NGINX_LINK" "$NGINX_SNIPPET"; do
        if [[ -e "$backup$item" || -L "$backup$item" ]]; then
          cp -a "$backup$item" "$item" || return 1
        fi
      done
      warn "Nginx không áp dụng được. Đã trả file về; dữ liệu còn nguyên, timer đang dừng. Backup: $backup"
      return 1
    fi
  fi

  rm -f "$LOGROTATE_FILE" \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN" \
    "$SYSTEMD_DIR/node-ram-watchdog.service" "$SYSTEMD_DIR/node-ram-watchdog.timer" \
    "$SYSTEMD_DIR/xhttp-node-cert-sync.service" "$SYSTEMD_DIR/xhttp-node-cert-sync.timer" \
    "$SYSTEMD_DIR/xhttp-node-nginx-recover.service" "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer"
  # Even copied certs may be used by a non-CDN inbound.
  rm -rf -- "$WEBROOT" "$EXPORT_DIR"
  rm -f "$STATE_FILE" "$STATE_DIR/web-template-source.txt" "$STATE_DIR/web-template-LICENSE" \
    "$WATCHDOG_STATE_DIR/last-restart"
  rmdir "$WATCHDOG_STATE_DIR" "$STATE_DIR" 2>/dev/null || true
  systemctl daemon-reload
  log "Đã gỡ CDN managed. Giữ remnanode và cert, kể cả $CERT_DIR."
  warn "Đổi profile trên Remnawave về node thường; script không sửa panel."
  warn "DNS/resource CDN, Caddy và cấu hình do công cụ khác tạo không bị xóa."
  ss -ltnp '( sport = :80 or sport = :443 or sport = :7443 )' || true
}

clean_managed() {
  require_root
  local backup item recreate_node="${1:-Y}"
  [[ ! -L "$STATE_DIR" && ! -L "$NODE_DIR" && ! -L "$WATCHDOG_STATE_DIR" ]] || { warn "Thư mục managed là symlink; cần kiểm tra thủ công."; return 1; }
  legacy_cdn_paths || return 1
  backup="$(backup_managed)" || { warn "Backup thất bại; chưa dừng/xóa gì."; return 1; }
  backup_legacy_cdn "$backup" || { warn "Backup CDN cũ thất bại; chưa dừng/xóa gì."; return 1; }
  log "Backup managed files: $backup"
  for item in "${LEGACY_CDN_PATHS[@]}"; do printf 'CDN cũ: %s\n' "$item"; done
  stop_legacy_cdn_units || { warn "Không dừng được timer/service; chưa xóa file. Backup: $backup"; return 1; }
  if systemctl is-active --quiet nginx; then
    systemctl stop nginx || { warn "Không dừng được Nginx cũ; chưa xóa cấu hình."; return 1; }
  fi
  if [[ ! "$recreate_node" =~ ^[Nn]$ ]]; then
    if command_exists docker && docker inspect remnanode >/dev/null 2>&1; then
      docker stop -t 20 remnanode >/dev/null || return 1
      docker rm remnanode >/dev/null || return 1
    fi
    rm -rf -- "$NODE_DIR" || return 1
  fi
  for item in "${LEGACY_CDN_PATHS[@]}"; do rm -rf -- "$item" || return 1; done
  rm -rf -- "$STATE_DIR" "$WATCHDOG_STATE_DIR" || return 1
  # Copied certs may still serve a non-CDN inbound; retain them even on reinstall.
  if [[ -d "$backup$CERT_DIR" ]]; then
    mkdir -p "$(dirname "$CERT_DIR")" || return 1
    cp -a "$backup$CERT_DIR" "$CERT_DIR" || return 1
  fi
  rm -f "$NGINX_LINK" "$NGINX_SITE" "$NGINX_SNIPPET" "$LOGROTATE_FILE" \
    "$SYSTEMD_DIR/node-ram-watchdog.service" "$SYSTEMD_DIR/node-ram-watchdog.timer" \
    "$SYSTEMD_DIR/xhttp-node-cert-sync.service" "$SYSTEMD_DIR/xhttp-node-cert-sync.timer" \
    "$SYSTEMD_DIR/xhttp-node-nginx-recover.service" "$SYSTEMD_DIR/xhttp-node-nginx-recover.timer" \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN" "$NGINX_RECOVER_BIN" || return 1
  systemctl daemon-reload || return 1
  log "Đã dừng và dọn CDN cũ; Nginx chỉ bật lại sau khi tạo cấu hình mới. Giữ cert và dịch vụ khác."
}

select_provider() {
  local choice
  printf '\nChọn CDN preset:\n'
  PS3='Chọn số: '
  select choice in "Yandex - GET + header" "VK - GET + header/cookie" "Beeline - POST + body"; do
    case "$REPLY" in
      1) CDN_PROVIDER=yandex; break ;;
      2) CDN_PROVIDER=vk; break ;;
      3) CDN_PROVIDER=beeline; break ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
  done
}

reinstall_clean() {
  write_setup reinstall
}

check_files() {
  local item
  load_state
  for item in "$STATE_FILE" "$NGINX_SITE" "$WEBROOT/index.html" "$EXPORT_DIR/host-extra.json" "$EXPORT_DIR/host-config.json" "$EXPORT_DIR/server-inbound.json" "$EXPORT_DIR/client-template.json" "$EXPORT_DIR/connection-info.json" "$WATCHDOG_BIN"; do
    if [[ -e "$item" ]]; then printf 'OK   %s\n' "$item"; else printf 'MISS %s\n' "$item"; fi
  done
  if [[ -n "$CERT_FULLCHAIN" && -s "$CERT_FULLCHAIN" ]]; then
    openssl x509 -in "$CERT_FULLCHAIN" -noout -subject -issuer -dates -checkhost "$DOMAIN" || true
  fi
}

write_setup() {
  require_root
  load_state
  local answer install_node cert cert_key path_default force_reinstall="${1:-}" old_env
  select_provider
  path_default="$(default_path_for_provider)"
  read -r -p "CDN domain/certificate [$DOMAIN]: " answer; [[ -n "$answer" ]] && DOMAIN="${answer,,}"
  read -r -p "Origin IP hoặc hostname [$ORIGIN_TARGET]: " answer
  if [[ -n "$answer" ]]; then ORIGIN_TARGET="${answer,,}"; fi
  [[ -n "$ORIGIN_TARGET" ]] || detect_origin_target
  read -r -p "Origin Host/SNI [$ORIGIN_HOST]: " answer; [[ -n "$answer" ]] && ORIGIN_HOST="${answer,,}"
  read -r -p "CDN edge/client address IP hoặc hostname [$CLIENT_ADDRESS]: " answer; [[ -n "$answer" ]] && CLIENT_ADDRESS="${answer,,}"
  read -r -p "XHTTP path [$path_default]: " answer; XHTTP_PATH="${answer:-$path_default}"
  read -r -p "XHTTP local port [$XHTTP_PORT]: " answer; [[ -n "$answer" ]] && XHTTP_PORT="$answer"
  read -r -p "Node API port [$NODE_PORT]: " answer; [[ -n "$answer" ]] && NODE_PORT="$answer"
  read -r -p "RAM threshold percent [$RAM_THRESHOLD]: " answer; [[ -n "$answer" ]] && RAM_THRESHOLD="$answer"
  read -r -p "Watchdog cooldown seconds [$COOLDOWN]: " answer; [[ -n "$answer" ]] && COOLDOWN="$answer"
  read -r -p "Cert fullchain path (blank=auto/self-signed): " cert
  read -r -p "Cert private key path (blank=auto/self-signed): " cert_key
  CERT_FULLCHAIN="$cert"; CERT_KEY="$cert_key"
  check_inputs
  read -r -p "Cài/recreate remnanode? [Y/n] (n=giữ node hiện tại): " install_node
  if [[ "$force_reinstall" == reinstall || -e "$STATE_FILE" || -e "$NGINX_SITE" || -e "$NODE_DIR/docker-compose.yml" ]] || \
    (command_exists docker && docker inspect remnanode >/dev/null 2>&1) || has_legacy_cdn; then
    printf 'Reinstall dừng Nginx/timer, backup và xóa cấu hình CDN cũ đã nhận diện.\n'
    [[ "$install_node" =~ ^[Nn]$ ]] || printf 'Container remnanode cũ sẽ bị dừng và tạo lại.\n'
    read -r -p "Gõ REINSTALL để xác nhận: " answer
    [[ "$answer" == REINSTALL ]] || die "Đã hủy để không ghi đè cấu hình cũ"
    # Recover the existing secret before removing the container, without logging it.
    if [[ ! "$install_node" =~ ^[Nn]$ && -z "${NODE_SECRET_KEY:-}" ]]; then
      if command_exists docker && docker inspect remnanode >/dev/null 2>&1; then
        old_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' remnanode)" || return 1
        while IFS= read -r answer; do
          case "$answer" in SECRET_KEY=*) NODE_SECRET_KEY="${answer#SECRET_KEY=}" ;; esac
        done <<< "$old_env"
        unset old_env
      fi
      if [[ -z "${NODE_SECRET_KEY:-}" ]]; then
        read -r -s -p 'SECRET_KEY từ panel (trước khi dừng node): ' NODE_SECRET_KEY
        printf '\n'
        [[ -n "$NODE_SECRET_KEY" ]] || die "SECRET_KEY rỗng; chưa dừng/xóa gì"
      fi
    fi
    clean_managed "$install_node" || return 1
  fi

  install_packages
  [[ ! "$install_node" =~ ^[Nn]$ ]] && install_remnanode
  prepare_certificate
  write_fake_site
  stop_nginx_recovery
  write_nginx
  write_nginx_recovery
  write_cert_sync
  write_watchdog
  write_logrotate
  write_exports
  save_state
  check_dns
  log "Đã lưu cấu hình và cài timer."
  report_nginx_readiness
  printf '\nHost Extra: %s\nServer inbound: %s\nClient template: %s\n' "$EXPORT_DIR/host-extra.json" "$EXPORT_DIR/server-inbound.json" "$EXPORT_DIR/client-template.json"
  printf 'Provider: %s\nCDN domain: %s\nOrigin: %s://%s:443\nOrigin Host/SNI: %s\nClient edge: %s:443\nPath: %s\n' "$CDN_PROVIDER" "$DOMAIN" "$ORIGIN_PROTOCOL" "$ORIGIN_TARGET" "$ORIGIN_HOST" "$CLIENT_ADDRESS" "$XHTTP_PATH"
  printf 'CDN policy: cache off, preserve query/cookie/body, methods GET/POST, timeout >= 300s.\n'
}

change_domain_path() {
  require_root
  load_state
  [[ -n "$DOMAIN" ]] || die "Chưa có setup; chọn Setup trước"
  local answer new_domain new_path old_site old_link
  old_site="$NGINX_SITE"; old_link="$NGINX_LINK"
  select_provider
  read -r -p "Domain mới [$DOMAIN]: " new_domain; [[ -n "$new_domain" ]] && DOMAIN="${new_domain,,}"
  read -r -p "Origin IP hoặc hostname [$ORIGIN_TARGET]: " answer; [[ -n "$answer" ]] && ORIGIN_TARGET="${answer,,}"
  read -r -p "Origin Host/SNI [$ORIGIN_HOST]: " answer; [[ -n "$answer" ]] && ORIGIN_HOST="${answer,,}"
  read -r -p "Path mới [$XHTTP_PATH] (Enter giữ path cũ): " new_path; [[ -n "$new_path" ]] && XHTTP_PATH="$new_path"
  read -r -p "Client address CDN mới [$CLIENT_ADDRESS]: " answer; [[ -n "$answer" ]] && CLIENT_ADDRESS="${answer,,}"
  check_inputs
  backup_file "$old_site" >/dev/null || true
  backup_file "$old_link" >/dev/null || true
  # Domain changes require a certificate matching the new name.
  CERT_FULLCHAIN=""
  CERT_KEY=""
  prepare_certificate
  write_fake_site
  stop_nginx_recovery
  write_nginx
  write_nginx_recovery
  write_exports
  save_state
  log "Đã đổi domain/path. Cập nhật lại Host Extra và subscription."
  report_nginx_readiness
}

print_menu() {
  printf '\nXHTTP Node Manager v%s\n' "$SCRIPT_VERSION"
  PS3='Chọn số: '
  select action in "Setup / rebuild VPS" "Reinstall sạch (backup rồi xóa managed)" "Đổi CDN/domain/origin/path" "Kiểm tra node" "Kiểm tra file và JSON" "Xuất Host Extra" "Cài/cập nhật watchdog" "Tạo / đổi web giả (chọn template)" "Gỡ CDN, giữ node thường" "Thoát"; do
    case "$REPLY" in
      1) write_setup; break ;;
      2) reinstall_clean; break ;;
      3) change_domain_path; break ;;
      4) check_status; break ;;
      5) check_files; break ;;
      6) load_state; cat "$EXPORT_DIR/host-extra.json" 2>/dev/null || warn "Chưa có Host Extra"; break ;;
      7) require_root; load_state; write_watchdog; log "Watchdog: RAM ${RAM_THRESHOLD}%, mỗi phút, cooldown ${COOLDOWN}s, chỉ restart remnanode"; break ;;
      8) web_template_menu; break ;;
      9) remove_cdn_managed; break ;;
      10) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
if [[ "${1:-}" == "--version" ]]; then printf '%s\n' "$SCRIPT_VERSION"; exit 0; fi
require_root
while true; do
  print_menu
done
