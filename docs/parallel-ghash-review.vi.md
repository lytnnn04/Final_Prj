# Đánh giá Parallel GHASH x2 + bộ đệm hai phần tử

Phạm vi: đọc toàn bộ 7 tệp Verilog và 2 ROM HEX người dùng cung cấp; giữ nguyên RTL gốc, bổ sung mô phỏng và đề xuất thiết kế. Chưa triển khai `gf_mult_128`, GHASH x2 hoặc skid buffer mới. Đây là đánh giá kiến trúc, chưa phải kết quả tổng hợp FPGA.

## 1. Hệ thống hiện tại

| Tệp | Chức năng và nhận xét |
|---|---|
| `aes_xts_top_module.v` | Avalon-MM CSR, Avalon-ST, BIST, FSM sinh Kauth/H/mask/tweak, điều phối AAD/ciphertext/GHASH/finalize. FSM setup hệ thống nằm **ở đây**, không nằm trong AES iterative engine. |
| `aes_setup_engine.v` | AES-128 iterative dùng S-box đồng bộ; 3 trạng thái xử lý mỗi round, dùng cho BIST và các phép AES setup. |
| `aes_pipeline_cores.v` | Mã hóa và giải mã AES unrolled; 20 bước clock-enable; tweak chỉ tăng khi chấp nhận input. Cả hai nhánh AES cùng tồn tại. |
| `aes_round_transforms.v` | ShiftRows/MixColumns và nghịch đảo; nhân alpha cho XTS theo quy ước byte little-endian. Không dùng trực tiếp phép này thay cho nhân GHASH. |
| `aes_sbox_m20k.v` + hai HEX | ROM S-box/inverse S-box đồng bộ dùng trong cả pipeline và setup. Các ROM này vẫn cần sau khi thay GHASH. |
| `ghash_core.v` | 16 bảng 256 × 128 bit, khởi tạo theo H; CAPTURE/PARTIAL/FINAL; cho phép nhận khối kế tiếp ở FINAL bằng forwarding `final_result`. II = 3. |
| `auth_fifo.v` | `auth_fifo4`: hàng đợi RTL 4 × 128 bit, shift-register, có simultaneous push/pop; không instantiate FIFO IP. Không có bằng chứng FIFO này đang chiếm M20K. |

Khi mã hóa, GHASH lấy ciphertext ở handshake output; khi giải mã, GHASH lấy ciphertext ở handshake input. Không được chuyển sang hash plaintext khi sửa luồng. AES, S-box, key pipeline, valid và tweak cùng đóng băng theo `en`. Đây là cơ sở để có thể dùng bộ đệm nhỏ; độ sâu pipeline 20 không tự động đòi FIFO 20 phần tử nếu toàn pipeline thực sự dừng đồng bộ.

## 2. Công thức và quy ước bit

GHASH chuẩn:

```
Y1 = (Y0 XOR X1) · H
Y2 = (Y1 XOR X2) · H
   = (Y0 XOR X1) · H² XOR X2 · H
```

Hai bộ nhân phải nhận `(Y0 XOR X1, H²)` và `(X2, H)`. Không XOR trực tiếp Y0 ở đầu ra: `Y0 XOR X1·H² XOR X2·H` là sai.

Dùng trường GF(2^128), đa thức `x^128 + x^7 + x^2 + x + 1`. Với quy ước GHASH đang dùng: quét toán hạng từ bit 127 xuống 0, dịch phải, reduction `128'he1000000000000000000000000000000`. Phần tử đơn vị biểu diễn bằng `128'h80000000000000000000000000000000`, không phải số nguyên 1. H² dùng cùng quy ước này. Phép alpha của XTS dùng biểu diễn khác dù có cùng đa thức bất khả quy.

Vector đối chiếu: `0388dace60b6a392f328c2b971b2fe78 · 66e94bd4ef8a2c3b884cfa59ca342b2e = 5e2ec746917062882c85b0685353deb7`.

## 3. Thiết kế đề xuất

### Bộ nhân `gf_mult_128`

Giao diện tổ hợp: `a[127:0], b[127:0] -> product[127:0]`, không có clock hoặc RAM. Tạo partial products AND, tính reduction bằng mạng XOR cố định và cộng bằng cây XOR cân bằng. Để gọi chính xác là Mastrovito, cần thể hiện ma trận tích/reduction trong polynomial basis; vòng lặp shift-XOR tổ hợp unrolled chỉ là một hiện thực nhân trường, không tự chứng minh kiến trúc Mastrovito.

Với 128 partial products, cây cộng nhị phân có 7 tầng XOR; đó **không phải** tổng độ sâu critical path vì còn reduction, XOR đầu vào, fanout và routing. Tránh chuỗi `z = z ^ term` dài nếu không kiểm soát kết quả tổng hợp. H/H² chỉ cố định giữa các lần nạp khóa, không phải hằng elaboration: vẫn cần nhân với toán hạng lập trình được.

### Sinh H² trong setup

Sau khi chốt H từ AES, thêm trạng thái `SETUP_H2` ở FSM của **top module**. Mux bộ nhân thứ nhất sang `(H,H)`, chốt H² ở cạnh clock tiếp theo rồi đặt `hash_keys_ready`. Không tính từ thanh ghi H cũ ngay ở cạnh đang gán H bằng nonblocking assignment. Có thể lấy trực tiếp AES output nếu thiết kế thời gian rõ ràng, nhưng trạng thái riêng dễ kiểm chứng hơn.

Tái sử dụng một trong hai bộ nhân khi setup để tổng số bộ nhân vẫn là hai. Không instantiate một bộ nhân thứ ba chỉ để bình phương. Invalidate H/H²/readiness khi clear-key hoặc thay auth key/mode; chỉ đổi LBA không cần bình phương lại nếu auth key không đổi. Chặn input cho tới khi các khóa hash, tweak và BIST đều hợp lệ. Thay các giao diện `table_*` bằng giao diện khóa hash phù hợp.

### Bộ đệm và xử lý cặp

Tách rõ **skid buffer ready/valid** và **bộ gom cặp**: tên “skid buffer sâu 2” chưa mô tả đủ hành vi. Đề xuất hai slot 128 bit với metadata `last`, count 0/1/2; output có `block0`, `block1`, `pair_count`, `valid`, `ready`. Hỗ trợ pop-cặp và push một khối trong cùng chu kỳ, giữ thứ tự và không ghi đè slot khi downstream dừng.

- Mọi cập nhật dữ liệu/counter chỉ theo handshake; giữ output cùng metadata ổn định khi `valid && !ready`.
- Nếu đường ready là tổ hợp, phải chứng minh không có vòng ready combinational qua top/AES/buffer/GHASH.
- Nếu đăng ký ready/backpressure, phải dành slot skid cho lượng dữ liệu còn được phép đến trong độ trễ phản hồi. Không tự cho rằng hai slot vừa gom cặp vừa đủ hấp thụ mọi stall.
- Tiếp tục dùng global `en` để đóng băng toàn bộ AES, key schedule, S-box, valid và tweak; không chỉ chặn valid đầu vào rồi để kết quả trong pipeline tràn buffer.
- Khi cả hai slot có dữ liệu, pop hai phần tử; cho phép push một phần tử cùng cạnh để duy trì nhận một khối mỗi nhịp.
- Đơn giản nhất là không backpressure mọi cập nhật accumulator theo `ready_out` của AES; GHASH có handshake riêng. Tuy nhiên kết quả hash/final tag phải được giữ nếu giao diện kết quả mới có ready.

### Khối lẻ, AAD và finalize

Không thêm một **khối zero nguyên vẹn** vào cuối chỉ để đủ cặp: nó thực hiện thêm một phép nhân H và làm sai tag. Với một khối cuối, phải dùng `Ynext = (Y XOR Xlast) · H`, mux toán hạng để dùng một trong hai bộ nhân hiện có và bỏ đóng góp còn lại.

Luồng hash thực tế không chỉ có ciphertext: còn AAD (DM mode), padding của đoạn AAD và length block. Có thể ghép hai khối qua ranh giới AAD/ciphertext nếu đã tạo đúng padding và thứ tự. Gắn `last` cho length block, cho phép batch cuối chỉ chứa một khối.

Điều kiện finalize cũ đợi `auth_fifo_empty` trước khi cấp length block sẽ **deadlock** nếu bộ gom còn một khối và chỉ nhả khi đủ hai. Cần đổi FSM: dừng nhận input mới, drain AES, enqueue length block sau tất cả ciphertext, rồi flush batch 1/2 khối theo `last`. Tăng bit count theo ciphertext thực sự accepted, không theo số cặp. `tag_ready` chỉ bật sau commit accumulator của length block. Nếu `done` và accumulator chốt cùng cạnh bằng NBA, logic lấy tag phải đọc giá trị mới ở cạnh kế tiếp hoặc dùng `next_accumulator` đúng cách.

## 4. Thông lượng, tài nguyên và timing

- “0 clock delay” chỉ có nghĩa bộ nhân không có register nội bộ. Độ trễ vật lý khác 0; kết quả được chốt khi đáp ứng setup/hold ở cạnh clock.
- Đường phản hồi: `Y register -> XOR X1 -> multiply H² -> XOR product2 -> Y register`. Để commit mỗi chu kỳ, cả đường này phải đạt timing. Hai bộ nhân mắc song song không loại bỏ phụ thuộc Y.
- AES hiện chỉ cấp 128 bit/chu kỳ. Gom cặp làm một batch xuất hiện mỗi hai chu kỳ nhận liên tục; mục tiêu toàn luồng hợp lý là **1 block/clock**, sau pha làm đầy và khi không backpressure. “II=1” phải nói rõ đơn vị block hay pair và stage nào.
- Một bộ nhân tổ hợp 128-bit cũng có thể đạt GHASH một khối/chu kỳ nếu timing đủ. Hai bộ nhân không phải điều kiện bắt buộc cho II=1. Ưu điểm của folding x2 có thể là thêm ngân sách chu kỳ cho batch; cần so với phương án một bộ nhân và phương án pipeline hai nhịp cho một pair. Nếu pipeline nhân, phải xử lý khoảng cách phản hồi Y, không chỉ thêm register rồi khẳng định giữ pair II=1.
- 16 bảng hiện chứa `16 × 256 × 128 = 524288 bit`. Chỉ xét dung lượng đã cần ít nhất `ceil(524288/20480) = 26` M20K nếu lưu đầy đủ; hình dạng/port và ánh xạ từng bảng có thể cần nhiều hơn. Do đó không thể gọi là “16 M20K vật lý”. Fitter mới cho con số thực tế.
- Bỏ bảng GHASH sẽ bỏ bộ nhớ tra GHASH. **Không** giải phóng toàn bộ M20K của hệ thống: ROM S-box AES vẫn có ramstyle M20K. FIFO hiện tại chỉ 512 bit logical storage và có reset/asynchronous read; phải xem báo cáo tổng hợp trước khi tuyên bố tiết kiệm RAM từ FIFO.
- Build bảng cũ có 256 địa chỉ × 16 phase × 8 nhịp = 32768 nhịp xử lý sau table_start. Sinh H² một nhịp tổ hợp có thể loại bỏ thời gian này, nếu đường bình phương đạt timing. Các phép AES setup khác vẫn còn.
- Throughput end-to-end = 128 × fclk × số block accepted/clock trung bình. II thấp hơn nhưng fmax thấp hơn chưa chắc nhanh hơn.

Chưa có FPGA part, QSF/QPF, SDC, clock target hoặc Quartus trong bộ tệp. Chưa thể kết luận ALM/M20K/fmax, timing closure hay chất lượng routing. Khi triển khai cần so sánh cả hai bản trên cùng part, constraint và fitter seed; lưu ALM/register/M20K, WNS/TNS, fmax, throughput và latency.

## 5. Điểm cần xử lý riêng ở top hiện tại

Các nhận xét dưới đây từ đọc RTL; không coi là lỗi đã tái hiện nếu không có test riêng:

1. Giải mã xuất plaintext trước khi xác minh tag cuối. Khi thiếu một trong bốn word expected-tag, `tag_mismatch` không được kích hoạt; `tag_ready` chỉ biểu thị đã tính tag, không chứng minh xác thực thành công. Cần hợp đồng rõ với phía nhận dữ liệu và trạng thái “tag verified / failed / missing”.
2. Nonce/mask GMAC được suy ra từ LBA, không thấy bộ đếm phiên bản ghi. Ghi lại cùng LBA với cùng auth key làm lặp nonce; đây là vấn đề an toàn của giao thức xác thực cần giải quyết bằng nonce/version duy nhất được xác thực, không phải tối ưu bộ nhân.
3. `pipeline_busy` không bao gồm toàn bộ trạng thái setup; CSR/mode update hoặc clear/reset giữa lúc setup/streaming cần hợp đồng và regression. `setup_mode_changed` và cập nhật mode không bị gate theo idle như nhiều CSR khác.
4. Clear-key không xóa tất cả derived-key/H/mask/tweak registers; valid pipeline chỉ reset theo rst_n, không trực tiếp clear-key. Không nên coi lệnh clear-key hiện tại là bằng chứng zeroization hoặc hủy giao dịch đang bay.
5. Chỉ có interface cho full 128-bit blocks, chưa có byte-enable/keep hay ciphertext stealing. Không quảng bá hỗ trợ XTS partial-block hoặc GCM tổng quát từ các tệp này.

Không tự sửa các vấn đề này trong lần nhập mã/đánh giá kiến trúc để giữ baseline có thể đối chiếu.

## 6. Tiêu chí nghiệm thu bản mới

1. `gf_mult_128`: zero, identity, basis vectors, all-ones và random so với mô hình đa thức độc lập; kiểm tra không latch/RAM; H² khớp H·H.
2. GHASH x2 so với recurrence từng khối: 0/1/2/3/n khối, H=0, thay khóa, AAD, length, flush cuối lẻ.
3. Buffer: push/pop đồng thời, full/empty, output stall dài, giữ data/metadata, reset/clear không lặp/mất/đảo khối.
4. Top: AES/XTS encrypt/decrypt, DM on/off, valid gaps, downstream stalls, reset/clear, tag sai/thiếu, finalize lúc AES còn dữ liệu, thông điệp liên tiếp và thay khóa/LBA.
5. Throughput: đếm handshake thực tế sau warmup; phân biệt block II và pair II. Assertion không nhận khóa chưa sẵn sàng, không overflow, không output mất ổn định.
6. Quartus: so sánh cùng thiết bị/clock constraint; chỉ kết luận II/fmax/tài nguyên sau báo cáo đo được.

Tham chiếu chuẩn: NIST SP 800-38D (GHASH, biểu diễn trường, yêu cầu IV/nonce) https://doi.org/10.6028/NIST.SP.800-38D ; NIST SP 800-38E (XTS-AES) https://doi.org/10.6028/NIST.SP.800-38E. Báo cáo này chưa thay thế đánh giá giao thức bảo mật hoàn chỉnh.
