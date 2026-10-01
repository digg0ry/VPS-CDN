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
- reinstall sạch: backup rồi xóa container/config do script quản lý, không xóa cert, volume, website hoặc container khác.

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

Yandex preset dùng `GET + header` và `sessionIDPlacement: path`; không đổi sang cookie/query nếu client báo `400`. VK preset dùng `GET` với padding header riêng. Beeline preset dùng `POST + body`, `downloadHTTPMethod: GET` và cần CDN cho phép POST cùng rewrite đúng path.

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

Tên dependency, image và container cần thiết được giữ để tương thích. Đây là bản cài mới, không tự di chuyển service hoặc dữ liệu của các bản script trước. Trên node đã cài bản khác, kiểm tra listener TCP/443 và timer cũ trước khi chạy để tránh xung đột.

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

## Phục hồi Nginx từ 2.3.0

Setup, Reinstall và đổi domain/path tự cài timer `xhttp-node-nginx-recover.timer`.
Nginx dùng TCP `443`, XHTTP dùng `127.0.0.1:7443` mặc định. Script không cho chọn
`80`, `443` hoặc cổng API làm cổng XHTTP nội bộ. Client/CDN vẫn dùng `443`.

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

Nếu không tìm thấy cert hợp lệ cho domain, script tạo self-signed cert để Nginx chạy. Khi đó phải tắt kiểm tra certificate origin trên CDN. Cert có sẵn ở `/opt/certbot/certs/live/DOMAIN/` hoặc `/etc/letsencrypt/live/DOMAIN/` sẽ được tự phát hiện và đồng bộ vào `/opt/xhttp-node/certs/`.
