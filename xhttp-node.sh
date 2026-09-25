#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2.1.0"
STATE_DIR="/opt/xhttp-node"
STATE_FILE="$STATE_DIR/state.env"
WEBROOT="$STATE_DIR/www"
EXPORT_DIR="$STATE_DIR/exports"
CERT_DIR="$STATE_DIR/certs"
NGINX_SITE="/etc/nginx/sites-available/xhttp-node.conf"
NGINX_LINK="/etc/nginx/sites-enabled/xhttp-node.conf"
WATCHDOG_BIN="/usr/local/sbin/node-ram-watchdog"
CERT_SYNC_BIN="/usr/local/sbin/xhttp-node-cert-sync"
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
  install -d -m 700 "$STATE_DIR"
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
  [[ "$RAM_THRESHOLD" =~ ^[0-9]+$ ]] && (( RAM_THRESHOLD >= 50 && RAM_THRESHOLD <= 99 )) || die "RAM threshold phải từ 50 đến 99"
  [[ "$COOLDOWN" =~ ^[0-9]+$ ]] && (( COOLDOWN >= 60 )) || die "Cooldown phải >= 60 giây"
  normalize_path
}

install_packages() {
  command_exists apt-get || die "Script cần Ubuntu/Debian có apt-get"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx curl ca-certificates openssl jq dnsutils logrotate
  systemctl enable --now nginx
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
  mkdir -p /opt/remnanode /var/log/remnanode
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
  backup_file /opt/remnanode/docker-compose.yml >/dev/null || true
  cat > /opt/remnanode/docker-compose.yml <<EOF
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
  chmod 600 /opt/remnanode/docker-compose.yml
  docker compose -f /opt/remnanode/docker-compose.yml config -q
  docker compose -f /opt/remnanode/docker-compose.yml pull
  docker compose -f /opt/remnanode/docker-compose.yml up -d
  unset secret json_secret
}

find_certificate() {
  local candidates=(
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

proxy_location() {
  cat <<EOF
    location = ${XHTTP_PATH%/} {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        include /etc/nginx/snippets/xhttp-node-proxy.conf;
    }
    location ^~ $XHTTP_PATH {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        include /etc/nginx/snippets/xhttp-node-proxy.conf;
    }
EOF
}

write_nginx() {
  install -d -m 755 /etc/nginx/snippets /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > /etc/nginx/snippets/xhttp-node-proxy.conf <<'EOF'
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
    listen 80;
    listen [::]:80;
    server_name $DOMAIN $ORIGIN_HOST;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN $ORIGIN_HOST;
    ssl_certificate $CERT_FULLCHAIN;
    ssl_certificate_key $CERT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    root $WEBROOT;
    index index.html;

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
  systemctl reload nginx
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
      jq -n --arg domain "$DOMAIN" \
        '{xmux:{maxConcurrency:"8-16",cMaxReuseTimes:"128-256",hKeepAlivePeriod:30,hMaxRequestTimes:"600-1000",hMaxReusableSecs:"1800-3600"},headers:{Accept:"application/vnd.api+json, application/json, text/plain, */*",Pragma:"no-cache", "Cache-Control":"no-cache", "Accept-Language":"ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"},uplinkHTTPMethod:"GET",uplinkDataPlacement:"header",uplinkDataKey:"X-Playback-Token",serverMaxHeaderBytes:32768,sessionKey:"media_sid",sessionPlacement:"path",seqKey:"offset",seqPlacement:"query",xPaddingKey:"q",xPaddingPlacement:"query",xPaddingMethod:"tokenish",xPaddingBytes:"48-320",xPaddingObfsMode:true,scMaxBufferedPosts:64,scMaxEachPostBytes:"1536-6144",scMinPostsIntervalMs:"10-30"}' > "$extra_file"
      ;;
    vk)
      jq -n --arg cookie "$cookie" \
        '{xPaddingKey:"_dc",xPaddingHeader:"X-Cache",xPaddingMethod:"tokenish",uplinkHTTPMethod:"GET",uplinkDataKey:"X-Playback-Token",uplinkDataPlacement:"header",sessionIDKey:"media_sid",sessionIDPlacement:"cookie",seqKey:"offset",seqPlacement:"query",headers:{Accept:"*/*",Cookie:$cookie,Pragma:"no-cache", "Cache-Control":"no-cache"},xPaddingObfsMode:true,xPaddingPlacement:"queryInHeader"}' > "$extra_file"
      ;;
    beeline)
      jq -n --arg domain "$DOMAIN" --arg cookie "$cookie" \
        '{xmux:{maxConcurrency:"1"},seqKey:"chunk_id",seqPlacement:"query",headers:{Accept:"*/*",Cookie:$cookie,Origin:("https://"+$domain+"/"),Referer:("https://"+$domain+"/"),"User-Agent":"Mozilla/5.0(WindowsNT10.0;Win64;x64;rv:151.0)Gecko/20100101Firefox/151.0","Sec-Fetch-Dest":"empty","Sec-Fetch-Mode":"cors","Sec-Fetch-Site":"same-origin","Accept-Language":"ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"},sessionKey:"auth",sessionIDKey:"auth",sessionPlacement:"query",sessionIDPlacement:"query",sessionIDTable:"Base62",sessionIDLength:"16-32",noSSEHeader:true,noGRPCHeader:true,xPaddingBytes:"50-150",xPaddingHeader:"X-Api-Key",xPaddingMethod:"tokenish",xPaddingObfsMode:true,xPaddingPlacement:"header",uplinkHTTPMethod:"POST",downloadHTTPMethod:"GET",uplinkDataPlacement:"body",scMaxBufferedPosts:100,scMaxEachPostBytes:3000000,scMaxConcurrentPosts:10,scMinPostsIntervalMs:"5-10",serverMaxHeaderBytes:32768}' > "$extra_file"
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
  free -h
  systemctl --no-pager --full status node-ram-watchdog.timer 2>/dev/null || true
  systemctl --no-pager --full status xhttp-node-cert-sync.timer 2>/dev/null || true
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
  local stamp="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  install -d -m 700 "$stamp"
  for item in "$STATE_DIR" /opt/remnanode "$NGINX_SITE" "$NGINX_LINK" \
    /etc/nginx/snippets/xhttp-node-proxy.conf /etc/logrotate.d/xhttp-node \
    /etc/systemd/system/node-ram-watchdog.service /etc/systemd/system/node-ram-watchdog.timer \
    /etc/systemd/system/xhttp-node-cert-sync.service /etc/systemd/system/xhttp-node-cert-sync.timer \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN"; do
    [[ -e "$item" || -L "$item" ]] || continue
    mkdir -p "$stamp$(dirname "$item")"
    cp -a "$item" "$stamp$item"
  done
  printf '%s\n' "$stamp"
}

clean_managed() {
  require_root
  local backup
  backup="$(backup_managed)"
  log "Backup managed files: $backup"
  if command_exists docker && docker inspect remnanode >/dev/null 2>&1; then
    docker rm -f remnanode >/dev/null 2>&1 || true
  fi
  rm -rf /opt/remnanode "$STATE_DIR"
  rm -f "$NGINX_LINK" "$NGINX_SITE" /etc/nginx/snippets/xhttp-node-proxy.conf /etc/logrotate.d/xhttp-node
  systemctl disable --now node-ram-watchdog.timer xhttp-node-cert-sync.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/node-ram-watchdog.service /etc/systemd/system/node-ram-watchdog.timer \
    /etc/systemd/system/xhttp-node-cert-sync.service /etc/systemd/system/xhttp-node-cert-sync.timer \
    "$WATCHDOG_BIN" "$CERT_SYNC_BIN"
  systemctl daemon-reload
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  log "Đã xóa managed install. Cert ngoài /opt/certbot và website/container khác được giữ nguyên."
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
  clean_managed
  write_setup
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
  local answer install_node cert cert_key path_default
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
  if [[ -e "$STATE_FILE" || -e "$NGINX_SITE" || -e /opt/remnanode/docker-compose.yml ]] || \
    (command_exists docker && docker inspect remnanode >/dev/null 2>&1); then
    read -r -p "Đã có managed install. Gõ REINSTALL để backup và xóa sạch trước khi tạo lại: " answer
    [[ "$answer" == REINSTALL ]] || die "Đã hủy để không ghi đè cấu hình cũ"
    clean_managed
  fi
  read -r -p "Cài/recreate remnanode? [Y/n]: " install_node

  install_packages
  [[ ! "$install_node" =~ ^[Nn]$ ]] && install_remnanode
  prepare_certificate
  write_fake_site
  write_nginx
  write_cert_sync
  write_watchdog
  write_logrotate
  write_exports
  save_state
  check_dns
  log "Setup hoàn tất"
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
  write_nginx
  write_exports
  save_state
  log "Đã đổi domain/path. Cập nhật lại Host Extra và subscription."
}

print_menu() {
  printf '\nXHTTP Node Manager v%s\n' "$SCRIPT_VERSION"
  PS3='Chọn số: '
  select action in "Setup / rebuild VPS" "Reinstall sạch (backup rồi xóa managed)" "Đổi CDN/domain/origin/path" "Kiểm tra node" "Kiểm tra file và JSON" "Xuất Host Extra" "Cài/cập nhật watchdog" "Thoát"; do
    case "$REPLY" in
      1) write_setup; break ;;
      2) reinstall_clean; break ;;
      3) change_domain_path; break ;;
      4) check_status; break ;;
      5) check_files; break ;;
      6) load_state; cat "$EXPORT_DIR/host-extra.json" 2>/dev/null || warn "Chưa có Host Extra"; break ;;
      7) require_root; load_state; write_watchdog; log "Watchdog: RAM ${RAM_THRESHOLD}%, mỗi phút, cooldown ${COOLDOWN}s, chỉ restart remnanode"; break ;;
      8) exit 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
  done
}

if [[ "${1:-}" == "--version" ]]; then printf '%s\n' "$SCRIPT_VERSION"; exit 0; fi
require_root
while true; do
  print_menu
done
