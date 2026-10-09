# AES-XTS + GHASH / GMAC

Baseline RTL do người dùng cung cấp, kèm mô phỏng và đánh giá hướng **Parallel GHASH x2 + bộ đệm hai phần tử**.

**Trạng thái:** 9 tệp `.v`/`.hex` gốc được giữ nguyên byte. Chưa thay GHASH bằng hai bộ nhân, chưa thay FIFO. Đề xuất và các điểm cần sửa nằm trong [báo cáo kiến trúc](docs/parallel-ghash-review.vi.md).

## Chạy mô phỏng trong môi trường cloud

```bash
cd /workspace/Final_Prj
bash scripts/setup_sim.sh
/workspace/.tools/final-prj/venv/bin/python tests/run_checks.py
```

Script cài Icarus Verilog 12.0 từ gói Debian có kiểm tra chữ ký/hash và Python `cryptography==50.0.0` vào `/workspace/.tools/final-prj`, không cần sudo. Nhánh cài Icarus cục bộ dành cho Debian 13 x86_64; cần Python 3 có venv, APT, dpkg-deb và Debian archive keyring. Các miền tải: `deb.debian.org`, `pypi.org`, `files.pythonhosted.org`. Không cần API key hay dịch vụ nền.

Nếu máy đã có Icarus (`iverilog`, `vvp`) và Python `cryptography`, có thể chạy `python3 tests/run_checks.py`. Runner tự chọn thư mục gốc repository để `$readmemh` tìm đúng hai tệp HEX, tạo build tạm ngoài checkout và trả mã lỗi khác 0 khi compile/mô phỏng sai hoặc timeout.

## Kết quả kiểm chứng baseline

19 nhóm kiểm tra đã chạy và đạt:

- 1.000 phép nhân GHASH đối chiếu giữa mô hình shift/reduction và mô hình tích đa thức độc lập; 1.000 đẳng thức GHASH x2; vector nhân known-answer và toàn bộ 256 cặp S-box/inverse.
- AES iterative setup khớp vector chuẩn AES-128 `3243…0734 -> 3925…0b32` với khóa `2b7e…4f3c`.
- GHASH RTL: 48 khối, hai H khác nhau, clear giữ bảng, invalidate vô hiệu bảng; đo khoảng cách handshake xác nhận II = 3.
- 16 kịch bản top: encrypt/decrypt × DM off/on × 1/2/3/16 khối (88 khối tổng cộng), có valid gaps và output stalls. XTS so với `cryptography`/OpenSSL; tag so với AES-ECB + GHASH phần mềm. Kiểm tra dữ liệu output giữ ổn định khi bị backpressure, không thừa/thiếu output và finalize khi pipeline còn đang drain.

Đây là functional simulation, **không phải** chứng nhận bảo mật hoặc xác nhận timing FPGA. Chưa chạy Quartus/fitter, chưa đo ALM/M20K/fmax; chưa có FPGA part, QSF/QPF hoặc SDC. Các test mới chưa phủ toàn bộ reset giữa giao dịch, expected-tag sai/thiếu, nhiều sector liên tiếp hay nonce reuse. Các nguy cơ đọc từ RTL được tách rõ trong báo cáo.

## Điểm chính của hướng mới

`Y2 = (Y0 XOR X1) · H² XOR X2 · H` là đúng. Cần thêm trạng thái chốt H² ở FSM top, xử lý khối cuối lẻ và length block, đồng thời bảo toàn handshake trên toàn pipeline. “Combinational” không có nghĩa độ trễ vật lý bằng 0; II=1 và tài nguyên phải được đo sau triển khai. ROM S-box AES vẫn dùng RAM; FIFO gốc là RTL 4 phần tử, không phải FIFO IP.
