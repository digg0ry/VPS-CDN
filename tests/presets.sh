#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/xhttp-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
DOMAIN=cdn.example.com
ORIGIN_TARGET=192.0.2.1
ORIGIN_HOST=origin.example.com
CLIENT_ADDRESS=192.0.2.2
XHTTP_PATH=/custom/test/path/
XHTTP_PORT=17443
# Deterministic cookie makes the unchanged presets comparable field by field.
openssl() { printf '0123456789abcdef0123456789abcdef\n'; }

for CDN_PROVIDER in yandex vk beeline; do
  EXPORT_DIR="$TMP/$CDN_PROVIDER"
  write_exports
  jq -e -n --slurpfile extra "$EXPORT_DIR/host-extra.json" \
    --slurpfile server "$EXPORT_DIR/server-inbound.json" \
    --slurpfile client "$EXPORT_DIR/client-template.json" \
    --slurpfile host "$EXPORT_DIR/host-config.json" \
    --slurpfile info "$EXPORT_DIR/connection-info.json" \
    --arg provider "$CDN_PROVIDER" '
      ($server[0].inbounds[0].streamSettings.xhttpSettings.extra == $extra[0]) and
      ($client[0].outbounds[0].streamSettings.xhttpSettings.extra == $extra[0]) and
      ($host[0].extra == $extra[0]) and
      ($server[0].inbounds[0].listen == "127.0.0.1") and
      ($server[0].inbounds[0].port == 17443) and
      ($server[0].inbounds[0].streamSettings.xhttpSettings.path == "/custom/test/path/") and
      ($host[0].path == "/custom/test/path/" and $host[0].mode == "packet-up") and
      ($client[0].outbounds[0].settings.vnext[0].address == "192.0.2.2") and
      ($client[0].outbounds[0].settings.vnext[0].port == 443) and
      ($client[0].outbounds[0].streamSettings.tlsSettings.serverName == "cdn.example.com") and
      ($client[0].outbounds[0].streamSettings.xhttpSettings.host == "cdn.example.com") and
      ($info[0].provider == $provider and $info[0].originHostSni == "origin.example.com")
    ' >/dev/null
done

jq -e '. == {
  xmux: {cMaxReuseTimes:"0",maxConnections:"1",hKeepAlivePeriod:0,hMaxRequestTimes:"0",hMaxReusableSecs:"0"},
  seqKey:"offset",seqPlacement:"query",sessionIDKey:"auth",sessionIDPlacement:"query",
  sessionIDTable:"",sessionIDLength:"16-32",uplinkHTTPMethod:"GET",
  uplinkDataPlacement:"header",uplinkDataKey:"X-Playback-Token",uplinkChunkSize:"2000-3000",
  xPaddingBytes:"100-1000",scMaxBufferedPosts:100,scMaxEachPostBytes:8192,
  scMinPostsIntervalMs:30,serverMaxHeaderBytes:32768
}' "$TMP/yandex/host-extra.json" >/dev/null

jq -e '. == {
  xPaddingKey:"_dc",xPaddingHeader:"X-Cache",xPaddingMethod:"tokenish",uplinkHTTPMethod:"GET",
  uplinkDataKey:"X-Playback-Token",uplinkDataPlacement:"header",sessionIDKey:"media_sid",
  sessionIDPlacement:"cookie",seqKey:"offset",seqPlacement:"query",
  headers:{Accept:"*/*",Cookie:"session_id=0123456789abcdef0123456789abcdef",Pragma:"no-cache","Cache-Control":"no-cache"},
  xPaddingObfsMode:true,xPaddingPlacement:"queryInHeader"
}' "$TMP/vk/host-extra.json" >/dev/null

jq -e '. == {
  xmux:{maxConcurrency:"1"},seqKey:"chunk_id",seqPlacement:"query",
  headers:{Accept:"*/*",Cookie:"session_id=0123456789abcdef0123456789abcdef",
    Origin:"https://cdn.example.com/",Referer:"https://cdn.example.com/",
    "User-Agent":"Mozilla/5.0(WindowsNT10.0;Win64;x64;rv:151.0)Gecko/20100101Firefox/151.0",
    "Sec-Fetch-Dest":"empty","Sec-Fetch-Mode":"cors","Sec-Fetch-Site":"same-origin",
    "Accept-Language":"ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"},
  sessionIDKey:"auth",sessionIDPlacement:"query",sessionIDTable:"Base62",sessionIDLength:"16-32",
  noSSEHeader:true,noGRPCHeader:true,xPaddingBytes:"50-150",xPaddingHeader:"X-Api-Key",
  xPaddingMethod:"tokenish",xPaddingObfsMode:true,xPaddingPlacement:"header",uplinkHTTPMethod:"POST",
  downloadHTTPMethod:"GET",uplinkDataPlacement:"body",scMaxBufferedPosts:100,scMaxEachPostBytes:3000000,
  scMaxConcurrentPosts:10,scMinPostsIntervalMs:"5-10",serverMaxHeaderBytes:32768
}' "$TMP/beeline/host-extra.json" >/dev/null
printf 'PASS: Yandex query/header preset, unchanged VK/Beeline, matching server/client/Host Extra, preserved connection settings\n'
