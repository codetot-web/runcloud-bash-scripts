# Runbook cập nhật và vá PHP

Repo chưa có script cho việc này. Đây là quy trình thủ công cho server RunCloud. Nội dung bám theo cách các script hiện có phát hiện PHP.
Mọi lệnh bên dưới đã có sẵn trong script của repo hoặc chỉ đọc; không có bước nào tự động thay đổi phiên bản PHP.

## Cách PHP được cài trên server RunCloud

| Loại                                         | Binary PHP                           | Dịch vụ       | Cấu hình pool                    |
| -------------------------------------------- | ------------------------------------ | ------------- | -------------------------------- |
| Nginx + PHP-FPM của RunCloud                 | `/RunCloud/Packages/phpXYrc/bin/php` | `phpXYrc-fpm` | `/etc/phpXYrc/fpm.d/<site>.conf` |
| OpenLiteSpeed                                | `/usr/local/lsws/lsphpXY/bin/php`    | `lsws-rc`     | `/etc/lsws-rc/conf.d/<site>.d/`  |
| PHP-FPM chuẩn (Ondrej PPA, litesoup, Ubuntu) | `/usr/sbin/php-fpmX.Y`               | `phpX.Y-fpm`  | `/etc/php/X.Y/fpm/pool.d/`       |

`XY` là phiên bản không dấu chấm (`82` là PHP 8.2). Dùng đúng cột của server đang làm việc. Lệnh `apt upgrade php8.2-fpm` chỉ áp dụng cho hàng thứ ba.

## Bước 1: kiểm kê (có thể làm bất cứ lúc nào)

Liệt kê site và phiên bản PHP mà từng site thực sự chạy:

```bash
cd /root/runcloud-bash-scripts
./wp-health-check.sh --dry-run
```

Xem các phiên bản đã cài và đang chạy:

```bash
ls -d /RunCloud/Packages/php*rc 2>/dev/null
ls -d /usr/local/lsws/lsphp* 2>/dev/null
systemctl list-units --type=service --state=running | grep -E 'php[0-9.]+(rc)?-fpm|lsws'
```

Ghi lại vào bảng: server, site, phiên bản PHP, hết hỗ trợ hay chưa. Một phiên bản đã cài nhưng không site nào dùng thì không phải rủi ro chính, nhưng cũng nên gỡ nếu không cần.

Tra tình trạng hỗ trợ trên [php.net/supported-versions.php](https://www.php.net/supported-versions.php). Tại thời điểm viết (21/10/2026): 8.4 và 8.5 hỗ trợ đầy đủ, 8.2 và 8.3 chỉ vá bảo mật, 8.1 và 7.4 đã hết hỗ trợ.

## Bước 2: xác định bản vá đến từ đâu

PHP phát hành mã nguồn; server của mình nhận bản vá qua gói. Hai thứ này có thể lệch nhau vài giờ hoặc vài ngày.

```bash
dpkg -S /RunCloud/Packages/php82rc/bin/php        # gói nào sở hữu binary này
apt-cache policy <tên-gói-ở-lệnh-trên>
```

Chỉ coi một gói là đã vá khi changelog của gói nhắc đến CVE cần vá hoặc phiên bản gói không thấp hơn phiên bản PHP mà php.net công bố đã sửa.
Với gói của RunCloud, theo dõi thông báo của RunCloud. Đừng tự biên dịch PHP trên server đang chạy production.

## Bước 3: chuẩn bị trước khi vá

- Sao lưu database và snapshot server nếu nhà cung cấp hỗ trợ.
- Chọn một server ít quan trọng làm thử trước.
- Với site đang đóng băng, `wp-freeze.sh` không ảnh hưởng việc cập nhật PHP; không cần mở băng.
- Ghi lại baseline: `./wp-health-check.sh --all > /root/health-before.tsv`.

## Bước 4: vá một server

1. Cập nhật danh sách gói và xem cái gì sẽ đổi:
   ```bash
   apt update
   apt list --upgradable 2>/dev/null | grep -i php
   ```
2. Cập nhật đúng các gói PHP cần thiết (thay tên gói thực tế ở bước 2).
3. Kiểm tra cấu hình trước khi khởi động lại (với PHP-FPM chuẩn): `php-fpm8.3 -t`.
4. Khởi động lại dịch vụ tương ứng:
   ```bash
   systemctl restart php82rc-fpm      # RunCloud + nginx
   systemctl restart lsws-rc          # OpenLiteSpeed
   systemctl reload php8.3-fpm        # PHP-FPM chuẩn
   ```
5. Xác nhận phiên bản và thời điểm khởi động:
   ```bash
   /RunCloud/Packages/php82rc/bin/php -v
   /usr/local/lsws/lsphp82/bin/php -v
   systemctl status php82rc-fpm | head -5
   ```
6. Nếu đã cài ionCube, chạy lại `./install-ioncube.sh`, vì nó cài loader theo từng phiên bản PHP.

## Bước 5: kiểm tra sau khi vá

```bash
./wp-health-check.sh --all > /root/health-after.tsv
diff /root/health-before.tsv /root/health-after.tsv
```

Mã thoát `0` nghĩa là mọi site ok. Sau đó kiểm tra bằng tay một site có giỏ hàng, một site có form, và xem log lỗi PHP trong 24 giờ đầu.

## Bước 6: phiên bản hết hỗ trợ (7.4, 8.1 và cũ hơn)

Phiên bản hết hỗ trợ không nhận bản vá chính thức. Ưu tiên theo thứ tự:

1. Chuyển site sang phiên bản PHP được hỗ trợ trong RunCloud panel, kiểm tra bằng staging, rồi chuyển thật.
2. Nếu chưa chuyển kịp: giới hạn truy cập (VPN, IP whitelist, Cloudflare WAF) hoặc tạm ngừng public site đó.
3. Chuyển site sang server khác đã có PHP được hỗ trợ (`wp-migration.sh`).

Không chặn cổng 80 của cả server để "cho an toàn". Làm vậy sẽ làm sập mọi site trên server và cổng 443 vẫn mở.

## Khi có đợt vá khẩn cấp (ví dụ CVE-2026-109618 và CVE-2026-109619)

PHP lên lịch phát hành lúc 14:00 UTC ngày 21/10/2026 (21:00 giờ Việt Nam). Tại thời điểm viết, PHP chưa công bố phiên bản bị ảnh hưởng và phiên bản đã vá.

1. Trước giờ phát hành: hoàn thành bước 1 và 3.
2. Đọc [thông báo trên php.net](https://www.php.net/archive/2026.php#2026-10-20-1) để biết phiên bản bị ảnh hưởng và phiên bản vá.
3. Đối chiếu với nhà cung cấp gói (bước 2). Chưa có gói thì chưa vá được; áp dụng bước 6 cho phiên bản hết hỗ trợ.
4. Vá từng server theo bước 4, thử trên server ít quan trọng trước.
5. Theo dõi tiến trình PHP sinh shell (xem [security-runbook.md](security-runbook.md)).

## Việc có thể tự động hoá sau này

Một script kiểm kê (`php-inventory.sh`) in ra bảng server, site, phiên bản, trạng thái hỗ trợ, và một script vá có `--dry-run`. Chưa viết.
