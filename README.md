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

Yandex preset dùng `GET + header` và `sessionPlacement: path`; không đổi sang cookie/query nếu client báo `400`. VK preset dùng `GET` với padding header riêng. Beeline preset dùng `POST + body`, `downloadHTTPMethod: GET` và cần CDN cho phép POST cùng rewrite đúng path.

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
