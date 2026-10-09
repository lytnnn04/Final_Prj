# AES-XTS + Parallel GHASH x2

RTL đã chuyển sang **hai bộ nhân GF(2¹²⁸) tổ hợp và bộ đệm hai phần tử bằng DFF**. Bảng tra GHASH và `auth_fifo4` đã được loại bỏ. S-box và inverse S-box AES cũng đã chuyển sang logic tổ hợp, không còn ROM/M20K hoặc `$readmemh` trong RTL.

## Đọc mã nguồn

| Tệp | Vai trò |
|---|---|
| `aes_sbox_logic.v` | S-box/inverse tính bằng nghịch đảo GF(2⁸) + affine, không bảng tra. |
| `aes_sub_bytes.v` | DFF ở ranh giới SubBytes/SubWord, giữ latency và clock-enable. |
| `gf_mult_128.v` | Mạng AND/XOR, cây XOR cân bằng và reduction cố định; không clock/RAM. |
| `ghash_core.v` | Hai multiplier song song, thanh ghi H/H²/Y; xử lý cặp và singleton. |
| `auth_pair_buffer.v` | Gom cặp 128-bit, metadata `last`, backpressure và pop/push đồng thời. |
| `aes_xts_top_module.v` | Setup H², chọn AAD/ciphertext/length, handshake và finalize. |

[S-box logic và kiểm tra không có bộ nhớ](docs/aes-sbox-logic.vi.md) giải thích phép biến đổi đại số và cách giữ pipeline AES.

[Hướng dẫn kiến trúc và chu kỳ hoạt động](docs/ghash-x2.vi.md) giải thích từng khối và các điều kiện điều khiển. [Báo cáo baseline](docs/parallel-ghash-review.vi.md) được giữ làm tài liệu đối chiếu với commit `9eebeb2`.

Cặp khối: `Ynext = (Y XOR X1) · H² XOR X2 · H`.

Khối cuối đơn lẻ: `Ynext = (Y XOR Xlast) · H`, không đệm thêm khối zero. Length block đi qua cùng buffer và mang cờ `last`, tránh deadlock khi cuối thông điệp còn một khối chưa đủ cặp. H² được tính bằng cách dùng lại multiplier thứ nhất lúc setup; tổng cộng chỉ có hai bộ nhân.

## Chạy mô phỏng

```bash
cd /workspace/Final_Prj
bash scripts/setup_sim.sh
/workspace/.tools/final-prj/venv/bin/python tests/run_checks.py
```

Script cài Icarus Verilog 12.0 và Yosys 0.52 từ gói Debian được xác minh chữ ký/hash và Python `cryptography==50.0.0` vào `/workspace/.tools/final-prj`, không cần sudo. Nhánh cài Icarus cục bộ dành cho Debian 13 x86_64; cần Python 3 có venv, APT, dpkg-deb và Debian archive keyring. Các miền tải: `deb.debian.org`, `pypi.org`, `files.pythonhosted.org`. Không cần API key hay dịch vụ nền.

Nếu máy đã có `iverilog`, `vvp` và Python `cryptography`, chạy `python3 tests/run_checks.py`. Runner tự chọn thư mục repository, đọc bảng chuẩn chỉ từ `tests/vectors/` để kiểm thử S-box, tạo build tạm ngoài checkout và trả mã lỗi khác 0 khi compile, so sánh hoặc timeout thất bại. RTL biên dịch được ở chế độ Verilog-2005; testbench dùng SystemVerilog.

### Testbench IEEE/CAVS của người dùng

[tests/tb_aes_xts_top.v](tests/tb_aes_xts_top.v) giữ nguyên các vector IEEE 1619 và CAVS ban đầu, sửa chuỗi `$display` và đổi thứ tự finalize cho GHASH x2. Khi còn khối lẻ, phải gửi finalize trước khi chờ `pipeline_idle`: length block sẽ hoàn tất cặp đang chờ. Testbench còn thêm timeout, kiểm tra output ổn định khi stall và GMAC 1/2/3 khối với tag tham chiếu độc lập.

```bash
bash scripts/run_user_tb.sh
```

Kết quả: **204 PASSED, 0 FAILED**, gồm 96 khối mã hóa + 96 khối giải mã, BIST, GMAC 0/1/2/3 khối, DM-AEAD, trạng thái khóa và tag đúng/sai. Có 61 chu kỳ output bị stall được kiểm tra. Các vector XTS được đối chiếu độc lập bằng OpenSSL; tag GMAC bổ sung được tính bằng `cryptography.AESGCM` với plaintext rỗng và AAD tương ứng. Đây là kiểm tra chức năng, không phải chứng nhận bảo mật. Runner trả mã lỗi khác 0 nếu compile hoặc test thất bại; thay đổi có chủ đích một expected ciphertext đã xác nhận đường báo lỗi hoạt động.

Với ModelSim/Questa, compile các tệp RTL ở thư mục gốc và `tests/tb_aes_xts_top.v`, chọn top `tb_aes_xts_top`, chạy `run -all`. RTL không cần tệp HEX; danh sách compile phải dùng `aes_sbox_logic.v` và `aes_sub_bytes.v` thay cho `aes_sbox_m20k.v` cũ. Đã chạy bằng Icarus; chưa chạy ModelSim/Questa trong môi trường này.

## Kiểm chứng

29 nhóm kiểm tra:

- Mô hình toán: 1.000 phép nhân đối chiếu độc lập, 1.000 đẳng thức GHASH x2, vector known-answer và 256 cặp S-box/inverse.
- S-box RTL: đủ 256 giá trị forward/inverse, composition và kiểm tra các thanh ghi SubBytes/SubWord giữ nguyên khi `en=0`.
- AES iterative: vector chuẩn AES-128.
- Bộ nhân RTL: 773 vector, gồm zero/identity/all-ones, toàn bộ 255 bậc đơn thức của tích thô và 512 cặp ngẫu nhiên.
- GHASH x2 RTL: 96 batch với bốn khóa, cặp liên tiếp/singleton, valid gaps, H², clear/invalidate/reset.
- Buffer: scoreboard 1.500 chu kỳ, message dài 1–9 khối, stall dài, pop/push đồng thời, last lẻ/chẵn, clear khi đầy và reset.
- 20 kịch bản top: encrypt/decrypt × DM off/on × 0/1/2/3/16 khối; có input gaps và output backpressure, gồm stall 40 chu kỳ. XTS đối chiếu OpenSSL; tag đối chiếu AES+GHASH phần mềm.
- Hai kịch bản throughput: 64 khối liên tục cho mỗi chiều, assertion khoảng cách giữa các handshake input/output bằng một chu kỳ.
- Một kịch bản lifecycle: năm thông điệp liên tiếp, đổi LBA giữ H/H², đổi mode/key tạo lại H², clear-key giữa AES pipeline và khởi động lại.

Đây là functional simulation. Đã đo II=1 **theo handshake ở RTL** khi không stall, chưa đo fmax hay xác nhận timing FPGA. Cần FPGA part, QSF/QPF và SDC để chạy Quartus/fitter. S-box AES không dùng RAM; DFF pipeline vẫn được giữ để căn chỉnh dữ liệu. Bộ đệm dùng ready tổ hợp, không cắt đường ready bằng register. Thiết kế này xử lý full 128-bit blocks; không bổ sung XTS ciphertext stealing hoặc giải quyết lại giao thức nonce/tag của baseline.

## Kiểm tra không suy luận bộ nhớ

```bash
bash scripts/check_no_memories.sh
```

Yosys xác nhận hierarchy top có **0 memories, 0 memory bits và không latch**, trước khi map memory sang logic. Script báo lỗi nếu xuất hiện memory/latch. Rcon trong iterative setup cũng đã được đổi từ bảng hằng số sang `xtime`. Chưa chạy Intel Quartus/Fitter; các con số generic cell của Yosys không phải số ALM.
