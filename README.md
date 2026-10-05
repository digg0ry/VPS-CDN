# XHTTP Node Manager

`xhttp-node.sh` dựng origin HTTPS cho một node XHTTP trên Ubuntu/Debian.

Script có menu Bash `select` và các chức năng:

- dựng từ VPS mới: Nginx, web giả, origin HTTPS, log rotation, watchdog RAM;
- kiểm tra domain, IPv4, path, port, cert, file và JSON;
- chọn preset riêng cho Yandex, VK hoặc Beeline;
- đổi CDN domain, origin IP/hostname, origin Host/SNI, CDN edge address và path;
- xuất `Host Extra`, server inbound template và client template;
- watchdog kiểm tra mỗi phút, ngưỡng 80%, cooldown 10 phút, chỉ restart container `remnanode`;
- giữ backup của file managed trước khi rebuild;
- reinstall sạch: backup trước, dừng Nginx/timer, rồi xóa cấu hình CDN cũ đã nhận diện và tạo lại; giữ cert, volume, website và container không liên quan;
- Nginx bind vào IPv4 origin cụ thể khi phát hiện được, tránh server block cũ trên cùng VPS bắt nhầm request CDN.

Script không tự tạo resource CDN. Cấu hình resource trong dashboard CDN:

- origin `ORIGIN_TARGET:443` (IPv4 hoặc hostname);
- HTTPS tới origin bật;
- SNI và Host tới origin bằng `ORIGIN_HOST`;
- cache tắt;
- giữ query string và cookie;
- Yandex/VK: chuyển GET, giữ header;
- Beeline: chuyển POST, giữ body;
- timeout request/response tối thiểu 300 giây;
- HTTP/2 bật, HTTP/3 tùy CDN nhưng nên tắt khi test XHTTP;
- rewrite tắt trong lần test đầu.

Preset path mặc định:

- Yandex: `/api/v4/media/session/poll2/`;
- VK: `/api/v4/media/session/poll2/`;
- Beeline: `/xh`.

Từ `2.3.2`, Yandex preset thử `GET + header`, `uplinkChunkSize: "2000-3000"`, `sessionIDKey: "auth"`, `sessionIDPlacement: "query"`, `seqKey: "offset"` và `seqPlacement: "query"`. XMUX dùng `maxConnections: "1"`, không dùng cùng `maxConcurrency`; các giới hạn reuse trong XMUX đặt `"0"`. Buffer 100, payload mỗi packet tối đa 8192 byte, khoảng cách gửi 30 ms, padding `"100-1000"`. VK và Beeline giữ nguyên preset trước đó.

Đổi session placement/key là đổi framing: phải cập nhật **cả inbound trên Remnawave lẫn Host Extra**, rồi refresh subscription/profile client. Chỉ cập nhật script hoặc file JSON trên VPS không thay inbound đang chạy do panel quản lý. Nên thử trên Host/profile bản sao trước; không cần reinstall, đổi cert, domain hoặc path để thử preset.

`sessionKey` và `sessionPlacement` trong mẫu tham khảo không thuộc schema Xray 26.7.28; bản xuất dùng `sessionIDKey` và `sessionIDPlacement`. Giữ `serverMaxHeaderBytes: 32768` ở inbound vì payload 8192 byte được Base64 thành khoảng 10923 ký tự, chưa tính padding/header khác. `uplinkChunkSize` chia payload đã mã hóa thành từng header `X-Playback-Token-N`, không giới hạn tổng kích thước header của request. `sessionIDTable: ""` dùng UUID mặc định; `sessionIDLength` không tạo ID 16-32 ký tự khi bảng ký tự rỗng. Một kết nối XMUX không đảm bảo nhanh hơn hoặc sửa mọi lỗi CDN.

VK preset dùng `GET` với padding header riêng. Beeline preset dùng `POST + body`, `downloadHTTPMethod: GET` và cần CDN cho phép POST cùng rewrite đúng path.

`CDN domain` là domain người dùng kết nối và domain cert. `Origin target` là IP/hostname VPS trong dashboard CDN. `Origin Host/SNI` là hostname CDN gửi tới origin. `Client edge address` là hostname/IP mà profile client dùng làm địa chỉ kết nối; thường là CDN domain, nhưng có thể nhập edge riêng khi nhà cung cấp yêu cầu.

XHTTP inbound vẫn phải được thêm qua panel. File server template chỉ để tham khảo/dán vào profile; `clients: []` để panel quản lý user.

## Chạy trực tiếp từ GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/digg0ry/VPS-CDN/main/xhttp-node.sh \
  -o /usr/local/sbin/xhttp-node
chmod 700 /usr/local/sbin/xhttp-node
sudo /usr/local/sbin/xhttp-node
```

Nhập secret tại prompt ẩn khi cài container mới. Biến môi trường tùy chọn là `NODE_SECRET_KEY`.

Không commit `SECRET_KEY`, private key hoặc token vào GitHub.

Tên dependency, image và container cần thiết được giữ để tương thích. Reinstall nhận diện site/upstream có marker `Managed by xhttp-node.sh` hoặc upstream `cdn_xhttp_xray`, kể cả file từ lần cài cũ. Webroot dạng `/var/www/DOMAIN` của site cũ được backup và xóa nếu không có site giữ lại dùng chung. Log format dùng chung với site khác được giữ. Không xóa chỉ vì tên file bắt đầu bằng `cdn-` hoặc có cùng path XHTTP.

Setup và Reinstall đều nhập thông tin và yêu cầu gõ `REINSTALL` trước khi dọn cấu hình cũ. Chọn `Y` tại câu hỏi recreate để dừng và tạo lại `remnanode`; secret hiện tại được lấy lại mà không in ra màn hình. Chọn `n` để giữ container và compose hiện tại. Timer/service managed được dừng trước khi xóa; Nginx chỉ khởi động lại khi cấu hình mới đã được tạo và test hợp lệ. Backup lỗi hoặc không dừng/xóa được service/container thì dừng thao tác, không báo thành công. Backup tại `/var/backups/xhttp-node/reinstall-*`. Có gián đoạn dịch vụ trong lúc reinstall. Docker Engine, Caddy và dịch vụ không được nhận diện không bị tự động stop/xóa.

## Tạo hoặc đổi web giả

Từ phiên bản `2.2.0`, chọn **8) Tạo / đổi web giả (chọn template)** sau khi hoàn tất Setup.
Chọn một trong 11 mẫu: `10gag`, `convertit`, `converter`, `downloader`, `filecloud`,
`games-site`, `modmanager`, `speedtest`, `YouTube`, `503-1`, `503-2`.

Danh sách và nguồn template tham khảo [selfsteal.sh](https://github.com/DigneZzZ/remnawave-scripts/blob/main/selfsteal.sh).
Script tải thư mục template cùng assets từ repository đó, phục vụ bằng Nginx đang có tại `/opt/xhttp-node/www`.
Đây là nội dung web tĩnh; các mẫu không tự cung cấp backend chuyển đổi file hoặc lưu trữ.
Mục này không chạy installer `selfsteal.sh`, không cài Caddy, không thay cert, inbound hoặc container.

Web cũ được backup trong `/var/backups/xhttp-node/web-*` trước khi thay.
Tải lỗi hoặc thiếu `index.html` thì giữ web cũ. Đổi domain/path giữ template đang dùng;
reinstall sạch sẽ backup và tạo lại trang Journal mặc định.
Nguồn, commit template và license được lưu ở `/opt/xhttp-node/web-template-source.txt`
và `/opt/xhttp-node/web-template-LICENSE`, ngoài webroot.
Nếu chưa thấy thay đổi trên domain CDN, kiểm tra cache CDN hoặc thử trực tiếp origin.

## Phục hồi Nginx từ 2.3.1

Setup, Reinstall và đổi domain/path tự cài timer `xhttp-node-nginx-recover.timer`.
Nginx dùng TCP `443`, bind vào IPv4 origin cụ thể khi có thể, XHTTP dùng `127.0.0.1:7443` mặc định. Script không cho chọn
`80`, `443` hoặc cổng API làm cổng XHTTP nội bộ. Client/CDN vẫn dùng `443`.

HTTP/2 dùng cú pháp `http2 on` trên Nginx từ 1.25.1; bản cũ dùng `listen ... ssl http2` để tránh lỗi `unknown directive "http2"`. IPv4 bind lấy từ IP local, không dùng trực tiếp IP origin remote/NAT. Khi bind IP cụ thể, kiểm tra `/healthz` bằng IP origin đó, không phải `127.0.0.1`.

Nếu core còn chiếm `443`, script lưu cấu hình và báo chưa sẵn sàng, không kill core.
Chuyển inbound trên panel sang `127.0.0.1:7443` (hoặc cổng nội bộ đã chọn).
Timer kiểm tra mỗi phút và chỉ bật Nginx khi inactive/failed, cấu hình hợp lệ,
không có listener khác chiếm TCP `443`. HTTP port `80` không cần dùng vì profile mặc định là HTTPS.
Không restart container hoặc tắt cập nhật OS.
UDP `443` của Hysteria2 không xung đột với TCP `443` của Nginx.

Timer cũng bật lại Nginx sau khi bạn chủ động stop. Khi bảo trì, dừng timer và service
`xhttp-node-nginx-recover` trước. Reinstall tự dừng chúng trước khi xóa file managed.
Nginx active không chứng minh VPN chạy: vẫn cần kiểm tra listener XHTTP và test qua CDN.
Không cần reinstall chỉ để bật Nginx sau khi đổi cổng trên panel.

Menu **9) Gỡ CDN, giữ node thường** gỡ Nginx origin, web giả, exports,
logrotate, watchdog và timer do script quản lý. Script backup trước khi xóa, giữ
`remnanode`, toàn bộ cert (kể cả `/opt/xhttp-node/certs`), `/opt/certbot`, Docker và dịch vụ khác. Sau đó đổi Config Profile
trên Remnawave về inbound node thường; panel không được script sửa.
Nhập `REMOVE-CDN` sau khi kiểm tra hostname/IP hiển thị. Không chọn Reinstall để gỡ CDN.
DNS/resource trên nhà cung cấp CDN, Caddy và cấu hình do công cụ khác tạo không bị xóa.
Nếu Nginx test/reload thất bại, script trả file Nginx về và dừng, không báo gỡ thành công.
Backup nằm trong `/var/backups/xhttp-node/cdn-remove-*`, quyền riêng tư cho root.

```bash
systemctl status nginx xhttp-node-nginx-recover.timer --no-pager
journalctl -u xhttp-node-nginx-recover.service -n 50 --no-pager
ss -ltnp | grep -E ':(443|7443)\b'
```

## File trên node

- `/opt/xhttp-node/state.env`
- `/opt/xhttp-node/www/index.html`
- `/opt/xhttp-node/exports/host-extra.json`
- `/opt/xhttp-node/exports/server-inbound.json`
- `/opt/xhttp-node/exports/client-template.json`
- `/opt/xhttp-node/exports/connection-info.json`
- `/opt/xhttp-node/exports/host-config.json`
- `/etc/nginx/sites-available/xhttp-node.conf`
- `/usr/local/sbin/node-ram-watchdog`
- `/var/log/xhttp-node/access.log` và `/var/log/xhttp-node/error.log`
- `/etc/nginx/conf.d/xhttp-node-logging.conf`
- `/etc/logrotate.d/xhttp-node`
- `/etc/systemd/system/xhttp-node-logrotate.timer`

## Logging từ 2.3.3

Install, Reinstall và đổi domain/path tự cài logging mới. Log XHTTP nằm riêng trong
`/var/log/xhttp-node/`, không trùng wildcard `/var/log/nginx/*.log` của gói Nginx.
Access log dùng format gọn, buffer 64 KiB/flush 5 giây, chỉ ghi IP, thời gian,
method, URI **không có query**, status, số byte và thời gian/upstream. Không ghi
session trong query, Referer padding hoặc User-Agent cho từng packet.

Timer `xhttp-node-logrotate.timer` kiểm tra mỗi 5 phút. Rule dùng `hourly`,
`maxsize 20M`, giữ 6 bản, nén ngay (`nodelaycompress`). `maxsize` được kiểm tra
khi timer chạy, không phải giới hạn cứng tại thời điểm ghi. Rotation gửi `USR1`
để Nginx mở lại file, không reload config hoặc restart `remnanode`. Timer riêng
và logrotate hệ thống dùng cùng state/lock mặc định để tránh chạy đồng thời.

Node đã cài: cập nhật script rồi chọn **10) Sửa logging / logrotate (giữ node)**.
Mục này backup và chuyển cấu hình logging, không đổi domain/path/cert, Host Extra,
profile hay container. Giữ các log cũ trong `/var/log/nginx/`; không tự xóa dữ liệu
khi Install/Reinstall hoặc sửa logging. Nếu disk đã đầy, giữ mẫu cần thiết và dọn
đúng file log cũ trước. Không copy toàn bộ log nhiều GB vào backup cùng disk.

```bash
systemctl status xhttp-node-logrotate.timer --no-pager
logrotate -d /etc/logrotate.conf
du -sh /var/log/xhttp-node /var/log/nginx
```

Nếu không tìm thấy cert hợp lệ cho domain, script tạo self-signed cert để Nginx chạy. Khi đó phải tắt kiểm tra certificate origin trên CDN. Cert có sẵn ở `/opt/certbot/certs/live/DOMAIN/` hoặc `/etc/letsencrypt/live/DOMAIN/` sẽ được tự phát hiện và đồng bộ vào `/opt/xhttp-node/certs/`.
