# Tài liệu vận hành runcloud-bash-scripts

Dành cho người vận hành (DevOps, support kỹ thuật) quản lý đội server WordPress chạy RunCloud.
`README.md` ở thư mục gốc là tham chiếu từng script. Thư mục này trả lời câu hỏi "tôi cần làm việc X thì làm gì".

## Đọc theo tình huống

| Tình huống                                                                  | Đọc                                              |
| --------------------------------------------------------------------------- | ------------------------------------------------ |
| Mới nhận server, cần cài và cập nhật script                                 | [getting-started.md](getting-started.md)         |
| Việc định kỳ: dọn đĩa, kiểm tra sức khỏe, quét lỗ hổng, theo dõi tài nguyên | [daily-operations.md](daily-operations.md)       |
| Chuyển site, cập nhật plugin, đóng băng code, dọn git                       | [wordpress-lifecycle.md](wordpress-lifecycle.md) |
| Nghi ngờ bị tấn công, phát hiện webshell, lỗ hổng nghiêm trọng              | [security-runbook.md](security-runbook.md)       |
| Cập nhật hoặc vá PHP (kể cả đợt vá khẩn như CVE-2026-109618/109619)         | [php-update-runbook.md](php-update-runbook.md)   |
| Site lỗi 500, wp-cli không chạy, MariaDB không khởi động lại                | [troubleshooting.md](troubleshooting.md)         |

## Quy ước chung của mọi script

- Chạy bằng `root` trên server RunCloud, trừ khi tài liệu nói khác.
- Chọn site bằng `--site=TÊN` (tìm trong `/home/*/webapps/`) hoặc `--path=ĐƯỜNG_DẪN` ở những script hỗ trợ.
- Script có `--dry-run` thì luôn chạy `--dry-run` trước khi chạy thật.
- Chạy một server, kiểm tra kết quả, rồi mới sang server tiếp theo. Không chạy song song toàn đội ở lần đầu.
- Kiểm tra cú pháp trước khi đưa script lên server: `bash -n tên-script.sh`.

## Quy tắc cho repo public

Repo này công khai. Không đưa vào tài liệu hoặc commit: hostname và IP server, cổng SSH, số lượng server,
token, secret webhook, đường dẫn chứa tên khách hàng. Dùng `YOUR_SERVER`, `myapp`, `example.com` làm ví dụ.

## Việc chưa có trong repo

- Chưa có script cập nhật PHP-FPM. Quy trình thủ công nằm ở [php-update-runbook.md](php-update-runbook.md).
- Chưa có script sao lưu (backup) cho site. Việc sao lưu nằm ngoài repo này.
