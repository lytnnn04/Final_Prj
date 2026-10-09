# S-box tra bảng hằng bằng case tổ hợp

S-box dùng đúng kiểu `always @(*)` + `case` trong file `AES_Core.v` người dùng cung cấp làm mẫu. Đã bỏ toàn bộ module nghịch đảo GF(2⁸), phép lũy thừa và affine của bản trước.

## Mã nguồn

`aes_sbox_logic.v` có hai module:

- `aes_sbox_comb`: 256 mục S-box chuẩn AES, từ `8'h00` đến `8'hff`.
- `aes_inv_sbox_comb`: 256 mục inverse S-box cho giải mã.

Ví dụ:

```verilog
always @(*) begin
    case (data_in)
        8'h00: data_out = 8'h63;
        8'h01: data_out = 8'h7c;
        // ... các mục 02..FE ...
        8'hff: data_out = 8'h16;
        default: data_out = 8'h00;
    endcase
end
```

Mỗi mục gán trực tiếp một hằng 8 bit. Bảng forward được đối chiếu đủ 256 mục với module `sbox` trong file mẫu. Có `default` để không tạo latch. Không dùng mảng RAM, `$readmemh` hay clock trong hai module này. Hai bảng HEX ở `tests/vectors/` chỉ là fixture độc lập cho kiểm thử, không được RTL đọc lúc chạy.

`aes_sub_bytes.v` giữ các DFF ở ranh giới pipeline: S-box tổ hợp cho kết quả trước cạnh clock; `en=1` chốt kết quả, `en=0` giữ nguyên. Nhờ đó latency AES vẫn là 20 clock-enable, round key/state/valid/tweak giữ đúng căn chỉnh. GHASH x2, bộ gom cặp và công thức tag không đổi.

## Ánh xạ sang logic thay vì M20K

`case` mô tả bảng tổ hợp, nhưng một công cụ tổng hợp có thể tự nhận diện nó như ROM. Vì vậy hai module có thuộc tính Quartus:

```verilog
(* altera_attribute = "-name AUTO_ROM_RECOGNITION OFF" *)
```

Nếu cấu hình project Quartus ở mức toàn cục, có thể đặt trong QSF:

```tcl
set_global_assignment -name AUTO_ROM_RECOGNITION OFF
```

Đây là lựa chọn ánh xạ phần cứng, không thay đổi giá trị S-box. Project cần compile `aes_sbox_logic.v` và `aes_sub_bytes.v`, không dùng `aes_sbox_m20k.v` cũ; không cần nạp HEX. File `AES_Core.v` chỉ được dùng làm mẫu S-box, không thay thế pipeline/top hiện tại.

## Kiểm tra

```bash
bash scripts/check_no_memories.sh
/workspace/.tools/final-prj/venv/bin/python tests/run_checks.py
bash scripts/run_user_tb.sh
```

Luồng Yosys dùng `proc -norom` để giữ `case` ở dạng mux/logic, thay vì tự chuyển các switch thành ROM. Sau đó `memory_collect` và assertion vẫn bắt mọi memory array hoặc latch còn lại; không chạy `memory_map` để che giấu memory. Kết quả **trong luồng ánh xạ này** là 0 memories, 0 memory bits, không latch. Không diễn giải kết quả đó thành bằng chứng rằng mọi cấu hình tổng hợp mặc định đều không nhận diện ROM.

Kiểm tra S-box phủ đủ 256 đầu vào cho mỗi chiều, composition và DFF/clock-enable. Regression còn có AES KAT, XTS/tag, GHASH, stall và các vector IEEE/CAVS của người dùng. Chưa có báo cáo Intel Quartus/Fitter để xác nhận tài nguyên và fmax trên FPGA cụ thể.
