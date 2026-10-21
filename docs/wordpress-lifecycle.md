# Vòng đời site WordPress

Các việc làm với một site từ lúc chuyển về, cập nhật, đóng băng cho đến dọn git.

## Chuyển site giữa hai server RunCloud: wp-migration.sh

Chạy trên server nguồn, bằng user `runcloud`. Chuyển database, `wp-config.php`, `.htaccess`, `.htninja`, `wp-content/uploads`, submodule git.

Chuẩn bị:

1. Tạo webapp, database và user trên server đích bằng RunCloud panel trước.
2. Thiết lập SSH key một lần: `./wp-migration.sh runcloud@YOUR_SERVER --setup-ssh`.

Chạy:

```bash
./wp-migration.sh runcloud@YOUR_SERVER myapp
./wp-migration.sh runcloud@YOUR_SERVER myapp newapp          # đổi tên app ở đích
./wp-migration.sh runcloud@YOUR_SERVER myapp --staging-url=http://myapp.staging.temp-site.link
./wp-migration.sh runcloud@YOUR_SERVER:2222 myapp            # cổng SSH khác
```

Sau khi chuyển: mở site bằng staging URL, kiểm tra đăng nhập admin, trang chủ, một bài viết, ảnh, form. Chỉ đổi DNS khi mọi thứ ổn.

## Chuyển từ máy local lên production: wp-local-to-production.sh

Dành cho site đang dựng trên máy Mac (ví dụ LocalWP). Không sao chép `wp-config.php` và không xoá uploads trên server theo mặc định.

```bash
./wp-local-to-production.sh runcloud@YOUR_SERVER "/path/to/local/site/app/public" myapp \
  --production-url=http://example.temp-site.link --dry-run
```

Cờ hữu ích: `--setup-ssh`, `--skip-uploads`, `--skip-search-replace`, `--skip-htaccess`, `--skip-submodules`. Bắt buộc có `--production-url`. Chạy `--dry-run` trước.

## Chuyển ứng dụng Laravel: laravel-migration.sh

Giống `wp-migration.sh`, đọc thông tin từ `.env`. Trên đích:

- Database và user phải có cùng tên với nguồn; đổi mật khẩu bằng `ALTER USER` cho khớp trước khi chạy.
- Trong RunCloud panel đặt Public Path của webapp là `/public`, nếu không LiteSpeed trả 404.
- Cờ: `--staging-url`, `--skip-composer`, `--skip-build`, `--skip-storage`, `--skip-migrate`.

## Cập nhật plugin, theme, core: wp-update.sh

Chỉ chạy trên site có git. Nếu còn thay đổi chưa commit, script dừng. Điều này bảo vệ bạn khỏi việc ghi đè lên chỉnh sửa tay.

```bash
./wp-update.sh --site=myapp --action=status                       # xem cái gì đang chờ
./wp-update.sh --site=myapp --action=plugins --dry-run
./wp-update.sh --site=myapp --action=plugins --exclude=acf-pro,gravityforms
./wp-update.sh --site=myapp --action=themes
./wp-update.sh --site=myapp --action=core
./wp-update.sh --site=myapp --action=all
```

Plugin có giấy phép riêng hoặc cần thử kỹ (`acf-pro`, `gravityforms`) nên đưa vào `--exclude`.

Quy trình khuyến nghị cho site đang đóng băng:

```bash
./wp-freeze.sh --site=myapp --action=unfreeze
./wp-update.sh --site=myapp --action=plugins --dry-run
./wp-update.sh --site=myapp --action=plugins
./wp-health-check.sh --site=myapp
./wp-freeze.sh --site=myapp --action=freeze
```

## Đẩy plugin riêng lên nhiều site: wp-plugin-push.sh

Đóng gói plugin local (hoặc dùng file zip có sẵn), upload bằng SCP, cài bằng wp-cli trên mọi site WordPress của server, rồi kiểm tra HTTP 200.

```bash
./wp-plugin-push.sh --plugin=gravityforms --server=YOUR_SERVER --dry-run
./wp-plugin-push.sh --plugin=gravityforms --server=YOUR_SERVER --site=myapp
./wp-plugin-push.sh --plugin=gravityforms --servers=sv1,sv2
./wp-plugin-push.sh --plugin=gravityforms --all-servers
```

Thử một site trước, rồi một server, rồi mới `--all-servers`.

## Đóng băng code: wp-freeze.sh

Khoá hệ thống file và quyền quản trị sau khi site đã bàn giao. Đăng bài và tải ảnh vẫn hoạt động.

Ba lớp: file lõi chuyển sang chỉ đọc (`444`/`555`) và chặn chạy PHP trong uploads; `wp-config.php` thêm `DISALLOW_FILE_MODS`, `DISALLOW_FILE_EDIT`, `AUTOMATIC_UPDATER_DISABLED`; một mu-plugin gỡ quyền quản lý người dùng.

```bash
./wp-freeze.sh --site=myapp --action=freeze --dry-run
./wp-freeze.sh --site=myapp --action=freeze
./wp-freeze.sh --site=myapp --action=unfreeze
./wp-freeze.sh --action=status                  # mọi site
```

| Thao tác                           | Sau khi đóng băng |
| ---------------------------------- | ----------------- |
| Tạo, sửa, đăng bài                 | Được              |
| Tải media                          | Được              |
| Cài hoặc cập nhật plugin, theme    | Không             |
| Sửa file theme, plugin trong admin | Không             |
| Tạo, sửa, xoá người dùng           | Không             |
| Tự động cập nhật WordPress         | Không             |

Đừng chạy `fix-permission*.sh` hay `chown-site.sh` lên site đang đóng băng mà không mở băng trước, vì chúng sẽ đặt lại quyền.

## Dọn file git chưa theo dõi: wp-git-cleanup.sh

Quét file chưa được git theo dõi, phân loại và commit theo nhóm (core, từng theme, từng plugin, mu-plugin, ngôn ngữ), còn file sinh ra khi chạy production (cache, backup, log) được thêm vào `.gitignore`. Bỏ qua site đang đóng băng.

```bash
./wp-git-cleanup.sh --action=scan                       # chỉ báo cáo, mọi site
./wp-git-cleanup.sh --site=myapp --action=cleanup --dry-run
./wp-git-cleanup.sh --site=myapp --action=cleanup
```

Chạy `scan` và đọc kết quả trước khi `cleanup`. Script commit giúp bạn nên cần chắc chắn danh sách đúng.

## Chặn chạy PHP trong uploads: litespeed-lockdown.sh

Tạo file `/etc/lsws-rc/extra.d/<app>.rewrite.lockdown.conf` chặn thực thi PHP trong `wp-content/uploads` cho từng site OpenLiteSpeed (bỏ qua site đã có file), rồi chạy `lswsctrl restart`. Chạy trên từng server sau mỗi lần `git pull` script.
Lệnh restart LiteSpeed làm gián đoạn ngắn mọi site trên server, nên chạy ngoài giờ cao điểm.
