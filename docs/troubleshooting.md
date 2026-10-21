# Xử lý sự cố

## Site trả về lỗi 500 hoặc trang trắng

1. Xác định site nào lỗi và vì sao:
   ```bash
   ./wp-health-check.sh --site=myapp
   ```
   Đầu ra có phiên bản PHP của site và đoạn lỗi. `fail` kèm "Class not found" thường là plugin hoặc theme hỏng; kèm lỗi kết nối là database.
2. Nếu lỗi do một plugin:
   ```bash
   ./debug-wp-cli.sh --site=myapp
   ```
   Script thử bỏ qua từng plugin. Khi tìm được plugin gây lỗi, nó hỏi `y/n` trước khi tắt plugin đó. Chỉ trả lời `y` khi đã hiểu hệ quả cho site.
3. Nếu không phải plugin, kiểm tra sở hữu file:
   ```bash
   ./wp-ownership-audit.sh --site=myapp
   ```
   File thuộc `root` hoặc ACL chặn PHP-FPM đọc là nguyên nhân thường gặp sau khi ai đó chạy wp-cli hoặc unzip bằng root.
4. Xem log PHP và log web server của site trong RunCloud panel.

## wp-cli báo "Could not create directory" hoặc không ghi được file

Chủ sở hữu file sai. Chạy `./wp-ownership-audit.sh --site=myapp`, đọc danh sách, rồi `--fix`.
Luôn chạy wp-cli bằng user chủ site, không bằng `root`. Các script trong repo đã tự làm điều này bằng `sudo -u`.

## wp-health-check báo "MySQL extension missing" nhưng site vẫn chạy

Thường do dùng PHP CLI của hệ thống thay vì PHP của site. Script đã dùng binary FPM hoặc LSPHP của site để tránh lỗi này.
Nếu vẫn gặp, chạy `./wp-health-check.sh --dry-run` và xem script có nhận đúng phiên bản PHP của site không.

## Đĩa đầy

```bash
df -h
./cleanup-disk.sh --dry-run
./cleanup-disk.sh
du -xh /tmp/lsws-rc/swap 2>/dev/null | tail -1
```

Nếu vẫn đầy, tìm thư mục lớn nhất: `du -xh /home --max-depth=3 | sort -h | tail -20`.

## MariaDB không khởi động sau khi tinh chỉnh

`tweak-mycnf.sh` tự khôi phục nếu MariaDB không lên. Nếu cần làm tay:

```bash
./tweak-mycnf.sh --restore
systemctl status mariadb
journalctl -u mariadb --no-pager | tail -50
```

## git pull của repo script báo lỗi

```bash
cd /root/runcloud-bash-scripts
git checkout -- .
git pull --ff-only
chmod +x *.sh
```

## Mất kết nối SSH sau khi đổi cổng

Hãy luôn mở một phiên SSH thứ hai trước khi đổi cổng và chỉ đóng phiên cũ sau khi phiên mới đăng nhập được. Nếu đã mất kết nối, dùng console của nhà cung cấp VPS rồi chạy:

```bash
./change-ssh-port.sh restore
```

## Migration dừng giữa chừng

- Trước khi chạy lại `wp-migration.sh` hoặc `laravel-migration.sh`, xác nhận site đích chưa có dữ liệu cần giữ, vì lần chạy mới nhập lại database.
- Kiểm tra database và user đã tồn tại trên server đích; script không tự tạo.
- Kiểm tra SSH key: chạy lại với `--setup-ssh`.
- Laravel trả 404 trên đích: đặt Public Path là `/public` trong RunCloud panel.

## Site vừa đóng băng không cập nhật được plugin

Đó là hành vi đúng. Mở băng, cập nhật, đóng băng lại (xem [wordpress-lifecycle.md](wordpress-lifecycle.md)).

## Gửi thông tin khi cần hỗ trợ

Cung cấp: tên site, tên server (không đưa hostname vào repo công khai), lệnh đã chạy, đoạn lỗi đầy đủ, phiên bản PHP từ `wp-health-check.sh --dry-run`, và `cat /root/runcloud-bash-scripts/VERSION`.
