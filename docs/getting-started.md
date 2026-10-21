# Bắt đầu: cài đặt và cập nhật script

## Yêu cầu

- Ubuntu 20, 22 hoặc 24
- OpenLiteSpeed hoặc Nginx do RunCloud quản lý
- Quyền `root` (SSH key)

## Cài lần đầu trên một server

```bash
cd /root
git clone https://github.com/codetot-web/runcloud-bash-scripts.git
cd runcloud-bash-scripts
chmod +x *.sh
```

Repo luôn nằm ở `/root/runcloud-bash-scripts/` trên mọi server. Các cron và dashboard giả định đường dẫn này.

## Cập nhật script

### Tự động (khuyến nghị)

`self-update.sh` kéo bản mới từ GitHub, bỏ qua nếu đã mới nhất, rồi `chmod +x` lại toàn bộ script.

```bash
30 3 * * * /root/runcloud-bash-scripts/self-update.sh >> /var/log/runcloud-bash-scripts-update.log 2>&1
```

Thêm dòng trên bằng RunCloud Dashboard > Cron Job, chạy với user `root`.

### Thủ công trên một server

```bash
cd /root/runcloud-bash-scripts
git checkout -- .
git pull --ff-only
chmod +x *.sh
```

`git checkout -- .` cần thiết vì `chmod +x` làm đổi filemode và chặn `git pull`.

### Triển khai cho cả đội server

Dùng danh sách server của dashboard nội bộ (`~/.rc/config.yaml` hoặc `~/.rc/rc.db` trên máy điều khiển). Chạy lần lượt từng server, đọc lỗi,
rồi mới chạy song song. Lệnh mẫu và ghi chú nằm trong `AGENTS.md`, mục Deployment.

## Kiểm tra sau khi cài

```bash
cd /root/runcloud-bash-scripts
git log --oneline -1
cat VERSION
./wp-health-check.sh --dry-run
```

`--dry-run` liệt kê các site tìm thấy và phiên bản PHP của từng site mà không thăm dò gì thêm.

## Thử script mới trước khi gộp

```bash
bash -n script.sh
scp -P PORT script.sh root@YOUR_SERVER:/root/test.sh
ssh -p PORT root@YOUR_SERVER "bash /root/test.sh --site=SITE_NAME"
```

Luôn thử trên một server và một site trước khi merge và triển khai.

## Lỗi thường gặp khi cập nhật

| Triệu chứng                                | Nguyên nhân                   | Cách xử lý                                                                                  |
| ------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------------------------- |
| `git pull` báo có thay đổi cục bộ          | filemode bị đổi do `chmod +x` | `git checkout -- .` rồi pull lại                                                            |
| Cron chạy script nhưng `wp` không tìm thấy | `PATH` của cron ngắn          | script đã tự tìm `/usr/local/bin/wp`, `/usr/bin/wp`; kiểm tra wp-cli có ở một trong hai chỗ |
| Script báo không có `/home/runcloud/...`   | giả định cứng tên user        | dùng `--site=` hoặc `--path=`; webapp có thể thuộc user hệ thống khác                       |
