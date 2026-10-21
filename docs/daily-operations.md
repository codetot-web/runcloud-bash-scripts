# Vận hành định kỳ

Chạy bằng `root` trong `/root/runcloud-bash-scripts/`. Lệnh nào có `--dry-run` thì chạy thử trước.

## Bảng việc theo tần suất

| Tần suất                  | Việc                         | Lệnh                                             |
| ------------------------- | ---------------------------- | ------------------------------------------------ |
| Hằng ngày                 | Dọn cache và log             | `./cleanup-disk.sh`                              |
| Hằng ngày                 | Phát hiện site hỏng          | `./wp-health-check.sh`                           |
| Hằng ngày hoặc mỗi 5 phút | Gửi số liệu về dashboard     | `server-metrics.sh` qua cron                     |
| Hằng tuần                 | Quét lỗ hổng plugin và theme | `./wp-vuln-check.sh --site=myapp --include-core` |
| Hằng tuần                 | Kiểm tra sở hữu file         | `./wp-ownership-audit.sh --dirs-only`            |
| Hằng tuần                 | Quét mã độc                  | `./wp-security-audit.sh`                         |
| Sau mỗi lần thay đổi lớn  | Cập nhật script              | `./self-update.sh`                               |

## Dọn đĩa: cleanup-disk.sh

Xoá các thứ sẽ tự tạo lại: cache WordPress, cache LiteSpeed, file swap của LiteSpeed, journal log (giữ 500M). Không mất dữ liệu.

```bash
./cleanup-disk.sh --dry-run          # xem trước
./cleanup-disk.sh                    # tất cả webapp và hệ thống
./cleanup-disk.sh --site=myapp       # một webapp
./cleanup-disk.sh --system-only      # chỉ hệ thống
```

Khi đĩa đầy đột ngột, kiểm tra `/tmp/lsws-rc/swap/` trước vì file swap LiteSpeed có thể chiếm 5-15G.

## Kiểm tra sức khỏe site: wp-health-check.sh

Chạy `wp eval` qua đúng binary PHP của site (FPM hoặc LSPHP), không đi qua Cloudflare, nên không báo lỗi giả khi site đang bật Under Attack Mode.

```bash
./wp-health-check.sh                  # chỉ hiện site lỗi
./wp-health-check.sh --all            # hiện cả ok và skip
./wp-health-check.sh --site=myapp
./wp-health-check.sh --format=json
./wp-health-check.sh --dry-run        # chỉ liệt kê site và phiên bản PHP
```

Mã thoát: `0` mọi site ok, `1` có ít nhất một site lỗi, `2` lỗi của chính script (không có wp-cli hoặc thư mục webapps).
Đầu ra TSV gồm: site, phiên bản PHP, trạng thái, đoạn lỗi.

`--dry-run` cũng là cách nhanh nhất để lấy bảng "site nào đang dùng PHP nào" khi cần kiểm kê.

## Quét lỗ hổng: wp-vuln-check.sh

Hỏi API WPVulnerability.net cho từng plugin và theme, trả về CVE, điểm CVSS và mức nghiêm trọng. Cần `python3` và `curl`.

```bash
./wp-vuln-check.sh --site=myapp
./wp-vuln-check.sh --site=myapp --include-core
./wp-vuln-check.sh --site=myapp --json
./wp-vuln-check.sh --site=myapp --plugins-only
```

Script này chỉ nói về plugin, theme và core WordPress. Nó không phát hiện lỗ hổng trong chính PHP. Với PHP xem [php-update-runbook.md](php-update-runbook.md).

## Sở hữu file: wp-ownership-audit.sh

Bắt tình trạng file thuộc `root` hoặc thuộc sai user, và ACL chặn PHP-FPM đọc file. Triệu chứng thường là wp-cli báo "Could not create directory" hoặc site lỗi 500.

```bash
./wp-ownership-audit.sh --dirs-only    # nhanh, chỉ thư mục cấp trên
./wp-ownership-audit.sh                # quét sâu
./wp-ownership-audit.sh --site=myapp
./wp-ownership-audit.sh --fix          # chown về đúng chủ sở hữu
./wp-ownership-audit.sh --format=json
```

Chạy không có `--fix` trước, đọc danh sách, rồi mới `--fix`.

## Quyền file: fix-permission*.sh và chown-site.sh

| Script                                     | Làm gì                                                               |
| ------------------------------------------ | -------------------------------------------------------------------- |
| `fix-permission.sh`                        | Đặt lại chủ sở hữu, thư mục 755, file 644 cho mọi webapp             |
| `fix-permission-site.sh --site=myapp`      | Như trên cho một site                                                |
| `chown-site.sh --site=myapp [--user=NAME]` | Chown cả cây về `www-data:www-data`, giữ nguyên `wp-content/uploads` |

Cả hai nhóm đều bỏ qua `wp-content/uploads/`. Phải kiểm tra thư mục này bằng tay.

## Theo dõi tài nguyên: server-metrics.sh

Thu CPU, RAM, đĩa, load, uptime, danh sách webapp và bản cập nhật WordPress đang chờ; gửi JSON tới webhook, có ký HMAC-SHA256 nếu đặt `WEBHOOK_SECRET`.

```bash
./server-metrics.sh --print           # in ra màn hình, không gửi
```

```bash
*/5 * * * * WEBHOOK_URL=https://example.com/webhook WEBHOOK_SECRET=your-secret /root/runcloud-bash-scripts/server-metrics.sh >> /var/log/server-metrics.log 2>&1
```

Phía nhận phải kiểm tra chữ ký bằng so sánh thời gian hằng định (`hash_equals` trong PHP, `hmac.compare_digest` trong Python).
Không ghi `WEBHOOK_SECRET` vào repo; đặt trong cron hoặc biến môi trường của server.

## Tinh chỉnh MariaDB: tweak-mycnf.sh

```bash
./tweak-mycnf.sh --status             # xem cấu hình hiện tại
./tweak-mycnf.sh --dry-run            # xem sẽ đổi gì
./tweak-mycnf.sh                      # áp dụng (có sao lưu, tự khôi phục nếu MariaDB không lên)
./tweak-mycnf.sh --restore            # quay về bản sao lưu gần nhất
```

Script khởi động lại MariaDB, nên chạy ngoài giờ cao điểm. Quy tắc tính: `innodb_buffer_pool_size` khoảng 50% RAM, `max_connections` 300, `wait_timeout` 300s.

## Các việc ít gặp

| Việc                              | Lệnh                                                                                                                                                                   |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Đổi cổng SSH                      | `./change-ssh-port.sh <cổng_mới>`; quay lại: `./change-ssh-port.sh restore`. Mở cổng mới trên firewall và giữ phiên SSH hiện tại cho đến khi đăng nhập thử thành công. |
| Cài ionCube cho mọi phiên bản PHP | `./install-ioncube.sh` (hỗ trợ OpenLiteSpeed, gói PHP của RunCloud và PHP-FPM chuẩn)                                                                                   |
| Cập nhật Node.js                  | `./update-nodejs.sh`                                                                                                                                                   |
| Gỡ lỗi wp-cli                     | `./debug-wp-cli.sh --site=myapp`                                                                                                                                       |
| Liệt kê plugin và theme dạng JSON | `./wp-plugin-list.sh --site=myapp`                                                                                                                                     |
