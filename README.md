# AES-XTS + Parallel GHASH x2

RTL đã chuyển sang **hai bộ nhân GF(2¹²⁸) tổ hợp và bộ đệm hai phần tử bằng DFF**. Bảng tra GHASH và `auth_fifo4` đã được loại bỏ. AES-XTS datapath và các ROM S-box giữ nguyên.

## Đọc mã nguồn

| Tệp | Vai trò |
|---|---|
| `gf_mult_128.v` | Mạng AND/XOR, cây XOR cân bằng và reduction cố định; không clock/RAM. |
| `ghash_core.v` | Hai multiplier song song, thanh ghi H/H²/Y; xử lý cặp và singleton. |
| `auth_pair_buffer.v` | Gom cặp 128-bit, metadata `last`, backpressure và pop/push đồng thời. |
| `aes_xts_top_module.v` | Setup H², chọn AAD/ciphertext/length, handshake và finalize. |

[Hướng dẫn kiến trúc và chu kỳ hoạt động](docs/ghash-x2.vi.md) giải thích từng khối và các điều kiện điều khiển. [Báo cáo baseline](docs/parallel-ghash-review.vi.md) được giữ làm tài liệu đối chiếu với commit `9eebeb2`.

Cặp khối: `Ynext = (Y XOR X1) · H² XOR X2 · H`.

Khối cuối đơn lẻ: `Ynext = (Y XOR Xlast) · H`, không đệm thêm khối zero. Length block đi qua cùng buffer và mang cờ `last`, tránh deadlock khi cuối thông điệp còn một khối chưa đủ cặp. H² được tính bằng cách dùng lại multiplier thứ nhất lúc setup; tổng cộng chỉ có hai bộ nhân.

## Chạy mô phỏng

```bash
cd /workspace/Final_Prj
bash scripts/setup_sim.sh
/workspace/.tools/final-prj/venv/bin/python tests/run_checks.py
```

Script cài Icarus Verilog 12.0 từ gói Debian được xác minh chữ ký/hash và Python `cryptography==50.0.0` vào `/workspace/.tools/final-prj`, không cần sudo. Nhánh cài Icarus cục bộ dành cho Debian 13 x86_64; cần Python 3 có venv, APT, dpkg-deb và Debian archive keyring. Các miền tải: `deb.debian.org`, `pypi.org`, `files.pythonhosted.org`. Không cần API key hay dịch vụ nền.

Nếu máy đã có `iverilog`, `vvp` và Python `cryptography`, chạy `python3 tests/run_checks.py`. Runner tự chọn thư mục repository để hai tệp HEX được tìm đúng, tạo build tạm ngoài checkout và trả mã lỗi khác 0 khi compile, so sánh hoặc timeout thất bại. RTL biên dịch được ở chế độ Verilog-2005; testbench dùng SystemVerilog.

## Kiểm chứng

28 nhóm kiểm tra:

- Mô hình toán: 1.000 phép nhân đối chiếu độc lập, 1.000 đẳng thức GHASH x2, vector known-answer và 256 cặp S-box/inverse.
- AES iterative: vector chuẩn AES-128.
- Bộ nhân RTL: 773 vector, gồm zero/identity/all-ones, toàn bộ 255 bậc đơn thức của tích thô và 512 cặp ngẫu nhiên.
- GHASH x2 RTL: 96 batch với bốn khóa, cặp liên tiếp/singleton, valid gaps, H², clear/invalidate/reset.
- Buffer: scoreboard 1.500 chu kỳ, message dài 1–9 khối, stall dài, pop/push đồng thời, last lẻ/chẵn, clear khi đầy và reset.
- 20 kịch bản top: encrypt/decrypt × DM off/on × 0/1/2/3/16 khối; có input gaps và output backpressure, gồm stall 40 chu kỳ. XTS đối chiếu OpenSSL; tag đối chiếu AES+GHASH phần mềm.
- Hai kịch bản throughput: 64 khối liên tục cho mỗi chiều, assertion khoảng cách giữa các handshake input/output bằng một chu kỳ.
- Một kịch bản lifecycle: năm thông điệp liên tiếp, đổi LBA giữ H/H², đổi mode/key tạo lại H², clear-key giữa AES pipeline và khởi động lại.

Đây là functional simulation. Đã đo II=1 **theo handshake ở RTL** khi không stall, chưa đo fmax hay xác nhận timing FPGA. Cần FPGA part, QSF/QPF và SDC để chạy Quartus/fitter. ROM S-box AES vẫn dùng RAM. Bộ đệm dùng ready tổ hợp, không cắt đường ready bằng register. Thiết kế này xử lý full 128-bit blocks; không bổ sung XTS ciphertext stealing hoặc giải quyết lại giao thức nonce/tag của baseline.
