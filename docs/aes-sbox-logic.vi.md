# AES S-box bằng logic tổ hợp, không dùng bộ nhớ

## Các tệp

- `aes_sbox_logic.v`: phép nghịch đảo GF(2⁸), S-box và inverse S-box, không clock.
- `aes_sub_bytes.v`: các S-box tổ hợp và DFF giữ latency/clock-enable của pipeline.
- `aes_setup_engine.v`: dùng S-box logic, sinh Rcon bằng `xtime` thay bảng hằng số.
- `aes_pipeline_cores.v`: SubWord và SubBytes dùng các module mới.

Đã bỏ `aes_sbox_m20k.v`. Nếu project Quartus/ModelSim của bạn có danh sách tệp cố định, bỏ tệp cũ và thêm **cả `aes_sbox_logic.v` lẫn `aes_sub_bytes.v`**. Không còn yêu cầu copy HEX hoặc cấu hình `ram_init_file`. Hai HEX trong `tests/vectors/` chỉ là dữ liệu chuẩn cho testbench Python, không phải đầu vào phần cứng.

## S-box tính như thế nào?

AES biểu diễn byte trong GF(2⁸) với đa thức `x⁸ + x⁴ + x³ + x + 1` (`0x11b`), bit i là hệ số xⁱ. Đây là quy ước khác với cách đặt bit của GHASH.

Với `a != 0`, phần tử nghịch đảo là `a²⁵⁴`; với `a=0`, quy ước nghịch đảo bằng 0. Module dùng addition chain:

```
a²   = square(a)
a³   = a² × a
a⁶   = square(a³)
a¹²  = square(a⁶)
a¹⁵  = a¹² × a³
a³⁰  = square(a¹⁵)
a⁶⁰  = square(a³⁰)
a¹²⁰ = square(a⁶⁰)
a²⁴⁰ = square(a¹²⁰)
a²⁵² = a²⁴⁰ × a¹²
a²⁵⁴ = a²⁵² × a²
```

Bảy phép bình phương là mạng XOR tuyến tính. Bốn phép nhân dùng partial products AND, cây XOR cân bằng và reduction cố định. Không có truy cập mảng theo địa chỉ hoặc `case` 256 nhánh để lookup S-box. Mảng `partial` cục bộ trong hàm multiply chỉ diễn tả các dây trung gian của vòng lặp được unroll khi tổng hợp.

Đặt `rol(x,k)` là quay vòng trái byte x k bit:

```
S(a) = inverse(a) XOR rol(inverse(a),1) XOR rol(inverse(a),2)
       XOR rol(inverse(a),3) XOR rol(inverse(a),4) XOR 0x63

S⁻¹(b) = inverse(rol(b,1) XOR rol(b,3) XOR rol(b,6) XOR 0x05)
```

Inverse S-box phải làm inverse-affine trước khi nghịch đảo trường. Kiểm tra đủ 256 đầu vào cho mỗi chiều giúp phát hiện sai thứ tự hoặc sai hướng quay bit.

## Vì sao vẫn có DFF?

**Lõi S-box là tổ hợp**, còn AES là hệ thống pipeline. Các lớp `aes_sbox_pair_sync`, `aes_sub_bytes_sync` và `aes_inv_sub_bytes_sync` chốt kết quả bằng DFF tại cạnh clock khi `en=1`; `en=0` giữ dữ liệu.

Giữ ranh giới DFF một nhịp của SubBytes/SubWord giúp:

- Pipeline AES vẫn có latency 20 clock-enable và khả năng nhận một khối mỗi chu kỳ.
- Round key, state, valid và tweak vẫn cùng dừng khi backpressure.
- AES iterative setup vẫn theo ba bước mỗi round: xử lý SubWord, xử lý SubBytes, capture round.

Rcon iterative khởi đầu bằng `01`, cập nhật ở cuối mỗi round bằng `xtime`: dịch trái và XOR `0x1b` khi bit cao là 1. Việc thay `case get_rcon` cũng loại bỏ một ROM nhỏ mà Yosys có thể suy luận từ bảng hằng số cũ.

## Kiểm chứng không có memory

```bash
bash scripts/setup_sim.sh
bash scripts/check_no_memories.sh
/workspace/.tools/final-prj/venv/bin/python tests/run_checks.py
bash scripts/run_user_tb.sh
```

Yosys đọc toàn bộ hierarchy từ `aes_xts_top_module`, chuyển process và tối ưu, sau đó chạy `memory_collect`. Script **không chạy `memory_map`** trước assertion; vì vậy không che giấu một ROM bằng cách map nó thành mux sau khi đã bị suy luận. Assertion yêu cầu không có `$mem*`, `$dlatch*`, `$adlatch*`; `check -assert` kiểm tra kết nối cơ bản. Kết quả generic netlist: **0 memories, 0 memory bits, không latch**. Đây không phải báo cáo tài nguyên của Intel Fitter.

Kiểm thử chức năng gồm đủ 256 giá trị S-box/inverse, composition, latency DFF, `en=0`, AES KAT, GHASH, XTS/tag, backpressure và các vector IEEE/CAVS của người dùng. Test Python đọc fixture từ `tests/vectors/`; mô phỏng RTL không đọc HEX.

## Timing và tài nguyên

Đổi ROM sang nghịch đảo trường làm tăng logic và tạo đường tổ hợp dài hơn. “Không thêm chu kỳ” không có nghĩa độ trễ lan truyền không đổi. Chưa có FPGA part, QSF/QPF và SDC để đo ALM, fmax hoặc timing closure; kết quả II=1 trong mô phỏng không thay cho việc kiểm tra timing trên Quartus. Đây là hiện thực đại số dễ đối chiếu, chưa phải S-box được tối ưu diện tích/độ sâu bằng composite-field hay mạng Boolean chuyên dụng.
