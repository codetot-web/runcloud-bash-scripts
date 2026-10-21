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

Tra tình trạng hỗ trợ trên [php.net/supported-versions.php](https://www.php.net/supported-versions.php). Tại 21/10/2026: 8.4 và 8.5 hỗ trợ đầy đủ, 8.2 và 8.3 chỉ vá bảo mật (8.2 hết vòng đời 31/12/2026), 8.1 và 7.4 đã hết hỗ trợ.

## Bước 2: xác định bản vá đến từ đâu

PHP phát hành mã nguồn; server của mình nhận bản vá qua gói. Hai thứ này có thể lệch nhau vài giờ hoặc vài ngày.

```bash
dpkg -S /RunCloud/Packages/php82rc/bin/php        # gói nào sở hữu binary này
apt-cache policy <tên-gói-ở-lệnh-trên>
```

Chỉ coi một gói là đã vá khi changelog của gói nhắc đến CVE cần vá hoặc phiên bản gói không thấp hơn phiên bản PHP mà php.net công bố đã sửa.
Với gói của RunCloud, theo dõi thông báo của RunCloud. Đừng tự biên dịch PHP trên server đang chạy production.

Với PHP-FPM chuẩn (hàng thứ ba trong bảng trên), kiểm tra máy đang lấy gói từ đâu, vì hai nguồn có thể lệch nhau vài giờ:

```bash
grep -rhE 'sury|ondrej' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
apt-cache policy php8.3-fpm | head -8
```

- `packages.sury.org` là kho chính của Ondrej Sury. Bản vá ngày 21/10/2026 đã có ở đây.
- `ppa.launchpadcontent.net/ondrej/php` (PPA Launchpad) là bản mirror, có thể về chậm hơn vài giờ. Máy dùng PPA cần chờ, hoặc chuyển sang kho `packages.sury.org` theo hướng dẫn của Ondrej.

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

PHP không còn phát hành bản chính thức cho các nhánh này. Ngoại lệ cần kiểm tra: kho `packages.sury.org` đã có gói `php7.4-fpm` bản `7.4.33-31` (build 21/10/2026, cùng ngày với bản vá). Gói do Ondrej Sury xây dựng, không phải bản phát hành của PHP.
Chỉ coi máy là đã vá khi `apt changelog php7.4-fpm` nhắc đến CVE-2026-109618 và CVE-2026-109619 (hoặc nguồn của Sury xác nhận). Áp dụng cho máy dùng PHP-FPM chuẩn từ Sury; gói PHP của RunCloud là kênh riêng.
Dù có bản backport, 7.4 vẫn là nhánh đã chết nhiều năm: coi đó là biện pháp tạm và vẫn lên kế hoạch nâng nhánh. Ưu tiên theo thứ tự:

1. Chuyển site sang phiên bản PHP được hỗ trợ trong RunCloud panel, kiểm tra bằng staging, rồi chuyển thật.
2. Nếu chưa chuyển kịp: giới hạn truy cập (VPN, IP whitelist, Cloudflare WAF) hoặc tạm ngừng public site đó.
3. Chuyển site sang server khác đã có PHP được hỗ trợ (`wp-migration.sh`).

Không chặn cổng 80 của cả server để "cho an toàn". Làm vậy sẽ làm sập mọi site trên server và cổng 443 vẫn mở.

## Khi có đợt vá khẩn cấp (ví dụ CVE-2026-109618 và CVE-2026-109619)

PHP đã phát hành bản vá ngày 21/10/2026 ([thông báo](https://www.php.net/archive/2026.php#2026-10-21-5)). Cả hai lỗi là RCE không cần xác thực, CVSS v4.0 9.2, ảnh hưởng mọi bản cài PHP phục vụ request web.

| Nhánh         | Phiên bản cần có                               |
| ------------- | ---------------------------------------------- |
| 8.5           | 8.5.12 trở lên                                 |
| 8.4           | 8.4.27 trở lên                                 |
| 8.3           | 8.3.36 trở lên                                 |
| 8.2           | 8.2.35 trở lên                                 |
| 8.1 và cũ hơn | Không có bản phát hành chính thức (xem bước 6) |

1. Hoàn thành bước 1 và 3 (kiểm kê, sao lưu).
2. Xác định kho gói của từng máy (bước 2). Máy dùng PPA Launchpad có thể chưa thấy gói mới; kho `packages.sury.org` đã có (8.3.36 đã được xác nhận trên kho này).
3. Gói RunCloud: chỉ coi là đã vá khi `/RunCloud/Packages/phpXYrc/bin/php -v` báo phiên bản trong bảng trên. Chưa có thì theo dõi thông báo của RunCloud và dùng biện pháp ở [security-runbook.md](security-runbook.md).
4. Vá từng server theo bước 4, thử trên server ít quan trọng trước.
5. Theo dõi tiến trình PHP sinh shell (xem [security-runbook.md](security-runbook.md)).

## Việc có thể tự động hoá sau này

Một script kiểm kê (`php-inventory.sh`) in ra bảng server, site, phiên bản, trạng thái hỗ trợ, và một script vá có `--dry-run`. Chưa viết.
