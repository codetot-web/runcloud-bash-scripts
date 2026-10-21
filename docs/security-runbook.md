# Runbook bảo mật

## Mức độ và hành động đầu tiên

| Tình huống                                             | Hành động đầu tiên                                                                |
| ------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Cảnh báo lỗ hổng PHP hoặc web server (chưa có bản vá)  | Kiểm kê phiên bản, xem [php-update-runbook.md](php-update-runbook.md)             |
| Cảnh báo lỗ hổng plugin, theme, core                   | `./wp-vuln-check.sh --site=myapp --include-core` rồi cập nhật bằng `wp-update.sh` |
| Nghi ngờ site bị chèn mã, trang lạ, redirect lạ        | Mục "Nghi ngờ bị xâm nhập" bên dưới                                               |
| Tiến trình PHP sinh shell, kết nối ra ngoài bất thường | Cô lập server, giữ log, xem mục "Nghi ngờ bị xâm nhập"                            |

## Cài công cụ quét

```bash
./wp-security-audit-installer.sh
```

Cài ClamAV, rkhunter, chkrootkit và cập nhật cơ sở dữ liệu ClamAV. Chạy một lần mỗi server.

## Quét mã độc: wp-security-audit.sh

Hai pha: pha 1 quét nhanh theo mẫu đã biết (`goods.php`, `shop.php`, thư mục `.tmb/`, `ZEa/`, cửa hậu ở `wp-login`); pha 2 quét sâu bằng ClamAV và kiểm tra rootkit nếu đã cài.

```bash
./wp-security-audit.sh                       # mọi site
./wp-security-audit.sh --site=myapp
./wp-security-audit.sh --folder=/path/to/webapp
./wp-security-audit.sh --site=myapp --install-deps
```

## Nghi ngờ bị xâm nhập

Làm theo thứ tự. Đừng xoá gì trước khi sao lưu bằng chứng.

1. **Giữ bằng chứng.** Sao chép log web và PHP, danh sách tiến trình, danh sách file mới sửa:
   ```bash
   ps -eo pid,ppid,user,lstart,args --forest > /root/incident-ps.txt
   find /home/*/webapps/myapp -type f -mtime -3 -name '*.php' > /root/incident-newfiles.txt
   ```
2. **Cô lập.** Nếu cần, tạm ngừng site trong RunCloud panel hoặc chặn ở Cloudflare cho từng domain. Không chặn cổng 80 của cả server.
3. **Quét.** `./wp-security-audit.sh --site=myapp` và `./wp-ownership-audit.sh --site=myapp`.
4. **Tìm file lạ.** So sánh với git: `git -C /home/USER/webapps/myapp status`. File PHP không được theo dõi trong `wp-content/uploads` hầu như chắc chắn là mã độc.
5. **Xem tiến trình và cron.** Kiểm tra `crontab -l` của root và user webapp, và tiến trình do `php-fpm`/`lsphp` sinh ra.
6. **Dọn và khoá.** Khôi phục file sạch từ git hoặc từ bản gốc plugin, đổi mật khẩu admin, khoá API và mật khẩu database, rồi chạy `./litespeed-lockdown.sh` và `./wp-freeze.sh --site=myapp --action=freeze`.
7. **Ghi lại.** Thời điểm phát hiện, đường vào nghi ngờ, file đã xoá, việc đã làm.

## Dấu hiệu khai thác kiểu RCE qua PHP

Theo hướng dẫn của Huntress cho đợt lỗ hổng PHP tháng 10/2026. Đây là suy luận, chưa phải dấu hiệu xác nhận.

- Worker PHP (`php-fpm`, `lsphp`, `apache2`) sinh shell, trình thông dịch hoặc công cụ tải về.
- Dòng lệnh chứa `/dev/tcp/`, `fsockopen`, `mkfifo`.
- Lệnh thăm dò `whoami`, `id`, `uname` chạy từ web server.

Kiểm tra nhanh:

```bash
ps -eo pid,ppid,user,args --forest | grep -E 'php-fpm|lsphp' -A3 | head -80
```

## Cân nhắc khi vận hành

- `wp-vuln-check.sh` chỉ biết lỗ hổng plugin, theme, core. Không dùng nó để kết luận PHP đã an toàn.
- `wp-freeze.sh` làm giảm rủi ro cài nhầm plugin, không thay thế việc cập nhật PHP.
- Sau khi dọn, chạy `./wp-health-check.sh --site=myapp` để chắc site vẫn lên.
